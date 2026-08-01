-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-auth-internal-only — lote 5b advisors 0029 (paso 5, parte authenticated)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Cierre de la parte `authenticated` del bucket "analizar" del inventario
-- (openspec/explore/2026-07-31-advisor-0028-0029-inventory.md). Mapeo completo
-- de callers 2026-08-01 sobre las 39 candidatas 0029-only:
--
--   · 7 con caller REST directo (frontend/Edge) → conservan authenticated.
--   · 27 llamadas por el backend (repositories/services vía asyncpg) →
--     conservan authenticated ADREDE: el Paso 2 de v31-tenancy-pool-rls
--     (sign-off PO) adopta SET LOCAL ROLE authenticated por transacción en el
--     pool — revocarlas hoy plantaría una rotura diferida al encender el corte.
--   · rpc_issue_credit_note → SIN caller hoy, pero su futuro caller natural es
--     el backend post-Paso-2: se CONSERVA como reserva documentada (revocarla
--     sería un landmine solo-prod que ni CI ni dev local detectarían).
--   · Estas 4 → REVOKE total (esta migración); ninguna tiene caller REST ni lo
--     va a tener por diseño:
--
--       1. rpc_process_outbox_dispatch(integer) — cron-only: la llama SOLO el
--          job pg_cron `relay-process-outbox` como postgres (verificado en
--          cron.job de prod). El endpoint manual del backend usa
--          rpc_process_outbox_batch, no esta.
--       2. rpc_create_sale_operation_v2(...) — NUNCA se llama directo: la v1
--          (rpc_create_sale_operation) delega internamente cuando el flag
--          sale_items_rpc_v2 está activo, y esa llamada corre como el DEFINER
--          (postgres), no como el usuario final (20260616000003 L296).
--       3. rpc_create_purchase_operation_v2(...) — simétrico (mismo flag).
--       4. get_dashboard_critical_stock() — sin caller vivo (el dashboard usa
--          rpc_dashboard_kpi_summary desde C-24); los tests de KPI del CI la
--          ejecutan como postgres. Si el frontend re-agrega una llamada
--          directa, falla rápido en dev con 42501 → GRANT consciente en esa
--          feature (no es rotura diferida).
--
-- REVOKE explícito de PUBLIC + anon + authenticated (regla refinada: Supabase
-- otorga EXECUTE directo a anon/authenticated en toda función nueva del schema
-- public — REVOKE FROM PUBLIC solo no alcanza). postgres/service_role quedan
-- intactos (cron y llamadas internas del definer no se ven afectados).
-- Idempotente y drift-tolerante (to_regprocedure). 0029 esperado: 78 → 74;
-- el resto es LÍNEA BASE ACEPTADA (REST-legítimas + backend Paso 2 + reserva).

DO $$
DECLARE
  v_sig text;
  v_fns CONSTANT text[] := ARRAY[
    'public.rpc_process_outbox_dispatch(integer)',
    'public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text)',
    'public.rpc_create_purchase_operation_v2(text, date, text, jsonb)',
    'public.get_dashboard_critical_stock()'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;  -- drift-tolerante
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated',
                   to_regprocedure(v_sig)::text);
  END LOOP;

  -- ── GATE negativo: sin EXECUTE para anon ni authenticated en las 4 ────────
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE NEG FAILED: % sigue expuesta vía REST', v_sig;
    END IF;
  END LOOP;

  -- ── GATE positivo: postgres conserva EXECUTE (cron + delegación interna) ──
  FOREACH v_sig IN ARRAY v_fns LOOP
    CONTINUE WHEN to_regprocedure(v_sig) IS NULL;
    IF NOT has_function_privilege('postgres', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE POS FAILED: postgres quedó sin EXECUTE en %', v_sig;
    END IF;
  END LOOP;
END $$;
