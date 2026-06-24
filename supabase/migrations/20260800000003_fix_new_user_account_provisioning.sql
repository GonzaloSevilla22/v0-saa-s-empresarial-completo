-- =============================================================================
-- MIGRATION: 20260800000003_fix_new_user_account_provisioning.sql
-- BUG FIX:   Signups posteriores al backfill C-05 quedaban SIN tenant.
--
-- SÍNTOMA (reportado por PO, 2026-06-24):
--   El usuario que CREA su empresa no puede crear operaciones (ventas, etc.).
--   La UI muestra "Solo lectura — contactá al owner para crear operaciones" o el
--   backend responde 403 "No active account found" (core/deps.py:get_account_id).
--
-- CAUSA RAÍZ:
--   El modelo de tenant (C-05) creó accounts + account_members (role='owner')
--   para todos los profiles EXISTENTES vía dos backfills de UNA sola vez
--   (20260606000002_tenant_backfill + 20260613000003_v20_companies_to_accounts).
--   Pero el trigger handle_new_user (que corre en CADA signup) solo inserta el
--   profile + los emails — NUNCA crea la cuenta ni la membresía. Por eso todo
--   usuario registrado DESPUÉS del backfill queda huérfano: profiles SÍ, pero
--   accounts/account_members NO. Confirmado en prod: 2 profiles sin tenant
--   (solruizherrada@gmail.com 2026-06-11, lijavo4037@synsky.com 2026-06-18).
--
-- FIX (dos partes, idempotentes):
--   A) Backfill de los huérfanos actuales → cuenta + membresía owner.
--   B) Extender handle_new_user para provisionar el tenant en cada signup nuevo,
--      preservando intacto lo que ya hacía (perfil + mail bienvenida + aviso admin).
--
-- GOVERNANCE: CRÍTICO — toca el path de signup (auth) y crea tenancy. PO firmó
--   el fix 2026-06-24.
--
-- APPLY: npx supabase db push   (NUNCA el MCP apply_migration — regla dura del proyecto)
--
-- ROLLBACK (no recomendado — dejaría signups nuevos sin tenant de nuevo):
--   Restaurar handle_new_user a la versión de
--   20260628000002_new_user_admin_notice.sql. El backfill (parte A) no se revierte.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE A — Backfill de profiles huérfanos (sin account / sin membership)
-- Mismo patrón idempotente que 20260606000002_tenant_backfill.sql.
-- Desbloquea a los usuarios ya registrados que no pueden operar HOY.
-- ─────────────────────────────────────────────────────────────────────────────

-- A.1  Una cuenta por cada profile que aún no tenga una (espeja el billing del profile).
INSERT INTO public.accounts (
  id, owner_user_id, billing_plan, billing_status,
  trial_plan, trial_started_at, trial_expires_at, created_at
)
SELECT
  gen_random_uuid(), p.id, p.billing_plan, p.billing_status,
  p.trial_plan, p.trial_started_at, p.trial_expires_at, p.created_at
FROM public.profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM public.accounts a WHERE a.owner_user_id = p.id
);

-- A.2  Registrar al owner como miembro 'owner' de su propia cuenta.
INSERT INTO public.account_members (account_id, user_id, role)
SELECT a.id, a.owner_user_id, 'owner'
FROM public.accounts a
ON CONFLICT (account_id, user_id) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE B — handle_new_user: provisionar tenant en cada signup nuevo
-- Base: versión deployada (20260628000002_new_user_admin_notice.sql).
-- SOLO se agrega el bloque (2): cuenta + membresía owner. El resto queda igual.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  user_name     text;
  user_phone    text;
  user_locality text;
  v_account_id  uuid;
BEGIN
  user_name     := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), '');
  user_phone    := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), '');
  user_locality := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), '');

  -- 1) Perfil
  INSERT INTO public.profiles (id, name, phone, locality, role)
  VALUES (new.id, user_name, user_phone, user_locality, 'user');

  -- 2) Tenant: cuenta propia + membresía como OWNER.
  --    Sin esto el signup queda huérfano y no puede crear operaciones (el bug).
  --    El nuevo usuario es el OWNER (admin) de su propia empresa.
  INSERT INTO public.accounts (
    owner_user_id, billing_plan, billing_status,
    trial_plan, trial_started_at, trial_expires_at
  )
  SELECT new.id, p.billing_plan, p.billing_status,
         p.trial_plan, p.trial_started_at, p.trial_expires_at
  FROM   public.profiles p
  WHERE  p.id = new.id
  RETURNING id INTO v_account_id;

  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_id, new.id, 'owner')
  ON CONFLICT (account_id, user_id) DO NOTHING;

  -- 3) Mail de bienvenida al usuario nuevo
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', COALESCE(user_name, 'Emprendedor'))
  );

  -- 4) Aviso al administrador con los datos del registro
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'new_user_admin_notice',
    'danielsevilla@alia-data.com',
    'Nuevo registro en ALIADATA',
    jsonb_build_object(
      'name',     COALESCE(user_name, 'Sin nombre'),
      'email',    new.email,
      'phone',    COALESCE(user_phone, '-'),
      'locality', COALESCE(user_locality, '-')
    )
  );

  RETURN new;
END;
$function$;


-- =============================================================================
-- TEST ASSERTIONS (correr DESPUÉS de aplicar)
--
-- T1: ya no hay profiles sin tenant
--   SELECT count(*) FROM public.profiles p
--   WHERE NOT EXISTS (SELECT 1 FROM public.account_members am WHERE am.user_id = p.id);
--   Esperado: 0
--
-- T2: todos los nuevos quedan como owner
--   SELECT role, count(*) FROM public.account_members GROUP BY role;
--   Esperado: solo 'owner' (más los que ya existieran)
--
-- T3 (manual): registrar un usuario de prueba y verificar que get_account_id
--   no devuelve 403 y que puede crear una venta.
-- =============================================================================
-- END OF MIGRATION 20260800000003_fix_new_user_account_provisioning.sql
-- =============================================================================
