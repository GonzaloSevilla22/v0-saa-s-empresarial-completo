## Context

C-07 agregó `branch_id` (nullable) a `sales`, `purchases`, `expenses` y `stock_movements`. Las RPCs de venta/compra ya aceptan `p_branch_id`. Lo que falta es el ledger de inventario por sucursal y la lógica que lo actualiza.

Estado actual:
- `products.stock` = inventario global/sin-sucursal de un producto
- `stock_movements` ya tiene `branch_id` pero no afecta nada específico de sucursal
- No existe `branch_stock` todavía

## Goals / Non-Goals

**Goals:**
- Tabla `branch_stock` como ledger de stock per `(product_id, branch_id)`
- Cuando una venta/compra tiene `branch_id`, decrementa/incrementa `branch_stock` en lugar de `products.stock`
- RPC atómica de transferencia entre sucursales
- Alerta de stock bajo evaluada por sucursal (independiente del stock global)
- Page `/sucursales/:id/stock` con inventario y ajuste manual
- Sin breaking change: operaciones sin `branch_id` siguen usando `products.stock`

**Non-Goals:**
- Migrar `products.stock` existente a `branch_stock` (los negocios arrancan con 0 en branch_stock)
- Stock por variante por sucursal (C-08 solo maneja producto único, no SKU-variante)
- Reporting cruzado entre stock global y branch stock en el mismo dashboard (fuera de scope MVP)

## Decisions

### D1 — Dual-ledger: branch_stock independiente de products.stock

`products.stock` sigue siendo el stock global (sin asignación de sucursal). Cuando se vende **con** `branch_id`, el sistema descuenta de `branch_stock` y NO toca `products.stock`. Cuando se vende **sin** `branch_id`, descuenta de `products.stock` como antes.

**Alternativa considerada**: Decrementar ambos (branch_stock Y products.stock) para mantener `products.stock` como suma total. Descartada porque requiere mantener invariante (sum de branch_stock = products.stock), lo que complica transfers y ajustes.

**Consecuencia**: Al activar branches, el dueño debe usar `rpc_adjust_branch_stock` para "distribuir" inventario a las sucursales. `products.stock` pasa a representar stock "central / sin asignar".

### D2 — Lazy initialization de branch_stock

Las filas de `branch_stock` se crean en el primer movimiento (venta, compra, ajuste, transfer). No se pre-populan al crear la sucursal ni al crear el producto.

**Alternativa**: Pre-poblar con `quantity = 0` para todos los productos al crear una sucursal. Descartada porque con 5.000 productos y 3 sucursales genera 15.000 filas de cero que no aportan valor.

**Implementación**: `INSERT INTO branch_stock ... ON CONFLICT (product_id, branch_id) DO UPDATE SET quantity = branch_stock.quantity + delta`

### D3 — Transfer RPC: dos stock_movements atómicos

`rpc_transfer_stock(p_product_id, p_from_branch_id, p_to_branch_id, p_quantity)`:
1. `SELECT ... FOR UPDATE` en ambas filas de `branch_stock` (evita race condition)
2. Verificar `branch_stock_from.quantity >= p_quantity` (stock suficiente en origen)
3. INSERT `stock_movements` tipo `transfer_out` (origen, delta negativo)
4. INSERT `stock_movements` tipo `transfer_in` (destino, delta positivo)
5. UPDATE `branch_stock` origen: `quantity - p_quantity`
6. UPSERT `branch_stock` destino: `quantity + p_quantity`
Todo dentro de una transacción. Si falla cualquier paso, rollback completo.

### D4 — Alerta de stock bajo por sucursal via trigger

El trigger `check_low_stock` actual evalúa `products.stock <= products.min_stock` tras cada `UPDATE products`. Para branch stock, se agrega un trigger `check_branch_low_stock` sobre `branch_stock` que evalúa `quantity <= min_stock` después de cada UPDATE. Mismo patrón de deduplicación (máximo 1 alerta por producto+sucursal por 24h).

### D5 — Ajuste manual: rpc_adjust_branch_stock

`rpc_adjust_branch_stock(p_product_id, p_branch_id, p_new_quantity, p_reason)` genera un `stock_movements` de tipo `adjustment` con `quantity_delta = new - old` y hace UPSERT en `branch_stock`. Solo `owner` y `admin` pueden ajustar (verificado en la RPC via account_members.role).

## Risks / Trade-offs

- **Dual-ledger inconsistency**: Si el usuario vende sin branch_id y con branch_id para el mismo producto, los stocks quedan en mundos separados. Mitigación: UI explica la distinción y muestra stock global + por sucursal en la page de detalle de producto.
- **Lazy init con stock negativo**: Si un usuario vende desde una sucursal sin haber cargado stock allí, `branch_stock.quantity` queda en negativo (la RPC debe validar stock >= cantidad antes de vender). Mitigación: misma lógica de `Insufficient stock` que existe hoy en la RPC de venta.
- **Migration scope**: No hay migration de datos (branch_stock empieza vacío). Riesgo bajo. El usuario entiende que debe hacer un ajuste inicial.

## Migration Plan

1. Aplicar migration SQL (`npx supabase db push`):
   - CREATE TABLE `branch_stock`
   - UNIQUE(product_id, branch_id)
   - RLS: mismo patrón que `branches` (account_id scope)
   - Función trigger `check_branch_low_stock`
   - `rpc_transfer_stock`
   - `rpc_adjust_branch_stock`
   - Modificar `rpc_create_sale_operation` y `rpc_create_purchase_operation`: rama condicional por `p_branch_id`

2. Frontend: nueva page `/sucursales/:id/stock`

3. Rollback: DROP TABLE branch_stock; restaurar RPCs desde 20260607000003.

## Open Questions

- ¿Debe mostrarse el stock de branch en la card de producto del inventario global, o solo en `/sucursales/:id/stock`? → Decisión UI, no bloqueante para el backend. Default: solo en la page de sucursal.
- ¿El reporte de sucursal (`/reportes/sucursal`) ya existente en C-07 debe incluir columna de stock actual de la sucursal? → Fuera de scope C-08 para no acoplar specs; se puede agregar en C-09 o C-14.
