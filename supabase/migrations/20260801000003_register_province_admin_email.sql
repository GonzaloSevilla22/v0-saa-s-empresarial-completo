-- =============================================================================
-- MIGRATION: 20260801000003_register_province_admin_email.sql
-- CHANGE:    seguimiento de register-name-terms-captcha
--
-- QUÉ HACE (aditivo, sin BREAKING):
--   A) profiles: columna nueva `province` (text) para la provincia del alta.
--   B) handle_new_user: copia `province` desde raw_user_meta_data al crear el
--      perfil, y suma `province` (+ ya estaba last_name/full_name) al metadata del
--      email new_user_admin_notice. Base EXACTA: 20260801000002. El bloque de
--      tenant + el resto de los emails NO cambian.
--
-- GOVERNANCE: CRÍTICO — toca el path de signup (auth). El bloque de tenant/emails
--   conserva su lógica.
--
-- APPLY: vía CI al mergear a main (GitHub Actions: build + deploy + db push).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE A — profiles.province (aditiva)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS province text;

COMMENT ON COLUMN public.profiles.province IS
  'Provincia argentina elegida en el alta (lista de 24 jurisdicciones). NULL para usuarios previos al change.';


-- ─────────────────────────────────────────────────────────────────────────────
-- PARTE B — handle_new_user: copiar province + sumarla al aviso al admin
-- Base EXACTA: 20260801000002. ÚNICOS cambios: variable user_province, el INSERT
-- de profiles incluye province, y el metadata del aviso admin suma 'province'.
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
  user_province      text;
  user_terms_version text;
  user_email_optin   boolean;
  v_terms_accepted_at timestamptz;
  v_account_id       uuid;
BEGIN
  user_name          := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), '');
  user_last_name     := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'last_name', '')), '');
  user_phone         := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), '');
  user_locality      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), '');
  user_province      := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'province', '')), '');
  user_terms_version := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'terms_version', '')), '');
  user_email_optin   := COALESCE((new.raw_user_meta_data->>'email_notifications_opt_in')::boolean, false);
  v_terms_accepted_at := CASE WHEN user_terms_version IS NOT NULL THEN now() ELSE NULL END;

  -- 1) Perfil (ahora también province)
  INSERT INTO public.profiles (
    id, name, last_name, phone, locality, province, role,
    terms_accepted_at, terms_version, email_notifications_opt_in
  )
  VALUES (
    new.id, user_name, user_last_name, user_phone, user_locality, user_province, 'user',
    v_terms_accepted_at, user_terms_version, user_email_optin
  );

  -- 2) Tenant: cuenta propia + membresía como OWNER (sin cambios).
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

  -- 3) Mail de bienvenida (sin cambios)
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', COALESCE(user_name, 'Emprendedor'))
  );

  -- 4) Aviso al administrador (ahora con apellido / nombre completo / provincia)
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
      'locality',  COALESCE(user_locality, '-'),
      'province',  COALESCE(user_province, '-')
    )
  );

  RETURN new;
END;
$function$;

-- =============================================================================
-- END OF MIGRATION 20260801000003_register_province_admin_email.sql
-- =============================================================================
