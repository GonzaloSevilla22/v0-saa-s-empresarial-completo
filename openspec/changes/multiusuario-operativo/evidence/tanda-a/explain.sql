-- 2.5 EXPLAIN (ANALYZE) antes/después de current_account_ids() — base LOCAL, dentro de BEGIN..ROLLBACK.
\set ON_ERROR_STOP on
\pset pager off
BEGIN;

-- ── Fixture: un usuario de UNA cuenta (el caso de los 41 de hoy) con 20.000 ventas, 10.000 compras y 5.000 gastos ──
CREATE TEMP TABLE xp_ctx (user_id uuid, account_id uuid);
DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc  uuid;
  v_branch uuid;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'explain-mu@test.local', now(), now(), '{"name":"Explain"}'::jsonb);
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_user;
  SELECT id INTO v_branch FROM public.branches WHERE account_id = v_acc LIMIT 1;
  INSERT INTO public.sales (user_id, account_id, amount, total, date, branch_id)
  SELECT v_user, v_acc, (100 + g % 900), (100 + g % 900), now() - (g % 400) * interval '1 hour', v_branch
  FROM generate_series(1, 20000) g;
  INSERT INTO public.purchases (user_id, account_id, amount, total, date, branch_id)
  SELECT v_user, v_acc, (50 + g % 500), (50 + g % 500), now() - (g % 400) * interval '1 hour', v_branch
  FROM generate_series(1, 10000) g;
  INSERT INTO public.expenses (user_id, account_id, category, amount, date, branch_id)
  SELECT v_user, v_acc, 'Varios', (10 + g % 100), now() - (g % 400) * interval '1 hour', v_branch
  FROM generate_series(1, 5000) g;
  INSERT INTO xp_ctx VALUES (v_user, v_acc);
END $$;
ANALYZE public.sales; ANALYZE public.purchases; ANALYZE public.expenses; ANALYZE public.account_members; ANALYZE public.profiles;

-- Medición: N repeticiones de cada consulta bajo `authenticated`, con RLS (la política llama a current_account_ids()).
CREATE TEMP TABLE xp_res (fase text, consulta text, ms_mediana numeric, ms_p95 numeric);
CREATE OR REPLACE FUNCTION pg_temp.xp_run(p_fase text, p_with_claim boolean) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_user uuid; v_acc uuid;
  v_n int := 40;
  i int; t0 timestamptz; t1 timestamptz;
  v_times numeric[];
  q record;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM xp_ctx;
  IF p_with_claim THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated',
      'app_metadata', json_build_object('account_id', v_acc::text))::text, true);
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  END IF;
  FOR q IN SELECT * FROM (VALUES
      ('ventas_lista_50', 'SELECT id, date, amount FROM public.sales ORDER BY date DESC LIMIT 50'),
      ('ventas_conteo', 'SELECT count(*) FROM public.sales'),
      ('dashboard_financials_30d', 'SELECT * FROM public.get_dashboard_financials(now() - interval ''30 days'', now(), NULL)'),
      ('current_account_ids_sola', 'SELECT count(*) FROM public.current_account_ids()')
    ) AS t(nombre, sql) LOOP
    v_times := ARRAY[]::numeric[];
    SET LOCAL ROLE authenticated;
    FOR i IN 1..v_n LOOP
      t0 := clock_timestamp();
      EXECUTE q.sql;
      t1 := clock_timestamp();
      v_times := v_times || (EXTRACT(EPOCH FROM (t1 - t0)) * 1000)::numeric;
    END LOOP;
    RESET ROLE;
    INSERT INTO xp_res
    SELECT p_fase, q.nombre,
           round((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x) FROM unnest(v_times) x)::numeric, 3),
           round((SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY x) FROM unnest(v_times) x)::numeric, 3);
  END LOOP;
END $f$;

-- ═══ DESPUÉS (la migración vigente) ═══
SELECT pg_temp.xp_run('despues_sin_claim', false);
SELECT pg_temp.xp_run('despues_con_claim', true);

-- ── EXPLAIN (ANALYZE) puntuales DESPUÉS, como `authenticated` con el claim ──
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT user_id::text FROM xp_ctx), 'role', 'authenticated',
  'app_metadata', json_build_object('account_id', (SELECT account_id::text FROM xp_ctx)))::text, true);
\echo '=== EXPLAIN ANALYZE DESPUES: ventas_lista_50 (con claim) ==='
SET LOCAL ROLE authenticated;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT id, date, amount FROM public.sales ORDER BY date DESC LIMIT 50;
RESET ROLE;
\echo '=== EXPLAIN ANALYZE DESPUES: dashboard_financials_30d (con claim) ==='
SET LOCAL ROLE authenticated;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM public.get_dashboard_financials(now() - interval '30 days', now(), NULL);
RESET ROLE;

-- ═══ ANTES: se reinstala el cuerpo previo de current_account_ids() (rollback documentado) ═══
CREATE OR REPLACE FUNCTION public.current_account_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT account_id
  FROM   public.account_members
  WHERE  user_id = (SELECT auth.uid())
$function$;
SELECT pg_temp.xp_run('antes', false);

SELECT fase, consulta, ms_mediana, ms_p95 FROM xp_res ORDER BY consulta, fase;

-- ── EXPLAIN (ANALYZE) puntuales, como `authenticated` ──
\echo '=== EXPLAIN ANALYZE ANTES: ventas_lista_50 (current_account_ids anterior) ==='
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT user_id::text FROM xp_ctx), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT id, date, amount FROM public.sales ORDER BY date DESC LIMIT 50;
RESET ROLE;

\echo '=== EXPLAIN ANALYZE ANTES: dashboard_financials_30d ==='
SET LOCAL ROLE authenticated;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT * FROM public.get_dashboard_financials(now() - interval '30 days', now(), NULL);
RESET ROLE;
ROLLBACK;
