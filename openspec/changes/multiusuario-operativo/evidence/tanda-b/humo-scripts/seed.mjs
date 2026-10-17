// Siembra el equipo de la tanda B en el stack LOCAL (todo @test.local): un dueño con su negocio, un vendedor
// que además tiene su cuenta personal (la más antigua), un administrador, compras, depósito, un observador y
// el dueño de OTRA cuenta (la víctima del red-team).
import { statusEnv, psql, loadSecrets, saveSecrets } from "./common.mjs"

export const TEAM = {
  owner: { email: "humob-owner@test.local", name: "Dueña Roca", business: "Ferretería Roca" },
  seller: { email: "humob-seller@test.local", name: "Vendedor Vera", business: "Kiosco de Vera" },
  admin: { email: "humob-admin@test.local", name: "Admin Ana", business: "Estudio de Ana" },
  purchases: { email: "humob-compras@test.local", name: "Compras Carlos", business: "Carlos SA" },
  stock: { email: "humob-deposito@test.local", name: "Depósito Diego", business: "Depósito de Diego" },
  viewer: { email: "humob-observador@test.local", name: "Observadora Olga", business: "Olga SRL" },
  other: { email: "humob-otra@test.local", name: "Otra Zulema", business: "Zulema Hnos" },
}

if (process.argv[1]?.endsWith("seed.mjs")) {
  const env = statusEnv()
  const API = env.API_URL
  const SK = env.SERVICE_ROLE_KEY
  if (!API || !SK) throw new Error("faltan API_URL / SERVICE_ROLE_KEY del stack local")
  const secrets = loadSecrets()
  secrets.anon = env.ANON_KEY
  secrets.service = SK
  secrets.jwtSecret = env.JWT_SECRET
  secrets.api = API
  saveSecrets(secrets)

  async function createUser(u) {
    const res = await fetch(`${API}/auth/v1/admin/users`, {
      method: "POST",
      headers: { apikey: SK, Authorization: `Bearer ${SK}`, "content-type": "application/json" },
      body: JSON.stringify({ email: u.email, password: secrets.password, email_confirm: true, user_metadata: { name: u.name } }),
    })
    const body = await res.json().catch(() => ({}))
    if (!res.ok && !/already|exists|registered/i.test(JSON.stringify(body))) {
      throw new Error(`createUser ${u.email}: ${res.status} ${JSON.stringify(body).slice(0, 200)}`)
    }
  }
  for (const u of Object.values(TEAM)) await createUser(u)

  const E = Object.fromEntries(Object.entries(TEAM).map(([k, u]) => [k, u.email]))
  psql(`
DO $$
DECLARE
  v_owner uuid; v_seller uuid; v_admin uuid; v_comp uuid; v_stock uuid; v_view uuid; v_other uuid;
  v_a uuid; v_b uuid; v_member uuid; v_branch uuid; v_prod uuid; v_ps uuid;
BEGIN
  SELECT id INTO v_owner  FROM auth.users WHERE email = '${E.owner}';
  SELECT id INTO v_seller FROM auth.users WHERE email = '${E.seller}';
  SELECT id INTO v_admin  FROM auth.users WHERE email = '${E.admin}';
  SELECT id INTO v_comp   FROM auth.users WHERE email = '${E.purchases}';
  SELECT id INTO v_stock  FROM auth.users WHERE email = '${E.stock}';
  SELECT id INTO v_view   FROM auth.users WHERE email = '${E.viewer}';
  SELECT id INTO v_other  FROM auth.users WHERE email = '${E.other}';
  SELECT account_id INTO v_a FROM public.account_members WHERE user_id = v_owner ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_b FROM public.account_members WHERE user_id = v_other ORDER BY created_at LIMIT 1;

  -- nombres de los negocios y plan que no limite a 7 miembros
  UPDATE public.profiles SET business_name = '${TEAM.owner.business}' WHERE id = v_owner;
  UPDATE public.profiles SET business_name = '${TEAM.seller.business}' WHERE id = v_seller;
  UPDATE public.profiles SET business_name = '${TEAM.other.business}' WHERE id = v_other;
  UPDATE public.accounts SET trial_plan = NULL, trial_expires_at = NULL, billing_plan = 'pro', billing_status = 'active'
   WHERE id IN (SELECT account_id FROM public.account_members WHERE user_id IN (v_owner, v_seller, v_admin, v_comp, v_stock, v_view, v_other));

  -- La personal de cada invitado es la MÁS ANTIGUA (como en producción cuando lo invitan).
  UPDATE public.account_members SET created_at = now() - interval '3 days'
   WHERE user_id IN (v_seller, v_admin, v_comp, v_stock, v_view) AND account_id <> v_a;

  NULL;
END $$;
`)

  for (const [key, role] of [["seller", "seller"], ["admin", "admin"], ["purchases", "purchases"], ["stock", "stock"], ["viewer", "viewer"]]) {
    psql(`
DO $$
DECLARE v_u uuid; v_a uuid; v_m uuid;
BEGIN
  SELECT id INTO v_u FROM auth.users WHERE email = '${E[key]}';
  SELECT account_id INTO v_a FROM public.account_members am JOIN auth.users u ON u.id = am.user_id WHERE u.email = '${E.owner}' ORDER BY am.created_at LIMIT 1;
  IF NOT EXISTS (SELECT 1 FROM public.account_members WHERE user_id = v_u AND account_id = v_a) THEN
    INSERT INTO public.account_members (account_id, user_id, role, created_at) VALUES (v_a, v_u, 'member', now() - interval '1 day') RETURNING id INTO v_m;
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_m, '${role}');
  END IF;
  -- Como dejaría la aceptación de una invitación: el negocio queda como cuenta activa.
  UPDATE public.profiles SET active_account_id = v_a WHERE id = v_u;
END $$;
`)
  }

  psql(`
DO $$
DECLARE
  v_owner uuid; v_other uuid; v_a uuid; v_b uuid; v_branch uuid; v_prod uuid;
BEGIN
  SELECT id INTO v_owner FROM auth.users WHERE email = '${E.owner}';
  SELECT id INTO v_other FROM auth.users WHERE email = '${E.other}';
  SELECT account_id INTO v_a FROM public.account_members WHERE user_id = v_owner ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_b FROM public.account_members WHERE user_id = v_other ORDER BY created_at LIMIT 1;
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE account_id = v_a AND sku = 'HUMOB-MARTILLO') THEN
    SELECT id INTO v_branch FROM public.branches WHERE account_id = v_a ORDER BY created_at LIMIT 1;
    INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_owner, v_a, 'Martillo Roca', 'HUMOB-MARTILLO', 600, 1000) RETURNING id INTO v_prod;
    PERFORM public.c21_apply_branch_stock_delta(v_a, v_prod, v_branch, 200);
    INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_owner, v_a, 'Cinta métrica', 'HUMOB-CINTA', 300, 500) RETURNING id INTO v_prod;
    PERFORM public.c21_apply_branch_stock_delta(v_a, v_prod, v_branch, 200);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE account_id = v_b AND sku = 'HUMOB-TUERCA') THEN
    SELECT id INTO v_branch FROM public.branches WHERE account_id = v_b ORDER BY created_at LIMIT 1;
    INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_other, v_b, 'Tuerca de Zulema', 'HUMOB-TUERCA', 10, 20) RETURNING id INTO v_prod;
    PERFORM public.c21_apply_branch_stock_delta(v_b, v_prod, v_branch, 500);
  END IF;
END $$;
`)
  console.log("seed OK:", Object.values(TEAM).map((u) => u.email).join(", "))
}
