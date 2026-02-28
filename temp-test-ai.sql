-- temp-test-ai.sql

-- 1. Create a User
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'margin.stock@eie.com',
  '{"name": "Admin AI Test"}'
);

-- 2. Create a Product with high stock
INSERT INTO public.products (id, user_id, name, price, cost, stock)
VALUES (
  '11111111-1111-1111-1111-111111111111',
  '00000000-0000-0000-0000-000000000001',
  'Licencia CRM PRO',
  1000.00,
  800.00,
  10
);

-- 3. Trigger low_margin_alert
-- Cost is 800. Sale for 850.
-- Margin = (850 - 800)/850 = 5.8% (< 15%)
INSERT INTO public.sales (user_id, product_id, amount, quantity)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  '11111111-1111-1111-1111-111111111111',
  850.00,
  1
);

-- 4. Trigger low_stock_alert
-- Current stock is 10. Update stock to 4 to trigger alert
UPDATE public.products SET stock = 4 WHERE id = '11111111-1111-1111-1111-111111111111';
