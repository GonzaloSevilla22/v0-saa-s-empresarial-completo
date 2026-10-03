// Humo funcional por la UI real de la tanda B (conversión remito -> venta). Stack LOCAL. Lee stock, caja,
// cuenta corriente y movimientos de la base local antes y después de cada paso.
// Uso: node humo-b.mjs [regex de pasos: a b c d e f g h]
import { existsSync, rmSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, consoleCollector } from './pw-b.mjs'
import {
  A, br1, harina, alf, escaso, client, stockAll, cashCount, cashSum, bankCount, customerMovs, allStockMovs, nMovs,
  dnStatus, dnLabel, dnRev, ordersOfDn, liveOrderOfDn, opOfOrder, snap, same, line, stdLines, mkDn, convApi, key,
  ensureSession, pickPaymentMethod, pwShot, check, sql, be, login, USERS, results,
} from './hb.mjs'

const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos'
const only = process.argv[2] ? new RegExp(process.argv[2]) : null
const run = (id) => !only || only.test(id)
const tok = await login(...USERS.owner)
const browser = await chromium.launch()
const authFile = (who) => `${SP}/qa-auth-${who}.json`
async function ctxFor(who) {
  if (!existsSync(authFile(who))) await uiLogin(browser, ...USERS[who], authFile(who))
  const c = await newCtx(browser, 'desktop', 'light', authFile(who))
  return c
}
const ctx = await ctxFor('owner')
const page = await ctx.newPage()
const errs = consoleCollector(page)
const report = []
const shot = pwShot(page, report)
const dlg = () => page.getByRole('dialog')
const go = async (path, pg = page) => {
  await pg.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await pg.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
}
const openConvert = async (pg = page) => {
  await pg.getByRole('button', { name: 'Venta', exact: true }).click()
  await pg.getByRole('dialog').getByText('Total a cobrar').waitFor({ timeout: 30000 })
}
const registrar = () => dlg().getByRole('button', { name: 'Registrar venta' })
const step = async (id, fn) => {
  if (!run(id)) return
  try { await fn() } catch (e) {
    check(`(${id}) el paso terminó sin excepción`, false, String(e).split('\n').slice(0, 4).join(' | ') + ' @ ' + page.url())
    await page.screenshot({ path: `${SP}/capturas-b/humo-fallo-${id}.png` }).catch(() => {})
  }
}
// Emite un remito por la API y lo convierte por la UI con la forma de pago dada; devuelve el id.
async function convertViaUi(dnId, pmRe, { dbl = false } = {}) {
  await go(`/remitos/${dnId}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), pmRe)
  if (dbl) await registrar().dblclick()
  else await registrar().click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
}
const S = {}

// (a) efectivo con caja abierta, precio del remito con catálogo remarcado y doble clic ------------------
await step('a', async () => {
  await ensureSession(tok)
  const dn = await mkDn(tok)
  S.a = dn.id
  const total = 2.5 * 1200 + 4 * 500
  const s0 = snap(); const stockAfterEmit = { h: stockAll(harina), a: stockAll(alf) }
  const movsDn = nMovs(dn.id)
  sql(`update products set price=9999 where id='${harina}'`)
  await go(`/remitos/${dn.id}`)
  await openConvert()
  const dialogText = await dlg().innerText()
  check('(a) el diálogo dice que el stock NO se vuelve a descontar, con el número del remito', new RegExp(`El stock ya se descontó al emitir el remito ${dnLabel(dn.id)}`).test(dialogText), dialogText.slice(0, 200))
  check('(a) sin selector de sucursal (es la del remito)', (await dlg().getByRole('combobox', { name: /Sucursal/ }).count()) === 0)
  check('(a) muestra el total del remito (5.000), no el del catálogo remarcado', /5\.000/.test(await dlg().getByTestId('convert-delivery-note-total').innerText()))
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await shot('humo-dialogo-efectivo', 'desktop', 'light')
  await registrar().dblclick() // doble clic
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  await shot('humo-exito', 'desktop', 'light')
  const s1 = snap()
  check('(a) el stock NO cambia (harina ni alfajor)', s1.h === s0.h && s1.a === s0.a, `h ${s0.h}->${s1.h} a ${s0.a}->${s1.a}`)
  check('(a) cero movimientos de stock nuevos en toda la cuenta', s1.mov === s0.mov, `${s0.mov}->${s1.mov}`)
  check('(a) los movimientos del remito siguen siendo los 2 de la emisión', nMovs(dn.id) === movsDn && movsDn === 2, `${movsDn}->${nMovs(dn.id)}`)
  check('(a) aparece UN movimiento de caja por el total del remito', s1.cash === s0.cash + 1 && cashSum() > 0 && Number(sql(`select amount from cash_movements order by created_at desc limit 1`)) === total, `${s0.cash}->${s1.cash}`)
  check('(a) doble clic = UNA orden confirmada', ordersOfDn(dn.id) === 'confirmed' && s1.orders === String(Number(s0.orders) + 1), `${ordersOfDn(dn.id)} orders ${s0.orders}->${s1.orders}`)
  const so = liveOrderOfDn(dn.id)
  const op = opOfOrder(so)
  check('(a) la orden nace con source_delivery_note_id del remito', sql(`select source_delivery_note_id from sales_orders where id='${so}'`) === dn.id)
  check('(a) la venta cobra el precio del remito (5.000), no el del catálogo (9.999)', Number(sql(`select sum(total) from sales where operation_id='${op}'`)) === total, sql(`select sum(total) from sales where operation_id='${op}'`))
  check('(a) remito en estado converted', dnStatus(dn.id) === 'converted')
  sql(`update products set price=1200 where id='${harina}'`)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  await page.getByRole('region', { name: 'Venta generada' }).waitFor({ timeout: 30000 })
  const ver = page.getByRole('link', { name: 'Ver venta' })
  check('(a) el detalle del remito convertido muestra "Ver venta" hacia la orden', (await ver.count()) === 1 && (await ver.getAttribute('href')).includes(so), await ver.getAttribute('href'))
  check('(a) el detalle ya no ofrece Venta, Editar ni Anular', (await page.getByRole('button', { name: 'Venta', exact: true }).count()) === 0 && (await page.getByRole('link', { name: 'Editar' }).count()) === 0 && (await page.getByRole('button', { name: 'Anular' }).count()) === 0)
  await shot('humo-detalle-convertido', 'desktop', 'light')
  await go('/ventas')
  const badge = page.getByRole('link', { name: new RegExp(`Desde remito ${dnLabel(dn.id)}`) }).filter({ visible: true }).first()
  await badge.waitFor({ timeout: 60000 })
  check('(a) /ventas muestra "Desde remito R-…" con el número del remito', true, await badge.textContent())
  await shot('humo-ventas-badge', 'desktop', 'light')
})

// (b) Facturar y borrar la venta ----------------------------------------------------------------------
// El listado ordena por fecha y pagina: se adelanta un día la venta del remito para que caiga en la 1ª página.
const bumpSaleDate = (dnId) => sql(`update sales set date = date + interval '1 day' where operation_id = (select sale_operation_id from sales_orders where source_delivery_note_id='${dnId}' and status<>'canceled')`)
async function deleteSaleOfDn(dnId) {
  bumpSaleDate(dnId)
  await go('/ventas')
  const badge = page.getByRole('link', { name: new RegExp(`Desde remito ${dnLabel(dnId)}`) }).filter({ visible: true }).first()
  await badge.waitFor({ timeout: 60000 })
  const row = badge.locator("xpath=ancestor::*[.//button[@data-testid='delete-operation-trigger']][1]")
  await row.locator("[data-testid='delete-operation-trigger']").filter({ visible: true }).first().click()
  return dlg().or(page.getByRole('alertdialog'))
}
await step('b', async () => {
  await ensureSession(tok)
  const dn = await mkDn(tok)
  S.b = dn.id
  await convertViaUi(dn.id, /efectivo/i)
  const op = opOfOrder(liveOrderOfDn(dn.id))
  const fact = dlg().getByRole('button', { name: /Facturar|Emitir comprobante/ }).first()
  await fact.waitFor({ timeout: 30000 })
  await fact.click()
  await page.waitForTimeout(2000)
  const emit = page.getByRole('button', { name: /Emitir comprobante|Emitir/ }).last()
  if (await emit.count()) { await emit.click().catch(() => {}); await page.waitForTimeout(5000) }
  const so0 = liveOrderOfDn(dn.id)
  const fiscal = () => sql(`select coalesce(string_agg(fd.status,','),'') from sales_orders so join fiscal_documents fd on fd.id=so.fiscal_document_id where so.id='${so0}'`)
  const fs0 = fiscal()
  check('(b) Facturar deja un comprobante de la venta de remito (pending_cae o authorized)', /pending_cae|authorized/.test(fs0), fs0)
  await shot('humo-facturar-resultado', 'desktop', 'light')
  const afterConv = snap()
  await page.keyboard.press('Escape')
  await page.waitForTimeout(500)
  const ad = await deleteSaleOfDn(dn.id)
  await page.getByRole('alertdialog').waitFor({ timeout: 30000 })
  const text = await page.getByRole('alertdialog').innerText()
  check('(b) el diálogo de borrado trae la línea de D9 con el número del remito', new RegExp(`El stock no vuelve: la mercadería quedó entregada con el remito ${dnLabel(dn.id)}`).test(text), text.slice(0, 260))
  await shot('humo-borrar-dialogo', 'desktop', 'light')
  await page.getByRole('alertdialog').getByRole('button', { name: /^Eliminar$/ }).click()
  await page.waitForTimeout(4000)
  const afterDel = snap()
  const fs1 = fiscal()
  if (/authorized/.test(fs0)) {
    check('(b) con comprobante AUTORIZADO la venta es inmutable: el borrado se rechaza sin efectos', dnStatus(dn.id) === 'converted' && same(afterDel, afterConv), `${dnStatus(dn.id)} ${JSON.stringify(afterDel)}`)
  } else {
    check('(b) con comprobante pending_cae sin marca el borrado lo ANULA (voided) en la misma transacción', /voided/.test(fiscal()), `antes=${fs0} después=${fiscal()}`)
    check('(b) el remito vuelve a PENDIENTE (issued)', dnStatus(dn.id) === 'issued', dnStatus(dn.id))
    check('(b) el stock NO cambia al borrar la venta', afterDel.h === afterConv.h && afterDel.a === afterConv.a && afterDel.mov === afterConv.mov, `h ${afterConv.h}->${afterDel.h} a ${afterConv.a}->${afterDel.a} mov ${afterConv.mov}->${afterDel.mov}`)
    check('(b) la caja se compensa (hay un movimiento nuevo de caja)', afterDel.cash === afterConv.cash + 1, `${afterConv.cash}->${afterDel.cash}`)
    check('(b) los movimientos del remito siguen siendo los 2 de la emisión', nMovs(dn.id) === 2, String(nMovs(dn.id)))
    check('(b) no queda ninguna orden viva del remito', liveOrderOfDn(dn.id) === '', ordersOfDn(dn.id))
    await go(`/remitos/${dn.id}`)
    check('(b) el detalle vuelve a ofrecer Venta, Editar y Anular', (await page.getByRole('button', { name: 'Venta', exact: true }).count()) === 1 && (await page.getByRole('link', { name: 'Editar' }).count()) === 1 && (await page.getByRole('button', { name: 'Anular' }).count()) === 1)
  }
})

// (c) borrar sin facturar, reconvertir a crédito (cuenta corriente, sin caja) -------------------------
await step('c', async () => {
  await ensureSession(tok)
  const dn = await mkDn(tok)
  S.c = dn.id
  await convertViaUi(dn.id, /efectivo/i)
  await page.keyboard.press('Escape')
  const afterConv = snap()
  await deleteSaleOfDn(dn.id)
  await page.getByRole('alertdialog').getByRole('button', { name: /^Eliminar$/ }).click()
  await page.waitForTimeout(4000)
  const afterDel = snap()
  check('(c) borrar la venta (sin facturar) devuelve el remito a pendiente', dnStatus(dn.id) === 'issued', dnStatus(dn.id))
  check('(c) el stock no se repone ni se descuenta', afterDel.h === afterConv.h && afterDel.a === afterConv.a && afterDel.mov === afterConv.mov, `${JSON.stringify([afterConv.h, afterConv.a, afterConv.mov])} -> ${JSON.stringify([afterDel.h, afterDel.a, afterDel.mov])}`)
  sql(`update clients set payment_terms_days=30 where id='${client}'`)
  const s0 = snap(); const cust0 = customerMovs()
  await go(`/remitos/${dn.id}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /cuenta corriente|cr[eé]dito/i)
  await dlg().getByText(/Saldo actual/).waitFor({ timeout: 15000 })
  await shot('humo-dialogo-credito', 'desktop', 'light')
  await registrar().click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  const s1 = snap()
  const row = sql(`select amount||'|'||movement_type||'|'||coalesce(due_date::text,'NULL') from customer_account_movements where account_id='${A}' order by created_at desc limit 1`)
  const expDue = sql(`select (timezone('America/Argentina/Mendoza', now())::date + 30)::text`)
  check('(c) reconvertir a crédito carga la cuenta corriente por el total (5.000)', s1.cust === cust0 + 1 && Number(row.split('|')[0]) === 5000, row)
  check('(c) vencimiento por cascada = hoy + 30', row.split('|')[2] === expDue, `${row} esperado ${expDue}`)
  check('(c) sin movimiento de caja ni banco', s1.cash === s0.cash && s1.bank === s0.bank)
  check('(c) el stock sigue sin cambiar', s1.h === s0.h && s1.a === s0.a && s1.mov === s0.mov)
  check('(c) la orden anterior queda cancelada y hay una viva nueva: 1 remito -> 1 venta viva', /confirmed/.test(ordersOfDn(dn.id)) && Number(sql(`select count(*) from sales_orders where source_delivery_note_id='${dn.id}' and status<>'canceled'`)) === 1, ordersOfDn(dn.id))
  check('(c) remito converted otra vez', dnStatus(dn.id) === 'converted')
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
})

// (d) editar las líneas de una venta de remito: bloqueado con motivo ------------------------------------
await step('d', async () => {
  const dnId = S.c || sql(`select source_delivery_note_id from sales_orders where source_delivery_note_id is not null and status<>'canceled' order by created_at desc limit 1`)
  const op = opOfOrder(liveOrderOfDn(dnId))
  bumpSaleDate(dnId)
  await go('/ventas')
  const badge = page.getByRole('link', { name: new RegExp(`Desde remito ${dnLabel(dnId)}`) }).filter({ visible: true }).first()
  await badge.waitFor({ timeout: 60000 })
  const row = badge.locator("xpath=ancestor::*[.//button[@data-testid='delete-operation-trigger']][1]")
  const locked = row.locator('button[disabled][title*="remito"]').filter({ visible: true })
  const n = await locked.count()
  const title = n ? await locked.first().getAttribute('title') : ''
  check('(d) "Editar" deshabilitado con el motivo del remito', n > 0, `botones=${n} title=${title}`)
  check('(d) el motivo nombra la salida (anulá o borrá la venta y rehacela desde el remito)', /remito/i.test(title || ''), title)
  await shot('humo-ventas-editar-bloqueado', 'desktop', 'light')
  const before = snap()
  const ids = sql(`select string_agg(id::text,',') from sales where operation_id='${op}'`).split(',')
  const r = await be(tok, 'PUT', '/sales/operation', {
    sale_ids: ids, date: new Date().toISOString().slice(0, 10), client_id: client, currency: 'ARS',
    items: [{ product_id: alf, quantity: 1, amount: 500 }],
  })
  check('(d) la edición por API responde 409 con delivery_note_sale_locked', r.status === 409 && /delivery_note_sale_locked/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 200)}`)
  check('(d) sin efectos (stock, ventas, caja)', same(before, snap()))
})

// (e) anular un remito convertido: prohibido ------------------------------------------------------------
await step('e', async () => {
  const dnId = S.c || S.a
  const before = snap()
  await go(`/remitos/${dnId}`)
  check('(e) el detalle del remito convertido no ofrece Anular', (await page.getByRole('button', { name: 'Anular' }).count()) === 0)
  const r = await be(tok, 'POST', `/delivery-notes/${dnId}/cancel`, { revision: dnRev(dnId), reason: 'intento de anular un convertido' })
  check('(e) POST /cancel sobre un convertido -> 409 delivery_note_locked_converted ("primero eliminá la venta")', r.status === 409 && /delivery_note_locked_converted|delivery_note_invalid_state/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 200)}`)
  check('(e) sin efectos y el remito sigue converted', same(before, snap()) && dnStatus(dnId) === 'converted')
  const u = await be(tok, 'PUT', `/delivery-notes/${dnId}`, { revision: dnRev(dnId), client_id: client, branch_id: br1, delivery_address: null, notes: 'x', items: [line(alf, 1, 500)] })
  check('(e) editar el convertido por API -> 409 sin efectos', u.status === 409 && same(before, snap()), `${u.status} ${JSON.stringify(u.body).slice(0, 160)}`)
})

// (f) pestaña vieja: el remito cambió -------------------------------------------------------------------
await step('f', async () => {
  await ensureSession(tok)
  const dn = await mkDn(tok)
  await go(`/remitos/${dn.id}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  // otro usuario edita el remito mientras el diálogo está abierto: alfajor 4 -> 5 (total 5.000 -> 5.500)
  const upd = await be(tok, 'PUT', `/delivery-notes/${dn.id}`, { revision: dn.revision, client_id: client, branch_id: br1, delivery_address: null, notes: 'editado en otra pestaña', items: [line(harina, 2.5, 1200, { unit_id: IDS_KG() }), line(alf, 5, 500)] })
  check('(f) edición concurrente aplicada', upd.status === 200, `${upd.status} ${JSON.stringify(upd.body).slice(0, 150)}`)
  const s0 = snap()
  await registrar().click()
  const alert = dlg().getByRole('alert')
  await alert.waitFor({ timeout: 60000 })
  const text = await alert.textContent()
  await shot('humo-error-remito-cambio', 'desktop', 'light')
  check('(f) delivery_note_changed traducido (el remito cambió)', /cambi|modific/i.test(text), text)
  check('(f) nada escrito: sigue issued, sin órdenes, sin caja', dnStatus(dn.id) === 'issued' && ordersOfDn(dn.id) === '' && same(s0, snap()))
  await page.waitForTimeout(1500)
  const totalTxt = await dlg().getByTestId('convert-delivery-note-total').innerText()
  check('(f) el resumen recargó el total vigente (5.500)', /5\.500/.test(totalTxt), totalTxt)
  await registrar().click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  check('(f) la 2ª confirmación convierte al total vigente (5.500)', dnStatus(dn.id) === 'converted' && Number(sql(`select total from sales_orders where source_delivery_note_id='${dn.id}' and status<>'canceled'`)) === 5500)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
})
function IDS_KG() { return sql(`select id from units_of_measure where account_id='${A}' and symbol='kg'`) }

// (g) rol stock: sin botón Venta --------------------------------------------------------------------------
await step('g', async () => {
  const dn = await mkDn(tok)
  const c2 = await ctxFor('stock')
  const p2 = await c2.newPage()
  const e2 = consoleCollector(p2)
  await go(`/remitos/${dn.id}`, p2)
  await p2.waitForTimeout(1500)
  check('(g) depósito: sin botón Venta en el detalle del remito pendiente', (await p2.getByRole('button', { name: 'Venta', exact: true }).count()) === 0)
  check('(g) depósito: sí puede editar (regresión de la tanda A)', (await p2.getByRole('link', { name: 'Editar' }).count()) === 1)
  const tokS = await login(...USERS.stock)
  const before = snap()
  const r = await convApi(tokS, dn.id, { expected_revision: dn.revision, payment_method_id: sql(`select id from payment_methods where account_id='${A}' and kind='other' and is_active limit 1`) })
  check('(g) depósito convirtiendo por API -> 403', r.status === 403, `${r.status} ${JSON.stringify(r.body).slice(0, 160)}`)
  check('(g) sin efectos', same(before, snap()) && dnStatus(dn.id) === 'issued')
  check('(g) consola del depósito sin errores propios', e2.filter((m) => !/40[134]|403|Failed to load resource/.test(m)).length === 0, e2.join(' | ').slice(0, 200))
  await c2.close()
})

// (h) regresión: formulario de venta, POS y presupuesto -> venta siguen descontando ---------------------------
await step('h', async () => {
  await ensureSession(tok)
  // formulario de venta
  const sa = stockAll(alf); const sales0 = Number(sql(`select count(*) from sales where account_id='${A}'`))
  await go('/ventas')
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
  await d.getByRole('button', { name: /Confirmar venta/ }).click()
  await page.waitForTimeout(6000)
  check('(h) formulario de venta: registra la venta y BAJA el stock', Number(sql(`select count(*) from sales where account_id='${A}'`)) === sales0 + 1 && stockAll(alf) === sa - 1, `${sa}->${stockAll(alf)}`)
  const pending = sql(`select count(*) from sales_orders where account_id='${A}' and source_delivery_note_id is not null and status='confirmed'`)
  check('(h) formulario de venta: la venta nueva NO nace de un remito (sin source_delivery_note_id)', sql(`select count(*) from sales_orders so join sales s on s.operation_id=so.sale_operation_id where so.account_id='${A}' and so.source_delivery_note_id is not null and s.created_at > now() - interval '30 seconds'`) === '0', pending)
  // POS
  const [sa2, sales1, cc] = [stockAll(alf), Number(sql(`select count(*) from sales where account_id='${A}'`)), cashCount()]
  await page.goto(`${BASE}/ventas/pos`, { waitUntil: 'domcontentloaded', timeout: 120000 })
  await page.getByRole('button', { name: 'Efectivo' }).waitFor({ timeout: 60000 })
  await page.getByText(/Caja abierta/).waitFor({ timeout: 30000 })
  await page.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.getByRole('option', { name: /Alfajor artesanal/ }).first().click()
  await page.getByRole('button', { name: 'Agregar al carrito' }).click()
  await page.getByRole('button', { name: /^Cobrar/ }).click()
  await page.waitForTimeout(6000)
  check('(h) POS: registra la venta, BAJA el stock y mueve la caja', Number(sql(`select count(*) from sales where account_id='${A}'`)) === sales1 + 1 && stockAll(alf) === sa2 - 1 && cashCount() === cc + 1, `${sa2}->${stockAll(alf)}`)
  // presupuesto -> venta
  const qr = await be(tok, 'POST', '/quotes', { client_id: client, valid_until: new Date(Date.now() + 864e5 * 10).toISOString().slice(0, 10), notes: 'regresión', items: [line(alf, 3, 500)] })
  await be(tok, 'POST', `/quotes/${qr.body.id}/transition`, { action: 'send' })
  const sa3 = stockAll(alf)
  await go(`/presupuestos/${qr.body.id}`)
  await page.getByRole('button', { name: 'Venta', exact: true }).click()
  await dlg().getByText('Total a cobrar').waitFor({ timeout: 30000 })
  await pickPaymentMethod(page, dlg(), /efectivo/i)
  await registrar().click()
  await dlg().getByText('Venta registrada').waitFor({ timeout: 60000 })
  check('(h) presupuesto -> Venta: BAJA el stock (3) como siempre', stockAll(alf) === sa3 - 3, `${sa3}->${stockAll(alf)}`)
  check('(h) presupuesto -> Venta: la orden NO lleva source_delivery_note_id', sql(`select count(*) from sales_orders where source_quote_id='${qr.body.id}' and source_delivery_note_id is null`) === '1')
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
})

console.log('\nconsole errors:', errs.length ? errs.slice(0, 8) : 'ninguno')
console.log(`\nRESUMEN HUMO B: ${results.filter((r) => r[1]).length} PASS / ${results.filter((r) => !r[1]).length} FAIL`)
await browser.close()
process.exit(results.some((r) => !r[1]) ? 1 : 0)
