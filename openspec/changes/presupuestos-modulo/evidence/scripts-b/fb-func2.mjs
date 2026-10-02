// (j) cajero sin botón Venta; (l) regresión: venta manual por el formulario y por el POS. Stack LOCAL.
import { chromium, BASE, newCtx, login as uiLogin, consoleCollector, AUTH } from './pwb-lib.mjs'
import { login, USERS, results } from './lib-b.mjs'
import { IDS, A, P, mkQuote, stdItems, ensureSession, pwShot, check, sql, stock, cashCount } from './fbh.mjs'
import { existsSync } from 'node:fs'

const only = process.argv[2] ? new RegExp(process.argv[2]) : null
const run = (id) => !only || only.test(id)
const tok = await login(...USERS.owner)
const browser = await chromium.launch()
const report = []

// ------------------------------------------------------------ (j) cajero
if (run('j')) {
  const CASH = 'C:/Users/Usuario/Desktop/EIE/scratchpad-presupuestos/qa-auth-cashier.json'
  await uiLogin(browser, ...USERS.cashier, CASH)
  const q = await mkQuote(tok, stdItems())
  const ctx = await newCtx(browser, 'desktop', 'light', CASH)
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  const shot = pwShot(page, report)
  await page.goto(`${BASE}/presupuestos/${q.id}`, { waitUntil: 'domcontentloaded', timeout: 120000 })
  await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 60000 })
  await page.waitForTimeout(1500)
  const venta = await page.getByRole('button', { name: 'Venta', exact: true }).count()
  check('(j) cajero: sin botón Venta en el detalle', venta === 0, `botones=${venta}`)
  const edit = await page.getByRole('link', { name: /Editar/ }).count() + await page.getByRole('button', { name: /Editar/ }).count()
  check('(j) cajero: sin Editar (sólo lectura)', edit === 0, `editar=${edit}`)
  await shot('detalle-cajero-sin-venta', 'desktop', 'light')
  check('(j) consola sin errores', errs.length === 0, errs.join('|').slice(0, 200))
  await ctx.close()
}

// ------------------------------------------------------------ (l) formulario de venta
if (run('l1')) {
  await ensureSession(tok)
  const ctx = await newCtx(browser, 'desktop', 'light')
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  const shot = pwShot(page, report)
  const [sa, so] = [stock(P.alf), Number(sql(`select count(*) from sales where account_id='${A}'`))]
  await page.goto(`${BASE}/ventas`, { waitUntil: 'domcontentloaded', timeout: 120000 })
  await page.getByRole('button', { name: /Nueva venta/ }).first().click()
  const d = page.getByRole('dialog')
  await d.getByText('Agregar producto', { exact: false }).first().waitFor({ timeout: 30000 })
  await d.getByRole('combobox', { name: /Sucursal|Sin sucursal/ }).first().click().catch(async () => { await d.getByText('Sin sucursal (general)').first().click() })
  await page.getByRole('option', { name: 'Casa Central' }).click()
  await d.getByRole('combobox').filter({ hasText: 'Seleccionar cliente' }).click()
  await page.getByRole('option', { name: /Cliente Demo QA/ }).first().click()
  await d.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.getByRole('option', { name: /Alfajor artesanal/ }).first().click()
  await d.getByRole('button', { name: 'Agregar al carrito' }).click()
  await shot('l-form-venta-carrito', 'desktop', 'light')
  await d.getByRole('button', { name: /Confirmar venta/ }).click()
  await page.waitForTimeout(6000)
  await shot('l-form-venta-resultado', 'desktop', 'light')
  console.log('dialog visible:', await d.isVisible(), '| toasts:', (await page.locator('[data-sonner-toast]').allInnerTexts()).join(' / '))
  const so2 = Number(sql(`select count(*) from sales where account_id='${A}'`))
  check('(l) formulario de venta: se registra la venta', so2 === so + 1, `${so}->${so2}`)
  check('(l) formulario de venta: baja el stock de la sucursal elegida', stock(P.alf) === sa - 1, `${sa}->${stock(P.alf)}`)
  check('(l) formulario de venta: consola sin errores', errs.length === 0, errs.join('|').slice(0, 250))
  await ctx.close()
}
// ------------------------------------------------------------ (l) POS
if (run('l2')) {
  await ensureSession(tok)
  const ctx = await newCtx(browser, 'desktop', 'light')
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  const shot = pwShot(page, report)
  const [sa, so, cc] = [stock(P.alf), Number(sql(`select count(*) from sales where account_id='${A}'`)), cashCount()]
  await page.goto(`${BASE}/ventas/pos`, { waitUntil: 'domcontentloaded', timeout: 120000 })
  await page.getByRole('button', { name: 'Efectivo' }).waitFor({ timeout: 60000 })
  await page.getByText(/Caja abierta/).waitFor({ timeout: 30000 })
  await page.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.getByRole('option', { name: /Alfajor artesanal/ }).first().click()
  await page.getByRole('button', { name: 'Agregar al carrito' }).click()
  await shot('l-pos-carrito', 'desktop', 'light')
  await page.getByRole('button', { name: /^Cobrar/ }).click()
  await page.waitForTimeout(6000)
  await shot('l-pos-resultado', 'desktop', 'light')
  check('(l) POS: se registra la venta', Number(sql(`select count(*) from sales where account_id='${A}'`)) === so + 1, `${so}`)
  check('(l) POS: baja el stock', stock(P.alf) === sa - 1, `${sa}->${stock(P.alf)}`)
  check('(l) POS: movimiento de caja en efectivo', cashCount() === cc + 1, `${cc}->${cashCount()}`)
  check('(l) POS: consola sin errores', errs.length === 0, errs.join('|').slice(0, 250))
  await ctx.close()
}
console.log(`\nRESUMEN: ${results.filter((r) => r[1]).length} PASS / ${results.filter((r) => !r[1]).length} FAIL`)
await browser.close()
