// Crea (idempotente) los usuarios QA que los tests E2E asumen existentes en el
// Supabase LOCAL: auth.setup.ts y auth.spec.ts hacen login por UI con
// QA_TEST_USER_* / QA_LOGOUT_USER_*, pero nadie los creaba — en el entorno del
// QA original se crearon a mano. Este script es lo que corre CI (y cualquier
// entorno local nuevo: `pnpm e2e:seed`) antes de `playwright test`.
//
// Usa la Admin API de GoTrue con la service_role LOCAL (email_confirm: true =
// no depende de la config de confirmaciones). El insert en auth.users dispara
// handle_new_user → siembra profile + account + branch "Casa Central" + caja
// (v3-provisioning-seed), que es exactamente lo que /dashboard necesita.
//
// Guardia anti-prod: mismo criterio que env-guard.ts — solo localhost/127.0.0.1.

const LOCAL_HOSTS = ['localhost', '127.0.0.1']

const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL_LOCAL
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !serviceKey) {
  console.error('[seed-users] SUPABASE_URL (o NEXT_PUBLIC_SUPABASE_URL_LOCAL) y SUPABASE_SERVICE_ROLE_KEY son requeridas.')
  process.exit(1)
}
if (!LOCAL_HOSTS.includes(new URL(url).hostname)) {
  console.error(`[seed-users] ${url} no es local — abortando para proteger produccion.`)
  process.exit(1)
}

const users = [
  { email: process.env.QA_TEST_USER_EMAIL, password: process.env.QA_TEST_USER_PASSWORD },
  { email: process.env.QA_LOGOUT_USER_EMAIL, password: process.env.QA_LOGOUT_USER_PASSWORD },
]

for (const { email, password } of users) {
  if (!email || !password) {
    console.error('[seed-users] QA_TEST_USER_* y QA_LOGOUT_USER_* son requeridas.')
    process.exit(1)
  }

  const res = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST',
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ email, password, email_confirm: true }),
  })

  if (res.ok) {
    console.log(`[seed-users] creado: ${email}`)
    continue
  }

  const body = await res.text()
  // Idempotencia: usuario ya existente no es error (422/409 segun version de GoTrue).
  if (res.status === 422 || res.status === 409 || /already|exists/i.test(body)) {
    console.log(`[seed-users] ya existia: ${email}`)
    continue
  }

  console.error(`[seed-users] fallo creando ${email}: HTTP ${res.status} — ${body}`)
  process.exit(1)
}

console.log('[seed-users] listo.')
