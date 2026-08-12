-- =============================================================================
-- community-counter-triggers-schema-fix
--
-- BUG QUE CORRIGE (producción, activo desde 2026-06-15)
--   C-23 (20260615000001_community_schema_move.sql) movió 16 tablas de `public`
--   a `community` con ALTER TABLE ... SET SCHEMA. Esa sentencia mueve la tabla
--   y CONSERVA los triggers colgados de ella, pero NO reescribe el cuerpo de
--   las funciones que esos triggers ejecutan. Las dos funciones de contador
--   quedaron haciendo `UPDATE public.posts ...` contra una tabla inexistente.
--   Como on_post_reply_change / on_post_like_change son triggers AFTER, el
--   42P01 aborta la transacción que los disparó: responder un post y dar o
--   sacar un like fallaban por completo, sin persistir la fila.
--
-- EVIDENCIA DE PRODUCCIÓN (gxdhpxvdjjkmxhdkkwyb, lectura de catálogo 2026-08-12)
--   · pg_proc: el prosrc de ambas matchea \mpublic\.posts\M y NO matchea
--     \mcommunity\.posts\M; proconfig = {search_path=public}.
--   · to_regclass('public.posts') = NULL — la tabla no existe: 42P01 garantizado.
--   · pg_trigger: ambos triggers habilitados (tgenabled='O') sobre las tablas
--     ya movidas.
--   · Daño consumado BAJO y acotado: pg_stat_all_tables da n_tup_ins = 0 y
--     n_dead_tup = 0 en community.post_likes, y ese contador incluye los
--     inserts cuya transacción luego aborta, o sea que mide INTENTOS — hubo
--     cero. La actividad de comunidad se apagó ANTES del corte (último post
--     2026-05-08, última reply 2026-05-31). No hay damnificados que recuperar;
--     sí una funcionalidad del plan PRO rota para el primero que la use.
--
-- QUÉ HACE
--   1. Redefine ambas funciones calificando community.posts (D1/D2).
--   2. Envuelve el UPDATE en un guard degrade-don't-fail (D3): un fallo del
--      contador emite WARNING y deja persistir la fila de negocio.
--   3. Recompute idempotente de los contadores contra el COUNT(*) real (D7).
--   4. Re-afirma los ACLs restrictivos de forma drift-tolerante (D4).
--   5. Gate inline: verifica el resultado y aborta si no quedó como se espera.
--
-- IDEMPOTENCIA: obligatoria. La integración GitHub de Supabase auto-aplica las
-- migraciones al mergear, ANTES del `db push` de GitHub Actions, así que esta
-- migración se aplica dos veces. CREATE OR REPLACE, REVOKE repetido y recompute
-- a valor absoluto son todos no-op en la segunda pasada.
--
-- ROLLBACK: re-aplicar el cuerpo previo de ambas funciones con CREATE OR
-- REPLACE (restaura el estado roto — solo tiene sentido si el fix introdujera
-- un problema peor). Los contadores recomputados no requieren rollback: son el
-- valor correcto bajo cualquiera de las dos versiones.
--
-- Gate de regresión: supabase/tests/test_community_interactions.sql (CI).
-- Governance: MEDIO.
-- =============================================================================

-- ── 1. update_post_replies_count ─────────────────────────────────────────────
-- Sin DROP previo: RETURNS trigger sin parámetros, así que CREATE OR REPLACE
-- no puede crear un segundo overload (no aplica el gotcha 42725) y los triggers
-- conservan el mismo oid sin recrearse.
CREATE OR REPLACE FUNCTION public.update_post_replies_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  -- Se resuelve el post ANTES del UPDATE y se guarda en una variable local:
  -- en un trigger DELETE la variable NEW esta sin asignar, y tocar NEW.post_id
  -- dentro del handler de excepcion lanzaria "record new is not assigned yet",
  -- rompiendo el guard justo en el camino que debe proteger.
  v_post_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.post_id ELSE NEW.post_id END;
BEGIN
  -- Guard degrade-don't-fail: la fila de community.replies es el hecho de
  -- negocio; replies_count es una desnormalización cosmética. Un contador
  -- nunca debe tener poder de veto sobre la operación del usuario.
  -- Precedentes: analytics_emit_operation_event (20260914000001),
  -- handle_new_user (20260812000001).
  BEGIN
    IF (TG_OP = 'INSERT') THEN
      UPDATE community.posts SET replies_count = replies_count + 1 WHERE id = v_post_id;
    ELSIF (TG_OP = 'DELETE') THEN
      UPDATE community.posts SET replies_count = replies_count - 1 WHERE id = v_post_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'update_post_replies_count: no se pudo actualizar replies_count del post % (TG_OP=%): % -- la reply se persiste igual (degrade-dont-fail)',
      v_post_id, TG_OP, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

-- ── 2. update_post_likes_count ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_post_likes_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  -- Mismo motivo que en update_post_replies_count: NEW no existe en DELETE.
  v_post_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.post_id ELSE NEW.post_id END;
BEGIN
  BEGIN
    IF (TG_OP = 'INSERT') THEN
      UPDATE community.posts SET likes_count = likes_count + 1 WHERE id = v_post_id;
    ELSIF (TG_OP = 'DELETE') THEN
      UPDATE community.posts SET likes_count = likes_count - 1 WHERE id = v_post_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'update_post_likes_count: no se pudo actualizar likes_count del post % (TG_OP=%): % -- el like se persiste igual (degrade-dont-fail)',
      v_post_id, TG_OP, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

-- ── 3. Recompute idempotente de los contadores ───────────────────────────────
-- Valor absoluto derivado del COUNT(*) real, no un delta: re-ejecutar la
-- migración es inofensivo. En prod hoy es un no-op verificado (los contadores
-- ya coinciden), pero afirma el invariante en la misma migración que restituye
-- el mecanismo que lo mantiene.
UPDATE community.posts p
SET    replies_count = COALESCE((SELECT count(*) FROM community.replies    r WHERE r.post_id = p.id), 0),
       likes_count   = COALESCE((SELECT count(*) FROM community.post_likes l WHERE l.post_id = p.id), 0)
WHERE  p.replies_count IS DISTINCT FROM COALESCE((SELECT count(*) FROM community.replies    r WHERE r.post_id = p.id), 0)
   OR  p.likes_count   IS DISTINCT FROM COALESCE((SELECT count(*) FROM community.post_likes l WHERE l.post_id = p.id), 0);

-- ── 4. Re-afirmar ACLs restrictivos (drift-tolerante) ────────────────────────
-- CREATE OR REPLACE preserva los ACLs (solo DROP+CREATE los resetea — hallazgo
-- sistémico de 20260822000001), así que esto es un no-op defensivo barato.
DO $$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.update_post_replies_count()',
    'public.update_post_likes_count()'
  ]
  LOOP
    CONTINUE WHEN to_regprocedure(v_fn) IS NULL;  -- drift-tolerante
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', v_fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', v_fn);
  END LOOP;
END $$;

-- ── 5. Gate inline (patrón 20260822000001) ───────────────────────────────────
DO $$
DECLARE
  v_failures text[] := '{}';
  v_proname  text;
  v_count    int;
BEGIN
  FOREACH v_proname IN ARRAY ARRAY['update_post_replies_count', 'update_post_likes_count']
  LOOP
    SELECT count(*) INTO v_count
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname;
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('public.%s: %s definiciones (esperado 1)', v_proname, v_count));
    END IF;

    SELECT count(*) INTO v_count
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname
      AND  p.prosrc ~ '\mpublic\.posts\M';
    IF v_count <> 0 THEN
      v_failures := array_append(v_failures, format('public.%s todavia referencia public.posts', v_proname));
    END IF;

    SELECT count(*) INTO v_count
    FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public' AND p.proname = v_proname
      AND  p.prosrc ~ '\mcommunity\.posts\M';
    IF v_count <> 1 THEN
      v_failures := array_append(v_failures, format('public.%s deberia referenciar community.posts', v_proname));
    END IF;
  END LOOP;

  -- Los triggers deben seguir vivos y habilitados (CREATE OR REPLACE no los toca).
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'on_post_reply_change' AND tgrelid = 'community.replies'::regclass AND tgenabled = 'O'
  ) THEN
    v_failures := array_append(v_failures, 'on_post_reply_change no esta habilitado sobre community.replies');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'on_post_like_change' AND tgrelid = 'community.post_likes'::regclass AND tgenabled = 'O'
  ) THEN
    v_failures := array_append(v_failures, 'on_post_like_change no esta habilitado sobre community.post_likes');
  END IF;

  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'20260918000001 gate inline FAILED:\n%', array_to_string(v_failures, E'\n');
  END IF;

  RAISE NOTICE '20260918000001: funciones de contador calificadas a community.posts, triggers habilitados, ACLs re-afirmados.';
END $$;
