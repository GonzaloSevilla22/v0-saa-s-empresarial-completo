// Pasada visual de la tanda B en las 4 combinaciones (desktop 1280 / móvil 375 x claro / oscuro). Stack LOCAL.
import { chromium, BASE, COMBOS, newCtx, consoleCollector, login as uiLogin, AUTH } from './pwb-lib.mjs'
import { login, USERS, results } from './lib-b.mjs'
import { writeFileSync } from 'node:fs'
import {
  IDS, A, P, KG, item, mkQuote, stdItems, ensureSession, closeSession, pickPaymentMethod, pickBank,
  pwShot, check, sql, be, isoIn,
} from './fbh.mjs'
import { existsSync } from 'node:fs'

const tok = await login(...USERS.owner)
const browser = await chromium.launch()
if (!existsSync(AUTH)) await uiLogin(browser, ...USERS.owner)
const report = []
const allErrs = []
const only = process.argv[2] ? process.argv[2].split(',') : null

for (const [vp, theme] of COMBOS) {
  if (only && !only.includes(`${vp}-${theme}`)) continue
  console.log(`\n=== ${vp} / ${theme} ===`)
  const ctx = await newCtx(browser, vp, theme)
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  const shot = pwShot(page, report)
  const dlg = () => page.getByRole('dialog')
  const go = async (path) => { await page.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 120000 }) }
  const openDetail = async (id) => { await go(`/presupuestos/${id}`); await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 60000 }) }
  const openConvert = async () => {
    await page.getByRole('button', { name: 'Venta', exact: true }).click()
    await dlg().getByText('Total a cobrar').waitFor({ timeout: 30000 })
  }
  const closeDlg = async () => { await page.keyboard.press('Escape'); await page.waitForTimeout(400) }

  // --- caja cerrada: Venta con efectivo bloqueada, con su motivo
  await closeSession(tok)
  const qBlock = await mkQuote(tok, stdItems())
  await openDetail(qBlock.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await shot('conv-dialog-caja-cerrada', vp, theme)
  const blocked = await dlg().getByRole('button', { name: 'Registrar venta' }).isDisabled()
  const reason = await dlg().getByText(/Abrí la caja de esta sucursal/).count()
  check(`[${vp}/${theme}] caja cerrada: confirmar deshabilitado con su motivo`, blocked && reason > 0, `disabled=${blocked} motivo=${reason}`)
  await closeDlg()

  // --- caja abierta: estados del formulario
  await ensureSession(tok)
  await openDetail(qBlock.id); await openConvert()
  await shot('conv-dialog-vacio', vp, theme)
  const focusInside = await page.evaluate(() => !!document.activeElement?.closest('[role="dialog"]'))
  check(`[${vp}/${theme}] el foco entra al diálogo`, focusInside)
  const disabledEmpty = await dlg().getByRole('button', { name: 'Registrar venta' }).isDisabled()
  check(`[${vp}/${theme}] sin forma de pago, confirmar deshabilitado`, disabledEmpty)
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await shot('conv-dialog-efectivo', vp, theme)
  await pickPaymentMethod(page, dlg(), /transferencia/i)
  await shot('conv-dialog-transferencia', vp, theme)
  await pickPaymentMethod(page, dlg(), /cuenta corriente|cr[eé]dito/i)
  await shot('conv-dialog-credito', vp, theme)
  // CTA visible dentro del viewport
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  const ctaBox = await dlg().getByRole('button', { name: 'Registrar venta' }).boundingBox()
  const vh = page.viewportSize().height
  check(`[${vp}/${theme}] CTA "Registrar venta" visible (dentro del viewport)`, ctaBox && ctaBox.y + ctaBox.height <= vh + 1, JSON.stringify(ctaBox))
  await closeDlg()
  const back = await page.evaluate(() => document.activeElement?.textContent?.trim())
  check(`[${vp}/${theme}] Escape devuelve el foco al botón Venta`, /Venta/.test(back || ''), String(back))

  // --- error de stock
  const qStock = await mkQuote(tok, [item(P.escaso, 5, 300), item(P.alf, 1, 500)])
  await openDetail(qStock.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByRole('alert').waitFor({ timeout: 60000 })
  await shot('conv-error-stock', vp, theme)
  const al = await dlg().getByRole('alert').textContent()
  check(`[${vp}/${theme}] error de stock con el producto, accionable`, /Producto escaso QA/.test(al), al)
  await closeDlg()

  // --- éxito
  const qOk = await mkQuote(tok, stdItems())
  await openDetail(qOk.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  await shot('conv-exito', vp, theme)
  const focusOnTitle = await page.evaluate(() => document.activeElement?.textContent?.trim())
  check(`[${vp}/${theme}] el foco pasa al título "Venta registrada"`, focusOnTitle === 'Venta registrada', String(focusOnTitle))
  const facturar = await dlg().getByRole('button', { name: /Facturar|Emitir comprobante/ }).count()
  check(`[${vp}/${theme}] "Facturar" ofrecido en el éxito`, facturar > 0)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  await page.waitForTimeout(500)
  await shot('detalle-convertido', vp, theme)
  await page.getByRole('region', { name: 'Venta generada' }).waitFor({ timeout: 30000 })

  // --- /ventas con el badge, y la línea de servicio con Editar deshabilitado
  const qSvc = await mkQuote(tok, [{ description: 'Flete a domicilio QA', quantity: 1, price: 800, subtotal: 800 }, item(P.alf, 2, 500)])
  await openDetail(qSvc.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /^otro/i)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  sql(`update sales set date = date + interval '1 day' where operation_id = (select sale_operation_id from sales_orders where source_quote_id='${qSvc.id}')`)
  await go('/ventas')
  const badge = page.getByRole('link', { name: /Desde presupuesto P-\d{8}/ }).first()
  await badge.waitFor({ timeout: 60000 })
  await shot('ventas-badge', vp, theme)
  await page.locator('[aria-expanded]').filter({ has: page.locator('button[title*="conceptos sin producto"]') }).filter({ visible: true }).first().click()
  await page.getByText('Flete a domicilio QA').filter({ visible: true }).first().waitFor({ timeout: 30000 })
  await shot('ventas-linea-servicio', vp, theme)

  // --- vencido
  const qEx = await mkQuote(tok, stdItems())
  sql(`update quotes set valid_until = current_date - 3 where id='${qEx.id}'`)
  await openDetail(qEx.id)
  const dis = await page.getByRole('button', { name: 'Venta', exact: true }).isDisabled()
  await shot('detalle-vencido-venta-deshabilitada', vp, theme)
  check(`[${vp}/${theme}] vencido: Venta deshabilitada con leyenda`, dis && (await page.getByText(/ampliá la validez o duplicalo/).count()) > 0)

  console.log('console errors:', errs.length ? errs.slice(0, 6) : 'ninguno')
  allErrs.push(...errs.map((e) => `[${vp}/${theme}] ${e}`))
  await ctx.close()
}
writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-presupuestos/visual-b-report.json', JSON.stringify({ report, allErrs }, null, 1))
const bad = report.filter((r) => r.docOverflow > 1 || r.overflowCount > 0)
console.log(`\nshots=${report.length} conDesborde=${bad.length}`)
console.log(`RESUMEN: ${results.filter((r) => r[1]).length} PASS / ${results.filter((r) => !r[1]).length} FAIL; consola con errores: ${allErrs.length}`)
await browser.close()
