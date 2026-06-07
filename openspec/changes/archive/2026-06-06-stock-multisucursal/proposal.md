## Why

El módulo de sucursales (C-07) permite registrar ventas y compras por sucursal, pero el stock sigue siendo global por usuario. Un negocio con 3 sucursales no puede saber cuánto stock tiene en cada punto de venta ni transferir mercadería entre ellas — lo que hace inútil el módulo de sucursales para gestión operativa real.

## What Changes

- **Nueva tabla `branch_stock`**: stock separado por combinación `(product_id, branch_id)`. Es el ledger de inventario por sucursal.
- **Lógica de decremento/incremento diferenciado**: `rpc_create_sale_operation` y `rpc_create_purchase_operation` ya reciben `branch_id`. Al ser no-NULL, el movimiento descuenta de `branch_stock` en lugar de `products.stock` (stock global).
- **Transferencia entre sucursales**: nueva RPC `rpc_transfer_stock(product_id, from_branch_id, to_branch_id, quantity)` que genera dos `stock_movements` atómicos (`transfer_out` + `transfer_in`).
- **Alerta de stock bajo por sucursal**: trigger `check_low_stock` actualizado para evaluar `branch_stock.quantity <= branch_stock.min_stock` independientemente por sucursal.
- **Page `/sucursales/:id/stock`**: inventario de la sucursal con tabla de productos, stock actual y ajustes manuales.
- **Ajuste manual de stock por sucursal**: RPC `rpc_adjust_branch_stock` para correcciones de inventario (tipo `adjustment` en `stock_movements`).

## Capabilities

### New Capabilities
- `branch-stock`: gestión de inventario separado por sucursal — tabla `branch_stock`, decrementos/incrementos diferenciados en RPCs de venta/compra, página de inventario por sucursal, ajuste manual.
- `stock-transfer`: transferencia de stock entre sucursales — RPC atómica `rpc_transfer_stock`, dos movimientos complementarios, UI de transferencia.

### Modified Capabilities
- `branches`: se agregan requirements de stock por sucursal (inventario, alertas de stock bajo, ajustes manuales) a la capacidad ya especificada en C-07.

## Impact

- **DB**: nueva tabla `branch_stock`; `stock_movements` ya tiene `branch_id` (C-07) — se activa el uso real en los RPCs.
- **Edge Functions / RPCs**: `rpc_create_sale_operation`, `rpc_create_purchase_operation` — rama condicional por `branch_id`. Nuevas: `rpc_transfer_stock`, `rpc_adjust_branch_stock`.
- **Triggers**: `check_low_stock` — lógica adicional para `branch_stock`.
- **Frontend**: nueva page `/sucursales/:id/stock`; formulario de transferencia.
- **Plan gate**: feature exclusiva de plan `'pro'` (RN-06). Misma restricción que el módulo de sucursales.
- **Dependencias**: requiere C-07 aplicado (tabla `branches`, `branch_id` en operaciones, RLS de sucursales).
