-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-anon-analyze-bucket — lote 5a advisors 0028/0029 (paso 5, parte anon)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Cierra los 9 lints 0028 restantes del bucket "analizar" del inventario
-- (openspec/explore/2026-07-31-advisor-0028-0029-inventory.md §"Sin caller
-- REST identificado"). Mapeo de callers completado 2026-08-01:
--
--   · rpc_atomic_update_sale/purchase_operation, rpc_open/close_cash_session,
--     rpc_register_cash_movement → los llama SOLO el backend Python vía
--     asyncpg como `postgres` (repositories de sales/purchases/cash_session);
--     cero callers `.rpc()` en frontend/ y supabase/functions/.
--   · rpc_accept_invitation → SIN flujo de aceptación implementado en ningún
--     lado (solo el type generado y un comentario en TeamSection.tsx); un
--     futuro flujo de aceptación sería post-login (authenticated).
--   · rpc_safe_delete_product ×2 → legacy sin callers (el borrado de productos
--     va por el backend desde C-16/PR #201).
--   · rls_auto_enable → RETURNS event_trigger, cableada como event trigger
--     (verificado en prod): PostgREST no puede invocarla; revoke TOTAL.
--
-- Política: revocar `anon` (+PUBLIC) conservando `authenticated` en las 8
-- primeras — aunque hoy solo el backend las llama como postgres, conservar
-- authenticated es robusto ante el cambio de rol del pool que propone
-- v31-tenancy-pool-rls y ante futuros callers REST legítimos. `rls_auto_enable`
-- pierde también authenticated (nunca invocable con éxito vía REST).
--
-- Tras esta migración, 0028 esperado: 14 → 5 (solo los 4 helpers de RLS, 5
-- firmas, aceptados por diseño). Recordar QUITAR estas 9 firmas de la
-- allowlist de supabase/tests/test_function_acl_gate.sql (mismo PR).

DO $$
DECLARE
  v_sig text;
  -- Revoke de anon conservando authenticated
  v_keep_auth CONSTANT text[] := ARRAY[
    'public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb)',
    'public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb)',
    'public.rpc_open_cash_session(uuid, numeric)',
    'public.rpc_close_cash_session(uuid, numeric, text)',
    'public.rpc_register_cash_movement(uuid, numeric, text, uuid)',
    'public.rpc_accept_invitation(text)',
    'public.rpc_safe_delete_product(uuid)',
    'public.rpc_safe_delete_product(uuid, uuid)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_keep_auth LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;  -- drift-tolerante
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon',
                   to_regprocedure(v_sig)::text);
  END LOOP;

  -- Event trigger: revoke total (anon + authenticated + PUBLIC)
  IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated';
  END IF;

  -- ── GATE negativo: anon sin EXECUTE en las 9 ──────────────────────────────
  FOREACH v_sig IN ARRAY (v_keep_auth || ARRAY['public.rls_auto_enable()']) LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE NEG FAILED: % sigue con EXECUTE para anon', v_sig;
    END IF;
  END LOOP;

  -- ── GATE positivo: authenticated conserva EXECUTE en las 8 ────────────────
  FOREACH v_sig IN ARRAY v_keep_auth LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE POS FAILED: % quedó SIN EXECUTE para authenticated', v_sig;
    END IF;
  END LOOP;

  -- ── GATE event trigger: rls_auto_enable sin exposición REST ───────────────
  -- to_regprocedure (no el cast ::regprocedure): el cast de un literal se
  -- resuelve al PARSEAR la sentencia y lanza 42883 si la función no existe
  -- (en CI no existe) — to_regprocedure devuelve NULL y has_function_privilege
  -- con NULL es NULL → el IF queda falso sin error.
  IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL AND (
       has_function_privilege('anon', to_regprocedure('public.rls_auto_enable()'), 'EXECUTE')
    OR has_function_privilege('authenticated', to_regprocedure('public.rls_auto_enable()'), 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE FAILED: rls_auto_enable sigue expuesta vía REST';
  END IF;
END $$;
