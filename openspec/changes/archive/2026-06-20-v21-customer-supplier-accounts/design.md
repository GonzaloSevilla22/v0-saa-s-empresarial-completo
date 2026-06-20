## Context

C-30 es el **último change del roadmap V2** (Fase 7, 5/5). Construye las cuentas corrientes (cuentas por cobrar/pagar) que el código real no tiene y que es la funcionalidad más pedida por las PyMEs (modelo V2 §5.5). Todas las piezas que orquesta ya están en producción:

- **Helpers de tenancy** (`supabase/migrations/20260606000001_tenant_tables.sql`, `20260606010000_roles_internos.sql`):
  - `public.current_account_ids()` → `SETOF uuid`, `SECURITY DEFINER STABLE`. El patrón RLS **debe** ser `account_id IN (SELECT public.current_account_ids())` — **nunca** `= ANY(...)` (función SETOF → `0A000 set-returning functions not allowed in WHERE`). [gotcha #4]
  - `public.is_account_writer(p_account_id uuid)` → `boolean` (TRUE si owner/admin). Guard de escritura dentro de los RPCs `SECURITY DEFINER`. [gotcha #5]
  - `public.c26_default_branch(account_id)` → resuelve la branch default.
- **Helper de caja C-28** (`supabase/migrations/20260701000001_c28_cash_session.sql`): `public.c28_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id)` — `LANGUAGE plpgsql`, `SET search_path = public`, **NO** `SECURITY DEFINER` pero **REVOKE de PUBLIC** (solo callable desde RPCs `SECURITY DEFINER`), **no abre transacción propia**, `SELECT ... FOR UPDATE` sobre la fila de sesión para serializar, calcula `balance_after = COALESCE(MAX(cm.balance_after), opening_balance) + p_amount`, INSERT append-only en `cash_movements`, RETURN id. `cash_movements` tiene RLS **solo SELECT** (append-only, sin UPDATE/DELETE) vía cadena de FKs. **Este es el molde exacto** de `c30_register_*_account_movement`. [gotchas #1, #4]
- **Hot path de venta C-29** (`supabase/migrations/20260702000001_c29_quote_salesorder.sql`): el núcleo transaccional es el helper interno `public._c29_confirm_order_core(p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid, p_comprobante_type text, p_point_of_sale_id uuid, p_canal text)` (`SECURITY DEFINER`, REVOKE de todos los roles). `rpc_confirm_sales_order` y `rpc_quick_sale` son wrappers finos sobre él. Detalles del punto de integración en D4.
- **Idempotencia (DEC-06)**: `operation_idempotency` UNIQUE `(user_id, operation_kind, idempotency_key)`, `user_id` NOT NULL; patrón `INSERT ... ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS ROW_COUNT` → replay si 0. [gotcha #3]
- **Outbox (C-25 activo, DEC-20)**: `events` (columnas `account_id, event_type, aggregate_type, aggregate_id, payload jsonb, occurred_at, processed_at`) + `rpc_process_outbox_dispatch`. INSERT en la misma transacción. [gotcha #7]
- **Flujo de compras**: NO existe `PurchaseOrder.receive()`. Las compras postean de inmediato vía `rpc_create_purchase_operation(idempotency_key, date, description, items_jsonb)` (`backend/repositories/purchase_repository.py`). `purchases` **no tiene `supplier_id`**. `suppliers` existe (stub con `account_id` + RLS). Ver OQ-3 y D7.

El backend FastAPI sigue 3 capas (routers→services→repositories), JWT-passthrough (RLS activa como red de seguridad), **nunca `service_role`**. El molde directo: C-28 (`services/cash.py`, `repositories/cash_session_repository.py`, `routers/cash.py`) y C-29 (`services/sales_orders.py`, `repositories/sale_order_repository.py`, `routers/sales_orders.py`), más `services/clients.py` / `repositories/client_repository.py`.

**Última migración en disco**: `20260719000001_c27_cae_relay_trigger.sql`. La nueva debe datarse **estrictamente por encima** → `20260720000001_c30_customer_supplier_accounts.sql`. [gotcha #6]

## Goals / Non-Goals

**Goals:**
- `CustomerAccount` con ledger append-only `customer_account_movements` (`balance_after` por movimiento, patrón `stock_movements`/`cash_movements`).
- `SupplierAccount` simétrico con `supplier_account_movements`.
- `PaymentReceived` (cobro) y `PaymentMade` (pago) que generan el movimiento del ledger correspondiente y reducen/ajustan el saldo, idempotentes (DEC-06).
- Integración **transaccional** de venta a crédito con `SalesOrder.confirm()` (C-29): `payment_method = 'credit'` postea un cargo en el `CustomerAccount` en el mismo commit (sin movimiento de caja).
- Helpers intra-transacción `c30_register_customer_account_movement` / `c30_register_supplier_account_movement` (espejo de `c28_register_cash_movement`).
- Backend FastAPI completo (routers/services/repositories/schemas) + tests TDD.
- UI `/clientes/[id]/cuenta` y `/proveedores/[id]/cuenta` (saldo, historial, registrar cobro/pago).

**Non-Goals:**
- Percepciones/retenciones AFIP, `BankReconciliation`, `JournalEntry` (todos → V2.5).
- Notas de crédito/débito **fiscales** reales (la emisión es C-27; aquí `credit_note`/`debit_note` son solo tipos de movimiento del ledger).
- Interés por mora / vencimientos automáticos.
- Bloqueo duro de venta por `credit_limit` dentro de `confirm()` (ver OQ-2; default: persistir el límite, no gatear en este change).
- Auto-integración compra→cta cte de proveedor dentro de `rpc_create_purchase_operation` (ver OQ-3; default: cargos/pagos manuales en C-30).
- Tocar el webhook de pagos de MercadoPago (dinero real de pasarela; `PaymentReceived`/`PaymentMade` son cobros/pagos manuales de cta cte).

## Decisions

### D1 — Saldo materializado en la cabecera + ledger append-only con `balance_after` (NO sumar el ledger en el hot path)

**Decisión**: cada agregado tiene una **cabecera** (`customer_accounts` / `supplier_accounts`) con una columna `balance numeric(15,2) NOT NULL DEFAULT 0` materializada, y un **ledger append-only** (`*_account_movements`) donde **cada movimiento guarda su `balance_after`**. El helper intra-tx computa `balance_after` a partir del saldo corriente y actualiza la cabecera, todo bajo `SELECT ... FOR UPDATE` sobre la fila de la cabecera. [gotcha #1]

**Mecánica (gotcha #2 — el incidente 23514 de C-26)**: el saldo se acumula con **UPDATE-then-INSERT bajo `FOR UPDATE`**, **nunca** con `INSERT VALUES(delta) ON CONFLICT DO UPDATE`. Postgres valida la fila PROPUESTA en el INSERT antes de resolver el conflicto, de modo que un `ON CONFLICT DO UPDATE` sobre una tabla con CHECK (p.ej. si se añadiera `CHECK (balance >= 0)`) dispararía `23514` contra la fila intermedia. El flujo es:
1. `SELECT * FROM customer_accounts WHERE id = p_account_id FOR UPDATE` (lock + lee `balance` corriente).
2. `v_balance_after := v_account.balance + p_amount`.
3. `INSERT INTO customer_account_movements (..., balance_after) VALUES (..., v_balance_after)`.
4. `UPDATE customer_accounts SET balance = v_balance_after WHERE id = p_account_id`.

**Por qué materializar el saldo en la cabecera además del `balance_after` del último movimiento**: el modelo V2 §2.5/§5.5 modela `CustomerAccount.balance` como atributo del root ("el agregado mantiene el saldo materializado dentro de su propia transacción"). El `FOR UPDATE` va sobre la fila de cabecera (existe una sola por cuenta) — más barato y robusto que `SELECT MAX(balance_after) ... FOR UPDATE` sobre el ledger (que no lockea filas futuras). C-28 computa desde `MAX(cm.balance_after)` porque su "cabecera" es la `cash_session` y ahí lockea; aquí la cabecera natural es `customer_accounts`. **No se recomputa el saldo sumando el ledger en el hot path** (gotcha #1): el saldo corriente sale de la cabecera lockeada.

**OQ-1 RESUELTO (PO 2026-06-20) — Invariante `balance >= 0` siempre**: el helper aplica explícitamente `IF v_balance_after < 0 THEN RAISE EXCEPTION 'overpayment' USING ERRCODE = 'P0409'` antes del INSERT del movimiento. Adicionalmente, la columna `balance` en la tabla de cabecera lleva `CHECK (balance >= 0)` como backstop de red de seguridad. La mecánica UPDATE-then-INSERT bajo `FOR UPDATE` (D1, gotcha #2) evita el `23514` que dispararía `ON CONFLICT DO UPDATE`. Esto aplica simétricamente a `supplier_accounts`.

**Alternativa descartada**: solo ledger sin columna `balance` materializada, recomputando `SUM(amount)` o `MAX(balance_after)` en cada lectura. Rechazada: el `FOR UPDATE` sobre la cabecera es la forma natural de serializar, y la UI de saldo (`/clientes/[id]/cuenta`) lee `balance` directo sin agregación.

### D2 — Helpers intra-transacción `c30_register_*_account_movement` (espejo exacto de `c28_register_cash_movement`)

**Decisión**: dos helpers (uno por agregado, ver D3 sobre por qué dos y no uno parametrizado):
```
public.c30_register_customer_account_movement(
  p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL
) RETURNS uuid

public.c30_register_supplier_account_movement(
  p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL
) RETURNS uuid
```
Ambos: `LANGUAGE plpgsql`, `SET search_path = public`, **REVOKE de PUBLIC** (solo callable desde RPCs `SECURITY DEFINER` de este módulo o de C-29), **NO abren transacción propia** (corren en la del llamador), `SELECT ... FOR UPDATE` sobre la fila de cabecera para serializar (D1), validan el `movement_type` contra el dominio del agregado, calculan `balance_after`, INSERT append-only en el ledger con `created_by = auth.uid()`, UPDATE de `balance` en la cabecera, RETURN el id del movimiento. Idéntica forma y contrato que `c28_register_cash_movement`. [gotchas #1, #2]

**Por qué intra-transacción y REVOKE de PUBLIC**: para que `_c29_confirm_order_core` (que es `SECURITY DEFINER`) pueda invocar `c30_register_customer_account_movement` **dentro del mismo commit** que el descuento de stock — exactamente como hoy invoca `c28_register_cash_movement`. Un movimiento posteado por el helper se revierte con el resto si algo posterior falla.

### D3 — Dos helpers separados, no uno parametrizado por tipo de cuenta

**Decisión**: helper de cliente y helper de proveedor **separados**, no `c30_register_account_movement(p_kind text, ...)`.

**Por qué (KISS + SRP, python-design-patterns)**: aunque la mecánica es idéntica (lock + balance_after + insert + update), las dos tablas de ledger tienen **CHECK de `movement_type` distintos** (`sale|payment_received|credit_note|adjustment` vs `purchase|payment_made|debit_note|adjustment`), FKs a tablas distintas (`customer_accounts` vs `supplier_accounts`) y semántica de negocio distinta (cobrar vs pagar). Un helper parametrizado obligaría a un `IF p_kind = 'customer' THEN ... ELSE ...` con ramas divergentes sobre tablas distintas — más complejo de leer y un único punto donde un bug afecta ambos dominios. La duplicación aquí es ~25 líneas de plpgsql idénticas en estructura; el costo de la abstracción supera el beneficio (regla del 3: solo hay 2 instancias). C-28 tiene un único `cash_movements`, así que no hay precedente de helper parametrizado. **Trade-off aceptado**: si en V2.5 aparece un tercer ledger de cuenta con la misma forma, reconsiderar extraer.

### D4 — Integración EXACTA con `_c29_confirm_order_core` (el cambio caliente)

`SalesOrder.confirm()` gana el cobro a crédito modificando el helper interno de C-29. **Cuatro cambios precisos** sobre `supabase/migrations/20260702000001_c29_quote_salesorder.sql`, todos vía `CREATE OR REPLACE` / `ALTER` en la migración nueva de C-30:

1. **ALTER del CHECK de `sales_orders.payment_method`** (hoy línea 177-178: `text NOT NULL DEFAULT 'other' CHECK (payment_method IN ('cash','other'))`):
   ```sql
   ALTER TABLE public.sales_orders DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check;
   ALTER TABLE public.sales_orders ADD CONSTRAINT sales_orders_payment_method_check
     CHECK (payment_method IN ('cash','other','credit'));
   ```
2. **Validación de `payment_method`** dentro de `_c29_confirm_order_core` (hoy línea ~421: `IF p_payment_method NOT IN ('cash','other') THEN RAISE ... P0400`): añadir `'credit'`:
   ```sql
   IF p_payment_method NOT IN ('cash', 'other', 'credit') THEN ... P0400
   ```
3. **Bloque de crédito** análogo al bloque de caja. Hoy (líneas 552-559) tras el loop de ítems:
   ```sql
   IF p_payment_method = 'cash' THEN
     PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total, 'sale', p_sales_order_id);
   END IF;
   ```
   C-30 añade, en el mismo lugar (después del descuento de stock, alrededor del INSERT al outbox):
   ```sql
   IF p_payment_method = 'credit' THEN
     -- resolver/crear la CustomerAccount del cliente (OQ-4: lazy auto-create)
     IF v_order.client_id IS NULL THEN
       RAISE EXCEPTION 'credit_requires_client' USING ERRCODE = 'P0400';
     END IF;
     v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, v_order.client_id);
     PERFORM public.c30_register_customer_account_movement(
       v_customer_account_id, v_total, 'sale', p_sales_order_id);
     -- OQ-6 (default sí): evento CustomerAccountCharged al outbox, mismo commit
   END IF;
   ```
   La idempotencia es la **heredada de C-29** (el bloque entero está bajo la misma `operation_idempotency` con `operation_kind='sale'`; en un replay no se re-postea el cargo). No hace falta clave separada.
4. **Update del gate (a) de C-29**. La migración de C-29 (líneas 794-808) tiene un gate que INSERTa `payment_method='credit'` y **espera un `check_violation`**. Con C-30 ese INSERT ya **no** viola el CHECK. C-30 **no puede dejar ese gate roto**: la migración de C-30 incluye, en su propio DO-block de gates, la aserción **inversa** — que `payment_method='credit'` ahora es **aceptado** por el CHECK (un INSERT mínimo con `credit` ya no lanza `check_violation`), revirtiéndolo con ROLLBACK. (El gate original en la migración de C-29 ya corrió en prod y no se re-ejecuta; el contrato se actualiza en la migración nueva y en el delta spec de `sales-order`.)

`CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(...)` reescribe la función completa con la misma firma (es `SECURITY DEFINER` y puede llamar helpers REVOKE-ados). Hay que **declarar la variable nueva** `v_customer_account_id uuid;` en el `DECLARE`. Los wrappers `rpc_confirm_sales_order`/`rpc_quick_sale` **no cambian** (la firma del core es estable).

### D5 — RLS por tabla: SELECT vía `account_id` desnormalizado; escritura por RPC vs repo directo (mirror C-29 D2/D3)

Decisión **por tabla** sobre si la escritura va por RPC `SECURITY DEFINER` (RLS solo SELECT) o por INSERT directo del repo (necesita policy INSERT/UPDATE — bug #3 de C-28). [gotcha #4]

| Tabla | `account_id` | Escritura | Policies RLS |
|---|---|---|---|
| `customer_accounts` | columna directa (FK→accounts) | **RPC** (`c30_get_or_create_customer_account`, helper actualiza `balance`) | SELECT (`account_id IN (SELECT current_account_ids())`) |
| `customer_account_movements` | **desnormalizado** (mirror `sale_items.account_id`) | **RPC** (helper intra-tx) | SELECT solo — **append-only, sin UPDATE/DELETE** (mirror `cash_movements`) |
| `supplier_accounts` | columna directa | **RPC** | SELECT |
| `supplier_account_movements` | desnormalizado | **RPC** | SELECT solo — append-only |
| `payments_received` | columna directa | **RPC** (`rpc_register_payment_received`) | SELECT |
| `payments_made` | columna directa | **RPC** (`rpc_register_payment_made`) | SELECT |

**Por qué todo por RPC (RLS solo SELECT)**: a diferencia de `quotes`/`quote_items` de C-29 (CRUD comercial sin invariantes caras → INSERT directo, D3 de C-29), **todas** las escrituras de C-30 tocan el saldo materializado bajo `FOR UPDATE` (D1) — son hot path con invariante de balance. Igual que `sales_orders`/`sales_order_items` de C-29 (D2 de C-29), van **exclusivamente por RPC `SECURITY DEFINER`** con guard `is_account_writer` explícito. Por lo tanto **ninguna** de las 6 tablas necesita policy INSERT/UPDATE. Los `*_movements` desnormalizan `account_id` para que la RLS SELECT sea directa (`account_id IN (SELECT current_account_ids())`), igual que `sale_items.account_id` y `sales_order_items.account_id`.

**Índices**: `customer_accounts (account_id, client_id) UNIQUE` (una cuenta por cliente, habilita el `ON CONFLICT` de OQ-4); `customer_account_movements (customer_account_id, created_at)` (historial paginado); `account_id` indexado en cada `*_movements` (RLS performance — supabase-postgres `security-rls-performance`). Simétrico para supplier.

### D6 — RPCs `SECURITY DEFINER` para el camino directo del usuario

- `c30_get_or_create_customer_account(p_account_id uuid, p_client_id uuid) RETURNS uuid` — interno (REVOKE de PUBLIC), `INSERT INTO customer_accounts (...) ON CONFLICT (account_id, client_id) DO NOTHING; SELECT id ...` (OQ-4 lazy auto-create). Simétrico para supplier.
- `rpc_create_customer_account(p_client_id uuid) RETURNS jsonb` / `rpc_create_supplier_account(p_supplier_id uuid)` — camino explícito de creación (público, guard `is_account_writer`).
- `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL) RETURNS jsonb` — resuelve/crea la cuenta, valida idempotencia (`operation_kind='payment_received'`, OQ-5), invoca `c30_register_customer_account_movement(account, -p_amount, 'payment_received', payment_id)` (signo negativo: el cobro reduce la deuda, OQ-1), inserta la fila `payments_received`, emite `PaymentReceived` al outbox (OQ-6 default). `rpc_register_payment_made` simétrico (`operation_kind='payment_made'`).
- Todos: `REVOKE ALL FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated`, mirror C-28/C-29.

**Por qué guards en el RPC y no solo RLS**: los RPCs `SECURITY DEFINER` bypassan RLS, así que el guard `is_account_writer(account_id)` se aplica **explícitamente** dentro del cuerpo, igual que C-28/C-29. [gotcha #5]

### D7 — Integración de proveedores: cargos/pagos manuales (OQ-3 default = opción B)

**Decisión (default, pendiente PO)**: en C-30, la cta cte de proveedor se alimenta vía comandos **explícitos** (`rpc_register_supplier_charge` para una compra a crédito cargada aparte, y `rpc_register_payment_made` para el pago), **sin** tocar `rpc_create_purchase_operation` ni agregar `supplier_id` a `purchases`. Razón: el flujo de compras postea de inmediato y `purchases` no tiene `supplier_id` (ver OQ-3 con citas de código); la opción A (auto-integración) requiere modelar `supplier_id` en compras y modificar la RPC de compras — más blast radius del que justifica la gobernanza MEDIO de este change. La opción B entrega saldo + historial + pagos (el 80% del valor) y deja A como follow-up.

### D8 — Custom ERRCODEs (5 chars — `backend/core/errors.py`) [gotcha #5]

Mapeo a HTTP por `backend/core/errors.py`: P0400→400, P0401→403, P0403→403, P0404→404, P0409→409, P0422→422. **Los códigos custom DEBEN ser de 5 chars** (4-char degradan a 42704).

| Falla | ERRCODE | HTTP |
|---|---|---|
| Sin permiso de escritura (`is_account_writer` false) | `P0401` | 403 |
| Sin cuenta activa (`current_account_ids` vacío) | `P0403` | 403 |
| Cliente/proveedor/cuenta no encontrado | `P0404` | 404 |
| Sobre-cobro / sobre-pago no marcado como anticipo (OQ-1) | `P0409` | 409 |
| Venta a crédito sin `client_id` | `P0400` | 400 |
| `movement_type` inválido (red de seguridad; el CHECK lo cubre) | `P0422` | 422 |
| `amount` ≤ 0 en cobro/pago | `P0400` | 400 |

### D9 — Backend FastAPI 3 capas + Pydantic v2 (reglas duras del proyecto)

Schemas Pydantic v2 (`CustomerAccountOut`, `AccountMovementOut`, `PaymentReceivedIn/Out`, `SupplierAccountOut`, `PaymentMadeIn/Out`) validan todo payload antes de tocar DB; enums para `movement_type`. Repositories invocan los RPCs vía `SELECT rpc_...(...)` con JWT-passthrough. Services llevan los guards `require_role(auth, ["user","admin"])` — **nunca en el router ni en el repository**. Routers solo validación + DI. Molde directo: `routers/cash.py` → `services/cash.py` → `repositories/cash_session_repository.py`. TS sin `any`; componentes React en PascalCase. (python-design-patterns: SRP por capa; fastapi-templates: DI vía `Depends`.)

### D10 — UI App Router: `/clientes/[id]/cuenta` y `/proveedores/[id]/cuenta`

Rutas dinámicas bajo `frontend/app/(dashboard)/`. `clientes` hoy es `frontend/app/(dashboard)/clientes/page.tsx` (no hay subruta `[id]`); hay que crear `clientes/[id]/cuenta/page.tsx`. **`proveedores` es greenfield** — no existe ninguna ruta; hay que crear el árbol `proveedores/[id]/cuenta/page.tsx`. Patrón (nextjs-app-router-patterns): la `page.tsx` puede ser Server Component que lee el saldo inicial; los componentes interactivos (formulario "registrar cobro", tabla de historial paginado) son Client Components con hooks React Query (`useCustomerAccount`, `useRegisterPayment`). No pasar datos no-serializables por el borde server→client. Saldo actual desde `customer_accounts.balance`; historial desde `customer_account_movements` paginado por `(account_id, created_at)`.

## Risks / Trade-offs

- **[Modificar `_c29_confirm_order_core` rompe el hot path de ventas]** → Es el riesgo mayor (toca el agregado más caliente del sistema). Mitigación: `CREATE OR REPLACE` con la **misma firma**; los cambios son aditivos (un branch `IF credit` nuevo + un valor más en el CHECK); el camino `cash`/`other` queda byte-idéntico. El smoke transaccional en prod (BEGIN…RAISE→ROLLBACK) verifica que `cash` y `other` siguen funcionando y que `credit` postea el movimiento. Gobernanza MEDIO con checkpoints.
- **[Gate (a) de C-29 roto por el ALTER del CHECK]** → La migración de C-30 incluye la aserción inversa (credit ahora aceptado) en su DO-block; el delta spec de `sales-order` documenta el contrato actualizado. Sin esto, una re-corrida del gate de C-29 fallaría.
- **[23514 al acumular saldo]** (gotcha #2, incidente C-26) → **UPDATE-then-INSERT bajo `FOR UPDATE`**, nunca `ON CONFLICT DO UPDATE` con delta. D1.
- **[RLS con función SETOF]** (gotcha #4) → `account_id IN (SELECT current_account_ids())`, nunca `= ANY`. Gate en code review + smoke.
- **[Escrituras denegadas por falta de policy]** (bug #3 C-28) → Todas las escrituras van por RPC `SECURITY DEFINER` (RLS solo SELECT); decisión consciente documentada en la migración (D5).
- **[Doble-cobro por reintento de red]** → Idempotencia DEC-06 con `operation_kind` propios (OQ-5). Test de replay.
- **[Saldo negativo / sobre-cobro]** → OQ-1 sin resolver por defecto; el default permite saldo a favor con marca de anticipo y bloquea el sobre-cobro no marcado con `P0409`. **Pendiente PO** antes del apply de esa rama.
- **[Cta cte de proveedor sin auto-integración]** → OQ-3 default = manual (B); entrega el valor núcleo, deja A como follow-up. **Pendiente PO**.
- **[Concurrencia: lock sobre la cabecera de la cuenta serializa cobros del mismo cliente]** → Aceptado: los cobros del mismo cliente son raros y el lock es corto (sin HTTP/IA/AFIP dentro; supabase-postgres `lock-short-transactions`). Cobros de clientes distintos no se bloquean entre sí (lock por fila).
- **[Migración mal datada]** (gotcha #6) → `20260720000001` > `20260719000001` (último en disco). Verificado.

## Migration Plan

1. **Migración SQL** `20260720000001_c30_customer_supplier_accounts.sql`:
   - 6 tablas (`customer_accounts`, `customer_account_movements`, `supplier_accounts`, `supplier_account_movements`, `payments_received`, `payments_made`) + índices + RLS (SELECT en las 6; sin INSERT/UPDATE — escritura por RPC, D5).
   - 2 helpers intra-tx `c30_register_customer_account_movement` / `c30_register_supplier_account_movement` (REVOKE de PUBLIC, D2).
   - `c30_get_or_create_customer_account` / `..._supplier_account` (REVOKE de PUBLIC, D6/OQ-4).
   - RPCs `SECURITY DEFINER`: `rpc_create_customer_account`, `rpc_create_supplier_account`, `rpc_register_payment_received`, `rpc_register_payment_made`, `rpc_register_supplier_charge` (D6/D7). REVOKE de PUBLIC,anon + GRANT EXECUTE a authenticated.
   - **ALTER del CHECK de `sales_orders.payment_method`** (+`'credit'`) + **`CREATE OR REPLACE` de `_c29_confirm_order_core`** con el bloque de crédito (D4).
   - (OQ-2 default) `ALTER TABLE clients ADD COLUMN IF NOT EXISTS credit_limit numeric(15,2)` — solo dato, sin gate.
   - DO-block de gates SQL (RED→GREEN, patrón C-28 §1.9 / C-29 §3.4) con ROLLBACK total: CHECK de `movement_type` de cada ledger; **credit ahora aceptado** por `sales_orders` (gate inverso de C-29); helper acumula `balance_after` correcto; sobre-cobro → P0409.
2. **Backend FastAPI**: schemas → repositories → services → routers; registrar en `main.py`. TDD (pytest + pytest-asyncio desde la raíz del repo: `python -m pytest backend/tests`), mocks de asyncpg como en `test_purchases.py`/`test_sale_items.py`.
3. **Frontend**: rutas `/clientes/[id]/cuenta` y `/proveedores/[id]/cuenta` (greenfield) + hooks React Query; vitest (`npm test`, nunca jest).
4. **CI** aplica la migración (`npx supabase db push`, **nunca** MCP `apply_migration`) y deploya en el merge a `main`.
5. **Smoke transaccional en prod** (BEGIN…RAISE→ROLLBACK contra `gxdhpxvdjjkmxhdkkwyb`): crear CustomerAccount; venta a crédito → cargo con `balance_after` correcto; cobro → saldo baja; `cash`/`other` siguen funcionando (regresión de C-29); SupplierAccount espeja. Gate de validación clave.

**Rollback**: `DROP FUNCTION` de los RPCs/helpers de C-30 + `CREATE OR REPLACE` de `_c29_confirm_order_core` a la versión C-29 + revertir el CHECK de `payment_method` a `('cash','other')` + `DROP TABLE` de las 6 tablas (orden inverso de FKs). Sin pérdida de datos: feature nueva, 0 filas en prod.

## Open Questions — TODAS RESUELTAS (PO 2026-06-20)

Las 6 OQ están resueltas. Ver `proposal.md` §Open Questions para el detalle de cada resolución.
- **OQ-1 RESUELTO**: `balance >= 0` siempre; sobrepago → P0409.
- **OQ-2 RESUELTO**: `credit_limit` nullable, sin gate en C-30.
- **OQ-3 RESUELTO**: proveedores con cargos/pagos manuales (opción B).
- **OQ-4 RESUELTO**: lazy auto-create idempotente.
- **OQ-5 RESUELTO**: `operation_kind` propios (`payment_received`/`payment_made`/`supplier_charge`) con `user_id` real.
- **OQ-6 RESUELTO**: eventos emitidos en el mismo commit; AuditLog consumer en C-25 es genérico (procesa todos los `event_type`).
