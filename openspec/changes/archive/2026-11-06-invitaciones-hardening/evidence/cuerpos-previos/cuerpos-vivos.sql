-- ==== rpc_accept_invitation
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
    -- multiusuario-operativo tanda C (D14): P0001 -> P0401, texto conservado.
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- auth-hardening-jwt-cookies (D14, F13): identidad del aceptante para el
  -- binding de email. Se resuelve contra auth.users y NO contra el claim: el
  -- backend propio empuja a Postgres sólo {"sub","role"[, "app_metadata"]}
  -- (backend/core/database.py), sin email, así que un guard keyeado en el
  -- claim rechazaría el 100% de las aceptaciones que lleguen por FastAPI. El
  -- claim se usa como atajo equivalente cuando está presente (camino PostgREST).
  v_caller_email := COALESCE(
    auth.jwt()->>'email',
    (SELECT u.email FROM auth.users u WHERE u.id = v_caller_id)
  );

  -- auth-hardening-jwt-cookies (D14): FOR UPDATE -- lock de la fila ANTES de
  -- validar estado y vigencia. Dos aceptaciones concurrentes del mismo token
  -- ya no pueden observar ambas el estado pendiente: la segunda espera acá y,
  -- al commitear la primera, su predicado status='pending' deja de matchear.
  -- multiusuario-operativo tanda C (D13): una invitación `revoked` o rotada por un reenvío
  -- tampoco matchea (status <> pending / token distinto) -> mismo error genérico.
  SELECT *
  INTO   v_inv
  FROM   public.account_invitations
  WHERE  token     = p_token
    AND  status    = 'pending'
    AND  expires_at > now()
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  -- auth-hardening-jwt-cookies (D14, F13): la invitación es de quien la
  -- recibió. Comparación insensible a mayúsculas en ambos lados; MISMO
  -- ERRCODE y MISMO texto que el rechazo por token inexistente/vencido, para
  -- que la respuesta no confirme que el token es válido para otra identidad.
  -- Fail-closed por los DOS lados (email del aceptante NULL y email de la
  -- invitación NULL): sin la comprobación explícita de NULL sobre la
  -- invitación, la lógica de tres valores dejaba la condición en NULL y el
  -- guard degradaba FAIL-OPEN (medido en la base local). Candado: bloque (8)
  -- de test_accept_invitation_binding.sql.
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

  -- v3-rbac-multirole humo fix (bug 1, 2026-09-12): plan EFECTIVO de la
  -- cuenta de la invitación -- el cupo evaluado al ACEPTAR debe coincidir
  -- con el efectivo evaluado al invitar (rpc_invite_member), nunca con
  -- accounts.billing_plan crudo.
  v_plan := public.get_effective_plan(v_inv.account_id);
  SELECT pl.max_users INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  -- D18: cuenta MIEMBROS, no asignaciones (sin cambios de fondo).
  SELECT COUNT(*) INTO v_cur_users FROM public.account_members WHERE account_id = v_inv.account_id;

  IF v_cur_users >= v_max_users THEN
    -- D18: P0001 -> P0402 (cupo), MISMO código que rpc_invite_member.
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  v_member_id := gen_random_uuid();

  -- Conjunto a otorgar (grupo 15): `roles` si la invitación la trae
  -- (creada por el overload de 3 args, ya con conjunto); si no, deriva del
  -- `role` legacy (una invitación pre-migración) -- mismo mapeo D2 que el
  -- backfill/rpc_change_member_role: member->viewer, owner/admin idénticos.
  v_roles := COALESCE(
    v_inv.roles,
    ARRAY[CASE COALESCE(v_inv.role, 'member') WHEN 'member' THEN 'viewer' ELSE v_inv.role END]
  );

  -- account_members.role: cualquier valor válido del CHECK sirve acá -- el
  -- trigger BEFORE INSERT (fn_derive_account_member_role, Parte A) lo
  -- sobreescribe de inmediato a 'member' (el pivot todavía no tiene ninguna
  -- fila para v_member_id en este instante), y la re-derivación CORRECTA
  -- ocurre sola cuando el loop de abajo inserta en el pivot (cada INSERT
  -- dispara trg_touch_account_member_role -> vuelve a tocar account_members
  -- -> trg_derive_account_member_role recalcula ya con el pivot poblado).
  INSERT INTO public.account_members
    (id, account_id, user_id, role, created_at)
  VALUES
    (v_member_id, v_inv.account_id, v_caller_id, 'member', now());

  -- Escritura a través del pivot (D3) — TODAS las asignaciones equivalentes,
  -- no sólo una. assigned_by = quien invitó (invited_by), nunca el propio
  -- invitado (mismo criterio que la Parte A).
  FOREACH v_role IN ARRAY v_roles LOOP
    INSERT INTO public.account_member_roles
      (account_id, member_id, role, assigned_by, assigned_at)
    VALUES
      (v_inv.account_id, v_member_id, v_role, v_inv.invited_by, now())
    ON CONFLICT (member_id, role) DO NOTHING;
  END LOOP;

  UPDATE public.account_invitations SET status = 'accepted' WHERE id = v_inv.id;

  -- multiusuario-operativo tanda C (D7): el negocio queda como CUENTA ACTIVA del
  -- invitado, en la MISMA transacción que crea la membresía (va DESPUÉS del INSERT:
  -- sólo se activa una cuenta de la que ya es miembro). El invitado conserva su cuenta
  -- personal (OQ-2 a). El frontend renueva el token después de aceptar, y el hook
  -- emite la cuenta del negocio. Sin esto su primera venta caería en la personal (R3l).
  UPDATE public.profiles SET active_account_id = v_inv.account_id WHERE id = v_caller_id;

  -- D19/R8 (el derivado singular sobrevive): `role` se lee de la columna
  -- espejo YA RE-DERIVADA por el loop de arriba (nunca recalculado a mano
  -- acá -- una segunda fórmula de precedencia divergiría en silencio de la
  -- única fuente real, D3) -- mantiene el contrato heredado de la Parte A
  -- (que el gate test_membership_rpcs_pivot_rewrite.sql sigue verificando)
  -- para quien todavía consuma `role`; `roles` es el conjunto COMPLETO.
  SELECT role INTO v_role_legacy FROM public.account_members WHERE id = v_member_id;

  RETURN json_build_object(
    'account_member_id', v_member_id,
    'account_id',        v_inv.account_id,
    'active_account_id', v_inv.account_id,
    'role',              v_role_legacy,
    'roles',             to_jsonb(v_roles)
  );
END;
$function$
;
-- ==== rpc_invitation_preview
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

  SELECT ai.* INTO v_inv
  FROM   public.account_invitations ai
  WHERE  ai.token = p_token AND ai.status = 'pending' AND ai.expires_at > now()
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
$function$
;
-- ==== rpc_invite_member
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
  v_token       text;
  v_email       text;
  v_roles       text[];
  v_role_legacy text;
BEGIN
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    -- multiusuario-operativo tanda C (D14): P0001 -> P0401 (candidato
    -- membership-rpcs-not-authenticated-p0401), texto conservado.
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  -- Caller must be owner or admin
  SELECT role INTO v_caller_role
  FROM   public.account_members
  WHERE  account_id = p_account_id AND user_id = v_caller_id;

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('owner', 'admin') THEN
    -- D18: P0001 -> P0403, texto conservado.
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

  -- account-membership-roles ("Invitación diferenciada por rol que puede
  -- invitar"): normaliza el conjunto (NULL o vacío -> {viewer}, D-account-
  -- membership-roles "Una invitación sin roles declarados resuelve a solo
  -- lectura") y deduplica.
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

  -- Admin can only invite with operational roles -- NUNCA owner/admin en el
  -- conjunto. Mismo texto que el cuerpo original (un solo rol, "admins") --
  -- ahora cubre además 'owner' en el conjunto, D18 conserva el texto más
  -- cercano existente en vez de inventar uno nuevo.
  IF v_caller_role = 'admin' AND (v_roles && ARRAY['owner', 'admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el owner puede invitar admins'
      USING ERRCODE = 'P0403';
  END IF;

  -- v3-rbac-multirole Parte C (D17, sign-off PO 6.2): el gate "'admin' IN
  -- p_roles requiere plan 'pro'" se RETIRA -- el paso "role='admin' requires
  -- plan='pro'" del cuerpo original queda eliminado por completo.

  -- v3-rbac-multirole humo fix (bug 1, 2026-09-12): plan EFECTIVO, no
  -- billing_plan crudo.
  v_plan := public.get_effective_plan(p_account_id);
  SELECT pl.max_users INTO v_max_users FROM public.plan_limits pl WHERE pl.plan = v_plan;
  IF v_max_users IS NULL THEN v_max_users := 1; END IF;

  -- D18: cuenta MIEMBROS, no asignaciones (sin cambios de fondo).
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

  v_token  := encode(extensions.gen_random_bytes(32), 'hex');
  v_inv_id := gen_random_uuid();

  -- Representante legacy por precedencia (D3: owner > admin > else 'member')
  -- -- satisface el CHECK de account_invitations.role, y es lo que
  -- consumiría un lector legacy que todavía no mira `roles`.
  v_role_legacy := CASE
    WHEN 'owner' = ANY(v_roles) THEN 'owner'
    WHEN 'admin' = ANY(v_roles) THEN 'admin'
    ELSE 'member'
  END;

  INSERT INTO public.account_invitations
    (id, account_id, email, token, role, roles, status, invited_by, created_at, expires_at)
  VALUES
    (v_inv_id, p_account_id, v_email, v_token,
     v_role_legacy, v_roles, 'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'token',      v_token,
    'email',      v_email,
    'roles',      to_jsonb(v_roles),
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$function$
;
-- ==== rpc_list_account_invitations
CREATE OR REPLACE FUNCTION public.rpc_list_account_invitations(p_account_id uuid)
 RETURNS TABLE(id uuid, email text, roles text[], role_labels text[], state text, created_at timestamp with time zone, expires_at timestamp with time zone, invited_by uuid, invited_by_name text, last_sent_at timestamp with time zone, send_count integer)
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
    COALESCE(s.send_count, 0)::integer
  FROM public.account_invitations ai
  LEFT JOIN public.profiles pr ON pr.id = ai.invited_by
  LEFT JOIN LATERAL (
    SELECT max(el.created_at) AS last_sent_at, count(*) AS send_count
    FROM   public.email_logs el
    WHERE  el.event_type = 'org_invite'
      AND  el.metadata ->> 'account_id'    = ai.account_id::text
      AND  el.metadata ->> 'invitation_id' = ai.id::text
  ) s ON true
  WHERE ai.account_id = p_account_id
    AND ai.status <> 'accepted'
    AND (
         (ai.status = 'pending' AND ai.expires_at > now())
      OR (ai.status IN ('pending', 'expired') AND ai.expires_at <= now() AND ai.expires_at > now() - interval '30 days')
      OR (ai.status = 'revoked' AND COALESCE(ai.revoked_at, ai.created_at) > now() - interval '30 days')
    )
  ORDER BY ai.created_at DESC, ai.id;
END;
$function$
;
-- ==== rpc_revoke_invitation
CREATE OR REPLACE FUNCTION public.rpc_revoke_invitation(p_invitation_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_inv record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0401';
  END IF;

  SELECT ai.* INTO v_inv
  FROM   public.account_invitations ai
  WHERE  ai.id = p_invitation_id
    AND  ai.account_id IN (SELECT cai FROM public.current_account_ids() AS cai)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'P404: invitation not found' USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._account_assert_capability(
    v_inv.account_id, ARRAY['owner', 'admin'],
    'solo el dueño o un administrador puede revocar invitaciones');

  -- Idempotente: revocar una ya revocada no falla ni cambia nada.
  IF v_inv.status = 'revoked' THEN
    RETURN json_build_object('id', v_inv.id, 'status', 'revoked');
  END IF;
  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'invitation_not_pending: la invitación ya fue aceptada'
      USING ERRCODE = 'P0409';
  END IF;

  UPDATE public.account_invitations
  SET    status = 'revoked', revoked_at = now(), revoked_by = v_uid
  WHERE  id = v_inv.id;

  RETURN json_build_object('id', v_inv.id, 'status', 'revoked');
END;
$function$
;
-- ==== rpc_send_invitation_email
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

  -- La invitación tiene que ser de la cuenta ACTIVA del caller (el mismo criterio que las
  -- RPCs de operaciones, tanda B): una de otra cuenta es indistinguible de una inexistente.
  -- Se toma con FOR UPDATE: dos envíos simultáneos de la MISMA invitación se serializan y el
  -- enfriamiento de abajo es confiable.
  SELECT ai.* INTO v_inv
  FROM   public.account_invitations ai
  WHERE  ai.id = p_invitation_id
    AND  ai.account_id IN (SELECT cai FROM public.current_account_ids() AS cai)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'P404: invitation not found' USING ERRCODE = 'P0404';
  END IF;

  -- Autoridad ANTES de cualquier otra cosa o escritura: dueño o administrador de ESA cuenta.
  -- Observador = P0401 (no escritor), otro rol = P0403 insufficient_role.
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

  -- Defensa en profundidad: el destinatario sale de la fila, y la fila ya se valida al crearla;
  -- una fila anterior o escrita por fuera de la RPC no puede mandar un email a `all_users`
  -- ni con saltos de línea.
  IF v_inv.email IS NULL
     OR char_length(v_inv.email) > 254
     OR v_inv.email !~ '^[^[:space:][:cntrl:]@]+@[^[:space:][:cntrl:]@]+\.[^[:space:][:cntrl:]@]+$' THEN
    RAISE EXCEPTION 'invalid_email: la dirección de email de la invitación no es válida'
      USING ERRCODE = 'P0400';
  END IF;

  -- Topes. El tope diario cuenta por cuenta: el candado de aviso serializa los envíos
  -- simultáneos de la cuenta para que dos invitaciones distintas no pasen ambas el conteo.
  PERFORM pg_advisory_xact_lock(hashtextextended('org_invite_cap:' || v_inv.account_id::text, 0));

  IF EXISTS (
    SELECT 1 FROM public.email_logs el
    WHERE  el.event_type = 'org_invite'
      AND  el.metadata ->> 'account_id'    = v_inv.account_id::text
      AND  el.metadata ->> 'invitation_id' = v_inv.id::text
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

  -- Reenviar ROTA el token (los links de los emails anteriores dejan de servir) y renueva el
  -- vencimiento; el primer envío conserva el de la creación.
  v_token   := v_inv.token;
  v_expires := v_inv.expires_at;
  IF p_renew THEN
    v_token   := encode(extensions.gen_random_bytes(32), 'hex');
    v_expires := now() + c_validity;
  END IF;

  -- Nombre del negocio: lo único que viene del caller (un dueño o administrador ya lo controla
  -- desde la marca). Sin caracteres de control ni saltos de línea (va al asunto), recortado a
  -- 120; si viene vacío se conserva el snapshot anterior y, si no, un nombre genérico.
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
  SET    token = v_token, expires_at = v_expires, account_display_name = v_name
  WHERE  id = v_inv.id;

  -- EL EMAIL, encolado en la MISMA transacción. El destinatario (`v_inv.email`) y el token
  -- salen de la FILA de la invitación: ninguno es un parámetro de esta función. El link NO se
  -- guarda acá: lo arma send-email con la URL fija de la app (APP_URL) y este token.
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
      -- distingue dos envíos de la misma invitación sin rotar el token (UNIQUE user/evento/metadata)
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
$function$
;
