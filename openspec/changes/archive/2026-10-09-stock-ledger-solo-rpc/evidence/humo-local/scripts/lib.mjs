// Helpers de la verificación visual (stack LOCAL únicamente). Sin credenciales de prod, sin imprimir env.
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

export const WT = resolve(dirname(fileURLToPath(import.meta.url)), '../../../../../../..')
export const API = process.env.SUPABASE_URL
if (!API || !new URL(API).hostname.match(/^(localhost|127\.0\.0\.1)$/)) throw new Error('env no local')

export const results = []
export const check = (name, ok, detail = '') => {
  results.push([name, !!ok])
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  -> ' + String(detail).slice(0, 300) : ''}`)
}

export const sql = (q) => {
  const r = spawnSync('docker', ['exec', '-i', 'supabase_db_v0-saa-s-empresarial-completo', 'psql', '-X', '-tA', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-c', q], { encoding: 'utf8' })
  if (r.status) throw new Error(r.stderr)
  return r.stdout.trim()
}

// Contraseñas locales por env (QA_ROLE_PW / QA_TEST_USER_PASSWORD): sin literales de prod.
const PW = process.env.QA_ROLE_PW
if (!PW) throw new Error('QA_ROLE_PW requerida (contraseña de los usuarios QA locales)')
export const USERS = {
  owner: ['qa.e2e@local.test', process.env.QA_TEST_USER_PASSWORD],
  stock: ['qa.stock@local.test', PW],
  seller: ['qa.seller@local.test', PW],
}
