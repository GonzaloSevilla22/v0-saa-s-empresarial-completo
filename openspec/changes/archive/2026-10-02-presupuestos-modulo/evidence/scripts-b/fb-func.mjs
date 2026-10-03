// Humo funcional por la UI real de la tanda B (desktop claro). Stack LOCAL.
import { chromium, BASE, newCtx, login as uiLogin, consoleCollector, AUTH } from './pwb-lib.mjs'
import { login, USERS, results } from './lib-b.mjs'
import {
  IDS, A, P, KG, CLIENT, stock, cashCount, bankCount, ordersOf, quoteStatus, item, mkQuote, stdItems,
  ensureSession, closeSession, currentSession, pickPaymentMethod, pickBank, pwShot, check, sql, be,
} from './fbh.mjs'
import { existsSync } from 'node:fs'

const only = process.argv[2] ? new RegExp(process.argv[2]) : null
const run = (id) => !only || only.test(id)
const tok = await login(...USERS.owner)
const browser = await chromium.launch()
if (!existsSync(AUTH)) await uiLogin(browser, ...USERS.owner)
const ctx = await newCtx(browser, 'desktop', 'light')
const page = await ctx.newPage()
const errs = consoleCollector(page)
const report = []
const shot = pwShot(page, report)
const dlg = () => page.getByRole('dialog')

async function openDetail(id) {
  await page.goto(`${BASE}/presupuestos/${id}`, { waitUntil: 'domcontentloaded', timeout: 120000 })
  await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 60000 })
}
async function openConvert() {
  await page.getByRole('button', { name: 'Venta', exact: true }).click()
  await dlg().getByText('Total a cobrar').waitFor({ timeout: 30000 })
}
const bankAccountTrigger = (d) => d.getByLabel(/cuenta/i).first()

// ---------------------------------------------------------------- (a)(g)(h) efectivo + doble clic + precio del presupuesto
if (run('a')) {
  await ensureSession(tok)
  const q = await mkQuote(tok, stdItems())
  const [sh, sa, cc] = [stock(P.harina), stock(P.alf), cashCount()]
  sql(`update products set price=9999 where id='${P.harina}'`) // (h) catálogo remarcado
  await openDetail(q.id)
  await openConvert()
  await shot('conv-dialog-vacio', 'desktop', 'light')
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await shot('conv-dialog-efectivo', 'desktop', 'light')
  await dlg().getByRole('button', { name: 'Registrar venta' }).dblclick() // (g) doble clic
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  await shot('conv-exito', 'desktop', 'light')
  check('(a) stock baja', stock(P.harina) === sh - 2 && stock(P.alf) === sa - 3, `h ${sh}->${stock(P.harina)} a ${sa}->${stock(P.alf)}`)
  check('(a) movimiento de caja', cashCount() === cc + 1, `${cc}->${cashCount()}`)
  check('(g) doble clic = UNA orden confirmada', ordersOf(q.id) === 'confirmed', ordersOf(q.id))
  check('(g) una sola operación de venta', sql(`select count(distinct sale_operation_id) from sales_orders where source_quote_id='${q.id}'`) === '1')
  const tot = Number(sql(`select sum(s.total) from sales s join sales_orders so on so.sale_operation_id=s.operation_id where so.source_quote_id='${q.id}'`))
  check('(h) la venta cobra el precio del presupuesto (3900), no el remarcado', tot === 3900, `total ${tot}`)
  check('(a) presupuesto accepted', quoteStatus(q.id) === 'accepted')
  sql(`update products set price=1200 where id='${P.harina}'`)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  await page.goto(`${BASE}/ventas`, { waitUntil: 'domcontentloaded' })
  const badge = page.getByRole('link', { name: /Desde presupuesto P-\d{8}/ }).first()
  await badge.waitFor({ timeout: 60000 })
  await shot('ventas-badge', 'desktop', 'light')
  check('(a) badge Desde presupuesto en /ventas', (await badge.textContent())?.includes('P-'), await badge.textContent())
  await openDetail(q.id)
  await page.getByRole('region', { name: 'Venta generada' }).waitFor({ timeout: 30000 })
  await shot('detalle-convertido', 'desktop', 'light')
  check('(a) detalle: Venta generada', true)
}

// ---------------------------------------------------------------- (b) crédito
if (run('b')) {
  sql(`update clients set payment_terms_days=30 where id='${CLIENT}'`)
  const q = await mkQuote(tok, stdItems())
  const cc = cashCount()
  const before = Number(sql(`select count(*) from customer_account_movements where account_id='${A}'`))
  await openDetail(q.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /cuenta corriente|cr[eé]dito/i)
  await dlg().getByText(/Saldo actual/).waitFor({ timeout: 15000 })
  await shot('conv-dialog-credito', 'desktop', 'light')
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  const row = sql(`select amount||'|'||coalesce(due_date::text,'NULL')||'|'||movement_type from customer_account_movements where account_id='${A}' order by created_at desc limit 1`)
  const expDue = sql(`select (timezone('America/Argentina/Mendoza', now())::date + 30)::text`)
  check('(b) cargo en cuenta corriente', Number(sql(`select count(*) from customer_account_movements where account_id='${A}'`)) === before + 1, row)
  check('(b) vencimiento por cascada = hoy+30', row.split('|')[1] === expDue, `${row} esperado ${expDue}`)
  check('(b) sin movimiento de caja', cashCount() === cc)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
}

// ---------------------------------------------------------------- (c) transferencia con cuenta bancaria
if (run('c')) {
  const q = await mkQuote(tok, stdItems())
  const bc = bankCount(), cc = cashCount()
  await openDetail(q.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /transferencia/i)
  await shot('conv-dialog-transferencia', 'desktop', 'light')
  const hasBankSel = await bankAccountTrigger(dlg()).count()
  check('(c) aparece el selector de cuenta bancaria', hasBankSel > 0)
  if (hasBankSel) await pickBank(page, dlg())
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  check('(c) movimiento de banco', bankCount() === bc + 1, `${bc}->${bankCount()}`)
  check('(c) sin caja', cashCount() === cc)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
}

// ---------------------------------------------------------------- (d) stock insuficiente
if (run('d')) {
  await ensureSession(tok)
  const q = await mkQuote(tok, [item(P.escaso, 5, 300), item(P.alf, 1, 500)])
  const [se, sa, cc, bc] = [stock(P.escaso), stock(P.alf), cashCount(), bankCount()]
  const draftsBefore = sql(`select count(*) from sales_orders where account_id='${A}'`)
  await openDetail(q.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  const alert = dlg().getByRole('alert')
  await alert.waitFor({ timeout: 60000 })
  const text = await alert.textContent()
  await shot('conv-error-stock', 'desktop', 'light')
  check('(d) mensaje con el producto', /Producto escaso QA/.test(text) || /stock/i.test(text), text)
  check('(d) el mensaje nombra el producto', /Producto escaso QA/.test(text), text)
  check('(d) nada escrito', stock(P.escaso) === se && stock(P.alf) === sa && cashCount() === cc && bankCount() === bc && ordersOf(q.id) === '' && quoteStatus(q.id) === 'sent' && sql(`select count(*) from sales_orders where account_id='${A}'`) === draftsBefore, `${stock(P.escaso)} ${ordersOf(q.id)} ${quoteStatus(q.id)}`)
  check('(d) el diálogo sigue abierto', await dlg().isVisible())
  await page.keyboard.press('Escape')
}

// ---------------------------------------------------------------- (e) vencido
if (run('e')) {
  const q = await mkQuote(tok, stdItems())
  sql(`update quotes set valid_until = current_date - 3 where id='${q.id}'`)
  await openDetail(q.id)
  const btn = page.getByRole('button', { name: 'Venta', exact: true })
  const disabled = await btn.isDisabled().catch(() => null)
  await shot('detalle-vencido-venta-deshabilitada', 'desktop', 'light')
  check('(e) Venta deshabilitada si está vencido', disabled === true, `disabled=${disabled}`)
  check('(e) leyenda del motivo', await page.getByText(/Vencido el .*ampliá la validez o duplicalo/).count() > 0)
}

// ---------------------------------------------------------------- (f) quote_changed
if (run('f')) {
  await ensureSession(tok)
  const q = await mkQuote(tok, stdItems())
  await openDetail(q.id)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  // otra pestaña/usuario edita el presupuesto: cantidad de alfajores 3 -> 4 (total 3900 -> 4400)
  const upd = await be(tok, 'PUT', `/quotes/${q.id}`, {
    revision: q.revision, client_id: CLIENT, branch_id: null, valid_until: q.valid_until, notes: 'editado en otra pestaña',
    items: [item(P.harina, 2, 1200, { unit_id: KG }), item(P.alf, 4, 500)],
  })
  check('(f) edición concurrente aplicada', upd.status === 200, `status ${upd.status}`)
  const so = ordersOf(q.id)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  const alert = dlg().getByRole('alert')
  await alert.waitFor({ timeout: 60000 })
  const text = await alert.textContent()
  await shot('conv-error-quote-changed', 'desktop', 'light')
  check('(f) quote_changed traducido', /cambi|modific/i.test(text), text)
  check('(f) nada escrito', ordersOf(q.id) === '' && quoteStatus(q.id) === 'sent' && so === '')
  // el resumen se recargó con el total vigente
  await page.waitForTimeout(1500)
  const totalTxt = await dlg().getByTestId('convert-quote-total').textContent()
  check('(f) el resumen recargó el total vigente (4.400)', /4\.400/.test(totalTxt), totalTxt)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  check('(f) la 2ª confirmación convierte al total vigente', ordersOf(q.id) === 'confirmed' && Number(sql(`select total from sales_orders where source_quote_id='${q.id}'`)) === 4400)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
}

// ---------------------------------------------------------------- (i) línea de servicio
if (run('i')) {
  await ensureSession(tok)
  const q = await mkQuote(tok, [{ description: 'Flete a domicilio QA', quantity: 1, price: 800, subtotal: 800 }, item(P.alf, 2, 500)])
  await openDetail(q.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /^otro/i)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  check('(i) la línea de servicio se convirtió', ordersOf(q.id) === 'confirmed')
  // el listado ordena por fecha: se adelanta un día la venta del servicio para que caiga en la 1ª página
  sql(`update sales set date = date + interval '1 day' where operation_id = (select sale_operation_id from sales_orders where source_quote_id='${q.id}')`)
  await page.goto(`${BASE}/ventas`, { waitUntil: 'domcontentloaded' })
  await page.getByRole('link', { name: /Desde presupuesto/ }).first().waitFor({ timeout: 60000 })
  await page.locator('[aria-expanded]').filter({ has: page.locator('button[title*="conceptos sin producto"]') }).first().click()
  await page.getByText('Flete a domicilio QA').first().waitFor({ timeout: 30000 })
  await shot('ventas-linea-servicio', 'desktop', 'light')
  check('(i) /ventas muestra la descripción del servicio', true)
  const locked = page.locator('button[title*="conceptos sin producto de un presupuesto"]')
  const nLocked = await locked.count()
  const allDisabled = nLocked > 0 && (await locked.evaluateAll((els) => els.every((e) => e.disabled)))
  check('(i) "Editar" deshabilitado con su motivo', allDisabled, `botones con el motivo=${nLocked}`)
  const title = nLocked ? await locked.first().getAttribute('title') : ''
  check('(i) el motivo incluye la salida (eliminar y volver a vender desde el duplicado)', /eliminala y volvé a venderla desde el presupuesto duplicado/.test(title || ''), title)
}

// ---------------------------------------------------------------- (k) Facturar desde el panel de éxito
if (run('k')) {
  const errsBeforeK = errs.length
  await ensureSession(tok)
  const q = await mkQuote(tok, [item(P.alf, 1, 500)])
  await openDetail(q.id); await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await dlg().getByRole('button', { name: 'Registrar venta' }).click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  const fact = dlg().getByRole('button', { name: /Facturar|Emitir comprobante/ }).first()
  await fact.waitFor({ timeout: 30000 })
  check('(k) EmitInvoiceButton presente', await fact.count() > 0)
  await shot('conv-exito-facturar', 'desktop', 'light')
  await fact.click()
  await page.waitForTimeout(2000)
  await shot('conv-facturar-dialogo', 'desktop', 'light')
  const emit = page.getByRole('button', { name: /Emitir comprobante|Emitir/ }).last()
  if (await emit.count()) { await emit.click().catch(() => {}); await page.waitForTimeout(4000) }
  const st = sql(`select string_agg(status,',') from fiscal_documents where account_id='${A}'`)
  check('(k) comprobante en trámite en la base', /pending_cae|authorized/.test(st || ''), st)
  await shot('conv-facturar-resultado', 'desktop', 'light')
  check('(k) la pantalla NO se rompe tras facturar (sin errores de consola)', errs.length === errsBeforeK, errs.slice(errsBeforeK).join(' | ').slice(0, 250))
}

console.log('\nconsole errors:', errs.length ? errs.slice(0, 8) : 'ninguno')
console.log(`\nRESUMEN: ${results.filter((r) => r[1]).length} PASS / ${results.filter((r) => !r[1]).length} FAIL`)
await browser.close()
