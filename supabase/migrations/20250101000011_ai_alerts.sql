-- Trigger for Low Stock Alerts with 24h cooldown
CREATE OR REPLACE FUNCTION public.check_low_stock()
RETURNS TRIGGER AS $$
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
      SELECT NEW.user_id, 'low_stock_alert', u.email, 'Alerta de Stock Bajo: ' || NEW.name, 
        jsonb_build_object('product_id', NEW.id, 'product_name', NEW.name, 'current_stock', NEW.stock)
      FROM auth.users u WHERE u.id = NEW.user_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_product_stock_update ON public.products;
CREATE TRIGGER on_product_stock_update
  AFTER INSERT OR UPDATE OF stock ON public.products
  FOR EACH ROW EXECUTE PROCEDURE public.check_low_stock();

-- Trigger for Low Margin Alert on Sales
CREATE OR REPLACE FUNCTION public.check_low_margin()
RETURNS TRIGGER AS $$
DECLARE
  prod_cost numeric;
  prod_name text;
  sale_margin numeric;
  user_email text;
BEGIN
  IF NEW.product_id IS NOT NULL AND NEW.amount > 0 THEN
    SELECT cost, name INTO prod_cost, prod_name FROM public.products WHERE id = NEW.product_id;
    
    IF prod_cost IS NOT NULL THEN
      sale_margin := ((NEW.amount - (prod_cost * NEW.quantity)) / NEW.amount) * 100;
      
      IF sale_margin < 15 THEN
        SELECT email INTO user_email FROM auth.users WHERE id = NEW.user_id;
        
        INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
        VALUES (
          NEW.user_id, 
          'low_margin_alert', 
          user_email, 
          'Alerta de Margen Bajo: ' || prod_name, 
          jsonb_build_object('sale_id', NEW.id, 'product_name', prod_name, 'margin_percentage', round(sale_margin, 2), 'amount', NEW.amount, 'cost_basis', prod_cost * NEW.quantity)
        );
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_sale_insert_margin_check ON public.sales;
CREATE TRIGGER on_sale_insert_margin_check
  AFTER INSERT ON public.sales
  FOR EACH ROW EXECUTE PROCEDURE public.check_low_margin();
