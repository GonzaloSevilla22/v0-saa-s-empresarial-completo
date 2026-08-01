-- ═══════════════════════════════════════════════════════════════════════════
-- Gate anti-regresión de ACLs — advisors 0028/0029
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Contexto: DROP FUNCTION + CREATE resetea el ACL al default (EXECUTE a
-- PUBLIC → anon/authenticated la heredan), mientras que CREATE OR REPLACE
-- conserva ACLs. Así regresaron check_low_margin() y handle_new_user() pese
-- al revoke de 20260517000002 (ver openspec/explore/2026-07-31-advisor-0028-
-- 0029-inventory.md §"Hallazgo sistémico").
--
-- Este gate corre en CI contra la DB resultante de TODAS las migraciones y
-- falla el PR si:
--   (1) una función trigger SECURITY DEFINER queda ejecutable por
--       anon/authenticated (invariante sin allowlist: las funciones trigger
--       nunca necesitan grants REST — Postgres no chequea EXECUTE al disparar
--       triggers), o
--   (2) una función SECURITY DEFINER queda ejecutable por `anon` fuera de la
--       allowlist explícita de abajo.
--
-- Mantenimiento de la allowlist: ACHICARLA (por revokes de lotes futuros) es
-- siempre válido — la entrada sobrante no falla. AGREGAR una entrada requiere
-- justificar en el PR por qué esa función necesita EXECUTE para anon
-- (caso de uso pre-login real). Espejo del inventario clasificado:
--   · 5 firmas = helpers de RLS — NUNCA revocar (las policies los ejecutan
--     como el rol consultante; revocarlos rompe todas las queries).
--   · 9 firmas = bucket "analizar" del inventario (paso 5, pendiente).

DO $$
DECLARE
  v_offenders text;
  v_allowlist CONSTANT text[] := ARRAY[
    -- Helpers de RLS — NUNCA revocar
    'public.current_account_ids()',
    'public.get_account_ids_for_user(p_user_id uuid)',
    'public.is_account_writer(p_account_id uuid)',
    'public.is_admin()',
    'public.is_admin(uid uuid)',
    -- Bucket "analizar" (inventario 2026-07-31, paso 5 pendiente)
    'public.rls_auto_enable()',
    'public.rpc_accept_invitation(p_token text)',
    'public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb)',
    'public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb)',
    'public.rpc_close_cash_session(p_session_id uuid, p_counted_balance numeric, p_idempotency_key text)',
    'public.rpc_open_cash_session(p_cashbox_id uuid, p_opening_balance numeric)',
    'public.rpc_register_cash_movement(p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid)',
    'public.rpc_safe_delete_product(p_product_id uuid)',
    'public.rpc_safe_delete_product(p_product_id uuid, p_user_id uuid)'
  ];
BEGIN
  -- Entorno sin roles de Supabase (p.ej. postgres pelado): no hay nada que gatear
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    RAISE NOTICE 'ACL GATE: rol anon no existe en este entorno — gate omitido';
    RETURN;
  END IF;

  -- ── (1) Funciones trigger SECURITY DEFINER expuestas — sin allowlist ──────
  SELECT string_agg(format('public.%s(%s)', p.proname,
                           pg_get_function_identity_arguments(p.oid)), E'\n  ')
  INTO v_offenders
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prosecdef
    AND p.prorettype = 'pg_catalog.trigger'::regtype
    AND (   has_function_privilege('anon',          p.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (1) FAILED: funciones trigger SECURITY DEFINER ejecutables por anon/authenticated (¿DROP+CREATE sin re-aplicar REVOKE?):\n  %', v_offenders;
  END IF;

  -- ── (2) SECURITY DEFINER ejecutables por anon fuera de la allowlist ───────
  SELECT string_agg(sig, E'\n  ')
  INTO v_offenders
  FROM (
    SELECT format('public.%s(%s)', p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  ) s
  WHERE s.sig <> ALL (v_allowlist);

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'ACL GATE (2) FAILED: funciones SECURITY DEFINER ejecutables por anon fuera de la allowlist (si es intencional, justificar y agregar a supabase/tests/test_function_acl_gate.sql; si no, REVOKE EXECUTE ... FROM PUBLIC, anon en la migración que la recrea):\n  %', v_offenders;
  END IF;

  RAISE NOTICE 'ACL GATE OK: sin triggers SECURITY DEFINER expuestos; anon-executable dentro de la allowlist (% firmas permitidas)', array_length(v_allowlist, 1);
END $$;
