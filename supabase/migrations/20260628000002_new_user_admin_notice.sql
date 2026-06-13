-- Aviso al administrador cuando se registra un usuario nuevo (pedido PO).
--
-- Extiende handle_new_user (sin cambiar lo existente: crea el profile y encola
-- el mail de bienvenida al usuario) agregando un SEGUNDO email_logs dirigido al
-- administrador, con los datos del registro. El envío real lo hace el Edge
-- Function send-email (plantilla 'new_user_admin_notice'); solo llega a destinos
-- externos una vez verificado el dominio en Resend.
--
-- Base: versión de 20260613000005_register_phone_locality.sql (no perder el
-- copiado de name/phone/locality ni el mail de bienvenida).

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
BEGIN
  user_name     := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'name', '')), '');
  user_phone    := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'phone', '')), '');
  user_locality := NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'locality', '')), '');

  -- 1) Perfil
  INSERT INTO public.profiles (id, name, phone, locality, role)
  VALUES (new.id, user_name, user_phone, user_locality, 'user');

  -- 2) Mail de bienvenida al usuario nuevo
  INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
  VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', COALESCE(user_name, 'Emprendedor'))
  );

  -- 3) Aviso al administrador con los datos del registro
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
