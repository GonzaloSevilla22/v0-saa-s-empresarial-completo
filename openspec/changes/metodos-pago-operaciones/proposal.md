## Why

El PO pidió (2026-08-19): *"quiero agregar categorías de pago en ventas y compras, ejemplo efectivo, banco, cuenta corriente, etc"*. Hoy **ninguna venta ni compra registra con qué se pagó**: `sales` (681 filas en prod) y `purchases` (427) no tienen columna de método, y ni el form de venta ni el de compra lo preguntan. Lo único que existe es `sales_orders.payment_method` (texto, CHECK `{cash,transfer,card,other,credit}`), que **solo escribe el POS** y que en la UI ofrece apenas dos botones — en prod: 63 órdenes `cash` y 57 `other`, nada más. Resultado: el emprendedor no puede responder "¿cuánto cobré en efectivo este mes?" ni separar lo cobrado de lo fiado.

Además `v3-provisioning-seed` dejó anotado explícitamente que *"formas de pago"* no existe como estructura (solo el CHECK de `sales_orders`), y hay **dos taxonomías paralelas** ya vivas que este change debe respetar sin romper: el CHECK de `sales_orders` y la de las RPCs de cobro/pago (`{cash,transfer,card,check}` + `bank_account_id`, de `bank-payment-routing`).

## What Changes

- **Catálogo maestro `payment_methods` por cuenta** (no enum fijo): `id`, `account_id`, `name` editable por el usuario, `kind` cerrado que es lo que razona el sistema, `is_active`, `sort_order`, soft delete (`deleted_at`/`deleted_by`). Espejo estructural exacto de `cost_centers`.
- **Seed automático de 6 métodos por cuenta** — Efectivo (`cash`), Transferencia bancaria (`transfer`), Tarjeta (`card`), Billetera virtual (`wallet`), Cuenta corriente (`credit`), Otro (`other`) — vía backfill idempotente de las cuentas existentes + sub-bloque en `handle_new_user` que degrada sin abortar el signup (patrón `v3-provisioning-seed`).
- **Columna nullable `payment_method_id` en `sales` y `purchases`**, por operación (replicada en todas las líneas del header plano, como `cost_center_id` en compras y `canal` en ventas). `NULL` = "Sin especificar", que es lo honesto para los 1.108 documentos históricos.
- **Altas y ediciones**: `rpc_create_sale_operation` / `rpc_create_purchase_operation` / `rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation` aceptan un `p_payment_method_id` opcional, validan pertenencia a la cuenta y lo persisten en todas las líneas; la edición que no lo envía **preserva** el método existente. Sobre la base vigente `20260927000001`, sin tocar el acarreo de líneas (#415) ni el espejo de `stock_movements` (#417).
- **Superficie frontend**: selector "Forma de pago" en el form de venta y en el de compra, badge + filtro por método en ambos listados, gestor del catálogo en `/configuracion` (junto a `CostCenterManager`), y reporte **`/reportes/formas-pago`** con entrada propia en el sidebar.
- **Read-model `rpc_payment_method_report(p_account_id, p_start, p_end)`**: ventas y compras agregadas por método en un rango, con fila "Sin especificar", espejo de `rpc_cost_center_report` y sujeto a los invariantes RN-D.
- **Endpoints FastAPI** `/payment-methods` (CRUD gateado a `owner`/`admin`) y `/reports/payment-methods`, en las tres capas (router → service → repository).
- **NO cambia**: el POS ni `rpc_quick_sale` / `rpc_confirm_sales_order`; el CHECK de `sales_orders.payment_method`; las RPCs de cobro/pago y su ruteo bancario/contable. El listado de ventas muestra el método de las operaciones nacidas en el POS **derivándolo de lectura** desde el texto legacy de la orden (`cash`→Efectivo, `other`→Otro), sin escribir nada.
- **Etiqueta honesta, no falsa afordancia**: elegir "Cuenta corriente" o "Efectivo" en los forms **no** genera cargo en la cuenta corriente del cliente ni movimiento de caja; el form lo dice explícitamente. Los cableados profundos quedan gateados como preguntas abiertas.

## Capabilities

### New Capabilities
- `payment-method`: catálogo de formas de pago por cuenta (`payment_methods` + `kind`), su seed de provisioning, la imputación opcional en ventas y compras (alta y edición), las superficies que la hacen usable (gestor, selectores, badges, filtros) y el read-model de distribución por forma de pago.

### Modified Capabilities
Ninguna. Todo el comportamiento nuevo es aditivo y se especifica dentro de `payment-method`; ninguna capability existente cambia sus requirements. En particular `sales-order` (POS), `sale-line-items` (doble escritura y flag), `cash-session`, `customer-account`, `bank-movement` y `reporting-invariants` quedan **sin modificación de contrato** — este change las consume, no las altera.

## Impact

**Base de datos** (migración idempotente, base `20260927000001`): tabla nueva `payment_methods` + RLS por `account_id` + índices; `ALTER TABLE sales/purchases ADD COLUMN payment_method_id uuid NULL REFERENCES payment_methods(id) ON DELETE SET NULL`; `DROP` + `CREATE` de las 4 RPCs de operaciones (la firma cambia → riesgo 42725 si quedara el overload) con re-`GRANT`/`REVOKE` en el mismo archivo; `CREATE OR REPLACE handle_new_user` (base exacta `20260812000001`) + backfill del catálogo; `rpc_payment_method_report` nueva.

**Backend Python**: `backend/repositories/payment_method_repository.py`, `backend/services/payment_methods.py`, `backend/routers/payment_methods.py`, `backend/schemas/payment_methods.py` (espejos de los de `cost_centers`); passthrough del `payment_method_id` en `sales_repository.py`, `purchase_repository.py` y sus schemas/services; `LEFT JOIN payment_methods` en los listados paginados (como ya se hace con `cost_centers` en compras).

**Frontend**: `hooks/data/use-payment-methods.ts`, `components/payment-methods/PaymentMethodSelect.tsx` + `PaymentMethodManager.tsx`, cambios en `components/forms/sale-form.tsx` y `purchase-form.tsx`, `components/ventas/sale-operations-list.tsx`, `components/compras/purchase-operations-list.tsx`, `app/(dashboard)/configuracion/page.tsx`, nueva ruta `app/(dashboard)/reportes/formas-pago/page.tsx`, entrada en `components/app-sidebar.tsx`, tipos en `lib/types.ts` y `lib/query-keys.ts`.

**Datos**: cero reescritura de importes. `payment_method_id` nace `NULL` en los 1.108 documentos históricos; el único backfill propuesto (gateado, OQ-5) es el de las 120 ventas nacidas en el POS, que **ya tienen** el método declarado por el usuario en su orden.

**Riesgos**: (a) romper las 4 RPCs de operaciones al recrearlas — se mitiga preservando el cuerpo byte a byte sobre la base `20260927000001` y con gates SQL de acarreo de líneas y de `stock_movements`; (b) que el usuario crea que "Cuenta corriente" fía o que "Efectivo" entra a la caja — se mitiga con texto explícito en el form y con las OQs abiertas al PO.
