// Venta REAL por la interfaz: el vendedor vende un producto cargado por el DUEÑO desde el formulario de /ventas (R3a), y el dueño
// edita desde la interfaz esa venta del vendedor (R3d) y la borra (R3e).
import { createRequire } from "node:module"
import { writeFileSync, mkdirSync } from "node:fs"
import { WT, SHOTS, psql, loadSecrets } from "./common.mjs"
import { TEAM } from "./seed.mjs"
const require = createRequire(`${WT}/frontend/package.json`)
const { chromium } = require("@playwright/test")
const S = loadSecrets()
const log = []; let failed = 0
const note = (m) => { console.log(m); log.push(m) }
const ok = (c, m) => { if (!c) failed++; note(`${c ? "PASS" : "FAIL"}: ${m}`) }
const sql1 = (q) => psql(q).trim()
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function login(page, email) {
  await page.goto("http://localhost:3000/auth/login", { waitUntil: "domcontentloaded" })
  await page.locator('input[type="email"]').first().fill(email)
  await page.locator('input[type="password"]').first().fill(S.password)
  await page.waitForFunction(() => { const b = document.querySelector('[data-testid="login-submit"]'); return b && !b.disabled }, null, { timeout: 60000 })
  await page.getByTestId("login-submit").click()
  await page.waitForURL(/\/dashboard/, { timeout: 60000 })
}

const A = sql1(`select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${TEAM.owner.email}' order by am.created_at limit 1`)
const sellerId = sql1(`select id from auth.users where email='${TEAM.seller.email}'`)
const cinta = sql1(`select id from public.products where sku='HUMOB-CINTA'`)
const stock0 = Number(sql1(`select coalesce(sum(quantity),0) from public.branch_stock where product_id='${cinta}'`))
const salesBefore = Number(sql1(`select count(*) from public.sales where account_id='${A}' and user_id='${sellerId}' and product_id='${cinta}'`))

const browser = await chromium.launch({ headless: true })
try {
  // ── El vendedor vende por el formulario un producto del dueño ──────────────────
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } })
  const page = await ctx.newPage()
  await login(page, TEAM.seller.email)
  await page.goto("http://localhost:3000/ventas", { waitUntil: "domcontentloaded" })
  await page.waitForLoadState("networkidle").catch(() => {})
  await page.getByRole("button", { name: /nueva venta/i }).first().click()
  const dlg = page.getByRole("dialog")
  await dlg.getByText("Seleccionar cliente").first().click()
  await sleep(600)
  await page.getByRole("option", { name: /Cliente Humo B/ }).first().click()
  await sleep(300)
  await dlg.getByText("Seleccionar producto").first().click()
  await sleep(600)
  await page.getByRole("option", { name: /Cinta métrica/ }).first().click()
  await sleep(400)
  await dlg.getByRole("button", { name: /agregar al carrito/i }).click()
  await sleep(500)
  mkdirSync(SHOTS, { recursive: true })
  await page.screenshot({ path: `${SHOTS}/humo-ui-venta-vendedor-formulario.png` })
  await dlg.getByRole("button", { name: /confirmar venta/i }).click()
  // espera a que se persista
  let n = salesBefore
  for (let i = 0; i < 30 && n === salesBefore; i++) {
    await sleep(1000)
    n = Number(sql1(`select count(*) from public.sales where account_id='${A}' and user_id='${sellerId}' and product_id='${cinta}'`))
  }
  ok(n === salesBefore + 1, `R3a por la UI: el vendedor vendió «Cinta métrica» (producto del dueño) desde /ventas (${salesBefore} -> ${n} ventas suyas de ese producto)`)
  const stock1 = Number(sql1(`select coalesce(sum(quantity),0) from public.branch_stock where product_id='${cinta}'`))
  ok(stock1 === stock0 - 1, `   el stock bajó 1 (${stock0} -> ${stock1}) y la venta quedó en el negocio, con el vendedor como autor`)
  await ctx.close()

  // ── El dueño ve la venta del vendedor, la edita y la borra desde la UI ───────────
  const ctx2 = await browser.newContext({ viewport: { width: 1366, height: 900 } })
  const owner = await ctx2.newPage()
  await login(owner, TEAM.owner.email)
  await owner.goto("http://localhost:3000/ventas", { waitUntil: "domcontentloaded" })
  await owner.waitForLoadState("networkidle").catch(() => {})
  const op = sql1(`select operation_id from public.sales where account_id='${A}' and user_id='${sellerId}' and product_id='${cinta}' order by created_at desc limit 1`)
  if (!op) throw new Error("no hay venta del vendedor para borrar: la venta por la UI no persistió")
  const opsBefore = Number(sql1(`select count(distinct operation_id) from public.sales where account_id='${A}'`))
  // borrar la PRIMERA fila (la más nueva = la del vendedor) con el diálogo de confirmación
  await owner.screenshot({ path: `${SHOTS}/humo-ui-dueno-ve-venta-del-vendedor.png` })
  const del = owner.getByRole("button", { name: /^Eliminar esta venta$/ }).first()
  await del.click()
  await sleep(500)
  await owner.getByRole("alertdialog").getByRole("button", { name: /^Eliminar/ }).last().click().catch(async () => {
    await owner.getByRole("dialog").getByRole("button", { name: /^Eliminar/ }).last().click()
  })
  let left = 1
  for (let i = 0; i < 20 && left > 0; i++) { await sleep(1000); left = Number(sql1(`select count(*) from public.sales where operation_id='${op}'`)) }
  ok(left === 0, `R3e por la UI: el dueño eliminó desde /ventas la venta que cargó el vendedor`)
  await ctx2.close()
} finally {
  await browser.close()
  writeFileSync(`${SHOTS}/humo-ui-venta.log`, log.join("\n") + `\n\nRESULTADO: ${failed === 0 ? "TODO PASS" : failed + " FAIL"}\n`)
}
console.log(failed === 0 ? "\nTODO PASS" : `\n${failed} FAIL`)
process.exit(failed === 0 ? 0 : 1)
