-- =============================================================================
-- accounts-profiles-privilege-columns — privilegios POR COLUMNA sobre las dos
-- tablas de identidad/facturación (governance CRÍTICO: dominio billing +
-- seguridad; arreglo aprobado explícitamente por el PO el 2026-09-21)
-- =============================================================================
--
-- EL HALLAZGO (verificado en el catálogo VIVO de prod gxdhpxvdjjkmxhdkkwyb,
-- sólo lectura, el 2026-09-21 — y reproducido por ejecución en el stack local
-- antes de escribir este archivo):
--
--   · `public.accounts`  → relacl `authenticated=arwdDxtm/postgres`
--     (INSERT+SELECT+UPDATE+DELETE+TRUNCATE), `pg_attribute.attacl` NULL en
--     las 15 columnas (CERO ACLs de columna), CERO triggers no internos, y
--     una sola policy de escritura: `accounts_owner_update`
--     (FOR UPDATE, USING = WITH CHECK = `owner_user_id = auth.uid()`),
--     SIN restricción de columnas.
--     ⇒ El dueño de una cuenta podía hacer, con SU PROPIO JWT,
--       `PATCH /rest/v1/accounts?id=eq.<la suya>` y escribir
--       `billing_exempt=true` (el CHECK sólo exige un motivo),
--       `billing_plan='pro'`, `plan_expires_at` lejano o un trial eterno.
--       `get_effective_plan` resuelve exención → trial vigente → plan pago,
--       así que cualquiera de las tres columnas alcanza para Pro gratis.
--
--   · `public.profiles`  → EXACTAMENTE la misma forma: `authenticated=arwdDxtm`,
--     0 ACLs de columna, y la policy `Users can update own profile`
--     (USING `auth.uid() = id`, sin WITH CHECK propio → Postgres usa el USING
--     también como CHECK), sin restricción de columnas. El único guard que
--     existe (`trg_prevent_profile_escalation` → `prevent_profile_privilege_
--     escalation()`, BEFORE UPDATE) cubre SÓLO `role`/`plan`/`id`: se escribió
--     en `20260425000001_security_hardening.sql`, SEIS SEMANAS antes de que
--     `20260605000001_billing_schema.sql` agregara a `profiles` las columnas
--     de billing/trial y los contadores de IA/export sin extenderlo.
--     ⇒ Un usuario podía auto-otorgarse `billing_plan='pro'` /
--       `trial_expires_at='2099-…'` (paywall de comunidad: las policies
--       `community.posts_insert_owner_and_plan` / `replies_insert_owner_and_
--       plan` leen `profiles.billing_plan`) y RESETEAR a 0 sus contadores
--       `ai_queries_used`/`ai_advice_used`/`exports_used`/`insights_used`
--       (los lee `supabase/functions/_shared/ai-quota.ts` y
--       `rpc_atomic_log_ai_insight` para la cuota de IA ⇒ costo de OpenAI sin
--       techo, independientemente del plan pagado).
--
-- POR QUÉ ALLOW-LIST POR COLUMNA Y NO UN TRIGGER MÁS. Un trigger que enumere
-- las columnas prohibidas es una DENY-LIST: la columna de billing que se
-- agregue mañana nace desprotegida y nadie lo nota (es literalmente lo que
-- pasó con `profiles` entre abril y junio). El privilegio por columna es una
-- ALLOW-LIST: una vez revocado el UPDATE a nivel TABLA, una columna NUEVA
-- nace SIN UPDATE para `authenticated` — Postgres no propaga el grant de
-- tabla a columnas futuras porque ya no existe grant de tabla. Además se
-- evalúa ANTES de la RLS y de los triggers, así que no depende de que la
-- policy esté bien escrita ni de que el trigger siga en su lugar.
-- `trg_prevent_profile_escalation` NO se toca: queda como segunda capa.
--
-- INVENTARIO DE ESCRITORES (verificado por `pg_proc.prosrc` sobre TODAS las
-- funciones de public/auth/community, no por nombre, + grep del repo):
--
--   accounts — 5 funciones, las 5 SECURITY DEFINER con owner `postgres`
--   (ejecutan puertas adentro sin importar el rol del caller, y NO dependen
--   del grant de tabla de `authenticated`):
--     · `handle_new_user()`            trigger AFTER INSERT en auth.users → el
--                                      ALTA DE CUENTA. No necesita INSERT de
--                                      tabla para `authenticated` (el trigger
--                                      lo dispara GoTrue y corre como su
--                                      definidor).
--     · `expire_trials()` / `process_cancellations()`  → crons (pg_cron corre
--                                      como `postgres`), ACL sin
--                                      `authenticated`.
--     · `rpc_set_default_payment_terms(smallint)`      → Configuración ▸
--                                      Cobranzas. Guard `is_account_writer`
--                                      (P0401) + validación `p_days >= 0`.
--     · `rpc_set_default_product_category(uuid)`       → Configuración ▸
--                                      Categorías. Guard `is_account_writer`
--                                      (P0401) + la categoría debe ser de la
--                                      cuenta, activa y no borrada (P0404).
--     (De paso, el REVOKE cierra gratis el bypass de esas dos validaciones:
--      hasta hoy un `PATCH` crudo escribía `default_payment_terms_days` /
--      `default_product_category_id` salteándolas.)
--
--   accounts — backend Python: `services/payments.py:310` y
--   `services/subscriptions.py:196/304/423/545/635`. Los 9 endpoints de
--   `routers/payments.py` (el único router que los alcanza) usan
--   `Depends(get_service_conn)`, que en `core/database.py` NO emite el
--   `SET LOCAL ROLE authenticated` del Paso 2 de v31-tenancy-pool-rls: corren
--   como `postgres` (BYPASSRLS). Ningún endpoint de ese router usa
--   `get_db_conn` (el import existe sin uso). ⇒ El REVOKE no los alcanza.
--
--   accounts — ÚNICO caller que corría como `authenticated` y se habría roto:
--   `frontend/app/api/billing/cancel/route.ts`, que hacía
--   `.from('accounts').update({billing_status:'cancelling', plan_expires_at})`
--   por PostgREST con el JWT del usuario (`createClient()` de
--   `@/lib/supabase/server` = anon key + cookies de sesión). Es el MISMO
--   mecanismo del hallazgo, así que no se le devuelve el privilegio: se migra
--   a la RPC de la sección 3, que resuelve la cuenta desde `auth.uid()`, exige
--   ser el TITULAR y NO acepta plan ni fechas por parámetro (§3).
--
--   profiles — 5 funciones SECURITY DEFINER: `handle_new_user()`,
--   `set_new_user_trial()` (trigger), `rpc_atomic_log_ai_insight(...)`,
--   `rpc_increment_ai_usage(uuid,text)` y `rpc_increment_export_usage(uuid)`
--   — las dos últimas ya guardan `p_user_id IS DISTINCT FROM auth.uid() →
--   unauthorized` (verificado con `pg_get_functiondef`: no son un camino
--   cross-user) y sólo INCREMENTAN. El backend Python NO escribe `profiles`
--   (grep sin resultados). Callers reales por PostgREST como `authenticated`:
--     · `contexts/auth-context.tsx` `updateProfile`      → name, last_name,
--       business_name, phone, locality, bio, avatar_url (vía
--       `lib/profile-update.ts`, única fuente de ese payload).
--     · `contexts/auth-context.tsx` `updatePreferences`  → currency, timezone,
--       date_format, language.
--     · `terms_version` / `email_notifications_opt_in` / `province` viajan en
--       el `user_metadata` del signUp y los copia `handle_new_user` — NO son
--       un PATCH de `authenticated` (verificado en `app/auth/actions.ts`).
--     · `overstock_threshold`: CERO escritores en todo el repo.
--     · `upgradePlan`/`downgradePlan` del mismo contexto escribían
--       `profiles.plan` desde el navegador (botones "Actualizar a Pro" /
--       "Cambiar a Gratis" de `/configuracion` ▸ Plan). NO es un caller
--       legítimo: es un auto-otorgamiento de plan que hoy sólo falla porque
--       `trg_prevent_profile_escalation` lo rechaza para quien no es admin.
--       Se retira en el mismo PR y los botones pasan a `/planes`, el camino
--       real (MercadoPago). `profiles.plan` NO entra en la allow-list.
--   ⇒ allow-list de `profiles` = esas 11 columnas de perfil y preferencias.
--      Ninguna es de billing, de trial, de cuota ni de privilegio.
--
-- VISTAS (camino de evasión auditado, prod): las dos únicas vistas sobre estas
-- tablas son `community.profiles` (id, name, avatar_url) y
-- `public.profiles_public` (id, name) — ambas con `security_invoker=true`, así
-- que el chequeo de privilegio de la tabla base se hace con el rol INVOCANTE y
-- la allow-list de abajo también las gobierna. Ninguna expone una columna
-- protegida. No hay ninguna vista sobre `accounts`. El gate lo fija como
-- invariante (chequeo (e)).
--
-- INSERT / DELETE / TRUNCATE. `authenticated` los tenía a nivel tabla en las
-- dos tablas. Hoy son inertes para INSERT/DELETE (no existe ninguna policy de
-- INSERT ni de DELETE en ninguna de las dos ⇒ 0 filas), pero TRUNCATE **no
-- pasa por la RLS en absoluto**: era el privilegio más peligroso de los
-- cuatro y no lo frenaba nada más que la ausencia de un camino que lo
-- ejecutara. Ningún caller del repo usa ninguno de los tres (grep) y el alta
-- de cuenta/perfil va por `handle_new_user`. Se revocan los tres.
--
-- `anon` ya no tiene ninguno de los cuatro desde
-- `20261035000001_revoke_anon_table_writes.sql` (relacl `anon=rxtm`); se lo
-- nombra igual en cada REVOKE (no-op idempotente) para que este archivo se
-- sostenga solo si alguna vez se reaplica sobre una base donde ese barrido no
-- corrió, y para que el gate pueda afirmar las dos columnas del contrato sin
-- depender de otra migración.
--
-- LO QUE NO CAMBIA (y por qué): `SELECT`, `REFERENCES`, `TRIGGER` y `MAINTAIN`
-- de `authenticated` quedan intactos (mismo criterio que
-- 20261035000001 §D2 — la lectura es legítima y está acotada por la RLS), las
-- dos policies de `accounts` y las cuatro de `profiles` quedan intactas
-- (`accounts_owner_update` queda inalcanzable para UPDATE por falta de
-- privilegio, no se borra: si algún día se otorgara una columna nueva, el
-- filtro de fila por titular sigue siendo el correcto), y
-- `trg_prevent_profile_escalation` queda intacto como segunda capa.
--
-- GOTCHA MEDIDO (2026-09-21, en el stack local, mientras se probaba que el gate
-- no fuera ciego): un `REVOKE UPDATE ON <tabla>` **también borra los GRANT por
-- COLUMNA** de ese mismo privilegio (Postgres revoca la tabla y sus columnas de
-- una). Por eso el orden REVOKE-de-tabla → GRANT-por-columna de la sección 2 es
-- LOAD-BEARING, no estético: invertirlo (o hacer un REVOKE de tabla "de
-- prolijidad" después del GRANT, como se hace en otras migraciones del
-- proyecto) deja `profiles` sin ninguna columna escribible y rompe el perfil y
-- las preferencias de TODOS los usuarios en silencio. Lo mismo vale para el
-- ROLLBACK de abajo y para cualquier migración futura que toque estos grants.
--
-- Idempotente: REVOKE/GRANT repetidos son no-op; `CREATE OR REPLACE FUNCTION`
-- de la §3 no crea overload (la función no tiene parámetros y no existía
-- antes, así que no hay riesgo del 42725 de DROP+CREATE con DEFAULT nuevo).
-- Segura en base vacía: sólo toca objetos que existen desde
-- 20260425000001 (`profiles`) y 20260605000001 (`accounts`).
--
-- Candado: `supabase/tests/test_accounts_privilege_columns.sql`, cableado en
-- `.github/workflows/KPI_Validation.yml`. Afirma la allow-list por columna
-- (una columna nueva que `authenticated` pueda escribir y no esté declarada
-- ⇒ FALLA), el intento REAL bajo `SET LOCAL ROLE authenticated` con claims de
-- un usuario dueño de una cuenta de fixture (42501 + fila intacta), el camino
-- legítimo (las 11 columnas y las 3 RPCs) y una MATRIZ DE EVASIÓN ejecutada
-- (UPDATE directo, UPDATE … RETURNING, upsert ON CONFLICT DO UPDATE, vista
-- actualizable, y cada RPC con EXECUTE para authenticated con parámetros
-- hostiles).
--
-- APPLY: npx supabase db push  (NUNCA el MCP apply_migration)
-- ROLLBACK (si un caller legítimo apareciera: re-otorgar SÓLO esa columna,
-- nunca el privilegio de tabla):
--   GRANT UPDATE (<columna>) ON public.accounts TO authenticated;
-- =============================================================================


-- =============================================================================
-- 1. accounts — allow-list VACÍA: `authenticated` no escribe NINGUNA columna.
--    Toda escritura legítima entra por función SECURITY DEFINER
--    (handle_new_user, los dos crons, las dos RPCs de configuración y la RPC
--    de cancelación de la §3) o por el contexto de servicio del backend.
-- =============================================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.accounts FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.accounts FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.accounts FROM PUBLIC;


-- =============================================================================
-- 2. profiles — allow-list de 11 columnas de perfil y preferencias.
--    El REVOKE de tabla va PRIMERO: sin él, el GRANT por columna no agrega
--    nada (el grant de tabla ya cubre todas las columnas, presentes y
--    futuras).
-- =============================================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.profiles FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.profiles FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.profiles FROM PUBLIC;

-- MISMA lista que `v_allowed_profile_cols` en
-- supabase/tests/test_accounts_privilege_columns.sql. Si se agrega una
-- columna acá, hay que agregarla allá en el MISMO PR o el gate falla.
GRANT UPDATE (
  name,
  last_name,
  business_name,
  phone,
  locality,
  bio,
  avatar_url,
  currency,
  timezone,
  date_format,
  language
) ON public.profiles TO authenticated;


-- =============================================================================
-- 3. Cancelación de suscripción — el caller migrado.
--
--    Reemplaza el `UPDATE public.accounts` que
--    `frontend/app/api/billing/cancel/route.ts` hacía por PostgREST como
--    `authenticated`. Diferencias deliberadas con el camino que reemplaza:
--
--      · NO acepta parámetros. Ni plan, ni estado, ni fecha: el
--        `plan_expires_at` lo calcula la función (now() + 30 días, la misma
--        estimación del MVP que hacía la ruta) y el `billing_status` es la
--        constante 'cancelling'. Un parámetro de fecha o de plan habría
--        recreado el hallazgo por otra puerta.
--      · Exige ser el TITULAR (`owner_user_id = auth.uid()`), no sólo miembro.
--        La ruta anterior sólo comprobaba membresía y dejaba que la RLS
--        filtrara: para un miembro NO titular el UPDATE afectaba 0 filas y la
--        ruta respondía `{ok:true}` igual — una confirmación de cancelación
--        falsa (hallazgo A1-5 de la auditoría). Ahora es un P0403 explícito.
--      · Resuelve la cuenta con `current_account_ids()` LIMIT 1, el mismo
--        patrón de `rpc_set_default_payment_terms` /
--        `rpc_set_default_product_category` (una cuenta por usuario es el
--        supuesto vigente en todo el proyecto).
--
--    Devuelve el `from_plan` y el `plan_expires_at` porque la ruta los sigue
--    necesitando para su fila de `billing_events` y para el mail de
--    `email_logs` — esas dos escrituras NO se mueven acá: `authenticated`
--    las hace hoy con su propia RLS y este change no las toca.
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

  SELECT a.owner_user_id, a.billing_plan, a.billing_status
    INTO v_owner, v_plan, v_status
  FROM   public.accounts a
  WHERE  a.id = v_account_id;

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

  RETURN jsonb_build_object(
    'account_id',      v_account_id,
    'from_plan',       v_plan,
    'plan_expires_at', v_expires
  );
END;
$function$;

-- Gotcha del proyecto: PostgREST expone por default toda función de `public`;
-- el REVOKE explícito es lo que la saca del alcance de `anon` (chequeo (2) del
-- gate de ACLs, supabase/tests/test_function_acl_gate.sql).
REVOKE ALL ON FUNCTION public.rpc_request_subscription_cancellation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_request_subscription_cancellation() FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_request_subscription_cancellation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_request_subscription_cancellation() TO service_role;

COMMENT ON FUNCTION public.rpc_request_subscription_cancellation() IS
  'accounts-profiles-privilege-columns: programa la cancelación de la suscripción del TITULAR de la cuenta resuelta desde auth.uid(). Sin parámetros por diseño (ni plan ni fechas). Reemplaza el UPDATE directo sobre accounts que hacía frontend/app/api/billing/cancel/route.ts como authenticated.';


-- =============================================================================
-- 4. Gate de la propia migración (mismo molde que
--    20261035000001_revoke_anon_table_writes.sql §3).
-- =============================================================================

DO $$
DECLARE
  -- MISMA lista que la §2 y que el gate de supabase/tests/.
  v_allowed_profile_cols CONSTANT text[] := ARRAY[
    'name', 'last_name', 'business_name', 'phone', 'locality', 'bio',
    'avatar_url', 'currency', 'timezone', 'date_format', 'language'
  ];
  v_role   text;
  v_tbl    text;
  v_priv   text;
  v_col    RECORD;
  v_name   text;
  v_bad    text := '';
BEGIN
  -- (a) Ni `authenticated` ni `anon` conservan privilegio de escritura a
  --     nivel TABLA en ninguna de las dos tablas.
  FOREACH v_role IN ARRAY ARRAY['authenticated', 'anon'] LOOP
    FOREACH v_tbl IN ARRAY ARRAY['public.accounts', 'public.profiles'] LOOP
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF has_table_privilege(v_role, v_tbl, v_priv) THEN
          v_bad := v_bad || format('%s tiene %s de TABLA sobre %s; ', v_role, v_priv, v_tbl);
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  -- (b) `accounts`: allow-list VACÍA — ninguna columna escribible por
  --     `authenticated` ni por `anon` (has_any_column_privilege sí ve los
  --     grants de columna, has_table_privilege no).
  FOREACH v_role IN ARRAY ARRAY['authenticated', 'anon'] LOOP
    IF has_any_column_privilege(v_role, 'public.accounts', 'UPDATE') THEN
      v_bad := v_bad || format('%s puede UPDATE alguna columna de accounts (allow-list vacía); ', v_role);
    END IF;
  END LOOP;

  -- (c) `profiles`: exactamente la allow-list declarada, ni una más.
  FOR v_col IN
    SELECT a.attname
    FROM   pg_attribute a
    WHERE  a.attrelid = 'public.profiles'::regclass
      AND  a.attnum > 0 AND NOT a.attisdropped
  LOOP
    IF has_column_privilege('authenticated', 'public.profiles', v_col.attname, 'UPDATE')
       AND NOT (v_col.attname = ANY (v_allowed_profile_cols))
    THEN
      v_bad := v_bad || format('authenticated puede UPDATE profiles.%s, fuera de la allow-list; ', v_col.attname);
    END IF;

    IF has_column_privilege('anon', 'public.profiles', v_col.attname, 'UPDATE') THEN
      v_bad := v_bad || format('anon puede UPDATE profiles.%s; ', v_col.attname);
    END IF;
  END LOOP;

  -- (d) El camino legítimo sigue en pie: las 11 columnas declaradas.
  FOREACH v_name IN ARRAY v_allowed_profile_cols LOOP
    IF NOT has_column_privilege('authenticated', 'public.profiles', v_name, 'UPDATE') THEN
      v_bad := v_bad || format('authenticated PERDIÓ el UPDATE de profiles.%s (está en la allow-list); ', v_name);
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'accounts-profiles-privilege-columns GATE FAILED: %', v_bad;
  END IF;

  -- (e) La RPC de cancelación existe, no acepta parámetros y no es ejecutable
  --     por `anon`.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rpc_request_subscription_cancellation'
      AND p.pronargs = 0 AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'accounts-profiles-privilege-columns GATE FAILED: rpc_request_subscription_cancellation() debe existir, ser SECURITY DEFINER y NO aceptar parámetros.';
  END IF;

  IF has_function_privilege('anon', 'public.rpc_request_subscription_cancellation()', 'EXECUTE') THEN
    RAISE EXCEPTION 'accounts-profiles-privilege-columns GATE FAILED: anon puede ejecutar rpc_request_subscription_cancellation().';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.rpc_request_subscription_cancellation()', 'EXECUTE') THEN
    RAISE EXCEPTION 'accounts-profiles-privilege-columns GATE FAILED: authenticated NO puede ejecutar rpc_request_subscription_cancellation() — la cancelación queda rota.';
  END IF;

  RAISE NOTICE 'accounts-profiles-privilege-columns OK: accounts sin ninguna columna escribible por authenticated/anon, profiles con exactamente % columnas en la allow-list, y la cancelación migrada a una RPC sin parámetros.', array_length(v_allowed_profile_cols, 1);
END $$;
