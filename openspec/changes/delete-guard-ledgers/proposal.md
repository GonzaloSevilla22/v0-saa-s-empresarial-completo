## Why

Eliminar una operación con dinero posteado **no compensa ningún libro financiero**. El delete vive en el backend Python (`SalesRepository.delete_by_id` / `PurchaseRepository.delete_by_id`) como una secuencia de dos pasos — reversa de stock (`rpc_reverse_stock_movement`, arreglada en #417) + `DELETE` directo — sin RPC atómica, sin guard fiscal, y **sin tocar `customer_account_movements`, `cash_movements`, `bank_movements` ni `journal_entries`**. El dinero queda flotando en los libros después de que la operación que lo originó dejó de existir.

Esto pasó de deuda latente a **daño real el 2026-08-21**: el PO no pudo editar una venta con cargo en cuenta corriente (bloqueo `P0423`, by design de #425), la borró y la recreó, y quedó un **cargo fantasma de $75.150** contra el cliente Gomez Camila — reparado a mano con un `adjustment`. Con la inmutabilidad que introdujeron #423/#425, **"borrar y recrear" ES el camino de corrección del usuario**, y está roto.

La auditoría en prod confirma que el daño no fue un caso aislado: **2 movimientos de caja huérfanos ($8.000) inflando el saldo de una sesión abierta desde el 2026-07-17**, **10 asientos contables posteados** de operaciones que ya no existen (3 `SaleOperation` + 3 `SalesOrder` del POS + 4 `Purchase`), y **3 `sales_orders` colgadas** apuntando a ventas borradas. Ninguno de estos fue detectado por nadie hasta ahora.

## What Changes

- **Guard fiscal en el DELETE** — una venta con comprobante `pending_cae`/`authorized` deja de ser borrable (`P0423`, mismo predicado y errcode que ya bloquean la edición desde #423). Hoy **se puede borrar una venta facturada** y dejar el `fiscal_document` huérfano ante ARCA; el camino correcto es la Nota de Crédito. **BREAKING** para el flujo actual (hoy no hay guard alguno).
- **Contra-movimientos automáticos en los cuatro libros** al borrar una operación con dinero posteado, en espejo del patrón de stock de #417:
  - **Cuenta corriente**: movimiento `credit_note` negativo (tipo que **ya existe** en el CHECK) vía el helper C-30, localizando por las dos convenciones de `reference_id` que conviven (`operation_id` del formulario y `sales_orders.id` del POS).
  - **Caja**: movimiento espejo `sale_reversal` **en la sesión abierta actual de la misma caja**, nunca dentro de un arqueo ya firmado (RN-95 antifraude intacta).
  - **Banco**: movimiento espejo con la dirección invertida (`transfer_in` → `transfer_out`, vocabulario existente), siempre `unreconciled`.
  - **Contable**: contra-asiento vía evento nuevo `SaleOperationDeleted` / `PurchaseDeleted`, calcado de la primera mitad de la rama `SaleOperationAdjusted` de #431.
- **Dos bloqueos nuevos, fundados en invariantes de esquema, no en preferencia**:
  - `P0425` cuando revertir el cargo dejaría el saldo del cliente/proveedor negativo (el cliente ya pagó). El CHECK `balance_after >= 0` es de tabla, no del helper — no hay forma de representarlo sin cambiar el modelo. El usuario debe registrar primero la devolución del pago.
  - `P0426` cuando hay que compensar caja y **no hay sesión abierta** en esa caja. Abrir la caja es la acción del mundo real que corresponde.
- **El delete se muda a una RPC atómica `SECURITY DEFINER` por operación** (`rpc_delete_sale_operation` / `rpc_delete_purchase_operation`), consistente con DEC-24 (UoW = RPCs `SECURITY DEFINER`) y con sus hermanas de creación y edición. El repositorio Python queda como *caller* fino. Los guards dejan de ser evaluables en dos round-trips (TOCTOU) y pasan a correr bajo el mismo lock que las escrituras.
- **El borrado de una venta POS cancela su `sales_order`** (`status='canceled'`, vocabulario ya existente) en la misma transacción, en vez de dejarla colgada apuntando a una venta inexistente.
- **Superficie frontend**: el `confirm()` nativo (*"¿Eliminar esta venta? Esta acción no se puede deshacer."*) se reemplaza por un diálogo que **enumera qué se va a compensar** antes de confirmar, y el botón de borrar se deshabilita con su razón cuando la operación no es borrable — mismo patrón visual que el lock de edición ya montado.
- **Grupo de reparación histórica gateado** para los huérfanos ya medidos en prod, con conteos verificados y política por libro.

## Capabilities

### New Capabilities
- `operation-delete-compensation`: contrato del borrado de una operación comercial — qué lo bloquea, qué compensa en cada libro, cómo localiza los movimientos bajo las dos convenciones de referencia, y su atomicidad.

### Modified Capabilities
- `journal-entry`: dos ramas nuevas de evento (`SaleOperationDeleted`, `PurchaseDeleted`) que postean contra-asiento y marcan `reversed` el asiento vigente, resolviendo el original por ambas convenciones (`SaleOperation`/`operation_id` y `SalesOrder`/`sales_order_id`).
- `cash-movement`: tipo `sale_reversal` incorporado al CHECK y regla de destino del contra-movimiento (sesión abierta actual, nunca una cerrada).
- `customer-account`: reversión de un cargo de venta como `credit_note` negativo, y bloqueo explícito cuando dejaría el saldo negativo.
- `party-account-charge`: contraparte de reversión del helper compartido `_pay_register_party_charge`, para cliente y proveedor.
- `bank-movement`: movimiento espejo de reversión con dirección invertida y `reconciliation_status='unreconciled'`, aun cuando el original ya esté conciliado.
- `operation-edit-context`: el lock fiscal y el lock por dinero posteado dejan de ser exclusivos de la edición — el DELETE los consulta y decide bloquear (fiscal) o compensar (dinero).
- `sales-order`: el borrado de la venta originada en el POS cancela la orden en la misma transacción.

## Impact

- **DB (governance MEDIO-ALTO — dinero en cuatro libros)**: dos RPCs nuevas `SECURITY DEFINER`; rama nueva en `_journal_post_from_event` (reescritura desde `pg_get_functiondef` vivo, con el bloque fiscal y las ramas existentes intactas byte a byte); ampliación idempotente del CHECK de `cash_movements.movement_type`. MAX(version) en prod verificado: `20261004000002`.
- **Backend Python**: `SalesRepository.delete_by_id` / `delete_by_operation` y sus espejos de compras pasan de secuencia a llamada única; `backend/core/errors.py` mapea los errcodes nuevos.
- **Frontend**: diálogo de borrado con detalle de compensación y botón deshabilitado con razón, en `sale-operations-list.tsx` y `purchase-operations-list.tsx`.
- **Datos en prod (medido, no estimado)**: 2 movimientos de caja huérfanos ($8.000), 10 asientos posteados sin operación viva, 3 `sales_orders` colgadas. El par fantasma+ajuste de cuenta corriente de Camila queda excluido por estar ya compensado a mano. Banco: cero huérfanos reales (el único candidato es un pago de cliente, falso positivo).
- **Reutilización**: el change **cablea helpers que ya existen** — `rpc_reverse_stock_movement`, `_pay_register_party_charge`, `c30_register_customer_account_movement`, `c28_register_cash_movement`, `_register_bank_movement`, `_journal_post_from_event`. No se escribe lógica de libro nueva.
