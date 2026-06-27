## Why

EmprendeSmart registra ventas, compras, cobros y pagos como documentos del ERP, pero no produce un **libro diario contable de partida doble**. Sin él, los contadores que asisten a los microemprendedores de Mendoza no tienen un registro auditable de débitos/créditos para conciliar saldos ni para basar declaraciones impositivas (IVA débito/crédito fiscal). El modelo de dominio V2 (`modelo-dominio-aliadata-v2.md` §5.6) define `JournalEntry`/`JournalLine` y, en §5.9, establece que la contabilidad **tolera segundos de retraso** — es derivada, no parte del hot path de la venta. Eso la hace candidata ideal para generarse **asíncronamente** a partir de hechos ya commitados, reutilizando el outbox transaccional que ya está en producción (C-25) y la dimensión `cost_center` recién entregada por `cost-center-dimension`.

## What Changes

- **Nuevo schema contable**: tablas `journal_entries` (cabecera del asiento, RLS por `account_id`) y `journal_lines` (líneas de partida doble: `account_code`, `cost_center_id`, `side`, `amount`). Las cuentas son un **plan hardcodeado de ~10 códigos AR** dentro de la función de posting (`account_code TEXT`, sin tabla FK). Una tabla `chart_of_accounts` configurable + UI queda **fuera de alcance (V2.6)**.
- **Nuevo Consumer 3 en el relay del outbox** (`rpc_process_outbox_dispatch`, C-25): un consumer **pure-SQL plpgsql** `JournalEntry` que, por cada evento V1 en alcance, postea un asiento balanceado vía un helper `_journal_post_from_event(event_row)`. Hereda del patrón C-25: `SECURITY DEFINER`, `FOR UPDATE SKIP LOCKED`, aislamiento por evento (`BEGIN/EXCEPTION/END`), idempotencia, sin `service_role`, sin HTTP/pg_net.
- **Eventos mapeados en V1** (generan asiento): `SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade` (pago a proveedor), `CreditNoteIssued`. **Diferidos a V2.6**: `ExpenseRegistered`, `CashSessionClosed`, `StockAdjusted`, `SupplierAccountCharged`.
- **Discriminación de IVA** (sensible fiscalmente): Factura A/B → líneas separadas de neto (`4100 Ventas`) + IVA débito fiscal (`4200`); Factura C / sin comprobante → línea única total en `4100`. Las compras espejan con `5100` + `5200` IVA crédito fiscal. Los campos `fiscal_documents.neto`/`iva_amount` ya existen (`fiscal-receptor-iva-relay`).
- **Idempotencia + balance**: cada asiento es idempotente por `UNIQUE(source_event_id)` (índice parcial). El invariante de partida doble (`Σdébito = Σcrédito`) se valida con un **ASSERT en la función de posting** (un `CHECK` de Postgres no puede usar subqueries); un balance fallido deja el evento sin procesar para retry, sin abortar el batch.
- **Dos productores nuevos** (tareas de implementación, no código de propose): `CreditNoteIssued` (no existe productor) y `PurchaseCreated` (verificado: **no existe productor en las migraciones** pese a lo que afirma el spec `transactional-outbox`; ver design.md). `SaleConfirmed`, `PaymentReceived` y `PaymentMade` ya tienen productores en vivo (C-29/C-30).
- **Governance HIGH**: el libro diario tiene implicancias fiscales/contables. El PO revisa `design.md` (especialmente la tabla de mapeo de IVA) antes de cualquier apply.

## Capabilities

### New Capabilities

- `journal-entry`: Contabilidad de partida doble generada automáticamente desde documentos del ERP ya commitados. Cubre el schema (`journal_entries`/`journal_lines`), las reglas de mapeo evento→asiento para los 5 eventos V1, la discriminación de IVA (Factura A/B vs C), la idempotencia por `source_event_id`, el invariante de balance (ASSERT), el flujo de reversión de notas de crédito, y la RLS de lectura por cuenta.

### Modified Capabilities

- `transactional-outbox`: Se agrega el **Consumer 3 (JournalEntry posting)** al relay `rpc_process_outbox_dispatch`. Corre in-DB con aislamiento por evento, solo dispara para los 5 tipos de evento V1, es idempotente por `(event_id, consumer_type)`, y un fallo de balance deja el evento sin procesar para retry sin afectar a los consumers AuditLog/Email.

## Impact

- **Migraciones**: una nueva migración SQL (fechada estrictamente por encima de `20260802000001`) crea las tablas, índices y la política RLS de SELECT, define el helper `_journal_post_from_event` y agrega el Consumer 3 a `rpc_process_outbox_dispatch`. Dos migraciones/ajustes adicionales agregan los productores `CreditNoteIssued` y `PurchaseCreated`. Aplicadas por CI (`npx supabase db push`), nunca a mano.
- **Tablas referenciadas**: `events`, `operation_idempotency`, `cost_centers`, `purchases`, `fiscal_documents`, `sales_orders` (FK `fiscal_document_id`), `accounts`.
- **Sin impacto en el hot path**: el posting es asíncrono; las RPCs de venta/compra/cobro/pago no cambian su comportamiento síncrono (salvo el agregado del INSERT de evento `PurchaseCreated`/`CreditNoteIssued` en su propia transacción).
- **Backend FastAPI**: opcional y mínimo — un endpoint de lectura (GET lista de asientos) en 3 capas + JWT-passthrough, sin `service_role`. No hay endpoint de escritura (el posting es 100% relay).
- **Sin dinero en movimiento**: los asientos derivan de hechos ya ocurridos; un fallo del consumer no afecta al ERP (el evento se reintenta).
