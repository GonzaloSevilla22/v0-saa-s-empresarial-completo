# Tasks — journal-entry-outbox

> **Governance HIGH.** El PO debe revisar y firmar `design.md` (en especial la tabla de cuentas D1 y el mapeo de IVA D4, validados contra 3-5 ventas reales) **antes** de iniciar el grupo 1. No iniciar apply sin ese sign-off.
>
> **TDD.** Cada grupo de lógica (2-4) sigue RED→GREEN→TRIANGULATE→REFACTOR con pgTAP/SQL. Escribir el test que falla antes del código de posting.
>
> **Migraciones.** Todas las migraciones SQL se fechan **estrictamente por encima** de `20260802000001` (la última actual) y se aplican por CI (`npx supabase db push`), nunca a mano ni vía MCP `apply_migration`.

## 0. Pre-apply gate (HIGH governance)

- [ ] 0.1 PO firma `design.md`: confirma los nombres legibles de las ~10 cuentas (D1) y valida el mapeo de IVA (D4) contra 3-5 ventas reales de la DB (monotributista/Factura C, RI/Factura A, RI/Factura B).
- [ ] 0.2 Confirmar que la última migración del repo sigue siendo `20260802000001`; reservar fechas consecutivas estrictamente superiores para las 3 migraciones de este change.

## 1. Schema migration (journal_entries + journal_lines + RLS)

- [ ] 1.1 Crear migración `<fecha > 20260802000001>_journal_entry_schema.sql` con `journal_entries` (id PK, account_id NOT NULL, posted_at, source_event_id → events, source_doc_type, source_doc_ref, status CHECK ('posted','reversed'), reversal_of self-FK NULL, created_at).
- [ ] 1.2 Crear `journal_lines` (id PK, entry_id → journal_entries ON DELETE CASCADE, account_id NOT NULL denormalizado, account_code text NOT NULL, cost_center_id → cost_centers ON DELETE SET NULL NULL, side CHECK ('debit','credit'), amount numeric(14,2) CHECK > 0, line_no int).
- [ ] 1.3 Índices: `journal_entries (account_id, posted_at DESC)`; unique parcial `journal_entries (source_event_id) WHERE source_event_id IS NOT NULL`; `journal_lines (entry_id)`; `journal_lines (account_code, entry_id)`; `journal_lines (account_id)`.
- [ ] 1.4 RLS: habilitar en ambas tablas; política **solo SELECT** por `account_id IN (SELECT current_account_ids())` en cada una. Sin política INSERT/UPDATE/DELETE para `authenticated` (escritura solo vía relay SECURITY DEFINER). Verificar con `supabase db advisors` que no quedan tablas RLS sin política de lectura ni `auth.uid()` re-evaluado por fila.
- [ ] 1.5 COMMENTs documentando: account_code sin FK (clave natural para futura FK V2.6), account_id denormalizado en lines (RLS sin subquery), balance por ASSERT (no CHECK).

## 2. Helper de posting + Consumer 3 en el relay

- [ ] 2.1 RED: test pgTAP/SQL que invoca el dispatch sobre un `SaleConfirmed` y espera 1 `journal_entries` + N `journal_lines` (falla porque no existe el consumer).
- [ ] 2.2 Definir `_journal_post_from_event(p_event public.events)` (`SECURITY DEFINER`, `SET search_path = public`): esqueleto con dispatch por `event_type`, reclamo de idempotencia `(event.id, 'JournalEntry')`, e INSERT de entry+lines.
- [ ] 2.3 Agregar **Consumer 3** a `rpc_process_outbox_dispatch` vía `CREATE OR REPLACE`, **preservando Consumers 1 (AuditLog) y 2 (Email) intactos**, dentro del mismo `BEGIN/EXCEPTION/END` por evento, después de los otros dos. Filtrar `event_type IN ('SaleConfirmed','PurchaseCreated','PaymentReceived','PaymentMade','CreditNoteIssued')`; otros → no-op.
- [ ] 2.4 GREEN: el test 2.1 pasa para el caso más simple (PaymentReceived: débito 1100 / crédito 1300).
- [ ] 2.5 REVOKE/GRANT del helper espejando el patrón C-25 (REVOKE de PUBLIC/anon; el helper se llama solo desde el dispatch SECURITY DEFINER).

## 3. Mapeo de los 5 eventos + ASSERT de balance

- [ ] 3.1 Implementar el ASSERT de balance en `_journal_post_from_event`: `Σ(debit) = Σ(credit)` antes de confirmar; si falla → `RAISE EXCEPTION ... USING ERRCODE = 'P0450'` (5 chars, espacio P04xx del proyecto). Test: entrada desbalanceada deja el evento pending y no inserta filas.
- [ ] 3.2 `SaleConfirmed`: lookup JOIN `sales_orders.fiscal_document_id → fiscal_documents` para `comprobante_type/neto/iva_amount`. Débito 1100 (cash/other) o 1300 (credit) por total; crédito 4100 [neto] + 4200 [iva] (A/B con desglose) o 4100 [total] (Factura C / sin doc). cost_center_id NULL en ingresos. TRIANGULATE: 3 casos (factura_c cash, factura_a credit, sin doc).
- [ ] 3.3 `PurchaseCreated`: débito 5100 [neto] (+ cost_center_id) + 5200 [iva] (con desglose) o 5100 [total]; crédito 2100 (credit) o 1100 (cash). cost_center_id desde payload o lookup a `purchases` por operation_id; NULL en línea de IVA. TRIANGULATE: cash sin IVA, credit con IVA.
- [ ] 3.4 `PaymentReceived`: débito 1100 / crédito 1300 por `amount`. `PaymentMade`: débito 2100 / crédito 1100 por `amount`. (Confirmado: el evento de pago a proveedor es `PaymentMade`, no `SupplierPaymentMade`.)
- [ ] 3.5 `CreditNoteIssued` (reversión): localizar asiento original por `source_doc_type='SalesOrder'` + `source_doc_ref` (o `source_sales_order_id` del payload); crear asiento espejo con lados invertidos + `reversal_of`; UPDATE original a `status='reversed'`. Si no se encuentra el original → RAISE (retry). TRIANGULATE: NC con original posteado; NC antes del original (retry).
- [ ] 3.6 REFACTOR: extraer constantes de account_code, factorizar el cálculo de líneas A/B-vs-C compartido entre venta y compra; tests verdes tras cada paso.

## 4. Productores nuevos (PurchaseCreated, CreditNoteIssued)

- [ ] 4.1 `PurchaseCreated`: agregar el INSERT de evento en `rpc_create_purchase_operation` (`CREATE OR REPLACE`), en la misma transacción, payload `{account_id, operation_id, total (Σ líneas), cost_center_id, neto, iva_amount, occurred_at}`. Test: una compra commitea exactamente 1 evento `PurchaseCreated` (y rollback de la compra → 0 eventos).
- [ ] 4.2 `CreditNoteIssued`: productor de nota de crédito que emite el evento con referencia al documento original (`source_sales_order_id` y/o `source_fiscal_document_id`) en el payload, en la transacción de la NC. Test: emisión de NC commitea 1 evento con la referencia correcta.
- [ ] 4.3 Verificar que NO se re-crean los productores ya en vivo (`SaleConfirmed`, `PaymentReceived`, `PaymentMade`).

## 5. Tests pgTAP / SQL (balance + idempotencia + reversión)

- [ ] 5.1 Balance: para cada uno de los 5 tipos de evento, `Σdebit = Σcredit` en el asiento posteado.
- [ ] 5.2 IVA: 3 casos de venta (Factura C → 1 línea de ingreso; Factura A y B → neto 4100 + IVA 4200) y 2 de compra (sin IVA → 5100 único; con IVA → 5100 + 5200).
- [ ] 5.3 Idempotencia: re-dispatch del mismo evento no crea un segundo asiento (unique `source_event_id` + slot `(event_id,'JournalEntry')`).
- [ ] 5.4 Reversión: venta → asiento; NC → asiento espejo (lados invertidos, balancea) + original `status='reversed'`; NC sin original → evento pending (retry).
- [ ] 5.5 Aislamiento: un asiento desbalanceado o una NC sin original NO aborta el batch — los demás eventos del batch se procesan.
- [ ] 5.6 No-op: eventos fuera de alcance (`StockAdjusted`, `CashSessionClosed`, `CustomerAccountCharged`, `SupplierAccountCharged`) no generan asiento.
- [ ] 5.7 RLS: usuario de otra cuenta no ve los asientos; INSERT directo a `journal_entries`/`journal_lines` por `authenticated` es rechazado.

## 6. Endpoint de lectura (opcional, mínimo)

- [ ] 6.1 (Opcional) Repository: query de lista de asientos por cuenta (most-recent-first) con sus líneas, JWT-passthrough, sin `service_role`.
- [ ] 6.2 (Opcional) Service + router FastAPI 3-capas: `GET` lista de asientos (entry: posted_at, status, source_doc_type + lines: account_code, side, amount, cost_center_id). Pydantic v2 en el schema de respuesta.
- [ ] 6.3 (Opcional) Test del endpoint: lista scoped a la cuenta del JWT; sin fuga cross-account.

## 7. Despliegue y cierre

- [ ] 7.1 Verificar las 3 migraciones con `supabase db advisors` (RLS, search_path, índices) antes de mergear.
- [ ] 7.2 Merge a main → CI aplica `db push` + redeploy. Confirmar que el cron `relay-process-outbox` sigue activo y que Consumer 3 procesa eventos reales (smoke test sobre una venta de homologación).
- [ ] 7.3 Marcar el change en el roadmap (V2.5 Finanzas) y archivar (`/opsx:archive journal-entry-outbox`) una vez verificado en producción.
