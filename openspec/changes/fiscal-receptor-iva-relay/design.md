## Context

El modelo de delegación (v22) ya emite CAE real en producción, pero solo está validado para el caso **"emisor monotributista → Factura C → consumidor final sin identificar, monto < umbral"**. La investigación 2026-06-26 (engram `opsx/v22-afip-delegation-billing/modelo-facturacion-decision`, #355) detectó que la identidad del receptor y el desglose de IVA se **pierden en el camino** entre la emisión y la llamada a AFIP, en cuatro capas encadenadas:

1. **Schema** — `fiscal_documents` ([20260627000001:176-195](supabase/migrations/20260627000001_c27_fiscal_profile.sql)) no tiene columnas para el receptor (DocTipo/DocNro) ni para el IVA (neto/iva/alícuota). Solo guarda `client_id` y `total`.
2. **RPCs** — `rpc_emit_pending_cae` no captura receptor ni IVA. `rpc_emit_subscription_payment_cae` recibe `p_receptor_doc_tipo/p_receptor_doc_nro` pero **los descarta** en el INSERT ([20260724000002:179-189](supabase/migrations/20260724000002_v22_subscription_payment_invoicing.sql)).
3. **Relay** — `claim_pending` (hot path) tiene un `RETURNING` con lista explícita de columnas sin receptor/IVA ([fiscal_document_repository.py:112-118](backend/repositories/fiscal_document_repository.py)); `CAERelayProcessor.process_document` arma el `CAERequest` sin esos campos ([cae_relay_processor.py:71-80](backend/services/fiscal/cae_relay_processor.py)).
4. **Adapter** — `WSFEAdapter._call_wsfe` hardcodea `DocTipo = 99` ([wsfe_adapter.py:521](backend/services/fiscal/wsfe_adapter.py)) y, para tipo A/B sin desglose, default a `ImpIVA = 0`.

El `CAERequest` (dataclass del port) **ya tiene** los campos `receptor_iva_condition`, `neto`, `iva_amount`, `iva_alicuota_id` (agregados en v21-wsfe-production-hardening) — pero nadie los popula. Faltan solo `receptor_doc_tipo`/`receptor_doc_nro` para distinguir CUIT (80) de DNI (96).

**Constraints del proyecto:** governance CRÍTICO (fiscal, dinero real, comprobantes ante ARCA) → propose/design only, sign-off del PO antes de código. Backend FastAPI 3 capas, asyncpg JWT-passthrough, SOAP `zeep` encapsulado en el adapter (ACL). Migraciones las aplica el CI (`deploy.yml` → `supabase db push`); se escribe el `.sql`. Strict TDD pytest; ARCA real = `@pytest.mark.integration` (manual). Fuente legal del umbral: RG 5824/2026 (vigente 12/02/2026), identificación obligatoria de consumidor final ≥ **$10.000.000**.

## Goals / Non-Goals

**Goals:**

- Que `DocTipo`/`DocNro` se deriven de los datos del receptor (80=CUIT, 96=DNI, 99=sin identificar) en vez de hardcodearse, sin cambiar el comportamiento de ningún comprobante existente.
- Que el desglose de IVA persistido alimente el array `AlicIva` real de Factura A/B (no `IVA = 0`).
- Cerrar el bug latente de `rpc_emit_subscription_payment_cae` (deja de descartar el receptor).
- Validar la identificación obligatoria del receptor cuando `total ≥ umbral` (RG 5824/2026).
- Mantener la invariante de rollback: columnas NULL = comportamiento actual (consumidor final sin identificar).

**Non-Goals:**

- NO se auto-computa el neto/IVA de una Factura A/B desde el total (es lógica de la venta; la venta provee el desglose). Acá se persiste y propaga lo que la venta calcule.
- NO se cablea el frontend del POS para capturar el receptor desde `client-fiscal-identity` (C-22) — queda como follow-up de UX (`producto-facturacion-afip-ux`). Esta corrección es de backend + DB.
- NO se toca el modelo de delegación (cert de plataforma, `Auth.Cuit`, TA por ambiente), ni la numeración (`FECompUltimoAutorizado`), ni `CondicionIVAReceptorId` (RG 5616, ya resuelto).
- NO se mueve el umbral a una tabla editable en runtime en este change (queda como constante de config — ver OQ-3).

## Decisions

### D1 — Resolver el receptor en la RPC de emisión, persistir el resultado

La identificación del receptor se **resuelve en el momento de emitir** (en la RPC) y se persiste ya resuelta (`receptor_doc_tipo`, `receptor_doc_nro`) en `fiscal_documents`. El relay y el adapter solo **leen** el valor persistido — no hacen joins a `clients` ni recomputan nada en el hot path.

- `rpc_emit_subscription_payment_cae`: ya recibe `p_receptor_doc_tipo/p_receptor_doc_nro` → solo hay que **agregarlos al INSERT** (hoy se descartan).
- `rpc_emit_pending_cae`: suma parámetros opcionales de receptor (e IVA) y los persiste. La fuente (cliente con identidad fiscal de C-22, o input explícito) la decide el caller; la RPC persiste lo que recibe.

**Alternativa descartada:** que el relay joinee `clients` para resolver el receptor en cada intento. Rechazada: mete lógica fiscal en el hot path del relay (corre cross-account con service_role, sin RLS), recomputa en cada reintento y acopla el relay al modelo de clientes. Resolver-una-vez-en-emisión es más simple y determinístico.

### D2 — `DocTipo` derivado en el adapter, default-safe a 99

El `WSFEAdapter` deriva `DocTipo`/`DocNro` así: si `CAERequest.receptor_doc_tipo` está presente (80/96) y hay `receptor_doc_nro` → usar esos; si no → `DocTipo = 99`, `DocNro = 0`. Agregar `receptor_doc_tipo: int | None` y `receptor_doc_nro: str | None` al `CAERequest` (los demás campos de receptor/IVA ya existen).

**Por qué en el adapter:** es donde vive el contrato SOAP de AFIP (la regla `DocTipo=99 ⇒ DocNro=0` es de AFIP). Mantiene el ACL: el dominio pasa datos de receptor, el adapter los traduce.

### D3 — Umbral de identificación como constante de config parametrizable

El umbral (`$10.000.000`, RG 5824/2026) se define como constante de configuración del backend (p. ej. `settings.afip_consumidor_final_threshold`, default `10_000_000`). El guard (`total ≥ umbral ⇒ receptor requerido`) se evalúa antes/al solicitar el CAE. Cuando una RG futura cambie el monto, se actualiza la constante sin tocar la lógica.

**Alternativa:** tabla `fiscal_config` editable en runtime. Mejor a largo plazo (cambia sin deploy), pero agrega superficie. → **OQ-3** para el PO.

### D4 — Migración aditiva, NULL = comportamiento actual (rollback-safe)

Columnas nuevas en `fiscal_documents`: `receptor_doc_tipo SMALLINT NULL`, `receptor_doc_nro TEXT NULL`, `neto NUMERIC(15,2) NULL`, `iva_amount NUMERIC(15,2) NULL`, `iva_alicuota_id SMALLINT NULL`. Todas NULLABLE, **sin backfill**: un comprobante histórico con NULL se emite exactamente como hoy (`DocTipo=99`, tipo C sin array `Iva`). Las RPC se actualizan con `CREATE OR REPLACE`. `claim_pending`/`list_pending`/`list_pending_all` extienden su `RETURNING`/`SELECT`. Rollback: `DROP COLUMN` + restaurar el cuerpo anterior de las RPC. La invariante "ningún comprobante existente cambia salvo que se provea identificación" es la red de seguridad del governance CRÍTICO.

### D5 — Factura A/B sin desglose = falla explícita, no IVA en cero silencioso

Si un comprobante tipo A/B llega al adapter sin desglose de IVA (`neto`/`iva_amount` NULL), el adapter NO emite con `ImpIVA = 0` silenciosamente (hoy lo hace): falla explícito (error de dominio reintentable) o el desglose se completa antes. Para el emisor actual (monotributista → tipo C) esto es inocuo; protege al primer emisor Responsable Inscripto que entre.

## Risks / Trade-offs

- **[CRÍTICO — un `DocTipo`/IVA mal armado genera un comprobante fiscal incorrecto ante ARCA]** → invariante NULL=actual (ningún doc existente cambia); TDD exhaustivo por caso (C consumidor final, B/C ≥ umbral con CUIT/DNI, A/B con IVA real); validación E2E en **homologación** con un CUIT representado antes de habilitar producción.
- **[Tocar dos RPC fiscales que ya están en producción]** → `CREATE OR REPLACE` + tests de regresión del flujo admin de suscripción (CAE real ya obtenido — no debe romperse) y del flujo de usuario. Migración reversible.
- **[Persistir el receptor en emisión puede quedar desactualizado si el cliente cambia su CUIT después]** → aceptable: el comprobante refleja el dato al momento de emitir (snapshot), que es lo fiscalmente correcto.
- **[El cómputo del neto/IVA para RI queda fuera de scope]** → riesgo de que A/B no se pueda emitir hasta cablear el desglose en la venta. Mitigación: el guard D5 lo hace visible; el segmento actual es 100% monotributista (tipo C), así que no bloquea hoy.
- **[Umbral hardcodeado puede desactualizarse ante una nueva RG]** → constante de config centralizada (D3); documentar la fuente (RG) en el código.

## Migration Plan

1. **Gate 0 — sign-off del PO** (bloqueante, antes de cualquier código): confirmar D1–D5 y resolver OQ-1..OQ-3.
2. Migración DB aditiva: columnas en `fiscal_documents` + `CREATE OR REPLACE` de `rpc_emit_pending_cae` y `rpc_emit_subscription_payment_cae` (persistir receptor + IVA). Archivo en `supabase/migrations/`; aplica CI.
3. Backend con TDD: `CAERequest` (+receptor_doc_tipo/nro), `fiscal_document_repository` (RETURNING/SELECT), `cae_relay_processor` (threading), `wsfe_adapter` (DocTipo derivado + AlicIva real + guard de umbral), `schemas/fiscal` (propagar receptor en `EmitPendingCAERequest`).
4. Tests `@pytest.mark.integration` contra ARCA homologación (manual, fuera del gate): Factura B con CUIT, Factura ≥ umbral.
5. **Rollback:** migración reversible (DROP COLUMN + restaurar RPC). El default NULL=99 garantiza que un rollback no deja comprobantes a medio camino. El `WSFEStubAdapter` sigue siendo el default sin cert de plataforma.
6. Validación E2E en homologación antes de tocar producción.

## Open Questions — RESUELTAS (Gate 0 sign-off, 2026-06-26, PO: GonzaloSevilla22)

- **OQ-1 ✅ RESUELTA:** El receptor se **autocompleta del cliente** (`client-fiscal-identity`, C-22) cuando `client_id` tiene identidad fiscal cargada, pero la identificación del receptor **NO es obligatoria en ningún punto** por debajo del umbral: ni al cargar el cliente (CUIT/DNI sigue siendo campo opcional del cliente), ni al emitir/mandar el CAE. Solo se vuelve obligatoria para ventas con `total ≥ umbral` ($10M). Por debajo, se emite `DocTipo = 99` sin fricción. **Invariante dura: esta corrección NO SHALL introducir un campo de receptor requerido en ningún formulario ni endpoint por debajo del umbral.**
- **OQ-2 ✅ RESUELTA:** Para Factura A/B el desglose neto/IVA **lo provee la venta** (line items). NO se auto-computa desde `total` + alícuota (rompería con alícuotas mixtas/exentos). El backend persiste y propaga lo que la venta calcula (D5).
- **OQ-3 ✅ RESUELTA:** El umbral va como **constante de config** del backend (`settings.afip_consumidor_final_threshold`, default `10_000_000`), documentando la RG fuente. No se crea tabla editable en runtime en este change.
