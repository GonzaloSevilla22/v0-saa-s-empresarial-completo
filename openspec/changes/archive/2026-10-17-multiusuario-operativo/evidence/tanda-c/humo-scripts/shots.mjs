// Verificación visual de la tanda C (18.1): /invitacion/[token] (anónimo, vista previa, no disponible, ya es miembro) y
// /organizacion/invitar (con y sin invitaciones), en escritorio y móvil, tema claro y oscuro. Sin desborde horizontal.
// Uso: node shots.mjs   (requiere stack.mjs up, seed.mjs, redteam.mjs/humo.mjs ya corridos)
import { createRequire } from "node:module"
import { writeFileSync, mkdirSync } from "node:fs"
import { WT, SHOTS, BASE, BACK, psql, sql1, loadSecrets, sleep, USERS } from "./common.mjs"

const require = createRequire(`${WT}/frontend/package.json`)
const { chromium } = require("@playwright/test")
const S = loadSecrets()
const log = []
let failed = 0
const note = (m) => { console.log(m); log.push(m) }
const ok = (c, m) => { if (!c) failed++; note(`${c ? "PASS" : "FAIL"}: ${m}`) }

async function tokenOf(email) {
  const r = await fetch(`${S.api}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: S.anon, "content-type": "application/json" }, body: JSON.stringify({ email, password: S.password }) })
  const b = await r.json()
  const claims = JSON.parse(Buffer.from(b.access_token.split(".")[1], "base64url").toString())
  return { token: b.access_token, accountId: claims.app_metadata?.account_id }
}
async function be(method, path, who, body) {
  const r = await fetch(`${BACK}${path}`, { method, headers: { Authorization: `Bearer ${who.token}`, "content-type": "application/json", "X-Account-Id": who.accountId }, body: body ? JSON.stringify(body) : undefined })
  return { status: r.status, body: await r.json().catch(() => null) }
}

const A = sql1(`select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${USERS.owner.email}' order by am.created_at limit 1`)
const B = sql1(`select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${USERS.other.email}' order by am.created_at limit 1`)
psql(`update public.accounts set billing_plan='pro', billing_status='active', trial_plan=null, trial_expires_at=null where id in ('${A}','${B}')`)
psql(`delete from public.account_invitations where account_id in ('${A}','${B}') and email like 'shots-%@test.local'`)
psql(`delete from public.email_logs where event_type='org_invite'`)

const owner = await tokenOf(USERS.owner.email)
// Invitaciones para la lista del dueño: una pendiente, una vencida, una revocada.
const pend = await be("POST", "/members/invitations", owner, { email: "shots-pendiente@test.local", roles: ["seller", "cashier"] })
const toExpire = await be("POST", "/members/invitations", owner, { email: "shots-vencida@test.local", roles: ["viewer"] })
const toRevoke = await be("POST", "/members/invitations", owner, { email: "shots-revocada@test.local", roles: ["purchases"] })
await be("DELETE", `/members/invitations/${toRevoke.body.id}`, owner)
psql(`update public.account_invitations set expires_at = now() - interval '2 days' where id='${toExpire.body.id}'`)
// La invitación para la vista previa / no disponible (dirigida a invitee2) y la de «ya es miembro» (dirigida al vendedor fijo).
await fetch(`${S.api}/auth/v1/admin/users`, { method: "POST", headers: { apikey: S.service, Authorization: `Bearer ${S.service}`, "content-type": "application/json" }, body: JSON.stringify({ email: USERS.invitee2.email, password: S.password, email_confirm: true, user_metadata: { name: USERS.invitee2.name } }) })
psql(`delete from public.account_members where user_id=(select id from auth.users where email='${USERS.invitee2.email}') and account_id='${A}'`)
const previewInv = await be("POST", "/members/invitations", owner, { email: USERS.invitee2.email, roles: ["seller"] })
const T = previewInv.body.token
const MEMBER_TOKEN = "e".repeat(64)
psql(`insert into public.account_invitations (account_id, email, token, role, roles, status, invited_by, account_display_name)
      select '${A}', '${USERS.seller.email}', '${MEMBER_TOKEN}', 'member', array['seller'], 'pending', id, 'Ferretería <Roca> & Hijos' from auth.users where email='${USERS.owner.email}'
      on conflict (token) do nothing`)

const browser = await chromium.launch({ headless: true })
const VIEWPORTS = { desktop: { width: 1280, height: 800 }, mobile: { width: 375, height: 812 } }

async function loginState(email) {
  const ctx = await browser.newContext({ viewport: VIEWPORTS.desktop })
  const page = await ctx.newPage()
  await page.goto(`${BASE}/auth/login`, { waitUntil: "domcontentloaded" })
  await page.locator('input[type="email"]').first().fill(email)
  await page.locator('input[type="password"]').first().fill(S.password)
  await page.waitForFunction(() => { const b = document.querySelector('[data-testid="login-submit"]'); return b && !b.disabled }, null, { timeout: 60000 })
  await page.getByTestId("login-submit").click()
  await page.waitForURL(/\/dashboard/, { timeout: 60000 })
  await page.waitForLoadState("networkidle").catch(() => {})
  const state = await ctx.storageState()
  await ctx.close()
  return state
}

const states = {
  owner: await loginState(USERS.owner.email),
  zulema: await loginState(USERS.other.email),
  invitee2: await loginState(USERS.invitee2.email),
  wrong: await loginState(USERS.wrong.email),
  seller: await loginState(USERS.seller.email),
}

const VIEWS = [
  { name: "invitacion-anonimo", path: `/invitacion/${T}`, state: null, expect: /tenés una invitación para sumarte a un negocio/i },
  { name: "invitacion-vista-previa", path: `/invitacion/${T}`, state: "invitee2", expect: /te invitaron a sumarte a/i },
  { name: "invitacion-no-disponible", path: `/invitacion/${T}`, state: "wrong", expect: /no está disponible para tu usuario/i },
  { name: "invitacion-ya-es-miembro", path: `/invitacion/${MEMBER_TOKEN}`, state: "seller", expect: /ya sos parte de/i },
  { name: "invitar-con-pendientes", path: "/organizacion/invitar", state: "owner", expect: /pendiente@test\.local/ },
  { name: "invitar-vacia", path: "/organizacion/invitar", state: "zulema", expect: /no hay invitaciones pendientes/i },
]

mkdirSync(SHOTS, { recursive: true })
for (const view of VIEWS) {
  for (const [vpName, viewport] of Object.entries(VIEWPORTS)) {
    for (const scheme of ["light", "dark"]) {
      const ctx = await browser.newContext({ viewport, colorScheme: scheme, ...(view.state ? { storageState: states[view.state] } : {}) })
      await ctx.addInitScript((t) => { try { localStorage.setItem("theme", t) } catch {} }, scheme)
      await ctx.addCookies([{ name: "ui:theme", value: scheme, url: BASE }])
      const page = await ctx.newPage()
      await page.goto(`${BASE}${view.path}`, { waitUntil: "domcontentloaded" })
      await page.waitForLoadState("networkidle").catch(() => {})
      const shown = page.getByText(view.expect).first()
      await shown.waitFor({ timeout: 25000 }).catch(() => {})
      await sleep(400)
      const visible = await shown.isVisible().catch(() => false)
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      const isDark = await page.evaluate(() => document.documentElement.classList.contains("dark"))
      ok(visible && overflow <= 0 && isDark === (scheme === "dark"), `${view.name} [${vpName}/${scheme}]: contenido visible=${visible}, desborde horizontal=${overflow}px, tema ${isDark ? "oscuro" : "claro"}`)
      await page.screenshot({ path: `${SHOTS}/visual-${view.name}-${vpName}-${scheme}.png`, fullPage: true })
      await ctx.close()
    }
  }
}
await browser.close()
writeFileSync(`${SHOTS}/visual.log`, log.join("\n") + `\n\nRESULTADO: ${failed === 0 ? "TODO PASS" : failed + " FAIL"}\n`)
console.log(failed === 0 ? "\nTODO PASS" : `\n${failed} FAIL`)
process.exit(failed === 0 ? 0 : 1)
