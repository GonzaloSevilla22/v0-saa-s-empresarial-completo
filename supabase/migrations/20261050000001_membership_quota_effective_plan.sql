-- =============================================================================
-- membership-quota-effective-plan — fix de un humo de aceptación de
-- v3-rbac-multirole (2026-09-12, con usuarios de prueba autorizados por el
-- PO en la base LOCAL). Bug 1 (HIGH, ver brief_fix.md / CHANGES.md "Humos
-- locales de aceptación").
--
-- SÍNTOMA: toda cuenta nueva nace con billing_plan='gratis' Y trial_plan
-- ('pro', 30 días -- handle_new_user / billing-pro-trial). El plan EFECTIVO
-- de esa cuenta es 'pro' (public.get_effective_plan, cupo 10), pero
-- rpc_invite_member (ambos overloads) y rpc_accept_invitation calculaban el
-- cupo contra accounts.billing_plan CRUDO ('gratis', cupo 1) -- con el owner
-- ya ocupando el único lugar, NINGUNA cuenta nueva podía invitar a nadie
-- durante todo el trial. Contradice D18 de v3-rbac-multirole Parte C ("el
-- cupo comercial cuenta miembros, no roles" -- implícitamente contra el
-- plan EFECTIVO, no el contratado) y la spec plan-gating ("Plan efectivo
-- con soporte de trial").
--
-- FIX: las 3 llamadas que hacían `SELECT billing_plan INTO v_plan FROM
-- accounts ...` pasan a `v_plan := public.get_effective_plan(<account_id>)`.
-- Es el ÚNICO cambio de comportamiento en las 3 funciones -- nada más se
-- toca (mismo cuerpo, misma firma, mismas ACLs). Mismo helper canónico que
-- ya usan reporting_plan_window (rpc_sales_evolution) y rpc_import_products
-- (importador-gate-plan, 2026-09-11) -- sin GRANT adicional: las 3 funciones
-- son SECURITY DEFINER con owner `postgres` (superusuario), así que la
-- llamada interna a get_effective_plan (EXECUTE sólo para
-- supabase_auth_admin/service_role) no requiere ACL nueva.
--
-- Integridad de función -- verificado contra el cuerpo VIVO de PROD el
-- 2026-09-12 vía mcp__supabase__execute_sql (read-only), md5 normalizado
-- (\r\n -> \n, mismo gotcha de siempre: el checkout local tiene CRLF, prod
-- no):
--   rpc_invite_member(text, uuid)             = 8fbe797d7aca628dbbe0379a3c77c22a
--   rpc_invite_member(text, uuid, text[])      = 6cbf16252141614069938cce5dfd2e0c
--   rpc_accept_invitation(text)                = e263f21d8562ac2874eb5e14459b74bc
-- Las 3 IDÉNTICAS en LOCAL (post 20261049000001) y en PROD -- este archivo
-- reescribe DESDE ESE CUERPO, con la única línea de arriba cambiada en cada
-- una. ACLs preservadas por CREATE OR REPLACE (misma firma, sin DROP):
-- {postgres=X, authenticated=X, service_role=X} en las 3, verificado igual
-- en ambos lados antes de escribir este archivo.
--
-- RONDA 3 ADVERSARIAL (finding MINOR, 2026-09-12, mismo día): la MISMA clase
-- de bug seguía viva en una 4ª función -- rpc_create_branch(uuid, text,
-- text) gateaba max_branches/has_branches_module contra billing_plan crudo,
-- mismo cohorte de trial (24/39 cuentas de prod). Se agrega a este mismo
-- archivo (bloque 4, al final) con el mismo patrón exacto: cuerpo VIVO
-- verificado (md5 073b8cb0f892c72e3e8676afc5fa9f65, idéntico local/prod),
-- CREATE OR REPLACE puro, único cambio v_plan := get_effective_plan(...).
--
-- Idempotente: CREATE OR REPLACE puro, misma firma en las 4 -- reaplicable
-- sin duplicar nada.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. rpc_invite_member(text, uuid) -- overload de 2 args (TeamSection.tsx,
--    "quick invite" sin selector de rol, sólo el owner).
-- -----------------------------------------------------------------------------
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
;

COMMENT ON FUNCTION public.rpc_invite_member(text, uuid) IS
  'membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, '
  '2026-09-12): el cupo se evalúa contra el plan EFECTIVO '
  '(public.get_effective_plan), no accounts.billing_plan crudo -- toda '
  'cuenta nueva (gratis + trial pro) podía quedar sin poder invitar a '
  'nadie durante el trial. Único cambio de comportamiento sobre el cuerpo '
  'de v3-rbac-multirole Parte C (D18): idéntica salvo esa línea. Sin gate '
  'de plan (nunca lo tuvo). "Quick invite" sin selector de rol '
  '(TeamSection.tsx) -- crea la invitación sin `role`/`roles` explícitos, '
  'default de tabla (role=''member'') -- rpc_accept_invitation la resuelve a '
  '{viewer} (D2).';


-- -----------------------------------------------------------------------------
-- 2. rpc_invite_member(text, uuid, text[]) -- overload de 3 args (conjunto
--    de roles, sin gate de plan, D17).
-- -----------------------------------------------------------------------------
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
;

COMMENT ON FUNCTION public.rpc_invite_member(text, uuid, text[]) IS
  'membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, '
  '2026-09-12): el cupo se evalúa contra el plan EFECTIVO '
  '(public.get_effective_plan), no accounts.billing_plan crudo -- mismo '
  'motivo que el overload de 2 args. Único cambio de comportamiento sobre '
  'el cuerpo de v3-rbac-multirole Parte C (grupo 15): idéntica salvo esa '
  'línea -- invita con CONJUNTO de roles del catálogo, sin roles '
  'declarados -> {viewer}, sin gate de plan (D17), ERRCODEs P04xx con el '
  'texto del mensaje preservado (D18): P0403 autoridad, P0400 catálogo, '
  'P0402 cupo, P0407 duplicada. p_roles SIN DEFAULT -- evita colisionar '
  'por aridad con el overload de 2 args (TeamSection.tsx), que sigue vivo.';


-- -----------------------------------------------------------------------------
-- 3. rpc_accept_invitation(text) -- el cupo evaluado AL ACEPTAR debe ser el
--    mismo efectivo que el evaluado al invitar.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_accept_invitation(p_token text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id    uuid;
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
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO   v_inv
  FROM   public.account_invitations
  WHERE  token     = p_token
    AND  status    = 'pending'
    AND  expires_at > now()
  LIMIT 1;

  IF NOT FOUND THEN
    -- Ronda 1 adversarial (finding NIT): P0001 -> P0404, texto conservado --
    -- mismo criterio D18 que el resto de esta migración (regla dura del
    -- proyecto: ERRCODEs P04xx del catálogo, nunca P0001, para un 404/409
    -- con mapeo obvio).
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_members
    WHERE  account_id = v_inv.account_id AND user_id = v_caller_id
  ) THEN
    -- Ronda 1 adversarial (finding NIT): P0001 -> P0409, texto conservado.
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
    -- D18: P0001 -> P0402 (cupo), MISMO código que rpc_invite_member --
    -- misma clase de error, texto conservado.
    RAISE EXCEPTION 'P403: member quota reached (% / %)', v_cur_users, v_max_users
      USING ERRCODE = 'P0402';
  END IF;

  v_member_id := gen_random_uuid();

  -- Conjunto a otorgar (grupo 15): `roles` si la invitación la trae
  -- (creada por el overload de 3 args, ya con conjunto); si no, deriva del
  -- `role` legacy (overload de 2 args, o una invitación pre-migración) --
  -- mismo mapeo D2 que el backfill/rpc_change_member_role: member->viewer,
  -- owner/admin idénticos.
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

  -- D19/R8 (el derivado singular sobrevive): `role` se lee de la columna
  -- espejo YA RE-DERIVADA por el loop de arriba (nunca recalculado a mano
  -- acá -- una segunda fórmula de precedencia divergiría en silencio de la
  -- única fuente real, D3) -- mantiene el contrato heredado del cuerpo de
  -- la Parte A (que el gate test_membership_rpcs_pivot_rewrite.sql sigue
  -- verificando) para quien todavía consuma `role`; `roles` es el conjunto
  -- COMPLETO, nuevo en esta parte.
  SELECT role INTO v_role_legacy FROM public.account_members WHERE id = v_member_id;

  RETURN json_build_object(
    'account_member_id', v_member_id,
    'account_id',        v_inv.account_id,
    'role',              v_role_legacy,
    'roles',             to_jsonb(v_roles)
  );
END;
$function$
;

COMMENT ON FUNCTION public.rpc_accept_invitation(text) IS
  'membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, '
  '2026-09-12): el cupo se evalúa contra el plan EFECTIVO de la cuenta de '
  'la invitación (public.get_effective_plan), no accounts.billing_plan '
  'crudo -- debe coincidir con el efectivo que ya evalúa rpc_invite_member '
  'al invitar. Único cambio de comportamiento sobre el cuerpo de '
  'v3-rbac-multirole Parte C (grupo 15): idéntica salvo esa línea -- '
  'acepta CUALQUIER conjunto de roles, lee account_invitations.roles si '
  'está poblada (overload de 3 args), si no deriva del `role` legacy '
  '(overload de 2 args / fila pre-migración, mismo mapeo D2). Escribe '
  'TODAS las asignaciones equivalentes a través del pivot en un FOREACH -- '
  'el espejo (account_members.role) converge sólo tras el ÚLTIMO insert '
  'del loop, vía trg_touch_account_member_role + trg_derive_account_'
  'member_role (Parte A). D18: cupo P0001->P0402 (mismo código que '
  'rpc_invite_member). Ronda 1 adversarial (finding NIT): "invalid or '
  'expired invitation token" P0001->P0404 y "already a member" '
  'P0001->P0409, texto conservado. "Not authenticated" SIGUE P0001.';


-- -----------------------------------------------------------------------------
-- 4. rpc_create_branch(uuid, text, text) -- ronda 3 adversarial (finding
--    MINOR, 2026-09-12): MISMA clase de bug que las 3 funciones de arriba,
--    misma migración -- gateaba `max_branches`/`has_branches_module` contra
--    `accounts.billing_plan` crudo. Toda cuenta nueva (gratis + trial pro
--    vigente, billing-pro-trial) tenía el módulo de sucursales APAGADO
--    (has_branches_module=false del plan crudo 'gratis') pese a que su plan
--    EFECTIVO (pro) lo habilita -- mismo cohorte de trial que el bug 1 de
--    arriba. Medido en PROD (read-only, mcp__supabase__execute_sql,
--    replicando la lógica de get_effective_plan sin poder ejecutarla -- el
--    rol de sólo lectura no tiene EXECUTE sobre ella): 24 de 39 cuentas con
--    has_branches_module=false/max_branches=1 por el plan crudo y
--    true/3 por el efectivo.
--
--    Integridad de función -- cuerpo VIVO de prod verificado el 2026-09-12
--    vía mcp__supabase__execute_sql (read-only), md5 normalizado (\r\n ->
--    \n): rpc_create_branch(uuid, text, text) = 073b8cb0f892c72e3e8676afc5fa9f65
--    -- IDÉNTICO en LOCAL (post 20261014000001_sucursal_guard_vaciado_
--    auditoria.sql) y en PROD -- este bloque reescribe DESDE ESE CUERPO, con
--    la única línea de plan efectivo agregada. ACLs preservadas por CREATE
--    OR REPLACE (misma firma, sin DROP): {postgres=X, authenticated=X,
--    service_role=X} en ambos lados, sin anon, verificado igual antes de
--    tocarla.
--
--    Único cambio de comportamiento: `v_plan := public.get_effective_plan(
--    p_account_id)` en vez de `JOIN public.plan_limits pl ON pl.plan =
--    a.billing_plan`. Mismo helper canónico que las 3 funciones de arriba y
--    que reporting_plan_window/rpc_import_products -- sin GRANT adicional
--    (SECURITY DEFINER, owner postgres).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_create_branch(p_account_id uuid, p_name text, p_address text DEFAULT NULL::text)
 RETURNS branches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plan            TEXT;
  v_max_branches    INTEGER;
  v_has_module      BOOLEAN;
  v_active_count    INTEGER;
  v_new_branch      public.branches;
BEGIN
  -- Verify caller belongs to this account
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Verify caller is writer (owner or admin)
  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can create branches'
      USING ERRCODE = 'P0401';
  END IF;

  -- Get plan limits -- membership-quota-effective-plan (hallazgo lateral
  -- MINOR, ronda 3 adversarial, 2026-09-12): plan EFECTIVO
  -- (public.get_effective_plan), no accounts.billing_plan crudo -- mismo
  -- motivo que rpc_invite_member/rpc_accept_invitation (ver arriba en este
  -- mismo archivo).
  v_plan := public.get_effective_plan(p_account_id);

  SELECT
    pl.max_branches,
    pl.has_branches_module
  INTO v_max_branches, v_has_module
  FROM public.plan_limits pl
  WHERE pl.plan = v_plan;

  IF NOT FOUND OR NOT v_has_module THEN
    RAISE EXCEPTION 'branch_limit_exceeded: branches module requires pro plan'
      USING ERRCODE = 'P0403';
  END IF;

  -- Count active branches
  SELECT COUNT(*) INTO v_active_count
  FROM public.branches
  WHERE account_id = p_account_id
    AND is_active  = TRUE;

  IF v_active_count >= v_max_branches THEN
    RAISE EXCEPTION 'branch_limit_exceeded: plan allows % branches, account has %',
      v_max_branches, v_active_count
      USING ERRCODE = 'P0403';
  END IF;

  -- Insert (UNIQUE constraint handles duplicate names)
  -- sucursal-guard-vaciado-auditoria (G2, D6): created_by = identidad en curso.
  BEGIN
    INSERT INTO public.branches (account_id, name, address, created_by)
    VALUES (p_account_id, p_name, p_address, auth.uid())
    RETURNING * INTO v_new_branch;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'branch_name_duplicate: a branch named % already exists in this account', p_name
        USING ERRCODE = 'P0409';
  END;

  RETURN v_new_branch;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_branch(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_branch(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_branch(uuid, text, text) IS
  'C-07 (sucursales-module-pro), redefinida por sucursal-guard-vaciado-'
  'auditoria (G2, created_by) y por membership-quota-effective-plan (ronda '
  '3 adversarial, 2026-09-12, hallazgo lateral MINOR): el cupo/módulo de '
  'sucursales se evalúa contra el plan EFECTIVO (public.get_effective_plan), '
  'no accounts.billing_plan crudo -- misma clase de bug y misma migración '
  'que rpc_invite_member/rpc_accept_invitation. Firma sin cambios. Candado: '
  'supabase/tests/test_sucursal_guard_vaciado.sql (G3a/G3b) + bloque (16) de '
  'supabase/tests/test_invite_member_roles_and_plan_gate.sql.';


-- =============================================================================
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--          md5(replace(pg_get_functiondef(p.oid), E'\r\n', E'\n')) AS md5_norm
--   FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
--     AND p.proname IN ('rpc_invite_member','rpc_accept_invitation','rpc_create_branch')
--   ORDER BY p.proname, p.pronargs;
--   -- las 4 deben mostrar `public.get_effective_plan(` en el cuerpo y CERO
--   -- apariciones de `billing_plan` fuera de comentario (ver gate SQL
--   -- (16) en test_invite_member_roles_and_plan_gate.sql).
--
--   SELECT p.proacl FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
--     AND p.proname IN ('rpc_invite_member','rpc_accept_invitation','rpc_create_branch');
--   -- ACLs sin cambios: {postgres=X, authenticated=X, service_role=X} en
--   -- las 4, idénticas a antes de este archivo.
-- =============================================================================
