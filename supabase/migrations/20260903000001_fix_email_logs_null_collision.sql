-- =============================================================================
-- MIGRATION: 20260903000001_fix_email_logs_null_collision.sql
-- CHANGE:    fix/email-logs-null-collision
--
-- QUÉ ARREGLA
--   Borrar un usuario puede fallar con
--     duplicate key value violates unique constraint
--     "email_logs_user_id_event_type_metadata_key"
--   y en producción HOY hay 2 usuarios reales en esa situación (medido el
--   2026-08-05). El mismo defecto deja residuo en CI: la limpieza best-effort
--   de los gates de migración aborta a mitad y sobreviven anchors sintéticos.
--
-- CAUSA
--   public.email_logs.user_id tiene FK a auth.users con ON DELETE SET NULL, y
--   el constraint de unicidad es:
--     UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)
--   Al borrar usuarios, sus filas de email_logs colapsan a user_id = NULL. Con
--   NULLS NOT DISTINCT dos filas NULL con el mismo (event_type, metadata) son
--   la MISMA clave, así que la segunda viola el unique y el DELETE del usuario
--   falla. Basta con que exista una huérfana previa que coincida.
--
--   Efecto colateral en los gates: su limpieza vive en un bloque
--   BEGIN ... EXCEPTION, que es una SUBTRANSACCIÓN — si falla la última
--   sentencia (el DELETE de auth.users), se revierten también los DELETE
--   anteriores que sí habían funcionado, y el error se traga en un NOTICE. Por
--   eso `20260819000001_billing_edge_effective_plan` deja 3 accounts + 3
--   usuarios sintéticos tras un reset completo.
--
-- POR QUÉ ES SEGURO QUITAR NULLS NOT DISTINCT (sign-off PO 2026-08-05)
--   Auditoría de TODOS los productores de email_logs (migraciones + Edge
--   Functions): ninguno inserta con user_id NULL a propósito — todos pasan el
--   id del usuario (`new.id` en handle_new_user, el id del destinatario en los
--   barridos de billing/notificaciones). La única excepción es una fila de gate
--   de prueba. Las filas NULL de producción son, sin excepción, filas cuyo
--   usuario fue borrado después.
--   ⇒ Deduplicar entre filas huérfanas no protege ningún envío: NULLS NOT
--     DISTINCT no aporta valor hoy y sí produce la colisión.
--   La deduplicación que SÍ importa —la de los `ON CONFLICT DO NOTHING` de los
--   productores, que evita reenviar el mismo aviso al mismo usuario— queda
--   INTACTA: para user_id NOT NULL el comportamiento no cambia.
--   Ningún caller referencia el constraint por nombre (`ON CONFLICT ON
--   CONSTRAINT ...`); todos usan `ON CONFLICT DO NOTHING`, que sigue funcionando.
--
-- QUÉ HACE
--   1. Recrea el constraint sin NULLS NOT DISTINCT (default de Postgres: los
--      NULL son distintos entre sí). Es un relajamiento: todo dato válido antes
--      sigue siendo válido, así que no puede fallar por datos existentes.
--   2. Limpia el residuo de anchors sintéticos (`%@test.local`). Verificado el
--      2026-08-05 contra producción: 0 usuarios con ese dominio, así que es un
--      no-op ahí. En prod sí borra 4 filas huérfanas de email_logs cuyo
--      `recipient` es `%@test.local` — rastro de gates que corrieron en prod.
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
-- ROLLBACK: volver a agregar el constraint con NULLS NOT DISTINCT
--   (reintroduce el bug; el rollback real es no aplicar).
-- =============================================================================


-- =============================================================================
-- 1. Constraint sin NULLS NOT DISTINCT (idempotente: solo actúa si hace falta)
-- =============================================================================
DO $$
DECLARE
  v_nulls_not_distinct boolean;
BEGIN
  SELECT i.indnullsnotdistinct INTO v_nulls_not_distinct
  FROM   pg_constraint c
  JOIN   pg_index i ON i.indexrelid = c.conindid
  WHERE  c.conrelid = 'public.email_logs'::regclass
    AND  c.conname  = 'email_logs_user_id_event_type_metadata_key';

  IF v_nulls_not_distinct IS NULL THEN
    RAISE NOTICE 'email-logs-null-collision: el constraint no existe en este entorno — nada que hacer.';
    RETURN;
  END IF;

  IF NOT v_nulls_not_distinct THEN
    RAISE NOTICE 'email-logs-null-collision: el constraint ya es NULLS DISTINCT — no-op.';
    RETURN;
  END IF;

  ALTER TABLE public.email_logs
    DROP CONSTRAINT email_logs_user_id_event_type_metadata_key;

  -- Sin cláusula NULLS: default de Postgres = NULLS DISTINCT.
  ALTER TABLE public.email_logs
    ADD CONSTRAINT email_logs_user_id_event_type_metadata_key
    UNIQUE (user_id, event_type, metadata);

  RAISE NOTICE 'email-logs-null-collision: constraint recreado sin NULLS NOT DISTINCT.';
END $$;

COMMENT ON CONSTRAINT email_logs_user_id_event_type_metadata_key ON public.email_logs IS
    'Dedupe de envíos por (user_id, event_type, metadata) — lo usan los ON CONFLICT '
    'DO NOTHING de los productores. NULLS DISTINCT a propósito: las filas con '
    'user_id NULL son SIEMPRE filas cuyo usuario se borró (FK ON DELETE SET NULL), '
    'nunca envíos nuevos. Con NULLS NOT DISTINCT, borrar un usuario fallaba si otra '
    'huérfana compartía (event_type, metadata) — ver 20260903000001.';


-- =============================================================================
-- 2. Limpieza del residuo de anchors sintéticos
--    Orden hijo→padre y email_logs ANTES que auth.users: no dependemos del
--    SET NULL, así el borrado no puede colisionar ni siquiera en una DB que
--    todavía no tenga aplicado el paso 1.
--    NO va en un BEGIN...EXCEPTION: ese patrón es justamente el que revierte
--    la limpieza entera si falla la última sentencia.
-- =============================================================================
DELETE FROM public.email_logs
WHERE  recipient LIKE '%@test.local'
   OR  user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local');

DELETE FROM public.branch_stock WHERE branch_id IN (
  SELECT b.id FROM public.branches b
  WHERE b.account_id IN (SELECT id FROM public.accounts
                         WHERE owner_user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local')));

DELETE FROM public.cashboxes WHERE branch_id IN (
  SELECT b.id FROM public.branches b
  WHERE b.account_id IN (SELECT id FROM public.accounts
                         WHERE owner_user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local')));

DELETE FROM public.branches WHERE account_id IN (
  SELECT id FROM public.accounts
  WHERE owner_user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local'));

DELETE FROM public.account_members
WHERE  user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local')
   OR  account_id IN (SELECT id FROM public.accounts
                      WHERE owner_user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local'));

DELETE FROM public.billing_events
WHERE  user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local');

DELETE FROM public.accounts
WHERE  owner_user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local');

DELETE FROM public.profiles
WHERE  id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local');

DELETE FROM public.operation_idempotency
WHERE  user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@test.local');

DELETE FROM auth.users WHERE email LIKE '%@test.local';


-- =============================================================================
-- 3. Gate de introspección (corre SIEMPRE, también en prod)
-- =============================================================================
DO $$
DECLARE
  v_nulls_not_distinct boolean;
  v_cols text;
BEGIN
  SELECT i.indnullsnotdistinct,
         (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
          FROM   unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN   pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
  INTO   v_nulls_not_distinct, v_cols
  FROM   pg_constraint c
  JOIN   pg_index i ON i.indexrelid = c.conindid
  WHERE  c.conrelid = 'public.email_logs'::regclass
    AND  c.conname  = 'email_logs_user_id_event_type_metadata_key';

  IF v_nulls_not_distinct IS NULL THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: desapareció el constraint de dedupe de email_logs.';
  END IF;

  IF v_nulls_not_distinct THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: el constraint sigue siendo NULLS NOT DISTINCT — borrar usuarios puede fallar.';
  END IF;

  IF v_cols IS DISTINCT FROM 'user_id,event_type,metadata' THEN
    RAISE EXCEPTION 'GATE INTROSPECCION FAILED: el constraint cambió de columnas (%) — el dedupe de los productores depende de estas tres.', v_cols;
  END IF;

  RAISE NOTICE 'GATE INTROSPECCION PASSED: dedupe de email_logs sobre (user_id, event_type, metadata), NULLS DISTINCT.';
END $$;


-- =============================================================================
-- 4. Gate de comportamiento auto-limpiante (solo DB vacía/CI, NOTICE-degrade)
--    Reproduce el escenario exacto que fallaba: dos usuarios con email_logs de
--    (event_type, metadata) IDÉNTICOS, borrados en UNA sola sentencia.
-- =============================================================================
DO $$
DECLARE
  v_u1       uuid := gen_random_uuid();
  v_u2       uuid := gen_random_uuid();
  v_acc1     uuid;
  v_nulls    bigint;
  v_dedupe   boolean := false;
  -- Los ids se capturan ANTES de borrar los usuarios: tras el SET NULL ya no
  -- hay forma de relacionar la fila con su anchor. No alcanza con filtrar por
  -- `recipient`: handle_new_user escribe además un `new_user_admin_notice`
  -- dirigido al ADMIN, que quedaría huérfano para siempre (justo la clase de
  -- residuo que esta migración corrige).
  v_log_ids  uuid[];
BEGIN
  -- Mismo `name` en el metadata a propósito: así handle_new_user escribe dos
  -- filas 'welcome' con metadata idéntico, que es la colisión del bug.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_u1, 'authenticated', 'authenticated', 'email-null-gate-1@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Colision', 'phone', '', 'locality', '', 'province', '')),
         (v_u2, 'authenticated', 'authenticated', 'email-null-gate-2@test.local', now(), now(),
          jsonb_build_object('name', 'Gate Colision', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_acc1 FROM public.account_members WHERE user_id = v_u1 LIMIT 1;

  IF v_acc1 IS NULL THEN
    RAISE NOTICE 'GATE EMAIL-NULL: no se pudo sembrar el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    DELETE FROM public.email_logs WHERE user_id IN (v_u1, v_u2);
    DELETE FROM auth.users WHERE id IN (v_u1, v_u2);
    RETURN;
  END IF;

  IF (SELECT count(*) FROM public.email_logs
      WHERE user_id IN (v_u1, v_u2) AND event_type = 'welcome') <> 2 THEN
    RAISE EXCEPTION 'GATE EMAIL-NULL FAILED (setup): se esperaban 2 filas welcome, una por usuario sintético.';
  END IF;

  SELECT array_agg(id) INTO v_log_ids
  FROM   public.email_logs WHERE user_id IN (v_u1, v_u2);

  -- ── (a) Dedupe VIVO intacto: repetir el mismo (user_id, event_type, metadata) choca ──
  BEGIN
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, event_type, recipient, subject, metadata
    FROM   public.email_logs WHERE user_id = v_u1 AND event_type = 'welcome' LIMIT 1;
  EXCEPTION
    WHEN unique_violation THEN
      v_dedupe := true;
  END;

  IF NOT v_dedupe THEN
    RAISE EXCEPTION 'GATE EMAIL-NULL FAILED (a): se perdió el dedupe para un usuario vivo — el ON CONFLICT de los productores dejaría de proteger contra reenvíos.';
  END IF;

  -- ── (b) La baja de DOS usuarios con metadata idéntico ya no colisiona ────
  --     (limpiamos primero lo que cuelga de las cuentas, no de email_logs:
  --      el punto del gate es que el SET NULL de email_logs no explote)
  DELETE FROM public.branch_stock WHERE branch_id IN (
    SELECT id FROM public.branches WHERE account_id IN (
      SELECT account_id FROM public.account_members WHERE user_id IN (v_u1, v_u2)));
  DELETE FROM public.cashboxes WHERE branch_id IN (
    SELECT id FROM public.branches WHERE account_id IN (
      SELECT account_id FROM public.account_members WHERE user_id IN (v_u1, v_u2)));
  DELETE FROM public.branches WHERE account_id IN (
    SELECT account_id FROM public.account_members WHERE user_id IN (v_u1, v_u2));
  DELETE FROM public.account_members WHERE user_id IN (v_u1, v_u2);
  DELETE FROM public.accounts        WHERE owner_user_id IN (v_u1, v_u2);
  DELETE FROM public.profiles        WHERE id IN (v_u1, v_u2);

  BEGIN
    DELETE FROM auth.users WHERE id IN (v_u1, v_u2);
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'GATE EMAIL-NULL FAILED (b): borrar dos usuarios con email_logs de metadata idéntico sigue colisionando — el fix del constraint no tomó efecto.';
  END;

  -- ── (c) El SET NULL ocurrió: las filas welcome sobreviven huérfanas ──────
  SELECT count(*) INTO v_nulls FROM public.email_logs
  WHERE  id = ANY(v_log_ids) AND user_id IS NULL AND event_type = 'welcome';

  IF v_nulls <> 2 THEN
    RAISE EXCEPTION 'GATE EMAIL-NULL FAILED (c): se esperaban 2 filas welcome huérfanas tras el SET NULL, hay %.', v_nulls;
  END IF;

  RAISE NOTICE 'GATE EMAIL-NULL PASSED: dedupe vivo intacto (a), baja múltiple sin colisión (b), SET NULL efectivo (c).';

  -- Limpieza del propio gate: por id, no por recipient — barre también el
  -- new_user_admin_notice dirigido al admin.
  DELETE FROM public.email_logs WHERE id = ANY(v_log_ids);

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'GATE EMAIL-NULL FAILED%' THEN
      -- Best-effort, pero sin tapar el fallo real.
      BEGIN
        DELETE FROM public.email_logs WHERE id = ANY(COALESCE(v_log_ids, '{}'));
        DELETE FROM public.email_logs WHERE user_id IN (v_u1, v_u2);
        DELETE FROM auth.users WHERE email LIKE 'email-null-gate-%@test.local';
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
      RAISE;
    END IF;
    BEGIN
      DELETE FROM public.email_logs WHERE id = ANY(COALESCE(v_log_ids, '{}'));
      DELETE FROM public.email_logs WHERE user_id IN (v_u1, v_u2);
      DELETE FROM auth.users WHERE email LIKE 'email-null-gate-%@test.local';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE NOTICE 'GATE EMAIL-NULL: contexto no permite el gate de comportamiento (%) — degradando sin abortar.', SQLERRM;
END $$;
