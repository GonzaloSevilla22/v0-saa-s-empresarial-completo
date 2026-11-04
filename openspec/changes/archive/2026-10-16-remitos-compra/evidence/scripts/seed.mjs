// Siembra de la verificación del remito de venta (stack LOCAL únicamente).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (de `supabase status`, no se imprimen), QA_TEST_USER_*, QA_ROLE_PW.
import { spawnSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { sql, USERS } from './lib.mjs'

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!url || !key || !new URL(url).hostname.match(/^(localhost|127\.0\.0\.1)$/)) throw new Error('env no local')

for (const [email, password] of Object.values(USERS)) {
  const r = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, email_confirm: true }),
  })
  console.log(email, r.status)
}

const seed = `
DO $$
DECLARE
  v_owner uuid; v_b uuid; v_acc uuid; v_acc_b uuid; v_m uuid; v_kg uuid; v_u uuid;
  v_br1 uuid; v_br2 uuid; r record; v_p uuid; v_pb uuid; v_brb uuid;
BEGIN
  SELECT id INTO v_owner FROM auth.users WHERE email='qa.e2e@local.test';
  SELECT id INTO v_b FROM auth.users WHERE email='qa.b@local.test';
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id=v_owner ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_acc_b FROM public.account_members WHERE user_id=v_b ORDER BY created_at LIMIT 1;

  FOR r IN SELECT * FROM (VALUES ('qa.admin@local.test','admin'),('qa.seller@local.test','seller'),
      ('qa.cashier@local.test','cashier'),('qa.stock@local.test','stock'),('qa.purchases@local.test','purchases')) t(email, role) LOOP
    DELETE FROM public.account_members WHERE user_id=(SELECT id FROM auth.users WHERE email=r.email);
    INSERT INTO public.account_members (account_id, user_id, role)
      VALUES (v_acc, (SELECT id FROM auth.users WHERE email=r.email), 'member') RETURNING id INTO v_m;
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc, v_m, r.role);
  END LOOP;

  SELECT id INTO v_br1 FROM public.branches WHERE account_id=v_acc ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name) VALUES (v_acc, 'Sucursal Norte QA') RETURNING id INTO v_br2;

  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
    VALUES (v_acc, 'Kilogramo QA', 'kg', 'weight', 1, false) RETURNING id INTO v_kg;
  INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system)
    VALUES (v_acc, 'Unidad QA', 'u', 'unit', 1, false) RETURNING id INTO v_u;

  INSERT INTO public.clients (user_id, account_id, name, phone) VALUES (v_owner, v_acc, 'Cliente Demo QA', '261 555-0202');
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner, v_acc, 'Cliente Dos QA');

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Harina 000 (por kg)', 'QA-HARINA', 700, 1200, v_kg) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 50);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Alfajor artesanal', 'QA-ALF', 250, 500, v_u) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br2, 10);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Producto escaso QA', 'QA-ESCASO', 100, 300, v_u) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 1);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Lote de tres QA', 'QA-TRES', 100, 300, v_u) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 3);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Aceite QA', 'QA-ACEITE', 400, 900, v_u) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 20);

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id) VALUES (v_owner, v_acc, 'Sin costo QA', 'QA-SINCOSTO', NULL, 800, v_u) RETURNING id INTO v_p;
  INSERT INTO public.suppliers (account_id, name, phone) VALUES (v_acc, 'Proveedor Demo QA', '261 555-0303');
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc, 'Proveedor Dos QA');
  SELECT id INTO v_brb FROM public.branches WHERE account_id=v_acc_b ORDER BY created_at LIMIT 1;
  INSERT INTO public.suppliers (account_id, name) VALUES (v_acc_b, 'Proveedor de B');
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_b, v_acc_b, 'SECRETO DE B', 'QA-B-SECRETO', 777, 999) RETURNING id INTO v_pb;
  PERFORM public.c21_apply_branch_stock_delta(v_acc_b, v_pb, v_brb, 30);
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_b, v_acc_b, 'Cliente de B');
END $$;
`
const r = spawnSync('docker', ['exec', '-i', 'supabase_db_v0-saa-s-empresarial-completo', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], { input: seed, encoding: 'utf8' })
if (r.status) { console.error(r.stderr); process.exit(1) }
const accA = sql("select account_id from account_members where user_id=(select id from auth.users where email='qa.e2e@local.test') order by created_at limit 1")
const accB = sql("select account_id from account_members where user_id=(select id from auth.users where email='qa.b@local.test') order by created_at limit 1")
const ids = {
  accA, accB,
  br1: sql(`select id from branches where account_id='${accA}' order by created_at limit 1`),
  br2: sql(`select id from branches where account_id='${accA}' and name='Sucursal Norte QA'`),
  brB: sql(`select id from branches where account_id='${accB}' order by created_at limit 1`),
  kg: sql(`select id from units_of_measure where account_id='${accA}' and symbol='kg'`),
  client: sql(`select id from clients where account_id='${accA}' and name='Cliente Demo QA'`),
  client2: sql(`select id from clients where account_id='${accA}' and name='Cliente Dos QA'`),
  clientB: sql(`select id from clients where account_id='${accB}'`),
  harina: sql(`select id from products where account_id='${accA}' and sku='QA-HARINA'`),
  alf: sql(`select id from products where account_id='${accA}' and sku='QA-ALF'`),
  escaso: sql(`select id from products where account_id='${accA}' and sku='QA-ESCASO'`),
  tres: sql(`select id from products where account_id='${accA}' and sku='QA-TRES'`),
  aceite: sql(`select id from products where account_id='${accA}' and sku='QA-ACEITE'`),
  sinCosto: sql(`select id from products where account_id='${accA}' and sku='QA-SINCOSTO'`),
  sup: sql(`select id from suppliers where account_id='${accA}' and name='Proveedor Demo QA'`),
  sup2: sql(`select id from suppliers where account_id='${accA}' and name='Proveedor Dos QA'`),
  supB: sql(`select id from suppliers where account_id='${accB}'`),
  prodB: sql(`select id from products where account_id='${accB}' and sku='QA-B-SECRETO'`),
}
writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/ids.json', JSON.stringify(ids, null, 1))
console.log('seed OK', Object.keys(ids).length, 'ids')
