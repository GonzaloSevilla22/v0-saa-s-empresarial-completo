// Helpers de la tanda B (stack LOCAL únicamente). Sin credenciales de prod, sin imprimir env.
import { spawnSync } from 'node:child_process'
export const API = process.env.SUPABASE_URL
export const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL
export const BE = 'http://127.0.0.1:8000'
if (!API || !new URL(API).hostname.match(/^(localhost|127\.0\.0\.1)$/)) throw new Error('env no local')

export const results = []
export const check = (name, ok, detail = '') => {
  results.push([name, !!ok])
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  -> ' + String(detail).slice(0, 300) : ''}`)
}

export async function login(email, password) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  const j = await r.json()
  if (!j.access_token) throw new Error('login ' + email + ' ' + r.status)
  return j.access_token
}

export const sql = (q) => {
  const r = spawnSync('docker', ['exec', '-i', 'supabase_db_v0-saa-s-empresarial-completo', 'psql', '-X', '-tA', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-c', q], { encoding: 'utf8' })
  if (r.status) throw new Error(r.stderr)
  return r.stdout.trim()
}

export const be = async (tok, method, path, body, headers = {}) => {
  const doFetch = () => fetch(BE + path, {
    method,
    headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json', Connection: 'close', ...headers },
    body: body ? JSON.stringify(body) : undefined,
  })
  const r = await doFetch().catch(() => doFetch())
  let j = null
  const ct = r.headers.get('content-type') || ''
  if (ct.includes('json')) j = await r.json().catch(() => null)
  return { status: r.status, body: j, ct }
}

export const rest = async (tok, method, path, body) => {
  const r = await fetch(`${API}/rest/v1/${path}`, {
    method,
    headers: { apikey: ANON, Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const t = await r.text()
  let j
  try { j = JSON.parse(t) } catch { j = t }
  return { status: r.status, body: j }
}

// Contraseñas locales por env (QA_ROLE_PW): sin literales en el repo.
const PW = process.env.QA_ROLE_PW
if (!PW) throw new Error('QA_ROLE_PW requerida (contraseña de los usuarios QA locales)')
export const USERS = {
  owner: ['qa.e2e@local.test', process.env.QA_TEST_USER_PASSWORD],
  admin: ['qa.admin@local.test', PW],
  seller: ['qa.seller@local.test', PW],
  cashier: ['qa.cashier@local.test', PW],
  stock: ['qa.stock@local.test', PW],
  b: ['qa.b@local.test', PW],
}
