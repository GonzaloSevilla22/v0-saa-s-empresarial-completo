CREATE OR REPLACE FUNCTION public.rpc_invite_member(p_email text, p_account_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id  uuid;
  v_plan       text;
  v_max_users  int;
  v_cur_users  int;
  v_inv_id     uuid;
  v_token      text;
BEGIN
  -- 1. Identify the caller
  v_caller_id := (SELECT auth.uid());
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Confirm caller is owner of this account
  IF NOT EXISTS (
    SELECT 1
    FROM   public.account_members
    WHERE  account_id = p_account_id
      AND  user_id    = v_caller_id
      AND  role       = 'owner'
  ) THEN
    -- v3-rbac-multirole Parte C (D18): P0001 -> P0403 (falta de autoridad),
    -- TEXTO conservado -- el cliente lo sigue matcheando por el substring
    -- "P401:" (frontend/components/settings/TeamSection.tsx).
    RAISE EXCEPTION 'P401: caller is not the owner of account %', p_account_id
      USING ERRCODE = 'P0403';
  END IF;

  -- 3. Get EFFECTIVE plan + max_users for this account (v3-rbac-multirole
  --    humo fix, bug 1, 2026-09-12): get_effective_plan() resuelve
  --    exención/trial vigente/billing_plan pagado con vencimiento -- leer
  --    accounts.billing_plan crudo dejaba a TODA cuenta nueva (gratis +
  --    trial 'pro' de 30 días, billing-pro-trial) con cupo 1 (el de
  --    'gratis') en vez de 10 (el de 'pro' efectivo), sin poder invitar a
  --    nadie con el owner ya ocupando el único lugar. Mismo helper
  --    canónico que reporting_plan_window/rpc_import_products
  --    (importador-gate-plan) -- sin GRANT adicional: esta función es
  --    SECURITY DEFINER con owner postgres (superusuario).
  v_plan := public.get_effective_plan(p_account_id);

  SELECT pl.max_users
  INTO   v_max_users
  FROM   public.plan_limits pl
  WHERE  pl.plan = v_plan;

  IF v_max_users IS NULL THEN
    v_max_users := 1; -- safe fallback for gratis
  END IF;

  -- 4. Count current active members (D18: cuenta MIEMBROS, sin cambios)
  SELECT COUNT(*)
  INTO   v_cur_users
  FROM   public.account_members
  WHERE  account_id = p_account_id;

  IF v_cur_users >= v_max_users THEN
    -- D18: P0001 -> P0402 (cupo), TEXTO conservado ("P403:" -- el cliente lo
    -- matchea por substring, no por sqlstate).
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  -- 5. Check for an existing pending invitation for this email
  IF EXISTS (
    SELECT 1
    FROM   public.account_invitations
    WHERE  account_id = p_account_id
      AND  email      = lower(trim(p_email))
      AND  status     = 'pending'
      AND  expires_at > now()
  ) THEN
    -- D18: P0001 -> P0407 (invitación duplicada), TEXTO conservado.
    RAISE EXCEPTION 'P409: pending invitation already exists for %', p_email
      USING ERRCODE = 'P0407';
  END IF;

  -- 6. Generate a secure random token (64 hex chars = 32 bytes entropy)
  v_token  := encode(extensions.gen_random_bytes(32), 'hex');
  v_inv_id := gen_random_uuid();

  -- 7. Insert the invitation
  INSERT INTO public.account_invitations
    (id, account_id, email, token, status, invited_by, created_at, expires_at)
  VALUES
    (v_inv_id, p_account_id, lower(trim(p_email)), v_token,
     'pending', v_caller_id, now(), now() + INTERVAL '7 days');

  RETURN json_build_object(
    'id',         v_inv_id,
    'token',      v_token,
    'email',      lower(trim(p_email)),
    'expires_at', (now() + INTERVAL '7 days')
  );
END;
$function$

-- ACL/COMMENT vivos:
-- ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- COMMENT: membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, 2026-09-12): el cupo se evalúa contra el plan EFECTIVO (public.get_effective_plan), no accounts.billing_plan crudo -- toda cuenta nueva (gratis + trial pro) podía quedar sin poder invitar a nadie durante el trial. Único cambio de comportamiento sobre el cuerpo de v3-rbac-multirole Parte C (D18): idéntica salvo esa línea. Sin gate de plan (nunca lo tuvo). "Quick invite" sin selector de rol (TeamSection.tsx) -- crea la invitación sin `role`/`roles` explícitos, default de tabla (role='member') -- rpc_accept_invitation la resuelve a {viewer} (D2).
