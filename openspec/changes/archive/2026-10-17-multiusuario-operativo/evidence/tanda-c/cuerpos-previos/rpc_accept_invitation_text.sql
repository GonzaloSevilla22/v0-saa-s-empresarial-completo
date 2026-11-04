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
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'P0001';
  END IF;

  -- auth-hardening-jwt-cookies (D14, F13): identidad del aceptante para el
  -- binding de email. Se resuelve contra auth.users y NO contra el claim: el
  -- backend propio empuja a Postgres sólo {"sub","role"}
  -- (backend/core/database.py:116 y :174), sin email, así que un guard
  -- keyeado en el claim rechazaría el 100% de las aceptaciones que lleguen
  -- por FastAPI. El claim se usa como atajo equivalente cuando está
  -- presente (camino PostgREST).
  v_caller_email := COALESCE(
    auth.jwt()->>'email',
    (SELECT u.email FROM auth.users u WHERE u.id = v_caller_id)
  );

  -- auth-hardening-jwt-cookies (D14): FOR UPDATE -- lock de la fila ANTES de
  -- validar estado y vigencia. Dos aceptaciones concurrentes del mismo token
  -- ya no pueden observar ambas el estado pendiente: la segunda espera acá y,
  -- al commitear la primera, su predicado status='pending' deja de matchear.
  SELECT *
  INTO   v_inv
  FROM   public.account_invitations
  WHERE  token     = p_token
    AND  status    = 'pending'
    AND  expires_at > now()
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    -- Ronda 1 adversarial (finding NIT): P0001 -> P0404, texto conservado --
    -- mismo criterio D18 que el resto de esta migración (regla dura del
    -- proyecto: ERRCODEs P04xx del catálogo, nunca P0001, para un 404/409
    -- con mapeo obvio).
    RAISE EXCEPTION 'P404: invalid or expired invitation token'
      USING ERRCODE = 'P0404';
  END IF;

  -- auth-hardening-jwt-cookies (D14, F13): la invitación es de quien la
  -- recibió. Comparación insensible a mayúsculas en ambos lados; MISMO
  -- ERRCODE y MISMO texto que el rechazo por token inexistente/vencido, para
  -- que la respuesta no confirme que el token es válido para otra identidad.
  --
  -- Fail-closed por los DOS lados, y el de la invitación NO es decorativo
  -- (revisión adversarial del grupo 10, hallazgo MEDIDO en la base local):
  -- sin `v_inv.email IS NULL` explícito, una invitación con email NULL hacía
  -- que `lower(v_inv.email) <> lower(v_caller_email)` evaluara a NULL —
  -- lógica de tres valores — la condición del IF quedara NULL, la rama NO se
  -- tomara, y **un desconocido entrara a la cuenta**. Reproducido: aflojando
  -- el NOT NULL en local, `rpc_accept_invitation` le devolvió membresía con
  -- rol a un usuario ajeno al email invitado.
  -- `account_invitations.email` es NOT NULL en prod (re-verificado hoy), así
  -- que hoy esa fila no puede existir y esta cláusula es inalcanzable. Se
  -- declara igual porque lo que estaba en juego no era el caso, era la
  -- DIRECCIÓN en que degrada el guard si ese constraint se cayera algún día:
  -- un guard de auth debe fallar cerrado, no abierto, y la cláusula cuesta
  -- una línea. Candado: bloque (8) de test_accept_invitation_binding.sql.
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

-- ACL/COMMENT vivos:
-- ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- COMMENT: auth-hardening-jwt-cookies Parte A (D14, hallazgo F13 de la auditoría del 2026-09-14): la aceptación exige que la identidad autenticada corresponda al email de la invitación (comparación con lower() en ambos lados), con el email del aceptante resuelto por COALESCE(auth.jwt()->>'email', SELECT email FROM auth.users WHERE id = auth.uid()) -- contra auth.users y NO sólo contra el claim, porque el backend propio empuja a Postgres sólo {"sub","role"} (backend/core/database.py:116 y :174) y un guard keyeado en el claim rechazaría toda aceptación que llegue por FastAPI. El rechazo usa el MISMO contrato que el token inexistente/vencido (P0404 + "P404: invalid or expired invitation token") para no confirmar que el token es válido para otra identidad. El rechazo es fail-closed por los DOS lados (email del aceptante NULL y email de la invitación NULL): sin la comprobación explícita de NULL sobre la invitación, la lógica de tres valores dejaba la condición en NULL y el guard degradaba FAIL-OPEN -- medido en la base local, no hipotético. Y la fila de la invitación se toma con SELECT ... FOR UPDATE ANTES de validar estado y vigencia, así que dos aceptaciones concurrentes del mismo token no pueden observar ambas el estado pendiente. Candado: supabase/tests/test_accept_invitation_binding.sql. — membership-quota-effective-plan (humo v3-rbac-multirole, bug 1, 2026-09-12): el cupo se evalúa contra el plan EFECTIVO de la cuenta de la invitación (public.get_effective_plan), no accounts.billing_plan crudo -- debe coincidir con el efectivo que ya evalúa rpc_invite_member al invitar. Acepta CUALQUIER conjunto de roles, lee account_invitations.roles si está poblada (overload de 3 args), si no deriva del `role` legacy (overload de 2 args / fila pre-migración, mismo mapeo D2). Escribe TODAS las asignaciones equivalentes a través del pivot en un FOREACH -- el espejo (account_members.role) converge sólo tras el ÚLTIMO insert del loop, vía trg_touch_account_member_role + trg_derive_account_member_role (Parte A). D18: cupo P0001->P0402 (mismo código que rpc_invite_member). Ronda 1 adversarial (finding NIT): "invalid or expired invitation token" P0001->P0404 y "already a member" P0001->P0409, texto conservado. "Not authenticated" SIGUE P0001.
