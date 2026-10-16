-- =============================================================================
-- GATE: test_multiusuario_cuenta_activa.sql
-- CHANGE: multiusuario-operativo — TANDA A (tasks 1.1-1.4, 2.4)
--
-- Ejercita de verdad, como `authenticated` con `request.jwt.claims` armado a
-- mano (el mismo mecanismo que PostgREST y que `get_db_conn` de FastAPI), que
-- un usuario de DOS cuentas opera siempre sobre UNA — la cuenta activa — y que
-- esa cuenta es la misma en la base, en el token y en cada RPC.
--
--   EL HUECO. Todo invitado tiene además su cuenta personal (la crea
--   `handle_new_user`). 45 funciones resuelven la cuenta con
--   `SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1`
--   SIN `ORDER BY`, y `current_account_ids()` devolvía TODAS las membresías: el
--   humo S20 de la auditoría de stock (2026-10-14) vio que la venta de servicio
--   de un invitado quedaba en su cuenta personal (R3l), que el POS buscaba el
--   stock en la personal (R3j, P0409) y que `rpc_import_products` rechazaba al
--   usuario de dos cuentas (`cuenta_ambigua`). Mientras tanto el token, FastAPI,
--   las Edge Functions y el frontend elegían OTRA (la más antigua): cuatro
--   criterios de "cuenta activa" conviviendo.
--
--   EL ARREGLO (design.md D1-D5). `current_account_ids()` pasa a devolver la
--   cuenta ACTIVA (0 o 1 fila): primero el claim `app_metadata.account_id` del
--   request validado contra la membresía viva (fail-closed: un claim de una
--   cuenta de la que el usuario ya no es miembro NO cae en silencio a otra);
--   si el claim falta, `resolve_active_account(auth.uid())` = la preferencia
--   `profiles.active_account_id` si sigue siendo una membresía, si no la más
--   antigua por (created_at, id). El hook emite el claim junto con los roles y el
--   plan DE ESA cuenta.
--
-- Fixtures (todos @test.local, dentro de BEGIN..ROLLBACK: residuo cero):
--   O  dueño de la cuenta A (con un producto y una venta)
--   U1 usuario de UNA sola cuenta (P1)  — control de no regresión de los 41
--   U2 usuario de DOS cuentas: su personal P2 (la más antigua) y A (seller)
--   Z  dueño de una tercera cuenta a la que U2 NUNCA perteneció
--
-- Estructura: cada bloque corre en su propio sub-bloque con EXCEPTION y registra
-- su falla en vez de abortar, así el RED (1.4) muestra de una vez QUÉ bloques
-- fallan y por qué; al final, si hubo alguna, el gate aborta listándolas.
--
--   (a) U1, con claim y sin claim, ve exactamente su cuenta (no regresión)
--   (b) U2 sin preferencia ve sólo P2; con la preferencia en A, ve sólo A
--   (c) rpc_set_active_account(A) funciona; con una cuenta ajena da P0404,
--       indistinguible de una inexistente; sin sesión da P0401
--   (d) un claim app_metadata.account_id gana sobre la preferencia
--   (e) un claim de una cuenta de la que U2 nunca fue / ya no es miembro
--       devuelve 0 filas (fail-closed); un claim malformado también
--   (f) el hook emite account_id, account_roles y plan de la cuenta ACTIVA, y
--       conserva su rama de degradación (claims intactos + WARNING)
--   (g) RLS bajo SET LOCAL ROLE authenticated: sales y accounts sólo de la activa
--   (h) get_dashboard_financials y rpc_period_comparison no suman la otra cuenta
--   (i) R3j / R3l: con A activa, el POS y la venta de servicio quedan en A
--       (por claim y por preferencia), y con P2 activa quedan en P2
--   (j) un gasto de U2 queda en la cuenta activa
--   (k) rpc_import_products en dry run ya no responde cuenta_ambigua
--   (l) rpc_my_active_account_roles() devuelve los roles de U2 en la ACTIVA
--   (m) rpc_my_effective_plan() devuelve el plan de la ACTIVA
--   (n) rpc_atomic_log_ai_insight y el trigger set_insight_account_id sellan la activa
--   (o) rpc_my_accounts(): una fila por membresía, una sola activa, campos crudos
--   (p) get_account_ids_for_user sigue devolviendo TODAS las membresías
--   (s) ESTRUCTURAL: resolve_active_account sin EXECUTE para anon/authenticated y
--       con EXECUTE para supabase_auth_admin; profiles.active_account_id fuera
--       de los privilegios de escritura; una definición por función; barrido por
--       convención (D15): ninguna función de public fuera de la allow-list resuelve
--       la membresía de un usuario con `LIMIT 1` sin acotar por cuenta.
-- =============================================================================

BEGIN;

-- ── Helpers (sesión; viven en pg_temp) ───────────────────────────────────────

-- Impersona a un usuario. `p_account` simula el claim app_metadata.account_id
-- del token (NULL = token sin el claim: emitido antes del deploy).
CREATE FUNCTION pg_temp.as_user(p_user uuid, p_account text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE
  v jsonb := jsonb_build_object('sub', p_user::text, 'role', 'authenticated');
BEGIN
  IF p_account IS NOT NULL THEN
    v := v || jsonb_build_object('app_metadata', jsonb_build_object('account_id', p_account));
  END IF;
  PERFORM set_config('request.jwt.claims', v::text, true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $f$;

-- Sin sesión (ni sub ni claims).
CREATE FUNCTION pg_temp.as_anon() RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $f$;

-- Lo que devuelve current_account_ids() para el caller actual, como el rol de la
-- aplicación (ordenado, para comparar arrays).
CREATE FUNCTION pg_temp.cai() RETURNS uuid[]
LANGUAGE plpgsql AS $f$
DECLARE v uuid[];
BEGIN
  SET LOCAL ROLE authenticated;
  SELECT COALESCE(array_agg(c ORDER BY c), ARRAY[]::uuid[]) INTO v FROM public.current_account_ids() c;
  RESET ROLE;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END $f$;

-- Corre una expresión de RPC como `authenticated`. NUNCA lanza: devuelve estado/mensaje.
CREATE FUNCTION pg_temp.try_rpc(p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE format('SELECT to_jsonb(%s)', p_expr) INTO o_res;
  RESET ROLE;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  o_res := NULL;
  RESET ROLE;
END $f$;

-- Filas de una consulta como `authenticated`, en jsonb. Lanza si la consulta lanza.
CREATE FUNCTION pg_temp.q(p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  SET LOCAL ROLE authenticated;
  EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) FROM (%s) t', p_sql) INTO v;
  RESET ROLE;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END $f$;

-- Fija / limpia la preferencia por SQL dinámico: antes de la migración la columna
-- no existe y el bloque que la FIJA debe fallar con ESE motivo, no al compilar el DO.
-- Limpiarla (NULL) es un no-op si la columna todavía no existe: así los bloques que
-- se apoyan en el CLAIM fallan antes de la migración por su comportamiento real (la
-- cuenta que resuelve la base), no por un efecto colateral del fixture.
CREATE FUNCTION pg_temp.set_pref(p_user uuid, p_account uuid) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_account IS NULL AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'active_account_id'
  ) THEN
    RETURN;
  END IF;
  EXECUTE format('UPDATE public.profiles SET active_account_id = %L WHERE id = %L', p_account, p_user);
END $f$;

CREATE FUNCTION pg_temp.ids_txt(p uuid[]) RETURNS text
LANGUAGE sql AS $f$ SELECT COALESCE(array_to_string(p, ','), '(vacío)') $f$;

-- ═════════════════════════════════════════════════════════════════════════════
DO $gate$
DECLARE
  v_fail       text[] := ARRAY[]::text[];
  v_blk        text;
  v_today      date := public.reporting_local_today();

  -- usuarios y cuentas
  v_o   uuid := gen_random_uuid();   v_u1 uuid := gen_random_uuid();
  v_u2  uuid := gen_random_uuid();   v_z  uuid := gen_random_uuid();
  v_a   uuid;   -- cuenta del dueño O (la del negocio)
  v_p1  uuid;   -- cuenta personal de U1
  v_p2  uuid;   -- cuenta personal de U2 (la más antigua de U2)
  v_zz  uuid;   -- cuenta de Z
  v_m_u2_a uuid;

  -- datos de negocio
  v_prod_a  uuid;
  v_branch_a uuid;
  v_sale_a  uuid;  v_sale_p2 uuid;  v_sale_p1 uuid;

  -- scratch
  v_ids   uuid[];
  v_r     record;
  v_r2    record;
  v_j     jsonb;
  v_n     integer;
  v_txt   text;
  v_acc   uuid;
  v_op    uuid;
BEGIN
  -- ── Fixtures ───────────────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
    (v_o,  'authenticated', 'authenticated', 'multiusuario-a-owner@test.local', now(), now(), '{"name":"MU Owner"}'::jsonb),
    (v_u1, 'authenticated', 'authenticated', 'multiusuario-a-u1@test.local',    now(), now(), '{"name":"MU Uno"}'::jsonb),
    (v_u2, 'authenticated', 'authenticated', 'multiusuario-a-u2@test.local',    now(), now(), '{"name":"MU Dos"}'::jsonb),
    (v_z,  'authenticated', 'authenticated', 'multiusuario-a-z@test.local',     now(), now(), '{"name":"MU Zeta"}'::jsonb);

  SELECT account_id INTO v_a  FROM public.account_members WHERE user_id = v_o;
  SELECT account_id INTO v_p1 FROM public.account_members WHERE user_id = v_u1;
  SELECT account_id INTO v_p2 FROM public.account_members WHERE user_id = v_u2;
  SELECT account_id INTO v_zz FROM public.account_members WHERE user_id = v_z;

  IF v_a IS NULL OR v_p1 IS NULL OR v_p2 IS NULL OR v_zz IS NULL THEN
    RAISE EXCEPTION 'GATE MULTIUSUARIO-CUENTA-ACTIVA (fixture): handle_new_user no creó la cuenta de algún usuario sintético (a=%, p1=%, p2=%, z=%).', v_a, v_p1, v_p2, v_zz;
  END IF;

  -- U2: su personal es la MÁS ANTIGUA (los created_at se fijan explícitos: dentro de
  -- una transacción now() es constante y el desempate por id sería aleatorio).
  UPDATE public.account_members SET created_at = now() - interval '2 days' WHERE user_id = v_u2 AND account_id = v_p2;
  INSERT INTO public.account_members (account_id, user_id, role, created_at)
  VALUES (v_a, v_u2, 'member', now() - interval '1 day')
  RETURNING id INTO v_m_u2_a;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_m_u2_a, 'seller');

  -- Planes efectivos DISTINTOS por cuenta, para poder distinguir cuál se resolvió.
  UPDATE public.accounts SET trial_plan = NULL, trial_expires_at = NULL, billing_plan = 'inicial',  billing_status = 'active', plan_expires_at = NULL WHERE id = v_p2;
  UPDATE public.accounts SET trial_plan = NULL, trial_expires_at = NULL, billing_plan = 'avanzado', billing_status = 'active', plan_expires_at = NULL WHERE id = v_a;
  UPDATE public.profiles SET business_name = 'MU Negocio Dos' WHERE id = v_u2;
  UPDATE public.profiles SET business_name = 'MU Negocio Owner' WHERE id = v_o;

  -- Un producto con stock en A (lo creó el dueño, no U2) y una venta en cada cuenta.
  SELECT id INTO v_branch_a FROM public.branches WHERE account_id = v_a ORDER BY created_at LIMIT 1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_o, v_a, 'GATE-MU-A', 'GATE-MU-A-1', 60, 100) RETURNING id INTO v_prod_a;
  PERFORM public.c21_apply_branch_stock_delta(v_a, v_prod_a, v_branch_a, 30);

  INSERT INTO public.sales (user_id, account_id, amount, total, date) VALUES (v_o,  v_a,  1000, 1000, now()) RETURNING id INTO v_sale_a;
  INSERT INTO public.sales (user_id, account_id, amount, total, date) VALUES (v_u2, v_p2,  100,  100, now()) RETURNING id INTO v_sale_p2;
  INSERT INTO public.sales (user_id, account_id, amount, total, date) VALUES (v_u1, v_p1,    7,    7, now()) RETURNING id INTO v_sale_p1;

  -- ── (a) U1, con claim y sin claim, ve exactamente su cuenta (no regresión) ──
  v_blk := '(a)';
  BEGIN
    PERFORM pg_temp.as_user(v_u1);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_p1] THEN
      RAISE EXCEPTION 'U1 sin claim debía ver sólo su cuenta %, vio %', v_p1, pg_temp.ids_txt(v_ids);
    END IF;
    PERFORM pg_temp.as_user(v_u1, v_p1::text);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_p1] THEN
      RAISE EXCEPTION 'U1 con el claim de su cuenta debía ver sólo %, vio %', v_p1, pg_temp.ids_txt(v_ids);
    END IF;
    PERFORM pg_temp.as_user(v_u1);
    v_j := pg_temp.q('SELECT public.rpc_my_active_account_roles() AS roles');
    IF v_j -> 0 -> 'roles' <> '["owner"]'::jsonb THEN
      RAISE EXCEPTION 'U1: rpc_my_active_account_roles() debía devolver ["owner"], devolvió %', v_j;
    END IF;
    RAISE NOTICE 'PASS (a): el usuario de una sola cuenta ve exactamente su cuenta, con y sin claim.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (b) U2: sin preferencia sólo P2; con la preferencia en A, sólo A ────────
  v_blk := '(b)';
  BEGIN
    PERFORM pg_temp.as_user(v_u2);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_p2] THEN
      RAISE EXCEPTION 'U2 sin preferencia debía ver sólo su cuenta más antigua %, vio %', v_p2, pg_temp.ids_txt(v_ids);
    END IF;

    PERFORM pg_temp.set_pref(v_u2, v_a);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_a] THEN
      RAISE EXCEPTION 'U2 con la preferencia en A debía ver sólo %, vio %', v_a, pg_temp.ids_txt(v_ids);
    END IF;

    -- Una preferencia que NO es una membresía se ignora: cae a la más antigua.
    PERFORM pg_temp.set_pref(v_u2, v_zz);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_p2] THEN
      RAISE EXCEPTION 'U2 con una preferencia que no es membresía (Z) debía caer a la más antigua %, vio %', v_p2, pg_temp.ids_txt(v_ids);
    END IF;

    PERFORM pg_temp.set_pref(v_u2, NULL);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_p2] THEN
      RAISE EXCEPTION 'U2 con la preferencia limpia debía volver a %, vio %', v_p2, pg_temp.ids_txt(v_ids);
    END IF;
    RAISE NOTICE 'PASS (b): sin preferencia gana la más antigua; con preferencia válida gana la preferencia; una preferencia inválida se ignora.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (c) rpc_set_active_account ──────────────────────────────────────────────
  v_blk := '(c)';
  BEGIN
    PERFORM pg_temp.as_user(v_u2);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_set_active_account(%L::uuid)', v_a));
    IF v_r.o_state <> '00000' THEN
      RAISE EXCEPTION 'rpc_set_active_account(A) debía funcionar, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_a] THEN
      RAISE EXCEPTION 'tras rpc_set_active_account(A) la cuenta activa debía ser %, es %', v_a, pg_temp.ids_txt(v_ids);
    END IF;

    -- Cuenta AJENA (existe pero U2 no es miembro) vs. cuenta INEXISTENTE: P0404 los dos,
    -- con el MISMO mensaje (no se revela si la cuenta existe).
    SELECT * INTO v_r  FROM pg_temp.try_rpc(format('public.rpc_set_active_account(%L::uuid)', v_zz));
    SELECT * INTO v_r2 FROM pg_temp.try_rpc(format('public.rpc_set_active_account(%L::uuid)', gen_random_uuid()));
    IF v_r.o_state <> 'P0404' OR v_r2.o_state <> 'P0404' THEN
      RAISE EXCEPTION 'una cuenta ajena / inexistente debía dar P0404; dieron % / %', v_r.o_state, v_r2.o_state;
    END IF;
    IF v_r.o_msg IS DISTINCT FROM v_r2.o_msg THEN
      RAISE EXCEPTION 'el rechazo de una cuenta ajena (%) es distinguible del de una inexistente (%)', v_r.o_msg, v_r2.o_msg;
    END IF;
    -- El rechazo no tocó la preferencia.
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_a] THEN
      RAISE EXCEPTION 'un rechazo no debía cambiar la cuenta activa (era A=%), quedó %', v_a, pg_temp.ids_txt(v_ids);
    END IF;

    -- Volver a la personal funciona también (es el mismo camino que el selector).
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_set_active_account(%L::uuid)', v_p2));
    IF v_r.o_state <> '00000' OR pg_temp.cai() <> ARRAY[v_p2] THEN
      RAISE EXCEPTION 'volver a la cuenta personal debía funcionar: % %', v_r.o_state, v_r.o_msg;
    END IF;

    -- Sin sesión: P0401 (no 500 ni éxito silencioso).
    PERFORM pg_temp.as_anon();
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_set_active_account(%L::uuid)', v_a));
    IF v_r.o_state <> 'P0401' THEN
      RAISE EXCEPTION 'sin sesión debía dar P0401, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    RAISE NOTICE 'PASS (c): rpc_set_active_account cambia la cuenta, rechaza una ajena con P0404 indistinguible de una inexistente y sin sesión da P0401.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (d) el claim gana sobre la preferencia ──────────────────────────────────
  v_blk := '(d)';
  BEGIN
    -- Sin preferencia y con el claim de A: A (la más antigua de U2 es P2, así que sólo el claim explica A).
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_a] THEN
      RAISE EXCEPTION 'sin preferencia y con el claim de A debía ver sólo A (%), vio %', v_a, pg_temp.ids_txt(v_ids);
    END IF;
    -- Con la preferencia en A y el claim de P2: gana el claim.
    PERFORM pg_temp.set_pref(v_u2, v_a);
    PERFORM pg_temp.as_user(v_u2, v_p2::text);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_p2] THEN
      RAISE EXCEPTION 'con la preferencia en A y el claim de P2 debía ganar el claim (%), vio %', v_p2, pg_temp.ids_txt(v_ids);
    END IF;
    PERFORM pg_temp.set_pref(v_u2, v_p2);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_a] THEN
      RAISE EXCEPTION 'con la preferencia en P2 y el claim de A debía ganar el claim (%), vio %', v_a, pg_temp.ids_txt(v_ids);
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    RAISE NOTICE 'PASS (d): el claim del token gana sobre la preferencia guardada, en los dos sentidos.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (e) un claim de una cuenta que no es (o ya no es) membresía: 0 filas ────
  v_blk := '(e)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    -- Z: U2 nunca fue miembro.
    PERFORM pg_temp.as_user(v_u2, v_zz::text);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[]::uuid[] THEN
      RAISE EXCEPTION 'el claim de una cuenta ajena (Z) debía devolver 0 filas, devolvió %', pg_temp.ids_txt(v_ids);
    END IF;

    -- U2 es miembro de Z y después lo quitan, con el token todavía vigente.
    INSERT INTO public.account_members (account_id, user_id, role, created_at) VALUES (v_zz, v_u2, 'member', now());
    PERFORM pg_temp.as_user(v_u2, v_zz::text);
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_zz] THEN
      RAISE EXCEPTION 'mientras es miembro de Z el claim de Z debía ver Z, vio %', pg_temp.ids_txt(v_ids);
    END IF;
    DELETE FROM public.account_members WHERE user_id = v_u2 AND account_id = v_zz;
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[]::uuid[] THEN
      RAISE EXCEPTION 'tras quitarlo de Z, el claim de Z debía devolver 0 filas (NO caer a otra cuenta), devolvió %', pg_temp.ids_txt(v_ids);
    END IF;

    -- Claim malformado / vacío.
    PERFORM pg_temp.as_user(v_u2, 'no-es-un-uuid');
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[]::uuid[] THEN
      RAISE EXCEPTION 'un claim que no es un uuid debía fallar cerrado (0 filas), devolvió %', pg_temp.ids_txt(v_ids);
    END IF;
    PERFORM pg_temp.as_user(v_u2, '');
    v_ids := pg_temp.cai();
    IF v_ids <> ARRAY[v_p2] THEN
      RAISE EXCEPTION 'un claim vacío cuenta como ausente: debía resolver la más antigua %, devolvió %', v_p2, pg_temp.ids_txt(v_ids);
    END IF;

    -- Los puntos de entrada lo reflejan: sin cuenta activa el reporte se rechaza (P0403).
    PERFORM pg_temp.as_user(v_u2, v_zz::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc('public.rpc_period_comparison(current_date, current_date, current_date, current_date)');
    IF v_r.o_state <> 'P0403' THEN
      RAISE EXCEPTION 'rpc_period_comparison con un claim sin membresía debía dar P0403 (sin cuenta activa), dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    RAISE NOTICE 'PASS (e): un claim de una cuenta ajena o revocada devuelve 0 filas y nunca cae en silencio a otra cuenta.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (f) el hook emite account_id, roles y plan de la cuenta ACTIVA ──────────
  v_blk := '(f)';
  BEGIN
    PERFORM pg_temp.as_anon();
    -- U2 sin preferencia → P2 (owner, plan inicial)
    PERFORM pg_temp.set_pref(v_u2, NULL);
    v_j := public.custom_access_token_hook(jsonb_build_object(
      'user_id', v_u2, 'claims', jsonb_build_object('app_metadata', jsonb_build_object('provider', 'email'))));
    IF (v_j #>> '{claims,app_metadata,account_id}') IS DISTINCT FROM v_p2::text THEN
      RAISE EXCEPTION 'U2 sin preferencia: el hook debía emitir account_id=% , emitió %', v_p2, v_j #>> '{claims,app_metadata,account_id}';
    END IF;
    IF v_j #> '{claims,app_metadata,account_roles}' <> '["owner"]'::jsonb OR (v_j #>> '{claims,app_metadata,plan}') <> 'inicial' THEN
      RAISE EXCEPTION 'U2 sin preferencia: roles/plan debían ser los de P2 (["owner"], inicial), fueron % / %', v_j #> '{claims,app_metadata,account_roles}', v_j #>> '{claims,app_metadata,plan}';
    END IF;
    IF (v_j #>> '{claims,app_metadata,provider}') <> 'email' THEN
      RAISE EXCEPTION 'el hook debía preservar las otras claves de app_metadata (provider): %', v_j;
    END IF;

    -- U2 con la preferencia en A → A (seller, plan avanzado)
    PERFORM pg_temp.set_pref(v_u2, v_a);
    v_j := public.custom_access_token_hook(jsonb_build_object('user_id', v_u2, 'claims', '{}'::jsonb));
    IF (v_j #>> '{claims,app_metadata,account_id}') IS DISTINCT FROM v_a::text THEN
      RAISE EXCEPTION 'U2 con la preferencia en A: el hook debía emitir account_id=%, emitió %', v_a, v_j #>> '{claims,app_metadata,account_id}';
    END IF;
    IF v_j #> '{claims,app_metadata,account_roles}' <> '["seller"]'::jsonb OR (v_j #>> '{claims,app_metadata,plan}') <> 'avanzado' THEN
      RAISE EXCEPTION 'U2 con la preferencia en A: roles/plan debían ser los de A (["seller"], avanzado), fueron % / %', v_j #> '{claims,app_metadata,account_roles}', v_j #>> '{claims,app_metadata,plan}';
    END IF;

    -- U1 (una cuenta): emite su cuenta y sus roles — no regresión.
    v_j := public.custom_access_token_hook(jsonb_build_object('user_id', v_u1, 'claims', '{}'::jsonb));
    IF (v_j #>> '{claims,app_metadata,account_id}') IS DISTINCT FROM v_p1::text OR v_j #> '{claims,app_metadata,account_roles}' <> '["owner"]'::jsonb THEN
      RAISE EXCEPTION 'U1: el hook debía emitir su cuenta % y ["owner"], emitió %', v_p1, v_j;
    END IF;

    -- Un usuario SIN membresía no recibe account_id (ni un array fabricado), como account_role/plan.
    v_j := public.custom_access_token_hook(jsonb_build_object('user_id', gen_random_uuid(), 'claims', '{}'::jsonb));
    IF v_j #> '{claims,app_metadata,account_id}' IS NOT NULL THEN
      RAISE EXCEPTION 'un usuario sin membresía no debía recibir account_id: %', v_j;
    END IF;

    -- La rama de degradación SE CONSERVA: un error DENTRO del bloque protegido (acá, `claims`
    -- escalar: jsonb_set no puede escribir sobre un escalar) devuelve los claims INTACTOS
    -- (nunca rompe el login). El hook de producción ya hace esto desde v31-authz-token-hook.
    v_j := public.custom_access_token_hook(jsonb_build_object('user_id', v_u1, 'claims', to_jsonb('preservado'::text)));
    IF v_j <> jsonb_build_object('claims', to_jsonb('preservado'::text)) THEN
      RAISE EXCEPTION 'ante un error el hook debía devolver los claims intactos, devolvió %', v_j;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    RAISE NOTICE 'PASS (f): el hook emite account_id, roles y plan de la cuenta activa, preserva app_metadata y conserva la degradación.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (g) RLS bajo SET LOCAL ROLE authenticated ───────────────────────────────
  v_blk := '(g)';
  BEGIN
    -- El claim gobierna la RLS (es lo que ve PostgREST).
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    v_j := pg_temp.q(format('SELECT id FROM public.sales WHERE id IN (%L, %L, %L) ORDER BY id', v_sale_a, v_sale_p2, v_sale_p1));
    IF v_j <> jsonb_build_array(jsonb_build_object('id', v_sale_a)) THEN
      RAISE EXCEPTION 'U2 con el claim de A debía ver sólo la venta de A (%), vio %', v_sale_a, v_j;
    END IF;
    v_j := pg_temp.q(format('SELECT id FROM public.accounts WHERE id IN (%L, %L, %L)', v_a, v_p2, v_zz));
    IF v_j <> jsonb_build_array(jsonb_build_object('id', v_a)) THEN
      RAISE EXCEPTION 'U2 con el claim de A debía ver sólo la fila de accounts de A, vio %', v_j;
    END IF;

    -- Sin claim ni preferencia: la más antigua (P2).
    PERFORM pg_temp.as_user(v_u2);
    v_j := pg_temp.q(format('SELECT id FROM public.sales WHERE id IN (%L, %L, %L) ORDER BY id', v_sale_a, v_sale_p2, v_sale_p1));
    IF v_j <> jsonb_build_array(jsonb_build_object('id', v_sale_p2)) THEN
      RAISE EXCEPTION 'U2 con P2 activa (sin preferencia) debía ver sólo la venta de P2 (%), vio %', v_sale_p2, v_j;
    END IF;

    -- Con la preferencia en A (sin claim): sólo A.
    PERFORM pg_temp.set_pref(v_u2, v_a);
    v_j := pg_temp.q(format('SELECT id FROM public.sales WHERE id IN (%L, %L, %L) ORDER BY id', v_sale_a, v_sale_p2, v_sale_p1));
    IF v_j <> jsonb_build_array(jsonb_build_object('id', v_sale_a)) THEN
      RAISE EXCEPTION 'U2 con la preferencia en A debía ver sólo la venta de A (%), vio %', v_sale_a, v_j;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    -- Y un claim de una cuenta ajena no deja ver nada.
    PERFORM pg_temp.as_user(v_u2, v_zz::text);
    v_j := pg_temp.q(format('SELECT id FROM public.sales WHERE id IN (%L, %L, %L)', v_sale_a, v_sale_p2, v_sale_p1));
    IF v_j <> '[]'::jsonb THEN
      RAISE EXCEPTION 'U2 con un claim de cuenta ajena no debía ver ninguna venta, vio %', v_j;
    END IF;

    -- U1 no ve nada ajeno (aislamiento entre usuarios, no sólo entre cuentas de un usuario).
    PERFORM pg_temp.as_user(v_u1);
    v_j := pg_temp.q(format('SELECT id FROM public.sales WHERE id IN (%L, %L, %L) ORDER BY id', v_sale_a, v_sale_p2, v_sale_p1));
    IF v_j <> jsonb_build_array(jsonb_build_object('id', v_sale_p1)) THEN
      RAISE EXCEPTION 'U1 debía ver sólo su venta (%), vio %', v_sale_p1, v_j;
    END IF;
    RAISE NOTICE 'PASS (g): la RLS muestra sólo la cuenta activa (por preferencia y por claim) y nada ajeno.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (h) agregados: no suman la otra cuenta ──────────────────────────────────
  v_blk := '(h)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    v_j := pg_temp.q('SELECT total_income FROM public.get_dashboard_financials(now() - interval ''1 day'', now() + interval ''1 day'', NULL)');
    IF (v_j -> 0 ->> 'total_income')::numeric <> 1000 THEN
      RAISE EXCEPTION 'get_dashboard_financials con A activa debía sumar sólo los 1000 de A, sumó %', v_j;
    END IF;
    v_j := pg_temp.q('SELECT period_a_revenue FROM public.rpc_period_comparison(current_date, current_date + 1, current_date - 30, current_date - 29)');
    IF (v_j -> 0 ->> 'period_a_revenue')::numeric <> 1000 THEN
      RAISE EXCEPTION 'rpc_period_comparison con A activa debía sumar sólo los 1000 de A, sumó %', v_j;
    END IF;

    PERFORM pg_temp.as_user(v_u2);
    v_j := pg_temp.q('SELECT total_income FROM public.get_dashboard_financials(now() - interval ''1 day'', now() + interval ''1 day'', NULL)');
    IF (v_j -> 0 ->> 'total_income')::numeric <> 100 THEN
      RAISE EXCEPTION 'get_dashboard_financials con P2 activa debía sumar sólo los 100 de P2, sumó %', v_j;
    END IF;
    v_j := pg_temp.q('SELECT period_a_revenue FROM public.rpc_period_comparison(current_date, current_date + 1, current_date - 30, current_date - 29)');
    IF (v_j -> 0 ->> 'period_a_revenue')::numeric <> 100 THEN
      RAISE EXCEPTION 'rpc_period_comparison con P2 activa debía sumar sólo los 100 de P2, sumó %', v_j;
    END IF;
    RAISE NOTICE 'PASS (h): get_dashboard_financials y rpc_period_comparison suman sólo la cuenta activa.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (i) R3j / R3l: el POS y la venta de servicio quedan en la cuenta activa ─
  v_blk := '(i)';
  BEGIN
    -- Por CLAIM (A activa): POS sobre un producto de A, y venta de servicio.
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_quick_sale(%L, NULL, %L::jsonb)', 'gate-mu-i1',
      jsonb_build_array(jsonb_build_object('product_id', v_prod_a, 'quantity', 1, 'price', 100, 'subtotal', 100))::text));
    IF v_r.o_state <> '00000' THEN
      RAISE EXCEPTION 'R3j (claim A): el POS sobre un producto de A debía funcionar, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    v_op := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = v_op LIMIT 1;
    IF v_acc IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'R3j (claim A): la venta del POS debía quedar en A (%), quedó en %', v_a, v_acc;
    END IF;

    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'gate-mu-i2', v_today,
      jsonb_build_array(jsonb_build_object('amount', 100, 'quantity', 1))::text));
    IF v_r.o_state <> '00000' THEN
      RAISE EXCEPTION 'R3l (claim A): la venta de servicio debía funcionar, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    v_op := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = v_op LIMIT 1;
    IF v_acc IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'R3l (claim A): la venta de servicio debía quedar en A (%), quedó en % (la otra es su cuenta personal)', v_a, v_acc;
    END IF;

    -- Por PREFERENCIA (sin claim): lo mismo.
    PERFORM pg_temp.set_pref(v_u2, v_a);
    PERFORM pg_temp.as_user(v_u2);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'gate-mu-i3', v_today,
      jsonb_build_array(jsonb_build_object('amount', 100, 'quantity', 1))::text));
    v_op := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = v_op LIMIT 1;
    IF v_r.o_state <> '00000' OR v_acc IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'R3l (preferencia A): la venta de servicio debía quedar en A (%), estado % cuenta %', v_a, v_r.o_state, v_acc;
    END IF;

    -- CONTROL: con P2 activa (claim), la venta de servicio queda en P2 — el claim se respeta en los dos sentidos.
    PERFORM pg_temp.as_user(v_u2, v_p2::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_create_sale_operation(%L, NULL, %L::date, ''ARS'', %L::jsonb)', 'gate-mu-i4', v_today,
      jsonb_build_array(jsonb_build_object('amount', 100, 'quantity', 1))::text));
    v_op := (v_r.o_res ->> 'operation_id')::uuid;
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = v_op LIMIT 1;
    IF v_r.o_state <> '00000' OR v_acc IS DISTINCT FROM v_p2 THEN
      RAISE EXCEPTION 'control (claim P2): la venta de servicio debía quedar en P2 (%), estado % cuenta %', v_p2, v_r.o_state, v_acc;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    RAISE NOTICE 'PASS (i): R3j y R3l — el POS y la venta de servicio de U2 quedan en la cuenta activa (por claim y por preferencia).';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (j) un gasto de U2 queda en la cuenta activa ────────────────────────────
  v_blk := '(j)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_create_expense(%L, 50, %L::date, %L)', 'Varios', v_today, 'gate-mu-j1'));
    IF v_r.o_state <> '00000' THEN
      RAISE EXCEPTION 'el gasto con A activa debía registrarse, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    SELECT account_id INTO v_acc FROM public.expenses WHERE description = 'gate-mu-j1';
    IF v_acc IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'el gasto con A activa debía quedar en A (%), quedó en %', v_a, v_acc;
    END IF;
    PERFORM pg_temp.as_user(v_u2, v_p2::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_create_expense(%L, 50, %L::date, %L)', 'Varios', v_today, 'gate-mu-j2'));
    SELECT account_id INTO v_acc FROM public.expenses WHERE description = 'gate-mu-j2';
    IF v_r.o_state <> '00000' OR v_acc IS DISTINCT FROM v_p2 THEN
      RAISE EXCEPTION 'control: el gasto con P2 activa debía quedar en P2 (%), estado % cuenta %', v_p2, v_r.o_state, v_acc;
    END IF;
    RAISE NOTICE 'PASS (j): un gasto de U2 queda en la cuenta activa.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (k) rpc_import_products (dry run) ya no responde cuenta_ambigua ─────────
  v_blk := '(k)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format(
      'public.rpc_import_products(%L, %L::jsonb, %L, %L, true)', 'gate-mu-k1',
      jsonb_build_array(jsonb_build_object('name', 'GATE-MU-K', 'price', 100, 'cost', 50))::text, 'gate.csv', 'gate-hash-k'));
    IF v_r.o_state = 'P0403' AND v_r.o_msg LIKE 'cuenta_ambigua%' THEN
      RAISE EXCEPTION 'rpc_import_products sigue rechazando al usuario de dos cuentas con cuenta_ambigua: %', v_r.o_msg;
    END IF;
    IF v_r.o_state <> '00000' THEN
      RAISE EXCEPTION 'el dry run de rpc_import_products con A activa debía funcionar, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    RAISE NOTICE 'PASS (k): el import en dry run funciona para el usuario de dos cuentas (su guard cuenta_ambigua queda inerte con 0/1 fila).';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (l) rpc_my_active_account_roles() = roles en la cuenta ACTIVA ───────────
  v_blk := '(l)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    v_j := pg_temp.q('SELECT public.rpc_my_active_account_roles() AS roles');
    IF v_j -> 0 -> 'roles' <> '["seller"]'::jsonb THEN
      RAISE EXCEPTION 'con el claim de A los roles debían ser ["seller"], fueron %', v_j;
    END IF;
    PERFORM pg_temp.as_user(v_u2);
    v_j := pg_temp.q('SELECT public.rpc_my_active_account_roles() AS roles');
    IF v_j -> 0 -> 'roles' <> '["owner"]'::jsonb THEN
      RAISE EXCEPTION 'con P2 activa los roles debían ser ["owner"], fueron %', v_j;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, v_a);
    v_j := pg_temp.q('SELECT public.rpc_my_active_account_roles() AS roles');
    IF v_j -> 0 -> 'roles' <> '["seller"]'::jsonb THEN
      RAISE EXCEPTION 'con A activa (preferencia) los roles debían ser ["seller"], fueron %', v_j;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    -- Claim de una cuenta ajena: array vacío (contrato: nunca NULL), jamás los roles de otra cuenta.
    PERFORM pg_temp.as_user(v_u2, v_zz::text);
    v_j := pg_temp.q('SELECT public.rpc_my_active_account_roles() AS roles');
    IF v_j -> 0 -> 'roles' <> '[]'::jsonb THEN
      RAISE EXCEPTION 'con un claim sin membresía los roles debían ser [] (no los de otra cuenta), fueron %', v_j;
    END IF;
    RAISE NOTICE 'PASS (l): rpc_my_active_account_roles() devuelve los roles de la cuenta activa.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (m) rpc_my_effective_plan() = plan de la cuenta ACTIVA ──────────────────
  v_blk := '(m)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    v_j := pg_temp.q('SELECT public.rpc_my_effective_plan() AS plan');
    IF v_j -> 0 ->> 'plan' <> 'avanzado' THEN
      RAISE EXCEPTION 'con el claim de A el plan debía ser avanzado, fue %', v_j;
    END IF;
    PERFORM pg_temp.as_user(v_u2);
    v_j := pg_temp.q('SELECT public.rpc_my_effective_plan() AS plan');
    IF v_j -> 0 ->> 'plan' <> 'inicial' THEN
      RAISE EXCEPTION 'con P2 activa el plan debía ser inicial, fue %', v_j;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, v_a);
    v_j := pg_temp.q('SELECT public.rpc_my_effective_plan() AS plan');
    IF v_j -> 0 ->> 'plan' <> 'avanzado' THEN
      RAISE EXCEPTION 'con A activa (preferencia) el plan debía ser avanzado, fue %', v_j;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_zz::text);
    v_j := pg_temp.q('SELECT public.rpc_my_effective_plan() AS plan');
    IF v_j -> 0 ->> 'plan' <> 'gratis' THEN
      RAISE EXCEPTION 'sin cuenta activa el plan debía ser gratis (fail-closed), fue %', v_j;
    END IF;
    RAISE NOTICE 'PASS (m): rpc_my_effective_plan() resuelve el plan de la cuenta activa y falla cerrado sin ella.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (n) insights: la RPC y el trigger sellan la cuenta activa ───────────────
  v_blk := '(n)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    SELECT * INTO v_r FROM pg_temp.try_rpc(format('public.rpc_atomic_log_ai_insight(%L, %L, %L)', 'tip', 'gate-mu-n1', 'gate'));
    IF v_r.o_state <> '00000' THEN
      RAISE EXCEPTION 'rpc_atomic_log_ai_insight debía funcionar, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    SELECT account_id INTO v_acc FROM public.insights WHERE message = 'gate-mu-n1';
    IF v_acc IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'el insight de la RPC con A activa debía sellarse en A (%), se selló en %', v_a, v_acc;
    END IF;

    -- Trigger set_insight_account_id, caso 1: el que inserta ES el dueño de la fila → la cuenta activa del request.
    INSERT INTO public.insights (user_id, type, priority, message) VALUES (v_u2, 'tip', 'media', 'gate-mu-n2');
    SELECT account_id INTO v_acc FROM public.insights WHERE message = 'gate-mu-n2';
    IF v_acc IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'trigger (caller = dueño de la fila, claim A): debía sellar A (%), selló %', v_a, v_acc;
    END IF;

    -- Caso 2: el que inserta es OTRO (p. ej. una Edge Function con service role) → el resolver del dueño de la fila.
    PERFORM pg_temp.set_pref(v_u2, v_a);
    PERFORM pg_temp.as_anon();
    INSERT INTO public.insights (user_id, type, priority, message) VALUES (v_u2, 'tip', 'media', 'gate-mu-n3');
    SELECT account_id INTO v_acc FROM public.insights WHERE message = 'gate-mu-n3';
    IF v_acc IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'trigger (sin sesión, preferencia de U2 = A): debía sellar A (%), selló %', v_a, v_acc;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    INSERT INTO public.insights (user_id, type, priority, message) VALUES (v_u2, 'tip', 'media', 'gate-mu-n4');
    SELECT account_id INTO v_acc FROM public.insights WHERE message = 'gate-mu-n4';
    IF v_acc IS DISTINCT FROM v_p2 THEN
      RAISE EXCEPTION 'trigger (sin sesión, sin preferencia): debía sellar la más antigua de U2 (%), selló %', v_p2, v_acc;
    END IF;
    RAISE NOTICE 'PASS (n): rpc_atomic_log_ai_insight y el trigger set_insight_account_id sellan la cuenta activa.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (o) rpc_my_accounts() ───────────────────────────────────────────────────
  v_blk := '(o)';
  BEGIN
    PERFORM pg_temp.set_pref(v_u2, NULL);
    PERFORM pg_temp.as_user(v_u2, v_a::text);
    v_j := pg_temp.q('SELECT * FROM public.rpc_my_accounts() ORDER BY created_at');
    IF jsonb_array_length(v_j) <> 2 THEN
      RAISE EXCEPTION 'U2 debía listar sus 2 cuentas, listó %', jsonb_array_length(v_j);
    END IF;
    IF (v_j -> 0 ->> 'account_id') <> v_p2::text OR (v_j -> 1 ->> 'account_id') <> v_a::text THEN
      RAISE EXCEPTION 'orden esperado: más antigua primero (P2, A); devolvió %', v_j;
    END IF;
    IF (v_j -> 0 ->> 'is_active')::boolean OR NOT (v_j -> 1 ->> 'is_active')::boolean THEN
      RAISE EXCEPTION 'con el claim de A, sólo A debía estar activa: %', v_j;
    END IF;
    IF NOT (v_j -> 0 ->> 'is_owner')::boolean OR (v_j -> 1 ->> 'is_owner')::boolean THEN
      RAISE EXCEPTION 'U2 es dueño de P2 y NO de A: %', v_j;
    END IF;
    IF v_j -> 0 -> 'roles' <> '["owner"]'::jsonb OR v_j -> 1 -> 'roles' <> '["seller"]'::jsonb THEN
      RAISE EXCEPTION 'los roles por cuenta debían ser ["owner"] / ["seller"]: %', v_j;
    END IF;
    -- Campos CRUDOS del nombre (la cascada vive en previewIssuer, no en SQL) y estado de billing.
    FOREACH v_txt IN ARRAY ARRAY['brand_display_name', 'fiscal_nombre_fantasia', 'fiscal_razon_social', 'brand_legal_name',
                                 'owner_business_name', 'billing_plan', 'billing_status', 'effective_plan'] LOOP
      IF NOT (v_j -> 0) ? v_txt THEN
        RAISE EXCEPTION 'rpc_my_accounts debía devolver la clave % : %', v_txt, v_j -> 0;
      END IF;
    END LOOP;
    IF (v_j -> 1 ->> 'owner_business_name') <> 'MU Negocio Owner' OR (v_j -> 0 ->> 'owner_business_name') <> 'MU Negocio Dos' THEN
      RAISE EXCEPTION 'owner_business_name debía ser el del dueño de cada cuenta: %', v_j;
    END IF;
    IF (v_j -> 0 ->> 'effective_plan') <> 'inicial' OR (v_j -> 1 ->> 'effective_plan') <> 'avanzado' THEN
      RAISE EXCEPTION 'effective_plan por cuenta debía ser inicial / avanzado: %', v_j;
    END IF;

    -- Con el claim de P2 y la preferencia en A, "activa" es la del claim (la que resuelve current_account_ids()).
    PERFORM pg_temp.set_pref(v_u2, v_a);
    PERFORM pg_temp.as_user(v_u2, v_p2::text);
    v_j := pg_temp.q('SELECT account_id, is_active FROM public.rpc_my_accounts() ORDER BY created_at');
    IF NOT (v_j -> 0 ->> 'is_active')::boolean OR (v_j -> 1 ->> 'is_active')::boolean THEN
      RAISE EXCEPTION 'con el claim de P2, la activa debía ser P2: %', v_j;
    END IF;

    -- U1: una sola fila, activa.
    PERFORM pg_temp.as_user(v_u1);
    v_j := pg_temp.q('SELECT account_id, is_active FROM public.rpc_my_accounts()');
    IF jsonb_array_length(v_j) <> 1 OR NOT (v_j -> 0 ->> 'is_active')::boolean OR (v_j -> 0 ->> 'account_id') <> v_p1::text THEN
      RAISE EXCEPTION 'U1 debía listar su única cuenta, activa: %', v_j;
    END IF;

    -- Sin sesión: P0401.
    PERFORM pg_temp.as_anon();
    SELECT * INTO v_r FROM pg_temp.try_rpc('(SELECT count(*) FROM public.rpc_my_accounts())');
    IF v_r.o_state <> 'P0401' THEN
      RAISE EXCEPTION 'rpc_my_accounts sin sesión debía dar P0401, dio % %', v_r.o_state, v_r.o_msg;
    END IF;
    PERFORM pg_temp.set_pref(v_u2, NULL);
    RAISE NOTICE 'PASS (o): rpc_my_accounts() lista una fila por membresía, una sola activa, con los campos crudos y el billing.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (p) get_account_ids_for_user NO cambia: sigue devolviendo todas ─────────
  v_blk := '(p)';
  BEGIN
    PERFORM pg_temp.as_user(v_u2);
    v_j := pg_temp.q(format('SELECT public.get_account_ids_for_user(%L::uuid) AS id', v_u2));
    IF jsonb_array_length(v_j) <> 2 THEN
      RAISE EXCEPTION 'get_account_ids_for_user(U2) debía seguir devolviendo las 2 membresías, devolvió %', v_j;
    END IF;
    RAISE NOTICE 'PASS (p): quien necesite todas las membresías sigue teniendo get_account_ids_for_user.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (s) ESTRUCTURAL ─────────────────────────────────────────────────────────
  v_blk := '(s1) ACL de resolve_active_account';
  BEGIN
    IF to_regprocedure('public.resolve_active_account(uuid)') IS NULL THEN
      RAISE EXCEPTION 'public.resolve_active_account(uuid) no existe';
    END IF;
    IF has_function_privilege('anon', 'public.resolve_active_account(uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.resolve_active_account(uuid)', 'EXECUTE') THEN
      RAISE EXCEPTION 'resolve_active_account recibe un usuario por parámetro y NO puede ser ejecutable por anon/authenticated (misma lección que get_account_ids_for_user, h4)';
    END IF;
    IF NOT has_function_privilege('supabase_auth_admin', 'public.resolve_active_account(uuid)', 'EXECUTE') THEN
      RAISE EXCEPTION 'supabase_auth_admin (el rol con el que GoTrue invoca el hook) debe conservar EXECUTE sobre resolve_active_account: sin él el hook degrada en silencio y el token pierde sus claims';
    END IF;
    RAISE NOTICE 'PASS (s1): resolve_active_account — sin EXECUTE para anon/authenticated, con EXECUTE para supabase_auth_admin.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  v_blk := '(s2) RPCs nuevas';
  BEGIN
    IF to_regprocedure('public.rpc_set_active_account(uuid)') IS NULL OR to_regprocedure('public.rpc_my_accounts()') IS NULL THEN
      RAISE EXCEPTION 'faltan rpc_set_active_account(uuid) y/o rpc_my_accounts()';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.rpc_set_active_account(uuid)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.rpc_my_accounts()', 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated debe poder ejecutar rpc_set_active_account y rpc_my_accounts (el selector las llama por supabase-js)';
    END IF;
    IF has_function_privilege('anon', 'public.rpc_set_active_account(uuid)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.rpc_my_accounts()', 'EXECUTE') THEN
      RAISE EXCEPTION 'anon NO debe poder ejecutar rpc_set_active_account ni rpc_my_accounts';
    END IF;
    -- Una definición viva por función reescrita o nueva (nada de overload fantasma, 42725).
    SELECT count(*) INTO v_n FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('current_account_ids', 'custom_access_token_hook', 'rpc_my_active_account_roles',
                         'rpc_my_effective_plan', 'rpc_atomic_log_ai_insight', 'set_insight_account_id',
                         'resolve_active_account', 'rpc_set_active_account', 'rpc_my_accounts');
    IF v_n <> 9 THEN
      RAISE EXCEPTION 'debía haber exactamente 9 definiciones vivas (6 reescritas + 3 nuevas), hay %', v_n;
    END IF;
    -- current_account_ids: mismo nombre, misma firma, SETOF uuid, DEFINER, STABLE, COMMENT que diga qué es.
    SELECT p.prosecdef, p.provolatile, p.proretset, pg_get_function_result(p.oid), obj_description(p.oid, 'pg_proc')
      INTO v_r FROM pg_proc p WHERE p.oid = 'public.current_account_ids()'::regprocedure;
    IF NOT v_r.prosecdef OR v_r.provolatile <> 's' OR NOT v_r.proretset OR v_r.pg_get_function_result <> 'SETOF uuid' THEN
      RAISE EXCEPTION 'current_account_ids debe seguir siendo SETOF uuid, SECURITY DEFINER y STABLE: %', v_r;
    END IF;
    IF COALESCE(v_r.obj_description, '') NOT ILIKE '%cuenta activa%' THEN
      RAISE EXCEPTION 'el COMMENT de current_account_ids debe decir que devuelve la cuenta activa (0 o 1 fila): %', v_r.obj_description;
    END IF;
    RAISE NOTICE 'PASS (s2): rpc_set_active_account / rpc_my_accounts con su ACL, una definición viva por función y current_account_ids documentada.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  v_blk := '(s3) profiles.active_account_id';
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'profiles'
                      AND column_name = 'active_account_id' AND data_type = 'uuid') THEN
      RAISE EXCEPTION 'falta la columna profiles.active_account_id uuid';
    END IF;
    IF has_column_privilege('authenticated', 'public.profiles', 'active_account_id', 'UPDATE')
       OR has_column_privilege('authenticated', 'public.profiles', 'active_account_id', 'INSERT')
       OR has_column_privilege('anon', 'public.profiles', 'active_account_id', 'UPDATE')
       OR has_column_privilege('anon', 'public.profiles', 'active_account_id', 'INSERT') THEN
      RAISE EXCEPTION 'profiles.active_account_id NO puede ser escribible por authenticated/anon: sólo rpc_set_active_account (que valida la membresía) y la aceptación de una invitación';
    END IF;
    -- Ejecutado: el UPDATE directo del propio usuario es rechazado por la capa de PRIVILEGIO.
    PERFORM pg_temp.as_user(v_u2);
    BEGIN
      SET LOCAL ROLE authenticated;
      EXECUTE format('UPDATE public.profiles SET active_account_id = %L WHERE id = %L', v_zz, v_u2);
      RESET ROLE;
      RAISE EXCEPTION 'el UPDATE directo de profiles.active_account_id por authenticated debía rechazarse';
    EXCEPTION WHEN insufficient_privilege THEN
      RESET ROLE;
      IF SQLERRM NOT ILIKE '%permission denied%' THEN
        RAISE EXCEPTION 'el rechazo debía ser de privilegio ("permission denied"), fue: %', SQLERRM;
      END IF;
    END;
    -- FK a accounts con ON DELETE SET NULL (borrar una cuenta no deja la preferencia colgada).
    IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                    WHERE c.conrelid = 'public.profiles'::regclass AND c.contype = 'f'
                      AND c.confrelid = 'public.accounts'::regclass AND c.confdeltype = 'n'
                      AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'public.profiles'::regclass AND attname = 'active_account_id')]) THEN
      RAISE EXCEPTION 'profiles.active_account_id debe tener FK a accounts ON DELETE SET NULL';
    END IF;
    RAISE NOTICE 'PASS (s3): profiles.active_account_id es una columna de PRIVILEGIO (no escribible por PostgREST) con FK ON DELETE SET NULL.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- (s4) BARRIDO POR CONVENCIÓN (D15): ninguna función de public, fuera de la allow-list,
  -- resuelve "la" membresía de un usuario con LIMIT 1 sin acotar por cuenta. Que no nazca un
  -- quinto criterio de cuenta activa.
  v_blk := '(s4) barrido por convención';
  BEGIN
    SELECT COALESCE(string_agg(f.proname, ', ' ORDER BY f.proname), '') INTO v_txt
    FROM (
      SELECT p.proname,
             regexp_replace(regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g'), '\s+', ' ', 'g') AS def
      FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
    ) f
    WHERE f.def ~* 'account_members[^;]*user_id\s*=[^;]*limit 1'          -- resuelve una membresía de un usuario con LIMIT 1…
      AND f.def !~* 'account_members[^;]*account_id\s*=\s*(p_|v_|\$|\w+\.account_id)'  -- …sin acotar por una cuenta dada
      AND f.proname NOT IN ('resolve_active_account', 'rpc_my_accounts', 'rpc_set_active_account', 'current_account_ids',
                            'rpc_invite_member', 'rpc_accept_invitation', 'rpc_list_account_members');
    IF v_txt <> '' THEN
      RAISE EXCEPTION 'funciones con su PROPIO criterio de cuenta activa (account_members … user_id = … LIMIT 1): %. Usá current_account_ids() / resolve_active_account().', v_txt;
    END IF;
    RAISE NOTICE 'PASS (s4): ninguna función de public (fuera de la allow-list) mantiene un criterio propio de cuenta activa.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── Veredicto ──────────────────────────────────────────────────────────────
  IF array_length(v_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION E'GATE MULTIUSUARIO-CUENTA-ACTIVA FAILED en % bloque(s):\n  - %', array_length(v_fail, 1), array_to_string(v_fail, E'\n  - ');
  END IF;
  RAISE NOTICE 'GATE MULTIUSUARIO-CUENTA-ACTIVA OK: la cuenta activa es única y la misma en base, token y RPCs (a-p, s1-s4).';
END
$gate$;

ROLLBACK;
