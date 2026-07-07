# Auditoría Técnica Pre-Producción — Dimensión: Arquitectura

**Proyecto**: ALIADATA (EmprendeSmart / EIE) — SaaS ERP para microemprendedores
**Auditor**: Principal Software Architect (auditoría de solo lectura)
**Fecha**: 2026-07-06/07
**Clasificación**: **Mejorable**

---

## 1. Alcance y método

Se leyó a fondo: `backend/main.py`, los 10 módulos de `backend/core/`, muestreo profundo de 7 routers (`sales`, `purchases`, `branches`, `outbox`, `health`, `purchases`, `fiscal` parcial), 8 services (`sales`, `purchases`, `cash`, `cost_centers`, `outbox_relay_service`, `payments`, `fiscal/fiscal_profile_service` parcial, `fiscal/fiscal_document_port`), 4 repositories completos (`sales_repository`, `purchase_repository`, `outbox_repository`, `base`), `frontend/middleware.ts`, `frontend/lib/supabase/middleware.ts`, `frontend/lib/api/python-client.ts`, `frontend/contexts/auth-context.tsx`, `frontend/providers/`, hooks de datos representativos (`use-branches`), `knowledge-base/08` y `09` completos, `modelo-dominio-aliadata-v2.md` §0-5, `CHANGES.md` (estructura y estado), `openspec/specs/asyncpg-pool/spec.md`, el design/tasks archivado de `backend-data-layer`, y ~10 migraciones SQL clave (outbox, purchase RPC, cash fix, FSM, ledger bancario). Se ejecutaron queries de **solo lectura** contra el proyecto de producción `gxdhpxvdjjkmxhdkkwyb` (pg_stat_activity, pg_roles, pg_class, conteos) para verificar hipótesis.

---

## 2. Veredicto ejecutivo

La arquitectura de ALIADATA es, en su diseño documental y en sus patrones, notablemente superior a la media de un MVP: monolito modular con 3 capas reales en el backend, RPC-as-UoW (DEC-24) aplicado con disciplina en los hot paths de creación, outbox transaccional in-DB con 4 consumers idempotentes, FSM como datos, puerto/adaptador hexagonal para AFIP, snapshots inmutables, y una base documental (KB + modelos V2/V3 + 62 specs + DEC-01..24) que la mayoría de los equipos senior no logra mantener.

Sin embargo, la auditoría encontró que **el mecanismo central de seguridad multi-tenant del backend — el JWT-passthrough con RLS como red de seguridad (DEC-13) — no funciona como está documentado en producción**, y que la **segunda capa de autorización (guards de service layer) está degenerada** al punto de que un guard bloquea una feature completa (cost centers: 0 filas en prod) y el resto no filtra nada. A esto se suman erosiones reales de las fronteras del modelo híbrido y violaciones de las propias decisiones DEC-07/DEC-24 en los write-paths de borrado. La brecha entre lo documentado y lo desplegado es el patrón dominante de los hallazgos.

---

## 3. Hallazgos (detalle exhaustivo)

### H1 — [CRITICA] El JWT-passthrough está arquitectónicamente roto en producción: `postgres` con BYPASSRLS + GUC de sesión sobre pooler en transaction mode

**Evidencia verificada:**

1. `backend/core/database.py:19-24` — el pool asyncpg se crea con `statement_cache_size=0` (el ajuste específicamente requerido para poolers en *transaction mode*).
2. `backend/core/database.py:52-60` — los claims se inyectan con `set_config('app.jwt_claims', $1, false)` y `set_config('request.jwt.claims', $2, false)`. El tercer argumento `false` = **scope de SESIÓN**, no de transacción, y se ejecuta **fuera de cualquier transacción explícita**.
3. `openspec/specs/asyncpg-pool/spec.md:5,10,26` — la spec (fuente de verdad) exige **`SET LOCAL app.jwt_claims`** (scope transaccional). El código no cumple su propia spec.
4. `openspec/changes/archive/2026-06-07-backend-data-layer/tasks.md:51` — la task de deploy prescribe "preferir el pooler `*.supabase.co:6543`" (= transaction mode de Supavisor).
5. **Verificado en prod** (`pg_stat_activity`): las conexiones del backend entran con `usename=postgres`, `application_name='Supavisor'` — el backend pasa por el pooler, no por conexión directa. Se observó **1 sola conexión de servidor** para un pool cliente de `min_size=2` — consistente con multiplexación transaction-mode (en session mode habría ≥2 conexiones pinneadas).
6. **Verificado en prod** (`pg_roles`): `postgres.rolbypassrls = true`. **Verificado** (`pg_class`): todas las tablas de negocio muestreadas (`sales`, `purchases`, `products`, `clients`, `accounts`, `account_members`, `events`, `bank_accounts`, `cashboxes`) tienen `owner=postgres` y `relforcerowsecurity=false`.
7. Antecedente del propio equipo (C-17): "SET ROLE no funciona con pgBouncer transaction mode" — confirmación operativa de que el DATABASE_URL de prod está en transaction mode.

**Consecuencias:**

- **(a) La RLS es totalmente inerte para el backend.** `postgres` tiene BYPASSRLS y es owner sin FORCE RLS: ninguna policy se evalúa en ninguna query del backend. La afirmación de DEC-13 y KB-08 ("la RLS org-based sigue activa como red de seguridad… última línea de defensa") es **falsa en producción**. El aislamiento de tenant del backend descansa exclusivamente en (i) que `get_account_id` resuelva bien el tenant vía `auth.uid()` y (ii) que cada query de repo filtre a mano por `account_id`.
- **(b) En transaction mode, los GUC de sesión no viajan con las queries.** Cada statement fuera de transacción es su propia transacción para el pooler: el `set_config` puede aterrizar en la conexión de servidor A y la query siguiente en la B. Dos modos de fallo: **fail-closed** — `auth.uid()` devuelve NULL → `get_account_id` 403 o el RPC aborta → 500 intermitente **sin llegar a la DB** (encaja exactamente con el síntoma del bug abierto K5: compras 500 intermitente); **fail-open** — la query corre sobre una conexión de servidor donde OTRO usuario dejó sus claims de sesión (nunca se resetean entre transacciones en el pooler) → `get_account_id` resuelve el **tenant equivocado** → lecturas Y escrituras cross-tenant, **sin RLS que las frene** (por (a)).
- Con 29 cuentas y baja concurrencia, la reasignación de conexiones es poco frecuente — por eso "funciona". El riesgo crece linealmente con el tráfico (objetivo comercial junio 2026) y con los crons cada minuto (CAE relay + outbox) que agregan concurrencia de fondo.

**Recomendación (P0):**
1. Crear un rol dedicado para el backend **sin BYPASSRLS** (o usar `authenticator`+`SET ROLE` sobre session pooler) para que la RLS vuelva a ser red real.
2. Envolver cada request en una transacción explícita y usar `set_config(..., true)` (transaction-local) DENTRO de ella — el patrón exacto de PostgREST — o migrar el `DATABASE_URL` al session pooler y resetear GUCs en el release del pool.
3. Mientras tanto: probar bajo carga concurrente (dos JWTs, requests paralelos) para detectar el interleave; monitorear 500s de compras contra este mecanismo.

---

### H2 — [ALTA] La capa 2 de autorización (guards del service layer) está degenerada; `cost_centers` quedó funcionalmente rota

**Evidencia:**

- `backend/core/auth.py:56-61` — el rol de app no viaja en el JWT (no existe custom access token hook, confirmado por el propio código en `backend/core/guards.py:20-29` y `backend/services/fiscal/fiscal_profile_service.py:280`): `auth["role"]` **siempre** cae al fallback `'user'` y `auth["plan"]` defaultea a `'pro'`.
- Consecuencia 1: `require_role(auth, ["user","admin"])` — el guard usado en TODOS los services de mutación (sales, purchases, cash, stock, quotes, clients, banks, etc.) — **pasa para cualquier usuario autenticado**. Es un no-op decorativo.
- Consecuencia 2: `require_role(auth, ["owner","admin"])` en `backend/services/cost_centers.py:34,51,70` **no puede pasar jamás** (el rol es siempre `'user'`) → crear/editar/desactivar centros de costo devuelve 403 a todo el mundo, incluido el owner. **Verificado en prod: `cost_centers` tiene 0 filas** pese a que la feature V2.5 se marcó completa. Los tests unitarios pasan porque inyectan `auth={"role":"owner"}` a mano — enmascaran el defecto.
- Consecuencia 3: `require_plan` está **definido y jamás invocado** en ningún service (grep exhaustivo). El gating por plan del backend no existe; vive solo en el frontend (`getEffectivePlan`) y en RPCs puntuales (`branch_limit_exceeded`).
- KB-08 documenta "tres capas de autorización: dependency (org+rol+plan, cacheable en Redis) → guards service → RLS". La capa 1 no resuelve rol/plan reales, la capa 2 es un no-op o un bloqueo total, la capa 3 está apagada para el backend (H1). De las tres capas documentadas, **la única efectiva es el filtro manual `WHERE account_id`** más los checks internos de los RPCs.
- Mitigante encontrado y correcto: `require_platform_admin` (guards.py:20) sí verifica contra `profiles.role` en DB (fix v22) — es el patrón que el resto de los guards debería seguir.

**Recomendación (P0/P1):** decidir la fuente de verdad del rol (custom access token hook que copie `account_members.role` al JWT, o lookup en DB como `require_platform_admin`) y reescribir los guards contra ella. Arreglar `cost_centers` de inmediato (hoy es una feature muerta en prod). Eliminar `require_plan` o implementarlo de verdad. Este trabajo converge con `v3-rbac-multirole` (CRÍTICO, pendiente sign-off PO) — pero el fix de cost_centers no debería esperar a ese change.

---

### H3 — [ALTA] Outbox: dispatch duplicado y divergente (Python 2 consumers vs DB 4) + RPCs de relay ejecutables por cualquier usuario autenticado

**Evidencia:**

- El dispatch canónico es in-DB: `rpc_process_outbox_dispatch` (migración `20260718000001_c25_events_outbox_reconcile.sql:410+`, pg_cron `relay-process-outbox` cada minuto), extendido por `20260803000001` (Consumer 3 JournalEntry) y `20260808000001` (Consumer 4 Notification). Hoy: **4 consumers**.
- El trigger "manual/secundario" Python sigue montado (`backend/main.py:154`, `backend/routers/outbox.py:32-44` → `backend/services/outbox_relay_service.py`) e implementa **solo 2 consumers** (AuditLog + Email) y luego marca `processed_at`. Nunca se actualizó tras los consumers 3 y 4.
- Cualquier usuario autenticado puede invocar `POST /outbox/process-pending` (solo exige `get_current_user`); como el backend corre como `postgres` BYPASSRLS (H1), los INSERTs directos a `audit_logs`/`email_logs` **funcionan** → los eventos pendientes (de **cualquier** cuenta: `rpc_process_outbox_batch` es SECURITY DEFINER cross-account) quedarían `processed` **sin asiento contable ni notificación**, de forma silenciosa e irreversible (la idempotencia por `(event_id, consumer_type)` impide reprocesar).
- Además `rpc_mark_event_processed(uuid)` es SECURITY DEFINER con `GRANT EXECUTE TO authenticated` **sin guard interno** (`20260718000001:201-203`, sin redefiniciones posteriores): llamable directo vía PostgREST desde el browser por cualquier usuario logueado, sobre cualquier `event_id` que conozca (sus propios eventos son listables por la SELECT policy per-account) → un usuario puede suprimir la contabilización de sus propias operaciones.
- Nada en el frontend llama al endpoint Python (grep limpio) — hoy es código muerto peligroso, no un flujo activo. `events_pending=0` en prod (outbox al día).

**Recomendación (P1):** eliminar el endpoint Python y `OutboxRelayService` (o degradarlos a admin-only con `require_platform_admin` y actualizados a 4 consumers); agregar guard interno a `rpc_mark_event_processed` (p.ej. exigir `auth.uid() IS NULL` / rol de servicio, o revocar de `authenticated` y dejarla solo para el cron).

---

### H4 — [ALTA] Los write-paths de borrado violan DEC-24 (UoW en RPC) y DEC-07 (ledger inmutable)

**Evidencia:**

- `backend/repositories/sales_repository.py:86-177` y `backend/repositories/purchase_repository.py:88-182` — `delete_by_id`/`delete_by_operation` implementan en Python transacciones multi-paso (`async with self._conn.transaction()`): lectura del movimiento, reversa de stock vía `rpc_apply_product_stock_delta`, **`DELETE FROM stock_movements`**, `DELETE FROM sales/purchases`, limpieza de `operation_idempotency`.
- DEC-07 (KB-09): "`stock_movements` es solo-inserción. **Ningún movimiento puede editarse o borrarse.** Las correcciones se hacen con ajustes compensatorios… El `movement_number` secuencial permite detectar huecos". El código borra físicamente filas del ledger → rompe la invariante documentada, deja huecos de numeración y destruye trazabilidad.
- DEC-24 (KB-09): "La transacción de escritura vive en los RPCs SECURITY DEFINER… los services… **nunca abren ni comitean una transacción ellos mismos**". Estas son las únicas rutas de escritura del hot path que quedaron fuera del patrón (los creates y updates sí van por RPC).
- Agravante de consistencia: el borrado **no emite evento de outbox** → no hay audit log del borrado ni asiento compensatorio para una venta que ya generó `journal_entry` vía Consumer 3 → la contabilidad devengada queda con un asiento de una venta que ya no existe.
- Con RLS apagada para el backend (H1), la única protección de tenancy de estos DELETEs es el `WHERE account_id` manual (presente, correcto hoy).

**Recomendación (P1):** mover el borrado a un RPC SECURITY DEFINER (`rpc_delete_sale_operation`) que (i) use ajuste compensatorio en el ledger en lugar de DELETE, (ii) emita evento `SaleDeleted` para audit + asiento de reversa, (iii) valide estado FSM (no borrar ventas facturadas con CAE). Alternativa mínima: reemplazar el DELETE del ledger por movimiento compensatorio y emitir el evento desde Python en la misma transacción.

---

### H5 — [ALTA] La frontera del modelo híbrido está erosionada: datos ERP fluyen directo browser→DB y hay doble write-path

**Evidencia:**

- El contrato documentado (KB-08, DEC-12): frontend → FastAPI para **mutaciones + lecturas de datos**; Supabase directo solo para Realtime/Auth/Storage.
- Realidad medida: **140 usos de `supabase.from(...)` en 53 archivos** y **31 usos de `.rpc(...)` en 17 archivos** del frontend. Una parte es legítima (community/cursos/IA/admin — dominios que nunca migraron por decisión; notificaciones Realtime per DEC-16). Pero incluye dominio ERP núcleo:
  - `frontend/hooks/data/use-branches.ts:96-154` — **mutaciones** de sucursales vía `supabase.rpc("rpc_create_branch"/"rpc_open_branch"/"rpc_close_branch"/"rpc_deactivate_branch")` directo desde el browser, mientras `backend/routers/branches.py:47-86` expone `POST /branches`, `/open`, `/close` — **endpoints muertos** (nadie los llama).
  - `stock-adjustment-modal.tsx`, `stock-import-adjustment-dialog.tsx` — ajustes de stock por RPC directo.
  - `use-branch-stock.ts`, `use-units-of-measure.ts`, `use-dashboard-kpi-summary.ts`, `use-profitability.ts`, `use-period-comparison.ts`, `use-channel-margin.ts`, `reportes/*`, `ventas/ordenes/[id]` — lecturas ERP directas.
- Consecuencia arquitectónica: el service layer FastAPI **no es choke point**. Los estándares de plataforma V3 (Idempotency-Key por header, RFC 7807, paginación estándar, soft-delete filtering del `BaseRepository`) **no aplican** a estas rutas; cualquier regla futura implementada solo en Python (rate limit, RBAC multirol, validaciones) tendrá bypass. Dos caminos de escritura para el mismo agregado (Branch) = deriva de comportamiento garantizada.
- Mitigante real: como los RPCs SECURITY DEFINER contienen las invariantes (DEC-24), ambos caminos convergen en la misma lógica transaccional — el daño hoy es de gobernabilidad y consistencia de contrato, no de corrupción.

**Recomendación (P1/P2):** inventariar las llamadas directas por dominio (ERP vs community/IA), migrar las mutaciones ERP restantes al backend (empezando por branches y ajustes de stock, que ya tienen endpoint), y borrar los endpoints muertos o conectarlos. Documentar la lista blanca de dominios que legítimamente hablan directo con Supabase.

---

### H6 — [MEDIA] `get_account_id`: sin contrato de tenant activo y query extra por request

**Evidencia:** `backend/core/deps.py:19-24` — `SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1` **sin ORDER BY**. Con membresía multi-cuenta el resultado es no determinístico; el frontend mantiene una cookie de tenant activo (`COOKIE_KEYS.TENANT`, `frontend/lib/supabase/middleware.ts:139`) que el backend **ignora por completo**. La feature de invitaciones (`organizacion/invitar`) hace posible la multi-membresía. **Verificado en prod: hoy 0 usuarios con >1 cuenta** — riesgo latente, no activo. Además, esta query corre en CADA request (el cache Redis de org/rol prometido en KB-08 y en el design de `backend-data-layer` nunca se implementó) — sobre un pooler transaccional, es un statement más expuesto al problema H1.
**Recomendación (P2):** definir el contrato de tenant activo (header `X-Account-Id` validado contra membresía, o claim en el JWT), agregar `ORDER BY` determinístico como red, y cachear la membresía.

### H7 — [MEDIA] Redis inicializado y sin ningún consumidor; sin rate limiting en el backend

**Evidencia:** `backend/core/redis_client.py` inicializa el cliente en startup; grep sobre routers/services: **cero usos**. El propio warning del módulo ("rate limiting unavailable") delata la intención jamás materializada. KB-08 promete cache de lookups org/rol y rate-limit vía Upstash. El backend en Render free queda sin ninguna protección de rate ante abuso (los endpoints de mutación son idempotentes, pero los GETs de reporting no son gratis).
**Recomendación (P2):** implementar rate limit básico (middleware por user_id) y el cache de membresía (converge con H6), o retirar Redis y su promesa documental.

### H8 — [MEDIA] Dinero degradado a `float` en fronteras de servicio

**Evidencia:** los schemas Pydantic usan `Decimal` correctamente (`backend/schemas/cash.py:49-71`), pero los services lo convierten a `float` antes de la DB: `backend/services/cash.py:52,63,95` (apertura/cierre/movimientos de caja), `backend/services/customer_accounts.py:95` (pagos de cta cte), `backend/services/fiscal/wsfe_adapter.py:475,531-532` y `cae_relay_processor.py:80-88` (montos AFIP). asyncpg convierte float→NUMERIC con el error binario del float. En una app contable con arqueo de caja al centavo (`difference` del cierre) es una fuente de descuadres de $0.01 y de discrepancias con AFIP en totales con IVA.
**Recomendación (P2):** pasar `Decimal` end-to-end (asyncpg lo soporta nativo para NUMERIC); prohibir `float` para dinero por convención (lint).

### H9 — [MEDIA] Higiene de plataforma: drift de dependencias, enforcement de fronteras declarado y ausente, dead code

**Evidencia:**
- `backend/pyproject.toml` declara `python-jose`; `backend/requirements.txt` (el que usa el deploy) declara `PyJWT[crypto]`; el código usa PyJWT (`backend/core/auth.py:3-4`). El pyproject está desactualizado y describe otra librería de crypto JWT.
- `modelo-dominio-aliadata-v2.md` §6 / KB-08: "Enforcement: lint de imports entre módulos + revisión de que ningún módulo lee tablas de otro". No existe import-linter, ruff, ni mypy configurado en el backend (pyproject sin secciones de tooling). La disciplina de fronteras hoy es solo convención (que, para ser justos, el muestreo mostró bien respetada: mapeo service→repository 1:1 limpio).
- Dead code: `PurchaseRepository.create_operation_with_event` (el producer C-25 se movió al RPC SQL en `20260803000002`; el método Python solo lo usan tests), `OutboxRelayService`+endpoint (H3), endpoints de mutación de branches (H5).
**Recomendación (P3):** alinear pyproject↔requirements, agregar ruff+import-linter con las 8 fronteras de módulos V2, y podar el dead code con sus tests.

### H10 — [BAJA] CORS: default `*` con `allow_credentials=True` y reflejo manual de origin en errores

**Evidencia:** `backend/main.py:58-64` — `allow_origins=[settings.backend_allowed_origin]` con default `"*"` (`backend/core/config.py:9`) y `allow_credentials=True`; `backend/core/errors.py:68-81` refleja el origin cuando `allowed == "*"` con `access-control-allow-credentials: true`. La combinación `*`+credentials es inválida para los browsers en el middleware estándar, pero el reflejo manual de `cors_error_headers` sí la hace efectiva para cualquier origin si prod quedara con el default. Si `BACKEND_ALLOWED_ORIGIN` está bien seteado en Render (un solo origin), el riesgo es solo de configuración.
**Recomendación (P3):** fail-fast en startup si `app_env=production` y `backend_allowed_origin == "*"`.

---

## 4. Evaluación de los focos obligatorios

| Foco | Evaluación |
|---|---|
| **Modelo híbrido Next↔FastAPI↔Supabase** | Bien concebido (DEC-12/16, trade-offs explícitos), implementación al ~80%: hot paths ERP migrados; frontera erosionada en branches/stock/reporting (H5); el eslabón de seguridad del passthrough roto (H1). |
| **Separación routers→services→repositories** | **Se respeta de verdad** en el muestreo (7+ slices): routers finos (validación+DI), guards y orquestación en services, SQL solo en repos. Sin lógica de negocio en routers; sin SQL en services. Excepción: lógica de negocio de borrado dentro de repositories (H4). |
| **DEC-24 RPC-as-UoW** | Consistente en creates/updates/cierres (sales, purchases, cash, quotes, fiscal, bank). Violado en deletes (H4). El mapeo P04xx→HTTP centralizado en `core/errors.py` es un complemento excelente del patrón. |
| **Acoplamientos ocultos del híbrido** | Sí existen: H5 (datos por fuera del backend) + H3 (RPCs SECURITY DEFINER llamables desde el browser sin guard) + H6 (tenant activo resuelto distinto en cada lado). |
| **Alineación DDD V2/V3** | Alta a nivel táctico: módulos V2 mapean 1:1 a slices; Shared Kernel respetado; snapshots, FSM-as-data, soft-delete y outbox implementados según V3. El enforcement de fronteras declarado no existe como tooling (H9). |
| **Patrones (outbox, FSM, snapshot, repository, strangler)** | Outbox: implementación in-DB sólida (idempotencia por consumer, SKIP LOCKED, aislamiento por evento) con el residuo divergente H3. FSM: catálogo + historial append-only correctos; `allowed_role` inerte hasta RBAC (K9). Snapshot: en RPCs bajo flag (26/29 cuentas ON). Repository: limpio, con `BaseRepository` que centraliza paginación y soft-delete. Strangler: avanzado, con endpoints muertos sin podar. |
| **Escalabilidad / SPOF** | SPOFs conocidos y aceptados por presupuesto (DEC-14): Render free single-instance (cold start ~50s; mitigado de facto porque el cron CAE golpea el backend cada minuto), Supabase single project, pooler compartido. El outbox y el CAE relay son autónomos del backend (bien). El límite real de escala es H1 (el interleave del pooler empeora con la concurrencia). |
| **Mantenibilidad / extensibilidad** | Muy buena por documentación, specs y tests (~1023 backend + ~443 frontend); los puntos de fricción son la doble vía de datos (H5) y los guards ficticios (H2) que hacen que el comportamiento real difiera del que el código aparenta. |

---

## 5. Verificación de known issues (área arquitectura)

| ID | Estado | Nota |
|---|---|---|
| K1 | CONFIRMADO | `20260804000002_bank_account_ledger.sql` solo crea policies SELECT (`bank_accounts_select` L169, `bank_movements_select` L224); escrituras vía RPC. Nota: para el backend la policy es irrelevante mientras corra como `postgres` BYPASSRLS (H1); aplica a PostgREST. |
| K4 | CONFIRMADO | Prod: 26/29 cuentas con `sale_items_rpc_v2` ON; 3 sin flag (293 sale_items existentes). |
| K5 | CONFIRMADO (abierto) | Sigue sin resolverse. **Hipótesis de causa raíz nueva y consistente**: GUC de sesión sobre pooler transaction-mode → `auth.uid()` NULL intermitente → RPC aborta antes de escribir (ver H1). Reproducible en teoría bajo concurrencia. |
| K7 | CONFIRMADO | Migración `20260809000001_branch_min_stock_realign.sql` presente; `products.min_stock` DEPRECATED sin DROP. |
| K8 | CONFIRMADO | La definición vigente de `rpc_create_purchase_operation` (`20260806000001_v3_snapshot_pattern.sql` L643+) inserta en `operation_idempotency`, `purchases` (header plano), `stock_movements` y `events` — **no escribe `purchase_items`**. RN-97 vigente. |
| K9 | CONFIRMADO | CHECK real binario `('owner','member')` (`20260606010000_roles_internos.sql:27`; el mapeo D3 de `20260808000001` lo reconfirma); `allowed_role` de la FSM inerte (`20260807000001:16,311`). Agravado por H2: el backend ni siquiera lee ese rol. |
| K10 | CONFIRMADO | Backend vía Supavisor verificado en `pg_stat_activity`; transaction mode inferido con 3 evidencias (ver H1). Cold start mitigado de facto por el cron CAE cada minuto. |
| K17 | RESUELTO | `20260804000003_fix_c28_cash_movement_balance.sql` reemplaza `MAX(balance_after)` por `opening + SUM(amount)` en `c28_register_cash_movement`; el arqueo al cierre nunca dependió de balance_after. Sin backfill por decisión PO (documentado). |
| K18 | CONFIRMADO | `20260804000006_fix_audit_logs_notnull.sql` presente; `OutboxRepository.insert_audit_log` (L88-95) sigue sin proveer `company_id`/`entity_type`. |
| K19 | CONFIRMADO | Ambos proyectos documentados en CLAUDE.md; el riesgo de drift persiste (solo se auditó prod). |
| K2, K3, K6, K11, K12, K13, K14, K15, K16, K20 | NO_EVALUADO | Fuera del foco de esta dimensión o requieren verificación que excede el alcance (CI gates, datos legacy, validación openspec global, enums UoM, FSM huecos finos, pendientes externos PO). |

---

## 6. Inconsistencias documentación ↔ código (consolidado)

1. `openspec/specs/asyncpg-pool/spec.md` exige `SET LOCAL` (transaccional); `core/database.py` usa `set_config(..., false)` (sesión). La spec describe el diseño correcto; el código el incorrecto.
2. DEC-13 / KB-08: "la RLS org-based sigue activa como red de seguridad" — falso en prod: el backend corre como `postgres` con `rolbypassrls=true` (verificado).
3. KB-08 "tres capas de autorización" — capa 1 no resuelve rol/plan reales (JWT sin claims), capa 2 degenerada (H2), capa 3 apagada para el backend (H1).
4. DEC-07 "stock_movements solo-inserción, ningún movimiento puede borrarse" vs `DELETE FROM stock_movements` en `sales_repository.py:119-122,164-167` y `purchase_repository.py:122-125,169-172`.
5. DEC-24 "los services nunca abren ni comitean transacciones" vs transacciones explícitas multi-paso en los repositories de deletes.
6. Modelo V2 §6 "enforcement: lint de imports entre módulos" — no existe ningún tooling de lint en el backend.
7. `OutboxRelayService`/`outbox.py` docstrings afirman "Called by the pg_cron job relay-process-outbox" — falso desde el pivot in-DB (el cron llama a `rpc_process_outbox_dispatch`); el endpoint quedó como trigger manual no actualizado (2 de 4 consumers).
8. KB-08 §Estructura de directorios: describe el layout pre-monorepo (raíz en vez de `frontend/`, 10 Edge Functions, DataContext) — desactualizado frente al árbol real.
9. `pyproject.toml` (python-jose) vs `requirements.txt`/código (PyJWT).
10. KB-08 promete cache Redis de org/rol y rate limiting — no implementados (H7).

---

## 7. Fortalezas (con la misma seriedad que los defectos)

1. **Layering 3 capas real y disciplinado**: en 7+ slices muestreados, cero lógica de negocio en routers, cero SQL en services, mapeo service→repository 1:1 limpio. El comentario de cabecera de `services/cash.py` ("Architecture rule (hard): NO business logic in routers") se cumple.
2. **DEC-24 RPC-as-UoW aplicado con consistencia** en los hot paths de creación/edición/cierre, con errores de negocio como SQLSTATE P04xx mapeados centralizadamente a HTTP en `core/errors.py` y envueltos en RFC 7807 — un contrato de errores uniforme de punta a punta (incluye 422 de Pydantic y catch-all sin leak de internals).
3. **Puerto/adaptador hexagonal para AFIP de libro**: `FiscalDocumentPort` (ABC + dataclasses de dominio), `WSFEAdapter` real y `WSFEStubAdapter` inyectables por DI; el SOAP jamás cruza el ACL. El relay de CAE es fail-closed (RELAY_SECRET desde vault, lease anti-doble-CAE, backstop pg_cron).
4. **Outbox transaccional in-DB robusto**: producers en la misma transacción del RPC, idempotencia por `(event_id, consumer_type)`, `FOR UPDATE SKIP LOCKED`, aislamiento por evento (un evento corrupto no aborta el batch), y autonomía total de Render — el hot loop no depende del backend. `events_pending=0` en prod.
5. **Frontend middleware ejemplar**: `getUser()` (nunca `getSession()` para auth), security headers completos + CSP, idle enforcement server-side con loop-safety razonado, admin gate contra DB.
6. **`BaseRepository` como plataforma**: paginación estándar `{items,total,page,pages}` centralizada, soft-delete con allowlist cerrada anti-inyección de identificadores, invariante de JWT-passthrough documentada en el docstring.
7. **Documentación y trazabilidad excepcionales**: KB de 10 archivos, modelos de dominio V2/V3 con auditoría del código real, 24 decisiones con trade-offs y reversiones explícitas, CHANGES.md con árbol de dependencias, 62 specs; las migraciones SQL llevan governance, rationale, rollback y hasta decisiones de PO fechadas. Este nivel de memoria institucional es raro y es un activo arquitectónico en sí mismo.
8. **Strangler fig avanzado y honesto**: los dominios de dinero (ventas, compras, caja, bancos, cta cte, fiscal) ya viven detrás del backend; los residuos están identificados en este informe.
9. **Migraciones idempotentes y CI con gates de comportamiento** sobre Postgres real (204 migraciones, patrón aprendido y documentado tras el incidente de auto-apply de la integración GitHub).

---

## 8. Deuda técnica (registro)

- Endpoints FastAPI muertos: mutaciones de `branches`, `POST /outbox/process-pending` (+`OutboxRelayService` desactualizado) — podar o cablear.
- `PurchaseRepository.create_operation_with_event`: dead code (producer vive en SQL desde `20260803000002`).
- Redis inicializado sin consumidores; rate limiting inexistente.
- `pyproject.toml` desalineado con `requirements.txt`; sin ruff/mypy/import-linter (el enforcement de fronteras V2 declarado).
- `purchase_items` no escritos por el RPC vigente (K8 — C-20 Grupo 10 diferido, RN-97).
- 3/29 cuentas sin `sale_items_rpc_v2` → ventas sin snapshots de línea (decisión PO pendiente).
- `products.min_stock` DEPRECATED sin DROP (K7).
- Cookie de tenant activo sin contrato backend (H6).
- KB-08 §estructura de directorios desactualizada.
- `ws_manager` scaffoldeado sin uso — aceptable (documentado como reserva en DEC-16), mantener la nota.

---

## 9. Justificación de la clasificación: **Mejorable**

No es "Buena" porque el hallazgo H1 toca el corazón del modelo arquitectónico elegido (JWT-passthrough + RLS como red) y está acompañado de una capa de autorización intermedia ficticia (H2) y de un residuo de outbox que permite a cualquier usuario autenticado alterar el pipeline contable (H3) — tres defectos en el núcleo de seguridad/consistencia del sistema en producción con usuarios reales. No es "Crítica" porque la exposición práctica hoy es baja (29 cuentas, baja concurrencia, 0 usuarios multi-cuenta, outbox al día), los patrones de base son sólidos y correctamente implementados en su mayoría, la tenancy manual (`WHERE account_id`) del backend es consistente en el muestreo, y el equipo demuestra capacidad sistemática de retirar deuda (30/30 changes + V2.5 + V3 parcial). Con H1-H4 resueltos, esta arquitectura sería "Muy buena".
