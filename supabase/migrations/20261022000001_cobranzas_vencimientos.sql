-- =============================================================================
-- MIGRATION: 20261022000001_cobranzas_vencimientos.sql
-- CHANGE: cobranzas-vencimientos (Etapa B del módulo de cobranzas)
-- Design ref: openspec/changes/cobranzas-vencimientos/design.md
--
-- Implementa (grupos 2-5 del tasks.md):
--   G1  Columnas de plazo (accounts/clients/suppliers, smallint NULL CHECK>=0)
--       y de vencimiento (due_date date NULL en los dos ledgers). SIN default,
--       SIN backfill (D2: DEFAULT 0 declararía morosa a toda la deuda nueva).
--   G2  DROP+CREATE de los helpers de cargo (c30_register_* + _pay_register_
--       party_charge) con el vencimiento trailing; la cascada de plazos se
--       resuelve SOLO en el helper compartido (D3). DROP+CREATE de los
--       caminos de alta que ganan p_due_date (wrapper + v2 + compra).
--   G3  DROP+CREATE de rpc_receivables_report (RETURNS extendido con aging
--       FIFO por línea de flotación, D4/D5) + rpc_payables_report (espejo)
--       + rpc_set_default_payment_terms.
--   G4  Barrido diario _produce_receivables_overdue_digest (molde
--       _produce_plan_expiring_soon, dedup por día argentino en dos capas,
--       D8) + _notification_from_event con los 2 tipos nuevos (9º y 10º del
--       Consumer 4) + pg_cron.
--
-- GATE DE INTEGRIDAD DE FUNCIÓN — md5(pg_get_functiondef) VIVO de prod,
-- capturado 2026-09-02 (checkpoint 1.3; toda reescritura parte de ese cuerpo):
--   _pay_register_party_charge(6 args)        61c54436467afaf6b43afdbd5a5fa1ad
--   c30_register_customer_account_movement(4) b8dcff26fbc713e70cb579fc6d6945c6
--   c30_register_supplier_account_movement(4) 8bf20071d75e41935299378c2b832bd6
--   rpc_create_sale_operation(10)             74c8bfb096ec770ab43e4ba47111bfed
--   rpc_create_sale_operation_v2(10)          0b6bcc5b6caa1a3c01e0da16518c7d35
--   rpc_create_purchase_operation(10)         3838dd2a4bf7bc028fca53c99c82254c
--   rpc_receivables_report(uuid)              52d49e127e1cbdb7cf588abe25c7e9d1
--   _notification_from_event(events)          6c697712bf6c663347326fa91b000960
--   _c29_confirm_order_core(9)                ff2aa9a2ea61a0f883e9ebf003c00d68
--
-- DESVÍOS DEL DESIGN, con razón (reportados en el apply):
--   (a) El design listaba 3 callers de alta; el cuerpo VIVO muestra que
--       rpc_create_sale_operation es un wrapper strangler que delega en
--       rpc_create_sale_operation_v2 (flag default ON) — el camino real del
--       formulario es la v2 y también se extiende (si no, la feature no
--       existiría para ningún tenant). Mismo precedente que p_cash_session_id
--       y p_bank_account_id, que ya se propagaron a la v2.
--   (b) El proposal decía "CREATE OR REPLACE (misma firma)" para los callers,
--       pero ganan un parámetro → sería un overload vivo (gotcha 42725, ya
--       cobrado 2 veces). Van por DROP+CREATE con ACLs re-emitidas, igual que
--       hizo caja-compras-cobranzas con estas MISMAS funciones.
--   (c) _c29_confirm_order_core NO se reescribe: su llamada corta al helper
--       ya ES la semántica D11 (sin override → el helper resuelve la
--       cascada). Reescribir 400 líneas SECURITY DEFINER de dinero para no
--       cambiar nada es riesgo sin beneficio; la simetría form/POS la fija
--       el gate test_cobranzas_vencimientos_schema.sql (7).
--   (d) El helper gana DOS trailing (p_charge_date, p_due_date), no uno: el
--       guard P0400 y la cascada anclan a la FECHA DE NEGOCIO del cargo
--       (los formularios admiten fechas pasadas; el spec exige aceptar un
--       vencimiento ya cumplido pero posterior al cargo), y el helper no la
--       conocía. p_due_date sigue siendo el último, como exige el spec.
--
-- ACLs VIVAS (checkpoint 1.4, 2026-09-02) que este archivo REPLICA:
--   _pay_register_party_charge: postgres+service_role — SIN authenticated NI
--     anon (hotfix 20261010000001/#454; re-otorgar reabriría el cross-tenant).
--   c30_register_*: anon+authenticated+service_role (estado vivo; el
--     endurecimiento es el candidato h3, FUERA de este alcance).
--   rpc_create_*: authenticated+service_role (sin anon).
--
-- IDEMPOTENCIA: reaplicable dos veces (auto-apply de Supabase GitHub):
--   ADD COLUMN IF NOT EXISTS; CHECK por DO-guard; DROP IF EXISTS de la firma
--   VIEJA (no-op en la reaplicación) + CREATE OR REPLACE de la nueva;
--   cron.unschedule condicional + schedule.
--
-- ROLLBACK (en orden):
--   SELECT cron.unschedule('cobranzas-overdue-digest-sweep') FROM cron.job
--     WHERE jobname = 'cobranzas-overdue-digest-sweep';
--   DROP FUNCTION IF EXISTS public._produce_receivables_overdue_digest();
--   -- _notification_from_event: restaurar 20260830000002 (8 tipos).
--   DROP FUNCTION IF EXISTS public.rpc_set_default_payment_terms(smallint);
--   DROP FUNCTION IF EXISTS public.rpc_payables_report(uuid);
--   -- rpc_receivables_report: restaurar 20261021000001 (firma Etapa A).
--   -- helpers de cargo y RPCs de alta: DROP de la aridad nueva + CREATE de
--   --   los cuerpos hasheados arriba, con las MISMAS ACLs vivas.
--   -- Las columnas SE DEJAN (aditivas, nullable, sin lectores tras el
--   --   rollback): dropearlas perdería vencimientos ya pactados.
-- =============================================================================


-- =============================================================================
-- 1. COLUMNAS — plazo en tres niveles + vencimiento en los dos ledgers
-- =============================================================================
ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS default_payment_terms_days smallint;
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS payment_terms_days smallint;
ALTER TABLE public.suppliers
  ADD COLUMN IF NOT EXISTS payment_terms_days smallint;
ALTER TABLE public.customer_account_movements
  ADD COLUMN IF NOT EXISTS due_date date;
ALTER TABLE public.supplier_account_movements
  ADD COLUMN IF NOT EXISTS due_date date;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'accounts_default_payment_terms_days_nonneg') THEN
    ALTER TABLE public.accounts
      ADD CONSTRAINT accounts_default_payment_terms_days_nonneg
      CHECK (default_payment_terms_days IS NULL OR default_payment_terms_days >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'clients_payment_terms_days_nonneg') THEN
    ALTER TABLE public.clients
      ADD CONSTRAINT clients_payment_terms_days_nonneg
      CHECK (payment_terms_days IS NULL OR payment_terms_days >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'suppliers_payment_terms_days_nonneg') THEN
    ALTER TABLE public.suppliers
      ADD CONSTRAINT suppliers_payment_terms_days_nonneg
      CHECK (payment_terms_days IS NULL OR payment_terms_days >= 0);
  END IF;
END $$;

COMMENT ON COLUMN public.accounts.default_payment_terms_days IS
  'cobranzas-vencimientos (D2): plazo de pago por defecto de la cuenta, en '
  'días. NULL = "sin plazo definido" (los cargos nacen SIN vencimiento) — '
  'NUNCA significa cero. 0 explícito = contado a la vista.';
COMMENT ON COLUMN public.clients.payment_terms_days IS
  'cobranzas-vencimientos (D2): plazo de pago propio del cliente — gana al '
  'default de la cuenta. NULL = hereda el de la cuenta (y si la cuenta '
  'tampoco tiene, el cargo nace sin vencimiento); nunca significa cero.';
COMMENT ON COLUMN public.suppliers.payment_terms_days IS
  'cobranzas-vencimientos (D2): plazo de pago propio del proveedor — espejo '
  'exacto de clients.payment_terms_days. NULL = hereda / sin vencimiento.';
COMMENT ON COLUMN public.customer_account_movements.due_date IS
  'cobranzas-vencimientos (D1): vencimiento del CARGO, congelado en el mismo '
  'INSERT que crea el movimiento (patrón snapshot) — jamás se recalcula ni '
  'se actualiza. Solo los cargos lo llevan; NULL = "cargo sin vencimiento" '
  '(históricos sin backfill, y toda cuenta sin plazo configurado).';
COMMENT ON COLUMN public.supplier_account_movements.due_date IS
  'cobranzas-vencimientos (D1): vencimiento del cargo de compra (fecha en '
  'que corresponde pagarle al proveedor), congelado al postear. NULL = sin '
  'vencimiento. Espejo exacto del lado cliente.';


-- =============================================================================
-- 2. HELPERS DE CARGO — DROP de la firma vieja + CREATE con el vencimiento
--    trailing. Cuerpos = los VIVOS de prod (hashes en cabecera) + diff mínimo.
-- =============================================================================

DROP FUNCTION IF EXISTS public.c30_register_customer_account_movement(uuid, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.c30_register_customer_account_movement(
  p_account_id   uuid,
  p_amount       numeric,
  p_type         text,
  p_reference_id uuid DEFAULT NULL,
  p_due_date     date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
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

  -- INSERT append-only en el ledger. cobranzas-vencimientos (D1): due_date
  -- viaja en el MISMO INSERT — snapshot, nunca un UPDATE posterior.
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, reference_id, due_date, created_by)
  VALUES
    (p_account_id, v_acc.account_id, p_amount, v_balance_after, p_type, p_reference_id, p_due_date, auth.uid())
  RETURNING id INTO v_movement_id;

  -- UPDATE de la cabecera (UPDATE-then-INSERT bajo FOR UPDATE, D1/gotcha #2)
  UPDATE public.customer_accounts
  SET balance = v_balance_after
  WHERE id = p_account_id;

  RETURN v_movement_id;
END;
$function$;

-- ACLs VIVAS replicadas (checkpoint 1.4): anon+authenticated+service_role.
-- El endurecimiento (quitar anon/authenticated) es el candidato h3 — FUERA de
-- este alcance; cuando h3 lo haga, debe actualizar también el assert (4b) de
-- test_cobranzas_vencimientos_schema.sql.
REVOKE ALL ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date) TO anon;
GRANT EXECUTE ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date) TO service_role;

COMMENT ON FUNCTION public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date) IS
  'C-30 + cobranzas-vencimientos: helper intra-transacción del ledger de '
  'cliente. FOR UPDATE en cabecera, balance_after materializado, INSERT '
  'append-only con due_date (5º arg, trailing, NULL = sin vencimiento). '
  'Redefinida por DROP+CREATE (nunca OR REPLACE con default nuevo — 42725).';


DROP FUNCTION IF EXISTS public.c30_register_supplier_account_movement(uuid, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.c30_register_supplier_account_movement(
  p_account_id   uuid,
  p_amount       numeric,
  p_type         text,
  p_reference_id uuid DEFAULT NULL,
  p_due_date     date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
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

  -- INSERT append-only. cobranzas-vencimientos (D1): due_date en el mismo INSERT.
  INSERT INTO public.supplier_account_movements
    (supplier_account_id, account_id, amount, balance_after, movement_type, reference_id, due_date, created_by)
  VALUES
    (p_account_id, v_acc.account_id, p_amount, v_balance_after, p_type, p_reference_id, p_due_date, auth.uid())
  RETURNING id INTO v_movement_id;

  -- UPDATE cabecera
  UPDATE public.supplier_accounts
  SET balance = v_balance_after
  WHERE id = p_account_id;

  RETURN v_movement_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date) TO anon;
GRANT EXECUTE ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date) TO service_role;

COMMENT ON FUNCTION public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date) IS
  'C-30 + cobranzas-vencimientos: espejo exacto del helper de cliente para '
  'el ledger de proveedor, con due_date como 5º arg trailing.';


DROP FUNCTION IF EXISTS public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid);

CREATE OR REPLACE FUNCTION public._pay_register_party_charge(
  p_account_id   uuid,
  p_party_kind   text,
  p_party_id     uuid,
  p_amount       numeric,
  p_reference_id uuid,
  p_operation_id uuid,
  p_charge_date  date DEFAULT NULL,
  p_due_date     date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
/*
  pagos-cableados-restantes (D1) + cobranzas-vencimientos (D2/D3): punto de
  paso ÚNICO del cargo en cuenta corriente Y único lugar donde se resuelve el
  vencimiento. Los callers sólo TRANSPORTAN (p_charge_date = fecha de negocio
  de la operación; p_due_date = override explícito del formulario); acá:
    - override explícito → gana tal cual, con guard P0400 si es anterior a la
      fecha del cargo (un cargo no puede vencer antes de existir; uno vencido
      pero posterior al cargo es legítimo — venta de la semana pasada).
    - sin override → COALESCE(plazo de la parte, plazo default de la cuenta)
      sumado a la fecha del cargo; sin plazo en ningún nivel → due_date NULL
      ("sin vencimiento", D2 — NUNCA se asume un plazo).
  El POS llama con la firma corta (sin fechas): charge_date = hoy argentino y
  cascada — exactamente D11.
*/
DECLARE
  v_party_account_id uuid;
  v_charge_date      date;
  v_terms            smallint;
  v_due_date         date;
BEGIN
  v_charge_date := COALESCE(p_charge_date, public.reporting_local_today());

  IF p_due_date IS NOT NULL THEN
    IF p_due_date < v_charge_date THEN
      RAISE EXCEPTION 'due_date_before_charge: el vencimiento (%) no puede ser anterior a la fecha del cargo (%)',
        p_due_date, v_charge_date
        USING ERRCODE = 'P0400';
    END IF;
    v_due_date := p_due_date;
  END IF;

  IF p_party_kind = 'customer' THEN
    v_party_account_id := public.c30_get_or_create_customer_account(p_account_id, p_party_id);

    IF p_due_date IS NULL THEN
      SELECT COALESCE(
               (SELECT c.payment_terms_days FROM public.clients  c WHERE c.id = p_party_id),
               (SELECT a.default_payment_terms_days FROM public.accounts a WHERE a.id = p_account_id)
             )
      INTO v_terms;
      v_due_date := CASE WHEN v_terms IS NULL THEN NULL ELSE v_charge_date + v_terms END;
    END IF;

    PERFORM public.c30_register_customer_account_movement(
      v_party_account_id, p_amount, 'sale', p_reference_id, v_due_date
    );

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'CustomerAccountCharged',
      'CustomerAccount',
      v_party_account_id,
      jsonb_build_object(
        'account_id',          p_account_id,
        'customer_account_id', v_party_account_id,
        'client_id',           p_party_id,
        'sales_order_id',      p_reference_id,
        'operation_id',        p_operation_id,
        'amount',              p_amount,
        'occurred_at',         now()
      ),
      now()
    );

  ELSIF p_party_kind = 'supplier' THEN
    v_party_account_id := public.c30_get_or_create_supplier_account(p_account_id, p_party_id);

    IF p_due_date IS NULL THEN
      SELECT COALESCE(
               (SELECT s.payment_terms_days FROM public.suppliers s WHERE s.id = p_party_id),
               (SELECT a.default_payment_terms_days FROM public.accounts a WHERE a.id = p_account_id)
             )
      INTO v_terms;
      v_due_date := CASE WHEN v_terms IS NULL THEN NULL ELSE v_charge_date + v_terms END;
    END IF;

    PERFORM public.c30_register_supplier_account_movement(
      v_party_account_id, p_amount, 'purchase', p_reference_id, v_due_date
    );

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      p_account_id,
      'SupplierAccountCharged',
      'SupplierAccount',
      v_party_account_id,
      jsonb_build_object(
        'account_id',           p_account_id,
        'supplier_account_id',  v_party_account_id,
        'supplier_id',          p_party_id,
        'reference_id',         p_reference_id,
        'operation_id',         p_operation_id,
        'amount',               p_amount,
        'occurred_at',          now()
      ),
      now()
    );

  ELSE
    RAISE EXCEPTION 'invalid_party_kind: % (esperado customer|supplier)', p_party_kind
      USING ERRCODE = 'P0400';
  END IF;

  RETURN v_party_account_id;
END;
$function$;

-- ⚠️ ACLs VIVAS replicadas (hotfix 20261010000001 / PR #454): este helper
-- NO es ejecutable por PUBLIC, anon NI authenticated — sólo lo invocan RPCs
-- SECURITY DEFINER. Re-otorgar authenticated acá reabriría una escritura
-- cross-tenant ya cerrada (lo custodian los chequeos (3) y (4) del gate de
-- ACLs, sin allowlist).
REVOKE ALL ON FUNCTION public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid, date, date) FROM anon;
REVOKE EXECUTE ON FUNCTION public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid, date, date) FROM authenticated;

COMMENT ON FUNCTION public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid, date, date) IS
  'pagos-cableados-restantes (D1) + cobranzas-vencimientos (D2/D3): autoría '
  'única del cargo en cuenta corriente Y de la resolución del vencimiento '
  '(cascada parte→cuenta; override explícito con guard P0400). REVOCADO de '
  'PUBLIC/anon/authenticated (hotfix #454) — sólo RPCs SECURITY DEFINER.';


-- =============================================================================
-- 3. CAMINOS DE ALTA — transportan (p_charge_date, p_due_date) al helper.
--    DROP+CREATE (ganan un arg → nunca OR REPLACE, 42725). Cuerpos VIVOS.
--    _c29_confirm_order_core NO se toca (desvío (c) de la cabecera).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(
  p_idempotency_key   text,
  p_client_id         uuid,
  p_date              date,
  p_currency          text,
  p_items             jsonb,
  p_branch_id         uuid DEFAULT NULL::uuid,
  p_canal             text DEFAULT NULL::text,
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_bank_account_id   uuid DEFAULT NULL::uuid,
  p_due_date          date DEFAULT NULL::date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_flag_on    boolean := false;
  v_uid        uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  -- deudas-menores-agosto (G1/D1): ausencia de fila = v2 (antes: legacy). El
  -- COALESCE va DESPUÉS del SELECT — SELECT ... INTO sin fila deja v_flag_on
  -- en NULL, y el COALESCE de acá lo resuelve a true. Ponerlo DENTRO del
  -- SELECT (como antes) no ejecuta nada cuando no hay fila y v_flag_on queda
  -- NULL (≈ false en el IF), que es exactamente el bug que se corrige.
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  IF v_flag_on THEN
    -- pagos-cableados-restantes: propaga p_cash_session_id a la v2.
    -- pos-banco-movimientos: propaga p_bank_account_id a la v2 (D6).
    -- cobranzas-vencimientos: propaga p_due_date a la v2 (el camino vivo).
    RETURN public.rpc_create_sale_operation_v2(
      p_idempotency_key, p_client_id, p_date, p_currency, p_items,
      p_branch_id, p_canal, p_payment_method_id, p_cash_session_id, p_bank_account_id,
      p_due_date
    );
  ELSE
    DECLARE
      v_new_op_id    uuid;
      v_existing_op  uuid;
      v_item         RECORD;
      v_product      RECORD;
      v_branch       RECORD;
      v_gate_branch  uuid;
      v_new_sale_id  uuid;
      v_result_items jsonb := '[]'::jsonb;
      v_qty_before   numeric;
      v_qty_after    numeric;
      v_unit_factor  numeric(20,10);
      v_qty_norm     numeric(15,4);
      v_branch_qty   numeric(15,4);
      v_inserted     integer;
      v_canal        text;
      -- pagos-cableados-restantes (task 5.3): mismo trío que la rama v2.
      v_kind                  text;
      v_total_sum             numeric(15,2) := 0;
      v_cash_session_status   text;
      v_cash_session_branch   uuid;
    BEGIN
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
          USING ERRCODE = 'P0403';
      END IF;

      IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
      END IF;

      IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
      END IF;

      IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
      END IF;

      v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
      IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
        RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
      END IF;

      -- pagos-cableados-restantes: mismo patrón de derivación de kind que la v2.
      -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id)
      IF p_payment_method_id IS NOT NULL THEN
        SELECT kind INTO v_kind
        FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'payment_method_not_found or not active for this account'
            USING ERRCODE = 'P0404';
        END IF;
      END IF;

      IF v_kind = 'credit' AND p_client_id IS NULL THEN
        RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id'
          USING ERRCODE = 'P0400';
      END IF;

      -- C-26: la branch explícita debe existir, estar activa Y operativa
      IF p_branch_id IS NOT NULL THEN
        SELECT id, status INTO v_branch
        FROM public.branches
        WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'branch_not_found or not active for this account'
            USING ERRCODE = 'P0404';
        END IF;
        IF v_branch.status = 'closed' THEN
          RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-26: branch del gate y del descuento (explícita o default operativa)
      v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

      v_new_op_id := gen_random_uuid();

      INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
      VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
      ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

      GET DIAGNOSTICS v_inserted = ROW_COUNT;

      IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'sale'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                 jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
                 '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.sales s
        WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

        RETURN jsonb_build_object(
          'operation_id', v_existing_op,
          'items',        v_result_items,
          'replayed',     true
        );
      END IF;

      FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                 AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
        ORDER BY product_id
      LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
          RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
          RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
        END IF;

        -- pagos-cableados-restantes: acumular total (mismo patrón que la v2).
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        v_unit_factor := 1.0;
        IF v_item.unit_id IS NOT NULL THEN
          SELECT factor INTO v_unit_factor
          FROM   public.units_of_measure
          WHERE  id = v_item.unit_id;
          IF NOT FOUND THEN
            RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P0404';
          END IF;
        END IF;
        v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

        IF v_item.product_id IS NOT NULL THEN
          SELECT id, user_id, is_variant, name, sku, cost INTO v_product
          FROM   public.products
          WHERE  id = v_item.product_id
          FOR UPDATE;

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
          END IF;

          IF v_product.user_id <> v_uid THEN
            RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
          END IF;

          IF NOT v_product.is_variant THEN
            IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
              RAISE EXCEPTION
                'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
                USING ERRCODE = 'P0422';
            END IF;
          END IF;

          -- C-26 (OQ-A): gate per-branch — el stock debe estar EN la branch
          -- de la operación (explícita o default operativa)
          SELECT COALESCE(quantity, 0) INTO v_branch_qty
          FROM   public.branch_stock
          WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
          v_branch_qty := COALESCE(v_branch_qty, 0);

          IF v_branch_qty < v_qty_norm THEN
            IF p_branch_id IS NOT NULL THEN
              RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            ELSE
              RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            END IF;
          END IF;

          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, v_item.product_id,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             p_branch_id, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;

          v_qty_before := v_branch_qty;
          v_qty_after  := v_branch_qty - v_qty_norm;

          PERFORM public.c21_apply_branch_stock_delta(
            v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

          -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id, branch_id, unit_cost_snapshot
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
            -v_qty_norm, v_qty_before, v_qty_after,
            v_new_sale_id, 'sale', v_uid,
            v_new_op_id, p_branch_id, v_product.cost
          );

        ELSE
          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, NULL,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             p_branch_id, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;
        END IF;

        v_result_items := v_result_items
          || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
      END LOOP;

      -- pagos-cableados-restantes (task 5.3/6.2): mismo trío opt-in de caja
      -- + cargo de crédito que la rama v2 — la rama legacy queda consistente.
      IF p_cash_session_id IS NOT NULL THEN
        IF v_kind IS DISTINCT FROM 'cash' THEN
          RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
            USING ERRCODE = 'P0422';
        END IF;

        SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
        FROM public.cash_sessions cs
        JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
        WHERE cs.id = p_cash_session_id;

        IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
          RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
            USING ERRCODE = 'P0422';
        END IF;

        IF p_date <> public.reporting_local_today() THEN
          RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una venta fechada hoy (%)', public.reporting_local_today()
            USING ERRCODE = 'P0422';
        END IF;

        PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total_sum, 'sale', v_new_op_id);
      END IF;

      -- cobranzas-vencimientos (D3): la rama legacy transporta la fecha de
      -- negocio y el override al helper — la MISMA llamada que la v2.
      IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
          v_account_id, 'customer', p_client_id, v_total_sum, v_new_op_id, v_new_op_id,
          p_date, p_due_date
        );
      END IF;

      -- pos-banco-movimientos (D5, task 5.1): rama legacy — mismo helper y
      -- mismo punto que la v2, para que ambas ramas del strangler queden
      -- consistentes (regla dura del proyecto: no duplicar la regla).
      PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'in', 'sale', v_new_op_id,
        p_date, v_gate_branch, NULL
      );

      RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
      );
    END;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) TO service_role;


DROP FUNCTION IF EXISTS public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation_v2(
  p_idempotency_key   text,
  p_client_id         uuid,
  p_date              date,
  p_currency          text,
  p_items             jsonb,
  p_branch_id         uuid DEFAULT NULL::uuid,
  p_canal             text DEFAULT NULL::text,
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_bank_account_id   uuid DEFAULT NULL::uuid,
  p_due_date          date DEFAULT NULL::date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_new_op_id    uuid;
  v_existing_op  uuid;
  v_item         RECORD;
  v_product      RECORD;
  v_branch       RECORD;
  v_gate_branch  uuid;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_unit_factor  numeric(20,10);
  v_qty_norm     numeric(15,4);
  v_branch_qty   numeric(15,4);
  v_inserted     integer;
  v_canal        text;
  -- pagos-cableados-restantes (D1/D4/D5): kind derivado + total acumulado
  -- para el cargo de crédito y el movimiento de caja opt-in.
  v_kind                  text;
  v_total_sum             numeric(15,2) := 0;
  v_cash_session_status   text;
  v_cash_session_branch   uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
      USING ERRCODE = 'P0403';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
  END IF;

  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
  IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
    RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
  END IF;

  -- pagos-cableados-restantes (D1 de pos-catalogo-pagos, reaplicado): el
  -- kind se DERIVA del catálogo — nunca se acepta como texto del cliente.
  -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id).
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = v_account_id
      AND is_active = TRUE AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- pagos-cableados-restantes (D5): crédito es obligatorio, nunca opcional —
  -- ANTES del descuento de stock (task 5.2). No hay "vender a cuenta
  -- corriente sin anotarlo".
  IF v_kind = 'credit' AND p_client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- C-26: la branch explícita debe existir, estar activa Y operativa
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch del gate y del descuento (explícita o default operativa)
  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'sale'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.sales s
    WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    -- pagos-cableados-restantes: acumular total para el cargo de crédito y/o
    -- el movimiento de caja opt-in (mismo patrón que rpc_create_purchase_operation).
    v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost a la lectura ya existente
      -- (name, is_variant) para congelar name/sku/cost sin un SELECT extra.
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      IF v_product.user_id <> v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-26 (OQ-A): gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        IF p_branch_id IS NOT NULL THEN
          RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        ELSE
          RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        END IF;
      END IF;

      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product ya cargado.
      -- iva_rate_snapshot: products no tiene columna de IVA (D3) → NULL.
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

      -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, p_branch_id, v_product.cost
      );

    ELSE
      -- v3-snapshot-pattern (2.6): línea de servicio — name_snapshot no
      -- disponible en el payload legacy de esta RPC (solo amount/quantity/
      -- unit_id); queda NULL como hoy. La línea de servicio con
      -- name_snapshot desde payload se resuelve en _c29_confirm_order_core
      -- (sales_order_items ya trae el nombre desde el frontend — ver 2.4/2.6).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- pagos-cableados-restantes (OQ-C, D4): opt-in de caja — las tres
  -- condiciones se validan en el SERVIDOR (kind cash + sesión abierta en la
  -- sucursal EFECTIVA + fecha de hoy en ART), nunca se confía en la UI. La
  -- ausencia de p_cash_session_id es no-op (D5 — compatible hacia atrás con
  -- las 223 operaciones históricas del formulario).
  IF p_cash_session_id IS NOT NULL THEN
    IF v_kind IS DISTINCT FROM 'cash' THEN
      RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
        USING ERRCODE = 'P0422';
    END IF;

    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cs.id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
        USING ERRCODE = 'P0422';
    END IF;

    IF p_date <> public.reporting_local_today() THEN
      RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una venta fechada hoy (%)', public.reporting_local_today()
        USING ERRCODE = 'P0422';
    END IF;

    PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total_sum, 'sale', v_new_op_id);
  END IF;

  -- pagos-cableados-restantes (OQ-D, D2/D5): crédito SIEMPRE postea el
  -- cargo, vía el mismo helper compartido que usa el POS — una sola
  -- definición de "cargar una venta a cuenta corriente" (D1).
  -- cobranzas-vencimientos (D3): transporta la fecha de negocio (p_date) y
  -- el override (p_due_date) — la cascada se resuelve EN el helper, nunca acá.
  IF v_kind = 'credit' THEN
    PERFORM public._pay_register_party_charge(
      v_account_id, 'customer', p_client_id, v_total_sum, v_new_op_id, v_new_op_id,
      p_date, p_due_date
    );
  END IF;

  -- pos-banco-movimientos (D5, task 5.1): movimiento bancario operativo del
  -- formulario de venta — mismo helper que el POS, mismo punto (después de
  -- caja/crédito). p_value_date = p_date (el form admite fechas pasadas —
  -- D4, guard P0424 dentro del helper).
  PERFORM public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    v_total_sum, 'in', 'sale', v_new_op_id,
    p_date, v_gate_branch, NULL
  );

  -- asiento-venta-formulario (D6): evento del outbox — INSERT plano, SIN
  -- bloque EXCEPTION. Si esto falla y la venta igual commitea, el
  -- resultado es exactamente el bug que este change arregla (venta sin
  -- asiento) pero silencioso — swallowear el fallo no es aceptable.
  -- payment_method va CRUDO (v_kind), sin COALESCE: el default vive en la
  -- rama del consumidor, no en el payload (D6 — lección de pagos-cableados-
  -- restantes D7 con el 'credit' cableado de compras).
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationCreated', 'SaleOperation', v_new_op_id,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_new_op_id,
      'total',          v_total_sum,
      'payment_method', v_kind,
      'client_id',      p_client_id,
      'sale_date',      p_date,
      'occurred_at',    now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date) TO service_role;


DROP FUNCTION IF EXISTS public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
  p_idempotency_key   text,
  p_date              date,
  p_description       text,
  p_items             jsonb,
  p_branch_id         uuid DEFAULT NULL::uuid,
  p_cost_center_id    uuid DEFAULT NULL::uuid,
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_bank_account_id   uuid DEFAULT NULL::uuid,
  p_supplier_id       uuid DEFAULT NULL::uuid,
  p_cash_session_id   uuid DEFAULT NULL::uuid,
  p_due_date          date DEFAULT NULL::date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  v3-snapshot-pattern: agrega name_snapshot/sku_snapshot/unit_cost_snapshot/
  iva_rate_snapshot al INSERT de purchases (D2 — el write path real de
  compra) y unit_cost_snapshot al stock_movements de compra. Preserva
  íntegro el fix de 20260804000004 (ON CONFLICT 3-col + branch_stock, sin
  products.stock).

  deudas-menores-agosto (G1): agrega la resolución del flag
  'sale_items_rpc_v2' (mismo patrón COALESCE-después-del-SELECT que
  rpc_create_sale_operation) y, condicionado por ella, el INSERT en
  purchase_items que este RPC nunca tuvo en prod.

  metodos-pago-operaciones: agrega p_payment_method_id opcional, validado
  contra el catálogo de la cuenta y persistido en todas las filas de la
  operación (mirror de p_cost_center_id).

  pagos-cableados-restantes (D7/OQ-E): el payload de PurchaseCreated ya no
  hardcodea 'payment_method':'credit' — deriva el kind real de
  p_payment_method_id (mismo SELECT que ya validaba la pertenencia, ahora
  captura también el kind) con COALESCE(..., 'credit') para preservar el
  comportamiento cuando no hay forma de pago imputada.

  pos-banco-movimientos (D5, task 5.2): agrega p_bank_account_id opcional —
  la compra por método bancario debita el ledger operativo (egreso,
  p_direction='out'), simétrico a la venta.

  compras-proveedor-cuenta-corriente (D4/D6/D8): agrega p_supplier_id opcional
  trailing — la compra pasa a saber a quién se le compró, persistido en LAS DOS
  ramas del INSERT a purchases (D4), y cuando la forma de pago imputada es de
  kind='credit' postea el cargo en la cuenta corriente del proveedor vía el
  helper compartido _pay_register_party_charge (D8).

  caja-compras-cobranzas (D2/D3): agrega p_cash_session_id opcional trailing —
  con las tres condiciones verificadas en servidor, descuenta de la caja por
  el total de la compra. Sin SQL nuevo para D3 (sucursal): p_branch_id ya se
  valida y persiste desde 20261009000001 — lo que arregla D3 vive en el
  frontend/backend Python (grupos 9/10), no acá.

  cobranzas-vencimientos (D3): agrega p_due_date opcional trailing — la
  compra a crédito transporta la fecha de negocio (p_date) y el override al
  helper compartido, que resuelve la cascada con el plazo del PROVEEDOR.
*/
DECLARE
    v_uid             uuid;
    v_account_id      uuid;
    v_flag_on         boolean := false;
    v_new_op_id       uuid;
    v_existing_op     uuid;
    v_item            RECORD;
    v_product         RECORD;
    v_new_purchase_id uuid;
    v_result_items    jsonb := '[]'::jsonb;
    v_qty_before      numeric;
    v_qty_after       numeric;
    v_unit_factor     numeric(20,10);
    v_qty_norm        numeric(15,4);
    v_stock_sum       numeric(15,4);   -- C-21: Σ branch_stock (reemplaza products.stock)
    v_inserted        integer;
    v_total_sum       numeric(15,2) := 0;
    v_kind            text;            -- pagos-cableados-restantes (D7)
    -- caja-compras-cobranzas (D2):
    v_cash_movement_id    uuid;
    v_cash_session_status text;
    v_cash_session_branch uuid;
BEGIN
    v_uid := (SELECT auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT cai INTO v_account_id
    FROM   current_account_ids() AS cai
    LIMIT  1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
            USING ERRCODE = 'P0403';
    END IF;

    -- deudas-menores-agosto (G1/D1): mismo flag_key y mismo patrón que
    -- rpc_create_sale_operation — ausencia de fila = v2 (escribe línea).
    SELECT enabled INTO v_flag_on
    FROM   public.account_feature_flags
    WHERE  account_id = v_account_id
      AND  flag_key   = 'sale_items_rpc_v2'
    LIMIT  1;
    v_flag_on := COALESCE(v_flag_on, true);

    IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
    END IF;

    IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
    END IF;

    -- Verify branch_id belongs to this account (if provided)
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.branches
            WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- cost-center-dimension: Verify cost_center_id belongs to this account (mirror of branch_id)
    IF p_cost_center_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.cost_centers
            WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'cost_center_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- metodos-pago-operaciones: Verify payment_method_id belongs to this account (mirror of cost_center_id).
    -- pagos-cableados-restantes (D7): el mismo SELECT que valida pertenencia
    -- ahora captura también el kind — un solo lookup, no dos.
    IF p_payment_method_id IS NOT NULL THEN
        SELECT kind INTO v_kind
        FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'payment_method_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- compras-proveedor-cuenta-corriente (D6): pertenencia del proveedor a la
    -- cuenta — mismo molde que branch_id/cost_center_id/payment_method_id.
    IF p_supplier_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.suppliers
            WHERE id = p_supplier_id AND account_id = v_account_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'supplier_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- compras-proveedor-cuenta-corriente (D6, OQ-1 opción A): no hay deuda sin
    -- acreedor. Espejo exacto de credit_requires_client del lado venta.
    IF v_kind = 'credit' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
            USING ERRCODE = 'P0400';
    END IF;

    v_new_op_id := gen_random_uuid();

    -- ON CONFLICT: el índice único es (user_id, operation_kind, idempotency_key).
    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
    ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'purchase'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                   jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                   '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

        -- Idempotency replay: NO emitir evento duplicado (DEC-20). caja-
        -- compras-cobranzas (D12): un replay tampoco vuelve a postear caja —
        -- el RETURN acá corta antes de llegar al bloque de caja de más abajo.
        RETURN jsonb_build_object(
            'operation_id', v_existing_op,
            'items',        v_result_items,
            'replayed',     true
        );
    END IF;

    FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                   AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
        ORDER BY product_id
    LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
            RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
            RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
        END IF;

        v_unit_factor := 1.0;
        IF v_item.unit_id IS NOT NULL THEN
            SELECT factor INTO v_unit_factor
            FROM   public.units_of_measure
            WHERE  id = v_item.unit_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P0404';
            END IF;
        END IF;
        v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

        -- journal-entry-outbox: acumular total para el payload del evento
        -- (y ahora también para el egreso de caja).
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
            SELECT id, user_id, is_variant, name, sku, cost INTO v_product
            FROM   public.products
            WHERE  id = v_item.product_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
            END IF;

            IF v_product.user_id <> v_uid THEN
                RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
            END IF;

            IF NOT v_product.is_variant THEN
                IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
                    RAISE EXCEPTION
                        'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                        USING ERRCODE = 'P0422';
                END IF;
            END IF;

            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id,
                 p_supplier_id,
                 v_product.name, v_product.sku, v_product.cost, NULL)
            RETURNING id INTO v_new_purchase_id;

            IF v_flag_on THEN
                INSERT INTO public.purchase_items (
                    purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
                    name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
                ) VALUES (
                    v_new_purchase_id, v_item.product_id, v_account_id, NULL,
                    v_item.quantity, v_item.unit_id,
                    v_item.amount, v_item.amount * v_item.quantity,
                    v_product.name, v_product.sku, v_product.cost, NULL
                );
            END IF;

            -- stock sobre branch_stock (C-21). before/after = Σ branch_stock.
            SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
            FROM   public.branch_stock
            WHERE  product_id = v_item.product_id;

            v_qty_before := v_stock_sum;
            v_qty_after  := v_stock_sum + v_qty_norm;

            PERFORM public.c21_apply_branch_stock_delta(
                v_account_id, v_item.product_id, p_branch_id, v_qty_norm);

            INSERT INTO public.stock_movements (
                user_id, account_id, product_id, product_name, type,
                quantity_delta, quantity_before, quantity_after,
                reference_id, reference_type, performed_by,
                operation_group_id, branch_id, unit_cost_snapshot
            ) VALUES (
                v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                v_qty_norm, v_qty_before, v_qty_after,
                v_new_purchase_id, 'purchase', v_uid,
                v_new_op_id, p_branch_id, v_product.cost
            );

        ELSE
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id,
                 p_supplier_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- ── caja-compras-cobranzas (D2) — OPT-IN DE CAJA, 3 condiciones ───────────
    -- Copiado LITERAL del molde de rpc_create_expense: mismos tres tokens de
    -- error, mismo orden, y p_date (`date`) comparado DIRECTO contra
    -- reporting_local_today() — PROHIBIDO castear a timestamptz (el ::date
    -- implícito usaría la timezone del servidor/UTC, y una compra cargada
    -- entre las 21:00 y las 23:59 de Mendoza se rechazaría con P0422 justo
    -- cuando el usuario sabe que es hoy).
    --
    -- "Sucursal efectiva de la compra" = p_branch_id tal cual (sin COALESCE a
    -- una default: a diferencia del gasto, la compra no resuelve una
    -- sucursal por defecto — D3 sólo exige que se PERSISTA la elegida). Una
    -- compra sin sucursal (p_branch_id NULL) no puede satisfacer esta
    -- condición para ninguna caja real: es el comportamiento correcto, no un
    -- caso sin cubrir.
    IF p_cash_session_id IS NOT NULL THEN
        IF v_kind IS DISTINCT FROM 'cash' THEN
            RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
                USING ERRCODE = 'P0422';
        END IF;

        SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
        FROM public.cash_sessions cs
        JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
        WHERE cs.id = p_cash_session_id;

        IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM p_branch_id THEN
            RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la compra'
                USING ERRCODE = 'P0422';
        END IF;

        IF p_date <> public.reporting_local_today() THEN
            RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una compra fechada hoy (%)', public.reporting_local_today()
                USING ERRCODE = 'P0422';
        END IF;

        v_cash_movement_id := public.c28_register_cash_movement(
            p_cash_session_id, -v_total_sum, 'purchase_payment', v_new_op_id, p_description
        );
    END IF;
    -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

    -- pos-banco-movimientos (D5, task 5.2): movimiento bancario operativo de
    -- EGRESO — v_kind CRUDO.
    PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'out', 'purchase', v_new_op_id,
        p_date, p_branch_id, NULL
    );

    -- compras-proveedor-cuenta-corriente (D8): cargo en la cuenta corriente
    -- del proveedor. cobranzas-vencimientos (D3): transporta la fecha de
    -- negocio y el override — la cascada (plazo del PROVEEDOR) vive en el helper.
    IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
            v_account_id, 'supplier', p_supplier_id, v_total_sum, v_new_op_id, v_new_op_id,
            p_date, p_due_date
        );
    END IF;

    -- ── journal-entry-outbox (Task 4.1): emitir PurchaseCreated en la misma tx ─
    INSERT INTO public.events
        (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
        v_account_id,
        'PurchaseCreated',
        'Purchase',
        v_new_op_id,
        jsonb_build_object(
            'account_id',     v_account_id,
            'operation_id',   v_new_op_id,
            'total',          v_total_sum,
            'cost_center_id', p_cost_center_id,
            'neto',           NULL,
            'iva_amount',     NULL,
            'payment_method', COALESCE(v_kind, 'credit'),
            'occurred_at',    now()
        ),
        now()
    );

    RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date) TO service_role;


-- =============================================================================
-- 4. READ-MODELS — rpc_receivables_report extendido (RETURNS cambia →
--    DROP+CREATE, 42P13) + rpc_payables_report (nuevo, espejo) +
--    rpc_set_default_payment_terms.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_receivables_report(uuid);

CREATE OR REPLACE FUNCTION public.rpc_receivables_report(p_account_id uuid)
RETURNS TABLE(
    client_id               uuid,
    client_name             text,
    client_phone            text,
    balance                 numeric,
    days_since_last_charge  integer,
    days_since_last_payment integer,
    last_payment_date       date,
    overdue_total           numeric,
    amount_current          numeric,
    amount_overdue_1_30     numeric,
    amount_overdue_31_60    numeric,
    amount_overdue_60_plus  numeric,
    amount_no_due_date      numeric,
    oldest_due_date         date,
    days_overdue_max        integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  cobranzas-panel (Etapa A) + cobranzas-vencimientos (Etapa B, D4/D5/D6):
  una fila por cliente deudor con el reparto de su saldo en cinco tramos,
  derivado FIFO por línea de flotación SIN materializar imputaciones:
    - cargos = movement_type 'sale' + 'adjustment' positivo, ordenados por
      (vencimiento o fecha local del posteo, created_at, id);
    - crédito disponible = suma NEGADA, con su propio signo, de todo lo demás
      (un cobro/nota suma crédito; una anulación de cobro lo RESTA — jamás es
      un cargo: rejuvenecería la mora);
    - abierto del cargo i = clamp(acumulado_i - crédito, 0, importe_i).
  Invariante de cierre: la suma de los 5 tramos = balance materializado.
  Clasificación (regla SEPARADA de la imputación, D5): sólo un cargo con
  vencimiento puede estar vencido; sin vencimiento = tramo propio, NUNCA se
  pliega a "al día". Día calendario argentino vía reporting_local_today().
*/
BEGIN
  -- Guard de membresía (D1 Etapa A): primera sentencia, antes de leer dato alguno.
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH today AS (
    SELECT public.reporting_local_today() AS d
  ),
  last_moves AS (
    -- D4 Etapa A: el cargo es EXCLUSIVAMENTE movement_type = 'sale' para las
    -- antigüedades; el cobro es EXCLUSIVAMENTE 'payment_received'.
    SELECT
      m.customer_account_id                                                 AS ca_id,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'sale')             AS last_charge_at,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'payment_received') AS last_payment_at
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
    GROUP BY m.customer_account_id
  ),
  pool AS (
    SELECT m.customer_account_id AS ca_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
      AND NOT (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.customer_account_id
  ),
  charges AS (
    SELECT m.customer_account_id AS ca_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.customer_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
      AND (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_items AS (
    SELECT ch.ca_id, ch.due_date,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.ca_id = ch.ca_id
  ),
  aging AS (
    SELECT oi.ca_id,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date <  t.d), 0) AS agg_overdue_total,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date >= t.d), 0) AS agg_current,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 1 AND 30), 0)  AS agg_1_30,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 31 AND 60), 0) AS agg_31_60,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) > 60), 0)              AS agg_60_plus,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NULL), 0)                                               AS agg_no_due,
      MIN(oi.due_date) FILTER (WHERE oi.open_amount > 0)                                    AS agg_oldest_due,
      MAX(t.d - oi.due_date) FILTER (WHERE oi.open_amount > 0 AND oi.due_date < t.d)        AS agg_days_max
    FROM open_items oi
    CROSS JOIN today t
    GROUP BY oi.ca_id
  )
  SELECT
    c.id       AS client_id,
    c.name     AS client_name,
    -- cobranzas-vencimientos (D12): el recordatorio de WhatsApp de /cobranzas
    -- necesita el telefono del deudor — mismo dato que ya expone /clientes.
    c.phone    AS client_phone,
    ca.balance AS balance,
    (t.d - (lm.last_charge_at  AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_charge,
    (t.d - (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_payment,
    (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date                  AS last_payment_date,
    COALESCE(ag.agg_overdue_total, 0) AS overdue_total,
    COALESCE(ag.agg_current, 0)       AS amount_current,
    COALESCE(ag.agg_1_30, 0)          AS amount_overdue_1_30,
    COALESCE(ag.agg_31_60, 0)         AS amount_overdue_31_60,
    COALESCE(ag.agg_60_plus, 0)       AS amount_overdue_60_plus,
    COALESCE(ag.agg_no_due, 0)        AS amount_no_due_date,
    ag.agg_oldest_due                 AS oldest_due_date,
    ag.agg_days_max::integer          AS days_overdue_max
  FROM public.customer_accounts ca
  JOIN public.clients c ON c.id = ca.client_id
  LEFT JOIN last_moves lm ON lm.ca_id = ca.id
  LEFT JOIN aging ag ON ag.ca_id = ca.id
  CROSS JOIN today t
  -- D5 Etapa A: sólo deuda viva y clientes vigentes (mismo criterio que /clientes).
  WHERE ca.account_id = p_account_id
    AND ca.balance > 0
    AND c.deleted_at IS NULL
  ORDER BY ca.balance DESC;
END;
$function$;

COMMENT ON FUNCTION public.rpc_receivables_report(uuid) IS
    'cobranzas-panel + cobranzas-vencimientos: read-model agregado de cuentas '
    'por cobrar con aging FIFO por línea de flotación (D4) — 5 tramos que '
    'suman el balance (invariante de cierre), sin materializar imputaciones. '
    'Sólo cargos con vencimiento pueden estar vencidos (D5); sin vencimiento '
    'es tramo propio. Día argentino via reporting_local_today(). Excluye '
    'balance = 0 y clientes con deleted_at. Guard P0401 primera sentencia.';

REVOKE ALL     ON FUNCTION public.rpc_receivables_report(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_receivables_report(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_receivables_report(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.rpc_payables_report(p_account_id uuid)
RETURNS TABLE(
    supplier_id             uuid,
    supplier_name           text,
    balance                 numeric,
    days_since_last_charge  integer,
    days_since_last_payment integer,
    last_payment_date       date,
    overdue_total           numeric,
    amount_current          numeric,
    amount_overdue_1_30     numeric,
    amount_overdue_31_60    numeric,
    amount_overdue_60_plus  numeric,
    amount_no_due_date      numeric,
    oldest_due_date         date,
    days_overdue_max        integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  cobranzas-vencimientos (D6): espejo TEXTUAL de rpc_receivables_report sobre
  supplier_accounts/suppliers — cargo = 'purchase' + 'adjustment' positivo;
  crédito = pagos/notas de débito/anulaciones con su signo. Mismas garantías:
  guard P0401 primera sentencia, invariante de cierre, día argentino,
  exclusión de balance = 0 y proveedores con deleted_at.
*/
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH today AS (
    SELECT public.reporting_local_today() AS d
  ),
  last_moves AS (
    SELECT
      m.supplier_account_id                                             AS sa_id,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'purchase')     AS last_charge_at,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'payment_made') AS last_payment_at
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
    GROUP BY m.supplier_account_id
  ),
  pool AS (
    SELECT m.supplier_account_id AS sa_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
      AND NOT (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.supplier_account_id
  ),
  charges AS (
    SELECT m.supplier_account_id AS sa_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.supplier_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
      AND (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_items AS (
    SELECT ch.sa_id, ch.due_date,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.sa_id = ch.sa_id
  ),
  aging AS (
    SELECT oi.sa_id,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date <  t.d), 0) AS agg_overdue_total,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date >= t.d), 0) AS agg_current,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 1 AND 30), 0)  AS agg_1_30,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 31 AND 60), 0) AS agg_31_60,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) > 60), 0)              AS agg_60_plus,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NULL), 0)                                               AS agg_no_due,
      MIN(oi.due_date) FILTER (WHERE oi.open_amount > 0)                                    AS agg_oldest_due,
      MAX(t.d - oi.due_date) FILTER (WHERE oi.open_amount > 0 AND oi.due_date < t.d)        AS agg_days_max
    FROM open_items oi
    CROSS JOIN today t
    GROUP BY oi.sa_id
  )
  SELECT
    s.id       AS supplier_id,
    s.name     AS supplier_name,
    sa.balance AS balance,
    (t.d - (lm.last_charge_at  AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_charge,
    (t.d - (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_payment,
    (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date                  AS last_payment_date,
    COALESCE(ag.agg_overdue_total, 0) AS overdue_total,
    COALESCE(ag.agg_current, 0)       AS amount_current,
    COALESCE(ag.agg_1_30, 0)          AS amount_overdue_1_30,
    COALESCE(ag.agg_31_60, 0)         AS amount_overdue_31_60,
    COALESCE(ag.agg_60_plus, 0)       AS amount_overdue_60_plus,
    COALESCE(ag.agg_no_due, 0)        AS amount_no_due_date,
    ag.agg_oldest_due                 AS oldest_due_date,
    ag.agg_days_max::integer          AS days_overdue_max
  FROM public.supplier_accounts sa
  JOIN public.suppliers s ON s.id = sa.supplier_id
  LEFT JOIN last_moves lm ON lm.sa_id = sa.id
  LEFT JOIN aging ag ON ag.sa_id = sa.id
  CROSS JOIN today t
  WHERE sa.account_id = p_account_id
    AND sa.balance > 0
    AND s.deleted_at IS NULL
  ORDER BY sa.balance DESC;
END;
$function$;

COMMENT ON FUNCTION public.rpc_payables_report(uuid) IS
    'cobranzas-vencimientos (D6): read-model de cuentas por pagar — espejo '
    'textual de rpc_receivables_report sobre supplier_accounts. Mismos '
    'tramos, mismo invariante de cierre, mismas garantías de tenencia.';

REVOKE ALL     ON FUNCTION public.rpc_payables_report(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_payables_report(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_payables_report(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.rpc_set_default_payment_terms(p_days smallint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
/*
  cobranzas-vencimientos (D10): plazo de pago por defecto de la cuenta —
  política comercial, sólo escribible por quien puede escribir en la cuenta
  (is_account_writer, P0401). NULL limpia el plazo (= "sin plazo definido").
*/
DECLARE
  v_account_id uuid;
BEGIN
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL OR NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  IF p_days IS NOT NULL AND p_days < 0 THEN
    RAISE EXCEPTION 'payment_terms_negative: el plazo de pago no puede ser negativo (%)', p_days
      USING ERRCODE = 'P0400';
  END IF;

  UPDATE public.accounts
  SET default_payment_terms_days = p_days
  WHERE id = v_account_id;
END;
$function$;

COMMENT ON FUNCTION public.rpc_set_default_payment_terms(smallint) IS
    'cobranzas-vencimientos (D10): fija (o limpia, con NULL) el plazo de pago '
    'por defecto de la cuenta del invocante. Guard is_account_writer (P0401); '
    'P0400 si negativo.';

REVOKE ALL     ON FUNCTION public.rpc_set_default_payment_terms(smallint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_set_default_payment_terms(smallint) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_set_default_payment_terms(smallint) TO authenticated;


-- =============================================================================
-- 5. CONSUMER 4 — _notification_from_event con los 2 tipos nuevos (9º y 10º).
--    MISMA firma (public.events) → CREATE OR REPLACE. Cuerpo VIVO + diff.
--    Los tipos NO entran al Consumer 3 (invariante D13 — 11 tipos canónicos).
-- =============================================================================
CREATE OR REPLACE FUNCTION public._notification_from_event(
    p_event public.events
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  v3-notifications-realtime (D2) + billing-pro-trial (D9) +
  mp-real-subscriptions (D11, PR2+PR4) + cobranzas-vencimientos (D8) —
  Consumer 4 (Notification) del relay del outbox.

  cobranzas-vencimientos agrega 'ReceivablesOverdueDigest' y
  'PayablesOverdueDigest' (9º y 10º tipos): resumen diario de deuda vencida
  por cobrar / por pagar, target ADMIN (owners), severidad warning, sin
  branch (la cuenta corriente no referencia sucursal).
*/
DECLARE
    v_payload    jsonb;
    v_event_type text;
    v_target     text;
    v_severity   text;
    v_branch_id  uuid;
    v_difference numeric;
    v_audience   uuid[];
    v_claimed    bool;
BEGIN
    v_payload    := p_event.payload;
    v_event_type := p_event.event_type;

    -- ── Filtro: los 10 tipos en-scope ─────────────────────────────────────────
    IF v_event_type NOT IN (
        'CashSessionClosed', 'StockBelowMinimum', 'FiscalDocumentRejected',
        'QuoteAccepted', 'TransferDispatched', 'PlanLimitExceeded',
        'SubscriptionPaymentFailed', 'SubscriptionExpiringSoon',
        'ReceivablesOverdueDigest', 'PayablesOverdueDigest'
    ) THEN
        RETURN;  -- no-op para eventos fuera de alcance
    END IF;

    -- ── CashSessionClosed: solo si difference <> 0 (D3/D4) ───────────────────
    IF v_event_type = 'CashSessionClosed' THEN
        v_difference := COALESCE((v_payload->>'difference')::numeric, 0);
        IF v_difference = 0 THEN
            RETURN;  -- sin diferencia de arqueo, no hace falta avisar
        END IF;
    END IF;

    -- ── Idempotencia: reclamar slot (event_id, 'Notification') ───────────────
    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
    VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        p_event.id::text || ':Notification',
        'event_consumer',
        p_event.id,
        'Notification'
    )
    ON CONFLICT (event_id, consumer_type)
    WHERE event_id IS NOT NULL
    DO NOTHING;

    GET DIAGNOSTICS v_claimed = ROW_COUNT;

    IF NOT v_claimed THEN
        RETURN;  -- slot ya existía → skip idempotente (ya se avisó)
    END IF;

    -- ── Dispatch por event_type → target + severity ──────────────────────────
    IF v_event_type = 'CashSessionClosed' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'FiscalDocumentRejected' THEN
        v_target    := 'URGENT_FISCAL';
        v_severity  := 'urgent';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'StockBelowMinimum' THEN
        v_target    := 'PURCHASES';
        v_severity  := 'warning';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'QuoteAccepted' THEN
        v_target    := 'SELLER';
        v_severity  := 'info';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'TransferDispatched' THEN
        v_target    := 'BRANCH_DEST';
        v_severity  := 'info';
        v_branch_id := (v_payload->>'destination_branch_id')::uuid;

    ELSIF v_event_type = 'PlanLimitExceeded' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;

    ELSIF v_event_type = 'SubscriptionPaymentFailed' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;

    ELSIF v_event_type = 'SubscriptionExpiringSoon' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;

    ELSIF v_event_type = 'ReceivablesOverdueDigest' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;

    ELSIF v_event_type = 'PayablesOverdueDigest' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;
    END IF;

    -- ── Resolver audiencia ────────────────────────────────────────────────────
    v_audience := public._notification_audience(p_event.account_id, v_target, v_branch_id);

    IF v_audience IS NULL OR array_length(v_audience, 1) IS NULL THEN
        RETURN;  -- audiencia vacía: nada dirigido a nadie (idempotencia ya reclamada)
    END IF;

    -- ── INSERT notifications ──────────────────────────────────────────────────
    INSERT INTO public.notifications
        (account_id, branch_id, type, severity, payload, audience)
    VALUES (
        p_event.account_id,
        v_branch_id,
        v_event_type,
        v_severity,
        v_payload,
        v_audience
    );
END;
$fn$;

REVOKE ALL     ON FUNCTION public._notification_from_event(public.events) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._notification_from_event(public.events) FROM anon;
REVOKE EXECUTE ON FUNCTION public._notification_from_event(public.events) FROM authenticated;

COMMENT ON FUNCTION public._notification_from_event IS
    'v3-notifications-realtime (D2) + billing-pro-trial (D9) + '
    'mp-real-subscriptions (D11) + cobranzas-vencimientos (D8): helper del '
    'Consumer 4 (Notification) del relay del outbox. 10 tipos en-scope. '
    'SECURITY DEFINER + SET search_path. Llamado solo desde '
    'rpc_process_outbox_dispatch (misma firma — NO se tocó ese dispatcher). '
    'REVOCADO de authenticated/anon/PUBLIC.';


-- =============================================================================
-- 6. BARRIDO DIARIO — _produce_receivables_overdue_digest(), molde textual de
--    _produce_plan_expiring_soon (20260830000002): UNA CTE por lado que
--    inserta email_logs y, SOLO para las filas realmente insertadas, events.
--    Dedup en dos capas (D8): ON CONFLICT (user_id, event_type, metadata) +
--    predicado explícito por día argentino (as_of) — los importes viajan en
--    metadata para la plantilla, así que la capa 1 sola no alcanza.
-- =============================================================================
CREATE OR REPLACE FUNCTION public._produce_receivables_overdue_digest()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  cobranzas-vencimientos (D8/D9): UN aviso resumido por cuenta, por lado y
  por día calendario argentino, SOLO sobre lo VENCIDO (overdue_total > 0).
  La derivación FIFO es la misma línea de flotación de los read-models (D4);
  OQ-2 firmada: clientes/proveedores dados de baja EXCLUIDOS (mismo D5 de la
  Etapa A — el aviso no nombra partes que la aplicación no lista).
  Destinatario: el propietario de la cuenta (precedente PlanLimitExceeded).
  Solo lectura sobre los libros: no toca saldos, movimientos ni asientos.
*/
DECLARE
  n_recv  integer := 0;
  n_pay   integer := 0;
  v_today date := public.reporting_local_today();
BEGIN
  -- ── Lado POR COBRAR ────────────────────────────────────────────────────────
  WITH pool AS (
    SELECT m.customer_account_id AS ca_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.customer_account_movements m
    WHERE NOT (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.customer_account_id
  ),
  charges AS (
    SELECT m.customer_account_id AS ca_id, m.account_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.customer_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.customer_account_movements m
    WHERE (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_overdue AS (
    SELECT ch.account_id, ch.ca_id,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.ca_id = ch.ca_id
    WHERE ch.due_date IS NOT NULL AND ch.due_date < v_today
  ),
  per_account AS (
    SELECT oo.account_id,
           COUNT(DISTINCT ca.client_id) FILTER (WHERE oo.open_amount > 0) AS party_count,
           SUM(oo.open_amount) AS overdue_total
    FROM open_overdue oo
    JOIN public.customer_accounts ca ON ca.id = oo.ca_id
    JOIN public.clients c ON c.id = ca.client_id
    WHERE ca.balance > 0 AND c.deleted_at IS NULL
    GROUP BY oo.account_id
    HAVING SUM(oo.open_amount) > 0
  ),
  candidates AS (
    SELECT pa.account_id, a.owner_user_id AS user_id, au.email AS recipient,
           pa.party_count, pa.overdue_total
    FROM per_account pa
    JOIN public.accounts a ON a.id = pa.account_id
    JOIN auth.users au ON au.id = a.owner_user_id
    WHERE NOT EXISTS (  -- D8 capa 2: dedup por día argentino, aunque cambien los importes
      SELECT 1 FROM public.email_logs el
      WHERE el.user_id = a.owner_user_id
        AND el.event_type = 'receivables_overdue_digest'
        AND el.metadata->>'as_of' = v_today::text
        AND (el.metadata->>'account_id')::uuid = pa.account_id
    )
  ),
  ins_email AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, 'receivables_overdue_digest', recipient,
           'Tenés deuda vencida por cobrar — ALIADATA',
           jsonb_build_object('account_id', account_id, 'as_of', v_today::text,
                              'party_count', party_count, 'overdue_total', overdue_total)
    FROM candidates
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING (metadata->>'account_id')::uuid AS account_id
  ),
  ins_event AS (
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    SELECT c.account_id, 'ReceivablesOverdueDigest', 'ReceivablesDigest', c.account_id,
           jsonb_build_object('account_id', c.account_id, 'as_of', v_today::text,
                              'party_count', c.party_count, 'overdue_total', c.overdue_total),
           now()
    FROM candidates c
    JOIN ins_email e ON e.account_id = c.account_id
    RETURNING 1
  )
  SELECT count(*) INTO n_recv FROM ins_email;

  -- ── Lado POR PAGAR (espejo) ────────────────────────────────────────────────
  WITH pool AS (
    SELECT m.supplier_account_id AS sa_id, COALESCE(SUM(-m.amount), 0) AS credit
    FROM public.supplier_account_movements m
    WHERE NOT (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
    GROUP BY m.supplier_account_id
  ),
  charges AS (
    SELECT m.supplier_account_id AS sa_id, m.account_id, m.id, m.amount, m.due_date,
           SUM(m.amount) OVER (
             PARTITION BY m.supplier_account_id
             ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      m.created_at, m.id
           ) AS cum_amount
    FROM public.supplier_account_movements m
    WHERE (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
  ),
  open_overdue AS (
    SELECT ch.account_id, ch.sa_id,
           LEAST(ch.amount, GREATEST(0::numeric, ch.cum_amount - COALESCE(po.credit, 0))) AS open_amount
    FROM charges ch
    LEFT JOIN pool po ON po.sa_id = ch.sa_id
    WHERE ch.due_date IS NOT NULL AND ch.due_date < v_today
  ),
  per_account AS (
    SELECT oo.account_id,
           COUNT(DISTINCT sa.supplier_id) FILTER (WHERE oo.open_amount > 0) AS party_count,
           SUM(oo.open_amount) AS overdue_total
    FROM open_overdue oo
    JOIN public.supplier_accounts sa ON sa.id = oo.sa_id
    JOIN public.suppliers s ON s.id = sa.supplier_id
    WHERE sa.balance > 0 AND s.deleted_at IS NULL
    GROUP BY oo.account_id
    HAVING SUM(oo.open_amount) > 0
  ),
  candidates AS (
    SELECT pa.account_id, a.owner_user_id AS user_id, au.email AS recipient,
           pa.party_count, pa.overdue_total
    FROM per_account pa
    JOIN public.accounts a ON a.id = pa.account_id
    JOIN auth.users au ON au.id = a.owner_user_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.email_logs el
      WHERE el.user_id = a.owner_user_id
        AND el.event_type = 'payables_overdue_digest'
        AND el.metadata->>'as_of' = v_today::text
        AND (el.metadata->>'account_id')::uuid = pa.account_id
    )
  ),
  ins_email AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, 'payables_overdue_digest', recipient,
           'Tenés deuda vencida con proveedores — ALIADATA',
           jsonb_build_object('account_id', account_id, 'as_of', v_today::text,
                              'party_count', party_count, 'overdue_total', overdue_total)
    FROM candidates
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING (metadata->>'account_id')::uuid AS account_id
  ),
  ins_event AS (
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    SELECT c.account_id, 'PayablesOverdueDigest', 'PayablesDigest', c.account_id,
           jsonb_build_object('account_id', c.account_id, 'as_of', v_today::text,
                              'party_count', c.party_count, 'overdue_total', c.overdue_total),
           now()
    FROM candidates c
    JOIN ins_email e ON e.account_id = c.account_id
    RETURNING 1
  )
  SELECT count(*) INTO n_pay FROM ins_email;

  RETURN n_recv + n_pay;
END;
$fn$;

REVOKE ALL ON FUNCTION public._produce_receivables_overdue_digest() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._produce_receivables_overdue_digest() IS
  'cobranzas-vencimientos (D8/D9): barrido diario — UN resumen de deuda '
  'vencida por cuenta, por lado (cobrar/pagar) y por día argentino, por los '
  'dos canales (email_logs + evento al outbox para la campana) con UN solo '
  'dedup: el evento se crea SOLO para las filas que el INSERT de email '
  'realmente insertó. Capa 2 de dedup por metadata->as_of (los importes '
  'viajan en metadata y cambiarían el conflicto de la capa 1). Excluye '
  'partes dadas de baja (OQ-2) y solo cuenta lo vencido (D9).';


-- =============================================================================
-- 7. SCHEDULING — patrón v3-notifications-realtime §4.2.
-- =============================================================================
SELECT cron.unschedule('cobranzas-overdue-digest-sweep')
FROM cron.job WHERE jobname = 'cobranzas-overdue-digest-sweep';

SELECT cron.schedule(
    'cobranzas-overdue-digest-sweep',
    '0 12 * * *',  -- diario a las 12:00 UTC (~09:00 Mendoza, franja user-facing)
    $$ SELECT public._produce_receivables_overdue_digest(); $$
);


-- =============================================================================
-- 8. GATE DE INTROSPECCIÓN (corre SIEMPRE, también en prod).
-- =============================================================================
DO $$
DECLARE
  v_def text;
  v_cnt int;
  v_fn  text;
BEGIN
  -- una sola definición de cada función tocada (42725)
  FOR v_fn IN
    SELECT unnest(ARRAY[
      '_pay_register_party_charge', 'c30_register_customer_account_movement',
      'c30_register_supplier_account_movement', 'rpc_create_sale_operation',
      'rpc_create_sale_operation_v2', 'rpc_create_purchase_operation',
      'rpc_receivables_report', 'rpc_payables_report',
      'rpc_set_default_payment_terms', '_produce_receivables_overdue_digest',
      '_notification_from_event'])
  LOOP
    SELECT COUNT(*) INTO v_cnt FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % tiene % definiciones (esperaba 1).', v_fn, v_cnt;
    END IF;
  END LOOP;

  -- el helper de cargo resuelve la cascada y guarda el P0400
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_pay_register_party_charge';
  IF position('due_date_before_charge' in v_def) = 0
     OR position('default_payment_terms_days' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: _pay_register_party_charge debe resolver la cascada (D3) y guardar due_date_before_charge (P0400).';
  END IF;

  -- el helper de cargo quedó SIN authenticated (hotfix #454 preservado)
  IF has_function_privilege('authenticated',
       'public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid, date, date)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: _pay_register_party_charge quedó ejecutable por authenticated — el hotfix 20261010000001 fue pisado.';
  END IF;

  -- los read-models anclan al día argentino
  FOR v_fn IN SELECT unnest(ARRAY['rpc_receivables_report', 'rpc_payables_report']) LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF position('reporting_local_today' in v_def) = 0 THEN
      RAISE EXCEPTION 'GATE INTROSPECCION FAILED: % no ancla el día a reporting_local_today().', v_fn;
    END IF;
  END LOOP;

  -- el cron quedó programado
  SELECT COUNT(*) INTO v_cnt FROM cron.job WHERE jobname = 'cobranzas-overdue-digest-sweep';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: el job cobranzas-overdue-digest-sweep no quedó programado.';
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: cobranzas-vencimientos instalado (11 funciones, cascada en el helper, ACLs, cron).';
END $$;
