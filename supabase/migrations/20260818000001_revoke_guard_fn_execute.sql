-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-guard-fn-execute — cierra advisor 0028 para dos guards trigger-only
-- ═══════════════════════════════════════════════════════════════════════════
--
-- El advisor de seguridad de Supabase (0028_anon_security_definer_function_
-- executable) marca WARN dos funciones SECURITY DEFINER trigger-only que
-- quedaron ejecutables vía PostgREST (/rest/v1/rpc/<fn>) por el GRANT EXECUTE
-- implícito a PUBLIC:
--
--   · fn_guard_product_soft_delete()   (20260811000001 / 20260811000004)
--   · fn_guard_supplier_plan_limit()   (20260817000001)
--
-- Ambas son BEFORE INSERT/UPDATE trigger-only: no existe caller legítimo vía
-- API. Revocar EXECUTE NO afecta el disparo de los triggers — Postgres no
-- chequea EXECUTE del usuario DML al disparar un trigger. Mismo patrón ya
-- aplicado en este repo a check_low_margin(), handle_new_user(), etc.
-- (20260517000002) y a _notification_from_event() /
-- _sweep_plan_limit_exceeded() (20260817000001).
--
-- Idempotente: REVOKE repetido es no-op; el guard to_regprocedure la hace
-- drift-tolerante (no-op si la función no existe en el entorno).
--
-- Rollback (no recomendado — reabre el WARN sin ganar nada):
--   GRANT EXECUTE ON FUNCTION public.fn_guard_product_soft_delete()  TO anon, authenticated;
--   GRANT EXECUTE ON FUNCTION public.fn_guard_supplier_plan_limit() TO anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.fn_guard_product_soft_delete()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.fn_guard_product_soft_delete() FROM PUBLIC, anon, authenticated;
  END IF;

  IF to_regprocedure('public.fn_guard_supplier_plan_limit()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.fn_guard_supplier_plan_limit() FROM PUBLIC, anon, authenticated;
  END IF;
END $$;

-- ── GATE: ninguna de las dos queda ejecutable por anon/authenticated ────────
-- (anon/authenticated heredan de PUBLIC, así que chequearlas cubre también
-- el caso de un EXECUTE residual vía PUBLIC)
DO $$
DECLARE
  v_fn   text;
  v_role text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['public.fn_guard_product_soft_delete()',
                              'public.fn_guard_supplier_plan_limit()']
  LOOP
    CONTINUE WHEN to_regprocedure(v_fn) IS NULL;  -- drift-tolerante
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF has_function_privilege(v_role, to_regprocedure(v_fn), 'EXECUTE') THEN
        RAISE EXCEPTION 'GATE FAILED: % sigue con EXECUTE para %', v_fn, v_role;
      END IF;
    END LOOP;
  END LOOP;
END $$;
