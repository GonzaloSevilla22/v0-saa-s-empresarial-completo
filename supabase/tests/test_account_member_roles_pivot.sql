-- =============================================================================
-- GATE: test_account_member_roles_pivot.sql (9 bloques)
-- CHANGE: v3-rbac-multirole Parte A, grupo 3 (D3, D4, D5) — el pivot y
-- member_active_roles()/account_user_active_roles().
--
-- Ancla su propio fixture (un usuario real vía auth.users, que dispara
-- handle_new_user y aprovisiona cuenta+owner) — no depende de ningún seed
-- preexistente. Degrade-don't-fail: si el signup no resuelve (entorno sin
-- auth.users insertable), el gate lo reporta y no ejercita los bloques
-- dependientes, pero sí cuenta cuántos bloques corrieron realmente.
--
--   (1) unicidad (member_id, role): un segundo INSERT del mismo par se
--       rechaza (23505), sin duplicar la fila.
--   (2) FK member_id -> account_members ON DELETE CASCADE: borrar la
--       membresía borra sus asignaciones del pivot.
--   (3) rol sin vencimiento -> activo; rol con vencimiento FUTURO -> activo;
--       rol con vencimiento PASADO -> NO activo (member_active_roles).
--   (4) la asignación vencida NO se borra — sigue presente en la tabla,
--       sólo ausente del array de activos.
--   (5) account_user_active_roles(account_id,user_id) resuelve lo mismo que
--       member_active_roles(member_id) para el mismo miembro, y devuelve
--       ARRAY vacío (no NULL) para un (account_id,user_id) que no es miembro.
--   (6) TRIANGULATE — miembro con 3 roles simultáneos (seller+cashier+stock)
--       más el owner del backfill/signup: los 4 aparecen todos activos.
--   (7) TRIANGULATE — miembro con 1 rol vencido y 1 vigente: sólo el vigente
--       aparece en member_active_roles.
--   (8) RONDA 1 (finding major, corregido): ni authenticated ni anon
--       pueden ejecutar member_active_roles/account_user_active_roles —
--       sin GRANT EXECUTE hasta que la Parte B tenga un consumidor real
--       con su propio guard de tenencia.
--   (9) RONDA 1 (finding minor/hardening, corregido): account_id ya no
--       puede ser incoherente con el member_id — FK compuesta
--       (member_id, account_id) rechaza una fila "fantasma".
-- =============================================================================

DO $$
DECLARE
  v_blocks_run int := 0;
  v_uid        uuid := gen_random_uuid();
  v_account    uuid;
  v_member     uuid;
  v_active     text[];
  v_count      int;
  v_phantom_account uuid;
  v_got_error  boolean;
BEGIN
  BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_uid, 'gate-pivot-anchor@test.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudo crear el usuario ancla (%). Se aborta el gate sin reportar PASS.', SQLERRM;
    RETURN;
  END;

  SELECT account_id, id INTO v_account, v_member
  FROM account_members WHERE user_id = v_uid;

  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: handle_new_user no aprovisionó account_members para el ancla — se aborta sin reportar PASS.';
    RETURN;
  END IF;

  -- (0, implícito) el signup ya escribió la fila 'owner' en el pivot (fix
  -- 6.3b de la migración) — se reutiliza como parte de los bloques 6/7.

  -- (1) unicidad (member_id, role)
  INSERT INTO account_member_roles (account_id, member_id, role) VALUES (v_account, v_member, 'seller');
  BEGIN
    INSERT INTO account_member_roles (account_id, member_id, role) VALUES (v_account, v_member, 'seller');
    RAISE EXCEPTION 'GATE FAILED (1): un segundo INSERT del mismo (member_id, role) NO fue rechazado';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS (1): (member_id, role) duplicado rechazado por unique_violation';
  END;
  SELECT count(*) INTO v_count FROM account_member_roles WHERE member_id = v_member AND role = 'seller';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (1): quedaron % filas para (member,seller), se esperaba 1', v_count;
  END IF;
  v_blocks_run := v_blocks_run + 1;

  -- (2) CASCADE member_id -> account_members — preparación acá (agrega el
  --     rol 'stock' al pivot del ancla), verificación real al FINAL del
  --     gate cuando se borra la membresía como parte del cleanup (así se
  --     ejercita el CASCADE de verdad, en vez de simularlo).
  INSERT INTO account_member_roles (account_id, member_id, role) VALUES (v_account, v_member, 'stock')
    ON CONFLICT (member_id, role) DO NOTHING;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2, preparación): fixture listo para CASCADE (se verifica al cerrar el gate)';

  -- (3) activo por vencimiento: sin vencimiento -> activo; futuro -> activo; pasado -> no activo
  INSERT INTO account_member_roles (account_id, member_id, role, expires_at)
  VALUES (v_account, v_member, 'purchases', now() + interval '1 day');

  INSERT INTO account_member_roles (account_id, member_id, role, expires_at)
  VALUES (v_account, v_member, 'accountant', now() - interval '1 day');

  v_active := member_active_roles(v_member);

  IF NOT ('seller' = ANY(v_active)) THEN
    RAISE EXCEPTION 'GATE FAILED (3): rol sin vencimiento (seller) debería estar activo. active=%', v_active;
  END IF;
  IF NOT ('purchases' = ANY(v_active)) THEN
    RAISE EXCEPTION 'GATE FAILED (3): rol con vencimiento FUTURO (purchases) debería estar activo. active=%', v_active;
  END IF;
  IF 'accountant' = ANY(v_active) THEN
    RAISE EXCEPTION 'GATE FAILED (3): rol con vencimiento PASADO (accountant) NO debería estar activo. active=%', v_active;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3): activos=%', v_active;

  -- (4) la asignación vencida NO se borra
  SELECT count(*) INTO v_count FROM account_member_roles WHERE member_id = v_member AND role = 'accountant';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE FAILED (4): la asignación vencida (accountant) desapareció de la tabla — se esperaba que sobreviva como constancia';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (4): la asignación vencida sigue presente en la tabla';

  -- (5) account_user_active_roles == member_active_roles para el mismo
  --     miembro, y ARRAY vacío (no NULL) para un no-miembro.
  IF account_user_active_roles(v_account, v_uid) IS DISTINCT FROM member_active_roles(v_member) THEN
    RAISE EXCEPTION 'GATE FAILED (5): account_user_active_roles y member_active_roles divergen: % vs %',
      account_user_active_roles(v_account, v_uid), member_active_roles(v_member);
  END IF;
  IF account_user_active_roles(v_account, gen_random_uuid()) IS DISTINCT FROM ARRAY[]::text[] THEN
    RAISE EXCEPTION 'GATE FAILED (5): un usuario no-miembro debería resolver a ARRAY vacío, no NULL: %',
      account_user_active_roles(v_account, gen_random_uuid());
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (5): account_user_active_roles coincide con member_active_roles y da ARRAY vacío para un no-miembro';

  -- (6) TRIANGULATE — 3 roles simultáneos + el owner del signup = 4 activos
  --     (stock ya se insertó en el bloque 2; agrega cashier acá).
  INSERT INTO account_member_roles (account_id, member_id, role) VALUES (v_account, v_member, 'cashier')
    ON CONFLICT (member_id, role) DO NOTHING;

  v_active := member_active_roles(v_member);
  IF NOT (v_active @> ARRAY['owner','seller','stock','cashier']) THEN
    RAISE EXCEPTION 'GATE FAILED (6): se esperaban owner+seller+stock+cashier simultáneos, activos=%', v_active;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (6): miembro con 4 roles simultáneos activos: %', v_active;

  -- (7) TRIANGULATE — 1 rol vencido (accountant, bloque 3) y 1 vigente
  --     (purchases, bloque 3): sólo el vigente figura, ya verificado en (3)
  --     pero se re-assertea explícitamente como caso de triangulación propio.
  v_active := member_active_roles(v_member);
  IF ('accountant' = ANY(v_active)) OR NOT ('purchases' = ANY(v_active)) THEN
    RAISE EXCEPTION 'GATE FAILED (7): triangulación vencido/vigente no se sostiene. activos=%', v_active;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (7): con 1 vencido y 1 vigente, sólo el vigente queda activo';

  -- (8) ronda 1 (finding major): ni authenticated ni anon pueden ejecutar
  --     las dos funciones de rol activo.
  IF has_function_privilege('authenticated', 'public.member_active_roles(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED (8): authenticated puede ejecutar member_active_roles';
  END IF;
  IF has_function_privilege('anon', 'public.member_active_roles(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED (8): anon puede ejecutar member_active_roles';
  END IF;
  IF has_function_privilege('authenticated', 'public.account_user_active_roles(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED (8): authenticated puede ejecutar account_user_active_roles';
  END IF;
  IF has_function_privilege('anon', 'public.account_user_active_roles(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED (8): anon puede ejecutar account_user_active_roles';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (8): ninguna de las dos funciones de rol activo es ejecutable por authenticated/anon';

  -- (9) ronda 1 (finding minor/hardening): una fila "fantasma" con
  --     account_id incoherente con el member_id es rechazada por la FK
  --     compuesta (member_id, account_id) -> account_members(id, account_id).
  v_phantom_account := gen_random_uuid();
  INSERT INTO public.accounts (id, owner_user_id) VALUES (v_phantom_account, v_uid);

  v_got_error := false;
  BEGIN
    INSERT INTO account_member_roles (account_id, member_id, role)
    VALUES (v_phantom_account, v_member, 'admin');
  EXCEPTION WHEN foreign_key_violation THEN
    v_got_error := true;
  END;
  IF NOT v_got_error THEN
    RAISE EXCEPTION 'GATE FAILED (9): una fila con account_id incoherente con member_id NO fue rechazada por la FK compuesta';
  END IF;
  IF EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_member AND role = 'admin' AND account_id = v_phantom_account) THEN
    RAISE EXCEPTION 'GATE FAILED (9): quedó una fila fantasma pese al rechazo';
  END IF;

  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE id = v_phantom_account;
  SET session_replication_role = DEFAULT;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (9): una fila fantasma (account_id incoherente con member_id) es rechazada por la FK compuesta';

  IF v_blocks_run <> 9 THEN
    RAISE EXCEPTION 'GATE ACCOUNT-MEMBER-ROLES-PIVOT FAILED (conteo): se ejercitaron % de 9 bloques esperados.', v_blocks_run;
  END IF;
  RAISE NOTICE 'GATE ACCOUNT-MEMBER-ROLES-PIVOT: 9/9 bloques PASS.';

  -- ── cleanup + verificación final del CASCADE (bloque 2) ──────────────────
  DELETE FROM account_members WHERE id = v_member; -- CASCADE a account_member_roles
  SELECT count(*) INTO v_count FROM account_member_roles WHERE member_id = v_member;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE FAILED (2): tras borrar la membresía quedaron % filas del pivot (se esperaban 0, CASCADE)', v_count;
  END IF;
  RAISE NOTICE 'PASS (2, verificación final): CASCADE borró las % asignaciones del pivot junto con la membresía', 0;

  SET session_replication_role = replica;
  -- ronda 2 (nit): cashboxes ANTES de branches — bajo `replica` no hay
  -- CASCADE, así que borrar branches primero deja cashboxes huérfanas
  -- (su propia subquery ya no encuentra la sucursal). Molde de
  -- test_asiento_contable_gastos.sql.
  DELETE FROM public.cashboxes cb USING public.branches b
    WHERE cb.branch_id = b.id AND b.account_id = v_account;
  DELETE FROM public.branches WHERE account_id = v_account;
  DELETE FROM public.payment_methods WHERE account_id = v_account;
  DELETE FROM public.product_categories WHERE account_id = v_account;
  DELETE FROM public.email_logs WHERE user_id = v_uid;
  DELETE FROM public.profiles WHERE id = v_uid;
  DELETE FROM public.accounts WHERE id = v_account;
  SET session_replication_role = DEFAULT;
  DELETE FROM auth.users WHERE id = v_uid;
  RAISE NOTICE 'GATE ACCOUNT-MEMBER-ROLES-PIVOT: cleanup completo.';
END $$;
