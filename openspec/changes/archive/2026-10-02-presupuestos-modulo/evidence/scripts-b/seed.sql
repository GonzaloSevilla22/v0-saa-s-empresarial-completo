
DO $$
DECLARE
  v_owner uuid; v_seller uuid; v_cashier uuid; v_b uuid;
  v_acc uuid; v_acc_b uuid; v_m uuid; v_kg uuid; v_u uuid; v_branch uuid; v_p1 uuid; v_p2 uuid; v_pb uuid;
BEGIN
  SELECT id INTO v_owner  FROM auth.users WHERE email='qa.e2e@local.test';
  SELECT id INTO v_seller FROM auth.users WHERE email='qa.seller@local.test';
  SELECT id INTO v_cashier FROM auth.users WHERE email='qa.cashier@local.test';
  SELECT id INTO v_b FROM auth.users WHERE email='qa.b@local.test';
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id=v_owner ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc_b FROM public.account_members WHERE user_id=v_b ORDER BY created_at LIMIT 1;

  -- seller / cashier como miembros de la cuenta del owner (sus cuentas propias quedan, pero la del owner es la primera? no: forzamos)
  DELETE FROM public.account_members WHERE user_id IN (v_seller, v_cashier);
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_acc, v_seller, 'member') RETURNING id INTO v_m;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc, v_m, 'seller');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_acc, v_cashier, 'member') RETURNING id INTO v_m;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc, v_m, 'cashier');

  SELECT id INTO v_branch FROM public.branches WHERE account_id=v_acc ORDER BY created_at LIMIT 1;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
    VALUES (v_acc, 'Kilogramo QA', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
    VALUES (v_acc, 'Unidad QA', 'u', 'unit', 1, false) RETURNING id INTO v_u;

  INSERT INTO public.clients (user_id, account_id, name, phone)
    VALUES (v_owner, v_acc, 'Cliente Demo QA', '261 555-0202');
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
    VALUES (v_owner, v_acc, 'Harina 000 (por kg)', 'QA-HARINA', 700, 1200, v_kg) RETURNING id INTO v_p1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
    VALUES (v_owner, v_acc, 'Alfajor artesanal', 'QA-ALF', 250, 500, v_u) RETURNING id INTO v_p2;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p1, v_branch, 50);
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p2, v_branch, 100);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
    VALUES (v_b, v_acc_b, 'SECRETO DE B', 'QA-B-SECRETO', 777, 999) RETURNING id INTO v_pb;
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_b, v_acc_b, 'Cliente de B');
  RAISE NOTICE 'acc=% accB=% prodB=%', v_acc, v_acc_b, v_pb;
END $$;
SELECT 'owner_acc='||(SELECT account_id FROM public.account_members WHERE user_id=(SELECT id FROM auth.users WHERE email='qa.e2e@local.test') ORDER BY created_at LIMIT 1);
SELECT 'seller_memberships='||count(*) FROM public.account_members WHERE user_id=(SELECT id FROM auth.users WHERE email='qa.seller@local.test');
