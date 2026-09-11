-- =============================================================================
-- GATE: test_account_owner_invariant.sql (14 bloques)
-- CHANGE: v3-rbac-multirole Parte A, grupo 4 (D3, D5, D6, D7) — invariante de
-- propietario único, owner sin vencimiento, espejo y auditoría.
--
-- GOTCHA (design R9/D6, task 4.9): este gate NO puede correr bajo
-- `session_replication_role = replica` — desactiva TODOS los triggers,
-- constraint triggers incluidos, y el invariante de la sección (1)-(4) es
-- precisamente uno. El cleanup de este archivo usa `replica` sólo para
-- `branches`/`cashboxes` (por trg_guard_branch_decommission, no relacionado
-- a este invariante) y lo hace DESPUÉS de que todas las aserciones ya
-- corrieron.
--
--   (1) revocar el único owner (DELETE de su fila en el pivot) es rechazado
--       con P0405, y la cuenta conserva su propietario (rollback completo).
--   (2) transferir la propiedad (revocar a A + asignar a B en la MISMA
--       transacción) se completa sin error.
--   (3) vaciar una cuenta por completo (borrar todas sus membresías) no es
--       bloqueado por el invariante — se satisface de forma vacua.
--   (4) la garantía no depende del procedimiento: un DELETE directo sobre el
--       pivot (sin pasar por ningún RPC) se rechaza igual que (1).
--   (5) asignar owner CON expires_at es rechazado con P0406; sin vencimiento
--       se acepta.
--   (6) el espejo: account_members.role ≡ precedencia(pivot) siempre, y un
--       intento de escribir la columna directamente queda revertido.
--   (7) auditoría: una asignación deja role.assigned en audit_logs con
--       cuenta/autor/miembro/rol; una revocación deja role.revoked.
--   (8) TRIANGULATE — degradar a admin (sin owner) con OTRO owner presente
--       se acepta (el invariante no sobre-bloquea cuando SÍ hay reemplazo).
--   (9) candado de cuerpo — fn_guard_account_owner_invariant es un
--       CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED (si alguien lo
--       reescribe como trigger normal, el gate de transferencia (2) fallaría
--       antes que éste, pero este candado lo hace explícito y rápido de
--       diagnosticar).
--   (10) candado — un UPDATE que degrada directamente el rol del único
--       owner (sin mover cuenta) sigue rechazado con P0405 (ya funcionaba
--       antes de la ronda 2; no dependía del bug de (12)).
--   (11) RONDA 2 (finding MAJOR, corregido): un UPDATE que mueve member_id
--       DENTRO de la MISMA cuenta re-deriva el espejo de AMBAS membresías
--       (origen Y destino) — antes, fn_touch_account_member_role sólo
--       tocaba el destino (NEW) y el origen quedaba con el rol viejo.
--   (12) RONDA 2 (finding MAJOR, corregido): un UPDATE que mueve la fila
--       owner a OTRA cuenta (member_id + account_id cambian juntos) se
--       rechaza con P0405 — antes, fn_guard_account_owner_invariant sólo
--       miraba NEW.account_id (destino) e ignoraba OLD (origen), así que
--       la cuenta de origen podía quedar con miembros y CERO owners sin
--       ningún error (reproducido en una transacción aislada y COMMITEADA).
--   (13) RONDA 3 (finding MINOR-1) — cobertura que faltaba de las "cuatro
--       formas" que pide la task 4.1: un DELETE sobre `account_members`
--       (no sobre el pivot) que borra la membresía completa del único
--       owner, conservando otro miembro en la cuenta, es rechazado con
--       P0405 igual que (1) — el `ON DELETE CASCADE` hacia el pivot
--       dispara el MISMO constraint trigger diferido (molde del bloque (1),
--       comportamiento ya correcto, sólo faltaba el gate).
--   (14) RONDA 3 (finding MINOR-3) — auditoría de UPDATE del pivot:
--       `role.updated` en `audit_logs` con el snapshot OLD/NEW (member_id,
--       account_id, role, expires_at), ejercitado con un UPDATE de
--       `expires_at` que no toca el invariante de propietario.
-- =============================================================================

DO $$
DECLARE
  v_blocks_run int := 0;
  v_uid_a      uuid := gen_random_uuid();
  v_uid_b      uuid := gen_random_uuid();
  v_uid_c      uuid := gen_random_uuid();
  v_account    uuid;
  v_member_a   uuid;
  v_member_b   uuid;
  v_account_b_own  uuid;
  v_member_b_own   uuid;
  v_member_c_in_b  uuid;
  v_got_error  boolean;
  v_audit_count int;
  v_audit_metadata jsonb;
BEGIN
  BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_uid_a, 'gate-owner-invariant-a@test.local');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'GATE DEGRADED: no se pudo crear el usuario ancla A (%). Se aborta el gate.', SQLERRM;
    RETURN;
  END;

  SELECT account_id, id INTO v_account, v_member_a FROM account_members WHERE user_id = v_uid_a;
  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE DEGRADED: handle_new_user no aprovisionó la cuenta ancla. Se aborta el gate.';
    RETURN;
  END IF;

  -- Segundo miembro, mismo tenant (member por defecto).
  INSERT INTO auth.users (id, email) VALUES (v_uid_b, 'gate-owner-invariant-b@test.local');
  -- handle_new_user le crea SU PROPIA cuenta a B (siempre aprovisiona una
  -- cuenta nueva por signup) — se lo agrega ADEMÁS a la cuenta de A a mano,
  -- como haría rpc_accept_invitation.
  INSERT INTO account_members (id, account_id, user_id, role)
  VALUES (gen_random_uuid(), v_account, v_uid_b, 'member')
  RETURNING id INTO v_member_b;

  -- Cuenta PROPIA de B (auto-provisionada por su propio signup) + un tercer
  -- usuario C agregado como member de ESA cuenta — fixture para el bloque
  -- (12), que necesita una SEGUNDA cuenta real con un miembro sin rol owner
  -- para reproducir el movimiento cross-account del hallazgo de ronda 2.
  SELECT account_id, id INTO v_account_b_own, v_member_b_own
  FROM account_members WHERE user_id = v_uid_b AND account_id <> v_account;

  INSERT INTO auth.users (id, email) VALUES (v_uid_c, 'gate-owner-invariant-c@test.local');
  INSERT INTO account_members (id, account_id, user_id, role)
  VALUES (gen_random_uuid(), v_account_b_own, v_uid_c, 'member')
  RETURNING id INTO v_member_c_in_b;

  -- ── (1) revocar el único owner es rechazado ─────────────────────────────
  -- El chequeo es DIFERIDO (D6): no alcanza con hacer el DELETE, hay que
  -- forzar la evaluación con SET CONSTRAINTS ... IMMEDIATE dentro de la
  -- misma subtransacción (BEGIN/EXCEPTION = SAVEPOINT implícito de
  -- PL/pgSQL) para verlo fallar SIN esperar al commit final del gate.
  v_got_error := false;
  BEGIN
    DELETE FROM account_member_roles WHERE member_id = v_member_a AND role = 'owner';
    SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  EXCEPTION WHEN SQLSTATE 'P0405' THEN
    v_got_error := true;
  END;

  IF NOT v_got_error THEN
    RAISE EXCEPTION 'GATE FAILED (1): revocar el único owner no fue rechazado con P0405';
  END IF;

  -- El rollback a la subtransacción deshizo el DELETE (y el modo de
  -- constraints, que también es transaccional). Verificar que la cuenta
  -- conserva su owner.
  IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_member_a AND role = 'owner') THEN
    RAISE EXCEPTION 'GATE FAILED (1): tras el rechazo, la cuenta debía conservar su owner y no lo conserva';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (1): revocar el único owner rechazado con P0405, owner conservado';

  -- ── (2) transferir la propiedad en la misma transacción se completa ────
  DELETE FROM account_member_roles WHERE member_id = v_member_a AND role = 'owner';
  INSERT INTO account_member_roles (account_id, member_id, role, assigned_by)
  VALUES (v_account, v_member_b, 'owner', v_uid_a);
  -- si el invariante disparara acá, esta misma sentencia top-level fallaría
  -- al llegar al implicit-commit del bloque DO al finalizar todo el script;
  -- para verificarlo DENTRO del gate (sin esperar al commit final), se usa
  -- SET CONSTRAINTS ALL IMMEDIATE momentáneamente.
  SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  IF (SELECT role FROM account_members WHERE id = v_member_b) <> 'owner' THEN
    RAISE EXCEPTION 'GATE FAILED (2): tras transferir, B debería figurar como owner. mirrored=%',
      (SELECT role FROM account_members WHERE id = v_member_b);
  END IF;
  IF (SELECT role FROM account_members WHERE id = v_member_a) = 'owner' THEN
    RAISE EXCEPTION 'GATE FAILED (2): tras transferir, A NO debería seguir figurando como owner';
  END IF;
  SET CONSTRAINTS trg_guard_account_owner_invariant DEFERRED;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (2): transferencia de propiedad (revocar A + asignar B en la misma transacción) completada sin error';

  -- ── (8) TRIANGULATE — degradar a admin CON otro owner presente se acepta
  --     (B es owner ahora; se le agrega 'admin' a A sin tocar su ausencia
  --     de owner — no hay degradación real que ejercitar sin rpc_change_
  --     member_role acá, así que se prueba el caso equivalente: asignar
  --     'admin' a A mientras B sigue siendo owner, sin disparar el guard).
  INSERT INTO account_member_roles (account_id, member_id, role, assigned_by)
  VALUES (v_account, v_member_a, 'admin', v_uid_b);
  SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  SET CONSTRAINTS trg_guard_account_owner_invariant DEFERRED;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (8): asignar un rol no-owner mientras existe otro owner activo no dispara el guard';

  -- ── (5) owner con expires_at rechazado; sin vencimiento se acepta ───────
  v_got_error := false;
  BEGIN
    INSERT INTO account_member_roles (account_id, member_id, role, expires_at)
    VALUES (v_account, v_member_a, 'owner', now() + interval '1 day');
  EXCEPTION WHEN SQLSTATE 'P0406' THEN
    v_got_error := true;
  END;
  IF NOT v_got_error THEN
    RAISE EXCEPTION 'GATE FAILED (5): asignar owner con expires_at NO fue rechazado con P0406';
  END IF;
  IF EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_member_a AND role = 'owner') THEN
    RAISE EXCEPTION 'GATE FAILED (5): quedó una fila owner+expiry pese al rechazo';
  END IF;
  -- sin vencimiento se acepta (A vuelve a ser owner también — cuenta con 2
  -- owners activos, válido, no lo prohíbe ningún requirement).
  INSERT INTO account_member_roles (account_id, member_id, role, assigned_by)
  VALUES (v_account, v_member_a, 'owner', v_uid_b);
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (5): owner+expires_at rechazado (P0406); owner sin vencimiento aceptado';

  -- ── (4) la garantía no depende del procedimiento: DELETE directo ────────
  -- A y B son ambos owners activos ahora. Revocar A (queda B) debe pasar;
  -- revocar TAMBIÉN a B después (dejando 0 owners con 2 miembros) debe
  -- fallar con P0405 — ejercitado vía DELETE directo sobre el pivot, sin
  -- ningún RPC de por medio.
  DELETE FROM account_member_roles WHERE member_id = v_member_a AND role = 'owner';
  SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  SET CONSTRAINTS trg_guard_account_owner_invariant DEFERRED;

  v_got_error := false;
  BEGIN
    DELETE FROM account_member_roles WHERE member_id = v_member_b AND role = 'owner';
    SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  EXCEPTION WHEN SQLSTATE 'P0405' THEN
    v_got_error := true;
  END;
  IF NOT v_got_error THEN
    RAISE EXCEPTION 'GATE FAILED (4): DELETE directo sobre el pivot dejando 0 owners con 2 miembros NO fue rechazado';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (4): el invariante se hace cumplir con un DELETE directo, sin pasar por ningún RPC';

  -- ── (6) espejo: intento de escritura directa queda revertido ────────────
  UPDATE account_members SET role = 'member' WHERE id = v_member_b;
  IF (SELECT role FROM account_members WHERE id = v_member_b) <> 'owner' THEN
    RAISE EXCEPTION 'GATE FAILED (6): la escritura directa de account_members.role NO fue revertida por el espejo. quedó=%',
      (SELECT role FROM account_members WHERE id = v_member_b);
  END IF;
  -- A tiene 'admin' activo en el pivot -> su columna debe reflejar 'admin'
  IF (SELECT role FROM account_members WHERE id = v_member_a) <> 'admin' THEN
    RAISE EXCEPTION 'GATE FAILED (6): A debería reflejar admin (precedencia del pivot), refleja %',
      (SELECT role FROM account_members WHERE id = v_member_a);
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (6): el espejo revierte la escritura directa y refleja la precedencia real del pivot';

  -- ── (7) auditoría: role.assigned y role.revoked ─────────────────────────
  SELECT count(*) INTO v_audit_count
  FROM audit_logs
  WHERE entity_type = 'account_member_role' AND action = 'role.assigned'
    AND entity_id IN (SELECT id FROM account_member_roles WHERE member_id IN (v_member_a, v_member_b));
  IF v_audit_count < 1 THEN
    RAISE EXCEPTION 'GATE FAILED (7): no se encontró ningún registro role.assigned para las asignaciones de este gate';
  END IF;

  SELECT count(*) INTO v_audit_count
  FROM audit_logs
  WHERE entity_type = 'account_member_role' AND action = 'role.revoked'
    AND account_id = v_account;
  IF v_audit_count < 1 THEN
    RAISE EXCEPTION 'GATE FAILED (7): no se encontró ningún registro role.revoked para las revocaciones de este gate';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (7): role.assigned y role.revoked quedaron en audit_logs';

  -- ── (9) candado de cuerpo — CONSTRAINT TRIGGER deferred ─────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t
    WHERE t.tgrelid = 'public.account_member_roles'::regclass
      AND t.tgname = 'trg_guard_account_owner_invariant'
      AND t.tgconstraint <> 0
      AND t.tgdeferrable
      AND t.tginitdeferred
  ) THEN
    RAISE EXCEPTION 'GATE FAILED (9): trg_guard_account_owner_invariant no es un CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (9): el invariante sigue siendo un constraint trigger diferido';

  -- ── (10) candado — UPDATE que degrada directamente al único owner ──────
  -- Estado previo: A={admin}/mirror=admin, B={owner}/mirror=owner (único
  -- owner de la cuenta). Cambiarle el rol a su fila 'owner' (sin mover
  -- cuenta) debe seguir rechazado — no depende del bug de ronda 2
  -- (NEW.account_id = OLD.account_id acá), pero cierra la otra mitad de la
  -- task 4.1/R1 ("un UPDATE que lo desplace"). Se ejercita ANTES de (11)
  -- para que B siga sin fila 'admin' propia (evita un unique_violation con
  -- la que (11) le agrega a continuación).
  v_got_error := false;
  BEGIN
    UPDATE account_member_roles SET role = 'admin' WHERE member_id = v_member_b AND role = 'owner';
    SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  EXCEPTION WHEN SQLSTATE 'P0405' THEN
    v_got_error := true;
  END;
  IF NOT v_got_error THEN
    RAISE EXCEPTION 'GATE FAILED (10): UPDATE role=admin sobre el único owner NO fue rechazado con P0405';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_member_b AND role = 'owner') THEN
    RAISE EXCEPTION 'GATE FAILED (10): tras el rechazo, B debía conservar su fila owner';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (10): un UPDATE que degrada directamente al único owner sigue rechazado con P0405';

  -- ── (11) RONDA 2 — espejo: mover member_id DENTRO de la misma cuenta ────
  -- re-deriva AMBAS membresías. Se mueve la ÚNICA fila 'admin' de A hacia B
  -- (misma cuenta v_account) — A debería decaer a 'member' (sin roles
  -- activos) y B debe seguir en 'owner' (mayor precedencia, no se pierde
  -- por heredar además el admin).
  UPDATE account_member_roles SET member_id = v_member_b WHERE member_id = v_member_a AND role = 'admin';
  -- forzar y re-diferir de inmediato (molde del bloque 8): confirma que
  -- este movimiento NO dispara el guard (misma cuenta, sigue habiendo un
  -- owner) y deja la cola de eventos diferidos limpia antes de (12).
  SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  SET CONSTRAINTS trg_guard_account_owner_invariant DEFERRED;

  IF (SELECT role FROM account_members WHERE id = v_member_a) <> 'member' THEN
    RAISE EXCEPTION 'GATE FAILED (11): tras mover su única asignación (admin) a otro miembro, A debería decaer a member (mirror=%)',
      (SELECT role FROM account_members WHERE id = v_member_a);
  END IF;
  IF (SELECT role FROM account_members WHERE id = v_member_b) <> 'owner' THEN
    RAISE EXCEPTION 'GATE FAILED (11): B debía seguir reflejando owner (mayor precedencia) tras heredar el admin de A (mirror=%)',
      (SELECT role FROM account_members WHERE id = v_member_b);
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (11): mover member_id dentro de la misma cuenta re-deriva el espejo de AMBAS membresías (origen y destino)';

  -- ── (12) RONDA 2 (finding MAJOR) — UPDATE que mueve la fila owner a OTRA
  -- cuenta se rechaza. Reproduce el hallazgo: mover el ÚNICO owner de A
  -- hacia la cuenta de B (a un miembro, C, que NO es owner ahí) dejaría a A
  -- con 2 miembros y 0 owners activos. fn_guard_account_owner_invariant
  -- pre-ronda-2 sólo miraba NEW.account_id (destino, que sigue con owner
  -- vía member_b_own) e ignoraba OLD.account_id (origen, A, que se queda
  -- sin ninguno) — ver la migración.
  v_got_error := false;
  BEGIN
    UPDATE account_member_roles
    SET member_id = v_member_c_in_b, account_id = v_account_b_own
    WHERE member_id = v_member_b AND role = 'owner';
    SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  EXCEPTION WHEN SQLSTATE 'P0405' THEN
    v_got_error := true;
  END;
  IF NOT v_got_error THEN
    RAISE EXCEPTION 'GATE FAILED (12): mover el owner de A a la cuenta de B (dejando a A con miembros y 0 owners) NO fue rechazado con P0405';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_member_b AND role = 'owner' AND account_id = v_account) THEN
    RAISE EXCEPTION 'GATE FAILED (12): tras el rechazo, B debía conservar su owner en la cuenta A (origen)';
  END IF;
  IF EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_member_c_in_b AND role = 'owner') THEN
    RAISE EXCEPTION 'GATE FAILED (12): tras el rechazo, C no debía haber ganado una asignación owner en la cuenta de B (destino)';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (12): un UPDATE que mueve la fila owner a otra cuenta se rechaza con P0405 (verifica NEW Y OLD)';

  -- ── (13) RONDA 3 (finding MINOR-1) — DELETE de account_members (no del
  -- pivot) del único owner, conservando otro miembro, es rechazado igual
  -- que (1). Estado actual: B es el único owner de v_account (owner+admin
  -- en el pivot), A está presente sin ningún rol activo (mirror='member').
  -- Borrar la MEMBRESÍA de B (no su fila del pivot) dispara el `ON DELETE
  -- CASCADE` hacia account_member_roles, que a su vez dispara el MISMO
  -- constraint trigger diferido — molde exacto del bloque (1).
  v_got_error := false;
  BEGIN
    DELETE FROM account_members WHERE id = v_member_b;
    SET CONSTRAINTS trg_guard_account_owner_invariant IMMEDIATE;
  EXCEPTION WHEN SQLSTATE 'P0405' THEN
    v_got_error := true;
  END;

  IF NOT v_got_error THEN
    RAISE EXCEPTION 'GATE FAILED (13): borrar la membresía (account_members) del único owner, conservando otro miembro, NO fue rechazado con P0405';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account_members WHERE id = v_member_b) THEN
    RAISE EXCEPTION 'GATE FAILED (13): tras el rechazo, la membresía de B (owner) debía seguir existiendo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM account_member_roles WHERE member_id = v_member_b AND role = 'owner') THEN
    RAISE EXCEPTION 'GATE FAILED (13): tras el rechazo, B debía conservar su asignación owner en el pivot';
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (13): borrar la membresía (account_members) del único owner, conservando otro miembro, es rechazado con P0405 vía CASCADE al pivot';

  -- ── (14) RONDA 3 (finding MINOR-3) — auditoría de UPDATE del pivot ──────
  -- role.updated en audit_logs con el snapshot OLD/NEW completo. Se
  -- ejercita sobre la fila 'admin' de B (no toca el invariante de
  -- propietario: B sigue siendo owner con esta fila intacta).
  UPDATE account_member_roles
     SET expires_at = now() - interval '1 day'
   WHERE member_id = v_member_b AND role = 'admin';

  -- `now()` es fijo por TRANSACCIÓN (no por sentencia) — el bloque (11) ya
  -- dejó su PROPIO registro role.updated sobre esta misma fila (mueve
  -- member_id, ambos expires_at NULL) con un created_at idéntico al de
  -- este bloque, así que `ORDER BY created_at DESC LIMIT 1` no alcanza
  -- para distinguirlos. Se filtra por new.expires_at IS NOT NULL, que sólo
  -- puede venir de ESTE UPDATE.
  SELECT metadata INTO v_audit_metadata
  FROM   audit_logs
  WHERE  entity_type = 'account_member_role'
    AND  action      = 'role.updated'
    AND  entity_id   = (SELECT id FROM account_member_roles WHERE member_id = v_member_b AND role = 'admin')
    AND  (metadata->'new'->>'expires_at') IS NOT NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_audit_metadata IS NULL THEN
    RAISE EXCEPTION 'GATE FAILED (14): no se encontró ningún registro role.updated tras el UPDATE de expires_at';
  END IF;
  IF (v_audit_metadata->'old'->>'expires_at') IS NOT NULL THEN
    RAISE EXCEPTION 'GATE FAILED (14): old.expires_at debía ser NULL (sin vencimiento previo). metadata=%', v_audit_metadata;
  END IF;
  IF (v_audit_metadata->'new'->>'expires_at') IS NULL THEN
    RAISE EXCEPTION 'GATE FAILED (14): new.expires_at debía llevar el vencimiento recién asignado. metadata=%', v_audit_metadata;
  END IF;
  IF (v_audit_metadata->'old'->>'role') <> 'admin' OR (v_audit_metadata->'new'->>'role') <> 'admin' THEN
    RAISE EXCEPTION 'GATE FAILED (14): old.role/new.role debían ser ambos admin. metadata=%', v_audit_metadata;
  END IF;
  IF (v_audit_metadata->'new'->>'member_id') <> v_member_b::text OR (v_audit_metadata->'new'->>'account_id') <> v_account::text THEN
    RAISE EXCEPTION 'GATE FAILED (14): new.member_id/new.account_id no coinciden con la fila actualizada. metadata=%', v_audit_metadata;
  END IF;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (14): role.updated quedó en audit_logs con el snapshot OLD/NEW (member_id, account_id, role, expires_at)';

  -- ── (3) vaciar la cuenta por completo no es bloqueado ───────────────────
  DELETE FROM account_members WHERE account_id = v_account;
  v_blocks_run := v_blocks_run + 1;
  RAISE NOTICE 'PASS (3): vaciar la cuenta por completo (borrar todas sus membresías) no fue bloqueado';

  IF v_blocks_run <> 14 THEN
    RAISE EXCEPTION 'GATE ACCOUNT-OWNER-INVARIANT FAILED (conteo): se ejercitaron % de 14 bloques esperados.', v_blocks_run;
  END IF;
  RAISE NOTICE 'GATE ACCOUNT-OWNER-INVARIANT: 14/14 bloques PASS.';

  -- ── cleanup ──────────────────────────────────────────────────────────────
  -- Block 3 ya vació la cuenta A (v_account); a B y a C les quedan sus
  -- PROPIAS cuentas (auto-provisionadas por su propio signup, la de B con
  -- member_c_in_b agregado a mano para el bloque 12) — hay que vaciarlas
  -- explícito ANTES de borrar `accounts` bajo `replica` (que desactiva
  -- también la FK ON DELETE CASCADE, dejaría el pivot huérfano, mismo
  -- gotcha que operacion-party-guard).
  DELETE FROM account_member_roles WHERE member_id IN (
    SELECT id FROM account_members WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_uid_a, v_uid_b, v_uid_c))
  );
  DELETE FROM account_members WHERE account_id IN (
    SELECT id FROM accounts WHERE owner_user_id IN (v_uid_a, v_uid_b, v_uid_c)
  );
  SET session_replication_role = replica;
  -- ronda 2 (nit): cashboxes ANTES de branches — bajo `replica` no hay
  -- CASCADE, así que borrar branches primero deja cashboxes huérfanas.
  DELETE FROM public.cashboxes cb USING public.branches b
    WHERE cb.branch_id = b.id AND b.account_id IN (
      SELECT id FROM accounts WHERE owner_user_id IN (v_uid_a, v_uid_b, v_uid_c)
    );
  DELETE FROM public.branches WHERE account_id IN (
    SELECT id FROM accounts WHERE owner_user_id IN (v_uid_a, v_uid_b, v_uid_c)
  );
  DELETE FROM public.payment_methods WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_uid_a, v_uid_b, v_uid_c));
  DELETE FROM public.product_categories WHERE account_id IN (SELECT id FROM accounts WHERE owner_user_id IN (v_uid_a, v_uid_b, v_uid_c));
  DELETE FROM public.email_logs WHERE user_id IN (v_uid_a, v_uid_b, v_uid_c);
  DELETE FROM public.profiles WHERE id IN (v_uid_a, v_uid_b, v_uid_c);
  DELETE FROM public.accounts WHERE owner_user_id IN (v_uid_a, v_uid_b, v_uid_c);
  SET session_replication_role = DEFAULT;
  DELETE FROM auth.users WHERE id IN (v_uid_a, v_uid_b, v_uid_c);
  RAISE NOTICE 'GATE ACCOUNT-OWNER-INVARIANT: cleanup completo.';
END $$;
