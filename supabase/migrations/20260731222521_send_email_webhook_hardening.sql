-- =============================================================================
-- MIGRATION: 20260731222521_send_email_webhook_hardening.sql
-- CHANGE:    send-email-webhook-hardening (sign-off PO 2026-07-31)
-- Design ref: openspec/changes/send-email-webhook-hardening/design.md
--
-- GOVERNANCE: CRÍTICO — seguridad del webhook de correo transaccional +
--   envío real de correo desde el dominio de la marca. Sign-off explícito
--   del PO 2026-07-31 (tasks.md §0.1-0.4): OQ1 = SÍ hubo entrega real de
--   mails espurios (severidad escalada, revisión de reputación de dominio
--   en Resend queda pendiente del PO, NO bloqueante); OQ2 = rotación solo
--   ante sospecha; OQ3 = SÍ allowlist para el fan-out `all_users` (grupo 6,
--   implementado en supabase/functions/send-email/index.ts, no en esta
--   migración); OQ4 = NO se mueve el destinatario admin a configuración.
--
-- Contexto (design.md §Context): `send-email` es hoy un relay de correo
-- abierto — no valida el origen de la request — y el trigger que la invoca
-- tiene la URL de producción hardcodeada, así que TODA base que aplica esta
-- migración (CI, previews, local) se convierte en cliente de la función de
-- PROD. Los gates de comportamiento de otras migraciones, que corren
-- exactamente cuando `accounts` está vacía, siembran usuarios sintéticos que
-- disparan `handle_new_user` → INSERT en `email_logs` → POST real contra
-- prod. De ahí las ráfagas de ~40-45 POST/evento de CI observadas el
-- 2026-07-31 (confirmadas en vivo en tasks.md §1.2 al momento del apply).
--
-- Implementa (design.md):
--   D1  Secreto y URL de destino se leen de Supabase Vault
--       (`vault.decrypted_secrets`), reusando literalmente el patrón de
--       `rpc_trigger_cae_relay()` (20260719000001_c27_cae_relay_trigger.sql).
--       Nombres: `send_email_webhook_secret` y `edge_functions_base_url`.
--       Esta migración NUNCA contiene esos valores.
--   D2  El guard de entorno ES el guard de seguridad: si cualquiera de los
--       dos valores de Vault es NULL, el trigger emite RAISE NOTICE y
--       retorna sin llamar a `net.http_post`. La posesión del secreto es la
--       ÚNICA definición de "producción" — no se infiere entorno por
--       ningún otro medio (nombre de base, flags, env vars).
--   D4  Header propio `x-webhook-secret` (no `Authorization` — el gateway de
--       Supabase lo interpreta como token de proyecto propio).
--   D6  Corte temprano por `status`: si la fila insertada no tiene
--       `status = 'pending'`, no se emite HTTP (se chequea ANTES de leer
--       Vault, más barato).
--
-- OQ4 (D7): el destinatario admin hardcodeado en `handle_new_user`
--   (`danielsevilla@alia-data.com`) NO se toca en este change — el riesgo
--   real ya lo cierra este guard de entorno (D2): una base sin los secretos
--   de Vault no puede emitir tráfico hacia prod aunque el destinatario siga
--   literal en su código.
--
-- IDEMPOTENCIA: `CREATE OR REPLACE FUNCTION` + `DROP TRIGGER IF EXISTS` +
--   `CREATE TRIGGER`, sin `vault.create_secret` (fallaría en la segunda
--   pasada por nombre duplicado y obligaría a poner el valor en el repo).
--   El pipeline aplica las migraciones DOS VECES por diseño (integración
--   GitHub de Supabase al mergear + `db push` de Actions) — todo este
--   archivo es re-aplicable sin efecto acumulativo (verificado, tasks.md
--   §4.8: aplicado dos veces seguidas sobre base local, resultado idéntico).
--
-- ORDEN DE DESPLIEGUE OBLIGATORIO (design.md §Migration Plan): esta
--   migración DEBE aplicarse ANTES de que se despliegue la nueva versión de
--   la Edge Function `send-email` que exige el header. `deploy.yml` ya lo
--   garantiza: "Deploy Database Migrations" (línea ~60, `db push
--   --include-all`) corre ANTES que "Deploy Edge Functions" (línea ~63,
--   `functions deploy --no-verify-jwt`), mismo job. Un header de más es
--   ignorado por la versión vieja de la función; un header de menos sería
--   un 401 masivo — por eso el orden importa y no hace falta partir en dos
--   PRs.
--
-- PRE-REQUISITO FUERA DE BANDA (PO, ANTES de mergear — tasks.md §0.5-0.8):
--   sin esto el deploy corta TODO el correo transaccional (fail-closed,
--   D3, ver supabase/functions/send-email/index.ts):
--
--   SELECT vault.create_secret(
--     '<valor aleatorio, ej. openssl rand -hex 32>',
--     'send_email_webhook_secret',
--     'Secreto compartido — autentica al trigger de email_logs contra send-email'
--   );
--   SELECT vault.create_secret(
--     'https://<project-ref>.supabase.co',
--     'edge_functions_base_url',
--     'Base URL de Edge Functions para llamadas HTTP desde triggers'
--   );
--   -- + secret de Edge Functions SEND_EMAIL_WEBHOOK_SECRET con el MISMO
--   --   valor (dashboard o `supabase secrets set`).
--   -- Verificar: SELECT name FROM vault.secrets
--   --   WHERE name IN ('send_email_webhook_secret','edge_functions_base_url');
--   --   → debe devolver exactamente 2 filas.
--
-- ROLLBACK: re-desplegar la versión anterior de `send-email` (deja de exigir
--   el header). Esta migración NO necesita revertirse: sin la función que lo
--   exige, el header extra es inocuo, y el guard de entorno es deseable de
--   todos modos. Si hiciera falta revertir el trigger, `20260628000003` es
--   re-aplicable tal cual.
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration).
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT prosecdef, proconfig FROM pg_proc WHERE proname = 'send_email_log_webhook';
--   SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'send_email_log_webhook'; -- sin URL ni secreto literal
--   SELECT tgname, tgtype FROM pg_trigger WHERE tgname = 'on_email_log_insert';
-- =============================================================================


-- =============================================================================
-- 1. public.send_email_log_webhook() — guard de entorno + header autenticado (D1, D2, D4, D6)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.send_email_log_webhook()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $function$
DECLARE
  v_base_url       text;
  v_webhook_secret text;
BEGIN
  -- D6: corte temprano por estado — más barato que leer Vault, y ya hoy la
  -- función `send-email` rechaza (400) cualquier fila que no esté pending,
  -- así que este tráfico nunca producía correo.
  IF NEW.status IS DISTINCT FROM 'pending' THEN
    RETURN NEW;
  END IF;

  -- D1: URL de destino y secreto compartido SOLO desde Supabase Vault —
  -- jamás literales en esta migración (repo público).
  SELECT decrypted_secret INTO v_webhook_secret
  FROM vault.decrypted_secrets
  WHERE name = 'send_email_webhook_secret'
  LIMIT 1;

  SELECT decrypted_secret INTO v_base_url
  FROM vault.decrypted_secrets
  WHERE name = 'edge_functions_base_url'
  LIMIT 1;

  -- D2: el guard de entorno ES el guard de seguridad. La posesión de AMBOS
  -- valores en Vault es la ÚNICA definición de "esta es la base de
  -- producción" — no se infiere el entorno por ningún otro medio. Sin
  -- alguno de los dos, no hay forma de autenticarse contra `send-email`, así
  -- que no tiene sentido emitir la request. RAISE NOTICE (no WARNING): este
  -- trigger corre por fila insertada, no una vez por minuto como el relay de
  -- CAE — con decenas de usuarios sintéticos en un `db reset` de CI, WARNING
  -- inundaría la salida.
  IF v_webhook_secret IS NULL OR v_base_url IS NULL THEN
    RAISE NOTICE 'send_email_log_webhook: Vault secrets not configured (send_email_webhook_secret / edge_functions_base_url) — skipping HTTP call for email_logs.id=%', NEW.id;
    RETURN NEW;
  END IF;

  -- D4: header propio `x-webhook-secret`, NO `Authorization` — el gateway de
  -- Supabase intercepta `Authorization` como su propio token de proyecto
  -- antes de que llegue al handler de la función.
  PERFORM net.http_post(
    url     := v_base_url || '/functions/v1/send-email',
    headers := jsonb_build_object(
      'Content-Type',     'application/json',
      'x-webhook-secret',  v_webhook_secret
    ),
    body    := jsonb_build_object(
      'type',   'INSERT',
      'table',  'email_logs',
      'record', to_jsonb(NEW)
    )
  );

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.send_email_log_webhook IS
  'send-email-webhook-hardening (D1/D2/D4/D6, sign-off PO 2026-07-31): SECURITY DEFINER '
  'que lee send_email_webhook_secret + edge_functions_base_url desde vault.decrypted_secrets '
  'y llama a send-email vía net.http_post con header x-webhook-secret. Inerte (RAISE NOTICE, '
  'sin HTTP) si falta cualquiera de los dos valores en Vault o si NEW.status <> ''pending''. '
  'La posesión de ambos secretos en Vault es la única definición de "entorno de producción".';


-- =============================================================================
-- 2. Recrear el trigger (sin cambios de forma — AFTER INSERT FOR EACH ROW)
-- =============================================================================
DROP TRIGGER IF EXISTS on_email_log_insert ON public.email_logs;

CREATE TRIGGER on_email_log_insert
  AFTER INSERT ON public.email_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.send_email_log_webhook();


-- =============================================================================
-- 3. GATES SQL (RED→GREEN→TRIANGULATE) — patrón billing-edge-effective-plan /
--    v31-fsm-status-triggers. Estructurales: SIEMPRE (prod y CI).
--    Comportamiento: SOLO si public.accounts está vacía (CI) — email_logs no
--    tiene FK a accounts, así que el anchor es una fila standalone, sin
--    necesitar provisionar cuenta/usuario. Limpieza best-effort.
-- =============================================================================
DO $gate$
DECLARE
  v_count          int;
  v_funcdef        text;
  v_run_behavioral boolean := false;

  -- estructurales
  v_gate_a boolean := false;  -- send_email_log_webhook: 1 sola def, SECURITY DEFINER + search_path fijado
  v_gate_b boolean := false;  -- cuerpo sin URL literal *.supabase.co
  v_gate_c boolean := false;  -- cuerpo referencia vault.decrypted_secrets + header x-webhook-secret
  v_gate_d boolean := false;  -- trigger on_email_log_insert: AFTER INSERT FOR EACH ROW, exactamente 1

  -- comportamiento (solo DB vacía)
  v_anchor_pending_id uuid := gen_random_uuid();
  v_anchor_sent_id    uuid := gen_random_uuid();
  v_queue_before       bigint;
  v_queue_after_1      bigint;
  v_queue_after_2      bigint;
  v_email_log_status   text;

  v_gate_e boolean := false;  -- sin secretos en Vault: INSERT pending no encola HTTP
  v_gate_f boolean := false;  -- el INSERT de (e) se confirma igual (no aborta la transacción del productor)
  v_gate_g boolean := false;  -- control negativo: status='sent' tampoco encola HTTP
BEGIN

  -- ── (a) send_email_log_webhook: 1 sola definición, SECURITY DEFINER + search_path ──
  SELECT COUNT(*) INTO v_count
  FROM pg_proc WHERE proname = 'send_email_log_webhook' AND pronamespace = 'public'::regnamespace;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaba 1 definición de send_email_log_webhook, hay % (lección 42725/overload)', v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'send_email_log_webhook' AND pronamespace = 'public'::regnamespace
      AND prosecdef
      AND proconfig IS NOT NULL
      AND EXISTS (SELECT 1 FROM unnest(proconfig) cfg WHERE cfg LIKE 'search_path=%')
  ) THEN
    RAISE EXCEPTION 'GATE (a) FAILED: send_email_log_webhook debe ser SECURITY DEFINER con search_path fijado';
  END IF;
  v_gate_a := true;

  -- ── (b)/(c) inspección del cuerpo de la función (design.md: sin URL ni secreto literal) ──
  SELECT pg_get_functiondef(oid) INTO v_funcdef
  FROM pg_proc WHERE proname = 'send_email_log_webhook' AND pronamespace = 'public'::regnamespace;

  IF v_funcdef ILIKE '%supabase.co%' THEN
    RAISE EXCEPTION 'GATE (b) FAILED: el cuerpo de send_email_log_webhook contiene una URL de proyecto literal (*.supabase.co)';
  END IF;
  v_gate_b := true;

  IF v_funcdef NOT ILIKE '%vault.decrypted_secrets%' OR v_funcdef NOT ILIKE '%x-webhook-secret%' THEN
    RAISE EXCEPTION 'GATE (c) FAILED: el cuerpo de send_email_log_webhook debe referenciar vault.decrypted_secrets y el header x-webhook-secret';
  END IF;
  v_gate_c := true;

  -- ── (d) trigger on_email_log_insert: AFTER INSERT FOR EACH ROW, exactamente 1 ──
  SELECT COUNT(*) INTO v_count
  FROM information_schema.triggers
  WHERE event_object_schema = 'public'
    AND event_object_table = 'email_logs'
    AND trigger_name = 'on_email_log_insert'
    AND action_timing = 'AFTER'
    AND event_manipulation = 'INSERT'
    AND action_orientation = 'ROW';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (d) FAILED: se esperaba exactamente 1 trigger on_email_log_insert (AFTER INSERT FOR EACH ROW) sobre email_logs, hay %', v_count;
  END IF;
  v_gate_d := true;

  -- ══════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). email_logs no tiene FK a accounts:
  -- el anchor es una fila standalone, sin provisionar cuenta ni usuario.
  -- ══════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- ── (e)/(f) sin secretos en Vault (default en CI/local: nadie corrió
      -- el setup fuera de banda del PO), un INSERT pending NO debe encolar
      -- ninguna request HTTP — es la prueba directa de que las ráfagas de
      -- CI observadas el 2026-07-31 se terminaron.
      SELECT COUNT(*) INTO v_queue_before FROM net.http_request_queue;

      -- event_type distinto entre los dos anchors: email_logs tiene
      -- UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)
      -- (20250101000008) — con user_id NULL y metadata default '{}' en
      -- ambos INSERT, un event_type repetido violaría esa constraint.
      INSERT INTO public.email_logs (id, event_type, recipient, subject, status)
      VALUES (v_anchor_pending_id, 'gate_send_email_webhook_hardening_pending', 'gate-synthetic@test.local', 'GATE 5.5/5.6', 'pending');

      SELECT COUNT(*) INTO v_queue_after_1 FROM net.http_request_queue;

      IF v_queue_after_1 <> v_queue_before THEN
        RAISE EXCEPTION 'GATE (e) FAILED: un INSERT pending sin secretos en Vault encoló % fila(s) nueva(s) en net.http_request_queue (antes=%, después=%) — el guard de entorno no está frenando el tráfico', (v_queue_after_1 - v_queue_before), v_queue_before, v_queue_after_1;
      END IF;
      v_gate_e := true;

      -- (f): el INSERT del productor se confirma igual — el guard no debe
      -- abortar NUNCA la transacción del productor.
      SELECT status INTO v_email_log_status FROM public.email_logs WHERE id = v_anchor_pending_id;
      IF v_email_log_status IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'GATE (f) FAILED: la fila anchor no quedó persistida con status=pending (encontrado: %) — el guard de entorno abortó o alteró la transacción del productor', v_email_log_status;
      END IF;
      v_gate_f := true;

      -- ── (g) control negativo del corte por estado: status='sent' tampoco
      -- encola tráfico (ni siquiera llega a leer Vault).
      INSERT INTO public.email_logs (id, event_type, recipient, subject, status)
      VALUES (v_anchor_sent_id, 'gate_send_email_webhook_hardening_sent', 'gate-synthetic@test.local', 'GATE 5.7', 'sent');

      SELECT COUNT(*) INTO v_queue_after_2 FROM net.http_request_queue;

      IF v_queue_after_2 <> v_queue_after_1 THEN
        RAISE EXCEPTION 'GATE (g) FAILED: un INSERT con status=sent encoló % fila(s) nueva(s) en net.http_request_queue — el corte por estado (D6) no está funcionando', (v_queue_after_2 - v_queue_after_1);
      END IF;
      v_gate_g := true;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (%' THEN
          RAISE;  -- una aserción real falló — abortar (CI lo atrapa)
        END IF;
        v_run_behavioral := false;
        RAISE NOTICE 'send-email-webhook-hardening: anchor sintético/gates de comportamiento degradados (%) — %', SQLSTATE, SQLERRM;
    END;

    -- ── Limpieza best-effort del anchor sintético (solo DB de test) ────────
    BEGIN
      DELETE FROM public.email_logs WHERE id IN (v_anchor_pending_id, v_anchor_sent_id);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'send-email-webhook-hardening: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== send-email-webhook-hardening SQL gates ===';
  RAISE NOTICE '(a) send_email_log_webhook: 1 def, SECURITY DEFINER + search_path: %', v_gate_a;
  RAISE NOTICE '(b) cuerpo sin URL literal *.supabase.co:                          %', v_gate_b;
  RAISE NOTICE '(c) cuerpo referencia vault.decrypted_secrets + x-webhook-secret:  %', v_gate_c;
  RAISE NOTICE '(d) trigger on_email_log_insert AFTER INSERT FOR EACH ROW, 1 solo: %', v_gate_d;
  RAISE NOTICE '(e) sin secretos en Vault: INSERT pending no encola HTTP:          %', v_gate_e;
  RAISE NOTICE '(f) el INSERT del productor se confirma igual (no abortado):       %', v_gate_f;
  RAISE NOTICE '(g) control negativo: status=sent tampoco encola HTTP:             %', v_gate_g;
  RAISE NOTICE '=== send-email-webhook-hardening: instalado OK ===';

END $gate$;
