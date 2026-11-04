// Pasada visual del remito de venta (tanda A): desktop 1280 y móvil 375 x tema claro y oscuro. Stack LOCAL.
// Capturas en scratchpad-remitos/capturas/<pantalla>-<viewport>-<tema>.png; desborde POR ELEMENTO; consola; foco y teclado en modales.
import { writeFileSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, COMBOS, measureOverflow, consoleCollector, OUT } from './pw-lib.mjs'
import { sql, check, results, USERS } from './lib.mjs'
import { readFileSync } from 'node:fs'

const IDS = JSON.parse(readFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos/ids.json', 'utf8'))
const { accA, client, br2 } = IDS
const issued = sql(`select id from delivery_notes where account_id='${accA}' and status='issued' and branch_id='${IDS.br1}' order by number desc limit 1`)
const canceled = sql(`select id from delivery_notes where account_id='${accA}' and status='canceled' order by number desc limit 1`)
const multi = sql(`select delivery_note_id from delivery_note_items where account_id='${accA}' group by 1 having count(*)>=2 order by max(created_at) desc limit 1`)
const brPending = sql(`select branch_id from delivery_notes where account_id='${accA}' and status='issued' and branch_id='${br2}' limit 1`)
const report = []
const browser = await chromium.launch()
const AUTH = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos/qa-auth-owner.json'
await uiLogin(browser, ...USERS.owner, AUTH) // sesión fresca: el estado guardado vence por inactividad

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
  // Scrollers horizontales PREEXISTENTES (min-w-[420px] del panel de movimientos de /stock y la tabla de operaciones de la ficha):
  // no los toca este change (git diff main); se informan aparte, no cuentan como desborde propio.
  const PRE = ['stock-movimientos-remito', 'cliente-ficha-cabecera']
  const pre = PRE.includes(name) ? ov.issues.filter((i) => i.kind === 'scroller') : []
  const own = ov.issues.filter((i) => !pre.includes(i))
  if (pre.length) console.log(`   (preexistente, no propio) ${name} ${vp}: scroller horizontal propio ${JSON.stringify(pre.map((i) => `${i.scrollW}>${i.clientW}`))}`)
  const bad = ov.docOverflow > 1 || own.length > 0
  report.push({ name, vp, th, docOverflow: ov.docOverflow, elementOverflow: ov.count, issues: ov.issues, note })
  check(`desborde 0: ${name} ${vp} ${th}`, !bad, bad ? JSON.stringify({ doc: ov.docOverflow, issues: own.slice(0, 3) }) : '')
}

const only = process.argv[2] ? new RegExp(process.argv[2]) : null
for (const [vp, th] of COMBOS.filter(([v, t]) => !only || only.test(`${v}-${t}`))) {
  const ctx = await newCtx(browser, vp, th, AUTH)
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  await open(page, '/remitos')
  await snap(page, 'remitos-listado', vp, th, errs)
  await open(page, `/remitos?estado=pendientes&sucursal=${br2}&cliente=${client}`)
  await snap(page, 'remitos-listado-filtros-chips', vp, th, errs)
  await open(page, '/remitos/nuevo', async (p) => { await p.getByRole('combobox', { name: 'Cliente' }).waitFor({ timeout: 90000 }) })
  await snap(page, 'remito-nuevo-vacio', vp, th, errs)
  await open(page, `/remitos/${multi}/editar`, async (p) => { await p.getByRole('button', { name: 'Guardar cambios' }).waitFor({ timeout: 90000 }) })
  await snap(page, 'remito-editar', vp, th, errs)
  await open(page, `/remitos/${issued}`)
  await snap(page, 'remito-detalle-pendiente', vp, th, errs)
  await open(page, `/remitos/${canceled}`)
  await snap(page, 'remito-detalle-anulado', vp, th, errs)
  // diálogo de anulación
  await open(page, `/remitos/${issued}`)
  await page.getByRole('button', { name: 'Anular' }).waitFor({ timeout: 90000 })
  await page.getByRole('button', { name: 'Anular' }).click()
  await page.getByRole('dialog').waitFor()
  await page.getByLabel(/Motivo/).fill('Motivo de prueba para la captura')
  await snap(page, 'remito-anular-dialogo', vp, th, errs)
  await page.keyboard.press('Escape')
  // cabecera de la ficha del cliente
  await open(page, `/clientes/${client}`)
  await snap(page, 'cliente-ficha-cabecera', vp, th, errs)
  if (vp === 'mobile') {
    const labels = await page.locator('main a[aria-label], main button[aria-label]').evaluateAll((els) => els.map((e) => e.getAttribute('aria-label')))
    const dups = labels.filter((l, i) => labels.indexOf(l) !== i)
    check(`ficha del cliente ${th}: aria-label distintos en botones de ícono (375 px)`, dups.length === 0 && labels.some((l) => /remito/i.test(l ?? '')), labels.join(' | '))
  }
  // panel de movimientos de /stock
  await open(page, '/stock')
  await page.getByText('Historial de movimientos').first().click()
  await page.getByText(/Remito R-\d{8}/).first().waitFor({ timeout: 60000 })
  await page.getByText(/Remito R-\d{8}/).first().scrollIntoViewIfNeeded()
  await snap(page, 'stock-movimientos-remito', vp, th, errs)
  // baja de sucursal con remitos pendientes
  await open(page, '/sucursales')
  const trigger = page.getByRole('button', { name: /Desactivar Sucursal Norte QA/ })
  await trigger.click()
  await page.getByRole('alertdialog').waitFor()
  await page.getByRole('alertdialog').getByRole('link', { name: /Ver remitos pendientes/ }).waitFor({ timeout: 30000 }).catch(() => {})
  await snap(page, 'sucursales-baja-con-remitos', vp, th, errs)
  await page.keyboard.press('Escape')
  const real = errs.filter((e) => !/status of 40[49]/.test(e))
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
  check('anular: al abrir, el foco queda dentro del diálogo', await inside())
  let trapped = true
  for (let i = 0; i < 8; i++) { await page.keyboard.press('Tab'); if (!(await inside())) trapped = false }
  check('anular: Tab no escapa del diálogo (8 Tab)', trapped)
  await page.keyboard.press('Escape')
  await page.waitForTimeout(500)
  check('anular: Escape cierra', (await dlg.count()) === 0)
  const back = await page.evaluate(() => (document.activeElement?.textContent ?? '').trim())
  check('anular: al cerrar, el foco vuelve al botón "Anular"', /Anular/.test(back), back)
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

writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos/visual-report.json', JSON.stringify(report, null, 1))
const failed = results.filter(([, ok]) => !ok)
console.log(`RESUMEN visual: ${results.length - failed.length}/${results.length} PASS`)
if (failed.length) console.log('FALLAN:', failed.map(([n]) => n).join(' | '))
await browser.close()
