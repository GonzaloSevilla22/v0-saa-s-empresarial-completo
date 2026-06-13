-- FIX: en producción nunca existió el trigger que dispara el envío de emails.
-- La migración vieja (20250101000009) apuntaba a host.docker.internal (local) y
-- en prod se salteaba, así que TODOS los email_logs quedaban en 'pending' sin
-- enviarse nunca (bienvenida, alertas, plan_upgraded, aviso de registro, etc.).
--
-- Acá creamos el disparador real con pg_net (ya instalado) que llama a la Edge
-- Function send-email en su URL de producción. send-email tiene verify_jwt=false
-- (config.toml), así que no requiere token → no hay secretos en el código.
-- Es AFTER INSERT: solo dispara para emails NUEVOS (no reenvía el backlog viejo).

CREATE OR REPLACE FUNCTION public.send_email_log_webhook()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM net.http_post(
    url     := 'https://gxdhpxvdjjkmxhdkkwyb.supabase.co/functions/v1/send-email',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'type',   'INSERT',
      'table',  'email_logs',
      'record', to_jsonb(NEW)
    )
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_email_log_insert ON public.email_logs;
CREATE TRIGGER on_email_log_insert
  AFTER INSERT ON public.email_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.send_email_log_webhook();
