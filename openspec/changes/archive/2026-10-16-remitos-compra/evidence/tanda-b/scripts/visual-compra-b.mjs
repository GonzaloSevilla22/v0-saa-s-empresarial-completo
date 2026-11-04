// Verificación visual de la TANDA B de remitos-compra en 4 combinaciones: desktop 1280 y móvil 375 × claro y oscuro.
// Stack LOCAL. Por combinación: detalle del remito pendiente y convertido, ConvertPurchaseDeliveryNoteDialog en todos sus
// estados, /compras (badge, Editar bloqueado, diálogo de borrado con la línea D9), botón Compra deshabilitado con motivo y el
// aviso contra la doble suma. Mide desborde POR ELEMENTO (también dentro del diálogo), foco/teclado y consola.
// Uso: node visual-compra-b.mjs [desktop-light|desktop-dark|mobile-light|mobile-dark]
import { existsSync, writeFileSync } from 'node:fs'
import { chromium, BASE, COMBOS, newCtx, login as uiLogin, consoleCollector, OUT } from './pw-lib.mjs'
import { SP, br1, br2, harina, alf, sinCosto, sup, kg, dnLabel, dnRev, mkDn, line, ensureSession, pickPaymentMethod, pwShot, check, sql, be, login, USERS, results } from './hb.mjs'

const only = process.argv[2] ?? null
const tok = await login(...USERS.owner)
const browser = await chromium.launch()
const AUTH = `${SP}/qa-auth-owner.json`
if (!existsSync(AUTH)) await uiLogin(browser, ...USERS.owner, AUTH)
await ensureSession(tok)
const report = []

// desborde dentro del diálogo / hoja: ningún hijo visible pasa el borde del contenedor ni del viewport
async function measureDialog(page) {
  return await page.evaluate(() => {
    const dlg = document.querySelector('[role="dialog"], [role="alertdialog"]')
    if (!dlg) return { found: false, issues: [] }
    const vw = document.documentElement.clientWidth
    const dr = dlg.getBoundingClientRect()
    const issues = []
    const scrolls = (el) => ['auto', 'scroll'].includes(getComputedStyle(el).overflowX)
    for (const el of dlg.querySelectorAll('*')) {
      const s = getComputedStyle(el), r = el.getBoundingClientRect()
      if (s.display === 'none' || s.visibility === 'hidden' || r.width === 0 || r.height === 0) continue
      let p = el.parentElement, inScroller = false
      while (p && p !== dlg) { if (scrolls(p)) { inScroller = true; break } p = p.parentElement }
      if (inScroller) continue
      if (r.right > Math.min(dr.right, vw) + 1.5) issues.push({ tag: el.tagName, text: (el.textContent || '').trim().slice(0, 40), right: Math.round(r.right), limit: Math.round(Math.min(dr.right, vw)) })
    }
    return { found: true, dialogWidth: Math.round(dr.width), vw, issues: issues.slice(0, 6), count: issues.length }
  })
}
async function shotDialog(page, name, vp, th) {
  await page.waitForTimeout(500)
  await page.screenshot({ path: `${OUT}/${name}-${vp}-${th}.png` })
  const m = await measureDialog(page)
  const ov = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  report.push({ name, viewport: vp, theme: th, dialog: m, docOverflow: ov })
  const flag = (m.count ?? 0) > 0 || ov > 1 ? '  <<< DESBORDE' : ''
  console.log(`shot ${name}-${vp}-${th} dialogOverflow=${m.count ?? 'n/a'} docOverflow=${ov}${flag}`)
  if (flag) console.log('   ', JSON.stringify(m.issues))
  check(`${name} (${vp}/${th}): sin desborde propio dentro del diálogo ni del documento`, (m.count ?? 0) === 0 && ov <= 1, JSON.stringify(m.issues.slice(0, 2)))
}

for (const [vp, th] of COMBOS) {
  if (only && only !== `${vp}-${th}`) continue
  const ctx = await newCtx(browser, vp, th, AUTH)
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  const shot = pwShot(page, report)
  const dlg = () => page.getByRole('dialog')
  const go = async (path) => {
    await page.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 180000 })
    await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
  }
  const registrar = () => dlg().getByRole('button', { name: 'Registrar compra' })
  console.log(`\n══ ${vp} / ${th}`)

  // 1. detalle pendiente + diálogo vacío
  const r1 = await mkDn(tok)
  await go(`/remitos/${r1.id}`)
  await shot('b-detalle-pendiente', vp, th)
  const compra = page.getByRole('button', { name: 'Compra', exact: true })
  await compra.click()
  await dlg().getByText('Total de la compra').waitFor({ timeout: 30000 })
  await shotDialog(page, 'b-dialogo-vacio', vp, th)
  check(`(${vp}/${th}) diálogo vacío: "Registrar compra" deshabilitado y el motivo es su descripción accesible`, (await registrar().isDisabled()) && /Elegí la forma de pago/.test((await registrar().getAttribute('aria-describedby').then((id) => id ? page.locator(`[id="${id}"]`).innerText() : '')) ?? ''))

  // 2. efectivo con caja (pre-marcado)
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await dlg().getByRole('checkbox').first().waitFor({ timeout: 20000 })
  check(`(${vp}/${th}) efectivo con caja abierta: "Registrar en caja" pre-marcado`, await dlg().getByRole('checkbox').isChecked())
  // el texto de apoyo del efectivo ya no dice que no mueve caja (hallazgo del humo 8.3)
  check(`(${vp}/${th}) el texto de apoyo de efectivo habla de la caja abierta y no dice "No genera ningún movimiento de caja"`, /se registra en la caja abierta/.test(await dlg().innerText()) && !/No genera ningún movimiento de caja/.test(await dlg().innerText()))
  await shotDialog(page, 'b-dialogo-efectivo-caja', vp, th)

  // 3. transferencia con cuenta bancaria
  await pickPaymentMethod(page, dlg(), /transferencia/i)
  await shotDialog(page, 'b-dialogo-transferencia', vp, th)

  // 4. crédito con saldo y vencimiento
  await pickPaymentMethod(page, dlg(), /cuenta corriente/i)
  await shotDialog(page, 'b-dialogo-credito', vp, th)
  check(`(${vp}/${th}) crédito: saldo actual, saldo proyectado y vencimiento del plazo del proveedor`, /Saldo actual/.test(await dlg().innerText()) && (await dlg().getByLabel('Vencimiento').inputValue()) !== '')

  // 5. teclado y foco: el foco ENTRA al diálogo, Tab no escapa, Escape cierra y el foco vuelve a "Compra"
  const insideDialog = () => page.evaluate(() => !!document.activeElement?.closest('[role="dialog"]'))
  check(`(${vp}/${th}) al abrir el diálogo el foco queda DENTRO del diálogo`, await insideDialog())
  let escaped = 0
  for (let i = 0; i < 24; i++) { await page.keyboard.press('Tab'); if (!(await insideDialog())) escaped++ }
  for (let i = 0; i < 6; i++) { await page.keyboard.press('Shift+Tab'); if (!(await insideDialog())) escaped++ }
  check(`(${vp}/${th}) 24 Tab y 6 Shift+Tab: el foco no escapa del diálogo`, escaped === 0, `escapes ${escaped}`)
  await page.keyboard.press('Escape')
  await dlg().waitFor({ state: 'hidden', timeout: 10000 })
  if (vp === 'desktop' && th === 'light') {
    const focused = await page.evaluate(() => document.activeElement?.textContent?.trim())
    check('(desktop/light) Escape cierra el diálogo y el foco vuelve al botón "Compra"', focused === 'Compra', String(focused))
  }

  // 6. «el remito cambió»: otro usuario lo edita mientras el diálogo está abierto
  await compra.click()
  await dlg().getByText('Total de la compra').waitFor({ timeout: 30000 })
  await pickPaymentMethod(page, dlg(), /transferencia/i)
  const put = await be(tok, 'PUT', `/delivery-notes/${r1.id}`, { direction: 'purchase', revision: dnRev(r1.id), supplier_id: sup, branch_id: br1, supplier_reference: null, notes: 'editado por otro', items: [line(harina, 2.5, 700, { unit_id: kg }), line(alf, 4, 250)] })
  await registrar().click()
  await dlg().getByRole('alert').waitFor({ timeout: 30000 })
  check(`(${vp}/${th}) «el remito cambió»: aviso en role=alert y el diálogo sigue abierto`, /cambió mientras lo tenías abierto/.test(await dlg().getByRole('alert').innerText()) && put.status === 200)
  await shotDialog(page, 'b-dialogo-remito-cambio', vp, th)
  await registrar().click() // reintento con la revisión recargada
  await dlg().getByText('Compra registrada').waitFor({ timeout: 60000 })
  const title = dlg().getByRole('heading', { name: 'Compra registrada' })
  check(`(${vp}/${th}) éxito: "Compra registrada" recibe el foco`, await title.evaluate((el) => el === document.activeElement))
  await shotDialog(page, 'b-dialogo-exito', vp, th)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  await page.getByRole('region', { name: 'Compra generada' }).waitFor({ timeout: 30000 })
  await shot('b-detalle-convertido', vp, th)

  // 7. /compras: badge, Editar bloqueado y diálogo de borrado
  sql(`update purchases set date = date + interval '1 day' where source_delivery_note_id='${r1.id}'`)
  await go('/compras')
  const badge = page.getByRole('link', { name: new RegExp(`Desde remito ${dnLabel(r1.id)}`) }).filter({ visible: true }).first()
  await badge.waitFor({ timeout: 60000 })
  await shot('b-compras-badge-editar-bloqueado', vp, th)
  const row = badge.locator("xpath=ancestor::*[.//button[@data-testid='delete-operation-trigger' or @data-testid='delete-operation-blocked']][1]")
  await row.locator("[data-testid='delete-operation-trigger']").filter({ visible: true }).first().click()
  await page.getByRole('alertdialog').waitFor({ timeout: 30000 })
  await shotDialog(page, 'b-compras-borrado-dialogo', vp, th)
  const del = await page.getByRole('alertdialog').innerText()
  check(`(${vp}/${th}) el diálogo de borrado dice que el remito vuelve a pendiente y que el stock NO vuelve (no promete reponerlo)`, new RegExp(`El stock no vuelve: la mercadería quedó recibida con el remito ${dnLabel(r1.id)}, que vuelve a quedar pendiente`).test(del) && !/Se revertirá el ingreso de stock/i.test(del), del.replace(/\n/g, ' ').slice(0, 200))
  await page.getByRole('alertdialog').getByRole('button', { name: 'Cancelar' }).click()

  // 8. «Compra» deshabilitada con el motivo (línea sin precio)
  const r3 = await mkDn(tok, [line(harina, 1, 700, { unit_id: kg }), line(sinCosto, 3, 0)])
  await go(`/remitos/${r3.id}`)
  await shot('b-detalle-sin-precio', vp, th)

  // 9. sin caja abierta en la sucursal (Norte no tiene caja): se avisa y no se bloquea
  const r4 = await mkDn(tok, undefined, { branch_id: br2 })
  await go(`/remitos/${r4.id}`)
  await compra.click()
  await dlg().getByText('Total de la compra').waitFor({ timeout: 30000 })
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  check(`(${vp}/${th}) efectivo sin caja en la sucursal: avisa el motivo y NO bloquea`, /No hay caja abierta en esta sucursal/.test(await dlg().innerText()) && (await registrar().isEnabled()))
  await shotDialog(page, 'b-dialogo-efectivo-sin-caja', vp, th)
  await page.keyboard.press('Escape')

  // 10. aviso contra la doble suma en "Nueva compra"
  await go('/compras')
  await page.getByRole('button', { name: /nueva compra/i }).first().click()
  await dlg().waitFor({ timeout: 30000 })
  await dlg().getByRole('combobox', { name: /Proveedor/ }).click()
  await page.getByRole('option', { name: /Proveedor Demo QA/ }).first().click()
  await dlg().getByRole('note').waitFor({ timeout: 30000 })
  await shotDialog(page, 'b-compras-aviso-doble-suma', vp, th)

  check(`(${vp}/${th}) la consola no tiene errores propios`, errs.filter((e) => !/404|409|Failed to load resource|favicon/.test(e)).length === 0, errs.slice(0, 3).join(' | '))
  await ctx.close()
}

writeFileSync(`${SP}/visual-b-report.json`, JSON.stringify(report, null, 1))
const bad = results.filter(([, ok]) => !ok)
console.log(`\n══ ${results.length - bad.length}/${results.length} PASS`)
await browser.close()
process.exit(bad.length ? 1 : 0)
