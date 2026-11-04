// Humo funcional por la UI real de la tanda B (conversión remito de COMPRA -> compra). Stack LOCAL. Lee stock, caja, banco,
// cuenta corriente del proveedor y movimientos de la base local antes y después de cada paso.
// Uso: node humo-compra-b.mjs [regex de pasos: a b c d e f g h i j k l m]
import { existsSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, consoleCollector } from './pw-lib.mjs'
import {
  SP, A, br1, harina, alf, aceite, sinCosto, sup, kg, stockAll, cashCount, cashSum, cashTypes, bankCount, supplierMovs,
  supplierMovTypes, supplierBalance, allStockMovs, nMovs, movs, dnStatus, dnLabel, dnRev, dnHistory, purchaseRows, opOfDn, opsOfDn,
  purchaseTotal, snap, same, line, stdLines, mkDn, convApi, convBody, pmId, delPurchase, updPurchase, code, key, ensureSession,
  pickPaymentMethod, pwShot, check, sql, be, login, USERS, results,
} from './hb.mjs'

const only = process.argv[2] ? new RegExp(process.argv[2]) : null
const run = (id) => !only || only.test(id)
const tok = await login(...USERS.owner)
const browser = await chromium.launch()
const authFile = (who) => `${SP}/qa-auth-${who}.json`
async function ctxFor(who) {
  // login fresco SIEMPRE: un storageState viejo (sesión vencida) dejaba al rol sin resolver y el botón "Compra" no aparecía
  await uiLogin(browser, ...USERS[who], authFile(who))
  return await newCtx(browser, 'desktop', 'light', authFile(who))
}
const ctx = await ctxFor('owner')
const page = await ctx.newPage()
const errs = consoleCollector(page)
const notFound = []
page.on('response', (r) => { if (r.status() === 404) notFound.push(r.url().replace(/[?].*$/, '')) })
const report = []
const shot = pwShot(page, report)
const dlg = () => page.getByRole('dialog')
// los roles se resuelven de forma asíncrona: antes de afirmar que un botón NO está, se espera a que la página se asiente
const settle = async (pg) => { await pg.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {}); await pg.waitForTimeout(2500) }
const go = async (path, pg = page) => {
  await pg.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await pg.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
}
const openConvert = async (pg = page) => {
  await pg.getByRole('button', { name: 'Compra', exact: true }).click()
  await pg.getByRole('dialog').getByText('Total de la compra').waitFor({ timeout: 30000 })
}
const registrar = (pg = page) => pg.getByRole('dialog').getByRole('button', { name: 'Registrar compra' })
const step = async (id, fn) => {
  if (!run(id)) return
  try { await fn() } catch (e) {
    check(`(${id}) el paso terminó sin excepción`, false, String(e).split('\n').slice(0, 4).join(' | ') + ' @ ' + page.url())
    await page.screenshot({ path: `${SP}/capturas/humo-fallo-${id}.png` }).catch(() => {})
  }
}
// El listado de compras ordena por fecha y pagina: se adelanta un día la compra del remito para que caiga en la 1ª página.
const bumpPurchaseDate = (dnId) => sql(`update purchases set date = date + interval '1 day' where source_delivery_note_id='${dnId}'`)
async function rowOfDn(dnId) {
  const badge = page.getByRole('link', { name: new RegExp(`Desde remito ${dnLabel(dnId)}`) }).filter({ visible: true }).first()
  await badge.waitFor({ timeout: 60000 })
  return badge.locator("xpath=ancestor::*[.//button[@data-testid='delete-operation-trigger' or @data-testid='delete-operation-blocked']][1]")
}
async function deleteViaUi(dnId) {
  bumpPurchaseDate(dnId)
  await go('/compras')
  const row = await rowOfDn(dnId)
  await row.locator("[data-testid='delete-operation-trigger']").filter({ visible: true }).first().click()
  await page.getByRole('alertdialog').waitFor({ timeout: 30000 })
  return await page.getByRole('alertdialog').innerText()
}
async function convertViaUi(dnId, pmRe, { dbl = false, bank = null } = {}) {
  await go(`/remitos/${dnId}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), pmRe)
  // El opt-in de caja carga la sesion de forma asincrona (hook compartido useCashOptin): un clic instantaneo la pisa.
  if (/efectivo/.test(String(pmRe))) await dlg().getByRole('checkbox').first().waitFor({ timeout: 20000 })
  if (bank) {
    await dlg().getByLabel(/cuenta/i).first().click()
    await page.getByRole('option', { name: bank }).first().click()
  }
  if (dbl) await registrar().dblclick()
  else await registrar().click()
  await dlg().getByText('Compra registrada').waitFor({ timeout: 60000 })
}
const S = {}

// (a) efectivo con caja abierta: el stock NO vuelve a subir, un movimiento de caja, doble clic = UNA compra ----------------
await step('a', async () => {
  await ensureSession(tok)
  const dn = await mkDn(tok)
  S.a = dn.id
  const total = 2.5 * 700 + 4 * 250
  const s0 = snap(); const movsDn = nMovs(dn.id)
  const costBefore = sql(`select cost from products where id='${harina}'`)
  sql(`update products set cost=9999 where id='${harina}'`)
  await go(`/remitos/${dn.id}`)
  await openConvert()
  const dialogText = await dlg().innerText()
  check('(a) el diálogo dice que el stock YA se sumó al recibir el remito, con su número', new RegExp(`El stock ya se sumó al recibir el remito ${dnLabel(dn.id)}: esta compra no lo vuelve a sumar`).test(dialogText), dialogText.slice(0, 220))
  check('(a) proveedor y sucursal fijos: sin selector de sucursal ni de proveedor', (await dlg().getByRole('combobox', { name: /Sucursal|Proveedor/ }).count()) === 0 && /Proveedor Demo QA/.test(dialogText) && /Ingresa a/.test(dialogText), dialogText.slice(0, 160))
  check('(a) muestra el total del remito (2.750), no el costo de catálogo remarcado', /2\.750/.test(await dlg().getByTestId('convert-delivery-note-total').innerText()))
  check('(a) "Registrar compra" deshabilitada hasta elegir la forma de pago (obligatoria, sin "Sin especificar")', await registrar().isDisabled())
  await dlg().getByLabel('Forma de pago').click()
  check('(a) el selector de forma de pago NO ofrece "Sin especificar"', (await page.getByRole('option', { name: /sin especificar/i }).count()) === 0)
  await page.getByRole('option', { name: /efectivo/i }).first().click()
  const optin = dlg().getByRole('checkbox')
  await optin.first().waitFor({ timeout: 20000 }).catch(() => {})
  check('(a) con efectivo y caja abierta, "Registrar en caja" aparece PRE-MARCADO', (await optin.count()) === 1 && (await optin.isChecked()))
  await shot('humo-b-dialogo-efectivo', 'desktop', 'light')
  await registrar().dblclick() // doble clic
  await dlg().getByText('Compra registrada').waitFor({ timeout: 60000 })
  await shot('humo-b-exito', 'desktop', 'light')
  const s1 = snap()
  check('(a) el stock NO cambia (harina ni alfajor): la compra no vuelve a sumarlo', s1.h === s0.h && s1.a === s0.a, `h ${s0.h}->${s1.h} a ${s0.a}->${s1.a}`)
  check('(a) cero movimientos de stock nuevos en toda la cuenta', s1.mov === s0.mov, `${s0.mov}->${s1.mov}`)
  check('(a) los movimientos del remito siguen siendo los 2 de la recepción (purchase/delivery_note)', nMovs(dn.id) === movsDn && movsDn === 2 && /purchase\/delivery_note/.test(movs(dn.id)), movs(dn.id))
  const op = opOfDn(dn.id)
  check('(a) UNA sola compra con los datos del remito (2 líneas, proveedor y sucursal del remito)', opsOfDn(dn.id) === '1' || Number(opsOfDn(dn.id)) === 1 && purchaseRows(dn.id) === 2 && sql(`select count(*) from purchases where operation_id='${op}' and supplier_id='${sup}' and branch_id='${br1}'`) === '2', `ops ${opsOfDn(dn.id)} filas ${purchaseRows(dn.id)}`)
  check('(a) la compra cobra el precio del remito (2.750), no el costo de catálogo (9.999)', purchaseTotal(op) === total, String(purchaseTotal(op)))
  check('(a) aparece UN movimiento de caja (purchase_payment) por el total', s1.cash === s0.cash + 1 && cashTypes(op) === `purchase_payment:${-total}`, cashTypes(op))
  check('(a) el costo de catálogo NO se actualiza con la compra', sql(`select cost from products where id='${harina}'`) === '9999')
  check('(a) remito converted, con el historial issued > converted', dnStatus(dn.id) === 'converted' && /-?>issued issued>converted$/.test(dnHistory(dn.id)) || dnHistory(dn.id).endsWith('issued>converted'), dnHistory(dn.id))
  sql(`update products set cost=${costBefore || 0} where id='${harina}'`)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  await page.getByRole('region', { name: 'Compra generada' }).waitFor({ timeout: 30000 })
  const ver = page.getByRole('link', { name: 'Ver compra' })
  check('(a) el detalle del remito convertido muestra "Ver compra"', (await ver.count()) === 1, await ver.getAttribute('href'))
  check('(a) el detalle ya no ofrece Compra, Editar ni Anular', (await page.getByRole('button', { name: 'Compra', exact: true }).count()) === 0 && (await page.getByRole('link', { name: 'Editar' }).count()) === 0 && (await page.getByRole('button', { name: 'Anular' }).count()) === 0)
  await shot('humo-b-detalle-convertido', 'desktop', 'light')
  bumpPurchaseDate(dn.id)
  await go('/compras')
  const row = await rowOfDn(dn.id)
  check('(a) /compras muestra "Desde remito RC-…" con el número del remito', true, await row.innerText().then((t) => t.slice(0, 80)))
  const lock = row.locator('button[disabled][aria-label^="No editable"]').filter({ visible: true }).first()
  check('(a) "Editar" está deshabilitado con el motivo del remito (precedencia sobre el de dinero)', (await lock.count()) === 1 && /la compra nació del remito RC-/.test((await lock.getAttribute('aria-label')) ?? ''), await lock.getAttribute('aria-label'))
  await shot('humo-b-compras-badge', 'desktop', 'light')
})

// (b) a crédito: cargo en la cuenta corriente con el vencimiento del plazo del proveedor (15 días) --------------------------
await step('b', async () => {
  const dn = await mkDn(tok)
  S.b = dn.id
  const total = 2.5 * 700 + 4 * 250
  const s0 = snap(); const bal0 = supplierBalance(); const m0 = supplierMovs()
  await go(`/remitos/${dn.id}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /cuenta corriente/i)
  const text = await dlg().innerText()
  check('(b) a crédito muestra el saldo actual y el saldo después de esta compra', /Saldo actual/.test(text) && /Después de esta compra/.test(text), text.slice(-260).replace(/\n/g, ' '))
  const due = await dlg().getByLabel('Vencimiento').inputValue()
  const expected = sql(`select (current_date + 15)::text`)
  check('(b) el vencimiento se pre-carga con el plazo del PROVEEDOR (15 días)', due === expected && /plazo del proveedor \(15 días\)/.test(text), `${due} vs ${expected}`)
  await shot('humo-b-dialogo-credito', 'desktop', 'light')
  await registrar().click()
  await dlg().getByText('Compra registrada').waitFor({ timeout: 60000 })
  const s1 = snap()
  check('(b) el stock NO cambia y no hay movimiento de caja ni de banco', s1.h === s0.h && s1.a === s0.a && s1.cash === s0.cash && s1.bank === s0.bank && s1.mov === s0.mov, JSON.stringify([s0.h, s1.h, s0.cash, s1.cash]))
  check('(b) un cargo en la cuenta corriente del proveedor por el total, con el vencimiento del plazo', supplierMovs() === m0 + 1 && supplierBalance() === bal0 + total && new RegExp(`purchase:${total}@${expected}`).test(supplierMovTypes()), `${supplierMovTypes()} saldo ${bal0}->${supplierBalance()}`)
  await dlg().getByRole('button', { name: 'Cerrar' }).click()
  await go(`/proveedores/${sup}/cuenta`)
  await page.getByText('Compra / cargo').filter({ visible: true }).first().waitFor({ timeout: 60000 })
  const body = await page.locator('main').innerText()
  check('(b) la cuenta corriente del proveedor muestra el saldo con la compra', new RegExp(String(supplierBalance()).replace(/(\d)(?=(\d{3})+$)/g, '$1.')).test(body), body.slice(0, 200).replace(/\n/g, ' '))
  await shot('humo-b-cuenta-proveedor', 'desktop', 'light')
})

// (c) transferencia con cuenta bancaria: UN movimiento de banco ---------------------------------------------------------------
await step('c', async () => {
  const dn = await mkDn(tok)
  S.c = dn.id
  const s0 = snap()
  await go(`/remitos/${dn.id}`)
  await openConvert()
  await pickPaymentMethod(page, dlg(), /transferencia/i)
  check('(c) con una forma de pago bancaria se ofrece la cuenta bancaria destino', (await dlg().getByLabel(/cuenta bancaria/i).count()) >= 1)
  await dlg().getByLabel(/cuenta bancaria/i).first().click()
  await page.getByRole('option', { name: /Banco QA/ }).first().click()
  await registrar().click()
  await dlg().getByText('Compra registrada').waitFor({ timeout: 60000 })
  const s1 = snap()
  check('(c) stock sin cambios, UN movimiento de banco y ninguno de caja ni de cuenta corriente', s1.h === s0.h && s1.bank === s0.bank + 1 && s1.cash === s0.cash && s1.supMovs === s0.supMovs, `bank ${s0.bank}->${s1.bank}`)
  check('(c) el movimiento de banco es el egreso por el total de la compra', Number(sql(`select amount from bank_movements where account_id='${A}' order by created_at desc limit 1`)) === -2750, sql(`select amount from bank_movements where account_id='${A}' order by created_at desc limit 1`))
})

// (d) borrar la compra del remito por /compras: el remito vuelve a pendiente, el stock NO se toca, compensa caja ------------
await step('d', async () => {
  await ensureSession(tok)
  const dn = await mkDn(tok)
  S.d = dn.id
  const t = 2.5 * 700 + 4 * 250
  await convertViaUi(dn.id, /efectivo/i)
  const s0 = snap(); const op = opOfDn(dn.id); const rev0 = dnRev(dn.id)
  const text = await deleteViaUi(dn.id)
  await shot('humo-b-dialogo-borrado', 'desktop', 'light')
  check('(d) el diálogo de borrado dice que el remito vuelve a pendiente, que el stock NO vuelve (ya entró con el remito) y la compensación de caja', new RegExp(`El stock no vuelve: la mercadería quedó recibida con el remito ${dnLabel(dn.id)}, que vuelve a quedar pendiente`).test(text) && !/repone el stock|Se revertirá el ingreso de stock/i.test(text) && /ingreso correspondiente en la caja abierta/i.test(text), text.replace(/\n/g, ' ').slice(0, 330))
  await page.getByRole('alertdialog').getByRole('button', { name: /^Eliminar$/ }).click()
  await page.waitForTimeout(2500)
  const s1 = snap()
  check('(d) el remito vuelve a pendiente (issued) y no queda ninguna compra suya', dnStatus(dn.id) === 'issued' && purchaseRows(dn.id) === 0, `${dnStatus(dn.id)} filas ${purchaseRows(dn.id)}`)
  check('(d) el stock NO se toca al borrar (ni resta ni repone) y no hay movimientos nuevos', s1.h === s0.h && s1.a === s0.a && s1.mov === s0.mov, `h ${s0.h}->${s1.h} mov ${s0.mov}->${s1.mov}`)
  check('(d) la caja se compensa: contra-movimiento purchase_payment_reversal por el total', s1.cash === s0.cash + 1 && /purchase_payment_reversal:2750/.test(cashTypes(op)), cashTypes(op))
  check('(d) el historial del remito: issued > converted > issued, y la revisión no cambia', /issued>converted issued>issued$|converted>issued$/.test(dnHistory(dn.id)) && dnRev(dn.id) === rev0, `${dnHistory(dn.id)} rev ${rev0}->${dnRev(dn.id)}`)
  await go(`/remitos/${dn.id}`)
  check('(d) el detalle del remito vuelve a ofrecer "Compra", "Editar" y "Anular"', (await page.getByRole('button', { name: 'Compra', exact: true }).count()) === 1 && (await page.getByRole('link', { name: 'Editar' }).count()) === 1 && (await page.getByRole('button', { name: 'Anular' }).count()) === 1)
  await shot('humo-b-detalle-reabierto', 'desktop', 'light')
})

// (e) reconvertir el remito reabierto (otra compra, mismo stock) y borrar una compra a crédito (compensa la cuenta corriente) -----
await step('e', async () => {
  const dn = await mkDn(tok)
  S.e = dn.id
  const bal0 = supplierBalance()
  await convertViaUi(dn.id, /cuenta corriente/i)
  const op1 = opOfDn(dn.id)
  check('(e) a crédito: el saldo del proveedor sube por el total', supplierBalance() === bal0 + 2750, `${bal0}->${supplierBalance()}`)
  const s0 = snap()
  await deleteViaUi(dn.id)
  await page.getByRole('alertdialog').getByRole('button', { name: /^Eliminar$/ }).click()
  await page.waitForTimeout(2500)
  const s1 = snap()
  check('(e) borrar la compra a crédito compensa la cuenta corriente (saldo vuelve) y no toca el stock', supplierBalance() === bal0 && s1.h === s0.h && s1.mov === s0.mov && dnStatus(dn.id) === 'issued', `saldo ${supplierBalance()} (esperado ${bal0}); ${dnStatus(dn.id)}`)
  await convertViaUi(dn.id, /transferencia/i)
  const op2 = opOfDn(dn.id)
  const s2 = snap()
  check('(e) reconvertir crea OTRA compra (operation_id distinto) y el stock sigue idéntico', op2 && op2 !== op1 && s2.h === s0.h && s2.mov === s0.mov && dnStatus(dn.id) === 'converted' && Number(opsOfDn(dn.id)) === 1, `${op1} -> ${op2}`)
})

// (f) edición bloqueada: la UI lo anticipa y el servidor lo rechaza sin efectos -------------------------------------------------
await step('f', async () => {
  const dn = await mkDn(tok)
  await convertViaUi(dn.id, /transferencia/i)
  const ids = sql(`select string_agg(id::text, ',') from purchases where source_delivery_note_id='${dn.id}'`).split(',')
  const s0 = snap(); const total0 = purchaseTotal(opOfDn(dn.id))
  const r = await updPurchase(tok, ids, { items: [{ product_id: harina, quantity: 1, amount: 700, unit_id: kg }] })
  check('(f) PUT /purchases/operation sobre la compra de un remito: rechazado con delivery_note_purchase_locked', r.status >= 400 && /delivery_note_purchase_locked/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 160)}`)
  check('(f) sin efectos: ni stock, ni compra, ni dinero', same(snap(), s0) && purchaseTotal(opOfDn(dn.id)) === total0)
})

// (g) precio faltante: "Compra" deshabilitada con el motivo; cargado el precio, convierte ------------------------------------
await step('g', async () => {
  const dn = await mkDn(tok, [line(harina, 1, 700, { unit_id: kg }), line(sinCosto, 3, 0)])
  await go(`/remitos/${dn.id}`)
  const btn = page.getByRole('button', { name: 'Compra', exact: true })
  check('(g) con una línea sin precio "Compra" queda deshabilitada y explica por qué', (await btn.isDisabled()) && /Falta el precio de compra de 1 línea/.test(await page.locator('main').innerText()))
  await shot('humo-b-compra-sin-precio', 'desktop', 'light')
  const put = await be(tok, 'PUT', `/delivery-notes/${dn.id}`, { direction: 'purchase', revision: dnRev(dn.id), supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, items: [line(harina, 1, 700, { unit_id: kg }), line(sinCosto, 3, 120)] })
  check('(g) cargar el precio faltante (edición del remito)', put.status === 200, String(put.status))
  await go(`/remitos/${dn.id}`)
  check('(g) con todos los precios "Compra" se habilita', await page.getByRole('button', { name: 'Compra', exact: true }).isEnabled())
})

// (h) roles: stock y purchases convierten; el vendedor no; purchases no puede borrar la compra de un remito ------------------
await step('h', async () => {
  const dn = await mkDn(tok)
  for (const [who, expected] of [['seller', false], ['cashier', false], ['stock', true], ['purchases', true]]) {
    const c = await ctxFor(who)
    const p = await c.newPage()
    await go(`/remitos/${dn.id}`, p)
    await settle(p)
    const visible = (await p.getByRole('button', { name: 'Compra', exact: true }).count()) === 1
    check(`(h) ${who}: botón "Compra" ${expected ? 'visible' : 'oculto'}`, visible === expected)
    await c.close()
  }
  // purchases convierte y ve el borrado de la compra de un remito DESHABILITADO con su motivo
  const c = await ctxFor('purchases')
  const p = await c.newPage()
  await go(`/remitos/${dn.id}`, p)
  await settle(p)
  await p.getByRole('button', { name: 'Compra', exact: true }).click()
  await p.getByRole('dialog').getByText('Total de la compra').waitFor({ timeout: 30000 })
  await pickPaymentMethod(p, p.getByRole('dialog'), /transferencia/i)
  await registrar(p).click()
  await p.getByRole('dialog').getByText('Compra registrada').waitFor({ timeout: 60000 })
  check('(h) purchases convierte el remito (control positivo)', dnStatus(dn.id) === 'converted')
  bumpPurchaseDate(dn.id)
  await go('/compras', p)
  const badge = p.getByRole('link', { name: new RegExp(`Desde remito ${dnLabel(dn.id)}`) }).filter({ visible: true }).first()
  await badge.waitFor({ timeout: 60000 })
  const row = badge.locator("xpath=ancestor::*[.//button[@data-testid='delete-operation-trigger' or @data-testid='delete-operation-blocked']][1]")
  const blocked = row.locator("[data-testid='delete-operation-blocked']").filter({ visible: true }).first()
  check('(h) purchases NO puede borrar la compra de un remito: botón deshabilitado con el motivo', (await blocked.count()) === 1 && /requiere administrador o dueño/.test((await blocked.getAttribute('aria-label')) ?? ''), await blocked.getAttribute('aria-label'))
  const op = opOfDn(dn.id)
  const r = await delPurchase(await login(...USERS.purchases), op)
  check('(h) y el servidor lo rechaza igual (delivery_note_purchase_delete_forbidden), sin efectos', r.status >= 400 && /delivery_note_purchase_delete_forbidden/.test(JSON.stringify(r.body)) && dnStatus(dn.id) === 'converted' && purchaseRows(dn.id) > 0, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  await shot('humo-b-compras-borrado-bloqueado', 'desktop', 'light')
  await c.close()
})

// (i) aviso contra la doble suma en "Nueva compra" con un proveedor con remitos pendientes -----------------------------------
await step('i', async () => {
  const dn = await mkDn(tok)
  S.i = dn.id
  await go('/compras')
  await page.getByRole('button', { name: /nueva compra/i }).first().click()
  await page.getByRole('dialog').waitFor({ timeout: 30000 })
  await page.getByRole('dialog').getByRole('combobox', { name: /Proveedor/ }).click()
  await page.getByRole('option', { name: /Proveedor Demo QA/ }).first().click()
  const note = page.getByRole('dialog').getByRole('note')
  await note.waitFor({ timeout: 30000 })
  const txt = await note.innerText()
  check('(i) elegir un proveedor con remitos de compra pendientes muestra el aviso contra la doble suma', /Este proveedor tiene \d+ remitos? de compra pendientes?/.test(txt) && /para no sumar el stock dos veces/.test(txt), txt.replace(/\n/g, ' '))
  const href = await note.getByRole('link').getAttribute('href')
  check('(i) el enlace lleva a la pestaña De compra, pendientes, de ese proveedor', href === `/remitos?sentido=compra&estado=pendientes&proveedor=${sup}`, href)
  await shot('humo-b-aviso-doble-suma', 'desktop', 'light')
  await page.keyboard.press('Escape')
})

// (j) compra directa en paralelo sigue sumando stock (regresión) -----------------------------------------------------------------
await step('j', async () => {
  const h0 = stockAll(aceite); const m0 = allStockMovs()
  const r = await be(tok, 'POST', '/purchases', {
    org_id: A, items: [{ product_id: aceite, quantity: 5, amount: 400 }], branch_id: br1, supplier_id: sup, payment_method_id: pmId('transfer'),
  }, { 'Idempotency-Key': key() })
  check('(j) compra directa por la API: 201', r.status === 201, `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
  check('(j) la compra DIRECTA suma el stock (+5) con movimiento purchase/purchase', stockAll(aceite) === h0 + 5 && allStockMovs() === m0 + 1 && /^purchase\/purchase:5$/.test(sql(`select coalesce(string_agg(type||'/'||reference_type||':'||quantity_delta::float8, ' '),'') from stock_movements where reference_id in (select id from purchases where operation_id='${r.body.operation_id}')`)), `${h0}->${stockAll(aceite)}`)
  check('(j) la compra directa no lleva remito de origen', sql(`select count(*) from purchases where operation_id='${r.body.operation_id ?? r.body.id}' and source_delivery_note_id is not null`) === '0')
})

// (k) un remito CONVERTIDO no se edita ni se anula: la UI no lo ofrece y la pantalla de edición / el servidor lo rechazan sin efectos
await step('k', async () => {
  const dn = await mkDn(tok)
  const c = await convApi(tok, dn.id, convBody(dn.id, 'transfer'))
  check('(k) preparación: el remito se convierte por la API (200)', c.status === 200 && dnStatus(dn.id) === 'converted', `${c.status}`)
  const s0 = snap(); const rev0 = dnRev(dn.id); const h0 = dnHistory(dn.id)
  const put = await be(tok, 'PUT', `/delivery-notes/${dn.id}`, { direction: 'purchase', revision: rev0, supplier_id: sup, branch_id: br1, supplier_reference: null, notes: 'edición indebida', items: [line(harina, 9, 700, { unit_id: kg })] })
  check('(k) editar un remito convertido por la API se rechaza (delivery_note_locked_converted)', put.status >= 400 && /delivery_note_locked_converted/.test(JSON.stringify(put.body)), `${put.status} ${JSON.stringify(put.body).slice(0, 140)}`)
  const cancel = await be(tok, 'POST', `/delivery-notes/${dn.id}/cancel`, { revision: rev0, reason: 'anulación indebida' })
  check('(k) anular un remito convertido por la API se rechaza (delivery_note_locked_converted)', cancel.status >= 400 && /delivery_note_locked_converted/.test(JSON.stringify(cancel.body)), `${cancel.status} ${JSON.stringify(cancel.body).slice(0, 140)}`)
  check('(k) sin efectos: remito converted, misma revisión e historial, stock y dinero intactos', dnStatus(dn.id) === 'converted' && dnRev(dn.id) === rev0 && dnHistory(dn.id) === h0 && same(snap(), s0), `${dnStatus(dn.id)} rev ${rev0}->${dnRev(dn.id)}`)
  await go(`/remitos/${dn.id}/editar`)
  await page.waitForTimeout(2500)
  const body = await page.locator('main').innerText()
  const guardado = page.getByRole('button', { name: /Guardar/ })
  check('(k) la pantalla de edición de un remito convertido no ofrece guardar (o redirige / explica)', (await guardado.count()) === 0 || (await guardado.first().isDisabled()), body.slice(0, 160).replace(/\n/g, ' ') + ' @ ' + page.url())
  await shot('humo-b-editar-convertido', 'desktop', 'light')
})

console.log('\n══ resumen: errores de consola:', errs.length, errs.slice(0, 5), '404:', JSON.stringify([...new Set(notFound)].slice(0, 8)))
const bad = results.filter(([, ok]) => !ok)
console.log(`══ ${results.length - bad.length}/${results.length} PASS`)
await browser.close()
process.exit(bad.length ? 1 : 0)
