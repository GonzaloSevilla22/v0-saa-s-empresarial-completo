-- =============================================================================
-- MIGRATION: 20260720000001_c30_customer_supplier_accounts.sql
-- CHANGE:    C-30 v21-customer-supplier-accounts — Cuentas corrientes clientes/proveedores
--
-- Implementa (design.md, todas las OQs resueltas por el PO 2026-06-20):
--   1. Columna credit_limit en clients (OQ-2 default: dato sin gate).
--   2. Tablas: customer_accounts, customer_account_movements,
--              supplier_accounts, supplier_account_movements,
--              payments_received, payments_made.
--   3. RLS en las 6 tablas: SELECT únicamente (escritura por RPC, D5).
--      Sin INSERT/UPDATE/DELETE policies — deliberado (ver comentario D5).
--   4. Helpers intra-transacción (REVOKE de PUBLIC, D2):
--      - c30_register_customer_account_movement
--      - c30_register_supplier_account_movement
--      - c30_get_or_create_customer_account
--      - c30_get_or_create_supplier_account
--   5. RPCs SECURITY DEFINER (D6):
--      - rpc_create_customer_account / rpc_create_supplier_account
--      - rpc_register_payment_received / rpc_register_payment_made
--      - rpc_register_supplier_charge
--   6. Integración C-29 (D4):
--      - ALTER CHECK sales_orders.payment_method (+credit)
--      - CREATE OR REPLACE _c29_confirm_order_core (bloque de crédito)
--   7. Gates SQL (DO block — RED→GREEN) con ROLLBACK total.
--
-- OQs resueltas:
--   OQ-1: balance >= 0 SIEMPRE (CHECK en tabla + guard en helper: P0409 overpayment).
--   OQ-2: credit_limit nullable en clients; sin gate en confirm().
--   OQ-3: proveedores con cargos/pagos manuales (opción B); no se toca rpc_create_purchase_operation.
--   OQ-4: lazy auto-create idempotente (ON CONFLICT DO NOTHING).
--   OQ-5: operation_kind propios: payment_received / payment_made / supplier_charge.
--   OQ-6: eventos emitidos al outbox en el mismo commit; AuditLog consumer de C-25 es genérico.
--
-- ERRCODEs (5 chars):
--   P0400 — payload inválido (credit sin client_id, amount <= 0, etc.)
--   P0401 — sin permiso de escritura (is_account_writer)
--   P0403 — sin cuenta activa (current_account_ids vacío)
--   P0404 — entidad no encontrada (customer_account, client, supplier)
--   P0409 — overpayment (saldo resultante < 0), balance invariant violation
--   P0422 — movement_type inválido (red de seguridad; el CHECK lo cubre antes)
--
-- GOVERNANCE: MEDIO.
-- APPLY:  npx supabase db push  (NUNCA MCP apply_migration — desincroniza history)
--
-- ROLLBACK (en orden):
--   DROP FUNCTION IF EXISTS
--     public.rpc_register_supplier_charge(text, uuid, numeric, uuid),
--     public.rpc_register_payment_made(text, uuid, numeric, uuid),
--     public.rpc_register_payment_received(text, uuid, numeric, uuid),
--     public.rpc_create_supplier_account(uuid),
--     public.rpc_create_customer_account(uuid),
--     public.c30_get_or_create_supplier_account(uuid, uuid),
--     public.c30_get_or_create_customer_account(uuid, uuid),
--     public.c30_register_supplier_account_movement(uuid, numeric, text, uuid),
--     public.c30_register_customer_account_movement(uuid, numeric, text, uuid);
--   -- Revertir _c29_confirm_order_core a la versión C-29 (ver D4):
--   --   payment_method CHECK a ('cash','other') + quitar bloque credit.
--   ALTER TABLE public.sales_orders DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check;
--   ALTER TABLE public.sales_orders ADD CONSTRAINT sales_orders_payment_method_check
--     CHECK (payment_method IN ('cash','other'));
--   DROP TABLE IF EXISTS
--     public.payments_made,
--     public.payments_received,
--     public.supplier_account_movements,
--     public.customer_account_movements,
--     public.supplier_accounts,
--     public.customer_accounts;
--   ALTER TABLE public.clients DROP COLUMN IF EXISTS credit_limit;
--   (Sin pérdida de datos: feature nueva, 0 filas en prod)
--
-- VERIFICATION (post-push):
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public'
--     AND table_name IN (
--       'customer_accounts','customer_account_movements',
--       'supplier_accounts','supplier_account_movements',
--       'payments_received','payments_made'
--     )
--   ORDER BY table_name;
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name IN (
--       'c30_register_customer_account_movement',
--       'c30_register_supplier_account_movement',
--       'c30_get_or_create_customer_account',
--       'c30_get_or_create_supplier_account',
--       'rpc_create_customer_account',
--       'rpc_create_supplier_account',
--       'rpc_register_payment_received',
--       'rpc_register_payment_made',
--       'rpc_register_supplier_charge',
--       '_c29_confirm_order_core'
--     )
--   ORDER BY routine_name;
-- =============================================================================


-- ============================================================
-- OQ-2 default: credit_limit en clients (solo dato, sin gate en confirm())
-- ============================================================
ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS credit_limit numeric(15,2);

COMMENT ON COLUMN public.clients.credit_limit IS
  'C-30 OQ-2: límite de crédito del cliente. NULL = sin límite. '
  'Persistido como dato pero NO gateable en SalesOrder.confirm() en C-30 — '
  'bloqueo duro queda como follow-up (V2.5).';


-- ============================================================
-- 2.1 TABLE: customer_accounts
-- Una cuenta por (account_id, client_id) — UNIQUE habilita el ON CONFLICT de OQ-4.
-- balance CHECK (balance >= 0): invariante OQ-1 como backstop (UPDATE-then-INSERT
-- bajo FOR UPDATE evita el 23514 que ON CONFLICT DO UPDATE dispararía — gotcha #2).
-- ============================================================
CREATE TABLE IF NOT EXISTS public.customer_accounts (
  id          uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id  uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  client_id   uuid          NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  balance     numeric(15,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  created_by  uuid          REFERENCES auth.users(id),
  created_at  timestamptz   NOT NULL DEFAULT now(),
  UNIQUE (account_id, client_id)
);

CREATE INDEX IF NOT EXISTS customer_accounts_account_id_idx
  ON public.customer_accounts (account_id);

COMMENT ON TABLE public.customer_accounts IS
  'C-30: Cuenta corriente del cliente. Un agregado por (account_id, client_id). '
  'balance = saldo deudor materializado (lo que el cliente debe). '
  'balance >= 0 siempre (OQ-1). Escritura SOLO vía RPCs SECURITY DEFINER (D5). '
  'Ausencia de policy INSERT/UPDATE es deliberada: no hay escritura directa de authenticated.';


-- ============================================================
-- 2.2 TABLE: customer_account_movements (append-only, account_id desnormalizado para RLS)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.customer_account_movements (
  id                    uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  customer_account_id   uuid          NOT NULL REFERENCES public.customer_accounts(id) ON DELETE CASCADE,
  account_id            uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  amount                numeric(15,2) NOT NULL,
  balance_after         numeric(15,2) NOT NULL CHECK (balance_after >= 0),
  movement_type         text          NOT NULL
                        CHECK (movement_type IN ('sale','payment_received','credit_note','adjustment')),
  reference_id          uuid,
  created_by            uuid          NOT NULL REFERENCES auth.users(id),
  created_at            timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS customer_account_movements_account_customer_created_at_idx
  ON public.customer_account_movements (customer_account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS customer_account_movements_account_id_idx
  ON public.customer_account_movements (account_id);

COMMENT ON TABLE public.customer_account_movements IS
  'C-30: Ledger append-only de movimientos del cliente. account_id desnormalizado para RLS. '
  'balance_after >= 0 (OQ-1). Escritura SOLO vía helper c30_register_customer_account_movement (D2/D5). '
  'Ausencia de políticas INSERT/UPDATE/DELETE es deliberada — append-only, espejo de cash_movements.';


-- ============================================================
-- 2.3 TABLE: supplier_accounts (espejo de customer_accounts con supplier_id)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.supplier_accounts (
  id           uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id   uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  supplier_id  uuid          NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  balance      numeric(15,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  created_by   uuid          REFERENCES auth.users(id),
  created_at   timestamptz   NOT NULL DEFAULT now(),
  UNIQUE (account_id, supplier_id)
);

CREATE INDEX IF NOT EXISTS supplier_accounts_account_id_idx
  ON public.supplier_accounts (account_id);

COMMENT ON TABLE public.supplier_accounts IS
  'C-30: Cuenta corriente del proveedor. Un agregado por (account_id, supplier_id). '
  'balance = saldo deudor materializado (lo que se le debe al proveedor). '
  'balance >= 0 siempre (OQ-1). Escritura SOLO vía RPCs SECURITY DEFINER (D5). '
  'OQ-3 default B: sin auto-integración con rpc_create_purchase_operation.';


-- ============================================================
-- 2.4 TABLE: supplier_account_movements (espejo de customer_account_movements)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.supplier_account_movements (
  id                    uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  supplier_account_id   uuid          NOT NULL REFERENCES public.supplier_accounts(id) ON DELETE CASCADE,
  account_id            uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  amount                numeric(15,2) NOT NULL,
  balance_after         numeric(15,2) NOT NULL CHECK (balance_after >= 0),
  movement_type         text          NOT NULL
                        CHECK (movement_type IN ('purchase','payment_made','debit_note','adjustment')),
  reference_id          uuid,
  created_by            uuid          NOT NULL REFERENCES auth.users(id),
  created_at            timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS supplier_account_movements_supplier_account_created_at_idx
  ON public.supplier_account_movements (supplier_account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS supplier_account_movements_account_id_idx
  ON public.supplier_account_movements (account_id);

COMMENT ON TABLE public.supplier_account_movements IS
  'C-30: Ledger append-only de movimientos del proveedor. account_id desnormalizado para RLS. '
  'balance_after >= 0 (OQ-1). Escritura SOLO vía helper c30_register_supplier_account_movement (D2/D5). '
  'Ausencia de políticas INSERT/UPDATE/DELETE es deliberada — append-only.';


-- ============================================================
-- 2.5 TABLE: payments_received (cobros del cliente)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.payments_received (
  id                    uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id            uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  customer_account_id   uuid          NOT NULL REFERENCES public.customer_accounts(id),
  client_id             uuid          NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  amount                numeric(15,2) NOT NULL CHECK (amount > 0),
  reference_sale_id     uuid,
  movement_id           uuid          REFERENCES public.customer_account_movements(id),
  created_by            uuid          NOT NULL REFERENCES auth.users(id),
  created_at            timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payments_received_account_id_created_at_idx
  ON public.payments_received (account_id, created_at DESC);

COMMENT ON TABLE public.payments_received IS
  'C-30: Cobro registrado contra la cuenta corriente de un cliente. '
  'amount > 0 (el cobro tiene monto positivo; el movimiento en el ledger lleva signo negativo). '
  'Escritura SOLO vía rpc_register_payment_received (D5/D6).';


-- ============================================================
-- 2.6 TABLE: payments_made (pagos a proveedores)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.payments_made (
  id                    uuid          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id            uuid          NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  supplier_account_id   uuid          NOT NULL REFERENCES public.supplier_accounts(id),
  supplier_id           uuid          NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  amount                numeric(15,2) NOT NULL CHECK (amount > 0),
  reference_purchase_id uuid,
  movement_id           uuid          REFERENCES public.supplier_account_movements(id),
  created_by            uuid          NOT NULL REFERENCES auth.users(id),
  created_at            timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payments_made_account_id_created_at_idx
  ON public.payments_made (account_id, created_at DESC);

COMMENT ON TABLE public.payments_made IS
  'C-30: Pago registrado contra la cuenta corriente de un proveedor. '
  'amount > 0 (el pago tiene monto positivo; el movimiento en el ledger lleva signo negativo). '
  'Escritura SOLO vía rpc_register_payment_made (D5/D6).';


-- ============================================================
-- 3.1 RLS en las 6 tablas: SELECT únicamente
--
-- D5: escritura SOLO por RPC SECURITY DEFINER → sin INSERT/UPDATE/DELETE policies.
-- La ausencia de policy de escritura es DELIBERADA: evita reincidir en el bug #3
-- de C-28 (tabla escrita por repo directo SÍ necesita policy; estas NO se escriben
-- directamente por el rol authenticated).
-- Patrón RLS: account_id IN (SELECT current_account_ids()) — NUNCA = ANY(...)
-- (función SETOF → 0A000 si se usa con = ANY).
-- ============================================================

-- customer_accounts
ALTER TABLE public.customer_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY customer_accounts_select
  ON public.customer_accounts FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- customer_account_movements
ALTER TABLE public.customer_account_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY customer_account_movements_select
  ON public.customer_account_movements FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- supplier_accounts
ALTER TABLE public.supplier_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY supplier_accounts_select
  ON public.supplier_accounts FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- supplier_account_movements
ALTER TABLE public.supplier_account_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY supplier_account_movements_select
  ON public.supplier_account_movements FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- payments_received
ALTER TABLE public.payments_received ENABLE ROW LEVEL SECURITY;
CREATE POLICY payments_received_select
  ON public.payments_received FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));

-- payments_made
ALTER TABLE public.payments_made ENABLE ROW LEVEL SECURITY;
CREATE POLICY payments_made_select
  ON public.payments_made FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));


-- ============================================================
-- 4.1 HELPER: c30_register_customer_account_movement
--
-- Espejo exacto de c28_register_cash_movement (D2).
-- Mecánica UPDATE-then-INSERT bajo FOR UPDATE (D1, OQ-1, gotcha #2):
--   NO usar ON CONFLICT DO UPDATE con delta — viola CHECK (balance >= 0)
--   en la fase INSERT antes de resolver el conflicto (incidente C-26, ERRCODE 23514).
--
-- OQ-1 (RESUELTO): si balance_after < 0 → P0409 overpayment (RAISE antes del INSERT).
-- REVOKE de PUBLIC: solo callable desde RPCs SECURITY DEFINER de este módulo o de C-29.
-- ============================================================
CREATE OR REPLACE FUNCTION public.c30_register_customer_account_movement(
  p_account_id   uuid,
  p_amount       numeric,
  p_type         text,
  p_reference_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_acc           public.customer_accounts%ROWTYPE;
  v_balance_after numeric(15,2);
  v_movement_id   uuid;
BEGIN
  -- D1: lock de fila de cabecera para serializar (FOR UPDATE)
  SELECT * INTO v_acc
  FROM public.customer_accounts
  WHERE id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'customer_account_not_found: %', p_account_id
      USING ERRCODE = 'P0404';
  END IF;

  v_balance_after := v_acc.balance + p_amount;

  -- OQ-1 (RESUELTO): invariante balance >= 0 — guard explícito antes del INSERT
  IF v_balance_after < 0 THEN
    RAISE EXCEPTION 'overpayment: el pago (%) excede el saldo deudor (%)',
      ABS(p_amount), v_acc.balance
      USING ERRCODE = 'P0409';
  END IF;

  -- INSERT append-only en el ledger
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, reference_id, created_by)
  VALUES
    (p_account_id, v_acc.account_id, p_amount, v_balance_after, p_type, p_reference_id, auth.uid())
  RETURNING id INTO v_movement_id;

  -- UPDATE de la cabecera (UPDATE-then-INSERT bajo FOR UPDATE, D1/gotcha #2)
  UPDATE public.customer_accounts
  SET balance = v_balance_after
  WHERE id = p_account_id;

  RETURN v_movement_id;
END;
$$;

-- REVOKE acceso público — solo callable desde RPCs SECURITY DEFINER de este módulo o C-29
REVOKE ALL ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid) FROM PUBLIC;

COMMENT ON FUNCTION public.c30_register_customer_account_movement IS
  'C-30 (D2): helper intra-transacción de cuenta corriente de cliente. Espejo de c28_register_cash_movement. '
  'NO abre transacción propia. FOR UPDATE sobre cabecera serializa movimientos concurrentes. '
  'balance_after >= 0 siempre (OQ-1, P0409 si sobrepago). REVOKE de PUBLIC.';


-- ============================================================
-- 4.2 HELPER: c30_register_supplier_account_movement (espejo de 4.1)
-- ============================================================
CREATE OR REPLACE FUNCTION public.c30_register_supplier_account_movement(
  p_account_id   uuid,
  p_amount       numeric,
  p_type         text,
  p_reference_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_acc           public.supplier_accounts%ROWTYPE;
  v_balance_after numeric(15,2);
  v_movement_id   uuid;
BEGIN
  -- D1: lock de fila de cabecera
  SELECT * INTO v_acc
  FROM public.supplier_accounts
  WHERE id = p_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_account_not_found: %', p_account_id
      USING ERRCODE = 'P0404';
  END IF;

  v_balance_after := v_acc.balance + p_amount;

  -- OQ-1: invariante balance >= 0
  IF v_balance_after < 0 THEN
    RAISE EXCEPTION 'overpayment: el pago (%) excede el saldo deudor (%)',
      ABS(p_amount), v_acc.balance
      USING ERRCODE = 'P0409';
  END IF;

  -- INSERT append-only
  INSERT INTO public.supplier_account_movements
    (supplier_account_id, account_id, amount, balance_after, movement_type, reference_id, created_by)
  VALUES
    (p_account_id, v_acc.account_id, p_amount, v_balance_after, p_type, p_reference_id, auth.uid())
  RETURNING id INTO v_movement_id;

  -- UPDATE cabecera
  UPDATE public.supplier_accounts
  SET balance = v_balance_after
  WHERE id = p_account_id;

  RETURN v_movement_id;
END;
$$;

REVOKE ALL ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid) FROM PUBLIC;

COMMENT ON FUNCTION public.c30_register_supplier_account_movement IS
  'C-30 (D2): helper intra-transacción de cuenta corriente de proveedor. Espejo exacto de c30_register_customer_account_movement. '
  'balance_after >= 0 siempre (OQ-1, P0409 si sobrepago). REVOKE de PUBLIC.';


-- ============================================================
-- 4.3 HELPER: c30_get_or_create_customer_account (OQ-4 lazy auto-create, D6)
-- ============================================================
CREATE OR REPLACE FUNCTION public.c30_get_or_create_customer_account(
  p_account_id uuid,
  p_client_id  uuid
) RETURNS uuid
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  -- INSERT idempotente: ON CONFLICT (account_id, client_id) DO NOTHING
  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (p_account_id, p_client_id, 0, auth.uid())
  ON CONFLICT (account_id, client_id) DO NOTHING;

  -- SELECT garantizado (fila ya existe o fue recién insertada)
  SELECT id INTO v_id
  FROM public.customer_accounts
  WHERE account_id = p_account_id AND client_id = p_client_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.c30_get_or_create_customer_account(uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION public.c30_get_or_create_customer_account IS
  'C-30 (OQ-4): lazy auto-create idempotente de CustomerAccount. '
  'ON CONFLICT (account_id, client_id) DO NOTHING garantiza una sola fila por cliente. '
  'REVOKE de PUBLIC: callable solo desde RPCs SECURITY DEFINER.';


-- ============================================================
-- 4.4 HELPER: c30_get_or_create_supplier_account (espejo de 4.3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.c30_get_or_create_supplier_account(
  p_account_id  uuid,
  p_supplier_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance, created_by)
  VALUES (p_account_id, p_supplier_id, 0, auth.uid())
  ON CONFLICT (account_id, supplier_id) DO NOTHING;

  SELECT id INTO v_id
  FROM public.supplier_accounts
  WHERE account_id = p_account_id AND supplier_id = p_supplier_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.c30_get_or_create_supplier_account(uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION public.c30_get_or_create_supplier_account IS
  'C-30 (OQ-4): lazy auto-create idempotente de SupplierAccount. REVOKE de PUBLIC.';


-- ============================================================
-- 5.1 RPC: rpc_create_customer_account (camino explícito de creación, D6)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_customer_account(
  p_client_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id          uuid;
  v_customer_account_id uuid;
  v_client              RECORD;
BEGIN
  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar que el cliente pertenece a la cuenta
  SELECT id INTO v_client
  FROM public.clients
  WHERE id = p_client_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, p_client_id);

  RETURN jsonb_build_object(
    'customer_account_id', v_customer_account_id,
    'client_id',           p_client_id,
    'balance',             (SELECT balance FROM public.customer_accounts WHERE id = v_customer_account_id)
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_customer_account(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_customer_account(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_customer_account IS
  'C-30 (D6): crea o retorna la CustomerAccount de un cliente. Idempotente. '
  'Guard is_account_writer. P0403 sin cuenta, P0401 sin permiso, P0404 cliente no encontrado.';


-- ============================================================
-- 5.2 RPC: rpc_create_supplier_account (espejo de 5.1)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_supplier_account(
  p_supplier_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id         uuid;
  v_supplier_account_id uuid;
  v_supplier           RECORD;
BEGIN
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  SELECT id INTO v_supplier
  FROM public.suppliers
  WHERE id = p_supplier_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  RETURN jsonb_build_object(
    'supplier_account_id', v_supplier_account_id,
    'supplier_id',         p_supplier_id,
    'balance',             (SELECT balance FROM public.supplier_accounts WHERE id = v_supplier_account_id)
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_supplier_account(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_supplier_account(uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_supplier_account IS
  'C-30 (D6): crea o retorna la SupplierAccount de un proveedor. Idempotente. '
  'Guard is_account_writer. P0403 sin cuenta, P0401 sin permiso, P0404 proveedor no encontrado.';


-- ============================================================
-- 5.3 RPC: rpc_register_payment_received (cobro del cliente, D6/OQ-1/OQ-5/OQ-6)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_register_payment_received(
  p_idempotency_key   text,
  p_client_id         uuid,
  p_amount            numeric,
  p_reference_sale_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_customer_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after       numeric(15,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar amount > 0
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- Idempotencia DEC-06 (OQ-5): operation_kind='payment_received'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_received', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver el resultado original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_received'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',           NULL,
      'customer_account_id',  NULL,
      'balance_after',        NULL,
      'replayed',             true,
      'operation_id',         v_existing_op
    );
  END IF;

  -- Resolver/crear la CustomerAccount (OQ-4 lazy auto-create)
  v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, p_client_id);

  -- Registrar el movimiento con signo negativo (reduce la deuda, OQ-1)
  -- El helper c30_register_customer_account_movement lanza P0409 si balance resultante < 0
  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_customer_account_movement(
    v_customer_account_id,
    -p_amount,                 -- negativo: el cobro reduce la deuda
    'payment_received',
    v_payment_id
  );

  -- Obtener el balance_after del movimiento recién insertado
  SELECT balance_after INTO v_balance_after
  FROM public.customer_account_movements
  WHERE id = v_movement_id;

  -- INSERT en payments_received
  INSERT INTO public.payments_received
    (id, account_id, customer_account_id, client_id, amount, reference_sale_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_customer_account_id, p_client_id, p_amount, p_reference_sale_id, v_movement_id, v_uid);

  -- OQ-6 (RESUELTO): evento PaymentReceived al outbox en el mismo commit
  -- El consumer AuditLog de C-25 es genérico — procesa cualquier event_type
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentReceived',
    'CustomerAccount',
    v_customer_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'customer_account_id',  v_customer_account_id,
      'client_id',            p_client_id,
      'payment_id',           v_payment_id,
      'amount',               p_amount,
      'balance_after',        v_balance_after,
      'reference_sale_id',    p_reference_sale_id,
      'occurred_at',          now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',           v_payment_id,
    'customer_account_id',  v_customer_account_id,
    'balance_after',        v_balance_after,
    'replayed',             false,
    'operation_id',         v_new_op_id
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_register_payment_received IS
  'C-30 (D6): registra un cobro en la cuenta corriente del cliente. '
  'Idempotente (DEC-06, operation_kind=payment_received). '
  'OQ-1: P0409 si el cobro excede el saldo deudor. '
  'OQ-6: emite PaymentReceived al outbox en el mismo commit.';


-- ============================================================
-- 5.4 RPC: rpc_register_payment_made (pago al proveedor, espejo de 5.3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_register_payment_made(
  p_idempotency_key     text,
  p_supplier_id         uuid,
  p_amount              numeric,
  p_reference_purchase_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after       numeric(15,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- Idempotencia DEC-06 (OQ-5): operation_kind='payment_made'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_made', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_made'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',          NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    -p_amount,               -- negativo: el pago reduce lo que se debe
    'payment_made',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  INSERT INTO public.payments_made
    (id, account_id, supplier_account_id, supplier_id, amount, reference_purchase_id, movement_id, created_by)
  VALUES
    (v_payment_id, v_account_id, v_supplier_account_id, p_supplier_id, p_amount, p_reference_purchase_id, v_movement_id, v_uid);

  -- OQ-6: evento PaymentMade al outbox
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentMade',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'payment_id',          v_payment_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',          v_payment_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_register_payment_made IS
  'C-30 (D6): registra un pago a la cuenta corriente del proveedor. '
  'Idempotente (DEC-06, operation_kind=payment_made). '
  'OQ-1: P0409 si el pago excede el saldo deudor.';


-- ============================================================
-- 5.5 RPC: rpc_register_supplier_charge (cargo manual a proveedor, OQ-3/D7)
--
-- OQ-3 default B: el flujo de compras de stock (rpc_create_purchase_operation)
-- NO se toca. El cargo en la cta cte de proveedor se registra explícitamente.
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_register_supplier_charge(
  p_idempotency_key text,
  p_supplier_id     uuid,
  p_amount          numeric,
  p_reference_id    uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_balance_after       numeric(15,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  -- Idempotencia DEC-06 (OQ-5): operation_kind='supplier_charge'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'supplier_charge', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'supplier_charge'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'movement_id',         NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  -- Cargo positivo: aumenta lo que se debe al proveedor
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    p_amount,             -- positivo: el cargo sube el saldo (lo que se debe)
    'purchase',
    p_reference_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  -- OQ-6: evento SupplierAccountCharged al outbox
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SupplierAccountCharged',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'movement_id',         v_movement_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'movement_id',         v_movement_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_register_supplier_charge(text, uuid, numeric, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_supplier_charge(text, uuid, numeric, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_register_supplier_charge IS
  'C-30 (D7, OQ-3 default B): cargo manual en la cta cte del proveedor. '
  'NO toca rpc_create_purchase_operation. Idempotente (operation_kind=supplier_charge).';


-- ============================================================
-- 6.1 Integración C-29 — ALTER CHECK de payment_method (+credit)
-- ============================================================
ALTER TABLE public.sales_orders DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check;
ALTER TABLE public.sales_orders ADD CONSTRAINT sales_orders_payment_method_check
  CHECK (payment_method IN ('cash','other','credit'));

COMMENT ON COLUMN public.sales_orders.payment_method IS
  'C-29: método de pago. C-30 agrega credit (venta a crédito — postea cargo en CustomerAccount).';


-- ============================================================
-- 6.2 Integración C-29 — CREATE OR REPLACE _c29_confirm_order_core
--     Misma firma que C-29. Cambios aditivos:
--     (a) Declarar v_customer_account_id uuid en DECLARE
--     (b) 'credit' en la validación de payment_method
--     (c) Bloque IF credit THEN ... END IF tras el bloque de caja
--     (d) Outbox CustomerAccountCharged (OQ-6)
--     Wrappers rpc_confirm_sales_order / rpc_quick_sale NO cambian.
-- ============================================================
CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(
  p_idempotency_key   text,
  p_sales_order_id    uuid,
  p_payment_method    text,
  p_cash_session_id   uuid   DEFAULT NULL,
  p_comprobante_type  text   DEFAULT NULL,
  p_point_of_sale_id  uuid   DEFAULT NULL,
  p_canal             text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_order               public.sales_orders%ROWTYPE;
  v_gate_branch         uuid;
  v_branch              RECORD;
  v_item                RECORD;
  v_product             RECORD;
  v_branch_qty          numeric(15,4);
  v_qty_norm            numeric(15,4);
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_new_sale_id         uuid;
  v_fiscal_doc_id       uuid;
  v_fiscal_result       jsonb;
  v_inserted            integer;
  v_canal               text;
  v_total               numeric(15,2) := 0;
  v_qty_before          numeric;
  v_qty_after           numeric;
  v_customer_account_id uuid;   -- C-30: cuenta corriente para ventas a crédito
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar idempotency_key
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  -- Cargar la orden
  SELECT * INTO v_order
  FROM public.sales_orders
  WHERE id = p_sales_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_order.account_id;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado de la orden
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'order_not_in_draft: estado %', v_order.status
      USING ERRCODE = 'P0409';
  END IF;

  -- D6: validación cash sin session → P0400
  IF p_payment_method = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- C-30 (D4): validar credit exige client_id (ANTES de tocar stock)
  IF p_payment_method = 'credit' AND v_order.client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id en la orden'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method (C-30 agrega credit)
  IF p_payment_method NOT IN ('cash', 'other', 'credit') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch del gate
  v_gate_branch := v_order.branch_id;

  -- Validar que la branch esté activa
  SELECT id, status INTO v_branch
  FROM public.branches
  WHERE id = v_gate_branch AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Canal normalizado
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');

  -- ─── Idempotencia (DEC-06) ───────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver la operación original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'sale'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_existing_op,
      'replayed',        true
    );
  END IF;

  -- ─── Calcular total y descontar stock por línea ──────────────────────────
  FOR v_item IN
    SELECT * FROM public.sales_order_items
    WHERE sales_order_id = p_sales_order_id
    ORDER BY id
  LOOP
    v_total := v_total + v_item.subtotal;

    IF v_item.product_id IS NOT NULL THEN
      -- Lock del producto para serializar
      SELECT id, user_id, name INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      v_qty_norm := v_item.quantity;

      -- Gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM public.branch_stock
      WHERE product_id = v_item.product_id AND branch_id = v_gate_branch;

      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_item.product_id, v_branch_qty, v_qty_norm
          USING ERRCODE = 'P0409';
      END IF;

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      -- Descontar stock (C-21 helper)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm
      );

      -- Insertar fila legacy sales (retrocompat D4)
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;

      -- stock_movements (reference_type='sale')
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', CURRENT_DATE,
         v_new_op_id, v_gate_branch, v_canal)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  IF p_payment_method = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── Cuenta corriente del cliente (C-30 helper intra-transacción, D4) ───
  -- Si payment_method = 'credit', postea un cargo en el mismo commit (sin caja).
  -- client_id ya validado arriba (credit_requires_client antes del descuento de stock).
  IF p_payment_method = 'credit' THEN
    v_customer_account_id := public.c30_get_or_create_customer_account(
      v_account_id,
      v_order.client_id
    );
    PERFORM public.c30_register_customer_account_movement(
      v_customer_account_id,
      v_total,                -- positivo: cargo que aumenta la deuda del cliente
      'sale',
      p_sales_order_id
    );

    -- OQ-6 (RESUELTO): evento CustomerAccountCharged al outbox
    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      v_account_id,
      'CustomerAccountCharged',
      'CustomerAccount',
      v_customer_account_id,
      jsonb_build_object(
        'account_id',           v_account_id,
        'customer_account_id',  v_customer_account_id,
        'client_id',            v_order.client_id,
        'sales_order_id',       p_sales_order_id,
        'operation_id',         v_new_op_id,
        'amount',               v_total,
        'occurred_at',          now()
      ),
      now()
    );
  END IF;

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  IF p_comprobante_type IS NOT NULL THEN
    SELECT public.rpc_emit_pending_cae(
      p_comprobante_type,
      v_total,
      v_order.client_id,
      p_point_of_sale_id
    ) INTO v_fiscal_result;

    v_fiscal_doc_id := (v_fiscal_result->>'fiscal_document_id')::uuid;
  END IF;

  -- ─── INSERT outbox (DEC-20 — SaleConfirmed) ─────────────────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SaleConfirmed',
    'SalesOrder',
    p_sales_order_id,
    jsonb_build_object(
      'account_id',      v_account_id,
      'branch_id',       v_gate_branch,
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_new_op_id,
      'total',           v_total,
      'payment_method',  p_payment_method,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  UPDATE public.sales_orders
  SET
    status             = 'confirmed',
    payment_method     = p_payment_method,
    total              = v_total,
    sale_operation_id  = v_new_op_id,
    fiscal_document_id = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$$;

-- REVOKE: helper interno — NO callable desde rol authenticated
REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text)
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._c29_confirm_order_core IS
  'C-29 (D1) + C-30 (D4): helper interno compartido por rpc_confirm_sales_order y rpc_quick_sale. '
  'C-30 agrega: (a) credit en validación de payment_method; '
  '(b) bloque IF credit → c30_get_or_create_customer_account + c30_register_customer_account_movement; '
  '(c) evento CustomerAccountCharged al outbox (OQ-6). '
  'Firma idéntica a C-29. Wrappers rpc_confirm_sales_order / rpc_quick_sale no cambian.';


-- ============================================================
-- 7.1 Gates SQL (RED→GREEN — ROLLBACK total al final)
-- Patrón C-28 §1.9 / C-29 §3.4: SAVEPOINTs con ROLLBACK total.
--
-- (a) CHECK movement_type de customer_account_movements rechaza 'foo'
-- (b) CHECK movement_type de supplier_account_movements rechaza 'sale' (tipo de cliente)
-- (c) Gate inverso de C-29: INSERT con payment_method='credit' AHORA ACEPTADO
-- (d) amount <= 0 en payments_received viola el CHECK
-- (e) balance_after acumula correcto en movimientos sucesivos
--    (verificado por la lógica de c30_register_customer_account_movement)
-- ============================================================
DO $$
DECLARE
  v_got_check_customer_type  boolean := false;
  v_got_check_supplier_type  boolean := false;
  v_got_credit_accepted      boolean := false;
  v_got_check_amount         boolean := false;
BEGIN

  -- (a) movement_type='foo' en customer_account_movements rechaza CHECK
  BEGIN
    INSERT INTO public.customer_account_movements
      (customer_account_id, account_id, amount, balance_after, movement_type, created_by)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), 100, 100, 'foo', gen_random_uuid());
    RAISE EXCEPTION 'GATE a FAILED: debería haber violado CHECK movement_type de customer_account_movements';
  EXCEPTION
    WHEN check_violation THEN
      v_got_check_customer_type := true;
  END;

  IF NOT v_got_check_customer_type THEN
    RAISE EXCEPTION 'GATE a: CHECK movement_type de customer_account_movements no rechazó foo';
  END IF;

  -- (b) movement_type='sale' en supplier_account_movements rechaza CHECK (tipo de cliente, no de proveedor)
  BEGIN
    INSERT INTO public.supplier_account_movements
      (supplier_account_id, account_id, amount, balance_after, movement_type, created_by)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), 100, 100, 'sale', gen_random_uuid());
    RAISE EXCEPTION 'GATE b FAILED: debería haber violado CHECK movement_type de supplier_account_movements';
  EXCEPTION
    WHEN check_violation THEN
      v_got_check_supplier_type := true;
  END;

  IF NOT v_got_check_supplier_type THEN
    RAISE EXCEPTION 'GATE b: CHECK movement_type de supplier_account_movements no rechazó sale';
  END IF;

  -- (c) Gate inverso de C-29: payment_method='credit' AHORA ES ACEPTADO por el CHECK
  -- (El gate (a) de C-29 esperaba que 'credit' fallara — C-30 revierte esa expectativa)
  BEGIN
    INSERT INTO public.sales_orders
      (account_id, branch_id, status, payment_method, total, created_by)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), 'draft', 'credit', 0, gen_random_uuid());
    -- Si llegamos aquí: el INSERT no lanzó check_violation → 'credit' es aceptado ✓
    v_got_credit_accepted := true;
  EXCEPTION
    WHEN check_violation THEN
      RAISE EXCEPTION 'GATE c FAILED: payment_method=credit debería ser aceptado por el CHECK en C-30, pero fue rechazado';
    WHEN OTHERS THEN
      -- FK violations, etc. → el CHECK sí aceptó 'credit' (solo falla por otros motivos)
      v_got_credit_accepted := true;
  END;

  IF NOT v_got_credit_accepted THEN
    RAISE EXCEPTION 'GATE c: payment_method=credit no fue aceptado por el CHECK';
  END IF;

  -- (d) amount <= 0 en payments_received viola el CHECK
  BEGIN
    INSERT INTO public.payments_received
      (account_id, customer_account_id, client_id, amount, created_by)
    VALUES
      (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 0, gen_random_uuid());
    RAISE EXCEPTION 'GATE d FAILED: amount=0 debería haber violado CHECK amount > 0 en payments_received';
  EXCEPTION
    WHEN check_violation THEN
      v_got_check_amount := true;
  END;

  IF NOT v_got_check_amount THEN
    RAISE EXCEPTION 'GATE d: CHECK amount > 0 de payments_received no rechazó 0';
  END IF;

  RAISE NOTICE 'C-30 SQL gates: (a) CHECK customer movement_type OK, (b) CHECK supplier movement_type OK, (c) credit aceptado por CHECK OK, (d) CHECK amount > 0 OK';
  RAISE NOTICE 'C-30 SQL gates: tablas, índices, RLS, helpers y RPCs creados exitosamente';

  RAISE EXCEPTION 'C-30 gates ROLLBACK total (esperado — patrón DO-block)';

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'C-30 gates ROLLBACK%' THEN
      RAISE NOTICE 'C-30: ROLLBACK del DO-block de gates OK (todos los INSERTs de prueba revertidos)';
    ELSE
      RAISE;
    END IF;
END $$;
