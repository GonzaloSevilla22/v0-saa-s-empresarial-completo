-- Trigger for Low Stock Alerts with 24h cooldown
create or replace function public.check_low_stock()
returns trigger as $$
declare
  recent_alert boolean;
begin
  if NEW.stock <= 5 and (TG_OP = 'INSERT' or OLD.stock > 5) then
    -- Check cooldown
    select exists (
      select 1 from public.email_logs 
      where event_type = 'low_stock_alert' 
      and metadata->>'product_id' = NEW.id::text 
      and created_at > now() - interval '24 hours'
    ) into recent_alert;

    if not recent_alert then
      insert into public.email_logs (user_id, event_type, recipient, subject, metadata)
      select NEW.user_id, 'low_stock_alert', u.email, 'Alerta de Stock Bajo: ' || NEW.name, 
        jsonb_build_object('product_id', NEW.id, 'product_name', NEW.name, 'current_stock', NEW.stock)
      from auth.users u where u.id = NEW.user_id;
    end if;
  end if;
  return NEW;
end;
$$ language plpgsql security definer;

create trigger on_product_stock_update
  after insert or update of stock on public.products
  for each row execute procedure public.check_low_stock();

-- Trigger for Low Margin Alert on Sales
create or replace function public.check_low_margin()
returns trigger as $$
declare
  prod_cost numeric;
  prod_name text;
  sale_margin numeric;
  user_email text;
begin
  if NEW.product_id is not null and NEW.amount > 0 then
    select cost, name into prod_cost, prod_name from public.products where id = NEW.product_id;
    
    if prod_cost is not null then
      -- Calculate margin %
      sale_margin := ((NEW.amount - (prod_cost * NEW.quantity)) / NEW.amount) * 100;
      
      -- If margin < 15%, send alert
      if sale_margin < 15 then
        select email into user_email from auth.users where id = NEW.user_id;
        
        insert into public.email_logs (user_id, event_type, recipient, subject, metadata)
        values (
          NEW.user_id, 
          'low_margin_alert', 
          user_email, 
          'Alerta de Margen Bajo: ' || prod_name, 
          jsonb_build_object('sale_id', NEW.id, 'product_name', prod_name, 'margin_percentage', round(sale_margin, 2), 'amount', NEW.amount, 'cost_basis', prod_cost * NEW.quantity)
        );
      end if;
    end if;
  end if;

  return NEW;
end;
$$ language plpgsql security definer;

create trigger on_sale_insert_margin_check
  after insert on public.sales
  for each row execute procedure public.check_low_margin();
