// Pasada visual del remito de COMPRA (tanda A): desktop 1280 y móvil 375 x tema claro y oscuro. Stack LOCAL.
// Capturas en scratchpad-remitos-compra/capturas/<pantalla>-<viewport>-<tema>.png; desborde POR ELEMENTO; consola; foco y teclado en modales.
import { writeFileSync, readFileSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, COMBOS, measureOverflow, consoleCollector, OUT } from './pw-lib.mjs'
import { sql, check, results, USERS, login, be } from './lib.mjs'

const ROOT = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra'
const IDS = JSON.parse(readFileSync(`${ROOT}/ids.json`, 'utf8'))
const { accA, br1, br2, sup, sup2, alf, escaso, client } = IDS
const tok = await login(...USERS.owner)
const mkP = async (items, extra = {}) => (await be(tok, 'POST', '/delivery-notes', { direction: 'purchase', supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, items, ...extra }, { 'Idempotency-Key': crypto.randomUUID() })).body
const line = (pid, q, price) => ({ product_id: pid, quantity: q, price, subtotal: q * price })

// datos de la pasada: un remito pendiente con varias líneas (una sin precio), uno anulado, uno con mercadería consumida,
// y una sucursal (Norte) con pendientes de AMBOS sentidos.
const multi = (await mkP([line(alf, 4, 250), line(IDS.harina, 2.5, 700), line(IDS.sinCosto, 3, 0)], { supplier_reference: '0004-00009999', notes: 'Pasada visual' })).id
const toCancel = await mkP([line(alf, 1, 250)])
await be(tok, 'POST', `/delivery-notes/${toCancel.id}/cancel`, { revision: 1, reason: 'Anulado para la pasada visual' })
sql(`update branch_stock set quantity=0 where product_id='${escaso}' and branch_id='${br1}'`)
const consumed = await mkP([line(escaso, 6, 100)])
const pm = sql(`select id from payment_methods where account_id='${accA}' and kind='other' and deleted_at is null limit 1`)
await be(tok, 'POST', '/sales-orders/quick-sale', { items: [{ product_id: escaso, quantity: 4, price: 300 }], payment_method: 'other', payment_method_id: pm || undefined, branch_id: br1 }, { 'Idempotency-Key': crypto.randomUUID() })
const norteBuy = await mkP([line(alf, 2, 250)], { branch_id: br2, supplier_id: sup2 })
await be(tok, 'POST', '/delivery-notes', { client_id: client, branch_id: br2, items: [line(alf, 1, 500)] }, { 'Idempotency-Key': crypto.randomUUID() })
const issued = multi, canceled = toCancel.id
const report = []
const browser = await chromium.launch()
const AUTH = `${ROOT}/qa-auth-owner.json`
await uiLogin(browser, ...USERS.owner, AUTH)

async function open(page, path, ready) {
  await page.goto(BASE + path, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
  if (ready) await ready(page)
  await page.waitForTimeout(1200)
}
async function snap(page, name, vp, th, errs, note = '') {
  await page.waitForTimeout(400)
  await page.screenshot({ path: `${OUT}/${name}-${vp}-${th}.png` })
  const ov = await measureOverflow(page)
  // Scrollers horizontales PREEXISTENTES (panel de movimientos de /stock, min-w-[420px]; tablas de /compras y de /proveedores):
  // no los toca este change; se informan aparte, no cuentan como desborde propio.
  const PRE = ['stock-movimientos-remito-compra', 'compras-form']
  const pre = PRE.includes(name) ? ov.issues.filter((i) => i.kind === 'scroller') : []
  const own = ov.issues.filter((i) => !pre.includes(i))
  if (pre.length) console.log(`   (preexistente, no propio) ${name} ${vp}: scroller ${JSON.stringify(pre.map((i) => `${i.scrollW}>${i.clientW}`))}`)
  const bad = ov.docOverflow > 1 || own.length > 0
  report.push({ name, vp, th, docOverflow: ov.docOverflow, elementOverflow: ov.count, issues: ov.issues, note })
  check(`desborde 0: ${name} ${vp} ${th}`, !bad, bad ? JSON.stringify({ doc: ov.docOverflow, issues: own.slice(0, 3) }) : '')
}

const only = process.argv[2] ? new RegExp(process.argv[2]) : null
for (const [vp, th] of COMBOS.filter(([v, t]) => !only || only.test(`${v}-${t}`))) {
  const ctx = await newCtx(browser, vp, th, AUTH)
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  await open(page, '/remitos?sentido=compra')
  await snap(page, 'compra-listado', vp, th, errs)
  await open(page, `/remitos?sentido=compra&estado=pendientes&sucursal=${br1}&proveedor=${sup}`)
  await snap(page, 'compra-listado-filtros-chips', vp, th, errs)
  await open(page, '/remitos/nuevo?tipo=compra', async (p) => { await p.getByRole('combobox', { name: /Proveedor/ }).waitFor({ timeout: 90000 }) })
  await snap(page, 'compra-nuevo-vacio', vp, th, errs)
  // con una línea cargada y el proveedor elegido
  await page.getByRole('combobox', { name: /Proveedor/ }).click()
  await page.waitForTimeout(800)
  await page.getByRole('option', { name: /Proveedor Demo QA/ }).first().click({ force: true })
  await page.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.waitForTimeout(800)
  await page.getByRole('option', { name: /Sin costo QA/ }).first().click({ force: true })
  await page.getByLabel(/^(Cantidad|Peso|Kilos|Cant\.)/).first().fill('2')
  await page.getByRole('button', { name: 'Agregar al remito' }).click()
  await snap(page, 'compra-nuevo-con-linea-sin-precio', vp, th, errs)
  await open(page, `/remitos/${multi}/editar`, async (p) => { await p.getByRole('button', { name: 'Guardar cambios' }).waitFor({ timeout: 90000 }) })
  await snap(page, 'compra-editar', vp, th, errs)
  await open(page, `/remitos/${issued}`)
  await snap(page, 'compra-detalle-pendiente', vp, th, errs)
  await open(page, `/remitos/${canceled}`)
  await snap(page, 'compra-detalle-anulado', vp, th, errs)
  // diálogo de anulación (con motivo) y rechazo por mercadería consumida
  await open(page, `/remitos/${issued}`)
  await page.getByRole('button', { name: 'Anular' }).waitFor({ timeout: 90000 })
  await page.getByRole('button', { name: 'Anular' }).click()
  await page.getByRole('dialog').waitFor()
  await page.getByLabel(/Motivo/).fill('Motivo de prueba para la captura')
  await snap(page, 'compra-anular-dialogo', vp, th, errs)
  await page.keyboard.press('Escape')
  await open(page, `/remitos/${consumed.id}`)
  await page.getByRole('button', { name: 'Anular' }).click()
  const dd = page.getByRole('dialog')
  await dd.waitFor()
  await dd.getByLabel(/Motivo/).fill('Anular con mercadería vendida')
  await dd.getByRole('button', { name: /Anular remito|Anular/ }).last().click()
  await page.getByRole('alert', { name: /Mercadería consumida/ }).first().waitFor({ timeout: 30000 })
  await snap(page, 'compra-anular-rechazo-consumida', vp, th, errs)
  await page.keyboard.press('Escape')
  // proveedores
  await open(page, '/proveedores')
  await snap(page, 'proveedores-listado', vp, th, errs)
  if (vp === 'mobile') {
    const labels = await page.locator('main a[aria-label], main button[aria-label]').evaluateAll((els) => els.filter((e) => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden').map((e) => e.getAttribute('aria-label')))
    const dups = labels.filter((l, i) => labels.indexOf(l) !== i)
    check(`/proveedores ${th}: aria-label distintos en botones de ícono (375 px)`, dups.length === 0 && labels.some((l) => /remito/i.test(l ?? '')), labels.slice(0, 8).join(' | '))
  }
  await open(page, `/proveedores/${sup}/cuenta`)
  await snap(page, 'proveedor-cuenta-cabecera', vp, th, errs)
  // panel de movimientos de /stock
  await open(page, '/stock')
  await page.getByText('Historial de movimientos').first().click()
  await page.getByText(/Remito RC-\d{8}/).first().waitFor({ timeout: 60000 })
  await page.getByText(/Remito RC-\d{8}/).first().scrollIntoViewIfNeeded()
  await snap(page, 'stock-movimientos-remito-compra', vp, th, errs)
  // baja de sucursal con pendientes de los dos sentidos
  await open(page, '/sucursales')
  await page.getByRole('button', { name: /Desactivar Sucursal Norte QA/ }).click()
  const ad = page.getByRole('alertdialog')
  await ad.waitFor()
  await ad.getByRole('link', { name: /Ver remitos/ }).first().waitFor({ timeout: 30000 }).catch(() => {})
  await page.waitForTimeout(800)
  const links = await ad.getByRole('link').evaluateAll((els) => els.map((e) => e.getAttribute('href')))
  check(`baja de sucursal ${vp} ${th}: un enlace por sentido (&sentido=venta y &sentido=compra)`, links.some((h) => /sentido=venta/.test(h ?? '')) && links.some((h) => /sentido=compra/.test(h ?? '')), links.join(' | '))
  await snap(page, 'sucursales-baja-remitos-ambos-sentidos', vp, th, errs)
  await page.keyboard.press('Escape')
  // formulario de compra (sin cambios visibles tras la extracción de SupplierSelect)
  await open(page, '/compras')
  await snap(page, 'compras-form', vp, th, errs)
  const real = errs.filter((e) => !/status of 40[049]/.test(e))
  check(`consola sin errores (${vp} ${th}; los 404/409 de red esperados aparte)`, real.length === 0, real.join(' | ').slice(0, 300))
  await ctx.close()
}

// foco y teclado en los modales (desktop claro)
{
  const ctx = await newCtx(browser, 'desktop', 'light', AUTH)
  const page = await ctx.newPage()
  await open(page, `/remitos/${issued}`)
  const trigger = page.getByRole('button', { name: 'Anular' })
  await trigger.focus()
  await page.keyboard.press('Enter')
  const dlg = page.getByRole('dialog')
  await dlg.waitFor()
  await page.waitForTimeout(400)
  const inside = () => page.evaluate(() => !!document.activeElement?.closest('[role=dialog]'))
  check('anular (compra): al abrir, el foco queda dentro del diálogo', await inside())
  let trapped = true
  for (let i = 0; i < 8; i++) { await page.keyboard.press('Tab'); if (!(await inside())) trapped = false }
  check('anular (compra): Tab no escapa del diálogo (8 Tab)', trapped)
  await page.keyboard.press('Escape')
  await page.waitForTimeout(500)
  check('anular (compra): Escape cierra', (await dlg.count()) === 0)
  const back = await page.evaluate(() => (document.activeElement?.textContent ?? '').trim())
  check('anular (compra): al cerrar, el foco vuelve al botón "Anular"', /Anular/.test(back), back)
  // el nuevo formulario es operable con teclado: el selector de proveedor abre con Enter y elige con flechas+Enter
  await open(page, '/remitos/nuevo?tipo=compra', async (p) => { await p.getByRole('combobox', { name: /Proveedor/ }).waitFor({ timeout: 90000 }) })
  await page.getByRole('combobox', { name: /Proveedor/ }).focus()
  await page.keyboard.press('Enter')
  await page.getByRole('option').first().waitFor({ timeout: 15000 })
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('Enter')
  await page.waitForTimeout(500)
  const shown = await page.getByRole('combobox', { name: /Proveedor/ }).innerText()
  check('proveedor: se elige con teclado (Enter, flechas, Enter)', !/Seleccionar proveedor/.test(shown), shown)
  // baja de sucursal
  await open(page, '/sucursales')
  await page.getByRole('button', { name: /Desactivar Sucursal Norte QA/ }).focus()
  await page.keyboard.press('Enter')
  await page.getByRole('alertdialog').waitFor()
  await page.waitForTimeout(400)
  const insideA = () => page.evaluate(() => !!document.activeElement?.closest('[role=alertdialog]'))
  check('baja de sucursal: foco dentro del diálogo al abrir', await insideA())
  let trappedA = true
  for (let i = 0; i < 6; i++) { await page.keyboard.press('Tab'); if (!(await insideA())) trappedA = false }
  check('baja de sucursal: Tab no escapa', trappedA)
  await page.keyboard.press('Escape')
  await page.waitForTimeout(400)
  check('baja de sucursal: Escape cierra', (await page.getByRole('alertdialog').count()) === 0)
  await ctx.close()
}

writeFileSync(`${ROOT}/visual-report.json`, JSON.stringify(report, null, 1))
const failed = results.filter(([, ok]) => !ok)
console.log(`RESUMEN visual: ${results.length - failed.length}/${results.length} PASS`)
if (failed.length) console.log('FALLAN:', failed.map(([n]) => n).join(' | '))
await browser.close()
