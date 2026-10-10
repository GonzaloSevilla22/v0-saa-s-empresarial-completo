// Siembra de la verificación visual del ajuste manual de stock (stack LOCAL únicamente).
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
  v_owner uuid; v_acc uuid; v_m uuid; r record; v_br1 uuid; v_br2 uuid; v_p uuid; v_parent uuid;
BEGIN
  SELECT id INTO v_owner FROM auth.users WHERE email='qa.e2e@local.test';
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id=v_owner ORDER BY created_at LIMIT 1;

  FOR r IN SELECT * FROM (VALUES ('qa.stock@local.test','stock'),('qa.seller@local.test','seller')) t(email, role) LOOP
    SET session_replication_role = replica;
    DELETE FROM public.account_member_roles WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id=(SELECT id FROM auth.users WHERE email=r.email));
    DELETE FROM public.account_members WHERE user_id=(SELECT id FROM auth.users WHERE email=r.email);
    SET session_replication_role = DEFAULT;
    INSERT INTO public.account_members (account_id, user_id, role)
      VALUES (v_acc, (SELECT id FROM auth.users WHERE email=r.email), 'member') RETURNING id INTO v_m;
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc, v_m, r.role);
  END LOOP;

  SELECT id INTO v_br1 FROM public.branches WHERE account_id=v_acc ORDER BY created_at LIMIT 1;
  INSERT INTO public.branches (account_id, name) VALUES (v_acc, 'Sucursal Norte QA') RETURNING id INTO v_br2;

  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_owner, v_acc, 'Tomate perita', 'QA-TOMATE', 600, 1000) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 8);
  UPDATE public.branch_stock SET min_stock = 2 WHERE product_id = v_p;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_owner, v_acc, 'Alfajor artesanal', 'QA-ALF', 250, 500) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 100);
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br2, 10);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_owner, v_acc, 'Producto escaso QA', 'QA-ESCASO', 100, 300) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 1);
  UPDATE public.branch_stock SET min_stock = 3 WHERE product_id = v_p;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_owner, v_acc, 'Aceite QA', 'QA-ACEITE', 400, 900) RETURNING id INTO v_p;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_p, v_br1, 20);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, stock_control_type) VALUES (v_owner, v_acc, 'Remera con variantes QA', 'QA-REMERA', 2000, 5000, 'variant_only');
END $$;
`
// Idempotente: si la siembra ya corrió (mismo SKU), no la repite.
if (sql("select count(*) from public.products where sku='QA-TOMATE'") === '0') {
  const r = spawnSync('docker', ['exec', '-i', 'supabase_db_v0-saa-s-empresarial-completo', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], { input: seed, encoding: 'utf8' })
  if (r.status) { console.error(r.stderr); process.exit(1) }
} else {
  console.log('siembra ya aplicada: sólo se regeneran los ids')
}
// Humo local: el formulario de producto exige categoría (alta y edición); la siembra inserta sin ella.
// Se asigna 'Alimentos' a los productos sembrados para que la edición del humo pueda guardar, como en un catálogo real.
sql(`update public.products p set category_id = (select c.id from public.product_categories c where c.account_id = p.account_id and c.name = 'Alimentos' limit 1) where p.sku like 'QA-%' and p.category_id is null`)
// Humo local: la venta exige cliente y la compra puede llevar proveedor; se siembra uno de cada uno (idempotente).
sql(`insert into public.clients (user_id, account_id, name) select u.id, m.account_id, 'Cliente humo local' from auth.users u join public.account_members m on m.user_id = u.id where u.email = 'qa.e2e@local.test' and not exists (select 1 from public.clients c where c.name = 'Cliente humo local') limit 1`)
sql(`insert into public.suppliers (account_id, name) select m.account_id, 'Proveedor humo local' from auth.users u join public.account_members m on m.user_id = u.id where u.email = 'qa.e2e@local.test' and not exists (select 1 from public.suppliers c where c.name = 'Proveedor humo local') limit 1`)
const accA = sql("select account_id from account_members where user_id=(select id from auth.users where email='qa.e2e@local.test') order by created_at limit 1")
const ids = {
  accA,
  br1: sql(`select id from branches where account_id='${accA}' order by created_at limit 1`),
  br2: sql(`select id from branches where account_id='${accA}' and name='Sucursal Norte QA'`),
  tomate: sql(`select id from products where account_id='${accA}' and sku='QA-TOMATE'`),
  alf: sql(`select id from products where account_id='${accA}' and sku='QA-ALF'`),
}
writeFileSync(`${process.env.SCRATCH_DIR}/ids.json`, JSON.stringify(ids, null, 1))
console.log('seed OK', JSON.stringify(ids))
