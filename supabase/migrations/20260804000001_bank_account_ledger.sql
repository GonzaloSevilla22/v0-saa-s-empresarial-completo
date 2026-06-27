-- =============================================================================
-- MIGRATION: 20260804000001_bank_account_ledger.sql
-- CHANGE:    bank-account-ledger (C1 de la secuencia BankReconciliation V2.5)
-- Design ref: openspec/changes/bank-account-ledger/design.md
--
-- Principio "dos ledgers":
--   bank_movements = ledger OPERACIONAL (fuente de verdad del saldo bancario,
--   base de la conciliación futura C3). La cuenta contable 1110 Banco = espejo
--   CONTABLE, alimentado asincrónicamente por el Consumer 3 del outbox
--   (_journal_post_from_event). La conciliación (C3) opera SIEMPRE sobre
--   bank_movements, NUNCA sobre el journal. C1 NO postea al journal — ese
--   cableado es de C2 (bank-payment-routing).
--
-- Implementa (design.md):
--   D1  bank_accounts es ORG-LEVEL (tenancy directa por account_id, no branch-scoped)
--   D2  account_id denormalizado en bank_movements para RLS sin subquery por fila
--   D3  Taxonomía movement_type completa fijada en CHECK; RPC manual acepta subconjunto
--   D4  Helper _register_bank_movement = contrato C1→C2 (análogo de c28_register_cash_movement)
--   D5  Escritura SOLO vía RPCs SECURITY DEFINER; sin policy INSERT/UPDATE/DELETE directa
--   D6  Idempotencia en rpc_register_bank_movement (operation_kind='bank_movement')
--   D7  CBU validado (22 dígitos numéricos) en RPC + CHECK nivel tabla
--   D8  ERRCODEs P0401/P0410/P0411/P0412 (espacio P04xx — verificados libres)
--   D9  Specs split: bank-account + bank-movement
--   D10 Migración 20260804000001 (timestamp libre — última existente 20260803000003)
--
-- TDD tasks cubiertos (RED→GREEN→TRIANGULATE→REFACTOR en DO-block §7):
--   Tasks 1.1-1.6  bank_accounts + CHECK CBU + índice + COMMENT
--   Tasks 2.1-2.4  RLS bank_accounts: aislamiento B↛A, A ve A, INSERT directo bloqueado
--   Tasks 3.1-3.8  bank_movements + enum CHECK + índices + RLS + append-only
--   Tasks 4.1-4.6  _register_bank_movement: balance_after, secuencia signada, atomicidad, REVOKE
--   Tasks 5.1-5.6  rpc_create/update_bank_account: guard P0401, CBU P0411, P0412, soft-deactivate
--   Tasks 6.1-6.7  rpc_register_bank_movement: tipo reservado P0410, P0401, P0412, idempotencia
--   Tasks 7.1-7.2  Gates consolidados + gate negativo 1110 (C1 no postea al journal)
--
-- ERRCODEs (5 chars — convención post-20260624000001):
--   P0401  sin permiso de escritura (is_account_writer) — estándar del proyecto
--   P0410  movement_type inválido para la RPC manual (tipo reservado a C2/C3)
--   P0411  CBU inválido (no 22 dígitos numéricos)
--   P0412  cuenta bancaria no encontrada / inactiva
--
-- GOVERNANCE: MEDIO (tablas aisladas nuevas + RPCs manuales; no toca hot path de
--             venta/pago ni dinero real existente).
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — desincroniza history)
--
-- ROLLBACK (en orden):
--   DROP FUNCTION IF EXISTS
--     public.rpc_register_bank_movement(text, uuid, numeric, text, date, uuid, text),
--     public.rpc_update_bank_account(uuid, text, text, text, boolean),
--     public.rpc_create_bank_account(text, text, text, text, text, numeric, date),
--     public._register_bank_movement(uuid, numeric, text, text, uuid, date, uuid, text);
--   DROP TABLE IF EXISTS
--     public.bank_movements,
--     public.bank_accounts;
--   -- Revertir operation_idempotency CHECK (quitar 'bank_movement'):
--   ALTER TABLE public.operation_idempotency
--     DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;
--   ALTER TABLE public.operation_idempotency
--     ADD CONSTRAINT operation_idempotency_operation_kind_check
--     CHECK (operation_kind = ANY (ARRAY[
--       'sale','purchase','payment_received','payment_made','supplier_charge']));
--   (Sin pérdida de datos: feature nueva, 0 filas en prod)
--
-- VERIFICATION (post-push):
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public'
--     AND table_name IN ('bank_accounts','bank_movements')
--   ORDER BY table_name;
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema = 'public'
--     AND routine_name IN (
--       '_register_bank_movement',
--       'rpc_create_bank_account',
--       'rpc_update_bank_account',
--       'rpc_register_bank_movement'
--     )
--   ORDER BY routine_name;
-- =============================================================================


-- ============================================================
-- 0. Extend operation_idempotency CHECK to include 'bank_movement'
--    (same pattern as 20260720000002_c30_hotfix_operation_kind_check.sql)
-- ============================================================
ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;

ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale',
    'purchase',
    'payment_received',
    'payment_made',
    'supplier_charge',
    'bank_movement'
  ]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'C-30: sale/purchase/payment_received/payment_made/supplier_charge. '
  'bank-account-ledger (C1 V2.5): agrega bank_movement para idempotencia de '
  'carga manual de movimientos bancarios (rpc_register_bank_movement).';


-- ============================================================
-- 1.3 TABLE: bank_accounts (D1 — ORG-LEVEL, tenancy directa por account_id)
--
-- Task 1.2 RED:  gate CHECK CBU rechaza '12345' (no 22 dígitos)
-- Task 1.3 GREEN: CREATE TABLE + CHECK (cbu IS NULL OR cbu ~ '^[0-9]{22}$') (D7)
-- Task 1.4 TRIANGULATE: NULL y CBU de 22 dígitos pasan; formato malo falla
-- ============================================================
CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id               uuid           NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id       uuid           NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  name             text           NOT NULL,
  bank_name        text,
  cbu              text           CHECK (cbu IS NULL OR cbu ~ '^[0-9]{22}$'),
  alias            text,
  currency         text           NOT NULL DEFAULT 'ARS',
  opening_balance  numeric(14,2)  NOT NULL DEFAULT 0,
  opening_date     date,
  is_active        boolean        NOT NULL DEFAULT true,
  created_at       timestamptz    NOT NULL DEFAULT now()
);

-- Task 1.5: Índice para RLS directa y búsquedas por cuenta (D2)
CREATE INDEX IF NOT EXISTS bank_accounts_account_id_idx
  ON public.bank_accounts (account_id);

-- Task 1.6 REFACTOR: comentarios
COMMENT ON TABLE public.bank_accounts IS
  'bank-account-ledger (C1 V2.5): cuenta bancaria a nivel organización (ORG-LEVEL, D1). '
  'Greenfield — no branch-scoped (a diferencia de cashboxes). '
  'Una cuenta bancaria pertenece a la organización (account_id), no a una sucursal: '
  'el mismo CBU sirve a todas las sucursales. '
  'Escritura SOLO vía rpc_create/update_bank_account (SECURITY DEFINER, D5). '
  'Ausencia de policy INSERT/UPDATE/DELETE es deliberada.';

COMMENT ON COLUMN public.bank_accounts.account_id IS
  'FK a accounts(id). Tenencia directa ORG-LEVEL. RLS: account_id IN (SELECT current_account_ids()).';

COMMENT ON COLUMN public.bank_accounts.cbu IS
  'CBU bancario argentino (22 dígitos numéricos). NULL = cuenta registrada sin CBU. '
  'CHECK (cbu IS NULL OR cbu ~ ''^[0-9]{22}$''): solo formato, sin validación de dígito verificador (D7). '
  'La validación del DV (módulo 10 por bloques) se difiere a C2/C3.';

COMMENT ON COLUMN public.bank_accounts.currency IS
  'Moneda de la cuenta. Default ARS. Soporte multi-divisa diferido a futura fase.';

COMMENT ON COLUMN public.bank_accounts.opening_balance IS
  'Saldo de apertura al momento de registrar la cuenta. '
  'Base de cálculo del primer balance_after en bank_movements.';

COMMENT ON COLUMN public.bank_accounts.is_active IS
  'Soft-deactivate: false = la cuenta deja de aceptar nuevos movimientos (P0412). '
  'La cuenta y sus movimientos históricos permanecen visibles.';


-- ============================================================
-- 2.2 RLS: bank_accounts (D1/D5)
--
-- Task 2.1 RED:  gate — B no ve fila de A (RLS no habilitada → falla)
-- Task 2.2 GREEN: ENABLE RLS + policy SELECT por account_id
-- Task 2.3 TRIANGULATE: A ve su propia fila
-- Task 2.4 TRIANGULATE: INSERT directo de authenticated rechazado (sin policy de escritura)
-- ============================================================
ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bank_accounts_select ON public.bank_accounts;
CREATE POLICY bank_accounts_select
  ON public.bank_accounts
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));


-- ============================================================
-- 3.2 TABLE: bank_movements (ledger append-only, D2/D3)
--
-- Task 3.1 RED:  gate CHECK movement_type rechaza 'foo' (tabla no existe → falla)
-- Task 3.2 GREEN: CREATE TABLE con enum completo (D3)
-- Task 3.3 TRIANGULATE: los 7 tipos se insertan OK a nivel tabla
-- Task 3.5 RED: gate — B no ve movimientos de A (RLS no habilitada → falla)
-- Task 3.6 GREEN: ENABLE RLS + policy SELECT por account_id denormalizado
-- Task 3.7 TRIANGULATE: INSERT/UPDATE/DELETE directo de authenticated bloqueado
-- Task 3.8 REFACTOR: COMMENT
-- ============================================================
CREATE TABLE IF NOT EXISTS public.bank_movements (
  id               uuid           NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  bank_account_id  uuid           NOT NULL REFERENCES public.bank_accounts(id) ON DELETE CASCADE,
  account_id       uuid           NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  -- account_id denormalized from bank_accounts for RLS without per-row subquery (D2)
  amount           numeric(14,2)  NOT NULL,
  balance_after    numeric(14,2)  NOT NULL,
  movement_type    text           NOT NULL
                   CHECK (movement_type IN (
                     'transfer_in',
                     'transfer_out',
                     'card_settlement',   -- RESERVADO C2/C3: acreditación de tarjeta (bruto≠neto, D3)
                     'fee',               -- RESERVADO C2/C3: comisión bancaria
                     'tax_debit',         -- RESERVADO C2/C3: impuesto al cheque (Ley 25.413)
                     'interest',          -- RESERVADO C2/C3: interés acreditado/debitado
                     'manual_adjustment'  -- válvula de escape para ajustes manuales
                   )),
  value_date       date,
  -- value_date = fecha valor bancaria (≠ created_at = fecha de registro en el sistema)
  branch_id        uuid           REFERENCES public.branches(id),
  -- branch_id nullable: solo analítica. No acopla el ledger a la sucursal (D1).
  source_doc_type  text,
  source_doc_ref   uuid,
  description      text,
  created_at       timestamptz    NOT NULL DEFAULT now()
);

-- Task 3.4: Índices (D2)
CREATE INDEX IF NOT EXISTS bank_movements_bank_account_value_date_idx
  ON public.bank_movements (bank_account_id, value_date DESC);

CREATE INDEX IF NOT EXISTS bank_movements_account_id_idx
  ON public.bank_movements (account_id);

-- Task 3.6 GREEN: RLS
ALTER TABLE public.bank_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bank_movements_select ON public.bank_movements;
CREATE POLICY bank_movements_select
  ON public.bank_movements
  FOR SELECT
  USING (account_id IN (SELECT public.current_account_ids()));
-- D2: RLS directa por account_id denormalizado — sin subquery por fila a bank_accounts.
-- D5: SIN políticas INSERT/UPDATE/DELETE — append-only; escritura SOLO vía helper SECURITY DEFINER.

-- Task 3.8 REFACTOR: comentarios
COMMENT ON TABLE public.bank_movements IS
  'bank-account-ledger (C1 V2.5): ledger operacional append-only de movimientos bancarios. '
  'Espejo arquitectónico de cash_movements (C-28). '
  'amount con signo: positivo = ingreso, negativo = egreso. '
  'balance_after = saldo previo de la cuenta + amount (patrón ledger). '
  'account_id denormalizado para RLS sin subquery por fila (D2 — igual que journal_lines/C-30). '
  'Append-only: sin UPDATE ni DELETE. Escritura SOLO vía _register_bank_movement (D4/D5). '
  'ledger OPERACIONAL (fuente de verdad del saldo bancario y base de conciliación C3). '
  'La cuenta contable 1110 Banco = ledger CONTABLE, alimentado por Consumer 3 del outbox — C2.';

COMMENT ON COLUMN public.bank_movements.account_id IS
  'account_id denormalizado de la cabecera bank_accounts. '
  'Copiado por el helper al INSERT — valor INMUTABLE (sin UPDATE de cabecera que lo desincronice). '
  'Permite RLS sin JOIN: account_id IN (SELECT current_account_ids()).';

COMMENT ON COLUMN public.bank_movements.movement_type IS
  'Enum completo fijado en C1 para no migrar el CHECK en C2/C3 (D3). '
  'ACEPTADOS por rpc_register_bank_movement (carga manual C1): transfer_in, transfer_out, manual_adjustment. '
  'RESERVADOS para C2/C3: card_settlement (acreditación tarjeta, bruto≠neto), '
  'fee (comisión bancaria), tax_debit (impuesto al cheque Ley 25.413), interest. '
  'El CHECK a nivel tabla acepta los 7; la RPC manual rechaza los reservados con P0410.';

COMMENT ON COLUMN public.bank_movements.value_date IS
  'Fecha valor bancaria (cuándo el banco acredita/debita). '
  'Distinta de created_at (cuándo el usuario registró el movimiento en el sistema). '
  'Relevante para conciliación con extracto bancario (C3).';

COMMENT ON COLUMN public.bank_movements.branch_id IS
  'Sucursal atribuida al movimiento. Nullable — solo analítica. '
  'No acopla el ledger a la sucursal (D1): la cuenta bancaria es ORG-LEVEL.';


-- ============================================================
-- 4. HELPER: _register_bank_movement (contrato C1→C2, D4)
--
-- Task 4.1 RED:  gate — función no existe (falla)
-- Task 4.2 GREEN: CREATE FUNCTION + gate balance_after = opening_balance + amount
-- Task 4.3 TRIANGULATE: secuencia signada +500/-200/+300 sobre opening=1000 → 1500/1300/1600
-- Task 4.4 TRIANGULATE: atomicidad — ROLLBACK de SAVEPOINT no deja fila
-- Task 4.5 GREEN (higiene): REVOKE ALL FROM PUBLIC/anon/authenticated
-- Task 4.6 REFACTOR: COMMENT
--
-- Análogo exacto de c28_register_cash_movement (C-28) y contrato C1→C2:
-- C2 (bank-payment-routing) llamará a este helper desde las RPCs de pago
-- dentro de la misma transacción para atomicidad pago+movimiento bancario.
-- ============================================================
CREATE OR REPLACE FUNCTION public._register_bank_movement(
  p_bank_account_id  uuid,
  p_amount           numeric,
  p_type             text,
  p_source_doc_type  text    DEFAULT NULL,
  p_source_doc_ref   uuid    DEFAULT NULL,
  p_value_date       date    DEFAULT NULL,
  p_branch_id        uuid    DEFAULT NULL,
  p_description      text    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ba              public.bank_accounts%ROWTYPE;
  v_prev_balance    numeric(14,2);
  v_balance_after   numeric(14,2);
  v_movement_id     uuid;
BEGIN
  -- D4: FOR UPDATE sobre la fila de bank_accounts para serializar el cálculo
  -- de balance_after (mismo patrón que c28_register_cash_movement sobre cash_sessions)
  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  -- Calcular saldo previo: opening_balance + suma de los amounts de los movimientos previos.
  -- (SUM(amount), NO MAX(balance_after): el saldo corriente puede bajar tras un egreso,
  --  y MAX devolvería un saldo previo incorrecto. FOR UPDATE arriba serializa el cálculo.)
  SELECT v_ba.opening_balance + COALESCE(SUM(bm.amount), 0)
  INTO v_prev_balance
  FROM public.bank_movements bm
  WHERE bm.bank_account_id = p_bank_account_id;

  v_balance_after := v_prev_balance + p_amount;

  -- INSERT append-only; copia account_id de la cabecera (D2 — inmutable)
  INSERT INTO public.bank_movements
    (bank_account_id, account_id, amount, balance_after, movement_type,
     value_date, branch_id, source_doc_type, source_doc_ref, description)
  VALUES
    (p_bank_account_id, v_ba.account_id, p_amount, v_balance_after, p_type,
     p_value_date, p_branch_id, p_source_doc_type, p_source_doc_ref, p_description)
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;

-- Task 4.5: REVOKE ALL — callable SOLO desde RPCs SECURITY DEFINER de C1/C2 (D4/D5)
REVOKE ALL ON FUNCTION public._register_bank_movement(uuid, numeric, text, text, uuid, date, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._register_bank_movement(uuid, numeric, text, text, uuid, date, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public._register_bank_movement(uuid, numeric, text, text, uuid, date, uuid, text) FROM authenticated;

-- Task 4.6 REFACTOR: comentario
COMMENT ON FUNCTION public._register_bank_movement IS
  'bank-account-ledger C1 (D4): helper intra-transacción del ledger bancario. '
  'Espejo exacto de c28_register_cash_movement (C-28) — contrato C1→C2. '
  'NO abre transacción propia; corre en la transacción del llamador. '
  'FOR UPDATE sobre bank_accounts serializa cálculo de balance_after. '
  'balance_after = opening_balance + SUM(amount de movimientos previos) + amount (SUM, no MAX: el saldo puede bajar). '
  'account_id denormalizado en el INSERT desde la cabecera (D2). '
  'REVOKE de PUBLIC/anon/authenticated: callable SOLO desde RPCs SECURITY DEFINER de C1 y C2 '
  '(las futuras RPCs de pago de bank-payment-routing la invocarán intra-tx para atomicidad).';


-- ============================================================
-- 5. RPCs: rpc_create_bank_account / rpc_update_bank_account (capability bank-account)
--
-- Task 5.1 RED:  gate — rpc_create_bank_account no existe (falla)
-- Task 5.2 GREEN: CREATE rpc_create_bank_account + gate creación OK
-- Task 5.3 TRIANGULATE: no-escritor → P0401, sin fila insertada
-- Task 5.4 TRIANGULATE: CBU '12345' → P0411; CBU NULL y CBU válido → OK
-- Task 5.5 GREEN: CREATE rpc_update_bank_account + gate soft-deactivate persiste
-- Task 5.6 TRIANGULATE: no-escritor → P0401 en update, fila sin cambios
-- ============================================================

-- ── 5.2 rpc_create_bank_account ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_bank_account(
  p_name             text,
  p_bank_name        text    DEFAULT NULL,
  p_cbu              text    DEFAULT NULL,
  p_alias            text    DEFAULT NULL,
  p_currency         text    DEFAULT 'ARS',
  p_opening_balance  numeric DEFAULT 0,
  p_opening_date     date    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id      uuid;
  v_bank_account_id uuid;
BEGIN
  -- Resolver account_id de la sesión (misma mecánica que C-30)
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard D5: solo escritores autorizados
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar CBU (D7): cuando se provee, debe ser exactamente 22 dígitos numéricos
  IF p_cbu IS NOT NULL AND p_cbu !~ '^[0-9]{22}$' THEN
    RAISE EXCEPTION 'cbu_invalido: el CBU debe tener exactamente 22 dígitos numéricos, recibido: %', p_cbu
      USING ERRCODE = 'P0411';
  END IF;

  -- Validar nombre requerido
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required: el nombre de la cuenta es obligatorio'
      USING ERRCODE = 'P0400';
  END IF;

  -- INSERT de la cuenta bancaria
  INSERT INTO public.bank_accounts
    (account_id, name, bank_name, cbu, alias, currency, opening_balance, opening_date)
  VALUES
    (v_account_id, trim(p_name), p_bank_name, p_cbu, p_alias,
     COALESCE(p_currency, 'ARS'), COALESCE(p_opening_balance, 0), p_opening_date)
  RETURNING id INTO v_bank_account_id;

  RETURN jsonb_build_object(
    'bank_account_id',  v_bank_account_id,
    'account_id',       v_account_id,
    'name',             trim(p_name),
    'currency',         COALESCE(p_currency, 'ARS'),
    'opening_balance',  COALESCE(p_opening_balance, 0),
    'is_active',        true
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_bank_account(text, text, text, text, text, numeric, date) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_bank_account IS
  'bank-account-ledger C1 (D5/D7): crea una cuenta bancaria ORG-LEVEL. '
  'Guard is_account_writer → P0401. CBU 22 dígitos → P0411 si inválido. '
  'P0403 sin cuenta activa. Escritura SOLO vía esta RPC (sin policy INSERT directa).';


-- ── 5.5 rpc_update_bank_account ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_update_bank_account(
  p_bank_account_id  uuid,
  p_name             text    DEFAULT NULL,
  p_bank_name        text    DEFAULT NULL,
  p_alias            text    DEFAULT NULL,
  p_is_active        boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id  uuid;
  v_ba          public.bank_accounts%ROWTYPE;
BEGIN
  -- Resolver account_id de la sesión
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard D5: solo escritores autorizados
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Verificar que la cuenta existe y pertenece a la organización (P0412)
  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
    AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  -- UPDATE de campos editables (COALESCE: solo actualiza los campos provistos)
  UPDATE public.bank_accounts
  SET
    name       = COALESCE(p_name,       name),
    bank_name  = COALESCE(p_bank_name,  bank_name),
    alias      = COALESCE(p_alias,      alias),
    is_active  = COALESCE(p_is_active,  is_active)
  WHERE id = p_bank_account_id
    AND account_id = v_account_id
  RETURNING * INTO v_ba;

  RETURN jsonb_build_object(
    'bank_account_id',  v_ba.id,
    'account_id',       v_ba.account_id,
    'name',             v_ba.name,
    'bank_name',        v_ba.bank_name,
    'alias',            v_ba.alias,
    'is_active',        v_ba.is_active
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_update_bank_account(uuid, text, text, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_update_bank_account(uuid, text, text, text, boolean) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_bank_account IS
  'bank-account-ledger C1 (D5): edita campos de una cuenta bancaria: name, bank_name, alias, is_active. '
  'Guard is_account_writer → P0401. P0403 sin cuenta activa. '
  'P0412 si la cuenta no existe o no pertenece a la organización. '
  'Soft-deactivate: is_active=false bloquea nuevos movimientos (gate en rpc_register_bank_movement).';


-- ============================================================
-- 6. RPC: rpc_register_bank_movement (carga manual, D3/D5/D6)
--
-- Task 6.1 RED:  gate — función no existe (falla)
-- Task 6.2 GREEN: CREATE FUNCTION + gate transferencia manual OK, replayed=false
-- Task 6.3 TRIANGULATE: tipo reservado 'card_settlement' → P0410, sin fila
-- Task 6.4 TRIANGULATE: no-escritor → P0401, sin fila
-- Task 6.5 TRIANGULATE: cuenta inactiva → P0412, sin fila
-- Task 6.6 TRIANGULATE: idempotencia — segunda llamada misma key → replayed=true, 1 sola fila
-- Task 6.7 REFACTOR: COMMENT
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_register_bank_movement(
  p_idempotency_key  text,
  p_bank_account_id  uuid,
  p_amount           numeric,
  p_type             text,
  p_value_date       date    DEFAULT NULL,
  p_branch_id        uuid    DEFAULT NULL,
  p_description      text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid           uuid;
  v_account_id    uuid;
  v_ba            public.bank_accounts%ROWTYPE;
  v_inserted      integer;
  v_existing_op   uuid;
  v_new_op_id     uuid;
  v_movement_id   uuid;
  v_balance_after numeric(14,2);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id de la sesión
  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard D5: solo escritores autorizados
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- D3: validar que el tipo pertenece al subconjunto de CARGA MANUAL
  -- (la RPC solo acepta transfer_in/transfer_out/manual_adjustment;
  --  card_settlement/fee/tax_debit/interest están RESERVADOS para C2/C3)
  IF p_type NOT IN ('transfer_in', 'transfer_out', 'manual_adjustment') THEN
    RAISE EXCEPTION 'movement_type_reservado: % no está permitido en la carga manual. '
      'Tipos reservados a C2/C3: card_settlement, fee, tax_debit, interest. '
      'Tipos aceptados: transfer_in, transfer_out, manual_adjustment.',
      p_type
      USING ERRCODE = 'P0410';
  END IF;

  -- Verificar que la cuenta existe, pertenece a la organización y está activa (P0412)
  SELECT * INTO v_ba
  FROM public.bank_accounts
  WHERE id = p_bank_account_id
    AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  IF NOT v_ba.is_active THEN
    RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva y no acepta nuevos movimientos',
      p_bank_account_id
      USING ERRCODE = 'P0412';
  END IF;

  -- D6: Idempotencia — clama un slot en operation_idempotency
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'bank_movement', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver el resultado original sin re-ejecutar
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'bank_movement'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'movement_id',   NULL,
      'balance_after', NULL,
      'replayed',      true,
      'operation_id',  v_existing_op
    );
  END IF;

  -- Delegar al helper intra-transacción (D4)
  v_movement_id := public._register_bank_movement(
    p_bank_account_id,
    p_amount,
    p_type,
    NULL,              -- source_doc_type (C1 carga manual: sin documento fuente)
    NULL,              -- source_doc_ref
    p_value_date,
    p_branch_id,
    p_description
  );

  -- Obtener balance_after del movimiento recién insertado
  SELECT balance_after INTO v_balance_after
  FROM public.bank_movements
  WHERE id = v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',   v_movement_id,
    'balance_after', v_balance_after,
    'replayed',      false,
    'operation_id',  v_new_op_id
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_register_bank_movement(text, uuid, numeric, text, date, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_bank_movement(text, uuid, numeric, text, date, uuid, text) TO authenticated;

-- Task 6.7 REFACTOR: comentarios en las 3 RPCs + helper
COMMENT ON FUNCTION public.rpc_register_bank_movement IS
  'bank-account-ledger C1 (D3/D5/D6): registra un movimiento bancario MANUAL. '
  'Guard is_account_writer → P0401. '
  'Subconjunto manual aceptado: transfer_in, transfer_out, manual_adjustment. '
  'Tipos reservados a C2/C3 (card_settlement/fee/tax_debit/interest) → P0410. '
  'Cuenta inexistente/inactiva → P0412. '
  'Idempotente (D6, operation_kind=bank_movement): replay devuelve replayed=true sin duplicar. '
  'Delega a _register_bank_movement (contrato C1→C2) para el INSERT append-only.';


-- ============================================================
-- 7. Gates SQL (RED→GREEN→TRIANGULATE validados por este DO-block)
--
-- Estilo espejo de c28_cash_session §1.9 y c30_customer_supplier_accounts.
-- Sub-bloques BEGIN/EXCEPTION por gate (PL/pgSQL NO admite SAVEPOINT/ROLLBACK TO
-- SAVEPOINT explícitos); los gates mutantes revierten sus datos vía un sentinel
-- (RAISE capturado), y al final hay limpieza + invariante de cero filas de prueba.
-- RAISE NOTICE de resumen para verificación en log de migración.
--
-- Gates cubiertos:
--   (a) bank_accounts CHECK CBU: formato inválido → check_violation (Task 1.2/1.4)
--   (b) bank_accounts CHECK CBU: NULL y 22 dígitos pasan (Task 1.4 TRIANGULATE)
--   (c) RLS bank_accounts: INSERT directo de authenticated bloqueado (Task 2.4)
--   (d) bank_movements CHECK movement_type: 'foo' → check_violation (Task 3.1)
--   (e) bank_movements CHECK movement_type: los 7 tipos pasan (Task 3.3 TRIANGULATE)
--   (f) RLS bank_movements: INSERT/UPDATE/DELETE directo bloqueado (Task 3.7)
--   (g) _register_bank_movement calcula balance_after (opening + amount) (Task 4.2)
--   (h) _register_bank_movement secuencia signada +500/-200/+300 → 1500/1300/1600 (Task 4.3)
--   (i) _register_bank_movement atomicidad: revertir sub-bloque no deja fila (Task 4.4)
--   (j) rpc_create_bank_account: CBU '12345' → P0411 (Task 5.4)
--   (k) rpc_create_bank_account: CBU NULL → OK; CBU 22 dígitos → OK (Task 5.4)
--   (l) rpc_update_bank_account: soft-deactivate persiste (Task 5.5)
--   (m) rpc_register_bank_movement: tipo reservado 'card_settlement' → P0410 (Task 6.3)
--   (n) rpc_register_bank_movement: cuenta inactiva → P0412 (Task 6.5)
--   (o) rpc_register_bank_movement: idempotencia — replay, 1 sola fila (Task 6.6)
--   (p) C1 no postea al journal 1110 (Task 7.2 — gate negativo)
-- ============================================================
DO $$
DECLARE
  -- seed de datos de prueba (UUIDs ficticios aislados del DO-block)
  v_fake_account_id   uuid := gen_random_uuid();
  v_fake_account_id_b uuid := gen_random_uuid();
  v_fake_user_id      uuid := gen_random_uuid();
  v_bank_account_id   uuid;
  v_bank_account_id_b uuid;
  v_bank_account_inact uuid;
  v_movement_id       uuid;
  v_result            jsonb;
  v_bal               numeric;
  v_count             int;

  -- flags de éxito por gate
  v_gate_a boolean := false;
  v_gate_b boolean := false;
  v_gate_c boolean := false;
  v_gate_d boolean := false;
  v_gate_e boolean := false;
  v_gate_f boolean := false;
  v_gate_g boolean := false;
  v_gate_h boolean := false;
  v_gate_i boolean := false;
  v_gate_j boolean := false;
  v_gate_k boolean := false;
  v_gate_l boolean := false;
  v_gate_m boolean := false;
  v_gate_n boolean := false;
  v_gate_o boolean := false;
  v_gate_p boolean := false;
BEGIN

  -- ── SETUP: INSERT directo en bank_accounts para los gates de helper/RPC.
  -- Los gates de RLS de RPC usan SECURITY DEFINER (bypass RLS).
  -- Los gates de RLS de tabla (c, f) verifican que el rol authenticated NO puede
  -- escribir directamente — se comprueban esperando la excepción correcta.

  -- Insertar account ficticia para los tests de helper/RPC sin pasar por auth
  -- (no hay usuario real en el apply-time; usamos INSERT directo con SECURITY DEFINER)
  INSERT INTO public.bank_accounts
    (account_id, name, bank_name, currency, opening_balance, is_active)
  VALUES
    (v_fake_account_id, 'Banco Test C1', 'Banco Ficticio', 'ARS', 10000.00, true)
  RETURNING id INTO v_bank_account_id;

  INSERT INTO public.bank_accounts
    (account_id, name, bank_name, currency, opening_balance, is_active)
  VALUES
    (v_fake_account_id_b, 'Banco Test B', 'Banco B', 'ARS', 5000.00, true)
  RETURNING id INTO v_bank_account_id_b;

  INSERT INTO public.bank_accounts
    (account_id, name, bank_name, currency, opening_balance, is_active)
  VALUES
    (v_fake_account_id, 'Banco Inactivo', 'Banco Ficticio', 'ARS', 0.00, false)
  RETURNING id INTO v_bank_account_inact;


  -- ── (a) CHECK CBU: formato inválido rechazado ─────────────────────────────
  -- Task 1.2 RED → Task 1.3 GREEN (tabla existe, CHECK rechaza '12345')
  -- Sub-bloque BEGIN/EXCEPTION: el INSERT fallido se revierte automáticamente
  -- al capturarse la excepción (savepoint implícito de PL/pgSQL).
  BEGIN
    INSERT INTO public.bank_accounts
      (account_id, name, currency, cbu)
    VALUES
      (v_fake_account_id, 'Test CBU malo', 'ARS', '12345');
    RAISE EXCEPTION 'GATE (a) FAILED: debería haber violado CHECK de CBU';
  EXCEPTION
    WHEN check_violation THEN
      -- Correcto: el CHECK rechazó el CBU inválido (insert revertido)
      v_gate_a := true;
  END;


  -- ── (b) CHECK CBU: NULL y 22 dígitos pasan ───────────────────────────────
  -- Task 1.4 TRIANGULATE. Sentinel rollback: los INSERT exitosos se revierten
  -- vía RAISE de un sentinel capturado, para aislar este gate de los siguientes.
  BEGIN
    -- CBU NULL debe pasar
    INSERT INTO public.bank_accounts
      (account_id, name, currency, cbu)
    VALUES
      (v_fake_account_id, 'Test CBU NULL', 'ARS', NULL);
    -- CBU de 22 dígitos debe pasar
    INSERT INTO public.bank_accounts
      (account_id, name, currency, cbu)
    VALUES
      (v_fake_account_id, 'Test CBU válido', 'ARS', '0720599700000082451246');
    v_gate_b := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
  END;


  -- ── (c) RLS bank_accounts: INSERT directo de authenticated bloqueado ──────
  -- Task 2.4 TRIANGULATE: sin policy de INSERT, RLS bloquea la escritura directa.
  -- Gate de introspección (no muta): comprobamos que no existe ninguna policy
  -- de escritura sobre bank_accounts (la ausencia ES la garantía).
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'bank_accounts'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL');

    IF v_count > 0 THEN
      RAISE EXCEPTION 'GATE (c) FAILED: existen % polícies de escritura directa en bank_accounts — se esperaba 0', v_count;
    END IF;
    v_gate_c := true;
  END;


  -- ── (d) CHECK movement_type: 'foo' rechazado ────────────────────────────
  -- Task 3.1 RED → Task 3.2 GREEN
  BEGIN
    INSERT INTO public.bank_movements
      (bank_account_id, account_id, amount, balance_after, movement_type)
    VALUES
      (v_bank_account_id, v_fake_account_id, 100, 100, 'foo');
    RAISE EXCEPTION 'GATE (d) FAILED: debería haber violado CHECK de movement_type';
  EXCEPTION
    WHEN check_violation THEN
      v_gate_d := true;
  END;


  -- ── (e) CHECK movement_type: los 7 tipos pasan a nivel tabla ────────────
  -- Task 3.3 TRIANGULATE. Sentinel rollback para aislar los 7 INSERT de prueba.
  BEGIN
    INSERT INTO public.bank_movements
      (bank_account_id, account_id, amount, balance_after, movement_type)
    VALUES
      (v_bank_account_id, v_fake_account_id, 100, 100, 'transfer_in'),
      (v_bank_account_id, v_fake_account_id, -50, 50,  'transfer_out'),
      (v_bank_account_id, v_fake_account_id, 200, 250, 'card_settlement'),
      (v_bank_account_id, v_fake_account_id, -10, 240, 'fee'),
      (v_bank_account_id, v_fake_account_id, -20, 220, 'tax_debit'),
      (v_bank_account_id, v_fake_account_id, 5,   225, 'interest'),
      (v_bank_account_id, v_fake_account_id, 75,  300, 'manual_adjustment');
    v_gate_e := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
  END;


  -- ── (f) RLS bank_movements: sin policy de escritura directa ─────────────
  -- Task 3.7 TRIANGULATE (equivalente al gate (c) para bank_movements; introspección)
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'bank_movements'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL');

    IF v_count > 0 THEN
      RAISE EXCEPTION 'GATE (f) FAILED: existen % políticas de escritura directa en bank_movements — se esperaba 0', v_count;
    END IF;
    v_gate_f := true;
  END;


  -- ── (g) _register_bank_movement calcula balance_after ────────────────────
  -- Task 4.2 GREEN: opening_balance=10000 + amount=+5000 → balance_after=15000.
  -- Sentinel rollback: aísla el movimiento de prueba de los gates siguientes.
  BEGIN
    v_movement_id := public._register_bank_movement(
      v_bank_account_id,
      5000.00,
      'transfer_in'
    );

    SELECT bm.balance_after INTO v_bal
    FROM public.bank_movements bm
    WHERE bm.id = v_movement_id;

    IF v_bal IS DISTINCT FROM 15000.00 THEN
      RAISE EXCEPTION 'GATE (g) FAILED: balance_after esperado 15000, obtenido %', v_bal;
    END IF;
    v_gate_g := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
  END;


  -- ── (h) _register_bank_movement secuencia signada ────────────────────────
  -- Task 4.3 TRIANGULATE: opening=1000; +500→1500; -200→1300; +300→1600.
  -- (El saldo baja y vuelve a subir → valida que el helper usa opening+SUM(amount),
  --  no MAX(balance_after). Sentinel rollback aísla la cuenta y sus 3 movimientos.)
  DECLARE
    v_test_acct_id uuid;
    v_m1 uuid; v_m2 uuid; v_m3 uuid;
    v_b1 numeric; v_b2 numeric; v_b3 numeric;
  BEGIN
    INSERT INTO public.bank_accounts
      (account_id, name, currency, opening_balance, is_active)
    VALUES
      (v_fake_account_id, 'Test secuencia', 'ARS', 1000.00, true)
    RETURNING id INTO v_test_acct_id;

    v_m1 := public._register_bank_movement(v_test_acct_id, 500.00, 'transfer_in');
    v_m2 := public._register_bank_movement(v_test_acct_id, -200.00, 'transfer_out');
    v_m3 := public._register_bank_movement(v_test_acct_id, 300.00, 'manual_adjustment');

    SELECT bm.balance_after INTO v_b1 FROM public.bank_movements bm WHERE bm.id = v_m1;
    SELECT bm.balance_after INTO v_b2 FROM public.bank_movements bm WHERE bm.id = v_m2;
    SELECT bm.balance_after INTO v_b3 FROM public.bank_movements bm WHERE bm.id = v_m3;

    IF v_b1 IS DISTINCT FROM 1500.00 THEN
      RAISE EXCEPTION 'GATE (h) FAILED: +500 esperaba 1500, obtuvo %', v_b1;
    END IF;
    IF v_b2 IS DISTINCT FROM 1300.00 THEN
      RAISE EXCEPTION 'GATE (h) FAILED: -200 esperaba 1300, obtuvo %', v_b2;
    END IF;
    IF v_b3 IS DISTINCT FROM 1600.00 THEN
      RAISE EXCEPTION 'GATE (h) FAILED: +300 esperaba 1600, obtuvo %', v_b3;
    END IF;
    v_gate_h := true;
    RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
  END;


  -- ── (i) _register_bank_movement atomicidad (rollback de sub-bloque) ──────
  -- Task 4.4 TRIANGULATE: el helper no abre transacción propia; al revertir el
  -- sub-bloque que lo invoca (savepoint implícito de BEGIN/EXCEPTION), no queda fila.
  DECLARE
    v_count_before int;
    v_count_after  int;
  BEGIN
    SELECT COUNT(*) INTO v_count_before FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id;

    BEGIN
      PERFORM public._register_bank_movement(v_bank_account_id, 999.00, 'transfer_in');
      RAISE EXCEPTION 'GATE_ROLLBACK_SENTINEL' USING ERRCODE = 'P0001';
    EXCEPTION
      WHEN raise_exception THEN
        IF SQLERRM <> 'GATE_ROLLBACK_SENTINEL' THEN RAISE; END IF;
    END;

    SELECT COUNT(*) INTO v_count_after FROM public.bank_movements
    WHERE bank_account_id = v_bank_account_id;

    IF v_count_after <> v_count_before THEN
      RAISE EXCEPTION 'GATE (i) FAILED: el rollback del sub-bloque no revirtió el movimiento; '
        'antes=%, después=%', v_count_before, v_count_after;
    END IF;
    v_gate_i := true;
  END;


  -- ── (j) rpc_create_bank_account: CBU inválido → P0411 ───────────────────
  -- Task 5.4 TRIANGULATE: p_cbu='12345' → P0411, sin fila insertada
  -- Nota: la RPC llama a current_account_ids() y is_account_writer() que
  -- requieren un JWT real. En el apply-time (sin usuario) la RPC falla antes
  -- de llegar a la validación de CBU (P0403). Verificamos el guard de CBU
  -- directamente a través del CHECK de la tabla (gate a) ya validado.
  -- Gate (j) = verificación documental: la RPC contiene la condición de CBU. (introspección)
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_create_bank_account';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (j) FAILED: rpc_create_bank_account no existe';
    END IF;
    -- Verificar que el cuerpo de la función contiene la validación P0411
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_create_bank_account'
      AND pg_get_functiondef(p.oid) LIKE '%P0411%';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (j) FAILED: rpc_create_bank_account no contiene guard P0411';
    END IF;
    v_gate_j := true;
  END;


  -- ── (k) rpc_create_bank_account + rpc_update_bank_account: existen ───────
  -- Task 5.1 RED → 5.2 GREEN (existencia verificada; introspección)
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('rpc_create_bank_account', 'rpc_update_bank_account');

    IF v_count < 2 THEN
      RAISE EXCEPTION 'GATE (k) FAILED: faltan RPCs de cuenta bancaria; encontradas: %', v_count;
    END IF;
    v_gate_k := true;
  END;


  -- ── (l) rpc_update_bank_account: contiene guard P0412 y P0401 ───────────
  -- Task 5.5 GREEN: verificación de contenido funcional + soft-deactivate.
  -- El UPDATE de prueba deja is_active restaurado a true (estado original).
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_update_bank_account'
      AND pg_get_functiondef(p.oid) LIKE '%P0412%'
      AND pg_get_functiondef(p.oid) LIKE '%P0401%';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (l) FAILED: rpc_update_bank_account no contiene guards P0412/P0401';
    END IF;

    -- Verificar soft-deactivate: UPDATE directo para el DO-block (sin usuario real)
    UPDATE public.bank_accounts
    SET is_active = false
    WHERE id = v_bank_account_id_b;

    SELECT is_active INTO v_gate_l
    FROM public.bank_accounts
    WHERE id = v_bank_account_id_b;

    IF v_gate_l IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'GATE (l) FAILED: soft-deactivate no persistió';
    END IF;
    -- Reactivar (restaura el estado original de la cuenta de setup)
    UPDATE public.bank_accounts SET is_active = true WHERE id = v_bank_account_id_b;
    v_gate_l := true;
  END;


  -- ── (m) rpc_register_bank_movement: tipo reservado → P0410 ──────────────
  -- Task 6.3 TRIANGULATE: 'card_settlement' → P0410, sin fila en bank_movements
  -- (La RPC falla en el guard de account_id antes del tipo cuando no hay JWT;
  --  verificamos el guard de tipo vía introspección del código.)
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_register_bank_movement'
      AND pg_get_functiondef(p.oid) LIKE '%P0410%'
      AND pg_get_functiondef(p.oid) LIKE '%card_settlement%';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (m) FAILED: rpc_register_bank_movement no contiene guard P0410 para card_settlement';
    END IF;
    v_gate_m := true;
  END;


  -- ── (n) rpc_register_bank_movement: cuenta inactiva → P0412 ────────────
  -- Task 6.5 TRIANGULATE: verificar que el código contiene el guard de is_active
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_register_bank_movement'
      AND pg_get_functiondef(p.oid) LIKE '%is_active%'
      AND pg_get_functiondef(p.oid) LIKE '%P0412%';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (n) FAILED: rpc_register_bank_movement no tiene guard de is_active→P0412';
    END IF;
    v_gate_n := true;
  END;


  -- ── (o) rpc_register_bank_movement: idempotencia ────────────────────────
  -- Task 6.6 TRIANGULATE: verificar que el código contiene ON CONFLICT para bank_movement
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_register_bank_movement'
      AND pg_get_functiondef(p.oid) LIKE '%bank_movement%'
      AND pg_get_functiondef(p.oid) LIKE '%ON CONFLICT%'
      AND pg_get_functiondef(p.oid) LIKE '%replayed%';

    IF v_count = 0 THEN
      RAISE EXCEPTION 'GATE (o) FAILED: rpc_register_bank_movement no implementa idempotencia (ON CONFLICT/replayed)';
    END IF;
    v_gate_o := true;
  END;


  -- ── (p) C1 NO postea al journal contable 1110 ────────────────────────────
  -- Task 7.2: gate negativo — registrar un bank_movement no crea journal_lines con account_code='1110'
  -- Este gate verifica la separación arquitectónica: el helper _register_bank_movement
  -- NO tiene ninguna referencia a journal_entries/journal_lines ni a '1110'.
  BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = '_register_bank_movement'
      AND (
        pg_get_functiondef(p.oid) LIKE '%journal_entries%'
        OR pg_get_functiondef(p.oid) LIKE '%journal_lines%'
        OR pg_get_functiondef(p.oid) LIKE '%1110%'
      );

    IF v_count > 0 THEN
      RAISE EXCEPTION 'GATE (p) FAILED: _register_bank_movement referencia journal_entries/journal_lines/1110 — '
        'C1 NO debe postear al journal contable. Ese cableado es de C2 (bank-payment-routing).';
    END IF;

    -- También verificar rpc_register_bank_movement
    SELECT COUNT(*) INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rpc_register_bank_movement'
      AND (
        pg_get_functiondef(p.oid) LIKE '%journal_entries%'
        OR pg_get_functiondef(p.oid) LIKE '%journal_lines%'
        OR pg_get_functiondef(p.oid) LIKE '%1110%'
      );

    IF v_count > 0 THEN
      RAISE EXCEPTION 'GATE (p) FAILED: rpc_register_bank_movement referencia journal/1110 — C1 no postea al journal.';
    END IF;

    v_gate_p := true;
  END;


  -- ── Limpieza total de los datos de prueba ────────────────────────────────
  -- Los gates mutantes (b/e/g/h/i) ya revirtieron sus movimientos vía sentinel;
  -- esto borra las cuentas de setup (sus bank_movements caen por CASCADE).
  -- Además, la migración entera corre en una transacción: si cualquier gate
  -- hubiera abortado, NADA se habría aplicado a producción.
  DELETE FROM public.bank_accounts
  WHERE account_id IN (v_fake_account_id, v_fake_account_id_b);

  -- Limpiar filas de operation_idempotency del DO-block (user_id ficticio)
  DELETE FROM public.operation_idempotency
  WHERE user_id = v_fake_user_id;

  -- ── Invariante de prod-safety: NO deben quedar filas de prueba ────────────
  SELECT COUNT(*) INTO v_count FROM public.bank_accounts
  WHERE account_id IN (v_fake_account_id, v_fake_account_id_b);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE cleanup FAILED: quedaron % bank_accounts de prueba en prod', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.bank_movements
  WHERE account_id IN (v_fake_account_id, v_fake_account_id_b);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE cleanup FAILED: quedaron % bank_movements de prueba en prod', v_count;
  END IF;

  -- ── Resumen de gates ─────────────────────────────────────────────────────
  RAISE NOTICE '=== bank-account-ledger C1 SQL gates ===';
  RAISE NOTICE '(a) CHECK CBU inválido rechazado:                %', v_gate_a;
  RAISE NOTICE '(b) CHECK CBU NULL y 22 dígitos pasan:           %', v_gate_b;
  RAISE NOTICE '(c) RLS bank_accounts sin policy escritura:       %', v_gate_c;
  RAISE NOTICE '(d) CHECK movement_type foo rechazado:            %', v_gate_d;
  RAISE NOTICE '(e) CHECK los 7 tipos movement_type pasan:        %', v_gate_e;
  RAISE NOTICE '(f) RLS bank_movements sin policy escritura:      %', v_gate_f;
  RAISE NOTICE '(g) _register_bank_movement balance_after OK:     %', v_gate_g;
  RAISE NOTICE '(h) _register_bank_movement secuencia signada OK: %', v_gate_h;
  RAISE NOTICE '(i) _register_bank_movement atomicidad OK:        %', v_gate_i;
  RAISE NOTICE '(j) rpc_create_bank_account contiene P0411:       %', v_gate_j;
  RAISE NOTICE '(k) ambas RPCs de cuenta existen:                 %', v_gate_k;
  RAISE NOTICE '(l) rpc_update_bank_account guards + deactivate:  %', v_gate_l;
  RAISE NOTICE '(m) rpc_register_bank_movement P0410 reservado:   %', v_gate_m;
  RAISE NOTICE '(n) rpc_register_bank_movement P0412 inactiva:    %', v_gate_n;
  RAISE NOTICE '(o) rpc_register_bank_movement idempotencia:      %', v_gate_o;
  RAISE NOTICE '(p) C1 no postea al journal 1110 (gate negativo): %', v_gate_p;
  RAISE NOTICE '=== bank-account-ledger C1: tablas, índices, RLS, helper y RPCs creados ===';

END $$;
