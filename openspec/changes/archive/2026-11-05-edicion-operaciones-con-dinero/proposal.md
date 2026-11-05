## Why

El PO pidió (2026-10-14), textual: *«quiero que se puedan editar todas las ventas, compras y gastos, aunque sea por cuenta corriente o otras, la única excepción que no se puede cambiar si solo si ya tiene CAE para el caso de las ventas»*.

Hoy una operación con dinero ya registrado es **inmutable** (`P0423`). Pasa con la venta o la compra con cargo en cuenta corriente, con movimiento de caja o con movimiento bancario, y con el gasto con caja o banco. Lo frenan seis guards en tres RPCs de edición (`pagos-cableados-restantes`, `pos-banco-movimientos`, `caja-compras-cobranzas`, `gastos-forma-pago` D11). El único camino de corrección es **borrar y volver a cargar**:

- pierde la fecha original de la caja (la recarga sólo entra a la caja si es de hoy);
- pierde el vencimiento pactado;
- obliga a tener la caja abierta;
- deja dos operaciones distintas donde había una.

El borrado ya sabe compensar los cuatro libros (`operation-delete-compensation`, `cobranzas-reverso`) y el alta ya sabe registrarlos. Lo que falta es hacer las dos cosas **en una sola edición atómica** y **sólo en los libros que cambian**.

Medido en prod (2026-10-14, sólo lectura, sin datos personales):

| | Operaciones | Bloqueadas por dinero | Desglose |
|---|---|---|---|
| Ventas | 570 | **228** | 70 por cuenta corriente, 74 por caja, 84 por banco (sin solapamiento) |
| Compras | 128 | **34** | 1 por cuenta corriente, 4 por caja, 29 por banco |
| Gastos | 259 | **48** | 14 por caja, 34 por banco |

- **Cuentas afectadas**: 6 en ventas y 5 en compras.
- **Bloqueo fiscal**: 19 ventas tienen CAE autorizado. Hay 0 comprobantes en vuelo, 0 congelados y 0 pendientes sin enviar. 17 ventas tienen a la vez dinero y CAE.
- **Ventas que este change habilita**: 211.
- **Caja de ventas**: 72 de los 77 movimientos están en sesiones ya cerradas. 62 están en cajas que hoy no tienen sesión abierta.
- **Cuenta corriente de clientes**: 50 de los 77 cargos están en cuentas cuyo saldo actual ya es menor que el cargo, es decir, el cliente ya pagó parte o todo. 31 cargos están en cuentas con saldo cero.
- **Conciliación bancaria**: 0 movimientos conciliados y 1 sesión cerrada. Esa sesión cubre 12 movimientos de operaciones.

## What Changes

- **Editar una operación con dinero ya es posible.** Vale para ventas (formulario y POS), compras y gastos. Para cada libro se compara la **huella vigente** de la operación con el **efecto que corresponde al estado editado**:
  - **iguales**: la edición no escribe nada en ese libro;
  - **distintos**: compensa la huella con los mismos helpers del borrado y registra el efecto nuevo con los mismos del alta.

  Todo pasa en la misma transacción que la reversa y aplicación de stock. Corregir la descripción o el cliente de una venta en efectivo de la semana pasada **no toca la caja** ni pide abrirla.
- **La edición conserva el identificador de operación.** Deja de regenerar `operation_id` en venta y compra; el gasto ya lo conservaba. **BREAKING** del contrato interno: los gates que esperan un `operation_id` nuevo tras editar cambian, y los consumidores contables excluyen los contra-asientos al buscar el asiento vigente.
- **Huella neta con una sola definición.** Es la suma neta de cada libro, por cuenta del libro y por referencia, y la usan:
  - la edición;
  - el **borrado**, que deja de sumar sólo el tipo original. Si no lo hiciera, una venta editada y luego borrada compensaría dos veces. El cambio también corrige la caja agrupada por sesión.
  - los listados.
- **Cambio de forma de pago al editar.** El efecto se traslada entre libros (crédito → efectivo, efectivo → transferencia, etc.) con las mismas reglas que el alta: cliente o proveedor obligatorio para crédito, cuenta bancaria válida (`P0412`) y período conciliado (`P0424`).
- **Regla de herencia.** Un libro sin huella sólo recibe efecto si la edición cambia la forma de pago o la parte, o si el usuario lo pide explícitamente. Editar la cantidad de una venta a crédito histórica sin cargo no le crea deuda nueva al cliente.
- **Caja.** La compensación va a la sesión abierta de la misma caja; si no hay sesión abierta, `P0426`. Una sesión cerrada nunca se toca. La corrección de un efectivo que ya entró a la caja no exige la fecha de hoy; un efectivo nuevo sí exige las tres condiciones del alta.
- **Cuenta corriente.**
  - Primero se registra el cargo nuevo y después se revierte el viejo, así que `P0425` sólo salta si el saldo **final** quedaría negativo.
  - El vencimiento se conserva salvo que se informe otro.
  - La imputación FIFO del aging **empareja cada reversión de cargo con los cargos de su misma referencia**. Sin esto, la reversión cancelaría el cargo más viejo del cliente y el aging, el aviso diario y el recordatorio por WhatsApp mostrarían deudas pagadas que no lo están.
- **Contable.**
  - Ventas del POS: la edición también ajusta su asiento (hoy sólo se ajusta el de las ventas del formulario).
  - Compras: evento **nuevo `PurchaseAdjusted`**. Hoy editar una compra con asiento deja el asiento viejo vivo y un borrado posterior queda reintentando `P0451` para siempre; medido 0 casos hoy.
  - Conjunto canónico: pasa de 14 a **15 tipos**.
  - `CreditNoteIssued` resuelve el asiento por las dos convenciones de referencia.
- **Concurrencia.** La edición de compra y la de gasto pasan a tomar sus filas `FOR UPDATE`, como ya hace la de venta. Orden fijo de bloqueos de los libros: cuentas corrientes → caja → banco.
- **Plan previo calculado por el servidor.** Antes de confirmar, la pantalla pide una vista previa (`dry_run`) con la misma función que ejecuta la edición. El diálogo enumera qué se compensa y qué se registra en cada libro, o por qué no se puede.
- **Auditoría.** Cada edición deja una fila en `audit_logs` con quién, cuándo, el antes y el después, los movimientos que generó y el motivo opcional. El detalle de la operación muestra un "Historial de cambios".
- **Excepción fiscal sin cambios.** Bloquea el comprobante autorizado **y** el que está en vuelo o congelado hacia ARCA (ver OQ-1). El pendiente no enviado se sigue anulando al editar.
- **Contrato de lectura.**
  - Se retira `is_payment_locked` de los tres listados (**BREAKING** de API; se migran todos los callers).
  - El motivo de bloqueo pasa a un token del servidor, `edit_locked_reason`, que falla cerrado.
  - Los indicadores `has_*` y `is_delete_blocked` pasan a semántica neta.
- **Opt-in de caja.** Su validación queda en un único helper que consumen las tres altas y las tres ediciones.

## Capabilities

### New Capabilities
- `operation-money-edit`: contrato transversal de la edición de una operación con dinero. Cubre:
  - huella vigente frente a efecto deseado, sin escritura cuando coinciden;
  - compensación y registro atómicos;
  - regla de herencia e intenciones tri-estado de caja, banco y vencimiento;
  - plan previo calculado por el servidor;
  - auditoría y orden de bloqueos;
  - identificador de operación estable;
  - quién puede corregir dinero.

### Modified Capabilities
- `operation-edit-context`: se retiran los requirements de inmutabilidad por dinero (venta, compra, caja de compra) y el que impedía pasar una compra a crédito al editar. Cambian los que regeneraban `operation_id` (orden promovida), el del proveedor reimputable y el del gasto en el contrato transversal.
- `operation-delete-compensation`: el borrado localiza y compensa la **huella neta** por referencia, en vez de sumar el tipo original.
- `customer-account`: la edición reemplaza el cargo del cliente. `P0425` se evalúa sobre el saldo final.
- `supplier-account`: se retira la inmutabilidad de la compra con cargo; la edición reemplaza el cargo del proveedor.
- `party-account-charge`: la reversión de un cargo lleva la referencia del cargo que revierte.
- `receivables-aging`: la derivación FIFO empareja la reversión de un cargo con los cargos de su misma referencia.
- `cash-movement`: contra-movimiento y movimiento nuevo de caja por edición.
- `cash-session`: la corrección por edición de un efectivo ya registrado no es un opt-in nuevo.
- `bank-movement`: espejo y movimiento nuevo bancario por edición.
- `journal-entry`:
  - `SaleOperationAdjusted` resuelve las dos convenciones (formulario y POS) y excluye contra-asientos;
  - nueva rama `PurchaseAdjusted`;
  - `CreditNoteIssued` resuelve por las dos convenciones;
  - conjunto de 15 tipos.
- `transactional-outbox`: productor de ajuste para ventas con identificador estable y para compras (`PurchaseAdjusted`); conjunto canónico de 15 tipos.
- `expense-operation`: se retira la inmutabilidad del gasto con dinero. El estado de bloqueo visible pasa a derivarse de la huella neta.
- `expense-journal-entry`: la edición del gasto ajusta su asiento con la contrapartida del libro que efectivamente quedó movido después de editar.
- `payment-method`: cambiar la forma de pago al editar traslada el efecto entre libros.
- `purchase-operation`: el bloque de descuento de caja deja de ser exclusivo del alta y aparece en la edición con el estado vigente.

## Impact

- **Base de datos**: una migración por tanda.
  - Reescritura desde el **cuerpo vivo de prod** de `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation`, `rpc_update_expense`, las tres RPCs de borrado, `_journal_post_from_event`, el despachador del relay (filtro del Consumer 3), `rpc_receivables_report`, `rpc_payables_report`, `_produce_receivables_overdue_digest`, las dos RPCs de cambio de vencimiento y las tres altas (opt-in de caja).
  - Funciones nuevas internas: huella neta, plan de edición y validación del opt-in de caja.
  - Las firmas de las ediciones cambian (`DROP` + `CREATE` + reafirmación de ACL).
  - Sin tablas ni tipos de movimiento nuevos. `audit_logs` ya existe.
- **Backend (FastAPI)**:
  - Esquemas de edición con `cash_session_id`, `bank_account_id`, `due_date` y `reason` en tri-estado.
  - Endpoints de vista previa e historial de ediciones.
  - Proyecciones de los tres listados (`edit_locked_reason`, `has_*` netos, vencimiento vigente).
  - `backend/repositories/_account_aging_sql.py` (emparejamiento).
- **Frontend**:
  - `/ventas`, `/compras` y `/gastos` (rutas y entradas de menú existentes). En listados y formularios en modo edición se habilitan los bloques de crédito, caja y banco.
  - Diálogo de confirmación con el plan del servidor, compartiendo la lista con el diálogo de borrado.
  - "Historial de cambios" en el detalle de la operación.
  - `lib/operation-errors.ts`.
  - Invalidación de caja, banco, cuentas corrientes, cobranzas y libro diario.
- **CI y gates**:
  - Gates SQL nuevos y modificados: 17 gates ejecutan las RPCs de edición.
  - Gate del conjunto canónico del outbox y gate de ACL.
  - Bloques de reaplicación de `KPI_Validation.yml` que fijan estas funciones.
- **Dependencias** (detalle en design.md §Dependencias). Este change se aplica **después** de:
  - `fix/stock-edicion-sucursal-y-piso`;
  - la tanda B de `remitos-compra`;
  - `multiusuario`, que toca las mismas RPCs de alta y edición.
- **Governance**: ALTA (dinero real en cuatro libros). El PO firma las OQs antes del apply.
