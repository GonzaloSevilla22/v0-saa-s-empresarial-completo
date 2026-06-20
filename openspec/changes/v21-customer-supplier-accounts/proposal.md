## Why

Hoy el sistema registra ventas y compras al contado, pero **no tiene cuenta corriente** — la funcionalidad más pedida por las PyMEs (modelo V2 §5.5: "que el código real no tiene y es la funcionalidad más pedida"). Una venta a crédito (factura emitida ≠ cobrada) no tiene dónde acumular el saldo deudor del cliente, ni el cobro parcial/total que lo cancela; lo mismo para lo que se le debe a un proveedor. C-29 dejó explícitamente `payment_method = credit` **diferido a C-30** (`sales_orders.payment_method CHECK (... IN ('cash','other'))`, OQ-2 de C-29): una venta a crédito no puede confirmarse hoy. C-30 cierra ese hueco y es el **último change del roadmap V2** (Fase 7, 5/5).

El modelo V2 (DEC-18, §3.5, §5.5) reemplaza `Receivable`/`Payable` del v1 por los agregados **`CustomerAccount`** y **`SupplierAccount`**: un ledger de cuenta corriente append-only con `balance_after` por movimiento — el mismo patrón que `stock_movements` (C-21) y `cash_movements` (C-28), "más simple de operar y auditar que CQRS" (§2.5). Con C-29 (SalesOrder.confirm transaccional) y C-28 (helper intra-transacción de caja) ya en producción, están dadas todas las piezas para enchufar el cobro a crédito en el mismo hot path.

## What Changes

- **Nuevo agregado `CustomerAccount`** (tablas `customer_accounts` + `customer_account_movements`): cuenta corriente del cliente. El ledger es **append-only** con `balance_after` por movimiento; `movement_type ∈ {sale, payment_received, credit_note, adjustment}`. Una cuenta por `(account_id, client_id)`.
- **Nuevo agregado `SupplierAccount`** (tablas `supplier_accounts` + `supplier_account_movements`): simétrico para proveedores; `movement_type ∈ {purchase, payment_made, debit_note, adjustment}`. Una cuenta por `(account_id, supplier_id)`.
- **`PaymentReceived`** (tabla `payments_received`): cobro parcial/total de un cliente; cada cobro genera un `customer_account_movement` de tipo `payment_received` que reduce el saldo. **`PaymentMade`** (tabla `payments_made`): pago a un proveedor; simétrico.
- **Integración con `SalesOrder.confirm()` (C-29)** — **el cambio caliente**:
  - **ALTER** del CHECK de `sales_orders.payment_method` para agregar `'credit'`.
  - `CREATE OR REPLACE` del helper interno `public._c29_confirm_order_core(...)`: se añade `'credit'` a la validación de `payment_method` (línea ~421) y un **bloque de crédito** análogo al bloque de caja: `IF p_payment_method = 'credit' THEN PERFORM public.c30_register_customer_account_movement(<customer_account>, +v_total, 'sale', p_sales_order_id); END IF;` — en la **misma transacción/commit**, después del descuento de stock, alrededor del INSERT al outbox. Hereda la idempotencia de C-29 (sin clave separada).
  - **Update del gate (a)** de la migración de C-29 (que hoy asevera que `payment_method='credit'` es rechazado por el CHECK): pasa a verificar que `'credit'` es **aceptado**.
- **Nuevo helper intra-transacción `public.c30_register_customer_account_movement` / `..._supplier_account_movement`** (espejo exacto de `c28_register_cash_movement`): `SET search_path = public`, `REVOKE` de PUBLIC, NO abre transacción propia, `SELECT ... FOR UPDATE` sobre la fila de la cuenta para serializar, calcula `balance_after` a partir del balance corriente (NO sumando el ledger en el hot path), INSERT append-only, RETURN id.
- **RPCs `SECURITY DEFINER`** para el camino directo del usuario: crear/habilitar cuenta corriente, registrar `PaymentReceived` (cobro) y `PaymentMade` (pago), con guard `is_account_writer` y ERRCODEs de 5 chars.
- **Backend FastAPI** (3 capas): `routers/customer_accounts.py` + `routers/supplier_accounts.py`, `services/...`, `repositories/...`, schemas Pydantic v2 — espejo de `cash.py` / `sales_orders.py` / `clients.py`. JWT-passthrough, nunca `service_role`.
- **Frontend** (App Router): nuevas rutas `/clientes/[id]/cuenta` (saldo actual, historial, registrar cobro) y `/proveedores/[id]/cuenta` (simétrica — **proveedores es greenfield**, no existe ninguna ruta hoy).
- Tests obligatorios (TDD): crear `CustomerAccount`; confirmar venta a crédito → `customer_account_movement` con `balance_after` correcto; registrar cobro → saldo disminuye; invariante de balance; `SupplierAccount` espeja.

> **No-goals**: percepciones/retenciones AFIP, conciliación bancaria (`BankReconciliation` → V2.5), asientos contables (`JournalEntry` → V2.5), interés por mora, notas de crédito/débito fiscales reales (aquí `credit_note`/`debit_note` son solo tipos de movimiento del ledger; la emisión fiscal de la NC es de C-27). Migración de ventas legacy a cta cte (las históricas quedan donde están). No se toca el webhook de pagos de MercadoPago (dinero real de pasarela) — `PaymentReceived`/`PaymentMade` son cobros/pagos manuales de cta cte, no de la pasarela.

## Capabilities

### New Capabilities
- `customer-account`: cuenta corriente del cliente. Ledger append-only `customer_account_movements` con `balance_after`; tipos `sale|payment_received|credit_note|adjustment`; helper intra-transacción `c30_register_customer_account_movement`; integración con `SalesOrder.confirm()` para ventas a crédito (en el mismo commit); `PaymentReceived` (cobro) que reduce el saldo.
- `supplier-account`: cuenta corriente del proveedor, simétrica. Ledger `supplier_account_movements` con `balance_after`; tipos `purchase|payment_made|debit_note|adjustment`; helper `c30_register_supplier_account_movement`; `PaymentMade` (pago).

### Modified Capabilities
- `sales-order`: `SalesOrder.confirm()` gana un cuarto efecto transaccional — si `payment_method = 'credit'`, postea un `customer_account_movement` (cargo) en lugar de un movimiento de caja, en el mismo commit. El `payment_method` admitido pasa de `{cash, other}` a `{cash, other, credit}`.

## Impact

- **DB (Supabase `gxdhpxvdjjkmxhdkkwyb`)**: migración nueva `20260720000001_c30_customer_supplier_accounts.sql` (timestamp **estrictamente mayor** que el último en disco `20260719000001`). 6 tablas (`customer_accounts`, `customer_account_movements`, `supplier_accounts`, `supplier_account_movements`, `payments_received`, `payments_made`) + RLS + 2 helpers intra-tx + RPCs `SECURITY DEFINER` + ERRCODEs 5-char + **ALTER del CHECK de `sales_orders.payment_method`** + `CREATE OR REPLACE` de `_c29_confirm_order_core` con el bloque de crédito + update del gate (a) de C-29. Reusa: `current_account_ids`, `is_account_writer`, `c26_default_branch`, `operation_idempotency`, `events`.
- **Backend FastAPI**: 2 routers, 2+ services, 2+ repositories, schemas; registrar routers en `main.py`. JWT-passthrough, sin `service_role`.
- **Frontend**: 2 rutas nuevas (`/clientes/[id]/cuenta`, `/proveedores/[id]/cuenta`) + hooks React Query. `proveedores` es greenfield (hay que crear el árbol de ruta).
- **CI/CD**: `.github/workflows/deploy.yml` aplica la migración y deploya en el merge a `main`. Smoke transaccional en prod (BEGIN…RAISE→ROLLBACK) como gate.
- **Cierra el roadmap V2**: C-30 es el último change (Fase 7, 5/5). Gobernanza **MEDIO** (lógica de cta cte; toca el hot path de C-29 pero reusando el patrón de helper aprobado de C-28; no toca dinero real de la pasarela).

## Open Questions — TODAS RESUELTAS POR EL PO (2026-06-20)

### OQ-1 — RESUELTO: Saldo del cliente NUNCA negativo (rechaza sobrepago)
**Resolución del PO**: convención deudora. `sale`/`credit_note` (cargo) → `amount` positivo, sube el saldo (deuda); `payment_received` → `amount` negativo, baja el saldo. **Invariante: `balance_after >= 0` SIEMPRE**. Si un movimiento llevaría el saldo por debajo de 0 (p.ej. cobro mayor a lo adeudado) → `RAISE` con ERRCODE **`P0409`** y mensaje claro (overpayment). Implementar: (a) guard explícito en el helper (`nuevo_saldo < 0` → P0409) Y (b) `CHECK (balance >= 0)` como backstop en la tabla. **NO** usar `INSERT VALUES(delta) ON CONFLICT DO UPDATE` — gotcha #2 viola el CHECK en fase INSERT; usar **UPDATE-then-INSERT** con `SELECT ... FOR UPDATE` sobre el header de la cuenta.

### OQ-2 — RESUELTO (default aplicado): `credit_limit` columna nullable, sin gate
`credit_limit` nullable en `customer_accounts` (NULL = sin límite). Almacenar pero **NO** gatear `confirm()` con ella en C-30 — bloqueo duro queda como follow-up.

### OQ-3 — RESUELTO (default aplicado): Proveedores con cargos/pagos MANUALES
**NO** tocar `rpc_create_purchase_operation` ni agregar `supplier_id` a `purchases`. Los `supplier_account_movements` (`purchase`/`debit_note`) y `payments_made` se crean vía RPCs dedicados desde la UI `/proveedores/:id/cuenta`. El saldo de proveedor espeja la misma invariante `>= 0` con P0409.

### OQ-4 — RESUELTO (default aplicado): Auto-creación lazy e idempotente
La cuenta corriente del cliente se auto-crea lazy e idempotente (`FOR UPDATE` / `ON CONFLICT DO NOTHING`) en la primera venta a crédito o primer movimiento manual. Sin toggle explícito.

### OQ-5 — RESUELTO (default aplicado): Idempotencia con `operation_kind` propios
Nuevo `operation_kind` en `operation_idempotency` para cobros (`payment_received`) y pagos (`payment_made`/`supplier_charge`), con `user_id` real del operador (no sentinel). Las ventas a crédito heredan la idempotencia existente de C-29.

### OQ-6 — RESUELTO (default aplicado): Outbox en el mismo commit
Los movimientos de cuenta y los pagos emiten eventos al outbox (`events`) en el MISMO commit (patrón productor C-25). El `rpc_process_outbox_dispatch` de C-25 tiene un consumer genérico AuditLog que procesa CUALQUIER `event_type` (el INSERT en `audit_logs` es incondicional — no requiere que el `event_type` esté en un allowlist). Los nuevos tipos `CustomerAccountCharged`, `PaymentReceived`, `PaymentMade`, `SupplierAccountCharged` serán procesados por el AuditLog; el consumer de EmailNotification los ignorará (ya que no están en su `IN (...)` allowlist actual). **No queda ningún evento `pending` sin consumer**.
