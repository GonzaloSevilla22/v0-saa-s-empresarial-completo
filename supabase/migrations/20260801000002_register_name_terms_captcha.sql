-- =============================================================================
-- MIGRATION: 20260801000002_register_name_terms_captcha.sql
-- CHANGE:    register-name-terms-captcha (Fase 7 — alta con apellido + consentimiento)
--
-- QUÉ HACE (todo aditivo, sin BREAKING):
--   A) profiles: 3 columnas nuevas para el consentimiento legal y el opt-in de email.
--   B) handle_new_user: copia last_name + los 3 campos de consentimiento desde
--      raw_user_meta_data al crear el perfil, PRESERVANDO byte-por-byte el bloque
--      de tenant (accounts + account_members) y los emails (bienvenida + aviso admin).
--      Base EXACTA: 20260800000003_fix_new_user_account_provisioning.sql.
--   C) El aviso al admin (new_user_admin_notice) ahora incluye apellido / nombre completo.
--
-- SIN BACKFILL: usuarios existentes conservan last_name NULL, terms_* NULL y
--   email_notifications_opt_in = false (default). La obligatoriedad del apellido y
--   los términos se aplica en el ALTA (frontend), no retroactivamente.
--
-- GOVERNANCE: CRÍTICO — toca el path de signup (auth). El bloque de tenant/emails
--   NO se modifica. **Aplicación a PROD pendiente de aprobación explícita del PO.**
--
-- APPLY: npx supabase db push   (NUNCA el MCP apply_migration — regla dura del proyecto)
--        siempre al proyecto real gxdhpxvdjjkmxhdkkwyb.
--
-- ROLLBACK: la migración es aditiva. Restaurar handle_new_user a la versión de
--   20260800000003 revierte el comportamiento del trigger sin tocar datos. Las
--   columnas nuevas pueden quedar inertes o dropearse aparte.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE A — profiles: columnas aditivas de consentimiento + opt-in
-- (profiles.last_name ya existe desde 20260510000001_extend_profiles.sql)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS terms_accepted_at         timestamptz,
  ADD COLUMN IF NOT EXISTS terms_version             text,
  ADD COLUMN IF NOT EXISTS email_notifications_opt_in boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.profiles.terms_accepted_at IS
  'Momento de aceptación de los Términos (lo setea handle_new_user con la hora del signup). NULL para usuarios previos al change.';
COMMENT ON COLUMN public.profiles.terms_version IS
  'Versión de Términos aceptada en el alta (constante TERMS_VERSION del frontend). NULL para usuarios previos.';
COMMENT ON COLUMN public.profiles.email_notifications_opt_in IS
  'Opt-in explícito a comunicaciones por email. Default false: nadie queda suscripto por accidente.';


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE B — handle_new_user: copiar last_name + consentimiento desde el metadata
-- Base EXACTA: 20260800000003. ÚNICOS cambios respecto de esa versión:
--   • 4 variables nuevas (user_last_name, user_terms_version, user_email_optin, v_terms_accepted_at)
--   • el INSERT de profiles incluye last_name + las 3 columnas nuevas
--   • el metadata del aviso admin incluye apellido / nombre completo
-- El bloque (2) de tenant y los emails NO cambian su lógica.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  user_name          text;
  user_last_name     text;
  user_phone         text;
  user_locality      text;
  user_terms_version text;
  user_email_optin   boolean;
  v_terms_accepted_at timestamptz;
  v_account_id       uuid;
BEGIN
  user_name          := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), '');
  user_last_name     := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'last_name', '')), '');
  user_phone         := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), '');
  user_locality      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), '');
  user_terms_version := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'terms_version', '')), '');
  -- El front manda un booleano JSON; si falta, default false (nadie queda suscripto solo).
  user_email_optin   := COALESCE((new.raw_user_meta_data->>'email_notifications_opt_in')::boolean, false);
  -- Sello de consentimiento: la hora del signup, solo si vino una versión de términos.
  v_terms_accepted_at := CASE WHEN user_terms_version IS NOT NULL THEN now() ELSE NULL END;

  -- 1) Perfil (ahora también last_name + consentimiento + opt-in)
  INSERT INTO public.profiles (
    id, name, last_name, phone, locality, role,
    terms_accepted_at, terms_version, email_notifications_opt_in
  )
  VALUES (
    new.id, user_name, user_last_name, user_phone, user_locality, 'user',
    v_terms_accepted_at, user_terms_version, user_email_optin
  );

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

  -- 4) Aviso al administrador con los datos del registro (ahora con apellido / nombre completo)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'new_user_admin_notice',
    'danielsevilla@alia-data.com',
    'Nuevo registro en ALIADATA',
    jsonb_build_object(
      'name',      COALESCE(user_name, 'Sin nombre'),
      'last_name', COALESCE(user_last_name, '-'),
      'full_name', NULLIF(TRIM(COALESCE(user_name, '') || ' ' || COALESCE(user_last_name, '')), ''),
      'email',     new.email,
      'phone',     COALESCE(user_phone, '-'),
      'locality',  COALESCE(user_locality, '-')
    )
  );

  RETURN new;
END;
$function$;


-- =============================================================================
-- TEST ASSERTIONS (correr DESPUÉS de aplicar — espejo de T1/T2 de 20260800000003)
--
-- T1: ya no hay profiles sin tenant (el bloque de provisioning quedó intacto)
--   SELECT count(*) FROM public.profiles p
--   WHERE NOT EXISTS (SELECT 1 FROM public.account_members am WHERE am.user_id = p.id);
--   Esperado: 0
--
-- T2: todos los miembros nuevos quedan como owner
--   SELECT role, count(*) FROM public.account_members GROUP BY role;
--   Esperado: solo 'owner' (más los que ya existieran)
--
-- T3: copiado de los campos nuevos en el alta (registrar un usuario de prueba con
--     last_name / terms_version / email_notifications_opt_in en el metadata del signUp)
--   SELECT name, last_name, terms_version, terms_accepted_at IS NOT NULL AS has_consent,
--          email_notifications_opt_in
--   FROM public.profiles WHERE id = '<uuid del usuario de prueba>';
--   Esperado: last_name y terms_version poblados; has_consent = true;
--             email_notifications_opt_in según lo enviado.
--
-- T4 (default seguro): un alta SIN email_notifications_opt_in en el metadata
--   deja email_notifications_opt_in = false (nunca NULL, nunca true por accidente).
-- =============================================================================
-- END OF MIGRATION 20260801000002_register_name_terms_captcha.sql
-- =============================================================================
