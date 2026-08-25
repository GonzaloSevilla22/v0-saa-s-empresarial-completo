-- =============================================================================
-- GATE: test_errcode_5char_gate.sql
-- CHANGE: limpiezas-pagos-admin (G3, tasks 2.1 RED / 2.2 RED-triangulate)
--
-- Gate PERMANENTE (D5 de design.md): la corrección de 2026-06-24
-- (20260624000001_fix_invalid_errcodes_5char.sql) se perdió porque nada la
-- sostenía — cada RPC nueva volvió a copiar el patrón inválido de 4
-- caracteres. Este gate falla el pipeline si CUALQUIER función viva de
-- public/community (no los archivos de migración) usa un ERRCODE custom de
-- menos de 5 caracteres.
--
-- Verifica:
--   (1) Estático: ninguna función de public/community tiene
--       `ERRCODE = '<1-4 chars>'` en su prosrc — nombra función y código si
--       falla.
--   (2) Comportamiento (triangulación): un RAISE real que antes del fix
--       llegaba como 42704 unrecognized_exception (mensaje perdido) ahora
--       llega con el SQLSTATE P04xx correcto y el mensaje original —
--       ejercitado sobre rpc_product_profitability (branch P403→P0403,
--       "Usuario sin cuenta activa").
-- =============================================================================

-- ── (1) Estático: cero ERRCODEs custom de 1-4 caracteres ────────────────────
DO $$
DECLARE
  v_offenders text;
BEGIN
  SELECT string_agg(
    format('%s: %s', p.proname, m[1]), E'\n  '
  )
  INTO v_offenders
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace,
  LATERAL regexp_matches(p.prosrc, 'ERRCODE\s*=\s*''([A-Za-z0-9]{1,4})''', 'g') AS m
  WHERE n.nspname IN ('public', 'community');

  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION E'GATE ERRCODE-5CHAR FAILED (1): funciones con ERRCODE custom de menos de 5 caracteres (Postgres los rechaza en runtime con 42704, perdiendo el mensaje):\n  %', v_offenders;
  END IF;

  RAISE NOTICE 'PASS (1): ninguna función de public/community tiene un ERRCODE custom de menos de 5 caracteres.';
END $$;


-- ── (2) Comportamiento: el RAISE real llega con SQLSTATE y mensaje correctos ─
DO $$
DECLARE
  v_anchor_email text := 'errcode-5char-gate@test.local';
  v_user_id      uuid := gen_random_uuid();
  v_sqlstate     text;
  v_message      text;
  v_resolved     boolean := false;
BEGIN
  -- Anchor SIN cuenta (no account_members): dispara la rama
  -- "Usuario sin cuenta activa" de rpc_product_profitability, que antes del
  -- fix lanzaba ERRCODE='P403' (4 chars → 42704 en runtime, mensaje
  -- perdido) y después del fix lanza 'P0403' con el mensaje intacto.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate ERRCODE 5char'))
  ON CONFLICT (id) DO NOTHING;

  -- handle_new_user() aprovisiona cuenta+membresía automáticamente al
  -- insertar en auth.users (trigger). Se retira la membresía a propósito
  -- para forzar la rama "Usuario sin cuenta activa" que dispara el ERRCODE
  -- bajo prueba — current_account_ids() la resuelve por account_members.
  DELETE FROM public.account_members WHERE user_id = v_user_id;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE ERRCODE-5CHAR: auth.uid() no resuelve al anchor con request.jwt.claims local — se omite el caso (2), degradando sin abortar.';
  ELSE
    v_resolved := true;

    BEGIN
      PERFORM public.rpc_product_profitability(30);
    EXCEPTION
      WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    END;

    IF v_sqlstate IS DISTINCT FROM 'P0403' THEN
      RAISE EXCEPTION 'GATE ERRCODE-5CHAR FAILED (2): esperaba SQLSTATE P0403 (Usuario sin cuenta activa), recibido % (mensaje: %). Si es 42704, el fix no se aplicó.',
        v_sqlstate, v_message;
    END IF;

    IF v_message NOT LIKE '%Usuario sin cuenta activa%' THEN
      RAISE EXCEPTION 'GATE ERRCODE-5CHAR FAILED (2b): el mensaje original debería preservarse ("Usuario sin cuenta activa"), llegó: %', v_message;
    END IF;

    RAISE NOTICE 'PASS (2): rpc_product_profitability sin cuenta llega con SQLSTATE=P0403 y el mensaje original intacto (no 42704).';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  DELETE FROM public.email_logs WHERE user_id = v_user_id;
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts   WHERE owner_user_id = v_user_id;
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles   WHERE id = v_user_id;
  DELETE FROM auth.users        WHERE id = v_user_id;

  IF v_resolved THEN
    RAISE NOTICE 'GATE ERRCODE-5CHAR PASSED.';
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      DELETE FROM public.email_logs WHERE user_id = v_user_id;
      -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
      SET session_replication_role = replica;
      DELETE FROM public.accounts   WHERE owner_user_id = v_user_id;
      SET session_replication_role = DEFAULT;
      DELETE FROM public.profiles   WHERE id = v_user_id;
      DELETE FROM auth.users        WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
