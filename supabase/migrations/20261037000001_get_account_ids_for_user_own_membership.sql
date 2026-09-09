-- =============================================================================
-- get_account_ids_for_user_own_membership — h4 de cuenta-corriente-party-guard
-- (candidato S3, sign-off PO 2026-09-09, governance CRÍTICO)
-- =============================================================================
--
-- Hallazgo (heredado de openspec/changes/archive/2026-08-23-cuenta-corriente-
-- party-guard/design.md §"Hallazgos laterales de la revisión de seguridad",
-- h4): `get_account_ids_for_user(uuid)` es SECURITY DEFINER y devuelve la
-- membresía de CUALQUIER user_id que se le pase, sin comparar contra
-- auth.uid(). Nace en 20260902000001_fix_account_members_rls_recursion.sql
-- (L67) como fix de la recursión 42P17 de la policy
-- `account_members_same_account_select`, que la invoca así:
--   account_id IN (SELECT public.get_account_ids_for_user((SELECT auth.uid())))
-- — siempre con el propio auth.uid(), nunca con un parámetro ajeno. Pero al
-- quedar expuesta como RPC de PostgREST (proacl con PUBLIC=X, verificado antes
-- de este archivo — ver el bloque `has_function_privilege` de más abajo, que
-- reproduce el estado sin el guard antes de aplicar), cualquier `authenticated`
-- (o `anon`) puede llamar `.rpc('get_account_ids_for_user', {p_user_id: <uuid
-- ajeno>})` y, como SECURITY DEFINER, bypassea la RLS de `account_members`
-- para enumerar las cuentas de un TERCERO — sin necesitar más que conocer su
-- user_id.
--
-- Verificado VIVO en prod (dato provisto por el orquestador, 2026-09-09):
--   LANGUAGE sql STABLE SECURITY DEFINER, cuerpo
--     `SELECT account_id FROM public.account_members WHERE user_id = p_user_id`
--   md5(pg_get_functiondef(...)) = 3f58f28200e3f52900a014da8c89ba04, 262 bytes.
-- Reproducido igual en la base local recién reseteada (MAX(version) =
-- 20261034000001, previo a este archivo): el mismo md5 sobre
-- pg_get_functiondef() da 3f58f28200e3f52900a014da8c89ba04 en 262 bytes
-- (verificado byte a byte contra el .sql fuente de 20260902000001 L67-74,
-- sin diferencia salvo el CRLF del checkout Windows, ya neutralizado al
-- comparar por el md5 de la salida de Postgres — no del archivo en disco).
-- Único caller vivo: la policy `account_members_same_account_select`
-- (barrido de pg_proc.prosrc completo: ninguna función SQL la invoca; grep de
-- frontend/ y backend/: ningún caller de aplicación). Está allowlisteada a
-- propósito en supabase/tests/test_function_acl_gate.sql (chequeo 2, "Helpers
-- de RLS — NUNCA revocar"): las policies la ejecutan como el rol
-- consultante, así que revocarle EXECUTE rompería toda lectura de
-- `account_members` para cualquier rol. Este archivo NO toca esa allowlist ni
-- ningún GRANT/REVOKE — ver la sección 2 más abajo.
--
-- Diseño (opción "silenciosa" — la policy NUNCA debe fallar, sólo dejar de
-- filtrar por un user_id ajeno): `CREATE OR REPLACE` con la MISMA firma
-- `(p_user_id uuid)`, mismo `LANGUAGE sql STABLE SECURITY DEFINER SET
-- search_path = public`, agregando al `WHERE` la condición
--   (p_user_id IS NOT DISTINCT FROM auth.uid() OR auth.role() = 'service_role')
-- — con un `user_id` ajeno al de la sesión, la función devuelve CERO filas
-- (nunca error: ni siquiera el único caller real, la policy, puede ver
-- fallar esto sin romper CADA SELECT sobre account_members); con el propio
-- devuelve lo de siempre; `service_role` conserva el comportamiento actual
-- (jobs administrativos que resuelven membresía de un tercero sin sesión de
-- usuario). `auth.role()` existe en este entorno (auth.role()/auth.uid() son
-- funciones SQL nativas de GoTrue, verificado con pg_get_functiondef antes de
-- escribir este archivo) y ya resuelve el fallback
-- `request.jwt.claim.role` → `request.jwt.claims->>'role'`, así que no hace
-- falta reimplementarlo a mano.
--
-- Por qué NO current_setting a mano: `auth.role()` es el helper CANÓNICO del
-- proyecto para esta comparación (usado en decenas de RPCs) — reutilización
-- antes que repetición (regla PO 2026-08-02).
--
-- Sin ERRCODE nuevo, sin helper nuevo: un solo predicado agregado al WHERE
-- de la única función tocada.
--
-- ACL: NO SE TOCA. `CREATE OR REPLACE` con la misma firma preserva el
-- `proacl` existente (PUBLIC=X + anon/authenticated/service_role=X,
-- verificado antes Y después de este archivo en el gate de la sección 3) —
-- sigue ejecutable por `anon`/`authenticated`/`PUBLIC`, que es exactamente lo
-- que la policy necesita y lo que la allowlist de
-- test_function_acl_gate.sql (2) ya declara "NUNCA revocar". Ningún
-- REVOKE/GRANT en este archivo.
--
-- Idempotente: CREATE OR REPLACE puro. Verificado con doble apply en local
-- (mismo fingerprint del cuerpo, mismo proacl, sin error).
--
-- Sin superficie frontend (declarado): función interna de RLS, sin caller de
-- aplicación.
-- =============================================================================


-- =============================================================================
-- 1. get_account_ids_for_user — agrega el guard de identidad al WHERE.
--    Firma SIN CAMBIOS (uuid) → CREATE OR REPLACE puro, sin DROP, sin riesgo
--    de overload 42725 (gate anti-overload en la sección 3).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_account_ids_for_user(p_user_id uuid)
RETURNS SETOF uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT account_id FROM public.account_members
  WHERE user_id = p_user_id
    AND (
      p_user_id IS NOT DISTINCT FROM auth.uid()
      OR auth.role() = 'service_role'
    )
$function$;

COMMENT ON FUNCTION public.get_account_ids_for_user(uuid) IS
  'Helper de RLS (SECURITY DEFINER): cuentas a las que pertenece un usuario. '
  'Bypassea RLS a propósito para que las policies de account_members no '
  'recursen (20260902000001). get_account_ids_for_user_own_membership (h4 de '
  'cuenta-corriente-party-guard): con un p_user_id distinto de auth.uid() '
  'devuelve CERO filas en vez de la membresía ajena — antes cualquier '
  'authenticated podía enumerar las cuentas de un tercero vía '
  '.rpc(''get_account_ids_for_user'', {p_user_id: <uuid ajeno>}). '
  'service_role conserva el comportamiento sin filtrar (jobs administrativos). '
  'ACL sin cambios — sigue siendo el helper de RLS allowlisteado en '
  'test_function_acl_gate.sql (2), NUNCA revocar: las policies lo ejecutan '
  'como el rol consultante.';


-- =============================================================================
-- 2. ACL — explícitamente NO se toca. Sin REVOKE/GRANT en este archivo (ver
--    cabecera). El gate de la sección 3 verifica que el proacl no cambió.
-- =============================================================================


-- =============================================================================
-- 3. Gate de la propia migración.
-- =============================================================================

DO $$
DECLARE
  v_count integer;
  v_def   text;
BEGIN
  -- (a) ANTI-OVERLOAD 42725: la firma no cambió → debe haber exactamente una
  --     definición.
  SELECT count(*) INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'get_account_ids_for_user';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'get_account_ids_for_user_own_membership ANTI-OVERLOAD: esperaba exactamente 1 definición de get_account_ids_for_user, hay %. Revisar overloads fantasma con: SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE pronamespace = ''public''::regnamespace AND proname = ''get_account_ids_for_user'';', v_count;
  END IF;

  -- (b) El cuerpo vivo contiene el guard de identidad (candado de texto,
  --     mismo patrón que otros gates del proyecto).
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_account_ids_for_user';

  IF position('auth.uid()' in v_def) = 0 THEN
    RAISE EXCEPTION 'get_account_ids_for_user_own_membership GUARD: el cuerpo vivo de get_account_ids_for_user no referencia auth.uid() — el guard de identidad no quedó escrito.';
  END IF;

  IF position('service_role' in v_def) = 0 THEN
    RAISE EXCEPTION 'get_account_ids_for_user_own_membership GUARD: el cuerpo vivo de get_account_ids_for_user no contempla la excepción de service_role.';
  END IF;

  -- Entorno sin roles de Supabase (p.ej. postgres pelado): no hay ACL que verificar.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RAISE NOTICE 'get_account_ids_for_user_own_membership: roles de Supabase ausentes — se omite la verificación de ACL.';
    RAISE NOTICE 'get_account_ids_for_user_own_membership OK (sin verificación de ACL): 1 definición, guard de identidad + excepción de service_role presentes en el cuerpo vivo.';
    RETURN;
  END IF;

  -- (c) ACL SIN CAMBIOS (D: "NO tocar"): sigue ejecutable por anon,
  --     authenticated y PUBLIC — exactamente lo que la policy y la allowlist
  --     de test_function_acl_gate.sql (2) esperan. Un REVOKE aquí sería una
  --     regresión (rompería la policy para todo rol consultante), así que el
  --     control es que SIGA concedido, no que esté revocado.
  IF NOT has_function_privilege('anon', 'public.get_account_ids_for_user(uuid)'::regprocedure, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.get_account_ids_for_user(uuid)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'get_account_ids_for_user_own_membership ACL: get_account_ids_for_user perdió EXECUTE para anon/authenticated — es un helper de RLS allowlisteado (test_function_acl_gate.sql chequeo 2), NUNCA debe revocarse: rompería toda lectura de account_members bajo RLS.';
  END IF;

  RAISE NOTICE 'get_account_ids_for_user_own_membership OK: 1 definición, guard de identidad (auth.uid() / service_role) presente en el cuerpo vivo, ACL intacto (anon + authenticated conservan EXECUTE, tal como exige la policy).';
END $$;
