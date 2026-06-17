## Why

Hoy una venta se registra con `rpc_create_sale_operation` (header `sales` + `sale_items` + descuento de `branch_stock` en la misma transacción), pero el modelo de dominio V2 (DEC-17, §3.3, §5.5) define un flujo comercial completo que el esquema todavía no tiene: **`Quote`** (presupuesto que vence, sin compromiso de stock) → **`SalesOrder`** (orden que compromete stock al confirmar) → comprobante fiscal + cobro. El presupuesto es la herramienta de venta número uno en servicios y B2B, y la orden de venta es el agregado donde, en V2.1, deben converger en **una sola transacción** el descuento de stock, el movimiento de caja (helper C-28 ya en prod), la numeración fiscal (C-27 ya en prod) y el INSERT al outbox (DEC-20).

Con C-20 (sale_items live), C-26 (branch-as-root), C-27 (FiscalProfile/DocumentSequence) y C-28 (CashSession + helper intra-tx) ya cerrados, están dadas todas las piezas para construir el hot path comercial. C-29 las orquesta y desbloquea C-30 (cuentas corrientes).

## What Changes

- **Nuevo agregado `Quote`** (tablas `quotes` + `quote_items`): cotización con ciclo de vida `draft → sent → accepted | expired | rejected`. No toca stock. `Quote.accept()` materializa un `SalesOrder` con los mismos ítems.
- **Nuevo agregado `SalesOrder`** (tablas `sales_orders` + `sales_order_items`): orden de venta con `confirm()` **transaccional** vía un único RPC `SECURITY DEFINER` que en la misma transacción:
  1. valida y descuenta `branch_stock` por cada ítem (gate per-branch + invariante `onHand ≥ 0` de C-26),
  2. invoca el helper intra-transacción `c28_register_cash_movement` si el pago es en efectivo (sesión de caja abierta),
  3. reserva número fiscal vía la maquinaria de C-27 (`rpc_emit_pending_cae` / `DocumentSequence`) si la operación factura,
  4. hace `INSERT` en el outbox (`events`) con el hecho `SaleConfirmed`.
- **Comando `quickSale()` (POS)**: crea y confirma un `SalesOrder` en un único paso/llamada y una sola pantalla (comprime las etapas del dominio sin eliminarlas — §3.3). Idempotente vía `idempotency_key` (DEC-06).
- **Retrocompatibilidad con `sales` legacy**: las ventas históricas (tabla `sales` + `sale_items`) siguen accesibles para lectura y para los endpoints existentes; `SalesOrder.confirm()` también escribe la fila `sales`/`sale_items` correspondiente (o una vista puente) para no romper listados, reportes ni Edge Functions de IA durante la transición.
- **Backend FastAPI** (3 capas): nuevos `routers/quotes.py` + `routers/sales_orders.py`, `services/quotes.py` + `services/sales_orders.py` (guards `require_role`), `repositories` que invocan los RPCs vía JWT-passthrough; schemas Pydantic v2.
- **Frontend** (mínimo, opcional en el scope de apply): hooks React Query para Quote/SalesOrder/quickSale; el POS reusa el formulario de venta existente.
- Tests obligatorios (TDD): `quickSale()` de 2 uds → `branch_stock` −2; venta con stock 0 → error "stock insuficiente" (P0409); `Quote.accept()` → `SalesOrder` con mismos ítems; `SalesOrder.confirm()` que falla a mitad → **rollback total** (cero efectos parciales en stock, caja, numeración, outbox).

> **No-goals**: cuentas corrientes / cobro a crédito (eso es C-30); el consumer del outbox (C-25 outbox-activation — C-29 solo hace el INSERT, no depende de consumers activos); migración de las ventas legacy a `sales_orders` (las nuevas se crean ahí; las viejas quedan donde están — RN-97: ninguna feature nueva sobre tablas en retirada, pero `sales` no se retira en C-29).

## Capabilities

### New Capabilities
- `quote`: presupuesto con ciclo de vida (`draft`/`sent`/`accept`/`expire`/`reject`), `quote_items` referenciando productos, y `accept()` que crea un `SalesOrder`. Sin efectos sobre stock ni caja.
- `sales-order`: orden de venta con `confirm()` transaccional (stock + caja + numeración fiscal + outbox en un commit), `quickSale()` POS, e idempotencia per DEC-06.

### Modified Capabilities
- `sale-line-items`: el ledger de ventas suma una nueva ruta de escritura (`SalesOrder.confirm()` produce filas `sales`/`sale_items` para retrocompat); el contrato de "una venta confirmada descuenta `branch_stock` atómicamente" se conserva y se extiende al nuevo agregado.
- `data-api-endpoints`: nuevos endpoints REST de Quote y SalesOrder/quickSale en el backend FastAPI.

## Impact

- **DB (Supabase `gxdhpxvdjjkmxhdkkwyb`)**: migración SQL nueva (timestamp por encima de `20260701000002`) con tablas `quotes`, `quote_items`, `sales_orders`, `sales_order_items` + RLS + RPCs `SECURITY DEFINER` (`rpc_confirm_sales_order`, `rpc_quick_sale`, `rpc_accept_quote`, y CRUD de Quote). Reusa: `c28_register_cash_movement`, `c21_apply_branch_stock_delta`, `c26_default_branch`, `rpc_emit_pending_cae` / `rpc_next_document_number`, `operation_idempotency`, tabla `events`.
- **Backend FastAPI**: 2 routers, 2 services, 2–4 repositories, schemas; registrar routers en `main.py`. JWT-passthrough, sin `service_role`.
- **Frontend**: hooks + (opcional) pantalla POS y de presupuestos. No rompe la UI de ventas actual.
- **CI/CD**: `.github/workflows/deploy.yml` aplica la migración y deploya en el merge a `main`. Smoke transaccional en prod (BEGIN…RAISE→ROLLBACK) como gate de validación.
- **Desbloquea**: C-30 v21-customer-supplier-accounts.
- **Governance**: MEDIO (lógica de ventas/stock; el cobro en efectivo toca caja pero reusa el helper aprobado de C-28; no toca el webhook de pagos ni dinero real de AFIP en el hot path — el CAE es asíncrono).
