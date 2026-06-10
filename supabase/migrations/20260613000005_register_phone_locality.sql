-- =============================================================================
-- MIGRATION: 20260613000000_register_phone_locality.sql
-- Registro con teléfono y localidad obligatorios (pedido PO 2026-06-10).
--
-- 1. profiles.locality (text, nullable) — phone ya existe.
--    Nullable a propósito: los usuarios existentes no tienen el dato y la
--    obligatoriedad se aplica en el formulario de registro, no en la DB.
-- 2. handle_new_user copia name/phone/locality desde raw_user_meta_data
--    (el frontend los manda en options.data del signUp).
--    De paso restaura el copiado de `name` a profiles, que se perdió en
--    20260424000002 (quedaba NULL y el módulo comunidad lo lee de profiles).
--    NULLIF(TRIM(...)) — si el metadata no trae el dato, queda NULL y el
--    frontend conserva sus fallbacks (user_metadata / prefijo del email).
-- =============================================================================

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS locality text;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  user_name text;
BEGIN
  user_name := COALESCE(new.raw_user_meta_data->>'name', 'Emprendedor');

  INSERT INTO public.profiles (id, name, phone, locality, role)
  VALUES (
    new.id,
    NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), ''),
    NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), ''),
    NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), ''),
    'user'
  );

  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', user_name)
  );

  RETURN new;
END;
$function$;
