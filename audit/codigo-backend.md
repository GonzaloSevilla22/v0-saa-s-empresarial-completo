# Auditoría técnica pre-producción — Código: Backend Python (FastAPI)

**Proyecto:** ALIADATA (EmprendeSmart / EIE) — `backend/`
**Auditor:** Staff Python Engineer (auditoría externa, solo lectura)
**Fecha:** 2026-07-06
**Alcance:** `backend/` completo (core 10, routers 24, services 33, repositories 27, schemas 22; ~12.700 líneas sin tests). Tests leídos solo para entender contratos. Verificaciones puntuales de solo-lectura contra el proyecto Supabase de PROD (`gxdhpxvdjjkmxhdkkwyb`) vía `execute_sql` para confirmar/descartar hipótesis (roles, policies, definiciones de RPCs, datos agregados).

**Clasificación: MEJORABLE.** La arquitectura de 3 capas es disciplinada y el hot path transaccional (RPCs SECURITY DEFINER con guards internos) está bien resuelto, pero la auditoría encontró 2 hallazgos CRÍTICOS confirmados (CAE falso por adapter stub en el fire-and-forget fiscal; aislamiento multi-tenant que descansa en una RLS que el rol del pool bypasea, con varios endpoints sin filtro de cuenta) y 3 endpoints rotos en prod por un mismo bug de shape del dict `auth` enmascarado por los tests.

---

## 1. Contexto arquitectónico verificado

- Pool único `asyncpg` (`backend/core/database.py:19-24`, min 2 / max 10, `statement_cache_size=0`).
- JWT-passthrough: `get_db_conn` setea `app.jwt_claims` + `request.jwt.claims` con `set_config(..., is_local=false)` (`database.py:52-60`). Las RPCs SECURITY DEFINER leen `auth.uid()` de ahí.
- **El rol de conexión (`postgres`) tiene `BYPASSRLS=true` — VERIFICADO en prod** (`SELECT rolbypassrls FROM pg_roles WHERE rolname='postgres'` → `true`). El propio código lo asume: `database.py:35` ("el usuario postgres tiene BYPASSRLS") y `repositories/billing_repository.py:8-9`.
- Consecuencia estructural: **la RLS NO actúa como red de seguridad para ninguna query directa del backend**. La tenencia depende exclusivamente de (a) el dep `get_account_id` + filtros `WHERE account_id = $n` explícitos en los repos, y (b) los guards internos de las RPCs (`is_account_writer`, `auth.uid()`). Donde falta (a) y no hay (b), hay acceso cross-tenant (ver H2).

---

## 2. Hallazgos (detalle completo)

### H1 — CRÍTICA — El fire-and-forget fiscal usa SIEMPRE el stub: la próxima factura emitida queda `authorized` con un CAE FALSO

**Evidencia:**
- `backend/services/fiscal/fiscal_profile_service.py:437-441` — `process_doc_by_id_background` instancia **incondicionalmente** `WSFEStubAdapter()` y procesa el doc recién emitido.
- `backend/services/fiscal/wsfe_stub_adapter.py:36-45` — el stub retorna `is_approved=True` con un CAE de 14 dígitos derivado de SHA-256 del `fiscal_document_id` (fabricado, AFIP nunca lo emitió).
- `backend/services/fiscal/cae_relay_processor.py:95-102` — `is_approved=True` ⇒ `update_authorized(doc_id, cae=falso, ...)`. Estado terminal: el cron con el adapter real nunca lo reprocesa (`fiscal_document_repository.py:61-73`, `WHERE status='pending_cae'`).
- Disparadores: `routers/fiscal.py:273` (`POST /fiscal/documents/emit`) y `routers/fiscal.py:301` (`POST /fiscal/documents/emit-subscription-payment` — el flujo REAL de facturación de suscripciones del admin). El BackgroundTask corre inmediatamente después del commit y le gana al pg_cron (que sí usa `build_cae_adapter_from_settings()` con el cert real).
- El comentario del código ("Si el stub falla, el cron lo reintenta con el adapter correcto", `fiscal_profile_service.py:429-430`) es **falso**: el stub nunca falla, siempre aprueba.
- Verificación en prod: existe exactamente 1 `fiscal_document` `authorized` (2026-06-24) con CAE `86251075197091` ≠ CAE stub esperado (`55125...`) ⇒ ese doc obtuvo CAE real (probablemente anterior al wiring del fire-and-forget). **No hay corrupción todavía, pero el camino está armado hoy**: la próxima emisión por esos endpoints produce una factura con CAE trucho (riesgo fiscal/legal directo, RG AFIP).

**Recomendación:** en `process_doc_by_id_background`, construir el adapter con `build_cae_adapter_from_settings()` (mismo gate que el cron). Si la intención era no bloquear, mover la llamada SOAP a un executor o directamente eliminar el fire-and-forget y dejar solo el cron (latencia máx. 1 min). Agregar un gate defensivo en `CAERelayProcessor`: nunca `update_authorized` si `ambiente='produccion'` y el adapter es stub.

### H2 — CRÍTICA — Aislamiento multi-tenant roto en endpoints sin filtro de cuenta (la RLS que los docstrings invocan está bypaseada)

**Premisa verificada:** pool = rol `postgres` con `BYPASSRLS=true` (ver §1). Todos los docstrings tipo "RLS garantiza tenencia" / "RLS SELECT ya limita al tenant" son incorrectos para el backend.

**Superficies confirmadas sin scoping (lectura y escritura cross-tenant con UUID conocido, cualquier usuario autenticado de otro tenant):**
- `GET /quotes/{id}` y `POST /quotes/{id}/transition` — `quote_repository.py:102-131`: `SELECT/UPDATE ... WHERE id=$1` sin `account_id`. La transición es **escritura cross-tenant** (cambia el estado del presupuesto de otra cuenta).
- `GET /sales-orders/{id}` — `sales_order_repository.py:129-134`: sin `account_id`.
- `PUT /organizations/{org_id}/settings` — `organization_repository.py:15-25`: `UPDATE organizations ... WHERE id=$1` sin verificación de membresía (**escritura cross-tenant**); guard `require_role(auth,["user"])` es universal (ver H5/K9).
- `GET /customer-accounts/{id}/movements` y `GET /supplier-accounts/{id}/movements` — `customer_account_repository.py:72-97` / `supplier_account_repository.py:71-96`: filtran solo por el id de la cuenta corriente.
- Cash: `GET /branches/{id}/cashboxes`, `GET /cashboxes/{id}/sessions`, `GET /sessions/{id}/movements` (`cashbox_repository.py:11-18`, `cash_session_repository.py:45-95`) y `POST /cashboxes` (`cashbox_repository.py:46-61` — **INSERT cross-tenant**: crea una caja en la sucursal de otro tenant pasando su `branch_id`).
- Conciliación bancaria (lecturas): `get_session`, `list_import_lines`, `list_matches` filtran solo por ids opacos (`bank_reconciliation_repository.py:139-165,220-237`).

**Mitigantes:** los ids son UUID v4 (no enumerables) y las mutaciones del hot path van por RPCs con guards internos. Pero "seguridad por no-adivinanza de UUIDs" no es un control: los ids viajan en exports, PDFs, URLs compartidas y logs.

**Recomendación:** (1) decisión de plataforma: o el pool usa un rol SIN `BYPASSRLS` (rol dedicado + policies para el backend) o se declara formalmente que la única defensa es el filtro explícito; (2) barrer todos los repos y exigir `account_id` (derivado de `get_account_id`) en todo `WHERE` de SELECT/UPDATE directo; (3) test de arquitectura que falle si un método de repo interpola un id de path sin `account_id`.

### H3 — ALTA — Tres endpoints rotos en prod por shape inválido del dict `auth` (claves `sub`/`account_id` inexistentes), enmascarado por overrides de tests

**Evidencia:**
- `get_current_user` retorna `{"user_id", "role", "plan"}` (`core/auth.py:63-67`). No existe ni `sub` ni `account_id`.
- `routers/quotes.py:60` — `created_by=auth.get("sub", "")` ⇒ siempre `""` ⇒ `INSERT ... $6::uuid` con cadena vacía ⇒ error de encoding UUID ⇒ **500 en cada `POST /quotes`**.
- `routers/customer_accounts.py:61` y `routers/supplier_accounts.py:61` — `account_id = auth.get("account_id") or auth.get("sub", "")` ⇒ `""` ⇒ `WHERE account_id = $1::uuid` revienta ⇒ **500 en cada `GET /clientes/{id}/cuenta` y `GET /proveedores/{id}/cuenta`**.
- El frontend SÍ los llama: `frontend/hooks/data/use-quotes.ts:117`, `use-customer-account.ts:115`, `use-supplier-account.ts:122`.
- Por qué los ~1023 tests no lo ven: los overrides de auth usan el shape equivocado `{"sub": ..., "role": ...}` (`backend/tests/test_c30_customer_supplier_accounts.py:301,404`; `conftest.py:16`) y los tests de router mockean el pool, así que el cast a uuid jamás se ejecuta contra una DB real. Drift clásico test-double vs contrato real.

**Recomendación:** fix de una línea por sitio (`auth["user_id"]` / `Depends(get_account_id)`), y un `TypedDict AuthContext` + fixture única compartida que replique el shape real de `get_current_user` para TODOS los overrides de tests. Un smoke E2E de los 5-6 endpoints principales contra Postgres real (ya tienen `db reset` en CI) habría atrapado esto.

### H4 — ALTA — Relay Python del outbox desincronizado (2 de 4 consumers) y dispara con cualquier JWT: puede marcar eventos `processed` sin asientos contables ni notificaciones

**Evidencia:**
- Prod (verificado): el relay real es `rpc_process_outbox_dispatch` (SQL, pg_cron) y contiene consumers de journal y notifications (`pg_get_functiondef` → journal=true, notif=true).
- El backend conserva un relay paralelo: `POST /outbox/process-pending` (`routers/outbox.py:32-44`, auth = cualquier usuario autenticado) → `OutboxRelayService` que solo ejecuta **AuditLog + Email** (`services/outbox_relay_service.py:85-105`) y llama `rpc_mark_event_processed` al éxito (`outbox_repository.py:39-49`).
- Con el pool BYPASSRLS, el `INSERT INTO audit_logs` directo (`outbox_repository.py:88-95`) **sí funciona** (la "protección" que el propio docstring de las líneas 64-87 esperaba de la RLS no existe), así que el consumer de audit da OK y el evento queda `processed_at` seteado ⇒ `rpc_process_outbox_dispatch` nunca genera el asiento (JournalEntry) ni la notificación de ese evento. Pérdida contable silenciosa — la misma clase de bug que se pagó caro el 2026-07-01 (#248).
- Extra: `EMAIL_EVENT_TYPES` usa snake_case (`sale_created`) mientras los producers Python emiten PascalCase (`PurchaseCreated`, `StockAdjusted` — `purchase_repository.py:302-312`, `stock_repository.py:86-98`): el consumer de email del relay Python jamás matchea un evento real.

**Recomendación:** eliminar el endpoint y el `OutboxRelayService` (dead-but-armed), o degradarlo a proxy que invoque `rpc_process_outbox_dispatch`. Si se conserva, protegerlo con `require_platform_admin` + secret de máquina como `/fiscal/documents/process-pending-cron`.

### H5 — ALTA — Gating de plan fail-open y RBAC decorativo en todo el backend

**Evidencia:**
- `core/auth.py:61` — `app_plan = app_metadata.get("plan", "pro")`: si el JWT no trae `app_metadata.plan` (no existe custom access token hook; el webhook de pagos escribe `accounts.billing_plan`, nunca el JWT — `services/payments.py:165-173`), **todo usuario es "pro"**.
- `services/products.py:35-36` — `plan = auth.get("plan", "pro")` + `PLAN_PRODUCT_LIMITS` ⇒ límite efectivo 999999 para todos: el único gate de plan del backend es inoperante vía API directa (el gating de UI/Edge sigue, pero la defensa en profundidad no existe).
- `core/guards.py:14-17` — `require_plan` no tiene NINGÚN uso en el código productivo (dead code); su default (`"gratis"`) contradice el de `auth.py` (`"pro"`).
- `require_role(auth, ["user","admin"])` (40+ usos) es hoy un no-op: `app_role` siempre cae a `"user"` (docstring de `require_platform_admin`, `guards.py:23-27`, lo admite). Consistente con K9 (RBAC multirole pendiente), pero conviene dejar de escribir guards que aparentan proteger.

**Recomendación:** derivar el plan de la DB (accounts.billing_plan) en `get_account_id`/dep dedicado, o poblar `app_metadata` desde el webhook; defaultear a `"gratis"` (fail-closed). Documentar que `require_role` es placeholder hasta `v3-rbac-multirole`.

### H6 — ALTA — La cache del TA de WSAA existe pero NUNCA se inyecta: loginCms por cada CAE → cooldown de AFIP con volumen

**Evidencia:**
- `PostgresTicketCache` (`services/fiscal/wsaa_ticket_cache.py:27`) no tiene ninguna instanciación fuera de docstrings (grep en `backend/` sin tests: 0 usos).
- Ambos relay points construyen el adapter sin cache: `routers/fiscal.py:323` y `:366` — `build_cae_adapter_from_settings()` (param `ticket_cache=None` ⇒ "el adapter llama loginCms en cada invocación", `adapter_factory.py:52-54`).
- WSAA rechaza un loginCms nuevo mientras hay TA vigente (~12h) ⇒ a partir del segundo comprobante del día, `request_cae` falla y consume attempts (máx 10 con backoff 1..60min ≈ 4-5h) ⇒ riesgo de docs `rejected` sin causa real. Hoy no duele porque el volumen es ~0 (1 doc autorizado en prod), pero es incompatible con el objetivo comercial.
- Deuda adjunta: la clase quedó en el modelo per-account pre-v22 (constructor exige `supabase_service_client` + `account_id`; docstring con key de 4 partes vs `_parse_key` de 3) — hay que adaptarla al modelo plataforma antes de poder inyectarla.

**Recomendación:** implementar `PlatformPostgresTicketCache` sobre `wsaa_platform_tickets` (la migración `20260800000002_v22_platform_wsaa_tickets.sql` ya existe) usando asyncpg (no supabase-py sync) e inyectarla en los 2 relay points + en el fix de H1.

### H7 — ALTA — Webhook MercadoPago (governance CRÍTICO) sin transacción y con carreras

**Evidencia (`services/payments.py:104-232`):**
- `UPDATE accounts` (165), `INSERT billing_events` (175), `INSERT email_logs` (220) son statements sueltos sin `conn.transaction()`: un fallo entre el UPDATE y el INSERT deja el plan activado sin evento de auditoría/recibo (el retry de MP lo repararía, pero la ventana existe y el estado intermedio es visible).
- Idempotencia TOCTOU: check por SELECT previo (114-120); dos notificaciones concurrentes pasan ambas. El unique index parcial `idx_billing_events_mp_payment_id` (migración `20260609000001:47-50`, verificado) actúa de red, pero el duplicado muere en 23505→500 DESPUÉS de re-aplicar el UPDATE de accounts, y MP reintenta un 500.
- `member_row` (140-148): `fetchrow` sin `ORDER BY`/`LIMIT` — si un user perteneciera a 2 cuentas, el upgrade cae en una arbitraria. Mismo patrón laxo que `core/deps.py:19-21` (`LIMIT 1` sin ORDER BY).

**Recomendación:** envolver el flujo de escritura en `async with conn.transaction()`, mover el INSERT de billing_events ANTES del UPDATE (o usar `ON CONFLICT DO NOTHING` + early-return), y definir determinísticamente la cuenta (owner o cuenta activa).

### H8 — MEDIA — Mapeo P0xxx→HTTP quintuplicado e inconsistente; el contrato RFC 7807 se rompe según el camino del error

**Evidencia:**
- 5 implementaciones paralelas: `core/errors.py:88-114` (global), `services/sales.py:86-100`, `services/sales_orders.py:150-164`, `services/quotes.py:157-172` (idénticas entre sí), `services/customer_accounts.py:22-40` ≡ `services/supplier_accounts.py:19-37`, `services/bank_accounts.py:25-32`.
- Inconsistencias reales: `P0422` → **422** en el handler global (`errors.py:94`) pero → **409** en sales/quotes/sales_orders (`sales_orders.py:161`); `P0412` → 404 global (`errors.py:98`) pero → 400 en cuentas corrientes (`customer_accounts.py:28`).
- El shape 7807 también diverge: los servicios que convierten a `HTTPException` salen con `code="http_error"` y detail prefijado ("Conflicto: ..."), mientras el handler global emite `code=<sqlstate>` limpio (`main.py:111-118` vs `errors.py:117-127`). Un cliente no puede depender de `code`.
- Smell puntual: `except (IndexError, Exception)` (`customer_accounts.py:38`, `supplier_accounts.py:35`) — tupla sin sentido.

**Recomendación:** borrar los `_map_postgres_error`/`_pg_to_http` locales y dejar que `asyncpg_error_handler` sea el ÚNICO mapeador (ya soporta overrides por endpoint tipo `BANK_ACCOUNT_CREATE_ERRCODE_STATUS`); congelar la tabla P0xxx→status en un solo módulo con test de contrato.

### H9 — MEDIA — Dinero convertido a `float` en la frontera service→repo pese a schemas `Decimal` y columnas `numeric`

**Evidencia:** `float(payload.amount)` y variantes en `services/customer_accounts.py:95`, `services/supplier_accounts.py:92,112`, `services/cash.py:52,63,94`, `services/sales_orders.py:87-89` (quick_sale items), `services/stock.py:29`; también `cae_relay_processor.py:80,87-88` y `wsfe_adapter.py:475` (montos fiscales como float). asyncpg encodea Decimal→numeric nativamente; el `float()` es gratuito y pierde exactitud por encima de ~15 dígitos significativos (plausible en ARS con inflación) además de romper la regla de oro de dinero. Contraste: `services/quotes.py:49-52` lo hace bien (`str(Decimal)`).

**Recomendación:** eliminar todos los `float()` sobre montos; pasar `Decimal` directo (o `str` para payloads jsonb, como quotes). Lint/CI: prohibir `float(` sobre campos `amount|total|balance|price|subtotal`.

### H10 — MEDIA — Escrituras multi-statement sin transacción + FSM con TOCTOU

**Evidencia:**
- `QuoteRepository.create_quote` (`quote_repository.py:41-87`): INSERT del header + N INSERTs de items SIN `conn.transaction()`. Un fallo en un item (FK, datos) deja un presupuesto a medias, visible en `GET /quotes`. (Además: N round-trips en loop en vez de un INSERT multi-fila).
- `ProductRepository.update` (`product_repository.py:94-129`): UPDATE + `_propagate_min_stock` + read-compute-apply del delta de stock, sin transacción — el comentario de las líneas 99-101 dice "en la MISMA transacción" y es falso (solo `create` la tiene, línea 57). El delta `target − Σ branch_stock` leído fuera de transacción es una carrera clásica: dos ediciones concurrentes producen stock final incorrecto.
- `transition_quote`: el service valida el estado con un SELECT (`services/quotes.py:113-123`) y el repo hace `UPDATE ... SET status=$2 WHERE id=$1` sin `AND status=$viejo` (`quote_repository.py:120-131`) — sin compare-and-swap ni registro en `document_status_history` (confirma K15).

**Recomendación:** transacción en ambos repos; CAS (`WHERE status = $expected`) + `record_status_transition` en quotes (o mover la transición a una RPC como el resto de la FSM).

### H11 — MEDIA — Duplicación estructural masiva entre módulos homólogos

**Evidencia (pedido explícito de la auditoría):**
- `SalesRepository` vs `PurchaseRepository`: `list_paginated_by_operation`, `get_operation`, `get_idempotency`, `delete_by_id`, `delete_by_operation` son espejos línea-a-línea (~200 líneas duplicadas; los propios comentarios lo admiten: "Espejo de PurchaseRepository.delete_by_id", `sales_repository.py:88`). La divergencia ya ocurrió: `create_operation_with_event` existe solo en purchases y es **dead code** (0 llamadas; el producer PurchaseCreated vive en la RPC desde `20260803000002`).
- `customer_accounts` vs `supplier_accounts`: services y repos ~90% idénticos (docstring: "Espejo exacto", `supplier_account_repository.py:4`).
- Helpers copy-pasteados: `_default` (serializador Decimal) ×6 (`sales_repository.py:190,239`, `purchase_repository.py:194,222,269`...), `_jsonb` ×5 (`customer_account_repository.py:17`, `supplier_account_repository.py:16`, `quote_repository.py:20`, `sales_order_repository.py:19`, `cash_session_repository.py:10`, `bank_reconciliation_repository.py:25`), `pages = -(-total // size)` ×6 (sales/purchases services, payments router, journal repo...) pese a existir `BaseRepository.paginate` que ya arma el envelope.
- Los deletes de sales/purchases revierten stock leyendo `stock_movements ... LIMIT 1` por fila y luego borran TODOS los movements de la referencia (`sales_repository.py:100-122`): correcto solo mientras el modelo sea 1 fila = 1 item; si una fila de venta llegara a tener >1 movimiento, se revierte uno y se borran todos. Frágil frente a C-20 Grupo 10.

**Recomendación:** extraer `OperationRepository` base parametrizada (tabla, reference_type, RPC) y un `pg_jsonb()`/`decimal_default()` en un util común; borrar `create_operation_with_event`.

### H12 — BAJA — Config y bordes: fallback HS256 con secret default, CORS credentials+"*", AttributeError latente, WS sin tenancy, SOAP sync en el event loop

**Evidencia:**
- `core/config.py:5` — `supabase_jwt_secret: str = "dev-secret"` + `core/auth.py:33-49`: si `supabase_url` no empieza con "http" (env faltante/typo), la validación cae a HS256 con un secret CONOCIDO ⇒ bypass de auth por misconfiguración. Fail-open; debería abortar el arranque en `app_env=production`.
- `main.py:58-64` — `allow_origins=["*"]` (default) con `allow_credentials=True`; `cors_error_headers` (`errors.py:74-81`) refleja cualquier origin con credentials cuando `backend_allowed_origin="*"`.
- `routers/fiscal.py:115` — `settings.supabase_service_role_key` no existe en `Settings` (el campo se llama `service_role_key`) ⇒ AttributeError ⇒ 500 en `POST /fiscal/profile/cert-upload-url` (endpoint deprecado, pero roto).
- `routers/ws.py:37-64` — `/ws/{room_id}`: cualquier autenticado se une a cualquier room (sin binding room↔account) y el broadcast no aísla tenants; `manager.broadcast` sin manejo de sockets muertos. Probable dead code (DEC-16 dejó realtime en Supabase) — confirmar y borrar.
- `wsfe_adapter.py:409,495,588` + `_build_zeep_client` (requests sync): llamadas SOAP bloqueantes dentro de `async def` — bloquean el event loop completo (Render free = 1 proceso) durante cada round-trip a AFIP; `process_all_pending_documents` puede serializar hasta 50. Mover a `asyncio.to_thread`.
- `services/fiscal/fiscal_profile_service.py:406-411` — el summary del cron retorna `authorized/retried/rejected` siempre en 0 (contadores nunca incrementados): telemetría engañosa.
- `core/redis_client.py` — Redis se inicializa y no se usa en ningún request path (rate limiting "unavailable"): dead infra.
- `SaleOperationIn.org_id` (`schemas/sales.py:24`) se acepta y se ignora (la cuenta sale de `get_account_id`): campo muerto en el contrato.
- Imports locales redundantes (`import json as _json` en `sales_repository.py:214`, `payments.py:47`; `import json` dentro de funciones en `outbox_repository.py:110,176`, `fiscal_profile_service.py:223,277`).

---

## 3. Fortalezas (con la misma seriedad)

1. **Disciplina de capas real**: routers finos (validación+DI), guards solo en services, repos sin lógica — el patrón se cumple en ~24 routers de forma notablemente consistente.
2. **Hot path transaccional bien resuelto**: mutaciones críticas (ventas, compras, caja, conciliación, cta cte) van por RPCs SECURITY DEFINER con idempotencia (`operation_idempotency`), guards internos y ERRCODEs tipados P0xxx (DEC-24 aplicado de verdad).
3. **Idempotencia como estándar**: `Idempotency-Key` header con fallback deprecado y 422 tipado (`core/idempotency.py`), replay explícito (`replayed=true`), claims con `ON CONFLICT DO NOTHING`.
4. **RFC 7807 centralizado** con handlers para asyncpg, validación Pydantic, HTTPException y catch-all sin filtrar internals (`main.py:80-130`), CORS inyectado en errores.
5. **Manejo cuidadoso del material criptográfico AFIP**: `PlatformCredentialProvider` (repr/str seguros, key nunca logueada, fail-closed), relay machine-endpoint con `hmac.compare_digest` y RELAY_SECRET fail-closed (`routers/fiscal.py:345-357`), anti-double-CAE con lease optimista (`claim_pending`).
6. **Pydantic v2 idiomático**: Decimal en montos, `model_validator` cruzados (p.ej. `bank_account_id` requerido si method bancario), `PageOut[T]` genérico, `exclude_unset` para upserts parciales, coerciones `mode="before"` documentadas.
7. **Soft delete centralizado con allowlist anti-inyección** (`base.py:13-15,126-139`) y `not_deleted_clause` reutilizado.
8. **Comentarios de arquitectura con referencias a decisiones/spec** (D-refs, RN-refs) en casi todos los archivos — trazabilidad excepcional para un equipo chico.

## 4. Debilidades sistémicas

1. La premisa "RLS como red de seguridad" es falsa en el backend (BYPASSRLS) y nadie lo re-verificó al escribir repos nuevos que dependen de ella.
2. Tests de router con overrides que no replican el contrato real de `get_current_user` → bugs de integración invisibles con 1023 tests verdes.
3. Duplicación por copy-paste entre módulos espejo sin extraer base común → divergencias ya materializadas (outbox event, mapeos de error).
4. Convivencia de código vivo y muerto sin marcar (relay Python vs SQL, ticket cache, require_plan, WS, redis) — "dead-but-armed paths" que un llamado accidental reactiva.
5. Guards de autorización decorativos (role/plan) que dan falsa sensación de defensa en profundidad.

## 5. Deuda técnica priorizada

- Retirar `OutboxRelayService` + endpoint (o proxy a `rpc_process_outbox_dispatch`).
- Unificar mapeo P0xxx→HTTP en un solo módulo (borrar 4 copias).
- Extraer base común sales/purchases y customer/supplier (repos + services).
- `PlatformPostgresTicketCache` asyncpg + inyección en relay points.
- Borrar: `create_operation_with_event`, `require_plan` (o usarlo), `_read_cert_from_storage`, endpoints cert-upload deprecados (o arreglar el AttributeError), `routers/ws.py` + `ws_manager` si DEC-16 lo dejó huérfano, `core/redis_client` si no se usa.
- `float()` → `Decimal` en toda la frontera de montos.
- SOAP AFIP a `asyncio.to_thread`; contadores reales en el summary del cron.
- Fixture de auth única con el shape real + smoke E2E contra Postgres del CI.
- `member_row`/`get_account_id` determinísticos (ORDER BY) para multi-cuenta futura.

## 6. Inconsistencias documentación ↔ código

- CLAUDE.md / KB 08 / DEC: "JWT-passthrough (RLS org-based activa como red de seguridad)" — la RLS NO está activa para el backend (rol postgres BYPASSRLS, verificado). Los guards reales son los filtros SQL y las RPCs.
- `outbox_repository.py:64-87` (docstring): asume que la RLS bloquearía el INSERT en audit_logs desde el backend — no aplica con BYPASSRLS.
- `fiscal_profile_service.py:429-430`: "Si el stub falla, el cron lo reintenta con el adapter correcto" — el stub nunca falla; aprueba con CAE falso.
- `product_repository.py:99-101`: "en la MISMA transacción" — `update()` no abre transacción.
- `routers/outbox.py` docstring: "Called by the pg_cron job" — el pg_cron llama a la función SQL, no a este endpoint (migración 20260718000001: el endpoint quedó "como trigger" manual).
- `wsaa_ticket_cache.py` docstring: cache key de 4 partes vs `_parse_key` de 3; nombre `PlatformPostgresTicketCache` citado en docstrings no existe (la clase es `PostgresTicketCache`).
- `repositories/fiscal_document_repository.py:5-6`: "el relay usa service_role" — usa el mismo pool postgres (no hay pool service separado; `init_service_pool` es no-op).

## 7. Known issues verificados (estado)

| ID | Estado | Nota |
|----|--------|------|
| K1 | CONFIRMADO | `pg_policies` prod: `bank_accounts` solo SELECT; `cashboxes` SELECT+INSERT; sin UPDATE en ninguna. Ojo: con BYPASSRLS del pool las policies hoy ni aplican al backend (ver H2). |
| K2 | NO_EVALUADO | Gates de CI en migraciones — fuera del scope backend Python. |
| K3 | CONFIRMADO | Prod: 23 `sale_items` + 18 `purchase_items` con `account_id IS NULL`. |
| K4 | CONFIRMADO | `account_feature_flags`: `sale_items_rpc_v2` enabled en 26/29 cuentas; 3 sin flag → sus ventas no escriben sale_items/snapshots. |
| K5 | CONFIRMADO (abierto) | No reproducible desde código estático. Candidatos concretos hallados: (a) todo sqlstate no mapeado (p.ej. 23502) cae en 500 "internal_error" (`errors.py:149-154`); (b) `set_config(..., is_local=false)` + `statement_cache_size=0` sugiere pooler — en transaction-mode los claims de sesión pueden aterrizar en otra server-conn ⇒ `auth.uid()` NULL intermitente en la RPC ⇒ error no-P04xx ⇒ 500. Verificar qué URL usa Render (5432 session vs 6543 transaction). |
| K6 | NO_EVALUADO | Specs OpenSpec — fuera de scope. |
| K7 | CONFIRMADO | `product_repository.py:16-21,99-113`: dual-write legacy `products.min_stock` + propagación a `branch_stock.min_stock` (fuente real). |
| K8 | CONFIRMADO | `pg_get_functiondef(rpc_create_purchase_operation)` en prod: NO escribe `purchase_items` (header plano RN-97 vigente para compras). |
| K9 | CONFIRMADO | `auth.py:56-60`: `app_role` siempre `'user'` (sin token hook); `require_role(["user","admin"])` es no-op; `require_platform_admin` verifica contra DB como excepción correcta. |
| K10 | NO_EVALUADO | Infra Render fuera de scope; `statement_cache_size=0` (`database.py:23`) es consistente con uso de pooler. |
| K11 | NO_EVALUADO | Enum UoM — no tocado por el backend Python auditado. |
| K12 | CONFIRMADO | `quote_repository.py:63-66,76`: `iva_rate_snapshot` se inserta NULL (products sin columna IVA). |
| K13 | CONFIRMADO y AGRAVADO | Los `/cuenta` no solo no paginan: están ROTOS en prod (H3, `account_id=""`). |
| K14 | CONFIRMADO | Endpoints fiscales sin `require_idempotency_key`; idempotencia por clave natural (receipt_id en emit-subscription-payment con SELECT previo — TOCTOU teórico benigno; fiscal_document_id en process). |
| K15 | CONFIRMADO | `quote_repository.py:120-131` + `services/quotes.py:91-133`: transición por UPDATE directo, sin historial ni CAS (H10). |
| K16 | NO_EVALUADO | Vive en SQL (notifications) — fuera de scope. |
| K17 | CONFIRMADO | Prod: `c28_register_cash_movement` usa `MAX(` (patrón buggy); `rpc_register_cash_movement` (la que llama el backend, `cash_session_repository.py:76`) no lo usa. Riesgo acotado a quien aún invoque la c28_. |
| K18 | CONFIRMADO (indirecto) | `outbox_repository.insert_audit_log` inserta solo `account_id, action, created_at` — coherente con el DROP NOT NULL drift-tolerant. |
| K19 | NO_EVALUADO | Drift prod/preview — fuera de scope backend. |
| K20 | NO_EVALUADO | Pendientes externos del PO. |

## 8. Métricas y observaciones menores

- Tamaños sanos: archivo más grande 610 líneas (`wsfe_adapter.py`); función más larga `_call_wsfe` (~175 líneas, complejidad justificada por el protocolo AFIP pero candidata a partirse en `_build_det_request` / `_parse_response`). No hay "God functions" fuera de fiscal.
- Naming consistente (snake_case, sufijos `In/Out`, prefijos `rpc_`), `from __future__ import annotations` uniforme, cero `Any` gratuito en firmas públicas (los `dict` sin tipar en services son la excepción — un `AuthContext` TypedDict pagaría rápido, ver H3).
- `promote_to_order`/`confirm`/`quick_sale`: patrón `except: _map(); return result` deja `result` potencialmente unbound para el analizador (funciona porque el mapper siempre raise-a; frágil ante refactors).
- `list_paginated_by_operation` pagina por operación pero devuelve filas por item (JOIN a sale_items): contrato implícito con el frontend (agrupa client-side) — documentarlo en el schema.
- `purchases.create_purchase_operation` toma `description` del primer item (`services/purchases.py:66`) — acoplamiento al shape del frontend, comentado pero frágil.
- `receipts.py` (fpdf) corre CPU-bound sync en el event loop en `POST /sales/receipt-pdf` — aceptable por tamaño, vigilar.

*Fin del detalle. Los 12 hallazgos priorizados están en el objeto estructurado de la auditoría.*
