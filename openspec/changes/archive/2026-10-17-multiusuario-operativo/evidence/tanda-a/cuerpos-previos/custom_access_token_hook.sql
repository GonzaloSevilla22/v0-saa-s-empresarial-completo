CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_claims        jsonb := COALESCE(event -> 'claims', '{}'::jsonb);
  v_user_id       uuid  := (event ->> 'user_id')::uuid;
  v_role          text;
  v_account_id    uuid;
  v_member_id     uuid;
  v_account_role  text;
  v_account_roles text[];
  v_plan          text;
  v_app_metadata  jsonb;
BEGIN
  -- Rol de PLATAFORMA (D1) — sin cambio semántico respecto de 20260800000004.
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = v_user_id;

  -- Rol de TENANT (D1) + cuenta activa determinística (D4): la membresía más
  -- antigua, desempatada por PK — MISMO criterio que
  -- backend/core/deps.py::get_account_id tras este change.
  SELECT id, account_id, role INTO v_member_id, v_account_id, v_account_role
  FROM public.account_members
  WHERE user_id = v_user_id
  ORDER BY created_at, id
  LIMIT 1;

  -- v3-rbac-multirole Parte B (D8): el CONJUNTO de roles ACTIVOS del mismo
  -- member_id ya resuelto arriba — vencidos excluidos por member_active_roles
  -- (D4 de la Parte A, reutilizado, nunca un segundo "rol activo"). NULL
  -- (no [] fabricado) si no se resolvió ningún member_id — distinto de "sin
  -- roles activos" (member_id resuelto, array vacío real).
  IF v_member_id IS NOT NULL THEN
    v_account_roles := public.member_active_roles(v_member_id);
  END IF;

  -- Plan EFECTIVO (D3) — delegado a la definición normativa única. Sin cuenta
  -- activa no hay plan que emitir (no se inventa un default acá).
  IF v_account_id IS NOT NULL THEN
    v_plan := public.get_effective_plan(v_account_id);
  END IF;

  -- Merge aditivo sobre app_metadata existente: preserva otras claves que
  -- Supabase ya haya puesto (p.ej. provider), y cada claim nuevo se agrega
  -- SOLO si se resolvió — un valor NULL no pisa nada.
  v_app_metadata := COALESCE(v_claims -> 'app_metadata', '{}'::jsonb);

  IF v_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('role', v_role);
  END IF;

  IF v_account_role IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_role', v_account_role);
  END IF;

  IF v_account_roles IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('account_roles', to_jsonb(v_account_roles));
  END IF;

  IF v_plan IS NOT NULL THEN
    v_app_metadata := v_app_metadata || jsonb_build_object('plan', v_plan);
  END IF;

  -- Solo tocar `claims.app_metadata` si hay algo nuevo que aportar o si YA
  -- existía (para no fabricar una clave `app_metadata: {}` en un evento que
  -- nunca la tuvo — un usuario sin profile ni membresía debe devolver los
  -- claims EXACTAMENTE como llegaron, sin ninguna clave nueva).
  IF v_app_metadata <> '{}'::jsonb OR v_claims ? 'app_metadata' THEN
    v_claims := jsonb_set(v_claims, '{app_metadata}', v_app_metadata, true);
  END IF;

  RETURN jsonb_build_object('claims', v_claims);
EXCEPTION
  WHEN OTHERS THEN
    -- Nunca romper la emisión del token: ante cualquier error (incluido un
    -- permiso faltante sobre member_active_roles, D8/D5), claims intactos.
    -- Deja rastro (D5 de v31-authz-token-hook): un permiso faltante o un
    -- cambio de esquema queda en los logs de Postgres, no como claims
    -- ausentes sin explicación.
    RAISE WARNING 'custom_access_token_hook degradado (SQLSTATE=%): %', SQLSTATE, SQLERRM;
    RETURN jsonb_build_object('claims', COALESCE(event -> 'claims', '{}'::jsonb));
END;
$function$

-- ACL: {postgres=X/postgres,service_role=X/postgres,supabase_auth_admin=X/postgres}
-- COMMENT: v3-rbac-multirole Parte B (D8): emite account_roles (CONJUNTO de roles ACTIVOS, vencidos excluidos) DENTRO del bloque protegido EXCEPTION WHEN OTHERS heredado de v31-authz-token-hook -- account_role (singular, derivado por precedencia) se conserva IDÉNTICO. Ante cualquier error, claims intactos + RAISE WARNING (nunca rompe el login).
