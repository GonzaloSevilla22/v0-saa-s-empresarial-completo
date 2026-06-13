# Tasks — v21-fiscal-profile (C-27)

> Governance CRÍTICO (facturación real): **no escribir ni aplicar nada hasta que el PO mergee proposal + design** (PR #168). OQ-1..OQ-4 **ya resueltas (PO 2026-06-12)** — ver design.md §Resolved Decisions: OQ-1 = Opción A (relay + `pg_cron`), OQ-2 = **multi-PV** (`points_of_sale` + `document_sequences` re-clavado por `point_of_sale_id`), OQ-3 = solo maquinaria + endpoint directo, OQ-4 = reusar `isValidCuit` de C-22. PA-22 (homologación + ambiente por cuenta) y DEC-22 (CAE asíncrono) ya estaban decididas.
> Migraciones SQL: SIEMPRE `npx supabase db push` (CLI). NUNCA el MCP `apply_migration`. Proyecto prod: `gxdhpxvdjjkmxhdkkwyb`.
> ERRCODEs: SIEMPRE 5 caracteres (`P0400`/`P0401`/`P0403`/`P0404`/`P0409`/`P0422`) + label descriptivo en el mensaje del RAISE (patrón C-26). PV ambiguo en emisión = **`P0422 ambiguous_point_of_sale`**.
> Backend: JWT-passthrough, NUNCA `service_role` (DEC-13) — única excepción: lectura del certificado AFIP server-side para firmar WSAA.
> Gotcha del proyecto: NUNCA upsert acumulativo `INSERT VALUES(delta) ON CONFLICT DO UPDATE` sobre tablas con CHECK — usar UPDATE-then-INSERT en `rpc_next_document_number`.
> TDD estricto: cada comportamiento test-first. Backend: pytest (baseline 124 antes de tocar). El adaptador WSFE real NO se testea en el gate de CI (homologación intermitente) — la lógica se prueba con el stub.

## 0. Pre-flight y decisiones del PO

- [x] 0.1 PO resuelve OQ-1..OQ-4 (2026-06-12). **OQ-1 = Opción A** (relay idempotente + `pg_cron`, adaptador WSFE único en Python). **OQ-2 = MODIFICADA: multi-PV** — nueva tabla `points_of_sale`, `fiscal_profiles` pierde `punto_de_venta`, `document_sequences` re-clavado por `point_of_sale_id`, emisión con PV opcional (`P0422 ambiguous_point_of_sale` si hay varios), CRUD de PVs en UI. **OQ-3 = solo maquinaria + endpoint directo** (wiring a C-29). **OQ-4 = reusar `isValidCuit` (módulo-11) de C-22**. Registrado en design.md §Resolved Decisions.
- [ ] 0.2 Baseline de tests del backend (`pytest`): registrar "N passing" (al proponer: 124).
- [ ] 0.3 Snapshot read-only en prod: cuentas con perfil fiscal (esperado 0 — tabla no existe), bucket `afip-certs` (no existe), `pg_cron` jobs existentes (`reset-ai-counters` como patrón de referencia).
- [ ] 0.4 Confirmar disponibilidad del SDK/cliente WSAA+WSFEv1 para Python (o decidir cliente SOAP, p. ej. `zeep`) y registrar la dependencia del adaptador real.

## 1. Migración SQL (única, no destructiva)

- [ ] 1.1 `CREATE TABLE fiscal_profiles` (`account_id` UNIQUE FK, `cuit` NOT NULL, CHECK de `iva_condition` y `ambiente`, `certificado_afip_path`, `iibb_condition` — **sin `punto_de_venta`**, OQ-2) + RLS (SELECT miembro, INSERT/UPDATE `is_account_writer` en WITH CHECK) + índice en `account_id`.
- [ ] 1.2 `CREATE TABLE points_of_sale` (`id` UUID PK, `fiscal_profile_id` FK NOT NULL → `fiscal_profiles`, `account_id` FK NOT NULL → `accounts` (desnormalizado para RLS), `branch_id` FK NULL → `branches`, `numero` INTEGER NOT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `created_at`) + UNIQUE `(fiscal_profile_id, numero)` + RLS por `account_id` (SELECT miembro; INSERT/UPDATE `is_account_writer` en WITH CHECK) + índice en `account_id`.
- [ ] 1.3 `CREATE TABLE document_sequences` (`id` UUID PK, `point_of_sale_id` FK NOT NULL → `points_of_sale`, `comprobante_type`, `last_number` BIGINT DEFAULT 0, `created_at`, UNIQUE `(point_of_sale_id, comprobante_type)`) + RLS (SELECT miembro vía join/columna; escritura solo vía RPC definer).
- [ ] 1.4 `CREATE TABLE fiscal_documents` (campos del spec: `status` CHECK `pending_cae|authorized|rejected`, `cae`, `cae_due_date`, `attempts`, `next_attempt_at`, `last_error`) + RLS por `account_id` + índice parcial `WHERE status='pending_cae'` (cola del relay).
- [ ] 1.5 Gate de concurrencia RED→GREEN: test SQL que llama `rpc_next_document_number` en 100 transacciones concurrentes sobre el MISMO `(point_of_sale_id, comprobante_type)` → assertion de números 1..100 sin huecos ni repetidos.
- [ ] 1.6 `rpc_next_document_number(p_point_of_sale_id, p_comprobante_type)` (SECURITY DEFINER, guard `is_account_writer` sobre el `account_id` del PV, `SELECT … FOR UPDATE`, UPDATE-then-INSERT — NO upsert acumulativo).
- [ ] 1.7 Función/RPC de emisión `pending_cae`: resuelve el PV efectivo (`point_of_sale_id` opcional — único PV activo → ese; varios y sin especificar → **`P0422 ambiguous_point_of_sale`**; PV ajeno/inactivo → `P0404`/`P0422`); reserva número vía 1.6 + INSERT en `fiscal_documents` con `status='pending_cae'`, en transacción corta sin tocar AFIP.
- [ ] 1.8 Bucket privado `afip-certs` + Storage policies INSERT/SELECT/UPDATE scoped por `account_id`.
- [ ] 1.9 `pg_cron` del relay del CAE (OQ-1 = A): job que dispara el procesamiento de `pending_cae` (endpoint backend o Edge Function relay) cada minuto.
- [ ] 1.10 `npx supabase db push`; `supabase db advisors` = 0 ERRORs.

## 2. Backend Python — adaptador WSFE y dominio fiscal (TDD)

- [ ] 2.1 Tests RED: `resolve_invoice_type` (RI→RI=A, RI→CF=B, monotributo=C) como función pura.
- [ ] 2.2 GREEN: `services/fiscal/invoice_type_resolver.py`.
- [ ] 2.3 Tests RED: `WSFEStubAdapter.request_cae` devuelve `CAEResponse` ficticio determinístico; el port `FiscalDocumentPort` define la interfaz; el service solo referencia tipos de dominio (no SOAP).
- [ ] 2.4 GREEN: port `FiscalDocumentPort` + `WSFEStubAdapter` + tipos `CAERequest`/`CAEResponse`/`DocumentType` + `CAE`/`CAEDueDate`.
- [ ] 2.5 `WSFEAdapter` real (WSAA ticket de acceso + WSFEv1, resuelve ambiente desde el perfil; lee el cert del bucket privado server-side). Tests con el cliente SOAP mockeado (sin red); test de integración real contra homologación marcado/excluido del gate de CI.
- [ ] 2.6 Tests RED: proceso de background idempotente — `pending_cae`+CAE válido→`authorized`; error transitorio→`attempts++` + `next_attempt_at` backoff; rechazo→`rejected`+`last_error`; reproceso de `authorized`→sin cambio.
- [ ] 2.7 GREEN: el relay/endpoint de procesamiento del CAE (Opción A) con backoff e idempotencia (reusa patrón `operation_idempotency`).

## 3. Backend Python — API del perfil fiscal (TDD)

- [ ] 3.1 Tests RED: `FiscalProfileRepository.get`/`upsert`; schemas validan `iva_condition` y `ambiente` (Literal); `FiscalProfileOut` no expone el contenido del cert; member no puede escribir el perfil (403).
- [ ] 3.2 GREEN: `fiscal_profile_repository.py`, schemas Pydantic v2 (`FiscalProfileCreate/Update/Out`).
- [ ] 3.3 Tests RED: `PointOfSaleRepository.list`/`create`/`deactivate`; `PointOfSaleCreate/Out` (Pydantic v2); `UNIQUE(fiscal_profile_id, numero)` rechaza duplicado (409); member no puede crear/desactivar PV (403); listar solo PVs de la cuenta.
- [ ] 3.4 GREEN: `point_of_sale_repository.py` + schemas; endpoints `GET /fiscal/points-of-sale`, `POST /fiscal/points-of-sale`, `PATCH /fiscal/points-of-sale/{id}` (desactivar) — router → service `require_role` → repo, sin lógica en el router.
- [ ] 3.5 Endpoints `GET /fiscal/profile`, `POST/PUT /fiscal/profile` (router → service `require_role` → repo) + endpoint de emisión directa `pending_cae` con `point_of_sale_id` opcional (alcance OQ-3; `P0422 ambiguous_point_of_sale` si hay varios PVs activos y no se especifica) + endpoint de procesamiento de pendientes.
- [ ] 3.6 Suite completa verde: baseline 124 + nuevos.

## 4. Frontend

- [ ] 4.1 `use-fiscal-profile`: select + upsert del perfil; reusa `isValidCuit` (módulo-11) de C-22 para validar el CUIT del emisor.
- [ ] 4.1b `use-points-of-sale`: list + create + deactivate de PVs (TanStack Query; invalida al mutar).
- [ ] 4.2 Página `/configuracion/fiscal`: formulario del perfil (CUIT, condición IVA, IIBB, ambiente) + **CRUD mínimo de puntos de venta** (listar / agregar con `numero` + `branch_id` opcional / desactivar, sin límite de cantidad — OQ-2) + upload del certificado al bucket privado (signed upload).
- [ ] 4.3 Estados de `FiscalDocument` en UI (badge `En trámite`/`Autorizado`/`Rechazado`); suscripción Realtime al cambio `pending_cae → authorized` (patrón tabla→Realtime, DEC-16) — alcance mínimo si OQ-3 deja la emisión como endpoint directo.
- [ ] 4.4 Errores nuevos traducidos en `translateRpcError`; `database.types.ts` regenerado; `tsc --noEmit` limpio; tests frontend verdes (`npm test`, no `npx jest`).

## 5. Verificación y cierre

- [ ] 5.1 Smoke transaccional en prod (rollback): crear perfil fiscal; **crear 2 PVs** (`UNIQUE(fiscal_profile_id, numero)`); reservar número por PV (concurrencia → sin huecos, secuencias independientes por PV); emitir `pending_cae` con 1 PV (auto) y con 2 PVs sin especificar → **`P0422 ambiguous_point_of_sale`**; relay con stub → `authorized` + CAE ficticio; member no puede escribir perfil/PV (P0401); cert no accesible público.
- [ ] 5.2 Verificación end-to-end en homologación de ARCA (manual/marcada): WSAA ticket de acceso → WSFEv1 CAE → numeración sin huecos → manejo de error. NO bloquea el merge (homologación intermitente).
- [ ] 5.3 PR a main; checks verdes; **el PO revisa y mergea** (governance CRÍTICO — no auto-merge); deploy Render/Vercel.
- [ ] 5.4 `/opsx:archive v21-fiscal-profile` → sync specs (`fiscal-profile`, `document-sequence`, `afip-fiscal-document`).
- [ ] 5.5 CHANGES.md C-27 `[x]`; CLAUDE.md próximo recomendado (C-28 cash-session o C-29 quote-salesorder).
