// Siembra el stack LOCAL para el humo de la tanda C (todo @test.local): el dueño de un negocio (con un producto
// con stock), un vendedor fijo (para el red-team: invitar sin rol), una identidad AJENA a la invitación y el dueño
// de OTRA cuenta (token ajeno). El INVITADO no se siembra: se registra por la interfaz desde el link del email.
import { statusEnv, psql, loadSecrets, saveSecrets, USERS } from "./common.mjs"

const env = statusEnv()
const API = env.API_URL
const SK = env.SERVICE_ROLE_KEY
if (!API || !SK) throw new Error("faltan API_URL / SERVICE_ROLE_KEY del stack local")
const secrets = loadSecrets() ?? {}
secrets.anon = env.ANON_KEY
secrets.service = SK
secrets.jwtSecret = env.JWT_SECRET
secrets.api = API
if (!secrets.password) throw new Error("falta secrets.password (contraseña de PRUEBA de los usuarios @test.local)")
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
for (const key of ["owner", "wrong", "other", "seller"]) await createUser(USERS[key])

const E = Object.fromEntries(Object.entries(USERS).map(([k, u]) => [k, u.email]))
psql(`
DO $$
DECLARE v_owner uuid; v_other uuid; v_seller uuid; v_a uuid; v_b uuid; v_m uuid; v_branch uuid; v_prod uuid;
BEGIN
  SELECT id INTO v_owner  FROM auth.users WHERE email = '${E.owner}';
  SELECT id INTO v_other  FROM auth.users WHERE email = '${E.other}';
  SELECT id INTO v_seller FROM auth.users WHERE email = '${E.seller}';
  SELECT account_id INTO v_a FROM public.account_members WHERE user_id = v_owner ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_b FROM public.account_members WHERE user_id = v_other ORDER BY created_at LIMIT 1;

  UPDATE public.profiles SET business_name = '${USERS.owner.business.replace(/'/g, "''")}' WHERE id = v_owner;
  UPDATE public.profiles SET business_name = '${USERS.other.business}' WHERE id = v_other;
  -- Un plan que no limite el cupo del humo.
  UPDATE public.accounts SET trial_plan = NULL, trial_expires_at = NULL, billing_plan = 'pro', billing_status = 'active'
   WHERE id IN (v_a, v_b);

  -- El vendedor fijo es miembro del negocio (sin autoridad para invitar).
  IF NOT EXISTS (SELECT 1 FROM public.account_members WHERE user_id = v_seller AND account_id = v_a) THEN
    INSERT INTO public.account_members (account_id, user_id, role, created_at) VALUES (v_a, v_seller, 'member', now() - interval '1 day') RETURNING id INTO v_m;
    INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_a, v_m, 'seller');
    UPDATE public.profiles SET active_account_id = v_a WHERE id = v_seller;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.products WHERE account_id = v_a AND sku = 'HUMOC-MARTILLO') THEN
    SELECT id INTO v_branch FROM public.branches WHERE account_id = v_a ORDER BY created_at LIMIT 1;
    INSERT INTO public.products (user_id, account_id, name, sku, cost, price) VALUES (v_owner, v_a, 'Martillo Roca', 'HUMOC-MARTILLO', 600, 1000) RETURNING id INTO v_prod;
    PERFORM public.c21_apply_branch_stock_delta(v_a, v_prod, v_branch, 200);
  END IF;
END $$;
`)
console.log("seed OK:", ["owner", "wrong", "other", "seller"].map((k) => E[k]).join(", "))
