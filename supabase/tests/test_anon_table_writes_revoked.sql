-- =============================================================================
-- GATE: test_anon_table_writes_revoked.sql
-- CHANGE: revoke-anon-table-writes (S1) — generalización de OQ-7 de
--         sucursal-guard-vaciado-auditoria (20261014000001 §9) a TODAS las
--         tablas base de `public` Y `community` (F4, revisión adversarial),
--         vía 20261035000001_revoke_anon_table_writes.sql
--
-- QUÉ PRUEBA. Que `anon` no tiene, a nivel de TABLA, ningún privilegio de
-- escritura (INSERT/UPDATE/DELETE/TRUNCATE) sobre ninguna tabla base de
-- `public` NI de `community` (F4 — `supabase/config.toml` sirve `community`
-- por la misma API de datos) fuera de la allowlist declarada (vacía en
-- ambos schemas — ver la migración), que una tabla FUTURA en cualquiera de
-- los dos nace igual de cerrada, y que el rechazo real de un INSERT de
-- `anon` viene de la CAPA DE TABLA (GRANT) y no de la RLS.
--
-- POR QUÉ (b)/(c) NO ALCANZAN SOLOS Y HACE FALTA (d). Postgres usa el MISMO
-- SQLSTATE 42501 tanto para "permission denied for table" (falta el GRANT)
-- como para "new row violates row-level security policy" (falta la policy).
-- Medido en RED (antes de 20261035000001, contra `sales`/`clients`/
-- `products`/`expenses`/`purchases`/`payment_methods`/
-- `account_feature_flags`/`analytics_events`/`profiles`/`suppliers` — los 10
-- casos de la lista de abajo):
--   sqlstate=42501 msg="new row violates row-level security policy for
--   table ..." — es decir, el 42501 YA aparecía ANTES de este change: lo
--   producía la RLS, no el GRANT (el GRANT de tabla existía). Un gate que
--   sólo mirara el SQLSTATE habría estado en VERDE todo este tiempo sin que
--   el REVOKE de tabla existiera — exactamente el punto ciego que este
--   archivo cierra. Sólo el TEXTO del mensaje distingue qué capa frenó la
--   escritura, así que el chequeo (d) exige el prefijo
--   "permission denied for table" y además comprueba, en el mismo string,
--   que NO aparece la frase de RLS (una futura versión de Postgres podría en
--   teoría anteponer ambos textos; el NOT LIKE lo blinda).
--
-- Degrade-don't-fail: (a)-(c) son metadata/estructura, no dependen de datos,
-- corren siempre. (d) hace un INSERT real bajo `SET LOCAL ROLE anon`, sin
-- tocar ninguna cuenta sintética ni dato de otra sesión — si la tabla no
-- existe en este entorno (drift), esa iteración se omite con NOTICE en vez
-- de abortar el gate (mismo criterio que los demás gates del proyecto).
--
-- Aislamiento: TODO el archivo corre dentro de un BEGIN … ROLLBACK explícito
-- (molde de test_outbox_single_dispatcher.sql). No es sólo prolijidad: (c)
-- crea una tabla real en `public` para probar el default privilege sobre
-- objetos NUEVOS, y (d) ejecuta INSERTs reales (que fallan, por diseño) con
-- `SET LOCAL ROLE anon` contra tablas de negocio compartidas por otras
-- sesiones del stack local — el ROLLBACK garantiza que ni la tabla de sondeo
-- ni ningún side-effect de los intentos de escritura (todos rechazados, pero
-- WITH CHECK/BEFORE triggers podrían en teoría dejar rastro) sobrevivan más
-- allá de esta corrida, sin depender de que cada INSERT haya fallado.
-- =============================================================================

BEGIN;

-- ── (a) Sweep: ninguna tabla de public/community fuera de la allowlist
--       (vacía) tiene INSERT/UPDATE/DELETE/TRUNCATE para anon ──────────────
DO $$
DECLARE
  v_allowlist CONSTANT text[] := ARRAY[]::text[];  -- MISMA allowlist que 20261035000001_revoke_anon_table_writes.sql
  v_bad       text := '';
  r           RECORD;
  v_total     integer := 0;
BEGIN
  FOR r IN
    SELECT n.nspname AS schemaname, c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'community')
      AND c.relkind = 'r'
  LOOP
    v_total := v_total + 1;

    IF (r.schemaname || '.' || r.tablename) = ANY (v_allowlist) THEN
      CONTINUE;
    END IF;

    IF has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'INSERT')
       OR has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'UPDATE')
       OR has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'DELETE')
       OR has_table_privilege('anon', format('%I.%I', r.schemaname, r.tablename), 'TRUNCATE')
    THEN
      v_bad := v_bad || r.schemaname || '.' || r.tablename || ' ';
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE ANON-TABLE-WRITES FAILED (a): anon conserva privilegios de escritura a nivel TABLA sobre: %. Deberían estar revocados por 20261035000001_revoke_anon_table_writes.sql salvo entrada explícita en su allowlist (hoy vacía).', v_bad;
  END IF;

  RAISE NOTICE 'PASS (a): % tablas base de public+community revisadas, ninguna con INSERT/UPDATE/DELETE/TRUNCATE para anon fuera de la allowlist (vacía).', v_total;
END $$;


-- ── (b) Default privilege de postgres/{public,community}/tablas ya no
--       reabre para anon ───────────────────────────────────────────────────
DO $$
DECLARE
  v_schema text;
  v_acl    aclitem[];
  v_priv   text;
BEGIN
  FOREACH v_schema IN ARRAY ARRAY['public', 'community'] LOOP
    SELECT defaclacl INTO v_acl
    FROM pg_default_acl
    WHERE defaclrole = 'postgres'::regrole
      AND defaclnamespace = v_schema::regnamespace
      AND defaclobjtype = 'r';

    IF v_acl IS NULL THEN
      RAISE NOTICE 'PASS (b) degradado [%]: no hay fila pg_default_acl para postgres/%/tablas en este entorno — nada que verificar.', v_schema, v_schema;
    ELSE
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF aclcontains(v_acl, makeaclitem('anon'::regrole, 'postgres'::regrole, v_priv, false)) THEN
          RAISE EXCEPTION 'GATE ANON-TABLE-WRITES FAILED (b): el default privilege de postgres en % todavía otorga % a anon sobre tablas FUTURAS: %', v_schema, v_priv, v_acl;
        END IF;
      END LOOP;
      RAISE NOTICE 'PASS (b) [%]: el default privilege de postgres en % no incluye a anon para INSERT/UPDATE/DELETE/TRUNCATE.', v_schema, v_schema;
    END IF;
  END LOOP;
END $$;


-- ── (c) Comportamiento real: una tabla NUEVA creada por postgres en public
--       Y en community nace SIN privilegios de escritura para anon (no sólo
--       la metadata de (b) — prueba que el default privilege realmente
--       aplica) ────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_probe  CONSTANT text := '_gate_anon_table_writes_probe';
  v_schema text;
BEGIN
  FOREACH v_schema IN ARRAY ARRAY['public', 'community'] LOOP
    EXECUTE format('DROP TABLE IF EXISTS %I.%I', v_schema, v_probe);
    EXECUTE format('CREATE TABLE %I.%I (id int)', v_schema, v_probe);

    IF has_table_privilege('anon', format('%I.%I', v_schema, v_probe), 'INSERT')
       OR has_table_privilege('anon', format('%I.%I', v_schema, v_probe), 'UPDATE')
       OR has_table_privilege('anon', format('%I.%I', v_schema, v_probe), 'DELETE')
       OR has_table_privilege('anon', format('%I.%I', v_schema, v_probe), 'TRUNCATE')
    THEN
      RAISE EXCEPTION 'GATE ANON-TABLE-WRITES FAILED (c): una tabla NUEVA creada por postgres en % nace CON privilegios de escritura para anon — el default privilege no está aplicando de verdad, sólo la metadata de (b) se ve bien.', v_schema;
    END IF;

    RAISE NOTICE 'PASS (c) [%]: una tabla nueva creada por postgres en % nace sin INSERT/UPDATE/DELETE/TRUNCATE para anon (comportamiento real).', v_schema, v_schema;
  END LOOP;
  -- Se limpia por el ROLLBACK del archivo completo — no hace falta DROP acá.
END $$;


-- ── (d) Negativo real: SET LOCAL ROLE anon; INSERT real contra tablas
--       representativas de public Y community → 42501 POR LA CAPA DE TABLA
--       (mensaje "permission denied for table"), nunca por la RLS ni con
--       éxito ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_tables CONSTANT text[] := ARRAY[
    'public.sales', 'public.clients', 'public.products', 'public.expenses',
    'public.purchases', 'public.payment_methods', 'public.account_feature_flags',
    'public.analytics_events', 'public.profiles', 'public.suppliers',
    'public.branches', 'public.events', 'public.document_status_transitions',
    -- F4: representativas de community — posts/replies (roles={public},
    -- auth.uid()=user_id) y course_progress (roles={authenticated},
    -- current_account_ids()) cubren los dos patrones de policy del schema.
    'community.posts', 'community.replies', 'community.course_progress'
  ];
  v_t        text;
  v_schema   text;
  v_table    text;
  v_sqlstate text;
  v_msg      text;
  v_bad      text := '';
  v_checked  integer := 0;
BEGIN
  FOREACH v_t IN ARRAY v_tables LOOP
    v_schema := split_part(v_t, '.', 1);
    v_table  := split_part(v_t, '.', 2);

    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_schema AND c.relname = v_table AND c.relkind = 'r'
    ) THEN
      RAISE NOTICE 'GATE ANON-TABLE-WRITES (d) degradado: la tabla % no existe en este entorno, se omite.', v_t;
      CONTINUE;
    END IF;

    v_checked := v_checked + 1;
    EXECUTE 'SET LOCAL ROLE anon';
    BEGIN
      EXECUTE format('INSERT INTO %I.%I DEFAULT VALUES', v_schema, v_table);
      v_sqlstate := 'NO_ERROR';
      v_msg := 'el INSERT tuvo éxito (no debería)';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;
    EXECUTE 'RESET ROLE';

    IF NOT (
      v_sqlstate = '42501'
      AND v_msg ILIKE 'permission denied for table%'
      AND v_msg NOT ILIKE '%row-level security%'
    ) THEN
      v_bad := v_bad || format('%s(sqlstate=%s,msg=%s); ', v_t, v_sqlstate, v_msg);
    END IF;
  END LOOP;

  IF v_checked = 0 THEN
    RAISE NOTICE 'GATE ANON-TABLE-WRITES (d) degradado: ninguna de las tablas representativas existe en este entorno — chequeo omitido.';
    RETURN;
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION 'GATE ANON-TABLE-WRITES FAILED (d): el rechazo de anon debe venir de la CAPA DE TABLA ("permission denied for table"), nunca de la RLS ("new row violates row-level security policy") ni de un INSERT exitoso — %', v_bad;
  END IF;

  RAISE NOTICE 'PASS (d): % tablas representativas (public+community) rechazan el INSERT de anon con "permission denied for table" (capa de GRANT, no RLS).', v_checked;
END $$;

ROLLBACK;
