# Design — v21-fiscal-profile (C-27)

## Context

Post-C-22 los clientes tienen identidad fiscal (`tax_id`, `iva_condition`, `legal_name`) y post-C-26 `Branch` es Aggregate Root con un punto de venta vinculable. Falta el **emisor**: la organización no declara su CUIT/condición IVA/punto de venta, no hay numeración de comprobantes y no existe canal hacia AFIP/ARCA.

Estado actual relevante:
- `accounts` es la tabla de organización (tenancy única post-C-19, `account_id`); RLS vía `current_account_ids()` / `is_account_writer(account_id)`.
- `branches` (C-26): `status ('active'|'closed')`, lifecycle open/close. `PointOfSale` AFIP se modela en `points_of_sale` (D10) con `branch_id` opcional en V2.1 (se vincula a la branch cuando el POS emita, C-29; modelo §3.6 / §5.1) — la numeración fiscal es **por punto de venta**.
- Convención de errores: ERRCODEs de 5 chars `P04xx` (`P0400/P0401/P0403/P0404/P0409/P0422`), `backend/core/errors.py` los mapea a HTTP.
- Escrituras de stock vía RPC SECURITY DEFINER con guard `is_account_writer`; el backend Python invoca RPCs vía repositories (JWT-passthrough, NUNCA `service_role` — DEC-13).
- Gotcha SQL del proyecto (encontrado en C-26): NUNCA upsert acumulativo `INSERT VALUES(delta) ON CONFLICT DO UPDATE` sobre tablas con CHECK — Postgres valida la fila propuesta del INSERT antes de resolver el conflicto. Para `DocumentSequence` usar **UPDATE-then-INSERT** o `SELECT FOR UPDATE` + UPDATE.
- IA/OCR siguen en Edge Functions; **los workers Python ARQ están pospuestos (DEC-15)** → el CAE asíncrono NO puede asumir un worker always-on; el mecanismo de background debe elegirse y justificarse (D6).

**Restricciones ya decididas (no se re-preguntan):**
- **PA-22 (resuelta 2026-06-12)**: adaptador real contra **homologación de ARCA**; `ambiente` config por cuenta; cutover a producción por cuenta = subir cert real + alta de PV WSFE, sin re-trabajo de código; trámites de producción son del usuario emisor, corren en paralelo, NO bloquean C-27.
- **DEC-22**: CAE asíncrono (`pending_cae` con reintento) para no atar el hot path al uptime de AFIP. Governance CRÍTICO.

**Stakeholders**: C-29 (`v21-quote-salesorder`) consume `DocumentSequence` y la emisión de `FiscalDocument` en `quickSale()`. Governance CRÍTICO: el PO revisa proposal + design y resuelve las OQs antes del apply.

## Goals / Non-Goals

**Goals**
1. `FiscalProfile` por cuenta (1:1 con `accounts`): CUIT, condición IVA, IIBB, certificado AFIP en Storage privado, `ambiente` por cuenta. **Multi-PV (OQ-2):** los puntos de venta viven en la tabla `points_of_sale` (1:N desde el perfil), con CRUD mínimo en la UI.
2. `DocumentSequence` con numeración sin huecos por `(point_of_sale_id, comprobante_type)`, lock corto, fuera de la transacción larga de la venta.
3. Adaptador WSFE detrás de un ACL: port `FiscalDocumentPort` con impl real (homologación) y stub (tests), inyectable por DI.
4. Emisión de `FiscalDocument` con CAE asíncrono: persistir `pending_cae` síncrono → obtener CAE en background con reintento por backoff → `authorized`/`rejected`.
5. UI `/configuracion/fiscal` con upload de certificado a bucket privado.
6. Backend (3 capas) y migraciones con RLS por `account_id`; TDD (pytest) con los tests clave del scope.

**Non-Goals**
- **Producción real de AFIP** (PA-22): el cutover por cuenta es operación del usuario emisor (cert real + alta PV), no código de C-27. C-27 valida en homologación.
- **`quickSale()` / emisión desde la venta**: C-29. C-27 entrega la maquinaria (perfil + secuencia + adaptador + emisión `pending_cae`); el wiring desde el flujo de venta es del siguiente change. La emisión en C-27 se prueba vía un comando/endpoint directo y el stub.
- **Notas de crédito / débito, percepciones/retenciones, multi-jurisdicción IIBB completo**: V2.5 (modelo §3.5). C-27 cubre el comprobante base (factura/ticket A/B/C).
- **Migrar el OCR de facturas de compra ni IA a Python** (DEC-15).
- **WebSocket Python para el server-push del CAE** (DEC-16): el `pending_cae → authorized` se emite vía tabla→Realtime de Supabase.
- **`JournalEntry` / asiento contable de la factura**: V2.5, vía outbox.

## Decisions

### D1 — `FiscalProfile` como tabla 1:1 con `accounts` (no columnas en `accounts`)
Tabla `fiscal_profiles` con `account_id` UNIQUE FK en vez de agregar columnas a `accounts`. Razón: el perfil fiscal es un cluster cohesivo (CUIT + condición + IIBB + cert + ambiente) que se edita junto en un solo trámite y conviene aislar para RLS/auditoría/versionado; mantiene `accounts` delgada. El modelo lo nombra "entidad dentro del agregado Organization" (§5.1) — 1:1 lo respeta sin polimorfismo. Alternativa rechazada: columnas en `accounts` — mezcla el ciclo de vida fiscal con el de billing/tenancy y ensucia la tabla más caliente.
**Nota (PO 2026-06-12, OQ-2):** el `punto_de_venta` singular **deja de vivir en `fiscal_profiles`** y se muda a la tabla `points_of_sale` (multi-PV, D10). El perfil sigue siendo 1:1 con la cuenta; lo que ahora es 1:N es la relación perfil → puntos de venta.

### D2 — `ambiente` por cuenta en `FiscalProfile`, no global ni por env var (PA-22)
`fiscal_profiles.ambiente TEXT NOT NULL DEFAULT 'homologacion' CHECK (ambiente IN ('homologacion','produccion'))`. El adaptador WSFE resuelve la URL del web service y el certificado a usar **a partir del perfil de la cuenta**, no de una variable de entorno del backend. Razón (PA-22): el cutover a producción es por cuenta sin re-deploy; cuentas piloto pueden ir a producción mientras el resto sigue en homologación. Alternativa rechazada: ambiente global por env var — obligaría a un deploy/flag por cada cuenta que migra y mezcla cuentas en distinto estado de homologación.

### D3 — `DocumentSequence` re-clavado por punto de venta + lock corto fuera de la transacción de venta (numeración sin huecos)
**(Actualizado OQ-2, PO 2026-06-12 — multi-PV.)** La numeración AFIP es **por punto de venta y tipo de comprobante**, no por perfil. `document_sequences` se re-clava a `(point_of_sale_id, comprobante_type, last_number)`, `UNIQUE(point_of_sale_id, comprobante_type)`; `point_of_sale_id` FK NOT NULL → `points_of_sale` (D10). RPC `rpc_next_document_number(p_point_of_sale_id, p_comprobante_type) → bigint`: `SELECT … FOR UPDATE` sobre la fila de `document_sequences`, incrementa `last_number`, devuelve el nuevo. Si la fila no existe, **UPDATE-then-INSERT** (no upsert acumulativo — gotcha del proyecto). El lock se toma y suelta en esta RPC; la transacción de la venta (cuando exista, C-29) llama esta RPC como sub-operación corta, no mantiene el lock mientras hace el resto del trabajo. Razón: AFIP exige secuencia sin huecos por PV — es un cuello de botella serializado por diseño (modelo §2.7, §5.9), aislarlo en un agregado pequeño con lock corto evita contención del POS; clavarlo por `point_of_sale_id` (en vez de `(fiscal_profile_id, punto_de_venta)`) hace de la FK al PV el clave natural y evita columnas redundantes. Alternativa rechazada: secuencia Postgres (`SEQUENCE`) — las sequences pueden saltar números en rollback (huecos), inaceptable para AFIP. Alternativa rechazada: mantener `(fiscal_profile_id, punto_de_venta, comprobante_type)` con `punto_de_venta` como INTEGER suelto — con la tabla `points_of_sale` ya existente, duplicaría el número de PV en dos lugares y abriría la posibilidad de secuencias para PVs no registrados.

### D4 — Adaptador WSFE como port/adapter detrás de un ACL
Interfaz en el dominio: `FiscalDocumentPort.request_cae(invoice_data: CAERequest) -> CAEResponse`. Dos implementaciones inyectables por `Depends`: `WSFEAdapter` (real, habla WSAA para el ticket de acceso + WSFEv1 para el CAE) y `WSFEStubAdapter` (devuelve un CAE ficticio determinístico para tests/dev). El dominio y los services conocen solo `CAE`, `CAEDueDate`, `DocumentType`, códigos de error normalizados — nunca el SOAP/XML de AFIP, que vive encapsulado en el adapter. Razón: aísla la dependencia externa frágil, permite testear toda la lógica de emisión sin tocar AFIP, y deja la puerta a otros países sin contaminar Sales (modelo §3.6). Alternativa rechazada: llamar al SOAP de AFIP desde el service — acopla la lógica de negocio al transporte y vuelve imposible el testing offline.

### D5 — CAE asíncrono con máquina de estados `pending_cae → authorized | rejected` (DEC-22)
`fiscal_documents.status TEXT CHECK (status IN ('pending_cae','authorized','rejected'))`. La emisión **síncrona** reserva el número (`rpc_next_document_number`) y persiste el comprobante con `status='pending_cae'` (sin tocar AFIP, transacción corta). El CAE se obtiene **fuera** de esa transacción vía el adaptador; al éxito → `authorized` + `cae` + `cae_due_date`; al rechazo definitivo → `rejected` + `error_code`/`error_detail`. Razón (DEC-22, modelo §8): AFIP puede estar caído o lento; atar la venta a su uptime rompe el POS. Alternativa rechazada: pedir el CAE síncrono dentro de la venta — un timeout de AFIP voltea la venta.

### D6 — Mecanismo de background del CAE: **cola en tabla + relay disparado por endpoint/`pg_cron`**, NO worker always-on (DEC-15) — sujeto a OQ-1
Los workers Python ARQ están pospuestos (DEC-15) y Render free no corre procesos always-on bien. Opciones evaluadas:
- **(A) Endpoint de procesamiento idempotente "retry-on-demand"**: `POST /fiscal/documents/process-pending` que toma N `pending_cae`, pide CAE vía adapter, actualiza estado; reintento por backoff usando `next_attempt_at`/`attempts` en la fila. Se dispara desde el frontend al emitir (fire-and-forget) y/o desde un **`pg_cron` gratis** (Supabase) que pinguea el endpoint o llama una Edge Function relay cada minuto. Cero infra nueva, reusa el patrón de cron ya presente (`reset-ai-counters`, PA-05). El estado de reintento vive en `fiscal_documents` (`attempts`, `next_attempt_at`, `last_error`).
- **(B) Edge Function `request-cae`** disparada por `pg_cron` o por DB Webhook on-insert de `pending_cae`: mueve la llamada a AFIP a Deno. Contra: duplica el adaptador WSFE en TypeScript/Deno (el real vive en Python) — viola "una sola implementación del ACL".
- **(C) Worker ARQ Python**: descartado por DEC-15 (sin presupuesto Render paid).

**Recomendación: (A)** — cola materializada en `fiscal_documents` + relay idempotente disparado por `pg_cron`, con backoff (`next_attempt_at = now() + interval based on attempts`). El adaptador WSFE queda **único** en Python. La idempotencia del relay reusa el patrón de `operation_idempotency`. **OQ-1 para el PO.**

### D7 — Certificado AFIP en bucket Storage **privado**, leído solo server-side
Bucket privado `afip-certs`; policies de Storage INSERT + SELECT + UPDATE scoped por `account_id` (el upsert de Storage requiere las tres — regla de la skill supabase). El `.crt`/`.key` se sube desde la UI (signed upload) y se lee **solo** desde el backend/Edge para firmar el WSAA; nunca se expone al cliente ni se sirve público. `fiscal_profiles.certificado_afip_path` guarda solo la ruta, no el contenido. Razón: el certificado es material criptográfico sensible (firma comprobantes fiscales). Alternativa rechazada: bucket público o cert en columna de DB — fuga de credenciales fiscales.

### D8 — Resolvedor de tipo de comprobante (A/B/C) como Domain Service puro
`resolve_invoice_type(emisor: FiscalProfile, receptor: ClientFiscalIdentity) -> DocumentType` — función pura, testeable, sin I/O: RI emisor + RI receptor → A; RI emisor + CF/monotributo receptor → B; monotributo emisor → C. Razón: la lógica fiscal vive en el dominio (modelo §3.6), no en el adapter ni en el router; es el corazón testeable de Fiscal (AR). Alternativa rechazada: hardcodear el tipo en la UI — la regla fiscal se duplicaría y divergiría.

### D9 — RLS por `account_id` en las cuatro tablas nuevas; escritura del perfil/PV solo owner/admin
`fiscal_profiles`, `points_of_sale`, `document_sequences`, `fiscal_documents` con RLS `TO authenticated` + predicado de ownership por `account_id` (`account_id = ANY(current_account_ids())` en USING; `is_account_writer(account_id)` en WITH CHECK para UPDATE/INSERT). `document_sequences` no se escribe directo desde el cliente — solo vía `rpc_next_document_number` (SECURITY DEFINER con guard). Razón: regla dura del proyecto (RLS por `account_id` en toda tabla nueva; UPDATE policies con USING y WITH CHECK; nada de SECURITY DEFINER para tapar permisos). El backend usa JWT-passthrough (NUNCA `service_role`, DEC-13) salvo la lectura del certificado para firmar WSAA, que es la excepción de job administrativo aislado.

### D10 — `points_of_sale` como entidad hija del `FiscalProfile`, con `account_id` desnormalizado para RLS (OQ-2 multi-PV, PO 2026-06-12)
Tabla `points_of_sale` (`id` UUID PK, `fiscal_profile_id` UUID FK NOT NULL → `fiscal_profiles`, `account_id` UUID FK NOT NULL → `accounts` (desnormalizado), `branch_id` UUID FK NULL → `branches`, `numero` INTEGER NOT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `created_at` TIMESTAMPTZ), `UNIQUE(fiscal_profile_id, numero)`. Una cuenta puede registrar **2 o más puntos de venta** desde C-27, sin límite artificial.
- **`account_id` desnormalizado (no join a `fiscal_profiles` para RLS)**: replica el patrón de C-26 (`stock_transfers`, `branch_stock`) y de las otras tablas de este change (`fiscal_documents` ya lleva `account_id` directo). Razón: la regla dura del proyecto es "RLS por `account_id` en toda tabla nueva" con índices que **empiezan por `account_id`** (modelo §5.9); un predicado RLS por columna directa (`account_id = ANY(current_account_ids())`) es más barato y menos frágil que un subquery/join a `fiscal_profiles` en cada chequeo. La consistencia `account_id == fiscal_profiles.account_id` se garantiza en el INSERT (el `fiscal_profile_id` y el `account_id` provienen del mismo contexto de cuenta del request, y `fiscal_profiles.account_id` es UNIQUE). Alternativa rechazada: RLS vía join a `fiscal_profiles` — más costosa por fila y depende de un segundo predicado para aislar.
- **`branch_id` NULL en V2.1**: el vínculo PV↔Branch es opcional ahora; el modelo (§3.6/§5.1) ata `PointOfSale` a `Branch`, pero el consumidor que emite por branch es C-29 (`quickSale`). Se endurece a NOT NULL cuando el POS emita (C-29), sin migrar datos (aditivo). Alternativa rechazada: NOT NULL ya — fuerza a cada cuenta a declarar branch del PV sin consumidor que lo use, agregando fricción al CRUD.
- **`numero`** = el nro de PV ante AFIP (el que se da de alta en WSFE). `UNIQUE(fiscal_profile_id, numero)` impide dos PVs con el mismo número en la misma cuenta.

### D11 — Selección de punto de venta en la emisión; PV ambiguo → `P0422 ambiguous_point_of_sale` (OQ-2)
El endpoint/flujo de emisión recibe `point_of_sale_id` **opcional**. Resolución del PV efectivo:
- Si la cuenta tiene **un solo** PV activo → se usa ese (no hace falta especificar).
- Si tiene **varios** PVs activos y no se especifica `point_of_sale_id` → error **`P0422 ambiguous_point_of_sale`** (HTTP 422; ERRCODE genérico de 5 chars del proyecto + label descriptivo en el mensaje del RAISE, patrón de C-26 — `backend/core/errors.py` mapea `P0422 → 422`, no colisiona con los existentes).
- Si se especifica un `point_of_sale_id` que no pertenece a la cuenta o está inactivo → `P0404`/`P0422` según corresponda.
Razón: con multi-PV la numeración depende del PV elegido (D3); no adivinarlo evita emitir contra la secuencia equivocada (números AFIP irrecuperables). Alternativa rechazada: elegir "el primero" silenciosamente — riesgo de numerar en el PV equivocado sin que el operador lo note.

## Risks / Trade-offs

- [El upsert de `document_sequences` viola un futuro CHECK como pasó en C-26 con `branch_stock`] → Mitigación: usar UPDATE-then-INSERT desde el día uno (D3); test de concurrencia (100 calls → sin huecos) en el plan de tests; smoke transaccional en prod.
- [El relay (A) no corre / se atrasa y comprobantes quedan `pending_cae` indefinidamente] → Mitigación: `pg_cron` cada minuto + disparo fire-and-forget al emitir + alerta si `pending_cae` con `attempts > N` (insight de IA por outbox, fuera de scope de C-27 pero el campo queda). El comprobante `pending_cae` es legalmente "en trámite", no perdido.
- [AFIP de homologación intermitente hace flakear los tests] → Mitigación: los tests de lógica usan el **stub** (D4); solo un test de integración opcional (marcado, no en el gate de CI) pega a homologación real.
- [La firma WSAA requiere el `service_role` para leer el cert, abriendo una brecha si se filtra] → Mitigación: la lectura del cert es la única excepción de `service_role`, aislada en el adapter server-side; el cert vive en bucket privado con RLS; el path se valida contra `account_id` del request antes de leer.
- [Numeración por PV vs. PV vinculado a Branch (C-26) — dónde vive el punto de venta] → **Resuelto (OQ-2, PO 2026-06-12): multi-PV** en tabla `points_of_sale` con `branch_id` NULL (opcional en V2.1, se endurece en C-29). `document_sequences` re-clavado por `point_of_sale_id`. Ver Resolved Decisions + D10/D11.
- [`account_id` desnormalizado en `points_of_sale` se desincroniza de `fiscal_profiles.account_id`] → Mitigación: se setea en el INSERT desde el mismo contexto de cuenta del request; `fiscal_profiles.account_id` es UNIQUE; opcional CHECK/trigger de consistencia si se quiere blindar (no requerido — el INSERT pasa por el repo con el `account_id` ya resuelto).
- [Governance CRÍTICO: facturación real] → Mitigación: el PO revisa y mergea propose; las OQs se resuelven antes del apply; ningún corte a producción real de AFIP sin aprobación humana explícita (PA-22 ya delimita: producción es trámite del usuario, no del code).

## Migration Plan

1. **Migración A (única, no destructiva)**: `CREATE TABLE fiscal_profiles` (+ RLS, UNIQUE `account_id`, CHECKs de `iva_condition`/`ambiente`; **sin** columna `punto_de_venta` — OQ-2) → `CREATE TABLE points_of_sale` (+ RLS por `account_id`, `fiscal_profile_id` FK NOT NULL, `branch_id` FK NULL, `numero`, `is_active`, UNIQUE `(fiscal_profile_id, numero)`) → `CREATE TABLE document_sequences` (+ RLS, `point_of_sale_id` FK NOT NULL, UNIQUE `(point_of_sale_id, comprobante_type)`) → `CREATE TABLE fiscal_documents` (+ RLS, CHECK de `status`, campos `cae`/`cae_due_date`/`attempts`/`next_attempt_at`/`last_error`) → `rpc_next_document_number(p_point_of_sale_id, p_comprobante_type)` (lock corto, UPDATE-then-INSERT) → función/RPC de emisión `pending_cae` (resuelve PV efectivo; `P0422 ambiguous_point_of_sale` si hay varios y no se especifica) → bucket privado `afip-certs` + Storage policies. `npx supabase db push` (CLI, proyecto `gxdhpxvdjjkmxhdkkwyb`). `supabase db advisors` = 0 ERRORs.
2. **Backend (TDD)**: port + `WSFEStubAdapter` + `WSFEAdapter` (real homologación) + resolvedor A/B/C + `FiscalProfileRepository` + router `fiscal` + relay del CAE → tests pytest (baseline 124 antes de tocar).
3. **Frontend**: `/configuracion/fiscal` + upload de cert + `use-fiscal-profile`; `database.types.ts` regenerado; `tsc --noEmit` limpio.
4. **`pg_cron`** del relay (si OQ-1 = A) + verificación end-to-end en homologación (stub en CI; integración real manual/marcada).
5. **PR → merge por el PO → deploy Render/Vercel**. Smoke: crear perfil, reservar número (sin huecos en concurrencia), emitir `pending_cae`, relay → `authorized` con CAE del stub.
6. **Rollback**: DROP de las 3 tablas + RPC + bucket (aditivo, sin pérdida de datos preexistentes — son tablas nuevas). El backend cae al stub si el adapter real falla (degradación, no caída).

## Open Questions (RESUELTAS por el PO 2026-06-12 — ver Resolved Decisions)

- ~~**OQ-1 — Mecanismo de background del CAE (D6)**: ¿confirmás la **Opción A** (cola en `fiscal_documents` + relay idempotente disparado por `pg_cron` + fire-and-forget al emitir, adaptador WSFE único en Python) frente a una Edge Function que duplicaría el adapter en Deno? **Recomendación: A** — sin infra nueva, una sola implementación del ACL, reusa el patrón de cron existente.~~ → **RESUELTA: Opción A.**
- ~~**OQ-2 — Dónde vive `punto_de_venta`**: ¿`fiscal_profiles.punto_de_venta` (un PV por cuenta) o `branches.punto_de_venta`? **Recomendación: `fiscal_profiles.punto_de_venta` en C-27** (mono-PV).~~ → **RESUELTA — MODIFICADA: multi-PV.** El PO quiere 2+ puntos de venta por cuenta desde C-27. Tabla `points_of_sale` (entidad hija del perfil, alineada a modelo §3.6/§5.1); `fiscal_profiles` pierde `punto_de_venta`; `document_sequences` re-clavado por `point_of_sale_id`. Ver D10/D11.
- ~~**OQ-3 — Alcance de la emisión en C-27**: ¿solo maquinaria + endpoint directo (probada con stub), wiring de venta a C-29 (**recomendado**), o ya conecta a `rpc_create_sale_operation`?~~ → **RESUELTA: solo maquinaria + endpoint directo; wiring al POS/quickSale a C-29.**
- ~~**OQ-4 — Validación de CUIT del emisor**: ¿reusar el validador de CUIT módulo-11 de C-22 (`isValidCuit`)?~~ → **RESUELTA: SÍ**, reusar `isValidCuit` (módulo-11) de C-22 para el CUIT del emisor.

## Resolved Decisions (PO, 2026-06-12 — "dale con lo recomendado, con OQ-2 multi-PV")

- **OQ-1 = SÍ (Opción A)**: el background del CAE es una **cola materializada en `fiscal_documents`** (`attempts`/`next_attempt_at`/`last_error`) + **relay idempotente disparado por `pg_cron`** (reusa el patrón de `reset-ai-counters`) + fire-and-forget al emitir. El adaptador WSFE vive **una sola vez, en Python** — no se duplica en Deno. Sin infra nueva (DEC-15: ARQ pospuesto). Ver D5/D6.
- **OQ-2 = MODIFICADA — multi-punto-de-venta**: la cuenta puede tener **2 o más PVs** desde C-27 (sin límite artificial). Resoluciones de implementación:
  - **Nueva tabla `points_of_sale`** (D10): `id`, `fiscal_profile_id` FK NOT NULL, `account_id` FK NOT NULL (desnormalizado para RLS — patrón de C-26), `branch_id` FK NULL (opcional en V2.1, se endurece cuando el POS emita en C-29), `numero` INTEGER NOT NULL (nro de PV ante AFIP), `is_active` BOOLEAN, `created_at`. `UNIQUE(fiscal_profile_id, numero)`. RLS por `account_id` (columna directa, no join).
  - **`fiscal_profiles` PIERDE la columna `punto_de_venta`** (se muda a `points_of_sale`). El perfil sigue 1:1 con la cuenta.
  - **`document_sequences` re-clavado** (D3): numeración **por PV y tipo** → `(point_of_sale_id, comprobante_type, last_number)`, `UNIQUE(point_of_sale_id, comprobante_type)`. Lock corto `SELECT FOR UPDATE` + UPDATE-then-INSERT (NUNCA upsert acumulativo sobre tabla con CHECK — gotcha del proyecto).
  - **Emisión** (D11): el endpoint recibe `point_of_sale_id` **opcional**; un solo PV activo → se usa ese; varios PVs y sin especificar → **error `P0422 ambiguous_point_of_sale`** (5 chars, no colisiona con `backend/core/errors.py`).
  - **UI `/configuracion/fiscal`**: CRUD mínimo de puntos de venta (listar / agregar / desactivar), sin límite de cantidad.
- **OQ-3 = SÍ (recomendada)**: C-27 entrega **maquinaria + endpoint directo de emisión** (`pending_cae`, probada con el stub). El wiring al POS/`quickSale()` queda **para C-29**.
- **OQ-4 = SÍ**: reusar el validador de CUIT **módulo-11** de C-22 (`isValidCuit`) para el CUIT del emisor; exigir CUIT válido para guardar el perfil.
