-- =============================================================================
-- MIGRATION: 20260509230813_fix_check_low_stock_security_definer.sql
-- DESCRIPTION: Fix check_low_stock trigger → SECURITY DEFINER
--
-- Root cause: function was SECURITY INVOKER. When authenticated user inserted
-- a product with stock ≤ 5 the trigger fired and executed:
--   SELECT ... FROM auth.users u WHERE u.id = NEW.user_id
-- The authenticated role cannot access auth.users → permission denied →
-- PostgREST returned 403 on the product INSERT.
--
-- Fix: declare SECURITY DEFINER + SET search_path = public (prevents
-- search-path hijacking). Function runs as owner (postgres) which can
-- access auth.users for the low-stock email alert lookup.
--
-- Applied directly via MCP on 2026-05-09. Version: 20260509230813
-- =============================================================================

CREATE OR REPLACE FUNCTION public.check_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  recent_alert boolean;
BEGIN
  IF NEW.stock <= 5 AND (TG_OP = 'INSERT' OR OLD.stock > 5) THEN
    SELECT EXISTS (
      SELECT 1 FROM public.email_logs
      WHERE event_type = 'low_stock_alert'
        AND metadata->>'product_id' = NEW.id::text
        AND created_at > now() - INTERVAL '24 hours'
    ) INTO recent_alert;

    IF NOT recent_alert THEN
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      SELECT
        NEW.user_id,
        'low_stock_alert',
        u.email,
        'Alerta de Stock Bajo: ' || NEW.name,
        jsonb_build_object(
          'product_id',    NEW.id,
          'product_name',  NEW.name,
          'current_stock', NEW.stock
        )
      FROM auth.users u
      WHERE u.id = NEW.user_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
