// Pasada visual de la tanda B en las 4 combinaciones (desktop 1280 / móvil 375 x claro / oscuro). Stack LOCAL.
// Capturas en scratchpad-remitos/capturas-b/<pantalla>-<viewport>-<tema>.png. Desborde medido POR ELEMENTO.
import { existsSync, writeFileSync } from 'node:fs'
import { chromium, BASE, COMBOS, newCtx, consoleCollector, login as uiLogin } from './pw-b.mjs'
import {
  IDS, A, br1, client, harina, alf, line, mkDn, ensureSession, closeSession, pickPaymentMethod, pickBank, pwShot,
  dnLabel, dnRev, liveOrderOfDn, sql, be, login, USERS, check, results,
} from './hb.mjs'

const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos'
const AUTH = `${SP}/qa-auth-owner.json`
const tok = await login(...USERS.owner)
const browser = await chromium.launch()
if (!existsSync(AUTH)) await uiLogin(browser, ...USERS.owner, AUTH)
const report = []
const allErrs = []
const only = process.argv[2] ? process.argv[2].split(',') : null
const KG = sql(`select id from units_of_measure where account_id='${A}' and symbol='kg'`)

for (const [vp, theme] of COMBOS) {
  if (only && !only.includes(`${vp}-${theme}`)) continue
  console.log(`\n=== ${vp} / ${theme} ===`)
  const ctx = await newCtx(browser, vp, theme, AUTH)
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  const failedReqs = []
  page.on('response', (r) => { if (r.status() >= 400) failedReqs.push(`${r.status()} ${r.request().method()} ${r.url().replace(/\?.*/, '').slice(-70)}`) })
  const shot = pwShot(page, report)
  const dlg = () => page.getByRole('dialog')
  const go = async (path) => {
    await page.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 120000 })
    await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 60000 })
  }
  const openConvert = async () => {
    await page.getByRole('button', { name: 'Venta', exact: true }).click()
    await dlg().getByText('Total a cobrar').waitFor({ timeout: 30000 })
  }
  const closeDlg = async () => { await page.keyboard.press('Escape'); await page.waitForTimeout(400) }
  const registrar = () => dlg().getByRole('button', { name: 'Registrar venta' })
  const tag = `[${vp}/${theme}]`

  // --- remito pendiente: detalle con el CTA Venta visible
  await ensureSession(tok)
  const dnA = await mkDn(tok)
  await go(`/remitos/${dnA.id}`)
  const venta = page.getByRole('button', { name: 'Venta', exact: true })
  await shot('remito-pendiente-con-venta', vp, theme)
  const vb = await venta.boundingBox()
  check(`${tag} CTA "Venta" del detalle visible dentro del viewport`, vb && vb.y + vb.height <= page.viewportSize().height + 1 && vb.x >= 0 && vb.x + vb.width <= page.viewportSize().width + 1, JSON.stringify(vb))

  // --- caja cerrada: efectivo bloqueado con su motivo
  await closeSession(tok)
  await go(`/remitos/${dnA.id}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await shot('conv-dialogo-caja-cerrada', vp, theme)
  check(`${tag} caja cerrada: confirmar deshabilitado con su motivo`, (await registrar().isDisabled()) && (await dlg().getByText(/Abrí la caja de esta sucursal/).count()) > 0)
  await closeDlg()

  // --- caja abierta: estados del diálogo
  await ensureSession(tok)
  await go(`/remitos/${dnA.id}`)
  await openConvert()
  await shot('conv-dialogo-vacio', vp, theme)
  check(`${tag} el foco entra al diálogo`, await page.evaluate(() => !!document.activeElement?.closest('[role="dialog"]')))
  check(`${tag} sin forma de pago, confirmar deshabilitado`, await registrar().isDisabled())
  check(`${tag} sin selector de sucursal: la del remito va fija`, (await dlg().getByRole('combobox', { name: /Sucursal/ }).count()) === 0)
  check(`${tag} línea fija "El stock ya se descontó al emitir el remito"`, (await dlg().getByText(/El stock ya se descontó al emitir el remito R-\d{8}/).count()) === 1)
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await shot('conv-dialogo-efectivo', vp, theme)
  await pickPaymentMethod(page, dlg(), /transferencia/i)
  if ((await dlg().getByLabel(/cuenta/i).count()) > 0) await pickBank(page, dlg())
  await shot('conv-dialogo-transferencia', vp, theme)
  sql(`update clients set payment_terms_days=30 where id='${client}'`)
  await pickPaymentMethod(page, dlg(), /cuenta corriente|cr[eé]dito/i)
  await dlg().getByText(/Saldo actual/).waitFor({ timeout: 15000 }).catch(() => {})
  await shot('conv-dialogo-credito', vp, theme)
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  const cta = await registrar().boundingBox()
  check(`${tag} CTA "Registrar venta" visible dentro del viewport`, cta && cta.y + cta.height <= page.viewportSize().height + 1, JSON.stringify(cta))
  // Tab no escapa del diálogo
  let escaped = false
  for (let i = 0; i < 12; i++) { await page.keyboard.press('Tab'); if (!(await page.evaluate(() => !!document.activeElement?.closest('[role="dialog"]')))) { escaped = true; break } }
  check(`${tag} Tab no escapa del diálogo (12 pulsaciones)`, !escaped)
  await closeDlg()
  const back = await page.evaluate(() => document.activeElement?.textContent?.trim())
  check(`${tag} Escape devuelve el foco al botón Venta`, /Venta/.test(back || ''), String(back))

  // --- el remito cambió: error accionable y resumen recargado
  const dnC = await mkDn(tok)
  await go(`/remitos/${dnC.id}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await be(tok, 'PUT', `/delivery-notes/${dnC.id}`, { revision: dnC.revision, client_id: client, branch_id: br1, delivery_address: null, notes: 'editado en otra pestaña', items: [line(harina, 2.5, 1200, { unit_id: KG }), line(alf, 5, 500)] })
  await registrar().click()
  await dlg().getByRole('alert').waitFor({ timeout: 60000 })
  await shot('conv-dialogo-error-cambio', vp, theme)
  const al = await dlg().getByRole('alert').textContent()
  check(`${tag} error "el remito cambió" accionable`, /cambi|modific/i.test(al), al)
  await closeDlg()

  // --- éxito
  const dnOk = await mkDn(tok)
  await go(`/remitos/${dnOk.id}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await registrar().click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  await shot('conv-exito', vp, theme)
  const focusOn = await page.evaluate(() => document.activeElement?.textContent?.trim())
  check(`${tag} el foco pasa al título "Venta registrada"`, focusOn === 'Venta registrada', String(focusOn))
  check(`${tag} "Facturar" ofrecido en el éxito`, (await dlg().getByRole('button', { name: /Facturar|Emitir comprobante/ }).count()) > 0)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  await page.getByRole('region', { name: 'Venta generada' }).waitFor({ timeout: 30000 })
  await shot('remito-convertido-detalle', vp, theme)
  check(`${tag} detalle convertido: "Ver venta" presente`, (await page.getByRole('link', { name: 'Ver venta' }).count()) === 1)

  // --- /ventas: badge, Editar bloqueado y diálogo de borrado
  // el listado ordena por fecha y pagina: se adelanta un día la venta para que caiga en la 1ª página
  sql(`update sales set date = date + interval '1 day' where operation_id = (select sale_operation_id from sales_orders where source_delivery_note_id='${dnOk.id}' and status<>'canceled')`)
  await go('/ventas')
  const badge = page.getByRole('link', { name: new RegExp(`Desde remito ${dnLabel(dnOk.id)}`) }).filter({ visible: true }).first()
  await badge.waitFor({ timeout: 60000 })
  await shot('ventas-badge-desde-remito', vp, theme)
  const row = badge.locator("xpath=ancestor::*[.//button[@data-testid='delete-operation-trigger']][1]")
  const locked = row.locator('button[disabled][title*="remito"]').filter({ visible: true })
  check(`${tag} "Editar" deshabilitado con el motivo del remito`, (await locked.count()) > 0, String(await locked.count()))
  await row.locator("[data-testid='delete-operation-trigger']").filter({ visible: true }).first().click()
  const ad = page.getByRole('alertdialog')
  await ad.waitFor({ timeout: 30000 })
  await shot('ventas-borrar-dialogo-remito', vp, theme)
  const t = await ad.innerText()
  check(`${tag} el diálogo de borrado trae la línea de D9 con el número del remito`, new RegExp(`El stock no vuelve: la mercadería quedó entregada con el remito ${dnLabel(dnOk.id)}`).test(t), t.slice(0, 200))
  const delBox = await ad.getByRole('button', { name: /^Eliminar$/ }).boundingBox()
  check(`${tag} botón "Eliminar" del diálogo visible dentro del viewport`, delBox && delBox.y + delBox.height <= page.viewportSize().height + 1, JSON.stringify(delBox))
  await closeDlg()

  // --- cliente dado de baja: Venta deshabilitada con motivo
  const dnD = await mkDn(tok, [line(alf, 1, 500)], { client_id: IDS.client2 })
  sql(`update clients set deleted_at=now() where id='${IDS.client2}'`)
  await go(`/remitos/${dnD.id}`)
  const dis = await page.getByRole('button', { name: 'Venta', exact: true }).isDisabled()
  await shot('remito-cliente-baja-venta-deshabilitada', vp, theme)
  check(`${tag} cliente dado de baja: Venta deshabilitada con leyenda`, dis && (await page.getByText(/cliente.*baja|elegí un cliente vigente/i).count()) > 0)
  sql(`update clients set deleted_at=null where id='${IDS.client2}'`)

  console.log('console errors:', errs.length ? errs.slice(0, 6) : 'ninguno')
  console.log('respuestas >=400:', [...new Set(failedReqs)].slice(0, 8))
  allErrs.push(...errs.map((e) => `${tag} ${e}`))
  await ctx.close()
}
writeFileSync(`${SP}/visual-b-report.json`, JSON.stringify({ report, allErrs }, null, 1))
const bad = report.filter((r) => r.docOverflow > 1 || r.overflowCount > 0)
console.log(`\nshots=${report.length} conDesborde=${bad.length}`)
console.log(`RESUMEN: ${results.filter((r) => r[1]).length} PASS / ${results.filter((r) => !r[1]).length} FAIL; consola con errores: ${allErrs.length}`)
await browser.close()
