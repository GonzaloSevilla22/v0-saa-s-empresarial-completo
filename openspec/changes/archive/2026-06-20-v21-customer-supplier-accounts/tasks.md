> **Bloqueo previo al apply**: OQ-1 (signo/invariante de saldo, ¿saldo a favor permitido?) y OQ-3 (integración de proveedores: A automática vs B manual) tocan invariantes de negocio / alcance — esperar sign-off del PO antes de implementar esas ramas. OQ-2/OQ-4/OQ-5/OQ-6 tienen default de bajo riesgo aplicable si el PO no objeta. Defaults documentados en `proposal.md`.

## 1. Preparación y datado de la migración

- [x] 1.1 Ejecutar `ls supabase/migrations | sort | tail -1` y confirmar el último timestamp en disco (`20260719000001_c27_cae_relay_trigger.sql`). Datar la nueva migración **estrictamente por encima**: `20260720000001_c30_customer_supplier_accounts.sql`. Crearla con `supabase migration new` o a mano con ese nombre exacto (NUNCA MCP `apply_migration` — desincroniza el history).
- [x] 1.2 Releer las fuentes de verdad antes de escribir SQL: `modelo-dominio-aliadata-v2.md` §2.5/§3.5/§5.5/§5.8/§5.9, `knowledge-base/09` DEC-06/DEC-18/DEC-20, RN-97 en `knowledge-base/05` (confirmar que `clients`/`suppliers`/`sales` NO están en retirada). Confirmar firmas reales de `c28_register_cash_movement`, `current_account_ids`, `is_account_writer`, `c26_default_branch`, y el cuerpo exacto de `_c29_confirm_order_core` en `20260702000001_c29_quote_salesorder.sql`.

## 2. Migración SQL — schema de las 6 tablas (RED para la capa DB)

- [x] 2.1 Crear `customer_accounts` (`id`, `account_id` FK→accounts ON DELETE CASCADE, `client_id` FK→clients ON DELETE CASCADE, `balance numeric(15,2) NOT NULL DEFAULT 0`, `created_by` FK→auth.users, `created_at timestamptz NOT NULL DEFAULT now()`) + `UNIQUE (account_id, client_id)` (habilita el `ON CONFLICT` de auto-create, OQ-4) + índice `(account_id)` (RLS perf).
- [x] 2.2 Crear `customer_account_movements` (`id`, `customer_account_id` FK→customer_accounts ON DELETE CASCADE, `account_id` **desnormalizado** FK→accounts, `amount numeric(15,2) NOT NULL`, `balance_after numeric(15,2) NOT NULL`, `movement_type text NOT NULL CHECK (movement_type IN ('sale','payment_received','credit_note','adjustment'))`, `reference_id uuid`, `created_by` FK→auth.users NOT NULL, `created_at timestamptz NOT NULL DEFAULT now()`) + índices `(customer_account_id, created_at)` y `(account_id)`.
- [x] 2.3 Crear `supplier_accounts` (espejo de 2.1 con `supplier_id` FK→suppliers; `UNIQUE (account_id, supplier_id)`).
- [x] 2.4 Crear `supplier_account_movements` (espejo de 2.2 con `supplier_account_id` FK→supplier_accounts; `CHECK (movement_type IN ('purchase','payment_made','debit_note','adjustment'))`).
- [x] 2.5 Crear `payments_received` (`id`, `account_id` FK→accounts, `customer_account_id` FK→customer_accounts, `client_id` FK→clients, `amount numeric(15,2) NOT NULL CHECK (amount > 0)`, `reference_sale_id uuid`, `movement_id uuid` FK→customer_account_movements, `created_by` NOT NULL, `created_at timestamptz NOT NULL DEFAULT now()`) + índice `(account_id, created_at)`.
- [x] 2.6 Crear `payments_made` (espejo de 2.5 con `supplier_account_id`, `supplier_id`, `reference_purchase_id`, FK→supplier_account_movements).
- [x] 2.7 (OQ-2 default — solo dato, sin gate) `ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS credit_limit numeric(15,2)` (NULL = sin límite). No usar en `confirm()` en este change.

## 3. Migración SQL — RLS (gotcha #4)

- [x] 3.1 `ENABLE ROW LEVEL SECURITY` en las 6 tablas. Política **SELECT** en las 6 con `account_id IN (SELECT public.current_account_ids())` (NUNCA `= ANY(...)` — función SETOF → 0A000).
- [x] 3.2 **NO** crear políticas INSERT/UPDATE/DELETE en ninguna de las 6 (escritura solo por RPC `SECURITY DEFINER`, D5). Los `*_movements` son append-only (sin UPDATE/DELETE), mirror `cash_movements`. Documentar en comentario de la migración que la ausencia de policy de escritura es deliberada (evita reincidir en el bug #3 de C-28: una tabla escrita por repo directo SÍ necesitaría policy).

## 4. Migración SQL — helpers intra-transacción (GREEN, gotchas #1, #2) — TDD por DO-block

- [x] 4.1 RED (gate): escribir, en el DO-block de gates (§7), la aserción de que `customer_account_movements.movement_type='foo'` viola el CHECK, y la de que insertar directo como rol no-definer es rechazado por RLS (append-only). Verificar que el gate falla antes de crear el helper.
- [x] 4.2 GREEN: `public.c30_register_customer_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL) RETURNS uuid` — `LANGUAGE plpgsql`, `SET search_path = public`, NO SECURITY DEFINER, **REVOKE ALL ... FROM PUBLIC**. Mecánica espejo de `c28_register_cash_movement` pero con cabecera `customer_accounts`: `SELECT * INTO v_acc FROM customer_accounts WHERE id = p_account_id FOR UPDATE` (404 si no existe → P0404); `v_balance_after := v_acc.balance + p_amount`; INSERT append-only en `customer_account_movements` (`account_id = v_acc.account_id`, `created_by = auth.uid()`, `balance_after = v_balance_after`); **UPDATE customer_accounts SET balance = v_balance_after WHERE id = p_account_id** (UPDATE-then-INSERT, NUNCA `ON CONFLICT DO UPDATE` con delta — gotcha #2); RETURN id.
- [x] 4.3 GREEN: `public.c30_register_supplier_account_movement(...)` — espejo exacto de 4.2 con `supplier_accounts`/`supplier_account_movements`. REVOKE de PUBLIC.
- [x] 4.4 GREEN: `public.c30_get_or_create_customer_account(p_account_id uuid, p_client_id uuid) RETURNS uuid` — REVOKE de PUBLIC; `INSERT INTO customer_accounts (account_id, client_id, balance, created_by) VALUES (..., 0, auth.uid()) ON CONFLICT (account_id, client_id) DO NOTHING; SELECT id INTO ... FROM customer_accounts WHERE account_id=p_account_id AND client_id=p_client_id` (lazy auto-create idempotente, OQ-4). Espejo `c30_get_or_create_supplier_account`.
- [x] 4.5 TRIANGULATE (gate): en el DO-block, verificar que dos movimientos sucesivos sobre la misma cuenta acumulan `balance_after` correcto (`+1000` luego `−400` → `balance_after` 1000 y 600; cabecera 600).

## 5. Migración SQL — RPCs SECURITY DEFINER de cta cte (GREEN, gotcha #5)

- [x] 5.1 `rpc_create_customer_account(p_client_id uuid) RETURNS jsonb` — resolver `account_id` vía `current_account_ids()` (P0403 si vacío); guard `is_account_writer` (P0401); validar cliente existe en la cuenta (P0404); llamar `c30_get_or_create_customer_account`; RETURN `{customer_account_id, client_id, balance}`. REVOKE de PUBLIC,anon + GRANT a authenticated. Espejo `rpc_create_supplier_account`.
- [x] 5.2 `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL) RETURNS jsonb` — guard `is_account_writer` (P0401); `amount > 0` (P0400); idempotencia DEC-06 `operation_kind='payment_received'` (`ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS` → replay si 0, OQ-5); `c30_get_or_create_customer_account`; **(OQ-1, pendiente PO)** si `p_amount > balance` y no se marca anticipo → P0409 overpayment; `PERFORM c30_register_customer_account_movement(account, -p_amount, 'payment_received', v_payment_id)` (signo negativo reduce deuda, OQ-1); INSERT en `payments_received`; (OQ-6 default) INSERT `events` `PaymentReceived` mismo commit; RETURN `{payment_id, customer_account_id, balance_after, replayed}`. REVOKE/GRANT.
- [x] 5.3 `rpc_register_payment_made(p_idempotency_key, p_supplier_id, p_amount, p_reference_purchase_id DEFAULT NULL)` — espejo de 5.2 (`operation_kind='payment_made'`, `payments_made`, evento `PaymentMade`).
- [x] 5.4 `rpc_register_supplier_charge(p_idempotency_key, p_supplier_id, p_amount, p_reference_id DEFAULT NULL)` — (OQ-3 default = B) postea movimiento `purchase` (amount positivo) en la `SupplierAccount`; idempotencia `operation_kind='supplier_charge'`; guard `is_account_writer`. REVOKE/GRANT. **NO** tocar `rpc_create_purchase_operation`.

## 6. Migración SQL — integración con C-29 `_c29_confirm_order_core` (el cambio caliente, D4)

- [x] 6.1 **ALTER del CHECK de `sales_orders.payment_method`**: `ALTER TABLE public.sales_orders DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check; ALTER TABLE public.sales_orders ADD CONSTRAINT sales_orders_payment_method_check CHECK (payment_method IN ('cash','other','credit'));`
- [x] 6.2 **`CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(...)`** con la **misma firma** (`text, uuid, text, uuid, text, uuid, text`). Copiar el cuerpo actual de la migración de C-29 y aplicar SOLO estos cambios aditivos:
  - Declarar `v_customer_account_id uuid;` en el `DECLARE`.
  - En la validación de `payment_method` (hoy `IF p_payment_method NOT IN ('cash','other') THEN ... P0400`): cambiar a `IF p_payment_method NOT IN ('cash','other','credit') THEN ... P0400`.
  - Tras el bloque de caja (`IF p_payment_method = 'cash' THEN PERFORM c28_register_cash_movement(...)`), añadir el **bloque de crédito**: `IF p_payment_method = 'credit' THEN` → si `v_order.client_id IS NULL` → P0400 `credit_requires_client`; `v_customer_account_id := c30_get_or_create_customer_account(v_account_id, v_order.client_id)`; `PERFORM c30_register_customer_account_movement(v_customer_account_id, v_total, 'sale', p_sales_order_id)` (cargo positivo, en el mismo commit, sin movimiento de caja); (OQ-6 default) INSERT `events` `CustomerAccountCharged` mismo commit. `END IF;`
  - Mantener `SECURITY DEFINER`, `SET search_path = public`, REVOKE de PUBLIC,anon,authenticated. La idempotencia es la heredada (el bloque entero corre bajo el claim `operation_kind='sale'`; en replay no se re-postea).
- [x] 6.3 **NO** modificar `rpc_confirm_sales_order` ni `rpc_quick_sale` (la firma del core es estable; los wrappers no cambian).

## 7. Migración SQL — gates DO-block + encabezado (RED→GREEN, patrón C-28 §1.9 / C-29 §3.4)

- [x] 7.1 DO-block con SAVEPOINTs y ROLLBACK total al final: (a) CHECK `movement_type` de `customer_account_movements` rechaza `'foo'`; (b) CHECK `movement_type` de `supplier_account_movements` rechaza `'sale'`; (c) **gate inverso de C-29**: insertar `sales_orders` con `payment_method='credit'` ahora **NO** viola el CHECK (revierte la expectativa del gate (a) de la migración de C-29); (d) `amount <= 0` en `payments_received` viola el CHECK; (e) (si se accede a un helper aislado) `balance_after` acumula correcto. Cada gate con RAISE NOTICE de resultado.
- [x] 7.2 Encabezado de migración con CHANGE / ERRCODEs (P0400/P0401/P0403/P0404/P0409 — 5 chars, gotcha #5) / GOVERNANCE MEDIO / APPLY (`npx supabase db push`, NUNCA MCP) / ROLLBACK (CREATE OR REPLACE de `_c29_confirm_order_core` a la versión C-29 + revertir CHECK de `payment_method` a `('cash','other')` + DROP de los RPCs/helpers de C-30 + DROP de las 6 tablas en orden inverso de FKs; sin pérdida de datos, feature nueva 0 filas) + bloque VERIFICATION post-push.

## 8. Backend FastAPI — schemas (Pydantic v2, D9)

- [x] 8.1 `backend/schemas/customer_accounts.py`: enum `CustomerMovementType` (`sale|payment_received|credit_note|adjustment`), `CustomerAccountOut` (incl. `balance`), `AccountMovementOut` (`amount`, `balance_after`, `movement_type`, `reference_id`, `created_at`), `PaymentReceivedIn` (`amount > 0`, `client_id`, `idempotency_key`, `reference_sale_id` opcional), `PaymentReceivedOut`. Sin `any`.
- [x] 8.2 `backend/schemas/supplier_accounts.py`: espejo — enum `SupplierMovementType` (`purchase|payment_made|debit_note|adjustment`), `SupplierAccountOut`, `PaymentMadeIn/Out`, `SupplierChargeIn/Out`.

## 9. Backend FastAPI — repositories (TDD: test primero, mock asyncpg)

- [x] 9.1 RED: `backend/tests/test_c30_customer_supplier_accounts.py` (correr desde la raíz: `python -m pytest backend/tests/test_c30_customer_supplier_accounts.py`) — tests de repository verificando que cada método invoca el RPC correcto con los args correctos (patrón `test_purchases.py`/`test_sale_items.py`): `register_payment_received`→`rpc_register_payment_received`, `register_payment_made`→`rpc_register_payment_made`, `create_customer_account`→`rpc_create_customer_account`, `register_supplier_charge`→`rpc_register_supplier_charge`; `get_account`/`list_movements` vía SELECT.
- [x] 9.2 GREEN: `backend/repositories/customer_account_repository.py` y `backend/repositories/supplier_account_repository.py` (heredar de `BaseRepository`; mutaciones vía `SELECT rpc_...(...)`, lecturas de saldo/historial vía SELECT con paginación por `(account_id, created_at)`). JWT-passthrough.

## 10. Backend FastAPI — services (TDD)

- [x] 10.1 RED: tests de service — `register_payment_received` con rol insuficiente → 403; propaga P0409 overpayment como 409; happy path devuelve `balance_after`; `amount <= 0` → 400.
- [x] 10.2 GREEN: `backend/services/customer_accounts.py` y `backend/services/supplier_accounts.py` con `require_role(auth, ["user","admin"])` (guards SOLO en el service, NUNCA en routers ni repositories), mapeo de payload y manejo de `HTTPException` vía `backend/core/errors.py`.

## 11. Backend FastAPI — routers (TDD)

- [x] 11.1 RED: tests de endpoint HTTP (async_client) — `POST /customer-accounts` 201; `GET /clientes/{client_id}/cuenta` (saldo+historial); `POST /customer-accounts/payments` (cobro); simétrico proveedores; token member → 403 en escritura.
- [x] 11.2 GREEN: `backend/routers/customer_accounts.py` y `backend/routers/supplier_accounts.py` (validación + DI únicamente, patrón `routers/cash.py`); registrar ambos en `backend/main.py`.
- [x] 11.3 TRIANGULATE: caso idempotencia (doble cobro misma key → `replayed=true`, sin duplicar el movimiento); caso saldo a favor / overpayment (OQ-1, según resolución del PO).

## 12. Integración venta a crédito con C-29 (test del cambio caliente)

- [x] 12.1 RED→GREEN: test que confirma una `SalesOrder` con `payment_method='credit'` y `client_id` → genera `customer_account_movement` de tipo `sale` con `balance_after = total`, `customer_accounts.balance = total`, y **ningún** `cash_movements`. (Smoke transaccional BEGIN…RAISE→ROLLBACK contra prod, o test de repo con mock que verifica el RPC.)
- [x] 12.2 Test de regresión C-29: `payment_method='cash'` y `'other'` siguen funcionando idénticos tras el `CREATE OR REPLACE` del core (cash → `cash_movements`; other → ni caja ni cta cte).
- [x] 12.3 Test: venta a crédito sin `client_id` → P0400 antes de tocar stock; venta a crédito de cliente sin `CustomerAccount` → la crea (lazy) y postea el cargo.
- [x] 12.4 Test invariante de balance: una venta a crédito de `total` seguido de un cobro de `total` → `customer_accounts.balance = 0` con dos movimientos (`sale +total`, `payment_received −total`).

## 13. Frontend — rutas App Router (D10, TDD vitest)

- [x] 13.1 `frontend/app/(dashboard)/clientes/[id]/cuenta/page.tsx` — Server Component que lee el saldo inicial; sub-componentes Client (PascalCase): `CustomerAccountBalance`, `CustomerAccountHistory` (tabla paginada de `customer_account_movements`), `RegisterPaymentForm` (registrar cobro). Hooks React Query `useCustomerAccount(clientId)`, `useRegisterPayment()`.
- [x] 13.2 `frontend/app/(dashboard)/proveedores/[id]/cuenta/page.tsx` — **greenfield** (crear el árbol `proveedores/`): simétrico — `SupplierAccountBalance`, `SupplierAccountHistory`, `RegisterPaymentMadeForm`.
- [x] 13.3 Tests vitest (`npm test`, NUNCA jest): render del saldo; submit del form de cobro llama al hook con el payload correcto; la lista de movimientos muestra `amount`/`balance_after`. Sin `any` en TS.

## 14. Validación y cierre

- [x] 14.1 `openspec validate v21-customer-supplier-accounts --strict` PASA.
- [x] 14.2 Backend: `python -m pytest backend/tests` verde (incl. los nuevos + sin regresión de C-29). Frontend: `npm test` verde.
- [x] 14.3 Smoke transaccional en prod (`gxdhpxvdjjkmxhdkkwyb`, BEGIN…RAISE→ROLLBACK): crear CustomerAccount; venta a crédito → cargo con `balance_after` correcto; cobro → saldo baja; `cash`/`other` siguen funcionando; SupplierAccount espeja.
- [x] 14.4 Merge a `main` (PR; CI aplica la migración vía `npx supabase db push` y deploya). Marcar [x] C-30 en `CHANGES.md` y cerrar el roadmap V2 (Fase 7, 5/5). — PR #199 mergeado 2026-06-20.
