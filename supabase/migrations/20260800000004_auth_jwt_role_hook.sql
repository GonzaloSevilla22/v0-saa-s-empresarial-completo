-- =============================================================================
-- MIGRATION: 20260800000004_auth_jwt_role_hook.sql
-- OPCIÓN B (follow-up del fix fiscal): Custom Access Token Hook
--
-- QUÉ HACE:
--   Define el hook `public.custom_access_token_hook(event jsonb)` que copia
--   `profiles.role` (rol de PLATAFORMA) al claim `app_metadata.role` del JWT.
--   Hoy ese claim NUNCA se setea (no hay hook) y por eso `core/auth.py` cae al
--   fallback `"user"`, lo que rompía `require_role(["admin"])` (ver fix Opción A:
--   require_platform_admin). Con este hook, `auth["role"]` refleja el rol real y
--   los guards basados en JWT vuelven a ser correctos.
--
-- ⚠️ DORMIDO POR DEFECTO — esta migración SOLO define la función y permisos.
--   El hook NO se activa hasta habilitarlo explícitamente en producción:
--     Supabase Dashboard → Authentication → Hooks (Beta) → Customize Access Token
--     → pg-functions://postgres/public/custom_access_token_hook
--   (config.toml solo afecta el entorno LOCAL `supabase start`).
--
--   Tras activarlo, los JWT existentes mantienen el claim viejo hasta el próximo
--   refresh (~1h) o re-login. Sin activarlo, no cambia absolutamente nada.
--
-- SEGURIDAD: el hook corre en CADA emisión de token. Está blindado con
--   EXCEPTION WHEN OTHERS → ante cualquier error devuelve los claims sin tocar,
--   para que un fallo nunca rompa el login.
--
-- GOVERNANCE: CRÍTICO (auth global). Activación = acción deliberada del PO.
-- APPLY: npx supabase db push (automático en el merge a main). Es seguro: la
--   función queda inerte hasta que se habilite el hook en el dashboard.
--
-- ROLLBACK:
--   1) Deshabilitar el hook en el dashboard (vuelve al comportamiento actual).
--   2) DROP FUNCTION IF EXISTS public.custom_access_token_hook(jsonb);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_claims jsonb := COALESCE(event -> 'claims', '{}'::jsonb);
  v_role   text;
BEGIN
  SELECT role INTO v_role
  FROM   public.profiles
  WHERE  id = (event ->> 'user_id')::uuid;

  IF v_role IS NOT NULL THEN
    -- Setea app_metadata.role preservando las demás claves de app_metadata.
    IF v_claims ? 'app_metadata' THEN
      v_claims := jsonb_set(v_claims, '{app_metadata,role}', to_jsonb(v_role), true);
    ELSE
      v_claims := jsonb_set(v_claims, '{app_metadata}', jsonb_build_object('role', v_role), true);
    END IF;
  END IF;

  RETURN jsonb_build_object('claims', v_claims);
EXCEPTION
  WHEN OTHERS THEN
    -- Nunca romper la emisión del token: ante cualquier error, claims intactos.
    RETURN jsonb_build_object('claims', COALESCE(event -> 'claims', '{}'::jsonb));
END;
$$;

-- El hook se ejecuta como el rol `supabase_auth_admin`.
GRANT  EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) FROM authenticated, anon, public;

-- supabase_auth_admin necesita leer profiles.role (profiles tiene RLS activa).
GRANT SELECT ON TABLE public.profiles TO supabase_auth_admin;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'profiles'
      AND policyname = 'auth_admin_can_read_roles'
  ) THEN
    CREATE POLICY "auth_admin_can_read_roles" ON public.profiles
      AS PERMISSIVE FOR SELECT TO supabase_auth_admin
      USING (true);
  END IF;
END $$;


-- =============================================================================
-- TEST (post-apply, antes de activar el hook en el dashboard):
--   SELECT public.custom_access_token_hook(jsonb_build_object(
--     'user_id', (SELECT id FROM auth.users WHERE email='admin@eie.com'),
--     'claims',  jsonb_build_object('app_metadata', jsonb_build_object('provider','email'))
--   ));
--   Esperado: claims.app_metadata.role = 'admin'
-- =============================================================================
-- END OF MIGRATION 20260800000004_auth_jwt_role_hook.sql
-- =============================================================================
