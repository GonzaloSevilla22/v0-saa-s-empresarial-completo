-- =============================================================================
-- test_community_interactions.sql — Gates de comportamiento y de catálogo:
-- community-counter-triggers-schema-fix
--
-- Verifica que responder un post y dar/sacar like sigan funcionando en
-- producción, y que ninguna función del catálogo vuelva a referenciar una
-- tabla movida por C-23 como si siguiera en `public`.
--
-- ORIGEN DEL BUG QUE ESTE GATE CIERRA
--   C-23 (20260615000001_community_schema_move.sql) movió 16 tablas de
--   `public` a `community` con ALTER TABLE ... SET SCHEMA. Esa sentencia mueve
--   la tabla y CONSERVA los triggers colgados de ella, pero NO reescribe el
--   cuerpo de las funciones que esos triggers ejecutan. Resultado:
--   update_post_replies_count() y update_post_likes_count() siguieron
--   haciendo `UPDATE public.posts ...` contra una tabla que dejó de existir.
--   Como son triggers AFTER, el 42P01 aborta la transacción que los disparó:
--   ni la reply ni el like se guardaban. Roto desde 2026-06-15, corregido por
--   20260918000001_community_counter_triggers_schema_fix.sql.
--
-- QUÉ VERIFICA (dos capas)
--   1. COMPORTAMIENTO (gates 1-3): el camino feliz con CONTEOS EXACTOS.
--      INSERT en community.replies no lanza, la fila persiste y replies_count
--      sube exactamente 1; DELETE lo baja exactamente 1; idem likes. Los
--      conteos exactos son deliberados: el guard degrade-don't-fail del fix
--      (D3) convierte un fallo del contador en un WARNING silencioso, así que
--      sin asserts de valor exacto una regresión futura pasaría en verde.
--   2. CATÁLOGO (gate 4): la red generalizada. Ninguna función de pg_proc en
--      `public` ni en `community` referencia public.<tabla> para ninguna de
--      las 16 tablas movidas por C-23. Cubre la FAMILIA del bug, no solo las
--      dos funciones que lo manifestaron.
--
-- CRITERIO DE FALSOS POSITIVOS DEL GATE 4 (design D5 / R2) — LEER ANTES DE
-- "ARREGLAR EL GATE" SI FALLA:
--   La regex se acota con límite de palabra a ambos lados (\mpublic\.<tabla>\M),
--   así que NO matchea nombres de columna (`posts_count`), ni sufijos
--   (`public.postscript`), ni prefijos. Si el gate falla, la referencia es
--   real. Los comentarios SQL dentro de prosrc SÍ cuentan como coincidencia, y
--   eso es intencional: una función que menciona `public.posts` aunque sea en
--   un comentario es documentación mentirosa sobre dónde vive el dato, y se
--   corrige el comentario. NO relajar la regex para silenciar el fallo.
--
-- Patrón del proyecto (test_kpis.sql, test_analytics_events.sql,
-- test_admin_kpis.sql): acumular fallos en text[], un solo RAISE EXCEPTION al
-- final para que psql -v ON_ERROR_STOP=1 salga con código distinto de cero.
-- Anchors sintéticos vía handle_new_user (siembra account + branch + cashbox,
-- 20260812000001). Cleanup hijo→padre al final, degradando con RAISE NOTICE si
-- el contexto no lo permite.
--
-- Corre en CI: KPI_Validation.yml (paso agregado en el mismo PR).
-- =============================================================================

DO $$
DECLARE
  v_failures          text[] := '{}';

  -- Anchor: dispara handle_new_user (account + branch + cashbox eager).
  v_user_email        text := 'community-counter-gate-user@test.local';
  v_user_id           uuid := gen_random_uuid();
  v_user_account      uuid;

  v_post_id           uuid := gen_random_uuid();
  v_reply_id          uuid := gen_random_uuid();
  v_like_id           uuid := gen_random_uuid();
  v_degrade_reply_id  uuid := gen_random_uuid();

  v_count_before      int;
  v_count_after       int;
  v_likes_before      int;
  v_likes_after       int;

  -- Gate 4: las 16 tablas movidas por C-23 (20260615000001).
  v_moved_tables      CONSTANT text[] := ARRAY[
    'courses', 'course_modules', 'course_lessons', 'course_enrollments',
    'course_progress', 'lesson_progress', 'posts', 'replies', 'post_likes',
    'meetings', 'seguros', 'purchase_pools', 'landing_sections',
    'fair_recommendations', 'fair_ai_tools', 'copilot_prompts'
  ];
  v_tbl               text;
  v_offender          record;

  -- Gate 5: superficie de las dos funciones de contador.
  v_pronames          CONSTANT text[] := ARRAY[
    'update_post_replies_count', 'update_post_likes_count'
  ];
  v_proname           text;
  v_def_count         int;
  v_trigger_ok        boolean;
  v_has_execute       boolean;

  -- Flags de operación: los gates de comportamiento capturan la excepción y la
  -- registran como fallo en vez de abortar el bloque, para que UNA sola corrida
  -- reporte TODOS los fallos (incluido el gate de catálogo, que es el más
  -- diagnóstico). Es el sentido del patrón text[] del proyecto: acumular.
  v_op_ok             boolean;
BEGIN
  -- ═══════════════════════════════════════════════════════════════════════
  -- FASE 1 — SETUP (como postgres: anchor + post de prueba)
  -- ═══════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_user_email, now(), now(),
          jsonb_build_object('name', 'Gate Community Counter', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_user_account
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_user_account IS NULL THEN
    RAISE NOTICE 'GATE COMMUNITY-COUNTER: no se pudo resolver una account para el anchor (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO community.posts (id, user_id, title, content, created_at)
  VALUES (v_post_id, v_user_id, 'Post gate contadores', 'contenido', now());

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 1 — Replies: INSERT persiste y replies_count sube EXACTAMENTE 1
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT replies_count INTO v_count_before FROM community.posts WHERE id = v_post_id;

  v_op_ok := true;
  BEGIN
    INSERT INTO community.replies (id, post_id, user_id, content, created_at)
    VALUES (v_reply_id, v_post_id, v_user_id, 'respuesta gate', now());
  EXCEPTION WHEN OTHERS THEN
    v_op_ok := false;
    v_failures := array_append(v_failures, format(
      'FAIL 1a: el INSERT en community.replies abortó (%s: %s). Si es 42P01 sobre public.posts, la función de contador quedó apuntando a una tabla movida por C-23.',
      SQLSTATE, SQLERRM));
  END;

  IF v_op_ok THEN
    IF NOT EXISTS (SELECT 1 FROM community.replies WHERE id = v_reply_id) THEN
      v_failures := array_append(v_failures,
        'FAIL 1b: la reply no quedó persistida tras el INSERT en community.replies');
    END IF;

    SELECT replies_count INTO v_count_after FROM community.posts WHERE id = v_post_id;
    IF v_count_after IS DISTINCT FROM v_count_before + 1 THEN
      v_failures := array_append(v_failures, format(
        'FAIL 1c: replies_count debería subir exactamente 1 (antes=%s, después=%s)',
        v_count_before, v_count_after));
    END IF;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 2 — Replies: DELETE decrementa EXACTAMENTE 1
  -- ═══════════════════════════════════════════════════════════════════════
  v_op_ok := true;
  BEGIN
    DELETE FROM community.replies WHERE id = v_reply_id;
  EXCEPTION WHEN OTHERS THEN
    v_op_ok := false;
    v_failures := array_append(v_failures, format(
      'FAIL 2a: el DELETE en community.replies abortó (%s: %s)', SQLSTATE, SQLERRM));
  END;

  IF v_op_ok THEN
    IF EXISTS (SELECT 1 FROM community.replies WHERE id = v_reply_id) THEN
      v_failures := array_append(v_failures, 'FAIL 2b: la reply debería haberse borrado');
    END IF;

    SELECT replies_count INTO v_count_after FROM community.posts WHERE id = v_post_id;
    IF v_count_after IS DISTINCT FROM v_count_before THEN
      v_failures := array_append(v_failures, format(
        'FAIL 2c: replies_count debería volver exactamente al valor previo tras el DELETE (esperado=%s, real=%s)',
        v_count_before, v_count_after));
    END IF;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 3 — Likes: INSERT sube EXACTAMENTE 1 y DELETE lo revierte
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT likes_count INTO v_likes_before FROM community.posts WHERE id = v_post_id;

  v_op_ok := true;
  BEGIN
    INSERT INTO community.post_likes (id, post_id, user_id, created_at)
    VALUES (v_like_id, v_post_id, v_user_id, now());
  EXCEPTION WHEN OTHERS THEN
    v_op_ok := false;
    v_failures := array_append(v_failures, format(
      'FAIL 3a: el INSERT en community.post_likes abortó (%s: %s). Si es 42P01 sobre public.posts, la función de contador quedó apuntando a una tabla movida por C-23.',
      SQLSTATE, SQLERRM));
  END;

  IF v_op_ok THEN
    IF NOT EXISTS (SELECT 1 FROM community.post_likes WHERE id = v_like_id) THEN
      v_failures := array_append(v_failures,
        'FAIL 3b: el like no quedó persistido tras el INSERT en community.post_likes');
    END IF;

    SELECT likes_count INTO v_likes_after FROM community.posts WHERE id = v_post_id;
    IF v_likes_after IS DISTINCT FROM v_likes_before + 1 THEN
      v_failures := array_append(v_failures, format(
        'FAIL 3c: likes_count debería subir exactamente 1 (antes=%s, después=%s)',
        v_likes_before, v_likes_after));
    END IF;

    BEGIN
      DELETE FROM community.post_likes WHERE id = v_like_id;
    EXCEPTION WHEN OTHERS THEN
      v_failures := array_append(v_failures, format(
        'FAIL 3d: el DELETE en community.post_likes abortó (%s: %s)', SQLSTATE, SQLERRM));
    END;

    SELECT likes_count INTO v_likes_after FROM community.posts WHERE id = v_post_id;
    IF v_likes_after IS DISTINCT FROM v_likes_before THEN
      v_failures := array_append(v_failures, format(
        'FAIL 3e: likes_count debería volver exactamente al valor previo tras sacar el like (esperado=%s, real=%s)',
        v_likes_before, v_likes_after));
    END IF;
  END IF;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 4 — Degrade-don't-fail: un fallo del contador NO tumba la reply
  --
  -- Cubre el escenario del spec "Un fallo del contador no tumba la operación
  -- del usuario" (design D3). Se fuerza el fallo del UPDATE del contador con
  -- un CHECK NOT VALID imposible sobre community.posts — NOT VALID no revisa
  -- las filas existentes, pero SÍ valida toda fila actualizada, así que
  -- cualquier UPDATE del contador falla. Mismo patrón que el gate 4 de
  -- test_analytics_events.sql.
  --
  -- Esperado con el guard puesto: el INSERT en community.replies NO lanza, la
  -- fila persiste, y el contador queda desfasado (reparable con el recompute).
  -- Sin el guard, el 42P01/23514 aborta la transacción y se pierde la reply.
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT replies_count INTO v_count_before FROM community.posts WHERE id = v_post_id;

  ALTER TABLE community.posts
    ADD CONSTRAINT tmp_community_counter_force_fail CHECK (replies_count < 0) NOT VALID;

  v_op_ok := true;
  BEGIN
    INSERT INTO community.replies (id, post_id, user_id, content, created_at)
    VALUES (v_degrade_reply_id, v_post_id, v_user_id, 'respuesta gate degrade', now());
  EXCEPTION WHEN OTHERS THEN
    v_op_ok := false;
    v_failures := array_append(v_failures, format(
      'FAIL 4a: el INSERT de la reply abortó por un fallo del contador (%s) — el guard degrade-don''t-fail no está protegiendo el dato de negocio',
      SQLERRM));
  END;

  IF v_op_ok AND NOT EXISTS (SELECT 1 FROM community.replies WHERE id = v_degrade_reply_id) THEN
    v_failures := array_append(v_failures,
      'FAIL 4b: la reply debería persistir aunque la actualización del contador falle (la fila es el hecho de negocio; el contador es cosmético)');
  END IF;

  -- 4c: el MISMO guard en el camino DELETE. No es simetría decorativa: en un
  -- trigger DELETE la variable NEW está sin asignar, así que un handler de
  -- excepción que toque NEW.post_id lanza "record new is not assigned yet" y
  -- rompe el guard justo donde tiene que proteger. Sin este assert, ese fallo
  -- solo aparecería en producción al borrar una reply con el contador caído.
  v_op_ok := true;
  BEGIN
    DELETE FROM community.replies WHERE id = v_degrade_reply_id;
  EXCEPTION WHEN OTHERS THEN
    v_op_ok := false;
    v_failures := array_append(v_failures, format(
      'FAIL 4c: el DELETE de la reply abortó por un fallo del contador (%s) — revisar que el handler no referencie NEW en el camino DELETE',
      SQLERRM));
  END;

  IF v_op_ok AND EXISTS (SELECT 1 FROM community.replies WHERE id = v_degrade_reply_id) THEN
    v_failures := array_append(v_failures,
      'FAIL 4d: la reply debería haberse borrado aunque la actualización del contador falle');
  END IF;

  ALTER TABLE community.posts DROP CONSTRAINT tmp_community_counter_force_fail;

  IF NOT EXISTS (SELECT 1 FROM community.replies WHERE id = v_degrade_reply_id) AND v_op_ok THEN
    RAISE NOTICE 'PASS 4: INSERT y DELETE de la reply sobreviven a un contador caído (degrade-don''t-fail); el contador queda desfasado y es reparable con el recompute.';
  END IF;

  DELETE FROM community.replies WHERE id = v_degrade_reply_id;

  -- El contador quedó desfasado a propósito por el gate 4: se realinea con el
  -- COUNT(*) real para no contaminar ningún assert posterior.
  UPDATE community.posts p
  SET    replies_count = (SELECT count(*) FROM community.replies r WHERE r.post_id = p.id),
         likes_count   = (SELECT count(*) FROM community.post_likes l WHERE l.post_id = p.id)
  WHERE  p.id = v_post_id;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 5 — Catálogo: ninguna función referencia public.<tabla movida>
  -- (la red generalizada — ver CRITERIO DE FALSOS POSITIVOS en la cabecera)
  -- ═══════════════════════════════════════════════════════════════════════
  FOREACH v_tbl IN ARRAY v_moved_tables LOOP
    FOR v_offender IN
      SELECT n.nspname AS schema_name, p.proname AS fn_name
      FROM   pg_proc p
      JOIN   pg_namespace n ON n.oid = p.pronamespace
      WHERE  n.nspname IN ('public', 'community')
        AND  p.prosrc ~ ('\mpublic\.' || v_tbl || '\M')
      ORDER  BY n.nspname, p.proname
    LOOP
      v_failures := array_append(v_failures, format(
        'FAIL 5: %I.%I() referencia public.%s, que vive en community.%s desde C-23 (20260615000001). Calificar el schema — NO ampliar search_path ni relajar el gate.',
        v_offender.schema_name, v_offender.fn_name, v_tbl, v_tbl));
    END LOOP;
  END LOOP;

  -- ═══════════════════════════════════════════════════════════════════════
  -- GATE 6 — Superficie de las funciones de contador
  -- ═══════════════════════════════════════════════════════════════════════
  FOREACH v_proname IN ARRAY v_pronames LOOP
    -- 6a: exactamente 1 definición (anti-42725: un CREATE OR REPLACE que
    -- cambie la firma crearía un segundo overload en vez de reemplazar).
    SELECT count(*) INTO v_def_count
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname;

    IF v_def_count <> 1 THEN
      v_failures := array_append(v_failures, format(
        'FAIL 6a: public.%s debería tener exactamente 1 definición, tiene %s (42725: overload duplicado)',
        v_proname, v_def_count));
    END IF;

    -- 6b: ni anon ni authenticated tienen EXECUTE (trigger-only, 20260822000001).
    IF v_def_count = 1 THEN
      SELECT has_function_privilege('anon', p.oid, 'EXECUTE')
             OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      INTO   v_has_execute
      FROM   pg_proc p
      JOIN   pg_namespace n ON n.oid = p.pronamespace
      WHERE  n.nspname = 'public' AND p.proname = v_proname;

      IF v_has_execute THEN
        v_failures := array_append(v_failures, format(
          'FAIL 6b: public.%s() es trigger-only y no debería tener EXECUTE para anon ni authenticated',
          v_proname));
      END IF;
    END IF;
  END LOOP;

  -- 6c: ambos triggers vivos, habilitados y apuntando a sus funciones.
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN   pg_proc p ON p.oid = t.tgfoid
    WHERE  t.tgname = 'on_post_reply_change'
      AND  t.tgrelid = 'community.replies'::regclass
      AND  t.tgenabled = 'O'
      AND  p.proname = 'update_post_replies_count'
  ) INTO v_trigger_ok;
  IF NOT v_trigger_ok THEN
    v_failures := array_append(v_failures,
      'FAIL 6c: on_post_reply_change debería existir habilitado sobre community.replies ejecutando update_post_replies_count()');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN   pg_proc p ON p.oid = t.tgfoid
    WHERE  t.tgname = 'on_post_like_change'
      AND  t.tgrelid = 'community.post_likes'::regclass
      AND  t.tgenabled = 'O'
      AND  p.proname = 'update_post_likes_count'
  ) INTO v_trigger_ok;
  IF NOT v_trigger_ok THEN
    v_failures := array_append(v_failures,
      'FAIL 6d: on_post_like_change debería existir habilitado sobre community.post_likes ejecutando update_post_likes_count()');
  END IF;

  -- ── Limpieza hijo→padre ──────────────────────────────────────────────────
  DELETE FROM community.post_likes WHERE post_id = v_post_id;
  DELETE FROM community.replies    WHERE post_id = v_post_id;
  DELETE FROM community.posts      WHERE id = v_post_id;
  DELETE FROM public.cashboxes WHERE branch_id IN (
    SELECT id FROM public.branches WHERE account_id = v_user_account
  );
  -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches        WHERE account_id = v_user_account;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id = v_user_id;
  DELETE FROM public.accounts        WHERE id = v_user_account;
  DELETE FROM public.profiles        WHERE id = v_user_id;
  DELETE FROM public.email_logs      WHERE user_id = v_user_id;
  DELETE FROM auth.users             WHERE id = v_user_id;

  -- ── Veredicto ────────────────────────────────────────────────────────────
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE COMMUNITY-COUNTER-TRIGGERS FAILED:\n%',
      array_to_string(v_failures, E'\n');
  END IF;

  RAISE NOTICE 'GATE COMMUNITY-COUNTER-TRIGGERS PASSED: replies y likes persisten con contadores exactos, degrade-don''t-fail protege el dato, catálogo sin referencias a public.<tabla movida> y superficie de las funciones intacta.';

EXCEPTION
  WHEN OTHERS THEN
    -- Best-effort cleanup incluso si algo falló a mitad de camino.
    BEGIN
      BEGIN
        ALTER TABLE community.posts DROP CONSTRAINT IF EXISTS tmp_community_counter_force_fail;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
      DELETE FROM community.post_likes WHERE post_id = v_post_id;
      DELETE FROM community.replies    WHERE post_id = v_post_id;
      DELETE FROM community.posts      WHERE id = v_post_id;
      DELETE FROM public.cashboxes WHERE branch_id IN (
        SELECT id FROM public.branches WHERE account_id = v_user_account
      );
      -- sucursal-guard-vaciado-auditoria: branches ahora prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.branches        WHERE account_id = v_user_account;
      SET session_replication_role = DEFAULT;
      DELETE FROM public.account_members WHERE user_id = v_user_id;
      DELETE FROM public.accounts        WHERE id = v_user_account;
      DELETE FROM public.profiles        WHERE id = v_user_id;
      DELETE FROM public.email_logs      WHERE user_id = v_user_id;
      DELETE FROM auth.users             WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
