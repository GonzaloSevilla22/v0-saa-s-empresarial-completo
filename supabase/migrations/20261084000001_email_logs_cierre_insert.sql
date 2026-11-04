-- =============================================================================
-- MIGRATION: 20261084000001_email_logs_cierre_insert.sql
-- HOTFIX:    email-logs-cierre-insert (OQ-7 de multiusuario-operativo, opción (a),
--            firmada por el PO). Governance CRÍTICO: vector de phishing desde el
--            dominio de ALIADATA; toca RLS, ACL y el envío de correos.
-- =============================================================================
--
-- EL HALLAZGO
--   `public.email_logs` admitía INSERT de cualquier usuario autenticado:
--     · policy `email_logs_backend_insert` (INSERT, authenticated, WITH CHECK (true)),
--       agregada en 20260828000001 (§4.2) como «excepción justificada» para cuando el
--       backend pasara a correr como `authenticated`;
--     · `authenticated` con INSERT/UPDATE/DELETE/TRUNCATE a nivel tabla (arwdDxtm) y
--       `anon` con SELECT.
--   La fila nace `status = 'pending'` (default, sin CHECK) y el trigger
--   `on_email_log_insert` → `send_email_log_webhook()` invoca a la Edge Function
--   `send-email`, que manda el correo desde `no-reply@aliadata.com.ar` a CUALQUIER
--   destinatario y con CUALQUIER asunto. Las plantillas no escapaban los datos del
--   usuario y `meeting_notice` tomaba el enlace de la metadata. Sin multiusuario de
--   por medio: explotable HOY por cualquier cuenta gratuita.
--
-- POR QUÉ SE PUEDE CERRAR SIN ROMPER NADA (inventario completo en
-- openspec/changes/multiusuario-operativo/evidence/hotfix-email-logs/inventario.md)
--   · Las 10 funciones SQL que escriben en `email_logs` son SECURITY DEFINER
--     (propietaria postgres): un trigger/cron DEFINER corre con el privilegio de su
--     propietario aunque lo dispare un `authenticated`. No las alcanza el REVOKE.
--   · Todos los INSERT del backend Python van por `get_service_conn` (usuario
--     postgres, propietario de la tabla), nunca por `get_db_conn`.
--   · `send-email` actualiza el estado con la service role key (`service_role`
--     conserva todo).
--   · El ÚNICO caller con sesión de usuario era
--     `frontend/app/api/billing/cancel/route.ts` (correo `plan_downgraded`).
--     Se migra: el correo se encola ADENTRO de `rpc_request_subscription_cancellation()`,
--     en la misma transacción que la cancelación. Destinatario y `user_id` salen de
--     `auth.uid()` / `auth.users`, NUNCA de un parámetro (la RPC no tiene ninguno), y
--     sólo la alcanza el titular de la cuenta (P0403 para cualquier otro).
--
-- QUÉ HACE
--   1. DROP POLICY email_logs_backend_insert.
--   2. REVOKE ALL ON email_logs FROM anon, authenticated; GRANT SELECT a
--      authenticated (la policy "Admins can view email logs" lo necesita).
--      service_role y postgres conservan todo. Doble candado: privilegio Y ausencia
--      de policy de escritura (default-deny de la RLS).
--   3. rpc_request_subscription_cancellation(): reescrita DESDE EL CUERPO VIVO
--      (md5 de prod verificado en el preflight) con tres agregados y nada más:
--        a. `FOR UPDATE` sobre la fila de la cuenta: dos cancelaciones simultáneas ya
--           no pueden pasar ambas el chequeo de estado y encolar dos correos;
--        b. encola el correo `plan_downgraded` (mismo asunto y metadata que encolaba
--           la ruta), con `ON CONFLICT DO NOTHING`;
--        c. el INSERT va en un subbloque que traga el error: un correo que falla
--           NUNCA aborta una cancelación (igual que antes: la ruta ignoraba el error).
--      Firma, tipo de retorno, códigos de error (P0401/P0404/P0403/P0400/P0409), ACL
--      y SECURITY DEFINER/search_path no cambian.
--
-- IDEMPOTENCIA: DROP POLICY IF EXISTS; REVOKE/GRANT idempotentes; CREATE OR REPLACE
--   sobre firma fija (sin overload, sin 42725). El preflight acepta el cuerpo de
--   partida (md5 de prod) o el propio (reaplicación) y aborta ante cualquier otro.
--
-- ORDEN DE DESPLIEGUE: esta migración y el frontend nuevo salen en el mismo merge.
--   · Frontend viejo + migración (ventana de segundos): la ruta vieja intenta su
--     INSERT en email_logs, falla con 42501 (su error se ignoraba) y el correo ya lo
--     encoló la RPC → un solo correo, ninguna cancelación rota.
--   · Frontend nuevo + migración vieja (si Vercel gana la carrera): la cancelación
--     funciona y el correo de «suscripción cancelada» se pierde esa ventana.
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP apply_migration).
--
-- ROLLBACK (de emergencia; REABRE el hallazgo, usar sólo si el correo de cancelación
--   deja de salir y el arreglo hacia adelante tarda; revertir además el PR del
--   frontend para no duplicar el correo):
--     CREATE POLICY "email_logs_backend_insert" ON public.email_logs
--       FOR INSERT TO authenticated WITH CHECK (true);
--     GRANT INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.email_logs TO authenticated;
--     GRANT SELECT ON public.email_logs TO anon;
--     -- y re-crear rpc_request_subscription_cancellation() con el cuerpo de
--     -- 20261053000001 (md5 8e63a7a288ba5692b78a012507dd612b).
--
-- VERIFICATION (post-merge, MCP de sólo lectura):
--   SELECT policyname, cmd FROM pg_policies WHERE tablename = 'email_logs';       -- sólo la de SELECT
--   SELECT relacl FROM pg_class WHERE oid = 'public.email_logs'::regclass;        -- sin arwd para authenticated/anon
--   SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
--    WHERE oid = 'public.rpc_request_subscription_cancellation()'::regprocedure;  -- el md5 de abajo
-- =============================================================================


-- =============================================================================
-- 0. PREFLIGHT
-- =============================================================================
DO $preflight$
DECLARE
  v_md5 text;
BEGIN
  IF to_regclass('public.email_logs') IS NULL THEN
    RAISE EXCEPTION 'email-logs-cierre-insert: falta public.email_logs.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'public.email_logs'::regclass AND tgname = 'on_email_log_insert' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'email-logs-cierre-insert: falta el trigger on_email_log_insert (el que invoca a send-email): este hotfix asume el camino de envío vigente.';
  END IF;
  IF to_regprocedure('public.rpc_request_subscription_cancellation()') IS NULL THEN
    RAISE EXCEPTION 'email-logs-cierre-insert: falta public.rpc_request_subscription_cancellation().';
  END IF;

  SELECT md5(replace(prosrc, E'\r', '')) INTO v_md5
  FROM   pg_proc
  WHERE  oid = 'public.rpc_request_subscription_cancellation()'::regprocedure;
  -- El de partida (cuerpo de producción 2026-10-17, de 20261053000001) o el propio.
  IF v_md5 NOT IN ('8e63a7a288ba5692b78a012507dd612b', '7f355faf5ad2c5c20a953ae32386dab9') THEN
    RAISE EXCEPTION 'email-logs-cierre-insert: el cuerpo vivo de rpc_request_subscription_cancellation() (md5 %) no es ni el de partida ni el de esta migración: otro change lo reescribió; rebasar este hotfix sobre el cuerpo vivo.', v_md5;
  END IF;
END $preflight$;


-- =============================================================================
-- 1. Cerrar la escritura abierta de email_logs
-- =============================================================================
DROP POLICY IF EXISTS "email_logs_backend_insert" ON public.email_logs;

-- REVOKE ALL (INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN, SELECT)
-- y devolver únicamente SELECT a authenticated: la policy de lectura de
-- administradores ("Admins can view email logs") filtra por fila.
REVOKE ALL ON TABLE public.email_logs FROM anon;
REVOKE ALL ON TABLE public.email_logs FROM authenticated;
GRANT SELECT ON TABLE public.email_logs TO authenticated;

COMMENT ON TABLE public.email_logs IS
  'Cola y registro de correos transaccionales. SOLO se escribe desde funciones SQL SECURITY DEFINER, el backend por el contexto de servicio (get_service_conn) y la Edge Function send-email con la service role key; authenticated y anon no tienen INSERT/UPDATE/DELETE (email-logs-cierre-insert). El trigger on_email_log_insert invoca a send-email por cada fila pending.';


-- =============================================================================
-- 2. rpc_request_subscription_cancellation(): encola el correo adentro
--    (cuerpo vivo de 20261053000001 + FOR UPDATE + encolado del correo)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_request_subscription_cancellation()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        uuid := auth.uid();
  v_account_id uuid;
  v_owner      uuid;
  v_plan       text;
  v_status     text;
  v_expires    timestamptz;
  v_email      text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'account_not_found'
      USING ERRCODE = 'P0404';
  END IF;

  -- FOR UPDATE: dos cancelaciones simultáneas se serializan; la segunda ve
  -- 'cancelling' y recibe P0409 en vez de encolar un segundo correo.
  SELECT a.owner_user_id, a.billing_plan, a.billing_status
    INTO v_owner, v_plan, v_status
  FROM   public.accounts a
  WHERE  a.id = v_account_id
  FOR UPDATE;

  -- Titular, no sólo miembro: cancelar una suscripción mueve dinero.
  IF v_owner IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'not_account_owner: sólo el titular puede cancelar la suscripción'
      USING ERRCODE = 'P0403';
  END IF;

  IF coalesce(v_plan, 'gratis') = 'gratis' THEN
    RAISE EXCEPTION 'no_active_paid_plan: no hay un plan pago activo para cancelar'
      USING ERRCODE = 'P0400';
  END IF;

  IF v_status = 'cancelling' THEN
    RAISE EXCEPTION 'cancellation_already_scheduled: la cancelación ya está programada'
      USING ERRCODE = 'P0409';
  END IF;

  v_expires := now() + interval '30 days';

  UPDATE public.accounts
  SET    billing_status  = 'cancelling',
         plan_expires_at = v_expires
  WHERE  id = v_account_id;

  -- Correo de confirmación (email-logs-cierre-insert). El destinatario y el
  -- user_id salen de la SESIÓN (v_uid = el titular, verificado arriba), nunca de
  -- un parámetro: esta función no tiene ninguno. Un correo que falla no aborta la
  -- cancelación (misma semántica que cuando lo insertaba la ruta y ignoraba el error).
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_uid;
  IF coalesce(v_email, '') <> '' THEN
    BEGIN
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      VALUES (
        v_uid,
        'plan_downgraded',
        v_email,
        'Tu suscripción fue cancelada — Aliadata',
        jsonb_build_object(
          'plan',            v_plan,
          'plan_expires_at', v_expires,
          'reason',          'user_requested'
        )
      )
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'rpc_request_subscription_cancellation: no se pudo encolar el correo plan_downgraded (%): %', SQLSTATE, SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'account_id',      v_account_id,
    'from_plan',       v_plan,
    'plan_expires_at', v_expires
  );
END;
$function$;

-- CREATE OR REPLACE conserva el ACL, pero se re-emite por idempotencia y para que
-- el gate de ACLs (advisors 0028/0029) lo vea en el mismo archivo que el CREATE.
REVOKE ALL ON FUNCTION public.rpc_request_subscription_cancellation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_request_subscription_cancellation() FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_request_subscription_cancellation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_request_subscription_cancellation() TO service_role;

COMMENT ON FUNCTION public.rpc_request_subscription_cancellation() IS
  'Programa la cancelación de la suscripción del TITULAR de la cuenta resuelta desde auth.uid() y encola, en la misma transacción, el correo plan_downgraded a SU email (auth.users). Sin parámetros por diseño (ni plan, ni fechas, ni destinatario). Reemplaza el UPDATE directo sobre accounts (accounts-profiles-privilege-columns) y el INSERT directo en email_logs (email-logs-cierre-insert) que hacía frontend/app/api/billing/cancel/route.ts como authenticated.';


-- =============================================================================
-- 3. Introspección de la propia migración (sin tolerancia: aborta si algo no quedó)
-- =============================================================================
DO $gate$
DECLARE
  v_role text;
  v_priv text;
  v_bad  text := '';
  v_def  text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'email_logs'
               AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')) THEN
    v_bad := v_bad || 'quedó una policy de escritura sobre email_logs; ';
  END IF;

  FOREACH v_role IN ARRAY ARRAY['authenticated', 'anon'] LOOP
    FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
      IF has_table_privilege(v_role, 'public.email_logs', v_priv) THEN
        v_bad := v_bad || format('%s conserva %s; ', v_role, v_priv);
      END IF;
    END LOOP;
  END LOOP;
  IF has_table_privilege('anon', 'public.email_logs', 'SELECT') THEN
    v_bad := v_bad || 'anon conserva SELECT; ';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.email_logs', 'SELECT') THEN
    v_bad := v_bad || 'authenticated perdió SELECT; ';
  END IF;
  IF NOT (has_table_privilege('service_role', 'public.email_logs', 'INSERT')
          AND has_table_privilege('service_role', 'public.email_logs', 'UPDATE')) THEN
    v_bad := v_bad || 'service_role perdió INSERT/UPDATE (send-email); ';
  END IF;

  SELECT pg_get_functiondef('public.rpc_request_subscription_cancellation()'::regprocedure) INTO v_def;
  IF v_def NOT LIKE '%SECURITY DEFINER%'
     OR v_def NOT LIKE '%''plan_downgraded''%'
     OR v_def NOT LIKE '%FOR UPDATE%' THEN
    v_bad := v_bad || 'el cuerpo de rpc_request_subscription_cancellation() no es el esperado; ';
  END IF;
  IF (SELECT pronargs FROM pg_proc WHERE oid = 'public.rpc_request_subscription_cancellation()'::regprocedure) <> 0 THEN
    v_bad := v_bad || 'rpc_request_subscription_cancellation() debe seguir sin parámetros; ';
  END IF;
  IF has_function_privilege('anon', 'public.rpc_request_subscription_cancellation()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_request_subscription_cancellation()', 'EXECUTE') THEN
    v_bad := v_bad || 'ACL de rpc_request_subscription_cancellation() incorrecta; ';
  END IF;
  IF obj_description('public.rpc_request_subscription_cancellation()'::regprocedure, 'pg_proc') IS NULL THEN
    v_bad := v_bad || 'falta el COMMENT de la RPC; ';
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'email-logs-cierre-insert GATE FAILED: %', v_bad;
  END IF;
  RAISE NOTICE 'email-logs-cierre-insert (introspección): OK — email_logs sin policy ni privilegio de escritura para authenticated/anon, service_role intacto, RPC de cancelación con el correo adentro.';
END $gate$;
