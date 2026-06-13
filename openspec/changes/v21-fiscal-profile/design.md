# Design — v21-fiscal-profile (C-27)

## Context

Post-C-22 los clientes tienen identidad fiscal (`tax_id`, `iva_condition`, `legal_name`) y post-C-26 `Branch` es Aggregate Root con un punto de venta vinculable. Falta el **emisor**: la organización no declara su CUIT/condición IVA/punto de venta, no hay numeración de comprobantes y no existe canal hacia AFIP/ARCA.

Estado actual relevante:
- `accounts` es la tabla de organización (tenancy única post-C-19, `account_id`); RLS vía `current_account_ids()` / `is_account_writer(account_id)`.
- `branches` (C-26): `status ('active'|'closed')`, lifecycle open/close, `PointOfSale` AFIP conceptualmente vive en la branch (modelo §3.6 / §5.1) — la numeración fiscal es **por punto de venta**.
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
1. `FiscalProfile` por cuenta (1:1 con `accounts`): CUIT, condición IVA, IIBB, punto de venta, certificado AFIP en Storage privado, `ambiente` por cuenta.
2. `DocumentSequence` con numeración sin huecos por `(fiscal_profile, punto_de_venta, comprobante_type)`, lock corto, fuera de la transacción larga de la venta.
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

### D2 — `ambiente` por cuenta en `FiscalProfile`, no global ni por env var (PA-22)
`fiscal_profiles.ambiente TEXT NOT NULL DEFAULT 'homologacion' CHECK (ambiente IN ('homologacion','produccion'))`. El adaptador WSFE resuelve la URL del web service y el certificado a usar **a partir del perfil de la cuenta**, no de una variable de entorno del backend. Razón (PA-22): el cutover a producción es por cuenta sin re-deploy; cuentas piloto pueden ir a producción mientras el resto sigue en homologación. Alternativa rechazada: ambiente global por env var — obligaría a un deploy/flag por cada cuenta que migra y mezcla cuentas en distinto estado de homologación.

### D3 — `DocumentSequence` con lock corto fuera de la transacción de venta (numeración sin huecos)
RPC `rpc_next_document_number(p_fiscal_profile_id, p_punto_de_venta, p_comprobante_type) → bigint`: `SELECT … FOR UPDATE` sobre la fila de `document_sequences`, incrementa `last_number`, devuelve el nuevo. Si la fila no existe, **UPDATE-then-INSERT** (no upsert acumulativo — gotcha del proyecto). El lock se toma y suelta en esta RPC; la transacción de la venta (cuando exista, C-29) llama esta RPC como sub-operación corta, no mantiene el lock mientras hace el resto del trabajo. Razón: AFIP exige secuencia sin huecos por PV — es un cuello de botella serializado por diseño (modelo §2.7, §5.9), aislarlo en un agregado pequeño con lock corto evita contención del POS. Alternativa rechazada: secuencia Postgres (`SEQUENCE`) — las sequences pueden saltar números en rollback (huecos), inaceptable para AFIP.

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

### D9 — RLS por `account_id` en las tres tablas nuevas; escritura del perfil solo owner/admin
`fiscal_profiles`, `document_sequences`, `fiscal_documents` con RLS `TO authenticated` + predicado de ownership por `account_id` (`account_id = ANY(current_account_ids())` en USING; `is_account_writer(account_id)` en WITH CHECK para UPDATE/INSERT del perfil). `document_sequences` no se escribe directo desde el cliente — solo vía `rpc_next_document_number` (SECURITY DEFINER con guard). Razón: regla dura del proyecto (RLS por `account_id` en toda tabla nueva; UPDATE policies con USING y WITH CHECK; nada de SECURITY DEFINER para tapar permisos). El backend usa JWT-passthrough (NUNCA `service_role`, DEC-13) salvo la lectura del certificado para firmar WSAA, que es la excepción de job administrativo aislado.

## Risks / Trade-offs

- [El upsert de `document_sequences` viola un futuro CHECK como pasó en C-26 con `branch_stock`] → Mitigación: usar UPDATE-then-INSERT desde el día uno (D3); test de concurrencia (100 calls → sin huecos) en el plan de tests; smoke transaccional en prod.
- [El relay (A) no corre / se atrasa y comprobantes quedan `pending_cae` indefinidamente] → Mitigación: `pg_cron` cada minuto + disparo fire-and-forget al emitir + alerta si `pending_cae` con `attempts > N` (insight de IA por outbox, fuera de scope de C-27 pero el campo queda). El comprobante `pending_cae` es legalmente "en trámite", no perdido.
- [AFIP de homologación intermitente hace flakear los tests] → Mitigación: los tests de lógica usan el **stub** (D4); solo un test de integración opcional (marcado, no en el gate de CI) pega a homologación real.
- [La firma WSAA requiere el `service_role` para leer el cert, abriendo una brecha si se filtra] → Mitigación: la lectura del cert es la única excepción de `service_role`, aislada en el adapter server-side; el cert vive en bucket privado con RLS; el path se valida contra `account_id` del request antes de leer.
- [Numeración por PV vs. PV vinculado a Branch (C-26) — dónde vive `punto_de_venta`] → Mitigación: OQ-2. El modelo dice PV en Branch; el scope de C-27 (CHANGES.md) lo pone en `fiscal_profiles`. Resolver antes del apply.
- [Governance CRÍTICO: facturación real] → Mitigación: el PO revisa y mergea propose; las OQs se resuelven antes del apply; ningún corte a producción real de AFIP sin aprobación humana explícita (PA-22 ya delimita: producción es trámite del usuario, no del code).

## Migration Plan

1. **Migración A (única, no destructiva)**: `CREATE TABLE fiscal_profiles` (+ RLS, UNIQUE `account_id`, CHECKs de `iva_condition`/`ambiente`) → `CREATE TABLE document_sequences` (+ RLS, UNIQUE `(fiscal_profile_id, punto_de_venta, comprobante_type)`) → `CREATE TABLE fiscal_documents` (+ RLS, CHECK de `status`, campos `cae`/`cae_due_date`/`attempts`/`next_attempt_at`/`last_error`) → `rpc_next_document_number` (lock corto, UPDATE-then-INSERT) → función/RPC de emisión `pending_cae` → bucket privado `afip-certs` + Storage policies. `npx supabase db push` (CLI, proyecto `gxdhpxvdjjkmxhdkkwyb`). `supabase db advisors` = 0 ERRORs.
2. **Backend (TDD)**: port + `WSFEStubAdapter` + `WSFEAdapter` (real homologación) + resolvedor A/B/C + `FiscalProfileRepository` + router `fiscal` + relay del CAE → tests pytest (baseline 124 antes de tocar).
3. **Frontend**: `/configuracion/fiscal` + upload de cert + `use-fiscal-profile`; `database.types.ts` regenerado; `tsc --noEmit` limpio.
4. **`pg_cron`** del relay (si OQ-1 = A) + verificación end-to-end en homologación (stub en CI; integración real manual/marcada).
5. **PR → merge por el PO → deploy Render/Vercel**. Smoke: crear perfil, reservar número (sin huecos en concurrencia), emitir `pending_cae`, relay → `authorized` con CAE del stub.
6. **Rollback**: DROP de las 3 tablas + RPC + bucket (aditivo, sin pérdida de datos preexistentes — son tablas nuevas). El backend cae al stub si el adapter real falla (degradación, no caída).

## Open Questions (resolver con el PO antes del apply)

- **OQ-1 — Mecanismo de background del CAE (D6)**: ¿confirmás la **Opción A** (cola en `fiscal_documents` + relay idempotente disparado por `pg_cron` + fire-and-forget al emitir, adaptador WSFE único en Python) frente a una Edge Function que duplicaría el adapter en Deno? **Recomendación: A** — sin infra nueva, una sola implementación del ACL, reusa el patrón de cron existente.
- **OQ-2 — Dónde vive `punto_de_venta`**: el modelo (§3.6/§5.1) ata `PointOfSale` a `Branch`; el scope de CHANGES.md lo pone en `fiscal_profiles`. ¿`fiscal_profiles.punto_de_venta` (un PV por cuenta en V2.1, simple) o `branches.punto_de_venta` (PV por sucursal, alineado al modelo pero exige que cada branch declare PV)? **Recomendación: `fiscal_profiles.punto_de_venta` en C-27** (un PV por cuenta cubre el 100% de las cuentas mono-branch actuales) y mover a `branches` cuando aparezca la cuenta multi-PV — `document_sequences` ya tiene la columna `punto_de_venta`, así que el salto es aditivo, sin migrar la numeración.
- **OQ-3 — Alcance de la emisión en C-27**: ¿C-27 entrega la emisión `pending_cae` solo vía endpoint/comando directo (probada con stub) y deja el wiring desde la venta (`quickSale()`) enteramente a C-29 (**recomendado**, respeta el límite de scope), o C-27 ya conecta la emisión a `rpc_create_sale_operation`? **Recomendación: solo maquinaria + endpoint directo** — C-29 es el dueño del flujo de venta.
- **OQ-4 — Validación de CUIT del emisor**: ¿reusar el validador de CUIT módulo-11 de C-22 (`isValidCuit`, frontend) y agregar un CHECK/validación equivalente para el CUIT del perfil (**recomendado**, cero duplicación), exigiendo CUIT válido para guardar el perfil?
