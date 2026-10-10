// Helpers del humo local de stock-ledger-solo-rpc (stack LOCAL únicamente). Reutiliza lib.mjs / pw-lib.mjs del arnés de la tanda B.
import { appendFileSync, readFileSync, existsSync, writeFileSync } from 'node:fs'
import { chromium, BASE, OUT, SCRATCH, VIEWPORTS, consoleCollector } from './pw-lib.mjs'
import { sql, USERS, API, WT } from './lib.mjs'

export { chromium, BASE, OUT, SCRATCH, sql, USERS, API, WT }
export const LOGS = `${OUT}/../logs`
export const AUTH = { owner: `${SCRATCH}/humo-auth-owner.json`, stock: `${SCRATCH}/humo-auth-stock.json`, seller: `${SCRATCH}/humo-auth-seller.json` }
export const IDS = () => JSON.parse(readFileSync(`${SCRATCH}/ids.json`, 'utf8'))
export const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL

export const log = (file, line) => { const s = typeof line === 'string' ? line : JSON.stringify(line); appendFileSync(`${LOGS}/${file}`, s + '\n'); console.log(s) }

export async function ctxFor(browser, role, viewport = 'desktop') {
  const ctx = await browser.newContext({
    viewport: VIEWPORTS[viewport], colorScheme: 'light',
    storageState: AUTH[role], isMobile: viewport === 'mobile', hasTouch: viewport === 'mobile',
  })
  await ctx.addInitScript(() => { try { localStorage.setItem('theme', 'light') } catch {} })
  return ctx
}

export async function loginAll(browser) {
  for (const role of Object.keys(AUTH)) {
    const [email, password] = USERS[role]
    const ctx = await browser.newContext({ viewport: VIEWPORTS.desktop })
    const page = await ctx.newPage()
    await page.goto(BASE + '/auth/login', { waitUntil: 'domcontentloaded', timeout: 180000 })
    await page.getByTestId('login-email').fill(email)
    await page.getByTestId('login-password').fill(password)
    await page.getByTestId('login-submit').click()
    await page.waitForURL(/\/dashboard/, { timeout: 180000 })
    await ctx.storageState({ path: AUTH[role] })
    await ctx.close()
    console.log('login OK', role)
  }
}

export async function open(page, path, readyText) {
  await page.goto(BASE + path, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
  if (readyText) await page.getByText(readyText).filter({ visible: true }).first().waitFor({ timeout: 90000 })
  await page.waitForTimeout(800)
}

export const shot = async (page, name, opts = {}) => { await page.waitForTimeout(400); await page.screenshot({ path: `${OUT}/${name}.png`, ...opts }) }

// Consola y respuestas de red con error (>=400) de una página, a un log del humo.
export function watch(page, tag, file = '20_consola_navegador.log') {
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) log(file, `[${tag}] console.${m.type()}: ${m.text().slice(0, 300)}`) })
  page.on('pageerror', (e) => log(file, `[${tag}] pageerror: ${String(e).slice(0, 300)}`))
  page.on('response', (r) => { if (r.status() >= 400 && !/\/_next\/|favicon|\.map$/.test(r.url())) log(file, `[${tag}] HTTP ${r.status()} ${r.request().method()} ${r.url().replace(/\?.*/, '').slice(0, 160)}`) })
}

// JWT real del usuario (password grant contra el Auth LOCAL) para los pasos de API.
export async function jwtFor(role) {
  const [email, password] = USERS[role]
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }) })
  const j = await r.json()
  if (!j.access_token) throw new Error('sin token: ' + r.status)
  return j.access_token
}
export async function rest(role, method, path, body, extra = {}) {
  const jwt = await jwtFor(role)
  const r = await fetch(`${API}/rest/v1/${path}`, { method, headers: { apikey: ANON, Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json', ...extra }, body: body === undefined ? undefined : JSON.stringify(body) })
  const text = await r.text()
  return { status: r.status, body: text.slice(0, 600) }
}

// Registro de resultados por sub-paso: logs/10_resultados.jsonl (alimenta REPORTE.md).
export const rec = (step, action, expected, observed, pass, shotNames = '') => {
  log('10_resultados.jsonl', { ts: new Date().toISOString(), step, action, expected, observed, result: pass ? 'PASS' : 'FAIL', shots: shotNames })
}
export const dbRows = (q) => sql(q)
