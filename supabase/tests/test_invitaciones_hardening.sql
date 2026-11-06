-- =============================================================================
-- GATE: test_invitaciones_hardening.sql
-- CHANGE: invitaciones-hardening (governance CRÍTICO — auth / membresías)
--
-- Ejercita de verdad, como `authenticated` con `request.jwt.claims` armado a mano (el mismo
-- mecanismo que PostgREST y que `get_db_conn` de FastAPI), los cuatro cierres del change:
--
--   1. el token NO se guarda en claro (account_invitations.token_hash; email_logs.metadata.token
--      se retira apenas el envío deja de estar `pending`);
--   2. account_invitations es SÓLO para las funciones del dominio (sin policy ni privilegios de
--      tabla para anon/authenticated; ataque real del dueño por PostgREST => 42501);
--   3. la lista muestra el estado de la última entrega (last_delivery_status/_at);
--   4. un envío `failed` no cuenta para el enfriamiento (sí para el tope diario).
--
-- Fixtures (todos @test.local, dentro de BEGIN..ROLLBACK: residuo cero). Cada usuario tiene
-- además su cuenta personal (la crea `handle_new_user`).
--   O dueño de A   AD administrador de A   I invitado (aún sin A)   W otra identidad
--   Z dueño de B (cuenta ajena)
--
-- Estructura: cada bloque corre en su sub-bloque con EXCEPTION y registra su falla (el RED
-- muestra de una vez QUÉ bloques fallan); al final, si hubo alguna, el gate aborta listándolas.
--
--   (a) la fila guarda sólo el hash; el envío devuelve el token y la fila no lo contiene
--   (b) cada envío emite un token distinto; sólo el último acepta
--   (c) email_logs: el token se retira al salir de pending (sent/failed/partial), sólo de
--       org_invite; el reenvío lo retira de los pending anteriores
--   (d) privilegios y policies de account_invitations
--   (e) ataque real del dueño por PostgREST (INSERT/UPDATE/DELETE/SELECT => 42501)
--   (f) las RPCs del dominio funcionan de punta a punta con roles reales
--   (g) estado de la última entrega en el listado
--   (h) enfriamiento (failed no cuenta) y tope diario (failed cuenta)
--   (i) ACLs y una sola definición viva por función
-- =============================================================================

BEGIN;

-- ── Helpers (sesión; viven en pg_temp) ───────────────────────────────────────

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

CREATE FUNCTION pg_temp.try_tbl(p_from text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) FROM %s t', p_from) INTO o_res;
  RESET ROLE;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  o_res := NULL;
  RESET ROLE;
END $f$;

-- Corre una sentencia SQL arbitraria como `authenticated`; devuelve el SQLSTATE ('00000' = ok).
CREATE FUNCTION pg_temp.try_sql(p_sql text, OUT o_state text, OUT o_msg text)
LANGUAGE plpgsql AS $f$
BEGIN
  o_state := '00000';
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql;
  RESET ROLE;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_msg = MESSAGE_TEXT;
  RESET ROLE;
END $f$;

CREATE FUNCTION pg_temp.run(p_user uuid, p_account uuid, p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.as_user(p_user, p_account::text);
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try_rpc(p_expr) t;
END $f$;

CREATE FUNCTION pg_temp.run_tbl(p_user uuid, p_account uuid, p_from text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.as_user(p_user, p_account::text);
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try_tbl(p_from) t;
END $f$;

CREATE FUNCTION pg_temp.run_sql(p_user uuid, p_account uuid, p_sql text, OUT o_state text, OUT o_msg text)
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.as_user(p_user, p_account::text);
  SELECT t.o_state, t.o_msg INTO o_state, o_msg FROM pg_temp.try_sql(p_sql) t;
END $f$;

CREATE FUNCTION pg_temp.e_invite(p_email text, p_account uuid, p_roles text[]) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_invite_member(%L, %L::uuid, %L::text[])', p_email, p_account, p_roles::text) $f$;
CREATE FUNCTION pg_temp.e_send(p_inv uuid, p_name text, p_renew boolean DEFAULT false) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_send_invitation_email(%L::uuid, %L, %L::boolean)', p_inv, p_name, p_renew) $f$;
CREATE FUNCTION pg_temp.e_revoke(p_inv uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_revoke_invitation(%L::uuid)', p_inv) $f$;
CREATE FUNCTION pg_temp.e_preview(p_token text) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_invitation_preview(%L)', p_token) $f$;
CREATE FUNCTION pg_temp.e_accept(p_token text) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_accept_invitation(%L)', p_token) $f$;
CREATE FUNCTION pg_temp.e_list(p_account uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT format('public.rpc_list_account_invitations(%L::uuid)', p_account) $f$;

CREATE FUNCTION pg_temp.expect(p_label text, p_state text, p_msg text, p_exp text, p_like text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_exp = 'ok' THEN
    IF p_state <> '00000' THEN
      RAISE EXCEPTION '% debía funcionar, dio % %', p_label, p_state, p_msg;
    END IF;
  ELSE
    IF p_state <> p_exp THEN
      RAISE EXCEPTION '% debía dar %, dio % %', p_label, p_exp, p_state, COALESCE(p_msg, '(sin error)');
    END IF;
    IF p_like IS NOT NULL AND COALESCE(p_msg, '') NOT ILIKE '%' || p_like || '%' THEN
      RAISE EXCEPTION '% dio % pero el mensaje % no contiene %', p_label, p_state, p_msg, p_like;
    END IF;
  END IF;
END $f$;

-- La fila de la invitación NO contiene `p_tok` en ninguna columna (en claro).
CREATE FUNCTION pg_temp.row_has(p_inv uuid, p_tok text) RETURNS boolean
LANGUAGE sql AS $f$
  SELECT position(p_tok IN to_jsonb(ai)::text) > 0 FROM public.account_invitations ai WHERE ai.id = p_inv
$f$;

-- Estado de entrega de una invitación según el listado del dueño.
CREATE FUNCTION pg_temp.delivery(p_user uuid, p_account uuid, p_inv uuid, OUT o_status text, OUT o_at timestamptz, OUT o_row jsonb)
LANGUAGE plpgsql AS $f$
DECLARE
  r record;
BEGIN
  SELECT * INTO r FROM pg_temp.run_tbl(p_user, p_account, format('public.rpc_list_account_invitations(%L::uuid)', p_account));
  IF r.o_state <> '00000' THEN
    RAISE EXCEPTION 'listar falló: % %', r.o_state, r.o_msg;
  END IF;
  SELECT e INTO o_row FROM jsonb_array_elements(r.o_res) e WHERE e ->> 'id' = p_inv::text;
  IF o_row IS NULL THEN RAISE EXCEPTION 'la invitación % no aparece en el listado', p_inv; END IF;
  o_status := o_row ->> 'last_delivery_status';
  o_at := (o_row ->> 'last_delivery_at')::timestamptz;
END $f$;

-- Crea una invitación y la envía como el dueño; devuelve (id, token).
CREATE FUNCTION pg_temp.invite_and_send(p_user uuid, p_account uuid, p_email text, OUT o_id uuid, OUT o_token text)
LANGUAGE plpgsql AS $f$
DECLARE
  r record;
BEGIN
  SELECT * INTO r FROM pg_temp.run(p_user, p_account, pg_temp.e_invite(p_email, p_account, ARRAY['seller']));
  PERFORM pg_temp.expect('invitar ' || p_email, r.o_state, r.o_msg, 'ok');
  o_id := (r.o_res ->> 'id')::uuid;
  SELECT * INTO r FROM pg_temp.run(p_user, p_account, pg_temp.e_send(o_id, 'Negocio Hardening', false));
  PERFORM pg_temp.expect('enviar ' || p_email, r.o_state, r.o_msg, 'ok');
  o_token := r.o_res ->> 'token';
END $f$;

-- ═════════════════════════════════════════════════════════════════════════════
DO $gate$
DECLARE
  v_fail   text[] := ARRAY[]::text[];
  v_pass   integer := 0;
  v_blk    text;

  v_o  uuid := gen_random_uuid();  v_ad uuid := gen_random_uuid();
  v_i  uuid := gen_random_uuid();  v_w  uuid := gen_random_uuid();
  v_z  uuid := gen_random_uuid();
  v_a  uuid;  v_b uuid;  v_pi uuid;  v_pw uuid;

  v_member uuid;
  v_r record;  v_r2 record;
  v_inv uuid;  v_inv2 uuid;  v_inv3 uuid;
  v_t1 text;  v_t2 text;  v_t3 text;
  v_n integer;  v_n0 integer;
  v_row record;
  v_id uuid;
  v_st text;
  v_msg1 text;  v_msg2 text;
  v_txt text;
  v_p text;  v_role text;
BEGIN
  -- ── Fixtures ───────────────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
    (v_o,  'authenticated', 'authenticated', 'ih-owner@test.local',   now(), now(), '{"name":"IH Dueno"}'::jsonb),
    (v_ad, 'authenticated', 'authenticated', 'ih-admin@test.local',   now(), now(), '{"name":"IH Admin"}'::jsonb),
    (v_i,  'authenticated', 'authenticated', 'ih-invitee@test.local', now(), now(), '{"name":"IH Invitado"}'::jsonb),
    (v_w,  'authenticated', 'authenticated', 'ih-wrong@test.local',   now(), now(), '{"name":"IH Otra"}'::jsonb),
    (v_z,  'authenticated', 'authenticated', 'ih-zeta@test.local',    now(), now(), '{"name":"IH Zeta"}'::jsonb);

  SELECT account_id INTO v_a  FROM public.account_members WHERE user_id = v_o;
  SELECT account_id INTO v_b  FROM public.account_members WHERE user_id = v_z;
  SELECT account_id INTO v_pi FROM public.account_members WHERE user_id = v_i;
  SELECT account_id INTO v_pw FROM public.account_members WHERE user_id = v_w;
  IF v_a IS NULL OR v_b IS NULL OR v_pi IS NULL OR v_pw IS NULL THEN
    RAISE EXCEPTION 'GATE INVITACIONES-HARDENING (fixture): handle_new_user no creó la cuenta de algún usuario sintético.';
  END IF;
  UPDATE public.accounts SET billing_plan = 'pro', trial_plan = NULL, trial_expires_at = NULL WHERE id IN (v_a, v_b);

  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_a, v_ad, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_member, 'admin');

  -- ── (a) la fila guarda sólo el hash; el token vuelve del envío ──────────────
  v_blk := '(a) token_hash en la fila, token sólo en el retorno del envío';
  BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_invitations' AND column_name = 'token') THEN
      RAISE EXCEPTION 'account_invitations todavía tiene la columna token en claro';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_invitations' AND column_name = 'token_hash') THEN
      RAISE EXCEPTION 'falta la columna token_hash';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'account_invitations' AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%(token_hash)%') THEN
      RAISE EXCEPTION 'falta el índice único sobre token_hash';
    END IF;

    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('ih-invitee@test.local', v_a, ARRAY['seller']));
    PERFORM pg_temp.expect('el dueño invita', v_r.o_state, v_r.o_msg, 'ok');
    v_inv := (v_r.o_res ->> 'id')::uuid;
    IF v_r.o_res ? 'token' THEN RAISE EXCEPTION 'rpc_invite_member ya NO devuelve el token (lo emite el envío)'; END IF;
    IF (SELECT token_hash FROM public.account_invitations WHERE id = v_inv) IS NOT NULL THEN
      RAISE EXCEPTION 'una invitación sin enviar nace con token_hash NULL';
    END IF;

    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'Negocio Hardening', false));
    PERFORM pg_temp.expect('el dueño envía', v_r.o_state, v_r.o_msg, 'ok');
    v_t1 := v_r.o_res ->> 'token';
    IF v_t1 IS NULL OR v_t1 !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'el envío debía devolver el token (64 hex), devolvió %', v_t1; END IF;
    IF (SELECT token_hash FROM public.account_invitations WHERE id = v_inv) IS DISTINCT FROM encode(sha256(convert_to(v_t1, 'UTF8')), 'hex') THEN
      RAISE EXCEPTION 'token_hash debía ser el sha256 hex del token devuelto';
    END IF;
    IF pg_temp.row_has(v_inv, v_t1) THEN RAISE EXCEPTION 'la fila de la invitación contiene el token en claro'; END IF;
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (a)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (b) cada envío emite un token distinto; sólo el último acepta ───────────
  v_blk := '(b) cada envío rota el token';
  BEGIN
    -- Pasada la ventana de enfriamiento del primer envío.
    UPDATE public.email_logs SET created_at = now() - interval '11 minutes'
     WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'Negocio Hardening', false));
    PERFORM pg_temp.expect('el reenvío', v_r.o_state, v_r.o_msg, 'ok');
    v_t2 := v_r.o_res ->> 'token';
    IF v_t2 IS NULL OR v_t2 = v_t1 THEN RAISE EXCEPTION 'cada envío debía emitir un token distinto'; END IF;
    IF pg_temp.row_has(v_inv, v_t2) THEN RAISE EXCEPTION 'la fila contiene el token nuevo en claro'; END IF;
    IF (SELECT token_hash FROM public.account_invitations WHERE id = v_inv) IS DISTINCT FROM encode(sha256(convert_to(v_t2, 'UTF8')), 'hex') THEN
      RAISE EXCEPTION 'token_hash debía ser el del último envío';
    END IF;

    SELECT * INTO v_r  FROM pg_temp.run(v_i, v_pi, pg_temp.e_accept(v_t1));
    PERFORM pg_temp.expect('aceptar con el token del primer envío', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    SELECT * INTO v_r2 FROM pg_temp.run(v_i, v_pi, pg_temp.e_accept('token-que-no-existe'));
    IF v_r.o_msg IS DISTINCT FROM v_r2.o_msg THEN
      RAISE EXCEPTION 'el token rotado y el inexistente deben dar el MISMO mensaje: "%" vs "%"', v_r.o_msg, v_r2.o_msg;
    END IF;
    SELECT * INTO v_r  FROM pg_temp.run(v_i, v_pi, pg_temp.e_preview(v_t1));
    PERFORM pg_temp.expect('previsualizar con el token rotado', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    SELECT * INTO v_r  FROM pg_temp.run(v_i, v_pi, pg_temp.e_preview(v_t2));
    PERFORM pg_temp.expect('previsualizar con el token vigente', v_r.o_state, v_r.o_msg, 'ok');
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (b)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (c) email_logs: el token se retira al salir de pending ───────────────────
  v_blk := '(c) retiro del token en email_logs';
  BEGIN
    -- La fila nueva lleva el token en metadata mientras está pending.
    SELECT * INTO v_row FROM public.email_logs
     WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text AND metadata ->> 'token' = v_t2;
    IF NOT FOUND THEN RAISE EXCEPTION 'el envío vigente debía llevar metadata.token mientras está pending'; END IF;
    -- El envío anterior (pending) perdió el token al reenviar.
    IF EXISTS (SELECT 1 FROM public.email_logs WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text AND status = 'pending' AND metadata ->> 'token' = v_t1) THEN
      RAISE EXCEPTION 'el envío anterior (pending) debía perder el token al reenviar';
    END IF;
    IF EXISTS (SELECT 1 FROM public.email_logs WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text AND metadata ? 'token' AND metadata ->> 'token' <> v_t2) THEN
      RAISE EXCEPTION 'sólo el envío vigente puede conservar un token';
    END IF;

    -- Los tres desenlaces que escribe send-email.
    FOREACH v_st IN ARRAY ARRAY['sent', 'failed', 'partial'] LOOP
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      VALUES (v_o, 'org_invite', 'ih-c-' || v_st || '@test.local', 's',
              jsonb_build_object('invitation_id', gen_random_uuid(), 'account_id', v_a, 'token', 'tok-' || v_st, 'sent_at', clock_timestamp()))
      RETURNING id INTO v_id;
      UPDATE public.email_logs SET status = v_st WHERE id = v_id;
      IF (SELECT metadata ? 'token' FROM public.email_logs WHERE id = v_id) THEN
        RAISE EXCEPTION 'al pasar a % el registro debía perder metadata.token', v_st;
      END IF;
      IF NOT (SELECT metadata ? 'invitation_id' AND metadata ? 'account_id' FROM public.email_logs WHERE id = v_id) THEN
        RAISE EXCEPTION 'al retirar el token el registro debía conservar el resto del metadata';
      END IF;
    END LOOP;

    -- Un pending que NO cambia de estado conserva el token (el disparador no actúa sobre pending).
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    VALUES (v_o, 'org_invite', 'ih-c-pend@test.local', 's',
            jsonb_build_object('invitation_id', gen_random_uuid(), 'account_id', v_a, 'token', 'tok-pend', 'sent_at', clock_timestamp()))
    RETURNING id INTO v_id;
    UPDATE public.email_logs SET status = 'pending', provider_id = 'x' WHERE id = v_id;
    IF NOT (SELECT metadata ? 'token' FROM public.email_logs WHERE id = v_id) THEN
      RAISE EXCEPTION 'un registro que sigue pending conserva el token';
    END IF;

    -- Otro event_type con una clave `token` NO se toca.
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    VALUES (v_o, 'welcome', 'ih-c-other@test.local', 's', jsonb_build_object('token', 'otro-evento', 'k', 1))
    RETURNING id INTO v_id;
    UPDATE public.email_logs SET status = 'sent' WHERE id = v_id;
    IF (SELECT metadata ->> 'token' FROM public.email_logs WHERE id = v_id) IS DISTINCT FROM 'otro-evento' THEN
      RAISE EXCEPTION 'el disparador NO puede tocar el metadata de otros event_type';
    END IF;
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (c)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (d) privilegios y policies ───────────────────────────────────────────────
  v_blk := '(d) account_invitations sin privilegios ni policies de aplicación';
  BEGIN
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      FOREACH v_p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
        IF has_table_privilege(v_role, 'public.account_invitations', v_p) THEN
          RAISE EXCEPTION '% conserva % de tabla sobre account_invitations', v_role, v_p;
        END IF;
      END LOOP;
      FOREACH v_p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES'] LOOP
        IF has_any_column_privilege(v_role, 'public.account_invitations', v_p) THEN
          RAISE EXCEPTION '% conserva % de columna sobre account_invitations', v_role, v_p;
        END IF;
      END LOOP;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'account_invitations'
               AND (roles && ARRAY['anon', 'authenticated', 'public']::name[])) THEN
      RAISE EXCEPTION 'account_invitations conserva una policy para anon/authenticated/public';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.account_invitations'::regclass) THEN
      RAISE EXCEPTION 'RLS debe seguir habilitada en account_invitations';
    END IF;
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (d)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (e) ataque real del dueño por PostgREST ──────────────────────────────────
  v_blk := '(e) el dueño no escribe ni lee la tabla por fuera de las RPCs';
  BEGIN
    SELECT count(*) INTO v_n0 FROM public.account_invitations;
    SELECT * INTO v_r FROM pg_temp.run_sql(v_o, v_a, format(
      $q$INSERT INTO public.account_invitations (account_id, email, role, status, invited_by, expires_at) VALUES (%L, 'ih-attack@test.local', 'owner', 'pending', %L, now() + interval '1 day')$q$, v_a, v_o));
    IF v_r.o_state <> '42501' THEN RAISE EXCEPTION 'INSERT directo del dueño debía dar 42501, dio % %', v_r.o_state, v_r.o_msg; END IF;
    SELECT * INTO v_r FROM pg_temp.run_sql(v_o, v_a, format($q$UPDATE public.account_invitations SET roles = ARRAY['owner'] WHERE id = %L$q$, v_inv));
    IF v_r.o_state <> '42501' THEN RAISE EXCEPTION 'UPDATE directo del dueño debía dar 42501, dio % %', v_r.o_state, v_r.o_msg; END IF;
    SELECT * INTO v_r FROM pg_temp.run_sql(v_o, v_a, format($q$DELETE FROM public.account_invitations WHERE id = %L$q$, v_inv));
    IF v_r.o_state <> '42501' THEN RAISE EXCEPTION 'DELETE directo del dueño debía dar 42501, dio % %', v_r.o_state, v_r.o_msg; END IF;
    SELECT * INTO v_r FROM pg_temp.run_sql(v_o, v_a, 'SELECT * FROM public.account_invitations');
    IF v_r.o_state <> '42501' THEN RAISE EXCEPTION 'SELECT directo del dueño debía dar 42501, dio % %', v_r.o_state, v_r.o_msg; END IF;
    SELECT * INTO v_r FROM pg_temp.run_sql(v_o, v_a, 'TRUNCATE public.account_invitations');
    IF v_r.o_state <> '42501' THEN RAISE EXCEPTION 'TRUNCATE del dueño debía dar 42501, dio % %', v_r.o_state, v_r.o_msg; END IF;
    SELECT count(*) INTO v_n FROM public.account_invitations;
    IF v_n <> v_n0 THEN RAISE EXCEPTION 'el ataque cambió filas: % -> %', v_n0, v_n; END IF;
    IF (SELECT roles FROM public.account_invitations WHERE id = v_inv) IS DISTINCT FROM ARRAY['seller']::text[] THEN
      RAISE EXCEPTION 'el ataque cambió los roles de la invitación';
    END IF;
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (e)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (f) las RPCs del dominio, de punta a punta con roles reales ──────────────
  v_blk := '(f) invitar, listar, revocar, previsualizar y aceptar siguen funcionando';
  BEGIN
    -- El administrador lista (sin token ni hash) y revoca una invitación ajena a él.
    SELECT * INTO v_r FROM pg_temp.invite_and_send(v_o, v_a, 'ih-f-revoke@test.local');
    v_inv2 := v_r.o_id;
    SELECT * INTO v_r FROM pg_temp.run_tbl(v_ad, v_a, pg_temp.e_list(v_a));
    PERFORM pg_temp.expect('el administrador lista', v_r.o_state, v_r.o_msg, 'ok');
    IF v_r.o_res::text ~* '"token' THEN RAISE EXCEPTION 'el listado NO puede exponer el token ni su hash'; END IF;
    IF jsonb_array_length(v_r.o_res) < 2 THEN RAISE EXCEPTION 'el listado debía traer las invitaciones pendientes (hay %)', jsonb_array_length(v_r.o_res); END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_revoke(v_inv2));
    PERFORM pg_temp.expect('el administrador revoca', v_r.o_state, v_r.o_msg, 'ok');

    -- El invitado previsualiza y acepta con el token del último envío; el negocio queda activo.
    SELECT * INTO v_r FROM pg_temp.run(v_w, v_pw, pg_temp.e_preview(v_t2));
    PERFORM pg_temp.expect('otra identidad previsualiza', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_preview(v_t2));
    PERFORM pg_temp.expect('el invitado previsualiza', v_r.o_state, v_r.o_msg, 'ok');
    IF v_r.o_res ->> 'account_display_name' IS DISTINCT FROM 'Negocio Hardening' THEN RAISE EXCEPTION 'la vista previa debía traer el nombre del negocio'; END IF;
    IF v_r.o_res::text ~* 'ih-invitee' THEN RAISE EXCEPTION 'la vista previa no puede devolver el email'; END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_accept(v_t2));
    PERFORM pg_temp.expect('el invitado acepta', v_r.o_state, v_r.o_msg, 'ok');
    IF NOT EXISTS (SELECT 1 FROM public.account_members WHERE account_id = v_a AND user_id = v_i) THEN
      RAISE EXCEPTION 'aceptar debía crear la membresía';
    END IF;
    IF (SELECT active_account_id FROM public.profiles WHERE id = v_i) IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'aceptar debía dejar el negocio como cuenta activa';
    END IF;
    IF (SELECT status FROM public.account_invitations WHERE id = v_inv) IS DISTINCT FROM 'accepted' THEN
      RAISE EXCEPTION 'la invitación debía quedar accepted';
    END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_a, pg_temp.e_accept(v_t2));
    PERFORM pg_temp.expect('canjear dos veces', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (f)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (g) estado de la última entrega en el listado ────────────────────────────
  v_blk := '(g) last_delivery_status / last_delivery_at';
  BEGIN
    -- Sin envío: NULL.
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('ih-g-none@test.local', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('invitar sin enviar', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, (v_r.o_res ->> 'id')::uuid);
    IF v_r2.o_status IS NOT NULL OR v_r2.o_at IS NOT NULL THEN RAISE EXCEPTION 'sin envío el estado debía ser NULL, es % / %', v_r2.o_status, v_r2.o_at; END IF;

    SELECT * INTO v_r FROM pg_temp.invite_and_send(v_o, v_a, 'ih-g-flow@test.local');
    v_inv3 := v_r.o_id;
    -- pending reciente: queued.
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, v_inv3);
    IF v_r2.o_status IS DISTINCT FROM 'queued' THEN RAISE EXCEPTION 'pending reciente debía ser queued, es %', v_r2.o_status; END IF;
    -- pending de 15 minutos o más: unconfirmed.
    UPDATE public.email_logs SET created_at = now() - interval '16 minutes' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text;
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, v_inv3);
    IF v_r2.o_status IS DISTINCT FROM 'unconfirmed' THEN RAISE EXCEPTION 'pending de 16 min debía ser unconfirmed, es %', v_r2.o_status; END IF;
    -- failed.
    UPDATE public.email_logs SET status = 'failed', error_details = 'detalle del proveedor SECRETO' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text;
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, v_inv3);
    IF v_r2.o_status IS DISTINCT FROM 'failed' THEN RAISE EXCEPTION 'failed debía ser failed, es %', v_r2.o_status; END IF;
    IF v_r2.o_row::text ~* 'SECRETO|error_details' THEN RAISE EXCEPTION 'el listado no puede exponer error_details'; END IF;
    -- sent: last_delivery_at = sent_at.
    UPDATE public.email_logs SET status = 'sent', sent_at = now() - interval '2 minutes' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text;
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, v_inv3);
    IF v_r2.o_status IS DISTINCT FROM 'sent' THEN RAISE EXCEPTION 'sent debía ser sent, es %', v_r2.o_status; END IF;
    IF v_r2.o_at IS NULL OR abs(extract(epoch FROM (v_r2.o_at - (now() - interval '2 minutes')))) > 5 THEN
      RAISE EXCEPTION 'last_delivery_at debía ser el sent_at, es %', v_r2.o_at;
    END IF;
    -- partial cuenta como sent.
    UPDATE public.email_logs SET status = 'partial' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text;
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, v_inv3);
    IF v_r2.o_status IS DISTINCT FROM 'sent' THEN RAISE EXCEPTION 'partial debía verse como sent, es %', v_r2.o_status; END IF;

    -- Toma el envío MÁS RECIENTE: uno viejo failed + uno nuevo sent => sent; al revés => failed.
    UPDATE public.email_logs SET status = 'failed', created_at = now() - interval '30 minutes' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv3, 'Negocio Hardening', false));
    PERFORM pg_temp.expect('reenviar tras un failed', v_r.o_state, v_r.o_msg, 'ok');
    UPDATE public.email_logs SET status = 'sent', sent_at = now() WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text AND status = 'pending';
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, v_inv3);
    IF v_r2.o_status IS DISTINCT FROM 'sent' THEN RAISE EXCEPTION 'con un failed viejo y un sent nuevo debía ser sent, es %', v_r2.o_status; END IF;
    UPDATE public.email_logs SET status = 'failed' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text AND created_at > now() - interval '5 minutes';
    UPDATE public.email_logs SET status = 'sent' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv3::text AND created_at < now() - interval '5 minutes';
    SELECT * INTO v_r2 FROM pg_temp.delivery(v_o, v_a, v_inv3);
    IF v_r2.o_status IS DISTINCT FROM 'failed' THEN RAISE EXCEPTION 'con un sent viejo y un failed nuevo debía ser failed, es %', v_r2.o_status; END IF;

    -- Los permisos del listado no cambian: el vendedor/observador/otra cuenta siguen rechazados.
    SELECT * INTO v_r FROM pg_temp.run_tbl(v_z, v_b, pg_temp.e_list(v_a));
    PERFORM pg_temp.expect('el dueño de OTRA cuenta lista la de A', v_r.o_state, v_r.o_msg, 'P0404');
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (g)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (h) enfriamiento y tope diario ───────────────────────────────────────────
  v_blk := '(h) un envío fallido no cuenta para el enfriamiento (sí para el tope diario)';
  BEGIN
    SELECT * INTO v_r FROM pg_temp.invite_and_send(v_o, v_a, 'ih-h-cool@test.local');
    v_id := v_r.o_id;
    -- Recién enviado y no fallido: el reenvío da P0439.
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_id, 'x', false));
    PERFORM pg_temp.expect('reenviar enseguida (pending)', v_r2.o_state, v_r2.o_msg, 'P0439', 'invitation_cooldown');
    UPDATE public.email_logs SET status = 'sent', sent_at = now() WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_id::text;
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_id, 'x', false));
    PERFORM pg_temp.expect('reenviar enseguida (sent)', v_r2.o_state, v_r2.o_msg, 'P0439', 'invitation_cooldown');
    -- Hace 1 minuto y FALLIDO: no bloquea.
    UPDATE public.email_logs SET status = 'failed', created_at = now() - interval '1 minute' WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_id::text;
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_id, 'x', false));
    PERFORM pg_temp.expect('reenviar tras un envío fallido', v_r2.o_state, v_r2.o_msg, 'ok');
    -- Y ahora el nuevo envío (pending, no fallido) vuelve a bloquear.
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_id, 'x', false));
    PERFORM pg_temp.expect('reenviar otra vez enseguida', v_r2.o_state, v_r2.o_msg, 'P0439', 'invitation_cooldown');

    -- Los failed SÍ cuentan para el tope diario: 20 envíos fallidos de la cuenta B en las últimas 24 h.
    FOR v_n IN 1..20 LOOP
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, status, metadata)
      VALUES (v_z, 'org_invite', 'ih-cap-' || v_n || '@test.local', 's', 'failed',
              jsonb_build_object('invitation_id', gen_random_uuid(), 'account_id', v_b, 'n', v_n));
    END LOOP;
    SELECT * INTO v_r FROM pg_temp.run(v_z, v_b, pg_temp.e_invite('ih-h-cap@test.local', v_b, ARRAY['viewer']));
    PERFORM pg_temp.expect('invitar en B', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_r2 FROM pg_temp.run(v_z, v_b, pg_temp.e_send((v_r.o_res ->> 'id')::uuid, 'x', false));
    PERFORM pg_temp.expect('el tope diario cuenta los fallidos', v_r2.o_state, v_r2.o_msg, 'P0439', 'invitation_daily_cap');
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (h)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (i) ACLs y una sola definición viva por función ──────────────────────────
  v_blk := '(i) ACLs';
  BEGIN
    IF to_regprocedure('public._invitation_token_hash(text)') IS NULL THEN RAISE EXCEPTION 'falta el helper _invitation_token_hash'; END IF;
    IF has_function_privilege('authenticated', 'public._invitation_token_hash(text)', 'EXECUTE')
       OR has_function_privilege('anon', 'public._invitation_token_hash(text)', 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                  WHERE p.oid = 'public._invitation_token_hash(text)'::regprocedure AND a.grantee = 0) THEN
      RAISE EXCEPTION 'el helper _invitation_token_hash no puede ser ejecutable por authenticated/anon/PUBLIC';
    END IF;
    FOR v_txt IN SELECT unnest(ARRAY['rpc_invite_member','rpc_accept_invitation','rpc_send_invitation_email','rpc_list_account_invitations','rpc_revoke_invitation','rpc_invitation_preview']) LOOP
      SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_txt;
      IF v_n <> 1 THEN RAISE EXCEPTION '% debía tener UNA definición viva, tiene %', v_txt, v_n; END IF;
      IF EXISTS (
        SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_txt
          AND (has_function_privilege('anon', p.oid, 'EXECUTE')
               OR NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
               OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0))
      ) THEN
        RAISE EXCEPTION '% tiene mal su ACL (anon/PUBLIC con EXECUTE o authenticated sin él)', v_txt;
      END IF;
    END LOOP;
    -- El disparador de retiro existe y su función es interna.
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.email_logs'::regclass AND tgname = 'trg_email_logs_strip_invite_token' AND NOT tgisinternal) THEN
      RAISE EXCEPTION 'falta el disparador trg_email_logs_strip_invite_token';
    END IF;
    -- rpc_invite_member ya no devuelve el token (cuerpo) y el envío es el único que lo genera.
    IF regexp_replace(pg_get_functiondef('public.rpc_invite_member(text,uuid,text[])'::regprocedure), '--[^\n]*', '', 'g') ~ 'gen_random_bytes' THEN
      RAISE EXCEPTION 'rpc_invite_member ya no genera el token';
    END IF;
    v_pass := v_pass + 1;
    RAISE NOTICE 'PASS (i)';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  IF coalesce(array_length(v_fail, 1), 0) > 0 OR v_pass <> 9 THEN
    RAISE EXCEPTION 'GATE INVITACIONES-HARDENING FALLÓ (% de 9 bloques OK): %', v_pass, array_to_string(v_fail, ' || ');
  END IF;
  RAISE NOTICE 'GATE INVITACIONES-HARDENING OK: token sólo como hash, retiro del token en email_logs, tabla sólo-RPC con ataque real rechazado, estado de entrega en el listado, enfriamiento sin fallidos, ACLs (a-i).';
END
$gate$;

ROLLBACK;
