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
  v_roles       text[];
  v_role_legacy text;
BEGIN
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
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
  -- billing_plan crudo -- mismo motivo y mismo helper que el overload de
  -- 2 args (ver comentario allí).
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
      AND  email      = lower(trim(p_email))
      AND  status     = 'pending'
      AND  expires_at > now()
  ) THEN
    RAISE EXCEPTION 'P409: pending invitation already exists for %', p_email
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
    (v_inv_id, p_account_id, lower(trim(p_email)), v_token,
     v_role_legacy, v_roles, 'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'token',      v_token,
    'email',      lower(trim(p_email)),
    'roles',      to_jsonb(v_roles),
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$function$

-- ACL/COMMENT vivos:
-- ACL: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
-- COMMENT: membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, 2026-09-12): el cupo se evalúa contra el plan EFECTIVO (public.get_effective_plan), no accounts.billing_plan crudo -- mismo motivo que el overload de 2 args. Único cambio de comportamiento sobre el cuerpo de v3-rbac-multirole Parte C (grupo 15): idéntica salvo esa línea -- invita con CONJUNTO de roles del catálogo, sin roles declarados -> {viewer}, sin gate de plan (D17), ERRCODEs P04xx con el texto del mensaje preservado (D18): P0403 autoridad, P0400 catálogo, P0402 cupo, P0407 duplicada. p_roles SIN DEFAULT -- evita colisionar por aridad con el overload de 2 args (TeamSection.tsx), que sigue vivo.
