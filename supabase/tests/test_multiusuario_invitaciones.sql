-- =============================================================================
-- GATE: test_multiusuario_invitaciones.sql
-- CHANGE: multiusuario-operativo — TANDA C (tasks 13.1-13.3, 14.3, 14.4)
--
-- Ejercita de verdad, como `authenticated` con `request.jwt.claims` armado a
-- mano (el mismo mecanismo que PostgREST y que `get_db_conn` de FastAPI: SIN
-- email en los claims, sólo `sub`, `role` y `app_metadata.account_id`), el
-- recorrido completo de la invitación a una cuenta:
--
--   rpc_invite_member(email, cuenta, roles)       crea la invitación (3 args; el de 2 se RETIRA)
--   rpc_send_invitation_email(id, nombre, renew)  encola el email `org_invite` y rota el token al reenviar
--   rpc_list_account_invitations(cuenta)          pendientes + vencidas/revocadas de los últimos 30 días
--   rpc_revoke_invitation(id)                     pasa la invitación a `revoked`
--   rpc_invitation_preview(token)                 vista previa LIGADA A LA IDENTIDAD del invitado
--   rpc_accept_invitation(token)                  crea la membresía y DEJA EL NEGOCIO COMO CUENTA ACTIVA
--
--   EL HUECO (design.md Context · Invitaciones). `rpc_invite_member` crea la fila
--   y devuelve el token, pero NADIE manda un email y `rpc_accept_invitation` no
--   tiene llamador: no hay forma de sumarse a una cuenta. Y aun si la hubiera, el
--   invitado tiene además su cuenta personal: sin activar el negocio al aceptar,
--   su primera venta caería en la personal (R3l).
--
--   EL ARREGLO (D7, D10, D12, D13, D14). El email se encola ADENTRO de una RPC
--   DEFINER en la misma transacción que crea o renueva la invitación, con el
--   destinatario y el token de la FILA —nunca de un parámetro—. La vista previa
--   devuelve el negocio sólo si la identidad coincide con el email de la
--   invitación (mismo error que un token vencido si no). Reenviar ROTA el token.
--   Revocar es un estado. Tope: 1 envío por invitación cada 10 minutos y 20 por
--   cuenta por día (P0439). El overload de 2 argumentos de rpc_invite_member
--   desaparece.
--
-- Fixtures (todos @test.local, dentro de BEGIN..ROLLBACK: residuo cero). Cada
-- usuario tiene además su cuenta personal (la crea `handle_new_user`).
--   O  dueño de A         AD administrador de A     S  vendedor de A
--   V  observador de A    I  invitado (aún sin A)   W  OTRA identidad (aún sin A)
--   Z  dueño de B (cuenta ajena)
--
-- Estructura: cada bloque corre en su sub-bloque con EXCEPTION y registra su
-- falla en vez de abortar (el RED 13.3 muestra de una vez QUÉ bloques fallan); al
-- final, si hubo alguna, el gate aborta listándolas.
--
--   (a) el envío encola `org_invite` con el destinatario y el token de la FILA
--   (b) autoridad: el vendedor P0403, el observador P0401, otra cuenta P0404,
--       sin sesión P0401 — y un rechazo no deja ningún email
--   (c) enfriamiento por invitación (P0439) y reenvío que ROTA el token
--   (d) tope diario por cuenta (P0439), por cuenta y con ventana de 24 h
--   (e) revocar: la aceptación y la vista previa fallan igual que un token vencido
--   (f) listar: sin token, ventana de 30 días, sólo owner/admin de la cuenta activa
--   (g) vista previa ligada a la identidad
--   (h) aceptar: el negocio queda como cuenta activa y la personal se conserva
--   (i) validación del email y "Not authenticated" = P0401
--   (j) ESTRUCTURAL: overload de 2 args retirado, CHECK con `revoked`, ACLs, una
--       definición viva por función, candado de cuerpo, email_logs sigue cerrada
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

CREATE FUNCTION pg_temp.as_anon() RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END $f$;

-- Corre una expresión de RPC (escalar) como `authenticated`. NUNCA lanza.
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

-- Lo mismo para una función que devuelve TABLE: agrega las filas en un arreglo jsonb.
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

-- Impersona y corre.
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

CREATE FUNCTION pg_temp.run_anon(p_expr text, OUT o_state text, OUT o_msg text, OUT o_res jsonb)
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.as_anon();
  SELECT t.o_state, t.o_msg, t.o_res INTO o_state, o_msg, o_res FROM pg_temp.try_rpc(p_expr) t;
END $f$;

-- Expresiones de RPC (texto). Las firmas son las NUEVAS de la tanda C.
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

-- Expectativa: lanza si el estado/mensaje no es el esperado. p_exp = 'ok' => sin error.
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

-- Cuántos emails `org_invite` hay (opcionalmente de una invitación o de un destinatario).
CREATE FUNCTION pg_temp.n_mail(p_inv uuid DEFAULT NULL, p_to text DEFAULT NULL) RETURNS integer
LANGUAGE sql AS $f$
  SELECT count(*)::integer FROM public.email_logs
  WHERE event_type = 'org_invite'
    AND (p_inv IS NULL OR metadata ->> 'invitation_id' = p_inv::text)
    AND (p_to IS NULL OR recipient = p_to)
$f$;

-- Mensaje de un rechazo de token (sin ids), para comparar "token vencido" con "otra identidad".
CREATE FUNCTION pg_temp.noid(p_msg text) RETURNS text
LANGUAGE sql IMMUTABLE AS $f$
  SELECT regexp_replace(COALESCE(p_msg, ''), '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<id>', 'g')
$f$;

-- ═════════════════════════════════════════════════════════════════════════════
DO $gate$
DECLARE
  v_fail   text[] := ARRAY[]::text[];
  v_blk    text;

  -- Usuarios
  v_o  uuid := gen_random_uuid();  v_ad uuid := gen_random_uuid();  v_s  uuid := gen_random_uuid();
  v_v  uuid := gen_random_uuid();  v_i  uuid := gen_random_uuid();  v_w  uuid := gen_random_uuid();
  v_z  uuid := gen_random_uuid();
  -- Cuentas
  v_a  uuid;  v_b uuid;  v_pi uuid;   -- A (negocio), B (ajena), personal de I

  v_member uuid;
  v_uid uuid;  v_txt text;
  v_r record;  v_r2 record;
  v_inv uuid;  v_inv2 uuid;  v_inv3 uuid;  v_inv4 uuid;
  v_tok text;  v_tok2 text;  v_tok3 text;
  v_n integer;  v_n0 integer;
  v_row record;
  v_exp0 timestamptz;
  v_def text;
  v_msg_gen text;  v_msg_other text;
  v_acc uuid;
  v_hist integer;
  v_long text := repeat('Ñandú ', 60);   -- 360 caracteres
BEGIN
  -- ── Fixtures ───────────────────────────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) VALUES
    (v_o,  'authenticated', 'authenticated', 'mu-c-owner@test.local',   now(), now(), '{"name":"MUC Dueno"}'::jsonb),
    (v_ad, 'authenticated', 'authenticated', 'mu-c-admin@test.local',   now(), now(), '{"name":"MUC Admin"}'::jsonb),
    (v_s,  'authenticated', 'authenticated', 'mu-c-seller@test.local',  now(), now(), '{"name":"MUC Vendedor"}'::jsonb),
    (v_v,  'authenticated', 'authenticated', 'mu-c-viewer@test.local',  now(), now(), '{"name":"MUC Observador"}'::jsonb),
    (v_i,  'authenticated', 'authenticated', 'mu-c-invitee@test.local', now(), now(), '{"name":"MUC Invitado"}'::jsonb),
    (v_w,  'authenticated', 'authenticated', 'mu-c-wrong@test.local',   now(), now(), '{"name":"MUC Otra"}'::jsonb),
    (v_z,  'authenticated', 'authenticated', 'mu-c-zeta@test.local',    now(), now(), '{"name":"MUC Zeta"}'::jsonb);

  SELECT account_id INTO v_a  FROM public.account_members WHERE user_id = v_o;
  SELECT account_id INTO v_b  FROM public.account_members WHERE user_id = v_z;
  SELECT account_id INTO v_pi FROM public.account_members WHERE user_id = v_i;
  IF v_a IS NULL OR v_b IS NULL OR v_pi IS NULL THEN
    RAISE EXCEPTION 'GATE MULTIUSUARIO-INVITACIONES (fixture): handle_new_user no creó la cuenta de algún usuario sintético (a=%, b=%, pi=%).', v_a, v_b, v_pi;
  END IF;

  -- Plan 'pro' (cupo 10) con el trial apagado: el cupo no es lo que mide este gate.
  UPDATE public.accounts SET billing_plan = 'pro', trial_plan = NULL, trial_expires_at = NULL WHERE id IN (v_a, v_b);

  FOR v_uid, v_txt IN VALUES (v_ad, 'admin'), (v_s, 'seller'), (v_v, 'viewer')
  LOOP
    INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_a, v_uid, 'member') RETURNING id INTO v_member;
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_member, v_txt);
  END LOOP;

  -- ── (a) el envío encola `org_invite` con el destinatario y el token de la FILA ─
  v_blk := '(a) el envío encola el email desde la fila';
  BEGIN
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('mu-c-invitee@test.local', v_a, ARRAY['seller']));
    PERFORM pg_temp.expect('el dueño invita', v_r.o_state, v_r.o_msg, 'ok');
    v_inv := (v_r.o_res ->> 'id')::uuid;
    v_tok := v_r.o_res ->> 'token';
    IF pg_temp.n_mail(v_inv) <> 0 THEN
      RAISE EXCEPTION 'crear la invitación NO envía el email por sí sola (lo hace rpc_send_invitation_email): hay % filas', pg_temp.n_mail(v_inv);
    END IF;

    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'Panadería <b>Sol</b> & Hijos', false));
    PERFORM pg_temp.expect('el dueño envía el email', v_r.o_state, v_r.o_msg, 'ok');
    IF (v_r.o_res ->> 'token') IS DISTINCT FROM v_tok THEN
      RAISE EXCEPTION 'el primer envío NO rota el token (era %, volvió %)', v_tok, v_r.o_res ->> 'token';
    END IF;

    SELECT * INTO v_row FROM public.email_logs WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text;
    IF NOT FOUND THEN RAISE EXCEPTION 'no se encoló ningún email org_invite'; END IF;
    IF pg_temp.n_mail(v_inv) <> 1 THEN RAISE EXCEPTION 'debía haber UN email, hay %', pg_temp.n_mail(v_inv); END IF;
    IF v_row.recipient IS DISTINCT FROM 'mu-c-invitee@test.local' THEN
      RAISE EXCEPTION 'el destinatario debía ser el email de la FILA (mu-c-invitee@test.local), es %', v_row.recipient;
    END IF;
    IF v_row.metadata ->> 'token' IS DISTINCT FROM v_tok THEN
      RAISE EXCEPTION 'el token del email debía ser el de la fila, es %', v_row.metadata ->> 'token';
    END IF;
    IF v_row.user_id IS DISTINCT FROM v_o THEN RAISE EXCEPTION 'user_id debía ser el invitador (%), es %', v_o, v_row.user_id; END IF;
    IF v_row.status IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 'el email debía nacer pending, es %', v_row.status; END IF;
    IF COALESCE(v_row.subject, '') = '' THEN RAISE EXCEPTION 'el email no tiene asunto'; END IF;
    IF (v_row.metadata ->> 'account_id') IS DISTINCT FROM v_a::text THEN RAISE EXCEPTION 'metadata.account_id debía ser A, es %', v_row.metadata ->> 'account_id'; END IF;
    IF (v_row.metadata ->> 'account_name') IS DISTINCT FROM 'Panadería <b>Sol</b> & Hijos' THEN
      RAISE EXCEPTION 'metadata.account_name debía conservar el nombre (se escapa en la plantilla), es %', v_row.metadata ->> 'account_name';
    END IF;
    IF (v_row.metadata ->> 'inviter_name') IS DISTINCT FROM 'MUC Dueno' THEN
      RAISE EXCEPTION 'metadata.inviter_name debía salir de profiles (MUC Dueno), es %', v_row.metadata ->> 'inviter_name';
    END IF;
    IF (v_row.metadata -> 'role_labels') IS DISTINCT FROM '["Vendedor"]'::jsonb THEN
      RAISE EXCEPTION 'metadata.role_labels debía salir del catálogo (["Vendedor"]), es %', v_row.metadata -> 'role_labels';
    END IF;
    IF (v_row.metadata ->> 'expires_at') IS NULL THEN RAISE EXCEPTION 'metadata.expires_at falta'; END IF;
    -- El snapshot del negocio queda en la fila (lo necesita la vista previa: el invitado todavía no es miembro).
    IF (SELECT account_display_name FROM public.account_invitations WHERE id = v_inv) IS DISTINCT FROM 'Panadería <b>Sol</b> & Hijos' THEN
      RAISE EXCEPTION 'account_invitations.account_display_name debía guardar el snapshot';
    END IF;

    -- Nada de lo que define a quién le llega ni qué link lleva sale de un parámetro: la función no recibe email ni token.
    SELECT pg_get_function_arguments(p.oid) INTO v_def
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_send_invitation_email';
    IF v_def ~* '(email|token|recipient|destinat)' THEN
      RAISE EXCEPTION 'rpc_send_invitation_email NO puede recibir destinatario ni token por parámetro; recibe: %', v_def;
    END IF;

    -- El nombre del negocio se recorta a 120 caracteres y se le quitan los caracteres de control (asunto).
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('mu-c-long@test.local', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('invita (nombre largo)', v_r.o_state, v_r.o_msg, 'ok');
    v_inv4 := (v_r.o_res ->> 'id')::uuid;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv4, E'Línea 1\r\nBcc: x@y.z ' || v_long, false));
    PERFORM pg_temp.expect('envía (nombre largo)', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_row FROM public.email_logs WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv4::text;
    IF length(v_row.metadata ->> 'account_name') > 120 THEN
      RAISE EXCEPTION 'metadata.account_name debía recortarse a 120, mide %', length(v_row.metadata ->> 'account_name');
    END IF;
    IF v_row.subject ~ '[\r\n]' OR (v_row.metadata ->> 'account_name') ~ '[\r\n]' THEN
      RAISE EXCEPTION 'el asunto y el nombre no pueden llevar saltos de línea (inyección de encabezados)';
    END IF;
    -- Sin nombre: el email igual sale, con un nombre genérico.
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('mu-c-noname@test.local', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('invita (sin nombre)', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_r2 FROM pg_temp.run(v_o, v_a, pg_temp.e_send((v_r.o_res ->> 'id')::uuid, NULL, false));
    PERFORM pg_temp.expect('envía (sin nombre)', v_r2.o_state, v_r2.o_msg, 'ok');
    IF COALESCE((SELECT metadata ->> 'account_name' FROM public.email_logs WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = (v_r.o_res ->> 'id')), '') = '' THEN
      RAISE EXCEPTION 'sin nombre de negocio el email debía llevar un nombre genérico, no vacío';
    END IF;
    RAISE NOTICE 'PASS (a): el envío encola UN org_invite con el recipient y el token de la fila, el invitador, las etiquetas del catálogo y el snapshot; sin parámetros de destino; nombre recortado y sin saltos de línea.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (b) autoridad: quién puede y quién no, sin dejar emails ──────────────────
  v_blk := '(b) autoridad';
  BEGIN
    -- El vendedor no invita (existente) ni reenvía.
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_invite('mu-c-x1@test.local', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('el vendedor invita', v_r.o_state, v_r.o_msg, 'P0403');
    v_n0 := pg_temp.n_mail();
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_send(v_inv, 'x', true));
    PERFORM pg_temp.expect('el vendedor reenvía', v_r.o_state, v_r.o_msg, 'P0403');
    -- El observador (no escritor) es P0401.
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_send(v_inv, 'x', true));
    PERFORM pg_temp.expect('el observador reenvía', v_r.o_state, v_r.o_msg, 'P0401');
    -- Otra cuenta (Z, dueño de B, con SU claim): la invitación de A es P0404, indistinguible de una inexistente.
    SELECT * INTO v_r FROM pg_temp.run(v_z, v_b, pg_temp.e_send(v_inv, 'x', true));
    PERFORM pg_temp.expect('el dueño de OTRA cuenta reenvía', v_r.o_state, v_r.o_msg, 'P0404');
    SELECT * INTO v_r2 FROM pg_temp.run(v_z, v_b, pg_temp.e_send(gen_random_uuid(), 'x', true));
    PERFORM pg_temp.expect('reenviar una invitación inexistente', v_r2.o_state, v_r2.o_msg, 'P0404');
    IF pg_temp.noid(v_r.o_msg) IS DISTINCT FROM pg_temp.noid(v_r2.o_msg) THEN
      RAISE EXCEPTION 'la invitación AJENA y la INEXISTENTE no son indistinguibles: "%" vs "%"', v_r.o_msg, v_r2.o_msg;
    END IF;
    -- Sin sesión: P0401.
    SELECT * INTO v_r FROM pg_temp.run_anon(pg_temp.e_send(v_inv, 'x', true));
    PERFORM pg_temp.expect('reenviar sin sesión', v_r.o_state, v_r.o_msg, 'P0401');
    IF pg_temp.n_mail() <> v_n0 THEN
      RAISE EXCEPTION 'los rechazos dejaron emails (antes %, después %)', v_n0, pg_temp.n_mail();
    END IF;
    -- El administrador SÍ invita y envía.
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_invite('mu-c-by-admin@test.local', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('el administrador invita', v_r.o_state, v_r.o_msg, 'ok');
    v_inv2 := (v_r.o_res ->> 'id')::uuid;
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_send(v_inv2, 'Panadería Sol', false));
    PERFORM pg_temp.expect('el administrador envía', v_r.o_state, v_r.o_msg, 'ok');
    IF pg_temp.n_mail(v_inv2, 'mu-c-by-admin@test.local') <> 1 THEN RAISE EXCEPTION 'el envío del administrador no encoló el email'; END IF;
    RAISE NOTICE 'PASS (b): vendedor P0403, observador P0401, otra cuenta P0404 (indistinguible de inexistente), sin sesión P0401; el administrador sí; los rechazos no dejan emails.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (c) enfriamiento por invitación y reenvío que ROTA el token ──────────────
  v_blk := '(c) enfriamiento y reenvío con token nuevo';
  BEGIN
    v_n0 := pg_temp.n_mail(v_inv);
    -- Reenviar enseguida: el email de (a) se encoló hace instantes.
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'Panadería Sol', true));
    PERFORM pg_temp.expect('reenviar enseguida', v_r.o_state, v_r.o_msg, 'P0439', 'invitation_cooldown');
    IF pg_temp.n_mail(v_inv) <> v_n0 THEN RAISE EXCEPTION 'el reenvío rechazado por enfriamiento encoló un email'; END IF;
    IF (SELECT token FROM public.account_invitations WHERE id = v_inv) IS DISTINCT FROM v_tok THEN
      RAISE EXCEPTION 'el reenvío rechazado por enfriamiento rotó el token';
    END IF;

    -- Pasada la ventana de 10 minutos y con el vencimiento a punto de caer, reenviar rota el token y lo renueva.
    UPDATE public.email_logs SET created_at = created_at - interval '11 minutes'
     WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text;
    UPDATE public.account_invitations SET expires_at = now() + interval '1 hour' WHERE id = v_inv;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'Panadería Sol', true));
    PERFORM pg_temp.expect('reenviar pasado el enfriamiento', v_r.o_state, v_r.o_msg, 'ok');
    v_tok2 := v_r.o_res ->> 'token';
    IF v_tok2 IS NULL OR v_tok2 = v_tok THEN RAISE EXCEPTION 'reenviar debía ROTAR el token (era %, es %)', v_tok, v_tok2; END IF;
    IF (SELECT token FROM public.account_invitations WHERE id = v_inv) IS DISTINCT FROM v_tok2 THEN
      RAISE EXCEPTION 'la fila debía quedar con el token nuevo';
    END IF;
    IF (SELECT expires_at FROM public.account_invitations WHERE id = v_inv) < now() + interval '6 days 23 hours' THEN
      RAISE EXCEPTION 'reenviar debía renovar el vencimiento a 7 días, quedó en %', (SELECT expires_at FROM public.account_invitations WHERE id = v_inv);
    END IF;
    IF pg_temp.n_mail(v_inv) <> v_n0 + 1 THEN RAISE EXCEPTION 'el reenvío debía encolar UN email nuevo'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.email_logs WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text AND metadata ->> 'token' = v_tok2 AND recipient = 'mu-c-invitee@test.local') THEN
      RAISE EXCEPTION 'el email del reenvío debía llevar el token NUEVO y el destinatario de la fila';
    END IF;

    -- El link anterior dejó de servir: ni la vista previa ni la aceptación lo reconocen.
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_preview(v_tok));
    PERFORM pg_temp.expect('vista previa con el token VIEJO', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_accept(v_tok));
    PERFORM pg_temp.expect('aceptar con el token VIEJO', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    IF EXISTS (SELECT 1 FROM public.account_members WHERE account_id = v_a AND user_id = v_i) THEN
      RAISE EXCEPTION 'el token viejo creó una membresía';
    END IF;

    -- Una invitación vencida se puede reenviar (sigue pending): revive con token nuevo.
    UPDATE public.email_logs SET created_at = created_at - interval '11 minutes'
     WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text;
    UPDATE public.account_invitations SET expires_at = now() - interval '1 day' WHERE id = v_inv;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'Panadería Sol', true));
    PERFORM pg_temp.expect('reenviar una invitación vencida', v_r.o_state, v_r.o_msg, 'ok');
    v_tok3 := v_r.o_res ->> 'token';
    IF v_tok3 IS NULL OR v_tok3 = v_tok2 THEN RAISE EXCEPTION 'reenviar la vencida debía rotar el token otra vez'; END IF;
    IF (SELECT expires_at FROM public.account_invitations WHERE id = v_inv) <= now() THEN
      RAISE EXCEPTION 'reenviar la vencida debía renovar el vencimiento';
    END IF;
    -- Pero SIN renovar (p_renew = false) una invitación vencida no se envía.
    UPDATE public.email_logs SET created_at = created_at - interval '11 minutes'
     WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text;
    UPDATE public.account_invitations SET expires_at = now() - interval '1 day' WHERE id = v_inv;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'Panadería Sol', false));
    PERFORM pg_temp.expect('enviar (sin renovar) una invitación vencida', v_r.o_state, v_r.o_msg, 'P0409', 'invitation_not_pending');
    -- Se deja vigente con el token vigente para los bloques que siguen.
    UPDATE public.account_invitations SET expires_at = now() + interval '7 days' WHERE id = v_inv;
    v_tok := v_tok3;
    RAISE NOTICE 'PASS (c): reenviar enseguida = P0439 sin efectos; pasado el enfriamiento ROTA el token, renueva el vencimiento y encola el email con el token nuevo; el link viejo deja de servir; la vencida revive.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (d) tope diario por cuenta ───────────────────────────────────────────────
  v_blk := '(d) tope diario de la cuenta';
  BEGIN
    UPDATE public.email_logs SET created_at = created_at - interval '11 minutes'
     WHERE event_type = 'org_invite' AND metadata ->> 'account_id' = v_a::text;
    SELECT count(*) INTO v_n FROM public.email_logs
     WHERE event_type = 'org_invite' AND metadata ->> 'account_id' = v_a::text AND created_at > now() - interval '1 day';
    -- Se completan 20 envíos en las últimas 24 h (filas sintéticas ya 'sent': no disparan el webhook).
    FOR v_n0 IN 1..(20 - v_n) LOOP
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, status, metadata, created_at)
      VALUES (v_o, 'org_invite', format('mu-c-cap-%s@test.local', v_n0), 'cap', 'sent',
              jsonb_build_object('account_id', v_a, 'invitation_id', gen_random_uuid(), 'k', v_n0), now() - interval '2 hours');
    END LOOP;
    IF (SELECT count(*) FROM public.email_logs WHERE event_type = 'org_invite' AND metadata ->> 'account_id' = v_a::text AND created_at > now() - interval '1 day') <> 20 THEN
      RAISE EXCEPTION 'el fixture del tope no quedó en 20 envíos';
    END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('mu-c-cap@test.local', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('invita (cuenta en el tope)', v_r.o_state, v_r.o_msg, 'ok');
    v_inv3 := (v_r.o_res ->> 'id')::uuid;
    v_n := pg_temp.n_mail();
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv3, 'Panadería Sol', false));
    PERFORM pg_temp.expect('el envío 21 del día', v_r.o_state, v_r.o_msg, 'P0439', 'invitation_daily_cap');
    IF pg_temp.n_mail() <> v_n THEN RAISE EXCEPTION 'el envío rechazado por el tope encoló un email'; END IF;
    -- El tope es POR CUENTA: la cuenta B envía normalmente.
    SELECT * INTO v_r FROM pg_temp.run(v_z, v_b, pg_temp.e_invite('mu-c-zb@test.local', v_b, ARRAY['viewer']));
    PERFORM pg_temp.expect('Z invita (cuenta B)', v_r.o_state, v_r.o_msg, 'ok');
    SELECT * INTO v_r2 FROM pg_temp.run(v_z, v_b, pg_temp.e_send((v_r.o_res ->> 'id')::uuid, 'Negocio B', false));
    PERFORM pg_temp.expect('la cuenta B no comparte el tope de A', v_r2.o_state, v_r2.o_msg, 'ok');
    -- La ventana es de 24 horas: pasado el día, A vuelve a poder.
    UPDATE public.email_logs SET created_at = created_at - interval '25 hours'
     WHERE event_type = 'org_invite' AND metadata ->> 'account_id' = v_a::text;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv3, 'Panadería Sol', false));
    PERFORM pg_temp.expect('pasadas 24 h el tope se libera', v_r.o_state, v_r.o_msg, 'ok');
    RAISE NOTICE 'PASS (d): con 20 envíos en 24 h el siguiente es P0439 invitation_daily_cap sin efectos; la cuenta B no lo comparte; pasadas 24 h se libera.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (e) revocar ──────────────────────────────────────────────────────────────
  v_blk := '(e) revocar';
  BEGIN
    -- Invitación nueva para I (la de (a)/(c) sigue vigente con v_tok; se revoca ESA).
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_revoke(v_inv));
    PERFORM pg_temp.expect('el vendedor revoca', v_r.o_state, v_r.o_msg, 'P0403');
    SELECT * INTO v_r FROM pg_temp.run(v_v, v_a, pg_temp.e_revoke(v_inv));
    PERFORM pg_temp.expect('el observador revoca', v_r.o_state, v_r.o_msg, 'P0401');
    SELECT * INTO v_r FROM pg_temp.run(v_z, v_b, pg_temp.e_revoke(v_inv));
    PERFORM pg_temp.expect('el dueño de OTRA cuenta revoca', v_r.o_state, v_r.o_msg, 'P0404');
    SELECT * INTO v_r FROM pg_temp.run_anon(pg_temp.e_revoke(v_inv));
    PERFORM pg_temp.expect('revocar sin sesión', v_r.o_state, v_r.o_msg, 'P0401');
    IF (SELECT status FROM public.account_invitations WHERE id = v_inv) <> 'pending' THEN
      RAISE EXCEPTION 'un rechazo revocó la invitación';
    END IF;

    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_revoke(v_inv));
    PERFORM pg_temp.expect('el dueño revoca', v_r.o_state, v_r.o_msg, 'ok');
    IF (SELECT status FROM public.account_invitations WHERE id = v_inv) <> 'revoked' THEN
      RAISE EXCEPTION 'la invitación debía quedar revoked';
    END IF;
    IF (SELECT revoked_at FROM public.account_invitations WHERE id = v_inv) IS NULL THEN
      RAISE EXCEPTION 'la revocación debía dejar revoked_at';
    END IF;
    -- Idempotente: revocar otra vez no falla ni cambia nada.
    SELECT * INTO v_r FROM pg_temp.run(v_ad, v_a, pg_temp.e_revoke(v_inv));
    PERFORM pg_temp.expect('revocar de nuevo (idempotente)', v_r.o_state, v_r.o_msg, 'ok');

    -- La aceptación y la vista previa fallan con el MISMO error que un token vencido o inexistente.
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_accept(v_tok));
    PERFORM pg_temp.expect('aceptar una revocada', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    SELECT * INTO v_r2 FROM pg_temp.run(v_i, v_pi, pg_temp.e_accept('token-que-no-existe'));
    IF v_r.o_msg IS DISTINCT FROM v_r2.o_msg THEN
      RAISE EXCEPTION 'revocada e inexistente no son indistinguibles: "%" vs "%"', v_r.o_msg, v_r2.o_msg;
    END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_preview(v_tok));
    PERFORM pg_temp.expect('vista previa de una revocada', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    -- Una revocada no se reenvía (ni con renovar), no se "des-revoca".
    UPDATE public.email_logs SET created_at = created_at - interval '11 minutes'
     WHERE event_type = 'org_invite' AND metadata ->> 'invitation_id' = v_inv::text;
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_send(v_inv, 'x', true));
    PERFORM pg_temp.expect('reenviar una revocada', v_r.o_state, v_r.o_msg, 'P0409', 'invitation_not_pending');
    -- Y se puede invitar de nuevo al mismo email (la duplicada sólo cuenta las pendientes).
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('mu-c-invitee@test.local', v_a, ARRAY['seller']));
    PERFORM pg_temp.expect('invitar de nuevo tras revocar', v_r.o_state, v_r.o_msg, 'ok');
    v_inv := (v_r.o_res ->> 'id')::uuid;
    v_tok := v_r.o_res ->> 'token';
    RAISE NOTICE 'PASS (e): vendedor P0403, observador P0401, otra cuenta P0404, sin sesión P0401; revocar es un estado idempotente con revoked_at; aceptar y previsualizar fallan IGUAL que un token inexistente; no se reenvía; se puede reinvitar.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (f) listar ───────────────────────────────────────────────────────────────
  v_blk := '(f) listar';
  BEGIN
    SELECT * INTO v_r FROM pg_temp.run_tbl(v_o, v_a, pg_temp.e_list(v_a));
    PERFORM pg_temp.expect('el dueño lista', v_r.o_state, v_r.o_msg, 'ok');
    IF jsonb_array_length(v_r.o_res) < 4 THEN RAISE EXCEPTION 'el listado debía traer las pendientes y la revocada reciente, trajo %', jsonb_array_length(v_r.o_res); END IF;
    IF v_r.o_res::text ~* '"token"' THEN RAISE EXCEPTION 'el listado NO puede exponer el token'; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r.o_res) e WHERE e ->> 'state' = 'revoked') THEN
      RAISE EXCEPTION 'la revocada reciente debía aparecer con state=revoked';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r.o_res) e WHERE e ->> 'id' = v_inv::text AND e ->> 'state' = 'pending' AND e ->> 'email' = 'mu-c-invitee@test.local') THEN
      RAISE EXCEPTION 'la pendiente de I debía aparecer con state=pending';
    END IF;
    -- last_sent_at / send_count salen del historial de emails.
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r.o_res) e WHERE e ->> 'id' = v_inv4::text AND (e ->> 'send_count')::integer = 1 AND e ->> 'last_sent_at' IS NOT NULL) THEN
      RAISE EXCEPTION 'send_count/last_sent_at no reflejan los envíos';
    END IF;
    -- El administrador también lista.
    SELECT * INTO v_r2 FROM pg_temp.run_tbl(v_ad, v_a, pg_temp.e_list(v_a));
    PERFORM pg_temp.expect('el administrador lista', v_r2.o_state, v_r2.o_msg, 'ok');
    -- El vendedor, el observador, otra cuenta y el anónimo, no.
    SELECT * INTO v_r2 FROM pg_temp.run_tbl(v_s, v_a, pg_temp.e_list(v_a));
    PERFORM pg_temp.expect('el vendedor lista', v_r2.o_state, v_r2.o_msg, 'P0403');
    SELECT * INTO v_r2 FROM pg_temp.run_tbl(v_v, v_a, pg_temp.e_list(v_a));
    PERFORM pg_temp.expect('el observador lista', v_r2.o_state, v_r2.o_msg, 'P0401');
    SELECT * INTO v_r2 FROM pg_temp.run_tbl(v_z, v_b, pg_temp.e_list(v_a));
    PERFORM pg_temp.expect('el dueño de OTRA cuenta lista la de A', v_r2.o_state, v_r2.o_msg, 'P0404');
    -- Las vencidas hace más de 30 días y las revocadas hace más de 30 días no aparecen; las aceptadas, nunca.
    UPDATE public.account_invitations SET expires_at = now() - interval '40 days' WHERE id = v_inv2;
    SELECT * INTO v_r2 FROM pg_temp.run_tbl(v_o, v_a, pg_temp.e_list(v_a));
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r2.o_res) e WHERE e ->> 'id' = v_inv2::text) THEN
      RAISE EXCEPTION 'una vencida hace 40 días no debía listarse';
    END IF;
    UPDATE public.account_invitations SET expires_at = now() - interval '2 days' WHERE id = v_inv2;
    SELECT * INTO v_r2 FROM pg_temp.run_tbl(v_o, v_a, pg_temp.e_list(v_a));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r2.o_res) e WHERE e ->> 'id' = v_inv2::text AND e ->> 'state' = 'expired') THEN
      RAISE EXCEPTION 'una vencida hace 2 días debía listarse con state=expired';
    END IF;
    UPDATE public.account_invitations SET expires_at = now() + interval '7 days' WHERE id = v_inv2;
    RAISE NOTICE 'PASS (f): el dueño y el administrador listan (sin token, con state/send_count/last_sent_at); vendedor P0403, observador P0401, otra cuenta P0404; ventana de 30 días.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (g) vista previa ligada a la identidad ───────────────────────────────────
  v_blk := '(g) vista previa ligada a la identidad';
  BEGIN
    -- Para I hay una invitación vigente (v_inv, token v_tok) con snapshot: se le pone nombre.
    UPDATE public.account_invitations SET account_display_name = 'Panadería Sol' WHERE id = v_inv;
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_preview(v_tok));
    PERFORM pg_temp.expect('I (la identidad invitada) previsualiza', v_r.o_state, v_r.o_msg, 'ok');
    IF v_r.o_res ->> 'account_display_name' IS DISTINCT FROM 'Panadería Sol' THEN RAISE EXCEPTION 'faltó el snapshot del negocio: %', v_r.o_res; END IF;
    IF v_r.o_res ->> 'inviter_name' IS DISTINCT FROM 'MUC Dueno' THEN RAISE EXCEPTION 'faltó el nombre de quien invita: %', v_r.o_res; END IF;
    IF (v_r.o_res -> 'role_labels') IS DISTINCT FROM '["Vendedor"]'::jsonb THEN RAISE EXCEPTION 'faltaron las etiquetas de rol: %', v_r.o_res; END IF;
    IF (v_r.o_res -> 'roles') IS DISTINCT FROM '["seller"]'::jsonb THEN RAISE EXCEPTION 'faltó el conjunto de roles: %', v_r.o_res; END IF;
    IF v_r.o_res ->> 'expires_at' IS NULL THEN RAISE EXCEPTION 'faltó el vencimiento'; END IF;
    IF (v_r.o_res ->> 'already_member')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'already_member debía ser false: %', v_r.o_res; END IF;
    IF v_r.o_res ->> 'account_id' IS DISTINCT FROM v_a::text THEN RAISE EXCEPTION 'faltó account_id (el invitado lo usa para cambiar de cuenta si ya es miembro)'; END IF;
    IF v_r.o_res ->> 'token' IS NOT NULL OR v_r.o_res::text ~* 'mu-c-invitee' THEN RAISE EXCEPTION 'la vista previa no puede devolver el token ni el email'; END IF;
    IF (SELECT status FROM public.account_invitations WHERE id = v_inv) <> 'pending' THEN RAISE EXCEPTION 'la vista previa NO consume la invitación'; END IF;

    -- OTRA identidad (W, con su sesión válida): el MISMO error que un token inexistente o vencido.
    SELECT * INTO v_r FROM pg_temp.run(v_w, (SELECT account_id FROM public.account_members WHERE user_id = v_w), pg_temp.e_preview(v_tok));
    PERFORM pg_temp.expect('otra identidad previsualiza', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    v_msg_other := v_r.o_msg;
    SELECT * INTO v_r FROM pg_temp.run(v_w, (SELECT account_id FROM public.account_members WHERE user_id = v_w), pg_temp.e_preview('token-que-no-existe'));
    v_msg_gen := v_r.o_msg;
    IF v_msg_other IS DISTINCT FROM v_msg_gen THEN
      RAISE EXCEPTION 'otra identidad e inexistente no son indistinguibles: "%" vs "%"', v_msg_other, v_msg_gen;
    END IF;
    -- Vencida: lo mismo.
    UPDATE public.account_invitations SET expires_at = now() - interval '1 minute' WHERE id = v_inv;
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_preview(v_tok));
    PERFORM pg_temp.expect('previsualizar una vencida', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    IF v_r.o_msg IS DISTINCT FROM v_msg_gen THEN RAISE EXCEPTION 'vencida e inexistente no son indistinguibles'; END IF;
    UPDATE public.account_invitations SET expires_at = now() + interval '7 days' WHERE id = v_inv;
    -- Sin sesión: P0401 (el anónimo nunca llega a la base: lo ve el frontend).
    SELECT * INTO v_r FROM pg_temp.run_anon(pg_temp.e_preview(v_tok));
    PERFORM pg_temp.expect('previsualizar sin sesión', v_r.o_state, v_r.o_msg, 'P0401');

    -- Ya es miembro: el dueño de A tiene una invitación a su propio email (la duplicada sólo mira las pendientes).
    UPDATE public.account_invitations SET email = 'mu-c-seller@test.local' WHERE id = v_inv2;
    SELECT token INTO v_tok2 FROM public.account_invitations WHERE id = v_inv2;
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_preview(v_tok2));
    PERFORM pg_temp.expect('un miembro previsualiza una invitación a su email', v_r.o_state, v_r.o_msg, 'ok');
    IF (v_r.o_res ->> 'already_member')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'already_member debía ser true: %', v_r.o_res; END IF;
    SELECT * INTO v_r FROM pg_temp.run(v_s, v_a, pg_temp.e_accept(v_tok2));
    PERFORM pg_temp.expect('aceptar siendo ya miembro', v_r.o_state, v_r.o_msg, 'P0409', 'already a member');
    RAISE NOTICE 'PASS (g): la identidad invitada ve negocio/invitador/roles/vencimiento (sin token ni email); otra identidad, vencida, inexistente y revocada = el MISMO error; sin sesión P0401; ya-miembro lo informa.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (h) aceptar: el negocio queda como cuenta activa ─────────────────────────
  v_blk := '(h) aceptar activa el negocio';
  BEGIN
    -- Estado de partida: I tiene sólo su cuenta personal y su preferencia está vacía.
    IF (SELECT active_account_id FROM public.profiles WHERE id = v_i) IS NOT NULL THEN
      RAISE EXCEPTION 'I debía partir sin cuenta activa persistida';
    END IF;
    -- Otra identidad no canjea el token (control: sigue funcionando el binding de email).
    SELECT * INTO v_r FROM pg_temp.run(v_w, (SELECT account_id FROM public.account_members WHERE user_id = v_w), pg_temp.e_accept(v_tok));
    PERFORM pg_temp.expect('otra identidad acepta', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');

    SELECT * INTO v_r FROM pg_temp.run(v_i, v_pi, pg_temp.e_accept(v_tok));
    PERFORM pg_temp.expect('I acepta', v_r.o_state, v_r.o_msg, 'ok');
    IF (v_r.o_res ->> 'account_id') IS DISTINCT FROM v_a::text THEN RAISE EXCEPTION 'la membresía debía ser de A: %', v_r.o_res; END IF;
    IF (v_r.o_res -> 'roles') IS DISTINCT FROM '["seller"]'::jsonb THEN RAISE EXCEPTION 'los roles otorgados debían ser [seller]: %', v_r.o_res; END IF;
    IF (SELECT status FROM public.account_invitations WHERE id = v_inv) <> 'accepted' THEN RAISE EXCEPTION 'la invitación debía quedar accepted'; END IF;
    -- EL PUNTO DE LA TANDA: la preferencia persistida pasa a ser el negocio…
    IF (SELECT active_account_id FROM public.profiles WHERE id = v_i) IS DISTINCT FROM v_a THEN
      RAISE EXCEPTION 'aceptar debía dejar profiles.active_account_id = A (%), es %', v_a, (SELECT active_account_id FROM public.profiles WHERE id = v_i);
    END IF;
    -- …y por eso el resolver (token sin claim) y el hook devuelven A.
    PERFORM pg_temp.as_user(v_i, NULL);
    IF public.resolve_active_account(v_i) IS DISTINCT FROM v_a THEN RAISE EXCEPTION 'resolve_active_account debía dar A tras aceptar'; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT string_agg(cai::text, ',') INTO v_txt FROM public.current_account_ids() AS cai;
    RESET ROLE;
    IF v_txt IS DISTINCT FROM v_a::text THEN RAISE EXCEPTION 'current_account_ids() sin claim debía dar sólo A, dio %', v_txt; END IF;
    -- La cuenta personal se CONSERVA (OQ-2 a) y el selector muestra las dos.
    IF NOT EXISTS (SELECT 1 FROM public.account_members WHERE account_id = v_pi AND user_id = v_i) THEN
      RAISE EXCEPTION 'la cuenta personal del invitado debía conservarse';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  v_blk := '(h2) el invitado ve dos cuentas y su primera venta cae en el negocio';
  BEGIN
    SELECT * INTO v_r FROM pg_temp.run_tbl(v_i, v_a, 'public.rpc_my_accounts()');
    PERFORM pg_temp.expect('rpc_my_accounts del invitado', v_r.o_state, v_r.o_msg, 'ok');
    IF jsonb_array_length(v_r.o_res) <> 2 THEN RAISE EXCEPTION 'el selector debía mostrar 2 cuentas, mostró %', jsonb_array_length(v_r.o_res); END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r.o_res) e WHERE e ->> 'account_id' = v_a::text AND (e ->> 'is_active')::boolean) THEN
      RAISE EXCEPTION 'la cuenta activa debía ser el negocio';
    END IF;
    -- Con el token renovado (claim = A) la venta de SERVICIO cae en el negocio, no en la personal (R3l).
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_a, format(
      'public.rpc_create_sale_operation(%L, NULL::uuid, %L::date, ''ARS'', %L::jsonb)',
      'gate-muc-h2-svc', public.reporting_local_today(), jsonb_build_array(jsonb_build_object('amount', 50, 'quantity', 1))::text));
    PERFORM pg_temp.expect('el invitado (vendedor) vende un servicio', v_r.o_state, v_r.o_msg, 'ok');
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = (v_r.o_res ->> 'operation_id')::uuid LIMIT 1;
    IF v_acc IS DISTINCT FROM v_a THEN RAISE EXCEPTION 'la primera venta del invitado debía quedar en el NEGOCIO (%), quedó en %', v_a, v_acc; END IF;
    -- Sin claim (token viejo): la preferencia persistida lo lleva igual al negocio.
    SELECT * INTO v_r FROM pg_temp.run(v_i, NULL, format(
      'public.rpc_create_sale_operation(%L, NULL::uuid, %L::date, ''ARS'', %L::jsonb)',
      'gate-muc-h2-svc-noclaim', public.reporting_local_today(), jsonb_build_array(jsonb_build_object('amount', 60, 'quantity', 1))::text));
    PERFORM pg_temp.expect('la venta de servicio sin claim', v_r.o_state, v_r.o_msg, 'ok');
    SELECT account_id INTO v_acc FROM public.sales WHERE operation_id = (v_r.o_res ->> 'operation_id')::uuid LIMIT 1;
    IF v_acc IS DISTINCT FROM v_a THEN RAISE EXCEPTION 'sin claim la venta debía seguir la preferencia (el negocio), quedó en %', v_acc; END IF;
    -- El token ya canjeado no se canjea dos veces.
    SELECT * INTO v_r FROM pg_temp.run(v_i, v_a, pg_temp.e_accept(v_tok));
    PERFORM pg_temp.expect('canjear dos veces el mismo token', v_r.o_state, v_r.o_msg, 'P0404', 'invalid or expired invitation token');
    RAISE NOTICE 'PASS (h): aceptar crea la membresía con los roles, deja profiles.active_account_id = A, la cuenta personal se conserva, el selector lista 2, la primera venta (con y sin claim) cae en el NEGOCIO; el token no se canjea dos veces.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (i) validación del email y "Not authenticated" = P0401 ───────────────────
  v_blk := '(i) email válido y P0401';
  BEGIN
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('esto-no-es-un-email', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('invitar a un email inválido', v_r.o_state, v_r.o_msg, 'P0400', 'invalid_email');
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('a@b' || E'\n' || 'c.com', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('invitar a un email con salto de línea', v_r.o_state, v_r.o_msg, 'P0400', 'invalid_email');
    SELECT * INTO v_r FROM pg_temp.run(v_o, v_a, pg_temp.e_invite('all_users', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('invitar a all_users', v_r.o_state, v_r.o_msg, 'P0400', 'invalid_email');
    -- "Not authenticated" deja de ser P0001 (candidato membership-rpcs-not-authenticated-p0401).
    SELECT * INTO v_r FROM pg_temp.run_anon(pg_temp.e_invite('mu-c-anon@test.local', v_a, ARRAY['viewer']));
    PERFORM pg_temp.expect('rpc_invite_member sin sesión', v_r.o_state, v_r.o_msg, 'P0401');
    SELECT * INTO v_r FROM pg_temp.run_anon(pg_temp.e_accept('lo-que-sea'));
    PERFORM pg_temp.expect('rpc_accept_invitation sin sesión', v_r.o_state, v_r.o_msg, 'P0401');
    RAISE NOTICE 'PASS (i): email inválido / con salto de línea / all_users = P0400; "Not authenticated" = P0401 en invitar y en aceptar.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
  END;

  -- ── (j) ESTRUCTURAL ──────────────────────────────────────────────────────────
  v_blk := '(j) estructura';
  BEGIN
    -- El overload de 2 argumentos se retiró (BREAKING interno, D14); queda UNA sola rpc_invite_member.
    IF to_regprocedure('public.rpc_invite_member(text,uuid)') IS NOT NULL THEN
      RAISE EXCEPTION 'rpc_invite_member(text, uuid) debía haberse retirado (D14)';
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_invite_member';
    IF v_n <> 1 THEN RAISE EXCEPTION 'rpc_invite_member debía tener UNA definición viva, tiene %', v_n; END IF;
    FOR v_r IN SELECT proname, count(*) AS n FROM pg_proc
                WHERE pronamespace = 'public'::regnamespace
                  AND proname IN ('rpc_send_invitation_email','rpc_list_account_invitations','rpc_revoke_invitation','rpc_invitation_preview','rpc_accept_invitation')
                GROUP BY proname HAVING count(*) <> 1
    LOOP
      RAISE EXCEPTION '% tiene % definiciones vivas', v_r.proname, v_r.n;
    END LOOP;
    IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
          AND proname IN ('rpc_send_invitation_email','rpc_list_account_invitations','rpc_revoke_invitation','rpc_invitation_preview')) <> 4 THEN
      RAISE EXCEPTION 'faltan funciones nuevas de la tanda C';
    END IF;

    -- CHECK de estado con `revoked` (ampliado por agregado al vivo).
    SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
     WHERE conname = 'account_invitations_status_values' AND conrelid = 'public.account_invitations'::regclass;
    IF v_def IS NULL OR v_def NOT LIKE '%revoked%' OR v_def NOT LIKE '%pending%' OR v_def NOT LIKE '%accepted%' OR v_def NOT LIKE '%expired%' THEN
      RAISE EXCEPTION 'el CHECK de estado debía admitir pending/accepted/expired/revoked: %', v_def;
    END IF;
    -- Columnas nuevas.
    IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_invitations'
          AND column_name IN ('account_display_name','revoked_at','revoked_by')) <> 3 THEN
      RAISE EXCEPTION 'faltan columnas nuevas en account_invitations (account_display_name, revoked_at, revoked_by)';
    END IF;

    -- ACLs: authenticated SÍ, anon y PUBLIC NUNCA, en las seis.
    FOR v_r IN
      SELECT p.oid, p.proname FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname IN ('rpc_invite_member','rpc_accept_invitation','rpc_send_invitation_email','rpc_list_account_invitations','rpc_revoke_invitation','rpc_invitation_preview')
    LOOP
      IF has_function_privilege('anon', v_r.oid, 'EXECUTE') OR NOT has_function_privilege('authenticated', v_r.oid, 'EXECUTE') THEN
        RAISE EXCEPTION '% tiene mal su ACL (anon=%, authenticated=%)', v_r.proname,
          has_function_privilege('anon', v_r.oid, 'EXECUTE'), has_function_privilege('authenticated', v_r.oid, 'EXECUTE');
      END IF;
      IF EXISTS (SELECT 1 FROM pg_proc q, aclexplode(COALESCE(q.proacl, acldefault('f', q.proowner))) a
                  WHERE q.oid = v_r.oid AND a.grantee = 0) THEN
        RAISE EXCEPTION '% tiene EXECUTE para PUBLIC', v_r.proname;
      END IF;
    END LOOP;

    -- COMMENT en las funciones nuevas.
    IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
                 AND p.proname IN ('rpc_send_invitation_email','rpc_list_account_invitations','rpc_revoke_invitation','rpc_invitation_preview')
                 AND obj_description(p.oid, 'pg_proc') IS NULL) THEN
      RAISE EXCEPTION 'las funciones nuevas deben llevar COMMENT';
    END IF;

    -- CANDADO DE CUERPO de rpc_send_invitation_email (comentarios removidos): guard de autoridad con el helper canónico
    -- ANTES de la primera escritura, lock de la fila, recipient y token de la FILA.
    SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_send_invitation_email';
    IF position('_account_assert_capability' IN v_def) = 0 OR position('FOR UPDATE' IN v_def) = 0
       OR position('INSERT INTO public.email_logs' IN v_def) = 0
       OR position('_account_assert_capability' IN v_def) > position('INSERT INTO public.email_logs' IN v_def)
       OR position('v_inv.email' IN v_def) = 0 THEN
      RAISE EXCEPTION 'rpc_send_invitation_email debe: bloquear la fila (FOR UPDATE), llamar a _account_assert_capability ANTES de escribir en email_logs y tomar el destinatario de v_inv.email';
    END IF;
    -- La aceptación activa la cuenta en la MISMA transacción.
    SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_accept_invitation';
    IF v_def !~* 'active_account_id' THEN RAISE EXCEPTION 'rpc_accept_invitation debe fijar profiles.active_account_id'; END IF;

    -- email_logs sigue CERRADA a la escritura de los usuarios (hotfix OQ-7): el envío sólo existe por la RPC DEFINER.
    PERFORM pg_temp.as_user(v_o, v_a::text);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      VALUES (v_o, 'org_invite', 'victima@example.com', 'Phishing', '{"token":"x"}'::jsonb);
      RESET ROLE;
      RAISE EXCEPTION 'un authenticated pudo INSERTAR en email_logs';
    EXCEPTION WHEN insufficient_privilege THEN
      RESET ROLE;   -- 42501 esperado
    END;

    RAISE NOTICE 'PASS (j): overload de 2 args retirado, una definición viva por función, CHECK con revoked, columnas nuevas, ACLs (sin anon ni PUBLIC), COMMENT, candado de cuerpo, email_logs cerrada.';
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail || format('%s %s [%s]', v_blk, SQLERRM, SQLSTATE);
    RAISE NOTICE 'FAIL %: % [%]', v_blk, SQLERRM, SQLSTATE;
    BEGIN RESET ROLE; EXCEPTION WHEN OTHERS THEN NULL; END;
  END;

  -- ── Veredicto ──────────────────────────────────────────────────────────────
  IF array_length(v_fail, 1) IS NOT NULL THEN
    RAISE EXCEPTION E'GATE MULTIUSUARIO-INVITACIONES FAILED en % bloque(s):\n  - %', array_length(v_fail, 1), array_to_string(v_fail, E'\n  - ');
  END IF;
  RAISE NOTICE 'GATE MULTIUSUARIO-INVITACIONES OK: la invitación se envía, se reenvía con token nuevo, se revoca y se lista; la vista previa está ligada a la identidad; aceptar activa el negocio (a-j).';
END
$gate$;

ROLLBACK;
