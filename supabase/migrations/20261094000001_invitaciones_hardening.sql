-- =============================================================================
-- invitaciones-hardening (governance CRÍTICO — auth / membresías)
-- Cuatro hallazgos de seguridad de la invitación a una cuenta, que
-- `multiusuario-operativo` dejó abiertos:
--
--   1. El token se guardaba EN CLARO (account_invitations.token y
--      email_logs.metadata.token).
--   2. El dueño podía escribir invitaciones por PostgREST saltando la RPC (policy
--      `account_invitations_owner_all` FOR ALL + privilegios de tabla de
--      authenticated: SELECT/INSERT/UPDATE/DELETE/TRUNCATE; anon: SELECT).
--   3. La lista de invitaciones no mostraba una entrega fallida.
--   4. Un envío fallido contaba para el enfriamiento de 10 minutos (el «Reenviar»
--      respondía 429 justo cuando más se lo necesita).
--   (El token en el path de la API se resuelve en backend/frontend, no acá.)
--
-- QUÉ HACE (design.md D1-D4, D7-D9)
--   · `account_invitations.token` -> `token_hash` (sha256 hex, índice único parcial).
--     Backfill: se hashea en el lugar lo que haya; nada se invalida. `DROP COLUMN token`.
--     Helper interno `_invitation_token_hash(text)` sin EXECUTE para roles de aplicación.
--   · El token nace en CADA envío (`rpc_send_invitation_email`, el primero incluido), se
--     devuelve una sola vez y viaja a la plantilla en email_logs.metadata.token; el
--     disparador `trg_email_logs_strip_invite_token` lo RETIRA apenas la fila deja de estar
--     `pending`. `rpc_invite_member` deja de devolver `token`.
--   · Vista previa y aceptación buscan por hash (mismo P0404, mismo FOR UPDATE, misma
--     ligadura a la identidad).
--   · `rpc_list_account_invitations` suma last_delivery_status / last_delivery_at (cambia el
--     tipo de retorno: DROP FUNCTION + CREATE, nunca CREATE OR REPLACE).
--   · El enfriamiento ignora los envíos `failed`; el tope diario los sigue contando.
--   · account_invitations queda SÓLO para las funciones del dominio: sin policy y sin
--     privilegios de tabla para anon/authenticated.
--
-- Cuerpos de partida (md5 de prosrc sin \r, prod == base local, 2026-11-06): ver el bloque 0,
-- que ABORTA si alguno cambió. Los completos están en
-- openspec/changes/invitaciones-hardening/evidence/cuerpos-previos/ (rollback).
--
-- Idempotente (CI la reaplica al final de la cadena): ADD COLUMN/CREATE INDEX IF NOT EXISTS,
-- backfill y DROP COLUMN guardados por existencia, CREATE OR REPLACE con firma fija,
-- DROP FUNCTION IF EXISTS + CREATE del listado, DROP TRIGGER IF EXISTS, REVOKE/GRANT/COMMENT
-- re-emitidos.
--
-- Gate: supabase/tests/test_invitaciones_hardening.sql.
--
-- Rollback: restaurar los cuerpos de evidence/cuerpos-previos/, la policy original
--   (account_invitations_owner_all FOR ALL TO authenticated USING/WITH CHECK dueño de la cuenta),
--   los privilegios previos, `ADD COLUMN token text` (vuelve vacía: los tokens en claro no se
--   reconstruyen; las invitaciones pendientes al momento del rollback se reenvían), y
--   DROP TRIGGER trg_email_logs_strip_invite_token + DROP FUNCTION _email_logs_strip_invite_token.
-- =============================================================================

-- =============================================================================
-- 0. Preflight: ningún cuerpo de partida cambió desde el checkpoint
-- =============================================================================
DO $$
DECLARE
  v_md5 text;
  v_ok  integer := 0;
  v_re  integer := 0;
  r     record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.rpc_invite_member(text,uuid,text[])',          'ff9d4a38e7dad25455d13249195263ec', 'dc843ced0ae286dd8a2c01232e767636'),
      ('public.rpc_send_invitation_email(uuid,text,boolean)', '69fcdf85dbb2706ab0f212c808bf83e3', '24aa689205a31a8c1dcef5f6c9d7a1c5'),
      ('public.rpc_invitation_preview(text)',                 '59b966c0ac826c036e132c9efba5cfd2', 'b3686d1fc76a651143dc2aca78d90287'),
      ('public.rpc_accept_invitation(text)',                  '92abe7e8e0c66314ff6d47230a8a913c', 'a484e092fadaca365f9a68ef026e766c'),
      ('public.rpc_list_account_invitations(uuid)',           '4b5e932632bb9f28afc31b560f8cb715', '8d96bc9f8cfd070b5bd2158117f22060')
    ) AS t(sig, old_md5, new_md5)
  LOOP
    SELECT md5(replace(p.prosrc, E'\r', '')) INTO v_md5
    FROM pg_proc p WHERE p.oid = to_regprocedure(r.sig);
    IF v_md5 = r.old_md5 THEN v_ok := v_ok + 1;
    ELSIF v_md5 = r.new_md5 THEN v_re := v_re + 1;
    ELSE
      RAISE EXCEPTION 'invitaciones-hardening (preflight): el cuerpo vivo de % mide % y no es ni el de partida (%) ni el de esta migración: otro change lo redefinió — rebasá la reescritura sobre el cuerpo vivo antes de aplicar', r.sig, COALESCE(v_md5, '(no existe)'), r.old_md5;
    END IF;
  END LOOP;
  RAISE NOTICE 'invitaciones-hardening (preflight): % cuerpos de partida verificados por md5, % ya reaplicados', v_ok, v_re;
END $$;

-- =============================================================================
-- 1. Helper interno: sha256 hex del token
-- =============================================================================
-- Sin sal ni KDF: el token son 32 bytes de gen_random_bytes (256 bits); un hash determinístico
-- es lo que permite buscar por índice. Built-in de PG >= 11 (no depende de pgcrypto).
CREATE OR REPLACE FUNCTION public._invitation_token_hash(p_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
$$;

REVOKE ALL ON FUNCTION public._invitation_token_hash(text) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._invitation_token_hash(text) IS
  'invitaciones-hardening (D1): sha256 hex del token de invitación. Interno: sin EXECUTE para anon/authenticated (lo usan las funciones SECURITY DEFINER de invitación). Sin sal: el token son 256 bits aleatorios y el hash determinístico permite buscar por índice.';

-- =============================================================================
-- 2. account_invitations: token_hash reemplaza a token
-- =============================================================================
ALTER TABLE public.account_invitations
  ADD COLUMN IF NOT EXISTS token_hash text;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'account_invitations' AND column_name = 'token') THEN
    EXECUTE 'UPDATE public.account_invitations SET token_hash = public._invitation_token_hash(token) WHERE token IS NOT NULL AND token_hash IS NULL';
    EXECUTE 'ALTER TABLE public.account_invitations DROP COLUMN token';
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS account_invitations_token_hash_key
  ON public.account_invitations (token_hash) WHERE token_hash IS NOT NULL;

COMMENT ON COLUMN public.account_invitations.token_hash IS
  'invitaciones-hardening (D1): sha256 hex del token del ÚLTIMO envío. NULL = invitación creada y todavía sin enviar (no se puede aceptar). El token en claro nunca se guarda.';

-- =============================================================================
-- 3. rpc_invite_member(text, uuid, text[]): ya no genera ni devuelve el token
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_invite_member(p_email text, p_account_id uuid, p_roles text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id   uuid;
  v_caller_role text;
  v_plan        text;
  v_max_users   int;
  v_cur_users   int;
  v_inv_id      uuid;
  v_email       text;
  v_roles       text[];
  v_role_legacy text;
BEGIN
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- Caller must be owner or admin
  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'P401: caller is not owner or admin of account %', p_account_id
      USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo tanda C (D10): el destinatario del email de invitación es el de
  -- ESTA fila, así que se valida acá, en el punto de entrada: una dirección mal formada, con
  -- saltos de línea (inyección de encabezados) o el literal `all_users` (fan-out de
  -- send-email) nunca llega a la tabla.
  v_email := lower(btrim(p_email));
  IF v_email IS NULL
     OR char_length(v_email) > 254
     OR v_email !~ '^[^[:space:][:cntrl:]@]+@[^[:space:][:cntrl:]@]+\.[^[:space:][:cntrl:]@]+$' THEN
    RAISE EXCEPTION 'invalid_email: la dirección de email de la invitación no es válida'
      USING ERRCODE = 'P0400';
  END IF;

  -- account-membership-roles: normaliza el conjunto (NULL o vacío -> {viewer}) y deduplica.
  IF p_roles IS NULL OR cardinality(p_roles) = 0 THEN
    v_roles := ARRAY['viewer'];
  ELSE
    SELECT ARRAY(SELECT DISTINCT unnest(p_roles)) INTO v_roles;
  END IF;

  -- Catálogo: cada rol del conjunto debe existir.
  IF EXISTS (
    SELECT 1 FROM unnest(v_roles) r(code)
    WHERE NOT EXISTS (SELECT 1 FROM public.account_role_catalog WHERE code = r.code)
  ) THEN
    RAISE EXCEPTION 'Rol inválido en el conjunto de la invitación'
      USING ERRCODE = 'P0400';
  END IF;

  -- Admin can only invite with operational roles -- NUNCA owner/admin en el conjunto.
  IF v_caller_role = 'admin' AND (v_roles && ARRAY['owner', 'admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el owner puede invitar admins'
      USING ERRCODE = 'P0403';
  END IF;

  -- v3-rbac-multirole Parte C (D17): sin gate de plan por rol.

  -- plan EFECTIVO, no billing_plan crudo.
  v_plan := public.get_effective_plan(p_account_id);
  SELECT pl.max_users INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  -- D18: cuenta MIEMBROS, no asignaciones.
  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = p_account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  -- Duplicate pending invitation check
  IF EXISTS (
    SELECT 1 FROM public.account_invitations
    WHERE  account_id = p_account_id
      AND  email      = v_email
      AND  status     = 'pending'
      AND  expires_at > now()
  ) THEN
    RAISE EXCEPTION 'P409: pending invitation already exists for %', v_email
      USING ERRCODE = 'P0407';
  END IF;

  v_inv_id := gen_random_uuid();

  -- Representante legacy por precedencia (D3: owner > admin > else 'member').
  v_role_legacy := CASE
    WHEN 'owner' = ANY(v_roles) THEN 'owner'
    WHEN 'admin' = ANY(v_roles) THEN 'admin'
    ELSE 'member'
  END;

  -- invitaciones-hardening (D2): la invitación nace SIN token (token_hash NULL): el token lo
  -- genera rpc_send_invitation_email en cada envío y sólo guarda su hash. Una invitación sin
  -- enviar no se puede aceptar; creación y envío van en la misma transacción del request.
  INSERT INTO public.account_invitations
    (id, account_id, email, token_hash, role, roles, status, invited_by, created_at, expires_at)
  VALUES
    (v_inv_id, p_account_id, v_email, NULL,
     v_role_legacy, v_roles, 'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'email',      v_email,
    'roles',      to_jsonb(v_roles),
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_invite_member(text, uuid, text[]) IS
  'multiusuario-operativo tanda C (D10, D14) + invitaciones-hardening (D2): único overload vivo. Crea la invitación con un CONJUNTO de roles del catálogo (sin roles -> {viewer}, sin gate de plan) SIN token (token_hash NULL) y NO lo devuelve: el token lo genera rpc_send_invitation_email en cada envío (sólo se guarda su hash). NO envía el email. "Not authenticated" = P0401; el email se valida (P0400 invalid_email). Cupo contra el plan EFECTIVO y ERRCODEs P04xx: P0403 autoridad, P0400 catálogo, P0402 cupo, P0407 duplicada. Candados: supabase/tests/test_multiusuario_invitaciones.sql y test_invitaciones_hardening.sql.';

-- =============================================================================
-- 4. rpc_send_invitation_email: token nuevo en CADA envío, sólo su hash a la fila
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_send_invitation_email(p_invitation_id uuid, p_account_display_name text, p_renew boolean DEFAULT false)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- Topes anti-abuso (OQ-8 a): la invitación es el único email que la app manda a una
  -- dirección que elige un usuario.
  c_cooldown    constant interval := interval '10 minutes';   -- 1 envío por invitación
  c_daily_cap   constant integer  := 20;                      -- envíos por cuenta, ventana de 24 h
  c_validity    constant interval := interval '7 days';
  c_fallback    constant text     := 'un negocio';

  v_uid      uuid := (SELECT auth.uid());
  v_inv      record;
  v_name     text;
  v_inviter  text;
  v_roles    text[];
  v_labels   text[];
  v_token    text;
  v_expires  timestamptz;
  v_n        integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- La invitación tiene que ser de la cuenta ACTIVA del caller: una de otra cuenta es
  -- indistinguible de una inexistente. Se toma con FOR UPDATE: dos envíos simultáneos de la
  -- MISMA invitación se serializan y el enfriamiento de abajo es confiable.
  SELECT ai.* INTO v_inv
  FROM   public.account_invitations ai
  WHERE  ai.id = p_invitation_id
    AND  ai.account_id IN (SELECT cai FROM public.current_account_ids() AS cai)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'P404: invitation not found' USING ERRCODE = 'P0404';
  END IF;

  -- Autoridad ANTES de cualquier otra cosa o escritura: dueño o administrador de ESA cuenta.
  PERFORM public._account_assert_capability(
    v_inv.account_id, ARRAY['owner', 'admin'],
    'solo el dueño o un administrador puede enviar invitaciones');

  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'invitation_not_pending: la invitación ya fue aceptada o revocada'
      USING ERRCODE = 'P0409';
  END IF;
  IF NOT p_renew AND v_inv.expires_at <= now() THEN
    RAISE EXCEPTION 'invitation_not_pending: la invitación venció; reenviala para renovarla'
      USING ERRCODE = 'P0409';
  END IF;

  -- Defensa en profundidad: el destinatario sale de la fila.
  IF v_inv.email IS NULL
     OR char_length(v_inv.email) > 254
     OR v_inv.email !~ '^[^[:space:][:cntrl:]@]+@[^[:space:][:cntrl:]@]+\.[^[:space:][:cntrl:]@]+$' THEN
    RAISE EXCEPTION 'invalid_email: la dirección de email de la invitación no es válida'
      USING ERRCODE = 'P0400';
  END IF;

  -- Topes. El tope diario cuenta por cuenta: el candado de aviso serializa los envíos
  -- simultáneos de la cuenta.
  PERFORM pg_advisory_xact_lock(hashtextextended('org_invite_cap:' || v_inv.account_id::text, 0));

  -- invitaciones-hardening (D8): un envío cuyo email no se pudo enviar (`failed`) NO cuenta para el
  -- enfriamiento (si no, el «Reenviar» destacado respondería 429 justo cuando más se lo necesita);
  -- el tope diario de abajo SÍ lo cuenta (cada intento le cuesta al proveedor).
  IF EXISTS (
    SELECT 1 FROM public.email_logs el
    WHERE  el.event_type = 'org_invite'
      AND  el.metadata ->> 'account_id'    = v_inv.account_id::text
      AND  el.metadata ->> 'invitation_id' = v_inv.id::text
      AND  el.status <> 'failed'
      AND  el.created_at > now() - c_cooldown
  ) THEN
    RAISE EXCEPTION 'invitation_cooldown: esperá unos minutos antes de reenviar esta invitación'
      USING ERRCODE = 'P0439';
  END IF;

  SELECT count(*) INTO v_n
  FROM   public.email_logs el
  WHERE  el.event_type = 'org_invite'
    AND  el.metadata ->> 'account_id' = v_inv.account_id::text
    AND  el.created_at > now() - interval '1 day';
  IF v_n >= c_daily_cap THEN
    RAISE EXCEPTION 'invitation_daily_cap: la cuenta alcanzó el máximo de invitaciones enviadas por día'
      USING ERRCODE = 'P0439';
  END IF;

  -- invitaciones-hardening (D2): el token nace en CADA envío (el primero incluido); de la
  -- fila sólo se guarda su hash. Cada envío invalida los enlaces anteriores. `p_renew` conserva
  -- su sentido: renovar el vencimiento a 7 días y revivir una vencida; el primer envío
  -- conserva el vencimiento de la creación.
  v_token   := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires := v_inv.expires_at;
  IF p_renew THEN
    v_expires := now() + c_validity;
  END IF;

  -- Nombre del negocio: lo único que viene del caller. Sin caracteres de control ni saltos de
  -- línea (va al asunto), recortado a 120; si viene vacío se conserva el snapshot anterior.
  v_name := btrim(left(btrim(regexp_replace(COALESCE(p_account_display_name, ''), '[[:space:][:cntrl:]]+', ' ', 'g')), 120));
  v_name := COALESCE(NULLIF(v_name, ''), NULLIF(v_inv.account_display_name, ''), c_fallback);

  -- Quien invita: el nombre de su perfil (no su email).
  SELECT NULLIF(btrim(left(btrim(regexp_replace(concat_ws(' ', pr.name, pr.last_name), '[[:space:][:cntrl:]]+', ' ', 'g')), 120)), '')
  INTO   v_inviter
  FROM   public.profiles pr WHERE pr.id = v_uid;
  v_inviter := COALESCE(v_inviter, 'Un administrador del negocio');

  v_roles := COALESCE(
    v_inv.roles,
    ARRAY[CASE COALESCE(v_inv.role, 'member') WHEN 'member' THEN 'viewer' ELSE v_inv.role END]
  );
  SELECT COALESCE(array_agg(c.label ORDER BY c.sort_order), ARRAY[]::text[]) INTO v_labels
  FROM   public.account_role_catalog c WHERE c.code = ANY (v_roles);

  UPDATE public.account_invitations
  SET    token_hash = public._invitation_token_hash(v_token), expires_at = v_expires, account_display_name = v_name
  WHERE  id = v_inv.id;

  -- invitaciones-hardening (D3): los envíos anteriores de ESTA invitación que sigan `pending` ya
  -- tienen el token rotado: se les retira del registro (no se escribe `status`, así que el
  -- disparador de retiro no interviene).
  UPDATE public.email_logs el
  SET    metadata = el.metadata - 'token'
  WHERE  el.event_type = 'org_invite'
    AND  el.status = 'pending'
    AND  el.metadata ->> 'invitation_id' = v_inv.id::text
    AND  el.metadata ? 'token';

  -- EL EMAIL, encolado en la MISMA transacción. El destinatario (`v_inv.email`) sale de la FILA
  -- de la invitación y el token lo generó esta función: ninguno es un parámetro. El link NO se
  -- guarda acá: lo arma send-email con la URL fija de la app (APP_URL) y este token, que el
  -- disparador trg_email_logs_strip_invite_token retira del registro apenas termina el intento.
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    v_uid,
    'org_invite',
    v_inv.email,
    'Invitación para sumarte a ' || v_name || ' en ALIADATA',
    jsonb_build_object(
      'invitation_id', v_inv.id,
      'account_id',    v_inv.account_id,
      'token',         v_token,
      'account_name',  v_name,
      'inviter_name',  v_inviter,
      'roles',         to_jsonb(v_roles),
      'role_labels',   to_jsonb(v_labels),
      'expires_at',    v_expires,
      -- distingue dos envíos de la misma invitación (UNIQUE user/evento/metadata)
      'sent_at',       clock_timestamp()
    )
  );

  RETURN json_build_object(
    'id',         v_inv.id,
    'email',      v_inv.email,
    'roles',      to_jsonb(v_roles),
    'expires_at', v_expires,
    'token',      v_token,
    'queued',     true
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_send_invitation_email(uuid, text, boolean) IS
  'multiusuario-operativo tanda C (D10, D13) + invitaciones-hardening (D2, D3, D8): encola el email org_invite de una invitación DENTRO de la transacción del request. El destinatario sale de la FILA y el token lo genera la función EN CADA ENVÍO (el primero incluido): la fila guarda sólo su hash (token_hash), el token se devuelve una sola vez (Copiar link) y viaja a la plantilla en email_logs.metadata.token, que el disparador trg_email_logs_strip_invite_token retira al salir de pending. Cada envío invalida los enlaces anteriores. Lo único del caller es el nombre del negocio (recortado a 120). Autoridad: dueño o administrador (helper _account_assert_capability, ANTES de escribir): observador P0401, otro rol P0403, otra cuenta o inexistente P0404. p_renew renueva el vencimiento a 7 días y revive una vencida; aceptada o revocada = P0409. Topes: 1 envío por invitación cada 10 minutos (los envíos failed NO cuentan, P0439 invitation_cooldown) y 20 por cuenta en 24 horas (los failed SÍ cuentan, P0439 invitation_daily_cap). Candados: test_multiusuario_invitaciones.sql y test_invitaciones_hardening.sql.';

-- =============================================================================
-- 5. Vista previa y aceptación: buscan por hash
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_invitation_preview(p_token text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid := (SELECT auth.uid());
  v_caller_email text;
  v_inv          record;
  v_roles        text[];
  v_labels       text[];
  v_inviter      text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- Misma resolución de identidad que rpc_accept_invitation: contra auth.users cuando el claim
  -- no trae el email (el backend propio empuja sólo sub/role/app_metadata.account_id).
  v_caller_email := COALESCE(
    auth.jwt()->>'email',
    (SELECT u.email FROM auth.users u WHERE u.id = v_uid)
  );

  -- invitaciones-hardening (D1): se busca por el hash del token; el token en claro no existe en la tabla.
  SELECT ai.* INTO v_inv
  FROM   public.account_invitations ai
  WHERE  ai.token_hash = public._invitation_token_hash(p_token)
    AND  ai.status = 'pending' AND ai.expires_at > now()
  LIMIT 1;

  -- Token inexistente, vencido, revocado, rotado, usado, o de OTRA identidad: UN solo error,
  -- con el MISMO código y texto que rpc_accept_invitation. Fail-closed por los dos lados.
  IF NOT FOUND
     OR v_caller_email IS NULL
     OR v_inv.email IS NULL
     OR lower(v_inv.email) <> lower(v_caller_email) THEN
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  v_roles := COALESCE(
    v_inv.roles,
    ARRAY[CASE COALESCE(v_inv.role, 'member') WHEN 'member' THEN 'viewer' ELSE v_inv.role END]
  );
  SELECT COALESCE(array_agg(c.label ORDER BY c.sort_order), ARRAY[]::text[]) INTO v_labels
  FROM   public.account_role_catalog c WHERE c.code = ANY (v_roles);

  SELECT NULLIF(btrim(concat_ws(' ', pr.name, pr.last_name)), '') INTO v_inviter
  FROM   public.profiles pr WHERE pr.id = v_inv.invited_by;

  RETURN json_build_object(
    'account_id',           v_inv.account_id,
    'account_display_name', COALESCE(NULLIF(v_inv.account_display_name, ''), 'un negocio'),
    'inviter_name',         COALESCE(v_inviter, 'Un administrador del negocio'),
    'roles',                to_jsonb(v_roles),
    'role_labels',          to_jsonb(v_labels),
    'expires_at',           v_inv.expires_at,
    'already_member',       EXISTS (
      SELECT 1 FROM public.account_members am
      WHERE  am.account_id = v_inv.account_id AND am.user_id = v_uid
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_invitation_preview(text) IS
  'multiusuario-operativo tanda C (D12, OQ-5) + invitaciones-hardening (D1): la vista previa de una invitación para el invitado que ya tiene sesión, buscando por el HASH del token (la tabla no guarda el token). Devuelve el negocio (snapshot), quién invita, los roles, el vencimiento, la cuenta y already_member SOLO si la identidad autenticada corresponde al email de la invitación (lower() en ambos lados). Con otra identidad, un token vencido, revocado, rotado, usado o inexistente responde LO MISMO: P0404 "P404: invalid or expired invitation token". No consume la invitación y no devuelve el token ni el email.';

CREATE OR REPLACE FUNCTION public.rpc_accept_invitation(p_token text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id    uuid;
  v_caller_email text;
  v_inv          record;
  v_plan         text;
  v_max_users    int;
  v_cur_users    int;
  v_member_id    uuid;
  v_roles        text[];
  v_role         text;
  v_role_legacy  text;
BEGIN
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- auth-hardening-jwt-cookies (D14, F13): identidad del aceptante para el binding de email,
  -- contra auth.users y NO sólo contra el claim (el backend propio empuja sólo sub/role).
  v_caller_email := COALESCE(
    auth.jwt()->>'email',
    (SELECT u.email FROM auth.users u WHERE u.id = v_caller_id)
  );

  -- FOR UPDATE: lock de la fila ANTES de validar estado y vigencia (dos aceptaciones
  -- concurrentes del mismo token no pueden ganar ambas). Una invitación `revoked` o rotada por
  -- un reenvío tampoco matchea (status <> pending / hash distinto) -> mismo error genérico.
  -- invitaciones-hardening (D1): se busca por el hash del token.
  SELECT *
  INTO   v_inv
  FROM   public.account_invitations
  WHERE  token_hash = public._invitation_token_hash(p_token)
    AND  status    = 'pending'
    AND  expires_at > now()
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  -- La invitación es de quien la recibió. Comparación insensible a mayúsculas; MISMO ERRCODE y
  -- MISMO texto que el rechazo por token inexistente/vencido. Fail-closed por los DOS lados
  -- (email del aceptante NULL y email de la invitación NULL). Candado: bloque (8) de
  -- test_accept_invitation_binding.sql.
  IF v_caller_email IS NULL
     OR v_inv.email IS NULL
     OR lower(v_inv.email) <> lower(v_caller_email) THEN
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_members
    WHERE  account_id = v_inv.account_id AND user_id = v_caller_id
  ) THEN
    RAISE EXCEPTION 'P409: caller is already a member of account %', v_inv.account_id
      USING ERRCODE = 'P0409';
  END IF;

  -- plan EFECTIVO de la cuenta de la invitación (el mismo criterio que al invitar).
  v_plan := public.get_effective_plan(v_inv.account_id);
  SELECT pl.max_users INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  -- D18: cuenta MIEMBROS, no asignaciones.
  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = v_inv.account_id;

  IF v_cur_users >= v_max_users THEN
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  v_member_id := gen_random_uuid();

  -- Conjunto a otorgar: `roles` si la invitación lo trae; si no, deriva del `role` legacy.
  v_roles := COALESCE(
    v_inv.roles,
    ARRAY[CASE COALESCE(v_inv.role, 'member') WHEN 'member' THEN 'viewer' ELSE v_inv.role END]
  );

  -- account_members.role: cualquier valor válido del CHECK sirve acá -- el trigger BEFORE INSERT
  -- (fn_derive_account_member_role) lo sobreescribe y la re-derivación CORRECTA ocurre sola
  -- cuando el loop de abajo inserta en el pivot.
  INSERT INTO public.account_members
    (id, account_id, user_id, role, created_at)
  VALUES
    (v_member_id, v_inv.account_id, v_caller_id, 'member', now());

  -- Escritura a través del pivot (D3) — TODAS las asignaciones equivalentes. assigned_by =
  -- quien invitó (invited_by), nunca el propio invitado.
  FOREACH v_role IN ARRAY v_roles LOOP
    INSERT INTO public.account_member_roles
      (account_id, member_id, role, assigned_by, assigned_at)
    VALUES
      (v_inv.account_id, v_member_id, v_role, v_inv.invited_by, now())
    ON CONFLICT (member_id, role) DO NOTHING;
  END LOOP;

  UPDATE public.account_invitations SET status = 'accepted' WHERE id = v_inv.id;

  -- multiusuario-operativo tanda C (D7): el negocio queda como CUENTA ACTIVA del invitado, en la
  -- MISMA transacción que crea la membresía (va DESPUÉS del INSERT). El invitado conserva su
  -- cuenta personal (OQ-2 a).
  UPDATE public.profiles SET active_account_id = v_inv.account_id WHERE id = v_caller_id;

  -- D19/R8: `role` se lee de la columna espejo YA RE-DERIVADA por el loop de arriba (nunca
  -- recalculado a mano); `roles` es el conjunto COMPLETO.
  SELECT role INTO v_role_legacy FROM public.account_members WHERE id = v_member_id;

  RETURN json_build_object(
    'account_member_id', v_member_id,
    'account_id',        v_inv.account_id,
    'active_account_id', v_inv.account_id,
    'role',              v_role_legacy,
    'roles',             to_jsonb(v_roles)
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_accept_invitation(text) IS
  'multiusuario-operativo tanda C (D7, D13, D14) + invitaciones-hardening (D1): crea la membresía con el conjunto de roles de la invitación Y DEJA EL NEGOCIO COMO CUENTA ACTIVA del invitado (profiles.active_account_id) en la misma transacción. Busca la invitación por el HASH del token. La aceptación exige que la identidad autenticada corresponda al email de la invitación (lower() en ambos lados, resuelto contra auth.users cuando el claim no trae el email); el rechazo usa el MISMO contrato que el token inexistente/vencido/revocado/rotado (P0404 + "P404: invalid or expired invitation token"), fail-closed por los DOS lados. La fila se toma con SELECT ... FOR UPDATE ANTES de validar. Cupo contra el plan EFECTIVO. "Not authenticated" = P0401; cupo P0402; ya miembro P0409. Candados: test_accept_invitation_binding.sql, test_multiusuario_invitaciones.sql y test_invitaciones_hardening.sql.';

-- =============================================================================
-- 6. rpc_list_account_invitations: estado de la última entrega (cambia el RETURNS)
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_list_account_invitations(uuid);

CREATE FUNCTION public.rpc_list_account_invitations(p_account_id uuid)
 RETURNS TABLE(id uuid, email text, roles text[], role_labels text[], state text, created_at timestamp with time zone, expires_at timestamp with time zone, invited_by uuid, invited_by_name text, last_sent_at timestamp with time zone, send_count integer, last_delivery_status text, last_delivery_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- La cuenta pedida tiene que ser la ACTIVA del caller (una de otra cuenta = P0404).
  IF NOT EXISTS (SELECT 1 FROM public.current_account_ids() AS cai WHERE cai = p_account_id) THEN
    RAISE EXCEPTION 'P404: account not found' USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._account_assert_capability(
    p_account_id, ARRAY['owner', 'admin'],
    'solo el dueño o un administrador puede ver las invitaciones');

  RETURN QUERY
  SELECT
    ai.id,
    ai.email,
    COALESCE(ai.roles, ARRAY[CASE COALESCE(ai.role, 'member') WHEN 'member' THEN 'viewer' ELSE ai.role END]),
    (SELECT COALESCE(array_agg(c.label ORDER BY c.sort_order), ARRAY[]::text[])
       FROM public.account_role_catalog c
      WHERE c.code = ANY (COALESCE(ai.roles, ARRAY[CASE COALESCE(ai.role, 'member') WHEN 'member' THEN 'viewer' ELSE ai.role END]))),
    CASE
      WHEN ai.status = 'revoked' THEN 'revoked'
      WHEN ai.status = 'pending' AND ai.expires_at > now() THEN 'pending'
      ELSE 'expired'
    END,
    ai.created_at,
    ai.expires_at,
    ai.invited_by,
    NULLIF(btrim(concat_ws(' ', pr.name, pr.last_name)), ''),
    s.last_sent_at,
    COALESCE(s.send_count, 0)::integer,
    -- invitaciones-hardening (D7): estado del envío MÁS RECIENTE. `sent`/`partial` = el proveedor
    -- aceptó el correo (un único destinatario); `pending` reciente = en cola; `pending` de 15
    -- minutos o más = sin confirmación (ni el disparador ni la Edge Function respondieron). NUNCA
    -- se expone error_details (puede traer texto del proveedor).
    CASE
      WHEN d.status IS NULL THEN NULL
      WHEN d.status IN ('sent', 'partial') THEN 'sent'
      WHEN d.status = 'failed' THEN 'failed'
      WHEN d.status = 'pending' AND d.created_at > now() - interval '15 minutes' THEN 'queued'
      ELSE 'unconfirmed'
    END,
    CASE
      WHEN d.status IS NULL THEN NULL
      WHEN d.status IN ('sent', 'partial') THEN COALESCE(d.sent_at, d.created_at)
      ELSE d.created_at
    END
  FROM public.account_invitations ai
  LEFT JOIN public.profiles pr ON pr.id = ai.invited_by
  LEFT JOIN LATERAL (
    SELECT max(el.created_at) AS last_sent_at, count(*) AS send_count
    FROM   public.email_logs el
    WHERE  el.event_type = 'org_invite'
      AND  el.metadata ->> 'account_id'    = ai.account_id::text
      AND  el.metadata ->> 'invitation_id' = ai.id::text
  ) s ON true
  LEFT JOIN LATERAL (
    SELECT el.status, el.sent_at, el.created_at
    FROM   public.email_logs el
    WHERE  el.event_type = 'org_invite'
      AND  el.metadata ->> 'account_id'    = ai.account_id::text
      AND  el.metadata ->> 'invitation_id' = ai.id::text
    ORDER BY el.created_at DESC
    LIMIT 1
  ) d ON true
  WHERE ai.account_id = p_account_id
    AND ai.status <> 'accepted'
    AND (
         (ai.status = 'pending' AND ai.expires_at > now())
      OR (ai.status IN ('pending', 'expired') AND ai.expires_at <= now() AND ai.expires_at > now() - interval '30 days')
      OR (ai.status = 'revoked' AND COALESCE(ai.revoked_at, ai.created_at) > now() - interval '30 days')
    )
  ORDER BY ai.created_at DESC, ai.id;
END;
$function$;

COMMENT ON FUNCTION public.rpc_list_account_invitations(uuid) IS
  'multiusuario-operativo tanda C (D13) + invitaciones-hardening (D7): las invitaciones de la cuenta ACTIVA para su dueño o administrador (observador P0401, otro rol P0403, otra cuenta P0404): las pendientes vigentes, las vencidas y las revocadas de los últimos 30 días; las aceptadas ya son miembros. NUNCA expone el token (la tabla sólo guarda su hash) ni error_details. state = pending | expired | revoked; last_sent_at y send_count salen del historial de envíos (email_logs); last_delivery_status (sent | queued | failed | unconfirmed | NULL = nunca enviada) y last_delivery_at salen del envío MÁS RECIENTE. Hace falta porque la tabla ya no es legible por PostgREST.';

-- =============================================================================
-- 7. email_logs: el token de la plantilla se retira apenas termina el intento
-- =============================================================================
CREATE OR REPLACE FUNCTION public._email_logs_strip_invite_token()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  NEW.metadata := NEW.metadata - 'token';
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public._email_logs_strip_invite_token() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._email_logs_strip_invite_token() IS
  'invitaciones-hardening (D3): retira metadata.token de una fila org_invite cuando deja de estar pending (sent, failed o partial). Función de disparador: sin EXECUTE para los roles de aplicación.';

DROP TRIGGER IF EXISTS trg_email_logs_strip_invite_token ON public.email_logs;
CREATE TRIGGER trg_email_logs_strip_invite_token
  BEFORE UPDATE OF status ON public.email_logs
  FOR EACH ROW
  WHEN (NEW.event_type = 'org_invite' AND NEW.status IS DISTINCT FROM 'pending' AND NEW.metadata ? 'token')
  EXECUTE FUNCTION public._email_logs_strip_invite_token();

-- Purga de lo que ya exista (el dato histórico).
UPDATE public.email_logs
SET    metadata = metadata - 'token'
WHERE  event_type = 'org_invite' AND status <> 'pending' AND metadata ? 'token';

-- =============================================================================
-- 8. account_invitations: sólo para las funciones del dominio
-- =============================================================================
DROP POLICY IF EXISTS account_invitations_owner_all ON public.account_invitations;
REVOKE ALL ON public.account_invitations FROM PUBLIC, anon, authenticated;
ALTER TABLE public.account_invitations ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.account_invitations IS
  'invitaciones-hardening (D4): invitaciones a una cuenta. Sin policy y sin privilegios de tabla para anon/authenticated: se escribe y se lee SÓLO por las funciones SECURITY DEFINER del dominio (rpc_invite_member, rpc_send_invitation_email, rpc_list_account_invitations, rpc_revoke_invitation, rpc_invitation_preview, rpc_accept_invitation). Guarda token_hash, nunca el token. Candado: supabase/tests/test_invitaciones_hardening.sql.';

-- =============================================================================
-- 9. ACLs re-emitidas
-- =============================================================================
REVOKE ALL ON FUNCTION public.rpc_invite_member(text, uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_invite_member(text, uuid, text[]) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.rpc_accept_invitation(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_accept_invitation(text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.rpc_send_invitation_email(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_send_invitation_email(uuid, text, boolean) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.rpc_list_account_invitations(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_list_account_invitations(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.rpc_revoke_invitation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_revoke_invitation(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.rpc_invitation_preview(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_invitation_preview(text) TO authenticated, service_role;

-- =============================================================================
-- 10. Introspección: falla la migración si algo no quedó como se diseñó
-- =============================================================================
DO $$
DECLARE
  v_def text;
  v_n   integer;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'account_invitations' AND column_name = 'token') THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): account_invitations todavía tiene la columna token en claro';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                 WHERE schemaname = 'public' AND tablename = 'account_invitations'
                   AND indexname = 'account_invitations_token_hash_key' AND indexdef LIKE '%UNIQUE%') THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): falta el índice único sobre token_hash';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'account_invitations'
             AND (roles && ARRAY['anon', 'authenticated', 'public']::name[])) THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): account_invitations conserva una policy para anon/authenticated/public';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.account_invitations'::regclass) THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): RLS deshabilitada en account_invitations';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(ARRAY['anon', 'authenticated']) AS rl(r),
                  unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS pv(p)
    WHERE has_table_privilege(rl.r, 'public.account_invitations', pv.p)
  ) THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): anon/authenticated conservan un privilegio de tabla sobre account_invitations';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(ARRAY['anon', 'authenticated']) AS rl(r),
                  unnest(ARRAY['SELECT','INSERT','UPDATE','REFERENCES']) AS pv(p)
    WHERE has_any_column_privilege(rl.r, 'public.account_invitations', pv.p)
  ) THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): anon/authenticated conservan un privilegio de columna sobre account_invitations';
  END IF;

  -- Una sola definición viva por función y ACLs: authenticated SÍ; anon y PUBLIC NUNCA.
  SELECT count(*) INTO v_n FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace
     AND proname IN ('rpc_invite_member','rpc_accept_invitation','rpc_send_invitation_email',
                     'rpc_list_account_invitations','rpc_revoke_invitation','rpc_invitation_preview');
  IF v_n <> 6 THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): se esperaban 6 funciones de invitación vivas (una por nombre), hay %', v_n;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('rpc_invite_member','rpc_accept_invitation','rpc_send_invitation_email',
                        'rpc_list_account_invitations','rpc_revoke_invitation','rpc_invitation_preview')
      AND (has_function_privilege('anon', p.oid, 'EXECUTE')
           OR NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0))
  ) THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): alguna función de invitación tiene mal su ACL (anon / PUBLIC con EXECUTE, o authenticated sin él)';
  END IF;

  -- Helper y función del disparador: sin EXECUTE para los roles de aplicación.
  IF has_function_privilege('authenticated', 'public._invitation_token_hash(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._invitation_token_hash(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._email_logs_strip_invite_token()', 'EXECUTE')
     OR has_function_privilege('anon', 'public._email_logs_strip_invite_token()', 'EXECUTE') THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): el helper de hash o la función del disparador son ejecutables por authenticated/anon';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.email_logs'::regclass
                 AND tgname = 'trg_email_logs_strip_invite_token' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): falta el disparador trg_email_logs_strip_invite_token';
  END IF;

  -- El envío conserva el guard de autoridad ANTES de escribir, el lock de la fila y el destinatario de la fila.
  SELECT regexp_replace(pg_get_functiondef('public.rpc_send_invitation_email(uuid,text,boolean)'::regprocedure), '--[^\n]*', '', 'g') INTO v_def;
  IF position('_account_assert_capability' IN v_def) = 0
     OR position('INSERT INTO public.email_logs' IN v_def) = 0
     OR position('_account_assert_capability' IN v_def) > position('INSERT INTO public.email_logs' IN v_def)
     OR position('FOR UPDATE' IN v_def) = 0
     OR position('v_inv.email' IN v_def) = 0
     OR position('_invitation_token_hash' IN v_def) = 0 THEN
    RAISE EXCEPTION 'invitaciones-hardening (introspección): rpc_send_invitation_email no tiene el guard de autoridad antes de escribir, el lock de la fila, el destinatario de la fila o el hash del token';
  END IF;

  RAISE NOTICE 'invitaciones-hardening (introspección): sin columna token, token_hash con índice único, account_invitations sin policy ni privilegios para anon/authenticated, 6 funciones de invitación con ACLs sin anon ni PUBLIC, helper y función de disparador internos, disparador de retiro del token presente, envío con guard antes de escribir';
END $$;
