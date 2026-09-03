## Why

La **Etapa A** (`cobranzas-panel`) respondió *"¿quién me debe y cuánto?"* pero se detuvo, deliberadamente y por escrito, antes de la única pregunta que decide a quién se llama hoy: **"¿quién me debe algo que ya venció?"**. Su propio requirement lo declara con todas las letras —*"El panel no promete mora ni vencimientos que el sistema no tiene"*— y la pantalla lleva una nota al pie diciéndole al usuario que el sistema todavía no registra vencimientos.

No es una omisión de superficie: **no existe el dato**. Ninguna tabla del dominio de cuentas corrientes tiene una columna de vencimiento, no hay plazo de pago por cliente ni por cuenta, y el ledger nunca supo qué cargo canceló cada cobro. Con eso, "días desde el último cargo" es lo máximo honesto que se puede mostrar, y un saldo de $567.000 repartido en 11 deudores se gestiona igual que en un cuaderno: de memoria.

Esta es la **Etapa B**, con alcance firmado por el PO el 2026-09-02. Le da al sistema las cuatro piezas que le faltan —plazo de pago, vencimiento por cargo, imputación FIFO y aviso automático— y recién entonces la palabra "vencido" pasa a estar respaldada por un dato.

**Dependencia dura**: el apply de este change requiere `cobranzas-panel` **aplicado y mergeado** primero. Extiende su RPC, su pantalla y su entrada de menú; sin la Etapa A no hay dónde apoyarse.

## What Changes

- **Plazo de pago (dato nuevo, en tres niveles)**: `accounts.default_payment_terms_days` (política de la cuenta), `clients.payment_terms_days` y `suppliers.payment_terms_days` (excepción por parte). Los tres **nullable**: sin plazo configurado no hay vencimiento y **nada pasa a estar vencido** — la funcionalidad es opt-in y no declara moroso a nadie de un día para el otro.
- **Vencimiento por cargo** — **BREAKING (firma)**: `customer_account_movements.due_date` y `supplier_account_movements.due_date` (columnas nuevas, nullable). El helper compartido `_pay_register_party_charge` y los dos `c30_register_*_account_movement` ganan un parámetro de vencimiento (`DROP FUNCTION` + `CREATE`, nunca `CREATE OR REPLACE` — gotcha `42725`), y los tres callers de alta (`rpc_create_sale_operation`, `_c29_confirm_order_core`, `rpc_create_purchase_operation`) resuelven y propagan la fecha. El vencimiento se **congela en la fila del cargo** (patrón snapshot ya adoptado por `document-snapshots`).
- **Fecha de vencimiento editable por venta**: el formulario de venta a crédito muestra el vencimiento resuelto y permite sobreescribirlo. El POS **no** lo edita (usa el resuelto) — decisión declarada, no olvido.
- **Imputación FIFO derivada**: cada cobro cancela el cargo abierto más viejo. La imputación **no se materializa**: se deriva por línea de flotación sobre el ledger append-only, lo que hace que anular un cobro reabra exactamente los cargos que había cerrado, sin ninguna tabla que desandar.
- **Aging por buckets** — al día / vencido 1-30 / 31-60 / +60 / **sin vencimiento** (tramo propio, no plegado a "al día"). El read-model agregado de la Etapa A (`rpc_receivables_report`) **se extiende** con los buckets en vez de nacer un segundo RPC: un único predicado de "quién es deudor", que es exactamente lo que la Etapa A decidió en su D2.
- **Aging por documento** en la cuenta corriente: el historial de movimientos expone, por cargo, su vencimiento, si está vencido, cuántos días y **cuánto queda abierto** tras la imputación FIFO.
- **Espejo de proveedores**: `rpc_payables_report`, endpoints `/reports/payables`, y una pestaña **"Por pagar"** en `/cobranzas` — con lo que este change **cierra la OQ-1 de `cobranzas-panel`** por la afirmativa que su propia recomendación proponía.
- **Aviso diario automático**: barrido `pg_cron` que produce **un resumen deduplicado por cuenta y por día** ("N clientes vencidos por $X") por los dos canales del precedente `_produce_plan_expiring_soon`: campana in-app (evento `ReceivablesOverdueDigest`, 9º tipo del Consumer 4) y email al dueño de la cuenta (plantilla nueva en `send-email`). Espejo para proveedores en el mismo barrido.
- **Recordatorio por WhatsApp** al cliente deudor desde la fila del panel, con mensaje prearmado, reutilizando `buildWhatsAppUrl` de `lib/phone-utils.ts` — el helper que ya usa el envío de comprobantes. Con esto **se cierra la OQ-2 de `cobranzas-panel`**, que remitió el contacto directo a esta etapa.
- **Superficie de configuración**: pestaña **Cobranzas** en `/configuracion` para el plazo por defecto de la cuenta, y campo "Plazo de pago (días)" en los formularios de cliente y de proveedor.

### Non-Goals (declarados)

- **Activar `clients.credit_limit`** — decisión explícita del PO. El campo sigue huérfano desde C-30 y este change no lo lee, no lo escribe y no lo gatea.
- **Backfill de vencimientos históricos**: los cargos ya posteados quedan con vencimiento nulo para siempre. Precedente firmado dos veces (175 gastos en `gastos-forma-pago`, 11 documentos en `caja-compras-cobranzas`); inventarles un vencimiento retroactivo sería declarar vencida deuda que nadie pactó.
- **Materializar la imputación** en una tabla de open-items, y **tocar el saldo materializado o la estructura append-only del ledger**: el saldo sigue siendo la fuente de verdad y los movimientos siguen sin actualizarse jamás.
- **Asiento contable de previsión por incobrabilidad** y cualquier efecto en el libro diario: un vencimiento no mueve plata, así que no emite ningún evento contable. El conjunto canónico de 11 `event_type` del Consumer 3 (invariante D13 de `transactional-outbox`) **no cambia**.
- **Intereses por mora, punitorios o recargos automáticos**: fuera del pedido del PO.
- **Editar el vencimiento de un cargo ya posteado**: la operación con cargo posteado es inmutable (`P0423`, vigente desde `pagos-cableados-restantes`). Queda como OQ.

## Capabilities

### New Capabilities

- `receivables-aging`: vencimiento de la deuda de punta a punta — plazo de pago en cuenta/cliente/proveedor, resolución y congelado del vencimiento en la fila de cargo del ledger, imputación FIFO derivada, clasificación por tramos de antigüedad, y el barrido diario que produce el aviso de deuda vencida por campana y por email. Cubre por igual el lado cliente y el lado proveedor: es un mecanismo espejado, no dos.

### Modified Capabilities

- `receivables-panel`: el read-model agregado suma el importe vencido y los tramos de antigüedad; la pantalla `/cobranzas` gana estado de vencimiento por deudor, filtro por tramo, la pestaña espejo **Por pagar** y el recordatorio por WhatsApp en la fila. Se **deroga** el requirement que prohibía rotular mora y ofrecer buckets: existía porque el dato no existía, y este change lo crea.
- `customer-account`: la fila de cargo del ledger de cliente admite y conserva un vencimiento, y el historial expone por movimiento su vencimiento y su saldo abierto tras la imputación.
- `supplier-account`: espejo exacto de lo anterior para el ledger de proveedor.
- `party-account-charge`: el helper compartido de cargo transporta el vencimiento resuelto hasta la fila del ledger, para los tres caminos de alta por igual.
- `in-app-notifications`: tipo de notificación nuevo — resumen diario de deuda vencida, con audiencia de administración y deduplicación por día calendario argentino.
- `transactional-email-delivery`: plantilla de email nueva para el mismo resumen, por el canal ya existente.

## Impact

**Base de datos** (una migración, `20261022000001` — la Etapa A reserva `20261021000001`):
- Columnas nuevas: `accounts.default_payment_terms_days`, `clients.payment_terms_days`, `suppliers.payment_terms_days`, `customer_account_movements.due_date`, `supplier_account_movements.due_date`. Todas nullable, sin backfill, sin `NOT NULL`.
- **`DROP FUNCTION` + `CREATE`** (aridad nueva): `_pay_register_party_charge`, `c30_register_customer_account_movement`, `c30_register_supplier_account_movement`, `rpc_receivables_report` (cambia el tipo de retorno). ACLs re-emitidas en el mismo archivo — un `DROP`+`CREATE` las resetea.
- **`CREATE OR REPLACE`** (misma firma): `rpc_create_sale_operation`, `_c29_confirm_order_core`, `rpc_create_purchase_operation`, `_notification_from_event`. Toda reescritura parte del `pg_get_functiondef` **vivo de prod**, no del último archivo de migración (regla de integridad de función).
- Funciones nuevas: `rpc_payables_report`, `rpc_set_default_payment_terms`, `_produce_receivables_overdue_digest` + su job de `pg_cron` diario.
- Sin tabla nueva, sin trigger nuevo, sin ERRCODE nuevo (`P0400`/`P0401`/`P0404` ya existen).

**Backend** (`backend/`): `customer_account_repository.py` (los **dos** listados de movimientos — el bloque derivado está duplicado literal y un derivado que sólo entre en uno no llega a la pantalla real), `supplier_account_repository.py`, `client_repository.py`, `supplier_repository.py`, sus services, schemas y routers, más el router de reportes de la Etapa A extendido y el de `payables`.

**Frontend** (`frontend/`): `/cobranzas` (columnas, filtro, pestañas, botón de WhatsApp), formularios de venta, cliente y proveedor, cuenta corriente de cliente y de proveedor, `/configuracion` (pestaña nueva), `NotificationBell` (rótulo del tipo nuevo), y la capa canónica de mappers, tipos, claves y hooks.

**Edge Functions**: `supabase/functions/send-email/index.ts` — una rama de plantilla más.

**Riesgo / governance**: **MEDIA con un tramo de severidad ALTA**. El tramo alto son las tres funciones de cargo y los tres callers de alta: escriben dinero real en cuentas corrientes y una regresión ahí rompe la venta a crédito, el POS y la compra a la vez. El resto —barrido, panel, formularios, configuración— es lectura, o escritura de política sin efecto sobre ningún libro. Nivel por grupo en `design.md`.
