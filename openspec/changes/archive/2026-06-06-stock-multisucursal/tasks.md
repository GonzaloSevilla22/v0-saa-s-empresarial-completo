## 1. Migración SQL — tabla branch_stock y RPCs

- [x] 1.1 Crear tabla `branch_stock` (`id`, `account_id`, `product_id`, `branch_id`, `quantity NUMERIC(15,4) DEFAULT 0`, `min_stock INTEGER DEFAULT 0`), UNIQUE(product_id, branch_id), FK a branches y products con ON DELETE CASCADE
- [x] 1.2 Crear índices: `(account_id, branch_id)` y `(product_id, branch_id)` en branch_stock
- [x] 1.3 Habilitar RLS en branch_stock: SELECT/INSERT/UPDATE solo para miembros de la cuenta (`account_id IN (SELECT account_id FROM account_members WHERE user_id = auth.uid())`)
- [x] 1.4 Modificar `rpc_create_sale_operation`: cuando `p_branch_id IS NOT NULL`, decrementar `branch_stock.quantity` (UPSERT lazy init) en lugar de `products.stock`; validar `branch_stock.quantity >= v_qty_norm` antes de decrementar
- [x] 1.5 Modificar `rpc_create_purchase_operation`: cuando `p_branch_id IS NOT NULL`, incrementar `branch_stock.quantity` (UPSERT lazy init) en lugar de `products.stock`
- [x] 1.6 Crear función `rpc_transfer_stock(p_product_id UUID, p_from_branch_id UUID, p_to_branch_id UUID, p_quantity NUMERIC)`: SELECT FOR UPDATE en ambas filas de branch_stock, validar stock suficiente en origen, validar `from != to`, validar que ambas branches pertenecen a la misma cuenta, INSERT dos stock_movements (`transfer_out` / `transfer_in`), UPDATE branch_stock origen y UPSERT branch_stock destino — todo atómico; solo owner/admin pueden ejecutar
- [x] 1.7 Crear función `rpc_adjust_branch_stock(p_product_id UUID, p_branch_id UUID, p_new_quantity NUMERIC, p_reason TEXT)`: UPSERT en branch_stock, INSERT stock_movement tipo `adjustment` con delta calculado; solo owner/admin
- [x] 1.8 Crear trigger `check_branch_low_stock` sobre UPDATE de `branch_stock`: si `NEW.quantity <= NEW.min_stock` e `NEW.quantity < OLD.quantity`, INSERT en email_logs con deduplicación 24h por `(product_id, branch_id)`
- [x] 1.9 Aplicar migración con `npx supabase db push` y verificar que no hay errores

## 2. Tipos TypeScript

- [x] 2.1 Agregar tipo `BranchStock` en `lib/types.ts`: `{ id: string; account_id: string; product_id: string; branch_id: string; quantity: number; min_stock: number }`
- [x] 2.2 Agregar tipos de retorno para `rpc_transfer_stock` y `rpc_adjust_branch_stock`

## 3. Servicios y hooks

- [x] 3.1 Crear `hooks/data/use-branch-stock.ts`: funciones `useBranchStock(branchId)`, `useAdjustBranchStock()`, `useTransferStock()` — cada una llama a la RPC correspondiente vía Supabase client
- [x] 3.2 Crear hook `useBranchStock(branchId)` en `hooks/data/`: fetch de `branch_stock` filtrado por `branch_id`, refetch tras mutaciones

## 4. Página /sucursales/:id/stock

- [x] 4.1 Crear page `app/(dashboard)/sucursales/[id]/stock/page.tsx` con PlanGate para plan PRO
- [x] 4.2 Crear componente `BranchStockTable`: tabla con columnas Producto, Stock actual, Stock mínimo, Acciones (Ajustar, Transferir); datos de `useBranchStock`
- [x] 4.3 Crear `AdjustStockModal`: formulario con campo cantidad nueva y razón; llama a `adjustBranchStock`; muestra error de la RPC si falla
- [x] 4.4 Crear `TransferStockModal`: dropdown de sucursal destino (sucursales activas de la cuenta, excluye la actual), campo cantidad; llama a `transferStock`; muestra error si stock insuficiente
- [x] 4.5 Invalidar queries de `branchStock` y `stockMovements` tras cada mutación (ajuste o transferencia)

## 5. Actualizar página de sucursales

- [x] 5.1 Agregar botón/link "Ver stock" en `/sucursales/:id` que navega a `/sucursales/:id/stock`
- [x] 5.2 Agregar contador de productos con stock asignado en la card de cada sucursal en `/sucursales` (query a branch_stock agrupado por branch_id)

## 6. Tests

- [x] 6.1 Test SQL (pgTAP o SQL directo): venta con branch_id reduce branch_stock y NO toca products.stock
- [x] 6.2 Test SQL: venta con branch_id falla si branch_stock insuficiente
- [x] 6.3 Test SQL: compra con branch_id incrementa branch_stock (lazy init desde 0)
- [x] 6.4 Test SQL: `rpc_transfer_stock` exitoso — branch A pierde N unidades, branch B gana N, dos stock_movements insertados
- [x] 6.5 Test SQL: `rpc_transfer_stock` falla si stock insuficiente en origen — no modifica ninguna fila
- [x] 6.6 Test SQL: `rpc_adjust_branch_stock` — branch_stock actualizado, stock_movement de tipo adjustment insertado
- [x] 6.7 Test SQL: member no puede llamar a rpc_transfer_stock ni rpc_adjust_branch_stock
