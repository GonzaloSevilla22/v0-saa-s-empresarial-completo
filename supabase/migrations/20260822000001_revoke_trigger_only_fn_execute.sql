-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-trigger-only-fn-execute — cierra advisors 0028/0029 para el lote de
-- 10 funciones trigger-only aún expuestas vía PostgREST
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ⚠ GOVERNANCE: el lote incluye funciones de dominios auth (handle_new_user,
--   prevent_profile_privilege_escalation) y billing (assign_billing_receipt_
--   number) = CRÍTICO. Este archivo se PROPONE gateado por sign-off explícito
--   del PO — NO mergear sin esa aprobación (mergear aplica a prod).
--
-- Paso 2 del plan de openspec/explore/2026-07-31-advisor-0028-0029-
-- inventory.md. Las 10 son SECURITY DEFINER RETURNS trigger: PostgREST no
-- puede invocarlas con éxito (un RPC sobre una función trigger falla), pero
-- el EXECUTE concedido dispara igual los WARN 0028/0029 y amplía superficie
-- sin razón. Postgres NO chequea EXECUTE del usuario DML al disparar
-- triggers → revocar NO afecta ninguna operación (mismo argumento que
-- 20260517000002, 20260808000003, 20260818000001 y 20260820000001, en prod).
--
-- Trigger wiring verificado en prod (2026-08-01, read-only, MCP) — las 10
-- tienen su trigger existente y habilitado ('O'):
--
--   · assign_billing_receipt_number  trg_assign_billing_receipt_number  billing_events
--   · check_low_margin               on_sale_insert_margin_check        sales          ← REGRESIÓN de 20260517000002
--   · handle_new_user                on_auth_user_created               auth.users     ← REGRESIÓN de 20260517000002
--   · notify_meeting_created         on_meeting_created                 community.meetings
--   · notify_pool_created            on_pool_created                    community.purchase_pools
--   · prevent_profile_privilege_escalation  trg_prevent_profile_escalation  profiles
--   · send_email_log_webhook         on_email_log_insert                email_logs
--   · set_insight_account_id         trg_set_insight_account_id         insights
--   · update_post_likes_count        on_post_like_change                community.post_likes
--   · update_post_replies_count      on_post_reply_change               community.replies
--
-- Las 2 REGRESIONES prueban el hallazgo sistémico del inventario: un
-- DROP FUNCTION + CREATE posterior resetea el ACL al default (EXECUTE a
-- PUBLIC) y deshace revokes previos en silencio. REGLA para migraciones
-- futuras: al recrear una función SECURITY DEFINER, re-aplicar su REVOKE en
-- el mismo archivo.
--
-- 0 callers vía REST en el código (grep frontend/, backend/,
-- supabase/functions/): solo comentarios y tipos generados.
-- service_role conserva EXECUTE donde ya lo tenía.
--
-- Idempotente: REVOKE repetido es no-op; guard to_regprocedure =
-- drift-tolerante (no-op donde la función no exista).
--
-- Rollback (no recomendado — reabre los WARN sin ganar nada):
--   GRANT EXECUTE ON FUNCTION public.<fn>() TO anon, authenticated;  -- por función

DO $$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.assign_billing_receipt_number()',
    'public.check_low_margin()',
    'public.handle_new_user()',
    'public.notify_meeting_created()',
    'public.notify_pool_created()',
    'public.prevent_profile_privilege_escalation()',
    'public.send_email_log_webhook()',
    'public.set_insight_account_id()',
    'public.update_post_likes_count()',
    'public.update_post_replies_count()'
  ]
  LOOP
    CONTINUE WHEN to_regprocedure(v_fn) IS NULL;  -- drift-tolerante
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_fn);
  END LOOP;
END $$;

-- ── GATE 1: ninguna de las 10 queda ejecutable por anon/authenticated ───────
DO $$
DECLARE
  v_fn   text;
  v_role text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.assign_billing_receipt_number()',
    'public.check_low_margin()',
    'public.handle_new_user()',
    'public.notify_meeting_created()',
    'public.notify_pool_created()',
    'public.prevent_profile_privilege_escalation()',
    'public.send_email_log_webhook()',
    'public.set_insight_account_id()',
    'public.update_post_likes_count()',
    'public.update_post_replies_count()'
  ]
  LOOP
    CONTINUE WHEN to_regprocedure(v_fn) IS NULL;
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF has_function_privilege(v_role, to_regprocedure(v_fn), 'EXECUTE') THEN
        RAISE EXCEPTION 'GATE FAILED: % sigue con EXECUTE para %', v_fn, v_role;
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- ── GATE 2 (positivo): cada función existente sigue con al menos un trigger ─
-- no-interno habilitado colgado de ella (el REVOKE no puede desconectar
-- triggers; este gate ata la migración a la realidad operativa y detecta
-- drift inesperado del entorno donde corre).
DO $$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.assign_billing_receipt_number()',
    'public.check_low_margin()',
    'public.handle_new_user()',
    'public.notify_meeting_created()',
    'public.notify_pool_created()',
    'public.prevent_profile_privilege_escalation()',
    'public.send_email_log_webhook()',
    'public.set_insight_account_id()',
    'public.update_post_likes_count()',
    'public.update_post_replies_count()'
  ]
  LOOP
    CONTINUE WHEN to_regprocedure(v_fn) IS NULL;
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger t
      WHERE t.tgfoid = to_regprocedure(v_fn)
        AND NOT t.tgisinternal
        AND t.tgenabled <> 'D'
    ) THEN
      RAISE EXCEPTION 'GATE FAILED: % existe pero no tiene ningún trigger habilitado — revisar wiring antes de continuar', v_fn;
    END IF;
  END LOOP;
END $$;
