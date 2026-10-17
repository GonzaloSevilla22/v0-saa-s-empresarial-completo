-- =============================================================================
-- multiusuario-operativo — TANDA A (governance CRÍTICO)
-- Una sola cuenta activa por usuario, la misma en la base, en el token, en
-- FastAPI, en las Edge Functions y en el frontend.
--
-- PROBLEMA (auditoría de stock del 2026-10-14, humo S20, pasos R3j / R3l).
--   Todo invitado a una cuenta tiene además su cuenta personal (la crea
--   `handle_new_user`). `current_account_ids()` devolvía TODAS las membresías, y
--   45 funciones la consumían con `SELECT cai INTO v_account_id FROM
--   current_account_ids() AS cai LIMIT 1` SIN `ORDER BY`: el resultado dependía del
--   orden físico del plan. La venta de servicio de un invitado quedaba en su
--   cuenta personal (R3l), el POS buscaba el stock en la personal (R3j, P0409), y
--   `get_dashboard_financials` / `rpc_period_comparison` SUMABAN las dos cuentas.
--   Mientras tanto el hook, FastAPI, las Edge Functions y el frontend elegían OTRA
--   cuenta (la membresía más antigua): cuatro criterios de "cuenta activa".
--
-- QUÉ HACE (design.md D1-D5)
--   1. `profiles.active_account_id` — la preferencia del usuario (OQ-1 (a)). Es una
--      columna de PRIVILEGIO: no entra en la allow-list de UPDATE de `authenticated`
--      (sólo la escriben `rpc_set_active_account` —que valida la membresía— y la
--      aceptación de una invitación, tanda C).
--   2. `resolve_active_account(uuid)` — el resolver canónico: la preferencia si
--      sigue siendo una membresía; si no, la membresía más antigua por
--      (created_at, id). SECURITY DEFINER, EXECUTE sólo para `supabase_auth_admin`
--      (recibe un usuario por parámetro: misma lección que get_account_ids_for_user, h4).
--   3. `current_account_ids()` pasa a devolver la cuenta ACTIVA (0 o 1 fila):
--      primero el claim `app_metadata.account_id` del request, validado contra la
--      membresía viva (fail-closed: si el usuario ya no es miembro, CERO filas, nunca
--      cae en silencio a otra cuenta); si el claim falta, el resolver. Mismo nombre,
--      misma firma, `SETOF uuid`, DEFINER, STABLE: las 45 funciones del patrón A, las
--      98 policies de RLS y los agregados que mezclaban cuentas quedan resueltos SIN
--      reescribir un solo cuerpo. Para los 41 usuarios de hoy (una sola cuenta) el
--      resultado es IDÉNTICO.
--   4. `rpc_set_active_account(uuid)` y `rpc_my_accounts()` — el selector.
--   5. Los otros cinco criterios se alinean al resolver: `custom_access_token_hook`
--      (emite además `app_metadata.account_id`), `rpc_my_active_account_roles`,
--      `rpc_my_effective_plan`, `rpc_atomic_log_ai_insight` y el trigger
--      `set_insight_account_id`.
--
-- NO TOCA el cuerpo de ninguna RPC de operaciones (ventas, compras, gastos, stock):
-- los changes hermanos que las reescriben (#646, edicion-operaciones-con-dinero,
-- tanda B de este change) no se pisan con esta migración.
--
-- Cuerpos de partida (checkpoint 2.2, 2026-10-16, md5 de prosrc sin \r, prod ==
-- base local construida desde los archivos): ver el bloque 0 (preflight), que
-- ABORTA si alguno cambió. Los cuerpos previos completos están en
-- openspec/changes/multiusuario-operativo/evidence/tanda-a/cuerpos-previos/ (rollback).
--
-- Idempotente (CI la reaplica al final de la cadena): ADD COLUMN IF NOT EXISTS,
-- CREATE INDEX IF NOT EXISTS, CREATE OR REPLACE con firmas fijas (sin overload, sin
-- 42725), REVOKE/GRANT y COMMENT re-emitidos.
--
-- Gates: supabase/tests/test_multiusuario_cuenta_activa.sql (EJECUTA el resolver, el
-- claim, el hook, la RLS, los agregados, el POS, la venta de servicio, el gasto, el
-- import, los roles, el plan, los insights y el selector),
-- test_custom_access_token_hook_account_roles.sql (ajustado: ahora también el claim
-- account_id) y test_accounts_privilege_columns.sql (ampliado: la columna nueva).
--
-- Rollback: restaurar los seis cuerpos de evidence/tanda-a/cuerpos-previos/ y
--   ALTER TABLE public.profiles DROP COLUMN active_account_id;
--   DROP FUNCTION public.resolve_active_account(uuid), public.rpc_set_active_account(uuid),
--                 public.rpc_my_accounts();
-- (la preferencia es descartable: no hay datos de valor en la columna).
-- =============================================================================

-- =============================================================================
-- 0. Preflight: ningún cuerpo de partida cambió desde el checkpoint (2.2)
-- =============================================================================
-- Las seis funciones que esta migración reescribe se reescriben desde su cuerpo VIVO.
-- Si otro change las redefinió en el medio, un CREATE OR REPLACE ciego pisaría ese
-- trabajo en silencio: se ABORTA con el md5 observado para rebasar el cuerpo sobre el
-- vivo. Idempotente: con el cuerpo de esta migración ya instalado (reaplicación)
-- sigue de largo.
DO $$
DECLARE
  v_expected jsonb := jsonb_build_object(
    'current_account_ids',          'f76efc604854dfc4cabafb30dc582127',
    'custom_access_token_hook',     'e5c1bb4dc7a52d7ed65d8d746e901864',
    'rpc_my_active_account_roles',  'c55dfdbf99c0215fad7fd21a22de5b61',
    'rpc_my_effective_plan',        '597cca421d5427c7af59280b087f248c',
    'rpc_atomic_log_ai_insight',    '0a432ccb5e60790b19f2f432bd7eb0a9',
    'set_insight_account_id',       '81cd871b46c2659eca98fe838a57769a');
  v_rewritten jsonb := jsonb_build_object(
    'current_account_ids',          '96f9b640f4801505c5ddf863e3c7ca2d',
    'custom_access_token_hook',     'c0ea3d4f3090df6a87142748b0404db9',
    'rpc_my_active_account_roles',  'd495a85a61dff76af138250de309948d',
    'rpc_my_effective_plan',        'cc30d755a61171381fa6ce9825790248',
    'rpc_atomic_log_ai_insight',    '8403e641ceb642313871a2c79b4d0e5e',
    'set_insight_account_id',       '95469d38d98203cd2ba5d29c6992ca07');
  v_fn  text;
  v_md5 text;
  v_ok  integer := 0;
  v_re  integer := 0;
BEGIN
  FOR v_fn IN SELECT jsonb_object_keys(v_expected) LOOP
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_md5 = (v_expected ->> v_fn) THEN
      v_ok := v_ok + 1;
    ELSIF v_md5 = (v_rewritten ->> v_fn) THEN
      v_re := v_re + 1;
    ELSE
      RAISE EXCEPTION 'multiusuario-operativo tanda A (preflight): el cuerpo vivo de % mide % y no es ni el de partida (%) ni el de esta migración (%): otro change la redefinió — rebasá la reescritura sobre el cuerpo vivo antes de aplicar',
        v_fn, COALESCE(v_md5, '(no existe)'), v_expected ->> v_fn, v_rewritten ->> v_fn;
    END IF;
  END LOOP;
  RAISE NOTICE 'multiusuario-operativo tanda A (preflight): % cuerpos de partida verificados por md5, % ya reaplicados', v_ok, v_re;
END $$;

-- =============================================================================
-- 1. La preferencia: profiles.active_account_id (D2)
-- =============================================================================
-- NULL = "sin elección": rige la membresía más antigua. ON DELETE SET NULL: borrar una
-- cuenta no deja la preferencia colgada. NO se agrega a la allow-list de UPDATE de
-- `authenticated` (20261053000001): nace protegida por construcción.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS active_account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL;

-- El FK ON DELETE SET NULL escanea profiles por esta columna al borrar una cuenta.
CREATE INDEX IF NOT EXISTS idx_profiles_active_account_id
  ON public.profiles (active_account_id)
  WHERE active_account_id IS NOT NULL;

COMMENT ON COLUMN public.profiles.active_account_id IS
  $c$multiusuario-operativo (D2): la cuenta que el usuario eligió como ACTIVA. NULL = sin elección (rige la membresía más antigua). Columna de PRIVILEGIO: sólo la escriben rpc_set_active_account (valida la membresía) y la aceptación de una invitación; NUNCA PostgREST. Un valor que ya no es una membresía se ignora (resolve_active_account).$c$;

-- =============================================================================
-- 2. El resolver canónico (D3)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.resolve_active_account(p_user_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- 1) la preferencia del usuario, SOLO si sigue siendo una membresía suya;
  -- 2) si no hay preferencia o dejó de ser válida, la membresía más antigua
  --    (created_at) — el criterio que regía antes de este change. A igual instante
  --    (dentro de una transacción now() es constante: pasa en los gates, no en
  --    producción) gana la cuenta de la que el usuario es DUEÑO y, en último
  --    lugar, el id: así el desempate es reproducible y no depende de un uuid.
  SELECT COALESCE(
    (SELECT am.account_id
       FROM public.profiles p
       JOIN public.account_members am
         ON am.account_id = p.active_account_id AND am.user_id = p.id
      WHERE p.id = p_user_id),
    (SELECT am.account_id
       FROM public.account_members am
      WHERE am.user_id = p_user_id
      ORDER BY am.created_at, (am.role <> 'owner'), am.id
      LIMIT 1)
  );
$function$;

COMMENT ON FUNCTION public.resolve_active_account(uuid) IS
  $c$multiusuario-operativo (D3): resolver CANÓNICO de la cuenta activa de un usuario — la preferencia (profiles.active_account_id) si sigue siendo una membresía; si no, la membresía más antigua por created_at (a igual instante, la cuenta de la que es dueño; en último lugar el id). Lo usan current_account_ids(), el custom access token hook y el trigger set_insight_account_id; NINGÚN otro componente (backend, Edge Functions, frontend) implementa un criterio propio. Recibe un usuario por parámetro: por eso NO es ejecutable por anon ni authenticated (misma lección que get_account_ids_for_user, h4), sólo por supabase_auth_admin (el hook).$c$;

-- =============================================================================
-- 3. current_account_ids(): la cuenta ACTIVA, 0 o 1 fila (D1)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.current_account_ids()
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid   uuid := (SELECT auth.uid());
  v_claim text;
BEGIN
  -- Sin sesión: cero filas (igual que antes).
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  -- El claim del request: app_metadata.account_id del token (PostgREST lo ve en
  -- request.jwt.claims; FastAPI lo empuja desde get_db_conn). Vacío = ausente.
  v_claim := NULLIF(auth.jwt() -> 'app_metadata' ->> 'account_id', '');

  IF v_claim IS NOT NULL THEN
    -- Un claim que no es un uuid no describe ninguna cuenta: falla CERRADO.
    IF v_claim !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RETURN;
    END IF;
    -- El claim gana sobre la preferencia (el token es la unidad de consistencia de
    -- un request: los claims de rol y de plan que FastAPI usa describen ESA cuenta),
    -- pero SOLO si el usuario sigue siendo miembro. Si lo quitaron con el token
    -- todavía vigente: cero filas — nunca cae en silencio a la otra cuenta.
    -- (account_id, user_id) es UNIQUE: a lo sumo una fila.
    RETURN QUERY
      SELECT am.account_id
        FROM public.account_members am
       WHERE am.user_id = v_uid
         AND am.account_id = v_claim::uuid;
    RETURN;
  END IF;

  -- Sin claim (token emitido antes del deploy, que vive a lo sumo 15 min, o un
  -- contexto que empuja claims mínimos): el resolver canónico.
  RETURN QUERY
    SELECT r.account_id
      FROM (SELECT public.resolve_active_account(v_uid) AS account_id) r
     WHERE r.account_id IS NOT NULL;
END;
$function$;

COMMENT ON FUNCTION public.current_account_ids() IS
  $c$multiusuario-operativo (D1): la cuenta ACTIVA del caller (0 o 1 fila). Con el claim app_metadata.account_id del request: esa cuenta SOLO si auth.uid() sigue siendo miembro (si no, 0 filas, nunca otra cuenta); sin claim: resolve_active_account(auth.uid()) = la preferencia o la membresía más antigua. El nombre queda en plural por compatibilidad con las 45 RPCs y las ~98 policies de RLS que la consumen. Quien necesite TODAS las membresías del usuario tiene get_account_ids_for_user(auth.uid()) o account_members (policy self_select). Nunca llamarla desde policies de account_members (recursión).$c$;

-- =============================================================================
-- 4. El selector: rpc_set_active_account y rpc_my_accounts (D5)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_set_active_account(p_account_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- Una cuenta ajena es INDISTINGUIBLE de una inexistente (mismo código, mismo
  -- mensaje, sin el id): no se revela qué cuentas existen.
  IF p_account_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.account_members am
     WHERE am.user_id = v_uid AND am.account_id = p_account_id
  ) THEN
    RAISE EXCEPTION 'account_not_found' USING ERRCODE = 'P0404';
  END IF;

  UPDATE public.profiles SET active_account_id = p_account_id WHERE id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'account_not_found' USING ERRCODE = 'P0404';
  END IF;

  RETURN p_account_id;
END;
$function$;

COMMENT ON FUNCTION public.rpc_set_active_account(uuid) IS
  $c$multiusuario-operativo (D2/D5): elige la cuenta activa del caller. Valida la MEMBRESÍA (una cuenta ajena o inexistente da P0404 con el mismo mensaje) y persiste profiles.active_account_id. El frontend la llama por supabase-js y a continuación renueva el token (el hook emite el claim de la cuenta nueva). Sin sesión: P0401.$c$;

CREATE OR REPLACE FUNCTION public.rpc_my_accounts()
 RETURNS TABLE (
   account_id             uuid,
   is_active              boolean,
   is_owner               boolean,
   member_role            text,
   roles                  text[],
   brand_display_name     text,
   fiscal_nombre_fantasia text,
   fiscal_razon_social    text,
   brand_legal_name       text,
   owner_business_name    text,
   billing_plan           text,
   billing_status         text,
   trial_plan             text,
   trial_started_at       timestamptz,
   trial_expires_at       timestamptz,
   plan_expires_at        timestamptz,
   billing_exempt         boolean,
   effective_plan         text,
   created_at             timestamptz
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_uid uuid := (SELECT auth.uid());
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  SELECT a.id,
         (a.id IN (SELECT public.current_account_ids())),
         (a.owner_user_id = v_uid),
         am.role,
         public.member_active_roles(am.id),
         -- Campos CRUDOS del nombre: la cascada vive en previewIssuer
         -- (frontend/lib/document-branding.ts), atada a issuer.py por un fixture.
         -- NO se calcula un nombre visible en SQL (sería una tercera cascada).
         ab.display_name,
         fp.nombre_fantasia,
         fp.razon_social,
         ab.legal_name,
         pr.business_name,
         a.billing_plan,
         a.billing_status,
         a.trial_plan,
         a.trial_started_at,
         a.trial_expires_at,
         a.plan_expires_at,
         a.billing_exempt,
         public.get_effective_plan(a.id),
         am.created_at
    FROM public.account_members am
    JOIN public.accounts a             ON a.id = am.account_id
    LEFT JOIN public.account_branding ab ON ab.account_id = a.id
    LEFT JOIN public.fiscal_profiles fp  ON fp.account_id = a.id
    LEFT JOIN public.profiles pr         ON pr.id = a.owner_user_id
   WHERE am.user_id = v_uid
   ORDER BY am.created_at, am.id;
END;
$function$;

COMMENT ON FUNCTION public.rpc_my_accounts() IS
  $c$multiusuario-operativo (D5): una fila por MEMBRESÍA del caller, con la activa marcada (is_active = la que resuelve current_account_ids()), el rol propio en cada cuenta, el estado de billing y los campos CRUDOS del nombre (marca, perfil fiscal, dueño) para que el frontend calcule el nombre visible con previewIssuer — la cascada de los documentos, no una tercera. Alimenta el selector de cuenta y el auth-context. DEFINER porque accounts sólo muestra la fila activa por RLS. Sin sesión: P0401.$c$;

-- =============================================================================
-- 5. Los otros cinco criterios se alinean al resolver (D4)
-- =============================================================================

-- 5.1 custom_access_token_hook — emite además app_metadata.account_id.
-- Reescrito desde el cuerpo VIVO (md5 e5c1bb4d…). Se CONSERVA el blindaje de
-- degradación: ante cualquier error, claims intactos + RAISE WARNING (nunca rompe el
-- login). Es el hook ACTIVO en producción desde 2026-08-01.
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_claims        jsonb := COALESCE(event -> 'claims', '{}'::jsonb);
  v_user_id       uuid  := (event ->> 'user_id')::uuid;
  v_role          text;
  v_account_id    uuid;
  v_member_id     uuid;
  v_account_role  text;
  v_account_roles text[];
  v_plan          text;
  v_app_metadata  jsonb;
BEGIN
  -- Rol de PLATAFORMA (D1) — sin cambio semántico respecto de 20260800000004.
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = v_user_id;

  -- multiusuario-operativo (D3/D4): la cuenta activa la decide el resolver CANÓNICO
  -- (la preferencia del usuario si sigue siendo una membresía; si no, la membresía
  -- más antigua por (created_at, id)) — el MISMO que usa current_account_ids() sin
  -- claim. Antes este hook tenía su propio criterio (ordenar account_members y tomar la primera).
  v_account_id := public.resolve_active_account(v_user_id);

  -- Rol de TENANT (D1) del miembro en ESA cuenta. (account_id, user_id) es UNIQUE.
  IF v_account_id IS NOT NULL THEN
    SELECT id, role INTO v_member_id, v_account_role
    FROM public.account_members
    WHERE account_id = v_account_id
      AND user_id    = v_user_id;
  END IF;

  -- v3-rbac-multirole Parte B (D8): el CONJUNTO de roles ACTIVOS del mismo
  -- member_id ya resuelto arriba — vencidos excluidos por member_active_roles
  -- (D4 de la Parte A, reutilizado, nunca un segundo "rol activo"). NULL
  -- (no [] fabricado) si no se resolvió ningún member_id — distinto de "sin
  -- roles activos" (member_id resuelto, array vacío real).
  IF v_member_id IS NOT NULL THEN
    v_account_roles := public.member_active_roles(v_member_id);
  END IF;

  -- Plan EFECTIVO (D3) — delegado a la definición normativa única. Sin cuenta
  -- activa no hay plan que emitir (no se inventa un default acá).
  IF v_account_id IS NOT NULL THEN
    v_plan := public.get_effective_plan(v_account_id);
  END IF;

  -- Merge aditivo sobre app_metadata existente: preserva otras claves que
  -- Supabase ya haya puesto (p.ej. provider), y cada claim nuevo se agrega
  -- SOLO si se resolvió — un valor NULL no pisa nada.
  v_app_metadata := COALESCE(v_claims -> 'app_metadata', '{}'::jsonb);

  IF v_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('role', v_role);
  END IF;

  -- multiusuario-operativo (D4): el token DECLARA la cuenta a la que corresponden
  -- los claims de rol y de plan de abajo. FastAPI usa los claims de rol SOLO si el
  -- token trae este claim (un token viejo sin él se resuelve contra la base), y
  -- get_db_conn lo empuja a SQL para que current_account_ids() resuelva la misma.
  IF v_account_id IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_id', v_account_id);
  END IF;

  IF v_account_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_role', v_account_role);
  END IF;

  IF v_account_roles IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_roles', to_jsonb(v_account_roles));
  END IF;

  IF v_plan IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('plan', v_plan);
  END IF;

  -- Solo tocar `claims.app_metadata` si hay algo nuevo que aportar o si YA
  -- existía (para no fabricar una clave `app_metadata: {}` en un evento que
  -- nunca la tuvo — un usuario sin profile ni membresía debe devolver los
  -- claims EXACTAMENTE como llegaron, sin ninguna clave nueva).
  IF v_app_metadata <> '{}'::jsonb OR v_claims ? 'app_metadata' THEN
    v_claims := jsonb_set(v_claims, '{app_metadata}', v_app_metadata, true);
  END IF;

  RETURN jsonb_build_object('claims', v_claims);
EXCEPTION
  WHEN OTHERS THEN
    -- Nunca romper la emisión del token: ante cualquier error (incluido un
    -- permiso faltante sobre member_active_roles o resolve_active_account),
    -- claims intactos.
    -- Deja rastro (D5 de v31-authz-token-hook): un permiso faltante o un
    -- cambio de esquema queda en los logs de Postgres, no como claims
    -- ausentes sin explicación.
    RAISE WARNING 'custom_access_token_hook degradado (SQLSTATE=%): %', SQLSTATE, SQLERRM;
    RETURN jsonb_build_object('claims', COALESCE(event -> 'claims', '{}'::jsonb));
END;
$function$;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  $c$multiusuario-operativo (D4): emite account_id (la cuenta ACTIVA, resuelta por resolve_active_account) junto con account_role, account_roles (CONJUNTO de roles ACTIVOS, vencidos excluidos) y plan, TODOS de esa misma cuenta. v3-rbac-multirole Parte B (D8): emite account_roles DENTRO del bloque protegido EXCEPTION WHEN OTHERS heredado de v31-authz-token-hook -- account_role (singular, derivado por precedencia) se conserva IDÉNTICO. Ante cualquier error, claims intactos + RAISE WARNING (nunca rompe el login).$c$;

-- 5.2 rpc_my_active_account_roles — los roles del caller en la cuenta ACTIVA.
CREATE OR REPLACE FUNCTION public.rpc_my_active_account_roles()
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Ronda 1 adversarial (nit 7): COALESCE a ARRAY vacío -- sin esto, un
  -- caller sin ninguna membresía en la cuenta activa (cero filas) devuelve NULL,
  -- lo que contradecía el COMMENT ("array vacío, no NULL"). Mismo criterio que
  -- member_active_roles/account_user_active_roles de la Parte A -- las TRES
  -- funciones de la familia "roles activos" quedan con el mismo contrato:
  -- ARRAY vacío, nunca NULL.
  --
  -- multiusuario-operativo (D4): la membresía es la de la cuenta ACTIVA
  -- (current_account_ids(): 0 o 1 fila), no "la más antigua". (account_id, user_id)
  -- es UNIQUE: el subselect devuelve a lo sumo una fila.
  SELECT COALESCE(
    (SELECT public.member_active_roles(am.id)
     FROM   public.account_members am
     WHERE  am.user_id = (SELECT auth.uid())
       AND  am.account_id IN (SELECT public.current_account_ids())),
    ARRAY[]::text[]
  );
$function$;

COMMENT ON FUNCTION public.rpc_my_active_account_roles() IS
  $c$v3-rbac-multirole Parte B (D10, R6) + multiusuario-operativo (D4): roles ACTIVOS del CALLER en su cuenta ACTIVA (la que resuelve current_account_ids(): el claim del token o, sin él, la preferencia / la membresía más antigua) -- SIN parámetro, no hay ningún member_id que un tercero pueda pasar. DOS consumidores, los dos en require_account_role (backend/core/guards.py): (1) el fallback a DB cuando el token no declara la cuenta activa (sin app_metadata.account_id los claims de rol no valen) o no trae ni el conjunto ni el singular, y (2) desde auth-hardening-jwt-cookies D12, el camino PRIMARIO de toda capacidad sensible (rbac.py::SENSITIVE_CAPABILITIES, hoy CAN_CONFIGURE = owner/admin): ahí se la consulta AUNQUE el claim esté presente, porque para las acciones de configuración el claim es un caché y la base es la autoridad -- un rol revocado o vencido deja de autorizar sin esperar a la próxima emisión de token. Array vacío (no NULL) si el caller no es miembro de la cuenta activa -- COALESCE explícito (ronda 1 adversarial, nit 7), mismo contrato que member_active_roles/account_user_active_roles de la Parte A.$c$;

-- 5.3 rpc_my_effective_plan — el plan de la cuenta ACTIVA.
CREATE OR REPLACE FUNCTION public.rpc_my_effective_plan()
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  -- multiusuario-operativo (D4): la cuenta es la ACTIVA del caller —
  -- current_account_ids() devuelve 0 o 1 fila: el claim del request (validado
  -- contra la membresía) o, sin claim, la preferencia / la membresía más antigua.
  -- Antes este RPC elegía "la membresía más antigua entre las elegibles", un
  -- criterio propio que bajo multi-membresía divergía del token y de FastAPI.
  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai;

  -- Sin cuenta resoluble (usuario sin membresía, sin sesión válida, o un claim de
  -- una cuenta de la que ya no es miembro): fail-closed, nunca lanza.
  IF v_account_id IS NULL THEN
    RETURN 'gratis';
  END IF;

  RETURN public.get_effective_plan(v_account_id);
END;
$function$;

COMMENT ON FUNCTION public.rpc_my_effective_plan() IS
  $c$billing-edge-effective-plan (D1/D2, sign-off PO 2026-07-31) + multiusuario-operativo (D4): wrapper SIN argumentos sobre get_effective_plan(uuid) para que las Edge Functions (JWT de usuario, sin service_role) lean el plan efectivo sin exponer get_effective_plan a authenticated (permanece revocada — D2 de billing-pro-trial). La cuenta del llamador se deriva SIEMPRE de auth.uid() vía current_account_ids() -- la cuenta ACTIVA (claim del token, o preferencia / membresía más antigua): es imposible por construcción consultar el plan de una cuenta ajena. Sin cuenta resoluble: gratis (fail-closed, D5).$c$;

-- 5.4 rpc_atomic_log_ai_insight — el insight se sella en la cuenta ACTIVA.
CREATE OR REPLACE FUNCTION public.rpc_atomic_log_ai_insight(p_type text, p_content text, p_source_function text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_profile        RECORD;
  v_insight_id     uuid;
  v_account_id     uuid;
  v_insight_record jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock del perfil para evitar carreras en el contador
  SELECT id, plan, insights_used INTO v_profile
  FROM profiles WHERE id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Límite de plan free
  IF v_profile.plan = 'free' AND v_profile.insights_used >= 5 THEN
    RAISE EXCEPTION 'AI Insights limit reached for free plan' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cuenta ACTIVA del usuario (multiusuario-operativo, D4): la que resuelve
  -- current_account_ids() — antes "la primera membership por account_id", otro
  -- criterio propio. NULL tolerado (sin cuenta activa), lo cubre el trigger.
  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai;

  -- Insert en la tabla canónica unificada
  INSERT INTO insights (user_id, account_id, type, message, priority)
  VALUES (v_uid, v_account_id, p_type, p_content, 'media')
  RETURNING id INTO v_insight_id;

  -- Contador de uso
  UPDATE profiles SET insights_used = insights_used + 1 WHERE id = v_uid;

  -- Telemetría
  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'insight_generated',
    jsonb_build_object('type', p_type, 'source_function', p_source_function, 'insight_id', v_insight_id));

  -- Detección de UMV (primer insight + primera operación)
  IF EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'operation_created')
  AND NOT EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'umv_reached')
  THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'umv_reached',
      jsonb_build_object('type', 'insight_generated', 'insight_id', v_insight_id));
  END IF;

  SELECT to_jsonb(i) INTO v_insight_record FROM insights i WHERE id = v_insight_id;
  RETURN v_insight_record;
END;
$function$;

-- 5.5 set_insight_account_id (trigger) — sella la cuenta ACTIVA del dueño de la fila.
CREATE OR REPLACE FUNCTION public.set_insight_account_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.account_id IS NULL THEN
    -- multiusuario-operativo (D4): si quien inserta ES el dueño de la fila, la cuenta
    -- activa de SU request (claim del token o resolver). Si inserta otro actor (p. ej.
    -- una Edge Function con service role, sin sesión de usuario), el resolver canónico
    -- sobre el dueño de la fila. Antes: "la primera membresía por account_id".
    IF NEW.user_id IS NOT DISTINCT FROM auth.uid() THEN
      SELECT cai INTO NEW.account_id FROM public.current_account_ids() AS cai;
    ELSE
      NEW.account_id := public.resolve_active_account(NEW.user_id);
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- =============================================================================
-- 6. ACLs (CREATE OR REPLACE las conserva; se RE-EMITEN explícitas)
-- =============================================================================
-- DROP + CREATE resetea las ACLs; acá no hay DROP, pero la regla del proyecto es dejar
-- escrito el ACL esperado de cada función tocada para que un reapply no dependa del
-- estado previo.

-- resolver por usuario: NUNCA anon / authenticated.
REVOKE ALL ON FUNCTION public.resolve_active_account(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_active_account(uuid) TO supabase_auth_admin;

-- el selector: authenticated (supabase-js) y service_role, nunca anon.
REVOKE ALL ON FUNCTION public.rpc_set_active_account(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_active_account(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_my_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_accounts() TO authenticated, service_role;

-- las reescritas conservan el ACL que tenían en producción.
REVOKE ALL ON FUNCTION public.current_account_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_account_ids() TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin, service_role;

REVOKE ALL ON FUNCTION public.rpc_my_active_account_roles() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_active_account_roles() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_my_effective_plan() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_effective_plan() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpc_atomic_log_ai_insight(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_log_ai_insight(text, text, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.set_insight_account_id() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_insight_account_id() TO service_role;

-- =============================================================================
-- 7. Introspección: falla la migración si algo no quedó como se diseñó
-- =============================================================================
DO $$
DECLARE
  v_bad   text[] := '{}';
  v_fn    text;
  v_md5   text;
  v_n     integer;
  v_src   text;
  v_exp   jsonb := jsonb_build_object(
    'current_account_ids',          '96f9b640f4801505c5ddf863e3c7ca2d',
    'custom_access_token_hook',     'c0ea3d4f3090df6a87142748b0404db9',
    'rpc_my_active_account_roles',  'd495a85a61dff76af138250de309948d',
    'rpc_my_effective_plan',        'cc30d755a61171381fa6ce9825790248',
    'rpc_atomic_log_ai_insight',    '8403e641ceb642313871a2c79b4d0e5e',
    'set_insight_account_id',       '95469d38d98203cd2ba5d29c6992ca07');
BEGIN
  -- Columna, FK ON DELETE SET NULL, índice parcial.
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'profiles'
                   AND column_name = 'active_account_id' AND data_type = 'uuid') THEN
    v_bad := v_bad || 'falta profiles.active_account_id uuid'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                 WHERE c.conrelid = 'public.profiles'::regclass AND c.contype = 'f'
                   AND c.confrelid = 'public.accounts'::regclass AND c.confdeltype = 'n'
                   AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                          WHERE attrelid = 'public.profiles'::regclass AND attname = 'active_account_id')]) THEN
    v_bad := v_bad || 'profiles.active_account_id sin FK a accounts ON DELETE SET NULL'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_profiles_active_account_id') THEN
    v_bad := v_bad || 'falta idx_profiles_active_account_id'::text;
  END IF;

  -- La columna es de PRIVILEGIO: authenticated / anon NO la escriben.
  IF has_column_privilege('authenticated', 'public.profiles', 'active_account_id', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.profiles', 'active_account_id', 'INSERT')
     OR has_column_privilege('anon', 'public.profiles', 'active_account_id', 'UPDATE')
     OR has_column_privilege('anon', 'public.profiles', 'active_account_id', 'INSERT') THEN
    v_bad := v_bad || 'profiles.active_account_id es escribible por authenticated/anon (debe ser columna de privilegio)'::text;
  END IF;

  -- Una definición viva por función (nada de overload fantasma, 42725).
  FOREACH v_fn IN ARRAY ARRAY['current_account_ids', 'custom_access_token_hook', 'rpc_my_active_account_roles',
                              'rpc_my_effective_plan', 'rpc_atomic_log_ai_insight', 'set_insight_account_id',
                              'resolve_active_account', 'rpc_set_active_account', 'rpc_my_accounts'] LOOP
    SELECT count(*) INTO v_n FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_n <> 1 THEN
      v_bad := v_bad || format('%s: %s definiciones vivas (esperaba 1)', v_fn, v_n);
    END IF;
  END LOOP;

  -- Cuerpos: md5 de prosrc (sin \r) = el de esta migración.
  FOR v_fn IN SELECT jsonb_object_keys(v_exp) LOOP
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;
    IF v_md5 IS DISTINCT FROM (v_exp ->> v_fn) THEN
      v_bad := v_bad || format('el cuerpo vivo de %s mide %s y el de esta migración es %s (¿una reaplicación posterior lo pisó?)', v_fn, v_md5, v_exp ->> v_fn);
    END IF;
  END LOOP;

  -- Semántica clave de cada cuerpo (con md5 igual debería sobrar; protege contra un cambio de la lista).
  SELECT p.prosrc INTO v_src FROM pg_proc p WHERE p.oid = 'public.custom_access_token_hook(jsonb)'::regprocedure;
  IF v_src NOT LIKE '%resolve_active_account(v_user_id)%' OR v_src NOT LIKE '%''account_id'', v_account_id%'
     OR v_src NOT LIKE '%custom_access_token_hook degradado (SQLSTATE=%' OR v_src LIKE '%ORDER BY created_at, id%' THEN
    v_bad := v_bad || 'custom_access_token_hook: debe resolver con resolve_active_account, emitir account_id y conservar la rama de degradación (sin ORDER BY propio)'::text;
  END IF;
  SELECT p.prosrc INTO v_src FROM pg_proc p WHERE p.oid = 'public.current_account_ids()'::regprocedure;
  IF v_src NOT LIKE '%app_metadata%' OR v_src NOT LIKE '%resolve_active_account(v_uid)%' THEN
    v_bad := v_bad || 'current_account_ids: debe leer el claim app_metadata.account_id y caer a resolve_active_account'::text;
  END IF;

  -- ACLs.
  IF has_function_privilege('anon', 'public.resolve_active_account(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.resolve_active_account(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('supabase_auth_admin', 'public.resolve_active_account(uuid)', 'EXECUTE') THEN
    v_bad := v_bad || 'ACL de resolve_active_account: sólo supabase_auth_admin (nunca anon/authenticated)'::text;
  END IF;
  IF has_function_privilege('anon', 'public.rpc_set_active_account(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_set_active_account(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpc_my_accounts()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpc_my_accounts()', 'EXECUTE') THEN
    v_bad := v_bad || 'ACL de rpc_set_active_account / rpc_my_accounts: authenticated sí, anon no'::text;
  END IF;
  IF NOT has_function_privilege('supabase_auth_admin', 'public.custom_access_token_hook(jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.custom_access_token_hook(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.custom_access_token_hook(jsonb)', 'EXECUTE') THEN
    v_bad := v_bad || 'ACL del hook: supabase_auth_admin conserva EXECUTE; anon/authenticated no'::text;
  END IF;
  IF has_function_privilege('anon', 'public.set_insight_account_id()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.set_insight_account_id()', 'EXECUTE') THEN
    v_bad := v_bad || 'ACL de set_insight_account_id: ni anon ni authenticated'::text;
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.current_account_ids()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.current_account_ids()', 'EXECUTE') THEN
    v_bad := v_bad || 'ACL de current_account_ids: debe conservar EXECUTE para anon y authenticated (las policies la evalúan)'::text;
  END IF;

  -- current_account_ids: SETOF uuid, DEFINER, STABLE, COMMENT.
  IF NOT EXISTS (SELECT 1 FROM pg_proc p
                 WHERE p.oid = 'public.current_account_ids()'::regprocedure
                   AND p.prosecdef AND p.provolatile = 's' AND p.proretset
                   AND pg_get_function_result(p.oid) = 'SETOF uuid') THEN
    v_bad := v_bad || 'current_account_ids debe seguir siendo SETOF uuid, SECURITY DEFINER y STABLE'::text;
  END IF;
  FOREACH v_fn IN ARRAY ARRAY['public.current_account_ids()', 'public.resolve_active_account(uuid)', 'public.rpc_set_active_account(uuid)',
                              'public.rpc_my_accounts()', 'public.custom_access_token_hook(jsonb)',
                              'public.rpc_my_active_account_roles()', 'public.rpc_my_effective_plan()'] LOOP
    IF obj_description(v_fn::regprocedure, 'pg_proc') IS NULL THEN
      v_bad := v_bad || format('%s sin COMMENT', v_fn);
    END IF;
  END LOOP;

  IF array_length(v_bad, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'multiusuario-operativo tanda A (introspección FALLÓ): %', array_to_string(v_bad, '; ');
  END IF;
  RAISE NOTICE 'multiusuario-operativo tanda A (introspección OK): columna profiles.active_account_id (privilegio, FK SET NULL, índice), resolver canónico sin EXECUTE para anon/authenticated, current_account_ids (SETOF uuid, claim validado + resolver), selector (rpc_set_active_account / rpc_my_accounts), hook con account_id y degradación conservada, y los cinco criterios alineados al resolver — una definición por función, ACLs y COMMENT.';
END $$;
