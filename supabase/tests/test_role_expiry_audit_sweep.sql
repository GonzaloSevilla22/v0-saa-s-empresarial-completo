-- =============================================================================
-- GATE: test_role_expiry_audit_sweep.sql
-- CHANGE: v3-rbac-multirole Parte B, grupo 12 (D16) — barrido diario de
-- vencimientos de rol.
--
--   (1) idempotencia (12.1): reejecutar el barrido no agrega un SEGUNDO
--       registro role.expired para la MISMA asignación.
--   (2) no borra ni cambia permisos (12.2): la fila del pivot sigue
--       existiendo IDÉNTICA (mismo role/expires_at/member_id) después del
--       barrido -- sólo se agregó la entrada de auditoría.
--   (3) el corte lo produce el PREDICADO, no el cron (12.3): con el
--       barrido nunca ejecutado (0 corridas), un rol YA vencido sigue sin
--       autorizar nada -- is_account_writer/member_active_roles ya lo
--       excluyen por sí solos.
--   (4) un rol VIGENTE (no vencido) nunca genera un registro role.expired
--       -- control negativo de (1)/(3), para que no sean una tautología.
--
-- Degrade-don't-fail si no hay auth.users para anclar el fixture.
-- =============================================================================
DO $$
DECLARE
  v_anchor_user  uuid;
  v_account_a    uuid := gen_random_uuid();
  v_member_a     uuid;
  v_role_id      uuid;
  v_role_id_2    uuid;
  v_n_first      int;
  v_n_second     int;
  v_row_before   record;
  v_row_after    record;
  v_writer       boolean;
  v_blocks_run   int := 0;
  v_expected     int := 4;
BEGIN
  SELECT id INTO v_anchor_user FROM auth.users LIMIT 1;
  IF v_anchor_user IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: no hay ningún auth.users para anclar el fixture -- se omite el gate completo.';
    RETURN;
  END IF;

  INSERT INTO public.accounts (id, owner_user_id) VALUES (v_account_a, v_anchor_user);
  INSERT INTO public.account_members (id, account_id, user_id, role)
    VALUES (gen_random_uuid(), v_account_a, v_anchor_user, 'member')
    ON CONFLICT (account_id, user_id) DO UPDATE SET role = EXCLUDED.role
    RETURNING id INTO v_member_a;

  -- is_account_writer() lee auth.uid() (D11) -- impersonar al anchor para
  -- que el control (3)/(3b) sea real, no un false-negativo por auth.uid()
  -- NULL (mismo mecanismo que test_is_account_writer_pivot.sql).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_anchor_user::text, 'role', 'authenticated')::text, true);

  -- Asignación YA VENCIDA (seller, expiró hace 1 día) + una VIGENTE (stock).
  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at, expires_at)
  VALUES (v_account_a, v_member_a, 'seller', now() - INTERVAL '10 days', now() - INTERVAL '1 day')
  RETURNING id INTO v_role_id;

  INSERT INTO public.account_member_roles (account_id, member_id, role, assigned_at)
  VALUES (v_account_a, v_member_a, 'stock', now())
  RETURNING id INTO v_role_id_2;

  SELECT * INTO v_row_before FROM public.account_member_roles WHERE id = v_role_id;

  -- (3) el corte lo produce el predicado, NO el cron -- el barrido
  -- TODAVÍA no corrió ni una vez en este fixture, y el rol vencido YA no
  -- autoriza nada (member_active_roles lo excluye por sí solo, D4).
  IF 'seller' = ANY(public.member_active_roles(v_member_a)) THEN
    RAISE EXCEPTION 'GATE FAILED (3): el rol vencido sigue apareciendo como ACTIVO sin que el barrido haya corrido nunca -- el corte no debe depender del cron';
  END IF;
  SELECT public.is_account_writer(v_account_a) INTO v_writer;
  -- stock SÍ es writer (is_writer=true en el catálogo) -- is_account_writer
  -- debe seguir dando true por el rol VIGENTE (stock), no por el vencido.
  IF v_writer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE FAILED (3b): is_account_writer debía ser true por el rol vigente (stock), independiente del vencido, dio %', v_writer;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3): el rol vencido ya no autoriza (predicado D4), con el barrido en 0 corridas.';

  -- (1) primera corrida: agrega EXACTAMENTE 1 registro role.expired (para
  -- el vencido) -- 0 para el vigente.
  SELECT public._produce_role_expiry_audit_sweep() INTO v_n_first;
  IF v_n_first <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1a): la primera corrida debía auditar exactamente 1 vencimiento (el fixture tiene 1 vencido + 1 vigente), auditó %', v_n_first;
  END IF;

  IF (SELECT count(*) FROM public.audit_logs WHERE entity_type = 'account_member_role' AND entity_id = v_role_id AND action = 'role.expired') <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1b): no se encontró exactamente 1 entrada role.expired para la asignación vencida';
  END IF;

  -- (4) control negativo: el VIGENTE (stock) NUNCA generó una entrada.
  IF EXISTS (SELECT 1 FROM public.audit_logs WHERE entity_type = 'account_member_role' AND entity_id = v_role_id_2 AND action = 'role.expired') THEN
    RAISE EXCEPTION 'GATE FAILED (4): el rol VIGENTE (stock) generó una entrada role.expired -- no debía';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (1)/(4): la primera corrida audita el vencido (y sólo el vencido) -- 1 entrada role.expired.';

  -- (1) segunda corrida: idempotencia -- 0 nuevas para la MISMA asignación.
  SELECT public._produce_role_expiry_audit_sweep() INTO v_n_second;

  IF (SELECT count(*) FROM public.audit_logs WHERE entity_type = 'account_member_role' AND entity_id = v_role_id AND action = 'role.expired') <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1c): reejecutar el barrido agregó un SEGUNDO registro role.expired para la misma asignación';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (1): idempotencia -- % vencimientos en la 2da corrida (dedup por asignación, nunca un 2º registro para la misma).', v_n_second;

  -- (2) no borra la fila del pivot ni cambia sus datos.
  SELECT * INTO v_row_after FROM public.account_member_roles WHERE id = v_role_id;
  IF v_row_after IS NULL THEN
    RAISE EXCEPTION 'GATE FAILED (2a): el barrido BORRÓ la fila del pivot -- D16 dice que audita, no borra';
  END IF;
  IF v_row_after.role <> v_row_before.role
     OR v_row_after.member_id <> v_row_before.member_id
     OR v_row_after.expires_at <> v_row_before.expires_at
  THEN
    RAISE EXCEPTION 'GATE FAILED (2b): el barrido modificó datos de la fila (role/member_id/expires_at)';
  END IF;
  -- tampoco tocó permisos: is_account_writer sigue dando true por 'stock'.
  SELECT public.is_account_writer(v_account_a) INTO v_writer;
  IF v_writer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GATE FAILED (2c): el barrido cambió el resultado de is_account_writer -- sólo debe auditar';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2): el barrido no borra la fila del pivot ni cambia ningún permiso -- sólo audita.';

  -- Cleanup
  DELETE FROM public.audit_logs WHERE entity_type = 'account_member_role' AND entity_id IN (v_role_id, v_role_id_2);
  DELETE FROM public.account_member_roles WHERE member_id = v_member_a;
  DELETE FROM public.account_members WHERE id = v_member_a;
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE id = v_account_a;
  SET session_replication_role = DEFAULT;

  IF v_blocks_run <> v_expected THEN
    RAISE EXCEPTION 'GATE ROLE-EXPIRY-AUDIT-SWEEP FAILED (conteo): % de % bloques.', v_blocks_run, v_expected;
  END IF;

  RAISE NOTICE 'GATE ROLE-EXPIRY-AUDIT-SWEEP: %/% bloques PASS.', v_blocks_run, v_expected;
EXCEPTION
  WHEN OTHERS THEN
    SET session_replication_role = DEFAULT;
    DELETE FROM public.audit_logs WHERE entity_type = 'account_member_role' AND entity_id IN (v_role_id, v_role_id_2);
    DELETE FROM public.account_member_roles WHERE member_id = v_member_a;
    DELETE FROM public.account_members WHERE id = v_member_a;
    SET session_replication_role = replica;
    DELETE FROM public.accounts WHERE id = v_account_a;
    SET session_replication_role = DEFAULT;
    RAISE;
END $$;
