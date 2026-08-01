-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-anon-rest-legit — lote 4 advisors 0028/0029 (paso 3 del inventario)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Revoca EXECUTE de `anon` (y del fallback PUBLIC) en las 26 firmas REST-
-- legítimas clasificadas en openspec/explore/2026-07-31-advisor-0028-0029-
-- inventory.md §"Llamadas vía REST desde el código": funciones que el frontend
-- y las Edge Functions SÍ llaman vía PostgREST, pero siempre con sesión
-- (`authenticated`). Ninguna tiene caso de uso pre-login:
--
--   · Callers del frontend: todos en rutas `(dashboard)` detrás del middleware
--     de auth; `useOrgRole` (rpc_my_account_role) gated por `enabled: !!accountId`.
--   · Edge Functions (ai-*, generate-export, _shared/ai-quota): cliente con
--     ANON_KEY + header Authorization del usuario (JWT passthrough →
--     `authenticated`) y verifican `auth.getUser()` antes del RPC.
--   · Backend Python: llama RPCs vía asyncpg como `postgres` — no usa estos grants.
--
-- CONSERVA el EXECUTE de `authenticated` y `service_role`: en prod los grants
-- son explícitos por rol (default privileges de Supabase), no heredados de
-- PUBLIC, así que revocar PUBLIC+anon no los toca — y el gate positivo de
-- abajo lo verifica igual (aborta si `authenticated` quedara sin EXECUTE).
--
-- Idempotente (REVOKE repetido = no-op) y drift-tolerante (to_regprocedure).
-- NO toca: los 4 helpers de RLS (is_admin ×2, current_account_ids,
-- get_account_ids_for_user, is_account_writer — las policies los ejecutan como
-- el rol consultante) ni el bucket "analizar" del inventario.
--
-- Rollback puntual:
--   GRANT EXECUTE ON FUNCTION public.<fn>(<args>) TO anon;

DO $$
DECLARE
  v_sig text;
  v_fns CONSTANT text[] := ARRAY[
    -- Admin KPIs (validan is_admin() internamente)
    'public.get_admin_activation_rate(timestamptz, timestamptz)',
    'public.get_admin_community_interactions(timestamptz, timestamptz)',
    'public.get_admin_insights_breakdown(timestamptz, timestamptz)',
    'public.get_admin_paid_conversion_rate()',
    'public.get_admin_umv_rate(timestamptz, timestamptz)',
    'public.rpc_admin_business_kpis(timestamptz, timestamptz)',
    'public.rpc_admin_kpi_overview(timestamptz, timestamptz, text)',
    'public.rpc_admin_module_stats(text, timestamptz, timestamptz)',
    'public.rpc_admin_retention_30d(text, timestamptz, timestamptz)',
    'public.rpc_admin_weekly_usage_distribution(timestamptz, timestamptz)',
    -- Dashboard / reportes
    'public.get_dashboard_financials(timestamptz, timestamptz, uuid)',
    'public.rpc_branch_report(uuid, date, date)',
    'public.rpc_period_comparison(date, date, date, date)',
    'public.rpc_product_profitability(integer)',
    -- IA / exportaciones (Edge Functions con JWT passthrough)
    'public.rpc_atomic_log_ai_insight(text, text, text)',
    'public.rpc_increment_ai_usage(uuid, text)',
    'public.rpc_increment_export_usage(uuid)',
    -- Miembros / organización
    'public.rpc_change_member_role(uuid, uuid, text)',
    'public.rpc_invite_member(text, uuid)',
    'public.rpc_invite_member(text, uuid, text)',
    'public.rpc_my_account_role(uuid)',
    'public.rpc_remove_member(uuid, uuid)',
    -- Sucursales / stock / catálogo
    'public.rpc_create_branch(uuid, text, text)',
    'public.rpc_deactivate_branch(uuid)',
    'public.rpc_bulk_upsert_products(jsonb, uuid)',
    'public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;  -- drift-tolerante
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon',
                   to_regprocedure(v_sig)::text);
  END LOOP;

  -- ── GATE negativo: anon sin EXECUTE en las 26 ─────────────────────────────
  -- (anon hereda de PUBLIC, así que esto también cubre un residual vía PUBLIC)
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE NEG FAILED: % sigue con EXECUTE para anon', v_sig;
    END IF;
  END LOOP;

  -- ── GATE positivo: authenticated CONSERVA EXECUTE en las 26 ───────────────
  -- Protege contra el error de herencia: si alguna función dependiera del
  -- grant a PUBLIC (sin grant explícito a authenticated), revocar PUBLIC la
  -- rompería para usuarios logueados — este gate lo detecta antes de commitear.
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE POS FAILED: % quedó SIN EXECUTE para authenticated', v_sig;
    END IF;
  END LOOP;
END $$;
