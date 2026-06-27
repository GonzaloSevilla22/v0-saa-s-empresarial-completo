## Context

EmprendeSmart no produce un libro diario contable. El modelo de dominio V2 (`modelo-dominio-aliadata-v2.md` §5.6) define `JournalEntry` (root) con `JournalLine` (value objects de partida doble), y §5.9 establece que la consistencia contable **tolera segundos de retraso** — es un proyectado derivado, no parte del commit de la venta. Esto la hace candidata natural para generarse **asíncronamente vía el outbox transaccional** (C-25, en producción).

Estado verificado en `supabase/migrations` (al 2026-06-27):

- **C-25 relay** (`20260718000001_c25_events_outbox_reconcile.sql`): `rpc_process_outbox_dispatch(p_batch_limit)` es pure-SQL plpgsql `SECURITY DEFINER`, recorre eventos pending con `FOR UPDATE SKIP LOCKED`, cada evento en su propio `BEGIN/EXCEPTION/END`, idempotencia por `(event_id, consumer_type)` en `operation_idempotency` (`ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS ROW_COUNT`). Consumer 1 = AuditLog, Consumer 2 = EmailNotification. `processed_at` se marca solo si todos los consumers activos del evento tuvieron éxito. Sin `service_role`, sin HTTP/pg_net en el hot loop.
- **`cost_centers`** (`20260802000001_cost_center_dimension.sql`): tabla por `account_id`, RLS SELECT por miembro de cuenta; `purchases.cost_center_id` y `expenses.cost_center_id` nullable (`ON DELETE SET NULL`); `rpc_create_purchase_operation` ya acepta y propaga `p_cost_center_id` a todas las líneas.
- **`fiscal_documents`** (`20260627000001_c27_fiscal_profile.sql` + `20260800000006_fiscal_receptor_iva_relay.sql`): tiene `comprobante_type text`, `total numeric(15,2)`, `client_id`, `account_id`, `status CHECK ('pending_cae','authorized','rejected')`, y las columnas **`neto numeric(15,2)` / `iva_amount numeric(15,2)` NULLABLE** (pobladas para Factura A/B, NULL para Factura C). `sales_orders.fiscal_document_id` es FK a esta tabla.
- **Productores en vivo** (verificados por grep): `SaleConfirmed` (C-29 `_c29...confirm`, `20260702000001` y `20260721000001`), `PaymentReceived` (C-30 `rpc_register_payment_received`), `PaymentMade` (C-30 `rpc_register_payment_made`), `CustomerAccountCharged` y `SupplierAccountCharged` (C-30).

Governance: **HIGH** (registros con implicancia fiscal; la lógica de IVA débito/crédito es sensible bajo RG AFIP). El PO firma este `design.md` — en particular la tabla de mapeo — antes del apply. No mueve dinero: los asientos derivan de hechos ya commitados.

## Goals / Non-Goals

**Goals:**

- Generar asientos de partida doble balanceados (`Σdébito = Σcrédito`) de forma asíncrona desde 5 tipos de evento del outbox, sin tocar el hot path del ERP.
- Reutilizar el patrón C-25 al pie de la letra: Consumer 3 dentro de `rpc_process_outbox_dispatch`, pure-SQL, `SECURITY DEFINER`, aislamiento por evento, idempotencia, retry implícito.
- Discriminar IVA correctamente (Factura A/B vs C / sin comprobante) para que el asiento sea válido para el libro de IVA.
- Soportar reversión de notas de crédito (asiento espejo + `status='reversed'` en el original).
- Diseñar el schema para que una futura FK a `chart_of_accounts` (V2.6) sea una migración indolora (`account_code` es la clave natural que esa FK referenciaría).

**Non-Goals:**

- UI/tabla configurable de plan de cuentas (`chart_of_accounts`) → **V2.6**.
- Asientos de gastos (`ExpenseRegistered`), cierre de caja (`CashSessionClosed`), ajuste de inventario (`StockAdjusted`), cargo manual a proveedor (`SupplierAccountCharged`) → **V2.6**.
- Export a software contable externo (Tango/Bejerman/Colppy), percepciones, retenciones, diferencias de cambio → **V2.6+**.
- Endpoint de escritura de asientos (el posting es 100% relay; no hay POST de asientos manuales en V1).

## Decisions

### D1 — Plan de cuentas hardcodeado (~10 códigos AR), `account_code TEXT` sin FK

El mapeo evento→cuenta usa un conjunto fijo de códigos en la función plpgsql (CASE estático). `journal_lines.account_code` es `TEXT` **sin tabla FK** en V1. Plan mínimo PYME argentino:

| Código | Cuenta | Tipo | Uso V1 |
|--------|--------|------|--------|
| `1100` | Caja | Activo | Débito en venta cash; crédito en pago a proveedor |
| `1110` | Banco | Activo | Reservado (medios electrónicos futuros) |
| `1300` | Deudores por Ventas (Clientes) | Activo | Débito en venta a crédito; crédito en cobro |
| `2100` | Proveedores | Pasivo | Crédito en compra a crédito; débito en pago |
| `4100` | Ventas | Ingreso | Crédito en venta (neto o total) |
| `4200` | IVA Débito Fiscal | Pasivo | Crédito en venta Factura A/B |
| `5100` | CMV / Compras | Egreso | Débito en compra (neto o total) |
| `5200` | IVA Crédito Fiscal | Activo | Débito en compra con IVA discriminado |
| `5300` | Gastos | Egreso | **Reservado — NO usado en V1** (expenses diferido) |

**Por qué:** cero migración adicional, cero UI, reglas simples. **Alternativa descartada:** tabla `chart_of_accounts` seeded + UI (Opción B de la exploración) — su seed/onboarding/UI es scope de V2.6. El schema soporta la migración futura: `account_code` es la clave natural que una FK a `chart_of_accounts(code)` referenciaría sin reescribir datos históricos.

### D2 — Consumer 3 pure-SQL dentro de `rpc_process_outbox_dispatch` + helper `_journal_post_from_event`

El posting vive como **Consumer 3** en `rpc_process_outbox_dispatch`, después de AuditLog (Consumer 1) y EmailNotification (Consumer 2), dentro del mismo sub-bloque `BEGIN/EXCEPTION/END` por evento. La lógica de mapeo se factoriza en un helper `_journal_post_from_event(p_event public.events)` (también `SECURITY DEFINER`, `SET search_path = public`) para mantener legible el dispatch.

El consumer:
1. Filtra por `event_type IN ('SaleConfirmed','PurchaseCreated','PaymentReceived','PaymentMade','CreditNoteIssued')`; otros tipos → no-op (skip).
2. Reclama el slot de idempotencia `(event.id, 'JournalEntry')` en `operation_idempotency` (`ON CONFLICT DO NOTHING`); si ya estaba → skip idempotente.
3. Llama a `_journal_post_from_event(event)`, que calcula las líneas, valida el balance (D5) e inserta `journal_entries` + `journal_lines`.

**Por qué pure-SQL:** el mapeo es un CASE estático (~5 eventos × 2-3 líneas); el único lookup externo es un JOIN a `fiscal_documents`/`purchases` para neto/IVA — manejable en plpgsql, idéntico en costo al consumer Email. **Umbral de escape a Python** (documentado para el futuro): >12 tipos de evento, lógica de distribución porcentual de costos, o necesidad de llamar APIs externas durante el posting. **Alternativa descartada:** RPC separada `rpc_post_journal_entries` llamada por un cron propio — duplica el scan de eventos y rompe la atomicidad `processed_at` del relay C-25.

### D3 — `SaleConfirmed` (no `FiscalDocumentIssued`) es el trigger del asiento de venta

El asiento de venta se dispara con **`SaleConfirmed`**, que siempre se emite al confirmar la orden (cash/other/credit), independientemente de si hay comprobante fiscal. Esto garantiza que las ventas de **monotributistas** (Factura C o sin comprobante) también generen asiento. El neto/IVA se obtiene por JOIN: `sales_orders.fiscal_document_id → fiscal_documents (comprobante_type, neto, iva_amount)`.

**Por qué:** la contabilidad refleja el hecho económico (la venta ocurrió), no el trámite fiscal (que es async y puede tardar minutos en obtener CAE, o no existir). **Alternativa descartada:** `FiscalDocumentIssued` como trigger — dejaría sin asiento a todas las ventas de monotributistas. `FiscalDocumentIssued` queda **fuera de alcance V1** como trigger; en V2.6 podría *enriquecer* el desglose neto/IVA de un asiento ya posteado, pero no es el disparador.

### D4 — Discriminación de IVA por `comprobante_type` + presencia de `neto`/`iva_amount`

- **Venta Factura A/B** (`comprobante_type IN ('factura_a','factura_b')` AND `neto IS NOT NULL` AND `iva_amount IS NOT NULL`): crédito `4100 Ventas` [neto] + crédito `4200 IVA Débito Fiscal` [iva_amount].
- **Venta Factura C / sin comprobante / sin desglose**: crédito único `4100 Ventas` [total]. (Hoy solo `factura_c` está en vivo; A/B planeado — el código cubre ambos.)
- **Compra**: espeja con débito `5100 Compras` [neto] + débito `5200 IVA Crédito Fiscal` [iva], o débito único `5100` [total] si no hay desglose.

**Por qué:** el segmento objetivo incluye Responsables Inscriptos (modelo V2); el libro de IVA AFIP exige discriminar débito/crédito fiscal. Los campos ya existen en `fiscal_documents`. **Regla de negocio:** ver `knowledge-base/05_reglas_de_negocio.md` (RN de Factura A/B/C). El balance se mantiene en ambas ramas (D5).

### D5 — Balance por ASSERT en la función, no por CHECK de tabla

El invariante `Σ(amount WHERE side='debit') = Σ(amount WHERE side='credit')` se valida con un `ASSERT` (o `IF ... RAISE EXCEPTION USING ERRCODE`) **dentro de `_journal_post_from_event`**, justo antes (o después con `DEFERRED`-style verificación) de los INSERT de líneas. Un `CHECK` a nivel tabla no puede usar subqueries/agregados cross-row en Postgres, por lo que el balance no es expresable como constraint declarativa.

Un balance fallido lanza una excepción que el `BEGIN/EXCEPTION/END` del evento captura: el `processed_at` del evento queda `NULL` (retry en el próximo tick) y el batch continúa con el siguiente evento — **no aborta el batch entero**. Esto es exactamente la semántica de aislamiento por evento de C-25. ERRCODE custom: `'P0450'` (libre dentro del espacio `P04xx` del proyecto — 5 chars, formato `RAISE EXCEPTION ... USING ERRCODE`).

### D6 — Idempotencia por `UNIQUE(source_event_id)` (índice parcial)

`journal_entries.source_event_id uuid` (FK a `events`) con índice único parcial `WHERE source_event_id IS NOT NULL` garantiza que un evento genera **a lo sumo un asiento**. Es la misma garantía que el slot `(event.id, 'JournalEntry')` en `operation_idempotency`; se usan **ambas** (el slot acelera el skip sin tocar `journal_entries`, el unique index es la red de seguridad de integridad referencial). Mismo estilo que el patrón `(event_id, consumer_type)` de C-25. Las reversiones (asientos de notas de crédito) llevan su propio `source_event_id` (el del evento `CreditNoteIssued`), distinto del asiento original.

### D7 — RLS: solo política SELECT por cuenta; escritura solo vía relay `SECURITY DEFINER`

`journal_entries` y `journal_lines` tienen RLS habilitada. Se crea **solo una política SELECT** por cuenta — **no** hay política INSERT/UPDATE para `authenticated`, porque toda escritura ocurre vía la función `SECURITY DEFINER` del relay (idéntico a `audit_logs` en C-25). Esto evita la trampa de C-28 (una tabla RLS escrita *directamente* por el usuario necesita política de escritura; acá NO, porque el relay es el único escritor).

- `journal_entries`: `SELECT ... USING (account_id IN (SELECT current_account_ids()))`.
- `journal_lines`: **decisión de derivación del account** — se elige **denormalizar `account_id` en `journal_lines`** (copiarlo del entry padre en el INSERT) y filtrar `SELECT ... USING (account_id IN (SELECT current_account_ids()))`. 

  **Por qué denormalizar y no `EXISTS` sobre el padre:** una política `EXISTS (SELECT 1 FROM journal_entries je WHERE je.id = journal_lines.entry_id AND je.account_id IN (...))` re-ejecuta la subquery por fila en cada SELECT de líneas (patrón que el proyecto ya penalizó en `20260517000003_fix_rls_initplan_and_indexes.sql`). El `account_id` denormalizado es inmutable (los asientos no se reasignan de cuenta) y el relay ya tiene el `account_id` en mano al insertar, por lo que el costo de denormalizar es nulo y la RLS de lectura queda en un simple índice por `account_id`. Trade-off aceptado: una columna redundante a cambio de RLS sin subquery por fila.

### D8 — Mapeo cost_center_id: NULL en ingresos, lookup a `purchases` en compras

- **Líneas de ingreso/venta** (`4100`, `4200`, `1100`, `1300` en `SaleConfirmed`): `cost_center_id = NULL`. El centro de costo es una dimensión analítica de **costos/gastos**, no de ingresos; las ventas no llevan `cost_center_id` hoy.
- **Líneas de compra** (`5100` en `PurchaseCreated`): `cost_center_id` se obtiene de `purchases.cost_center_id`. **Cómo:** el productor `PurchaseCreated` (a crear — ver D9) debe incluir `cost_center_id` en el payload del evento; si el payload no lo trae, el consumer hace un `SELECT cost_center_id FROM purchases WHERE operation_id = (payload->>'operation_id')::uuid LIMIT 1` (todas las líneas de la operación comparten el mismo CC, garantizado por `rpc_create_purchase_operation`). Las líneas de IVA crédito fiscal (`5200`) llevan `cost_center_id = NULL` (el IVA no se imputa a centro de costo).

### D9 — Productores: dos nuevos (`PurchaseCreated`, `CreditNoteIssued`); tres ya existen

Verificación por grep en `supabase/migrations`:

| Evento | Productor | Estado verificado |
|--------|-----------|-------------------|
| `SaleConfirmed` | `_c29...confirm_order_core` (C-29, `20260702000001` / `20260721000001`) | ✅ En vivo. Payload: `account_id, branch_id, sales_order_id, operation_id, total, payment_method, client_id, occurred_at`. |
| `PaymentReceived` | `rpc_register_payment_received` (C-30, `20260720000001`) | ✅ En vivo. Payload: `account_id, customer_account_id, client_id, payment_id, amount, balance_after, reference_sale_id, occurred_at`. |
| `PaymentMade` | `rpc_register_payment_made` (C-30, `20260720000001`) | ✅ En vivo. Payload: `account_id, supplier_account_id, supplier_id, payment_id, amount, balance_after, occurred_at`. **Nota: el evento se llama `PaymentMade`, no `SupplierPaymentMade`.** |
| `PurchaseCreated` | — | ❌ **NO existe productor** en ninguna migración (grep = 0 matches), pese a que el spec `transactional-outbox` afirma que C-25 lo agrega. **Tarea de este change:** agregar el INSERT de evento `PurchaseCreated` en `rpc_create_purchase_operation`, en su transacción, con payload `{account_id, operation_id, total (Σ líneas), cost_center_id, neto, iva_amount, occurred_at}`. |
| `CreditNoteIssued` | — | ❌ No existe. **Tarea de este change:** productor de nota de crédito que emita `CreditNoteIssued` con referencia al documento/venta original (`source_sales_order_id` / `source_fiscal_document_id`) para que el consumer encuentre el asiento a revertir. |

**Decisión lookup vs enriquecimiento de payload:**
- `SaleConfirmed`: el payload **no** trae `neto`/`iva_amount`/`comprobante_type` → el consumer hace **lookup JOIN** `sales_orders.fiscal_document_id → fiscal_documents`. No se enriquece el productor (es de C-29, en vivo; evitamos tocar el hot path de la venta).
- `PurchaseCreated`: como hay que **crear** el productor, se **enriquece el payload** con `cost_center_id`, `neto`, `iva_amount` desde el vamos (más barato que un lookup futuro). Si en la práctica `rpc_create_purchase_operation` no calcula neto/IVA de compra, el consumer hace lookup a `purchases` (total) y trata la compra como sin discriminación (débito único `5100`) hasta que exista IVA crédito fiscal de compras.
- `PaymentReceived` / `PaymentMade`: el payload trae `amount` → suficiente, sin lookup.

### D10 — Reversión de notas de crédito

`CreditNoteIssued` → el consumer:
1. Resuelve el asiento original por `source_doc_ref`/`source_doc_type` o por el `source_sales_order_id` del payload (`SELECT id FROM journal_entries WHERE source_doc_type='SalesOrder' AND source_doc_ref = <original_sales_order_id> AND status='posted'`).
2. Crea un **asiento espejo**: mismas líneas con `side` invertido (`debit↔credit`), `reversal_of = <id original>`, `status='posted'`, `source_event_id = <id del evento CreditNoteIssued>`.
3. Marca el original `UPDATE journal_entries SET status='reversed' WHERE id = <id original>`.

El asiento espejo también balancea (invertir lados preserva `Σdébito=Σcrédito`). Si no se encuentra el asiento original (p. ej. la venta nunca posteó), el consumer lanza excepción → el evento queda para retry (el `SaleConfirmed` original probablemente aún no se procesó; reintenta).

## Risks / Trade-offs

- **IVA discriminado incorrecto (A/B vs C)** → Mitigación: tests pgTAP con 3 casos (monotributista/factura_c, RI factura_a, RI factura_b) verificando las cuentas exactas y el balance; el PO valida la tabla de mapeo de este design contra 3-5 ventas reales antes del apply.
- **Asiento desbalanceado** → Mitigación: ASSERT en la función (D5); el evento queda pending para debugging, no corrompe el libro ni aborta el batch.
- **Productor `PurchaseCreated` ausente** (riesgo real descubierto en verificación) → Mitigación: crear el productor es una tarea explícita; sin él, las compras nunca generan asiento (degradación silenciosa). Test que verifica que una compra emite el evento y que el consumer lo postea.
- **Productor `CreditNoteIssued` sin referencia al asiento original** → Mitigación: diseñar el payload con `source_sales_order_id`/`source_fiscal_document_id`; test de reversión end-to-end (venta → asiento → NC → asiento espejo + original `reversed`).
- **Doble conteo `SaleConfirmed` + (futuro) `FiscalDocumentIssued`** → Mitigación: en V1 solo `SaleConfirmed` postea; `FiscalDocumentIssued` no es trigger (D3). La idempotencia por `source_event_id` evita duplicados aun si se agregara después.
- **`payment_method` no incluye 'credit' en el CHECK base de `sales_orders`** pero C-30 lo usa → el consumer debe tratar `payment_method='credit'` (débito `1300`) además de `cash`/`other` (débito `1100`); test cubre las dos ramas.
- **Crecimiento de `journal_entries` sin retención** → Mitigación: índice compuesto `(account_id, posted_at DESC)`; política de retención queda para V2.x (fuera de alcance).
- **Governance HIGH** → Mitigación: el PO firma este design antes del apply; la lógica de cuentas/IVA se revisa con criterio contable.

## Migration Plan

1. **Migración 1** (`<fecha > 20260802000001>_journal_entry_schema.sql`): crea `journal_entries` + `journal_lines` (con `account_id` denormalizado en lines), índices (`(account_id, posted_at DESC)`, parcial `source_event_id`, `(account_code, entry_id)`, `entry_id`), unique parcial `source_event_id`, RLS SELECT por cuenta. Define `_journal_post_from_event` y agrega el Consumer 3 a `rpc_process_outbox_dispatch` (CREATE OR REPLACE, preservando Consumers 1 y 2 intactos).
2. **Migración 2** (`<fecha+1>_purchase_created_producer.sql`): agrega el INSERT de evento `PurchaseCreated` en `rpc_create_purchase_operation` (CREATE OR REPLACE).
3. **Migración 3** (`<fecha+2>_credit_note_producer.sql`): productor de `CreditNoteIssued` con referencia al documento original.
4. **Aplicación**: por CI (`npx supabase db push` al mergear a main). **Nunca** MCP `apply_migration` (regla del proyecto). Las migraciones se fechan **estrictamente por encima** de `20260802000001` (la última actual).
5. **Rollback**: `DROP TABLE journal_lines, journal_entries`; restaurar el cuerpo previo de `rpc_process_outbox_dispatch` (sin Consumer 3) y de `rpc_create_purchase_operation` (sin el INSERT de `PurchaseCreated`); remover el productor de `CreditNoteIssued`. El relay vuelve a su estado C-25 sin pérdida de eventos (los `processed_at` ya marcados quedan; los pending se reprocesan sin Consumer 3).
6. **Sign-off PO (HIGH governance)**: requerido antes de la Migración 1 — revisión de la tabla de cuentas (D1) y del mapeo de IVA (D4) contra casos reales.

## Open Questions

Ninguna que bloquee la implementación — las 5 DEC-PO de la exploración (`openspec/explore/2026-06-27-journal-entry-outbox.md` §4/§8) están resueltas por las decisiones de este change (D1 plan hardcodeado, D3 SaleConfirmed trigger, D4 IVA discriminado, D9 scope de 5 eventos, expenses diferido). Pendiente **no bloqueante** para el apply: el PO confirma los nombres legibles de las ~10 cuentas (D1) y valida el mapeo (D4) contra ventas reales (procedural, parte del sign-off HIGH).
