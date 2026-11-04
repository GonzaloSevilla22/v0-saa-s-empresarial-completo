// Verificación visual + de comportamiento de /ventas y /compras por rol (tanda B, 10.5 / 11.1), contra el stack LOCAL
// con build de producción. Un observador, un vendedor, compras, un depósito y el dueño; escritorio y móvil, claro y oscuro.
// Uso: node ui.mjs
import { createRequire } from "node:module"
import { writeFileSync, mkdirSync } from "node:fs"
import { WT, SHOTS, psql, loadSecrets } from "./common.mjs"
import { TEAM } from "./seed.mjs"

const require = createRequire(`${WT}/frontend/package.json`)
const { chromium } = require("@playwright/test")

const BASE = "http://localhost:3000"
const BACK = "http://127.0.0.1:8000"
const S = loadSecrets()
const log = []
let failed = 0
const note = (m) => { console.log(m); log.push(m) }
const ok = (c, m) => { if (!c) failed++; note(`${c ? "PASS" : "FAIL"}: ${m}`) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const today = new Date().toISOString().slice(0, 10)
const sql1 = (q) => psql(q).trim()

async function apiLogin(email) {
  const r = await fetch(`${S.api}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { apikey: S.anon, "content-type": "application/json" }, body: JSON.stringify({ email, password: S.password }),
  })
  const b = await r.json()
  const claims = JSON.parse(Buffer.from(b.access_token.split(".")[1], "base64url").toString())
  return { token: b.access_token, accountId: claims.app_metadata?.account_id }
}
async function be(method, path, who, body) {
  const r = await fetch(`${BACK}${path}`, { method, headers: { Authorization: `Bearer ${who.token}`, "content-type": "application/json", "X-Account-Id": who.accountId }, body: body ? JSON.stringify(body) : undefined })
  return { status: r.status, body: await r.json().catch(() => null) }
}

// ── Datos de la prueba: operaciones de DISTINTOS autores en el negocio ──────────
const A = sql1(`select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${TEAM.owner.email}' order by am.created_at limit 1`)
const pid = (sku) => sql1(`select id from public.products where sku='${sku}'`)
const MARTILLO = pid("HUMOB-MARTILLO")
const CINTA = pid("HUMOB-CINTA")
const key = (p) => `ui-${p}-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`
const owner = await apiLogin(TEAM.owner.email)
const seller = await apiLogin(TEAM.seller.email)
const buyer = await apiLogin(TEAM.purchases.email)
await be("POST", "/sales", owner, { idempotency_key: key("so"), org_id: A, date: today, items: [{ product_id: CINTA, quantity: 1, amount: 500 }] })
await be("POST", "/sales", seller, { idempotency_key: key("ss"), org_id: A, date: today, items: [{ product_id: MARTILLO, quantity: 1, amount: 1000 }] })
await be("POST", "/purchases", owner, { idempotency_key: key("po"), org_id: A, date: today, items: [{ product_id: CINTA, quantity: 2, amount: 300 }] })
await be("POST", "/purchases", buyer, { idempotency_key: key("pc"), org_id: A, date: today, items: [{ product_id: MARTILLO, quantity: 2, amount: 600 }] })
const nSales = Number(sql1(`select count(distinct operation_id) from public.sales where account_id='${A}'`))
const nBuys = Number(sql1(`select count(distinct operation_id) from public.purchases where account_id='${A}'`))
const ownSalesOf = (email) => Number(sql1(`select count(distinct operation_id) from public.sales s join auth.users u on u.id=s.user_id where s.account_id='${A}' and u.email='${email}'`))
const ownBuysOf = (email) => Number(sql1(`select count(distinct operation_id) from public.purchases s join auth.users u on u.id=s.user_id where s.account_id='${A}' and u.email='${email}'`))
note(`datos: ${nSales} ventas y ${nBuys} compras en el negocio (vendedor: ${ownSalesOf(TEAM.seller.email)} ventas propias; compras: ${ownBuysOf(TEAM.purchases.email)} compras propias)`)

async function login(page, email) {
  await page.goto(`${BASE}/auth/login`, { waitUntil: "domcontentloaded" })
  await page.locator('input[type="email"]').first().fill(email)
  await page.locator('input[type="password"]').first().fill(S.password)
  const submit = page.getByTestId("login-submit")
  await submit.waitFor({ state: "visible", timeout: 30000 })
  await page.waitForFunction(() => { const b = document.querySelector('[data-testid="login-submit"]'); return b && !b.disabled }, null, { timeout: 60000 })
  await submit.click()
  await page.waitForURL(/\/dashboard/, { timeout: 60000 })
  await page.waitForLoadState("networkidle").catch(() => {})
}

async function counts(page, what) {
  // visibles: en escritorio el bloque móvil existe en el DOM pero está oculto (y viceversa)
  const pencils = await page.locator('button:has(svg.lucide-pencil)').evaluateAll((els) => els.filter((e) => e.offsetParent !== null).length)
  const trash = await page.locator(`button[aria-label^="Eliminar esta ${what}"], button[aria-label^="Eliminar esta operación"]`).evaluateAll((els) => els.filter((e) => e.offsetParent !== null).length)
  const nueva = await page.getByRole("button", { name: new RegExp(`nueva ${what}`, "i") }).evaluateAll((els) => els.filter((e) => e.offsetParent !== null).length)
  return { pencils, trash, nueva }
}

async function visit(browser, who, { w, h, scheme, shotPrefix }) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, colorScheme: scheme })
  const page = await ctx.newPage()
  await page.addInitScript((t) => { try { localStorage.setItem("theme", t) } catch {} }, scheme)
  await login(page, TEAM[who].email)
  const out = {}
  for (const [path, what, label] of [["/ventas", "venta", "ventas"], ["/compras", "compra", "compras"]]) {
    await page.goto(`${BASE}${path}`, { waitUntil: "domcontentloaded" })
    await page.waitForLoadState("networkidle").catch(() => {})
    await sleep(900)
    out[label] = await counts(page, what)
    if (shotPrefix) {
      mkdirSync(SHOTS, { recursive: true })
      await page.screenshot({ path: `${SHOTS}/${shotPrefix}-${label}.png`, fullPage: false })
    }
  }
  await ctx.close()
  return out
}

const browser = await chromium.launch({ channel: process.env.PW_CHANNEL || undefined, headless: true })
try {
  const expectations = {
    viewer:    { ventas: { nueva: 0, pencils: 0, trash: 0 }, compras: { nueva: 0, pencils: 0, trash: 0 } },
    seller:    { ventas: { nueva: 1, pencils: ownSalesOf(TEAM.seller.email), trash: ownSalesOf(TEAM.seller.email) }, compras: { nueva: 0, pencils: 0, trash: 0 } },
    purchases: { ventas: { nueva: 0, pencils: 0, trash: 0 }, compras: { nueva: 1, pencils: ownBuysOf(TEAM.purchases.email), trash: ownBuysOf(TEAM.purchases.email) } },
    stock:     { ventas: { nueva: 0, pencils: 0, trash: 0 }, compras: { nueva: 0, pencils: 0, trash: 0 } },
    owner:     { ventas: { nueva: 1, pencils: nSales, trash: nSales }, compras: { nueva: 1, pencils: nBuys, trash: nBuys } },
  }
  // Comportamiento (escritorio, claro) de los cinco perfiles
  for (const who of Object.keys(expectations)) {
    const got = await visit(browser, who, { w: 1366, h: 800, scheme: "light", shotPrefix: who === "seller" || who === "viewer" ? `visual-${who}-desktop-light` : null })
    for (const label of ["ventas", "compras"]) {
      const e = expectations[who][label]
      const g = got[label]
      ok(g.nueva === e.nueva && g.pencils === e.pencils && g.trash === e.trash, `${who} en /${label}: «Nueva» ${g.nueva}/${e.nueva}, Editar ${g.pencils}/${e.pencils}, Eliminar ${g.trash}/${e.trash} (obtenido/esperado)`)
    }
  }
  // Las cuatro combinaciones para el observador y el vendedor (10.5)
  for (const who of ["viewer", "seller"]) {
    for (const [vp, w, h] of [["desktop", 1366, 800], ["mobile", 375, 812]]) {
      for (const scheme of ["light", "dark"]) {
        if (vp === "desktop" && scheme === "light") continue // ya tomada arriba
        const got = await visit(browser, who, { w, h, scheme, shotPrefix: `visual-${who}-${vp}-${scheme}` })
        const e = expectations[who]
        for (const label of ["ventas", "compras"]) {
          const g = got[label]
          ok(g.nueva === e[label].nueva && g.pencils === e[label].pencils && g.trash === e[label].trash, `[${vp}/${scheme}] ${who} en /${label}: «Nueva» ${g.nueva}, Editar ${g.pencils}, Eliminar ${g.trash}`)
        }
      }
    }
  }
} finally {
  await browser.close()
  mkdirSync(SHOTS, { recursive: true })
  writeFileSync(`${SHOTS}/humo-ui.log`, log.join("\n") + `\n\nRESULTADO: ${failed === 0 ? "TODO PASS" : failed + " FAIL"}\n`)
}
console.log(failed === 0 ? "\nTODO PASS" : `\n${failed} FAIL`)
process.exit(failed === 0 ? 0 : 1)
