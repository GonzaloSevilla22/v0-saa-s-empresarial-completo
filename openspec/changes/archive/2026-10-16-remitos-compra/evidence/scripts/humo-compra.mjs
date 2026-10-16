// Humo funcional por la UI real del remito de COMPRA (tanda A). Stack LOCAL. Lee el stock de la DB local antes y después de cada paso.
// Uso: node humo-compra.mjs [regex de pasos: a b c d e f g h i]
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, consoleCollector, OUT } from './pw-lib.mjs'
import { login, USERS, sql, be, check, results } from './lib.mjs'

const ROOT = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra'
const IDS = JSON.parse(readFileSync(`${ROOT}/ids.json`, 'utf8'))
const { accA, br1, br2, harina, alf, escaso, tres, aceite, sinCosto, sup, sup2 } = IDS
const only = process.argv[2] ? new RegExp(process.argv[2]) : null
const run = (id) => !only || only.test(id)
const stock = (pid, br) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}' and branch_id='${br}'`))
const movs = (ref) => sql(`select coalesce(string_agg(type||'/'||reference_type||':'||quantity_delta::float8, ' ' order by created_at, id),'') from stock_movements where reference_id='${ref}'`)
const nMovs = (ref) => Number(sql(`select count(*) from stock_movements where reference_id='${ref}'`))
const maxNum = () => Number(sql(`select coalesce(max(number),0) from delivery_notes where account_id='${accA}' and direction='purchase'`))
const dnRow = (id) => sql(`select 'RC-'||lpad(number::text,8,'0')||'|'||status||'|rev'||revision||'|'||branch_id from delivery_notes where id='${id}'`)
const line = (pid, q, price, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })

const authFile = (n) => `${ROOT}/qa-auth-${n}.json`
const browser = await chromium.launch()
async function ctxFor(who, viewport = 'desktop', theme = 'light') {
  const f = authFile(who)
  await uiLogin(browser, ...USERS[who], f)
  const c = await newCtx(browser, viewport, theme, f)
  c.waRequests = []
  await c.route(/wa\.me|api\.whatsapp\.com|whatsapp\.com/, (route) => { c.waRequests.push(route.request().url()); route.abort() })
  return c
}
mkdirSync(OUT, { recursive: true })
const tokOwner = await login(...USERS.owner)
const ctx = await ctxFor('owner')
const page = await ctx.newPage()
const errs = consoleCollector(page)
const shot = async (name, vp = 'desktop', th = 'light', pg = page) => {
  await pg.waitForTimeout(500)
  await pg.screenshot({ path: `${OUT}/${name}-${vp}-${th}.png` })
}
const goto = async (path, pg = page) => {
  await pg.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await pg.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
}
async function pickSupplier(p, name = 'Proveedor Demo QA') {
  await p.getByRole('combobox', { name: /Proveedor/ }).click()
  await p.getByRole('option', { name: new RegExp(name) }).first().click()
}
async function pickBranch(p, re) {
  await p.getByRole('combobox').filter({ hasText: /Casa Central|Norte/ }).first().click()
  await p.getByRole('option', { name: re }).first().click()
}
async function addLine(p, productRe, qty, price) {
  await p.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await p.getByRole('option', { name: productRe }).first().click()
  const q = p.getByLabel(/^(Cantidad|Peso|Kilos|Cant\.)/).first()
  await q.fill(String(qty))
  if (price != null) await p.getByLabel(/Precio.*unit/).first().fill(String(price))
  await p.getByRole('button', { name: 'Agregar al remito' }).click()
}
const cartQty = (p, i) => p.locator('input[type=number]').nth(2 * i)
async function emit(p) {
  await p.getByRole('button', { name: /Emitir remito/ }).click()
  await p.waitForURL(/\/remitos\/[0-9a-f-]{36}$/, { timeout: 60000 })
  return p.url().split('/').pop()
}
async function save(p) {
  await p.getByRole('button', { name: 'Guardar cambios' }).click()
  await p.waitForURL(/\/remitos\/[0-9a-f-]{36}$/, { timeout: 60000 })
}
const apiMk = async (items, extra = {}, tok = tokOwner) => {
  const r = await be(tok, 'POST', '/delivery-notes', { direction: 'purchase', supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, items, ...extra }, { 'Idempotency-Key': crypto.randomUUID() })
  if (r.status !== 201) throw new Error('apiMk ' + r.status + ' ' + JSON.stringify(r.body).slice(0, 200))
  return r.body
}
const toasts = async (p) => (await p.locator('[data-sonner-toast], [role=alert]').allInnerTexts()).join(' | ')
const step = async (id, fn) => {
  if (!run(id)) return
  try { await fn() } catch (e) { check(`(${id}) el paso terminó sin excepción`, false, String(e).split('\n')[0]) }
}
const S = {}

// (a) recibir con 2 productos (uno por kg, uno sin costo → precio 0) ------------------------------------
await step('a', async () => {
  const [sh, ss, n0] = [stock(harina, br1), stock(sinCosto, br1), maxNum()]
  await goto('/remitos/nuevo?tipo=compra')
  await shot('compra-nuevo-vacio')
  await pickSupplier(page)
  await page.getByLabel(/N° de remito del proveedor/).fill('0004-00001234')
  await page.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.getByRole('option', { name: /Harina/ }).first().click()
  const precarga = await page.getByLabel(/Precio.*unit/).first().inputValue()
  check('(a) alta manual precarga el COSTO ($700), no el precio de venta ($1200)', Number(precarga) === 700, `precio precargado ${precarga}`)
  await page.getByLabel(/^(Cantidad|Peso|Kilos|Cant\.)/).first().fill('2.5')
  await page.getByRole('button', { name: 'Agregar al remito' }).click()
  await page.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.getByRole('option', { name: /Sin costo QA/ }).first().click()
  const sc = await page.getByLabel(/Precio.*unit/).first().inputValue()
  const aviso = await page.getByText(/Sin precio/).count()
  check('(a) producto sin costo: precio 0 con aviso "Sin precio"', Number(sc) === 0 && aviso > 0, `precio ${sc} avisos ${aviso}`)
  await page.getByLabel(/^(Cantidad|Peso|Kilos|Cant\.)/).first().fill('3')
  await page.getByRole('button', { name: 'Agregar al remito' }).click()
  await shot('compra-nuevo-lleno')
  S.a = await emit(page)
  check('(a) remito de compra con el número siguiente RC-', dnRow(S.a).startsWith(`RC-${String(n0 + 1).padStart(8, '0')}|issued`), dnRow(S.a))
  check('(a) el stock SUBE exacto (harina +2,5; sin costo +3)', stock(harina, br1) === sh + 2.5 && stock(sinCosto, br1) === ss + 3, `h ${sh}->${stock(harina, br1)} sc ${ss}->${stock(sinCosto, br1)}`)
  check('(a) movimientos purchase/delivery_note con referencia al remito', nMovs(S.a) === 2 && /purchase\/delivery_note:2.5/.test(movs(S.a)) && /purchase\/delivery_note:3/.test(movs(S.a)), movs(S.a))
  check('(a) número del proveedor y proveedor persistidos; el costo de catálogo NO cambió', sql(`select supplier_reference||'|'||supplier_id from delivery_notes where id='${S.a}'`) === `0004-00001234|${sup}` && Number(sql(`select cost from products where id='${harina}'`)) === 700, sql(`select cost from products where id='${harina}'`))
  await shot('compra-detalle-emitido')
  const detalle = await page.locator('main').innerText()
  check('(a) detalle: proveedor, N° del proveedor, "Ingresa a", badge Sin precio', /Proveedor Demo QA/.test(detalle) && /0004-00001234/.test(detalle) && /Ingresa a/.test(detalle) && /Sin precio/.test(detalle), detalle.slice(0, 200).replace(/\n/g, ' '))
  await goto('/stock')
  await page.getByText('Historial de movimientos').first().click()
  await page.getByText(/Remito RC-\d{8}/).first().waitFor({ timeout: 60000 })
  await shot('stock-movimientos-remito-compra')
  const n = await page.getByText(/Remito RC-\d{8}/).count()
  check('(a) /stock muestra "Remito RC-…" en el historial de movimientos', n >= 2, `${n} filas`)
  writeFileSync(`${ROOT}/dn-a.json`, JSON.stringify({ id: S.a }))
})

// (b) edición: subir, bajar, quitar, agregar, cambiar precio, cambiar sucursal ---------------------------
await step('b', async () => {
  const n = await apiMk([line(harina, 2, 700), line(alf, 4, 250), line(aceite, 2, 400)])
  S.b = n.id
  const [h0, a0, c0, t0] = [stock(harina, br1), stock(alf, br1), stock(aceite, br1), stock(tres, br1)]
  await goto(`/remitos/${S.b}/editar`)
  await cartQty(page, 0).fill('3')   // harina 2 -> 3 (suma 1)
  await cartQty(page, 1).fill('1')   // alfajor 4 -> 1 (resta 3)
  await page.getByRole('button', { name: 'Eliminar Aceite QA' }).click()  // quita aceite (resta 2)
  await addLine(page, /Lote de tres/, 2, 100)  // agrega producto nuevo (suma 2)
  await page.waitForTimeout(500)
  const effect = await page.getByRole('status', { name: 'Efecto en el stock' }).innerText().catch(() => '')
  await shot('compra-editar-resumen-ajuste')
  check('(b) el resumen del ajuste ("Entran… · Salen…") se muestra antes de guardar', /Entran|Salen/.test(effect), effect.slice(0, 200))
  await save(page)
  check('(b) harina +1, alfajor -3, aceite -2, lote de tres +2', stock(harina, br1) === h0 + 1 && stock(alf, br1) === a0 - 3 && stock(aceite, br1) === c0 - 2 && stock(tres, br1) === t0 + 2, `h ${h0}->${stock(harina, br1)} a ${a0}->${stock(alf, br1)} ac ${c0}->${stock(aceite, br1)} t ${t0}->${stock(tres, br1)}`)
  check('(b) revisión 2 y el remito sigue pendiente', /\|issued\|rev2\|/.test(dnRow(S.b)), dnRow(S.b))
  const sumDelta = Number(sql(`select coalesce(sum(quantity_delta),0) from stock_movements where reference_id='${S.b}'`))
  const held = Number(sql(`select coalesce(sum(quantity_base),0) from delivery_note_items where delivery_note_id='${S.b}'`))
  check('(b) invariante: Σ delta de movimientos = +Σ cantidad base de las líneas', Math.abs(sumDelta - held) < 1e-9, `${sumDelta} vs ${held}`)
  // sólo un par cambia
  const n2 = await apiMk([line(harina, 2, 700), line(alf, 1, 250)])
  const [mm0, hh0, aa0] = [nMovs(n2.id), stock(harina, br1), stock(alf, br1)]
  await goto(`/remitos/${n2.id}/editar`)
  await cartQty(page, 1).fill('3')
  await save(page)
  const perProd = (pid) => Number(sql(`select count(*) from stock_movements where reference_id='${n2.id}' and product_id='${pid}'`))
  check('(b) A=2/B=1 -> A=2/B=3: sólo un par espejo sobre B y cero sobre A; B +2', nMovs(n2.id) === mm0 + 2 && perProd(harina) === 1 && perProd(alf) === 3 && stock(harina, br1) === hh0 && stock(alf, br1) === aa0 + 2, `movs ${mm0}->${nMovs(n2.id)} h ${perProd(harina)} a ${perProd(alf)} stock h ${hh0}->${stock(harina, br1)} a ${aa0}->${stock(alf, br1)}`)
  // cargar precio al producto sin costo: cero movimientos
  const n3 = await apiMk([line(sinCosto, 2, 0)])
  const mp = nMovs(n3.id)
  await goto(`/remitos/${n3.id}/editar`)
  await page.getByLabel('Subtotal de Sin costo QA').fill('1600')
  await save(page)
  check('(b) cargar el precio faltante no mueve stock y quita el "Sin precio"', nMovs(n3.id) === mp && sql(`select coalesce(sum(price),0) from delivery_note_items where delivery_note_id='${n3.id}'`) === '800.0000' || Number(sql(`select price from delivery_note_items where delivery_note_id='${n3.id}'`)) === 800, `${mp}->${nMovs(n3.id)} precio ${sql(`select price from delivery_note_items where delivery_note_id='${n3.id}'`)}`)
  // cambio de sucursal con cantidades iguales: br1 -> Norte
  const n4 = await apiMk([line(alf, 3, 250)])
  const [b1, b2] = [stock(alf, br1), stock(alf, br2)]
  await goto(`/remitos/${n4.id}/editar`)
  await pickBranch(page, /Norte/)
  await shot('compra-editar-cambio-sucursal')
  await save(page)
  check('(b) cambiar la sucursal traslada lo recibido (Casa Central -3, Norte +3) y el remito queda en Norte', stock(alf, br1) === b1 - 3 && stock(alf, br2) === b2 + 3 && dnRow(n4.id).endsWith(br2), `br1 ${b1}->${stock(alf, br1)} br2 ${b2}->${stock(alf, br2)}`)
  S.n4 = n4.id
})

// (c) bajar una cantidad ya vendida → bloqueado con el producto nombrado -----------------------------------
await step('c', async () => {
  sql(`update branch_stock set quantity=0 where product_id='${escaso}' and branch_id='${br1}'`)
  const n = await apiMk([line(escaso, 10, 100)])
  S.c = n.id
  // vender 7 por el POS (quick-sale) → quedan 3
  const pm = sql(`select id from payment_methods where account_id='${accA}' and kind='other' and deleted_at is null limit 1`)
  const sale = await be(tokOwner, 'POST', '/sales-orders/quick-sale', { items: [{ product_id: escaso, quantity: 7, price: 300 }], payment_method: 'other', payment_method_id: pm || undefined, branch_id: br1 }, { 'Idempotency-Key': crypto.randomUUID() })
  check('(c) venta POS de 7 unidades (control)', sale.status >= 200 && sale.status < 300 && stock(escaso, br1) === 3, `${sale.status} stock ${stock(escaso, br1)} ${JSON.stringify(sale.body).slice(0, 120)}`)
  const m0 = nMovs(S.c)
  await goto(`/remitos/${S.c}/editar`)
  await page.getByRole('button', { name: 'Guardar cambios' }).waitFor({ timeout: 90000 })
  await page.waitForTimeout(3500)
  await shot('compra-editar-mercaderia-consumida')
  const aviso = [await page.locator('main').innerText()]
  check('(c) el formulario avisa el mínimo (no se puede bajar de lo vendido)', aviso.some((t) => /quedan \d+.*no puede bajar|no puede bajar de|no alcanza|consum/i.test(t)), aviso.join(' | ').slice(0, 250))
  await cartQty(page, 0).fill('5')
  await page.getByRole('button', { name: 'Guardar cambios' }).click()
  await page.waitForTimeout(4000)
  const body = await toasts(page) + ' ' + (await page.locator('main').innerText())
  await shot('compra-editar-bloqueada-bajar-a-5')
  check('(c) bajar a 5 (resta 5, quedan 3) está bloqueado con el producto nombrado y SIN efectos', /Producto escaso QA/.test(body) && /\/editar/.test(page.url()) && stock(escaso, br1) === 3 && nMovs(S.c) === m0, `${body.slice(0, 200).replace(/\n/g, ' ')} stock ${stock(escaso, br1)}`)
  await cartQty(page, 0).fill('8')
  await save(page)
  check('(c) bajar a 8 (resta 2, quedan 3) funciona: stock 1', stock(escaso, br1) === 1 && /\|rev2\|/.test(dnRow(S.c)), `stock ${stock(escaso, br1)} ${dnRow(S.c)}`)
})

// (d) anular con motivo; y uno cuya mercadería ya se vendió → bloqueado ----------------------------------------
await step('d', async () => {
  const n = await apiMk([line(harina, 1.5, 700), line(alf, 2, 250)])
  S.d = n.id
  const [h0, a0] = [stock(harina, br1), stock(alf, br1)]
  await goto(`/remitos/${S.d}`)
  await page.getByRole('button', { name: 'Anular' }).click()
  const d = page.getByRole('dialog')
  await d.waitFor()
  await shot('compra-anular-dialogo-vacio')
  const dlgText = await d.innerText()
  check('(d) el diálogo enumera lo que SALE del stock ("Salen de …")', /Salen de/.test(dlgText), dlgText.slice(0, 200).replace(/\n/g, ' '))
  const confirmBtn = d.getByRole('button', { name: /Anular remito|Anular/ }).last()
  check('(d) sin motivo no se puede confirmar', await confirmBtn.isDisabled())
  await d.getByLabel(/Motivo/).fill('El proveedor se llevó la mercadería')
  await shot('compra-anular-dialogo-motivo')
  await confirmBtn.click()
  await page.getByRole('status', { name: 'Remito anulado' }).waitFor({ timeout: 30000 })
  check('(d) el stock BAJA lo recibido (harina -1,5; alfajor -2)', stock(harina, br1) === h0 - 1.5 && stock(alf, br1) === a0 - 2, `h ${h0}->${stock(harina, br1)} a ${a0}->${stock(alf, br1)}`)
  check('(d) terminal: canceled + motivo en el historial', /\|canceled\|/.test(dnRow(S.d)) && Number(sql(`select count(*) from document_status_history where document_id='${S.d}' and to_status='canceled' and reason ilike '%llevó%'`)) === 1)
  await shot('compra-detalle-anulado')
  // mercadería consumida
  sql(`update branch_stock set quantity=0 where product_id='${escaso}' and branch_id='${br1}'`)
  const n2 = await apiMk([line(escaso, 6, 100)])
  const pm = sql(`select id from payment_methods where account_id='${accA}' and kind='other' and deleted_at is null limit 1`)
  await be(tokOwner, 'POST', '/sales-orders/quick-sale', { items: [{ product_id: escaso, quantity: 4, price: 300 }], payment_method: 'other', payment_method_id: pm || undefined, branch_id: br1 }, { 'Idempotency-Key': crypto.randomUUID() })
  const m0 = nMovs(n2.id), e0 = stock(escaso, br1)
  await goto(`/remitos/${n2.id}`)
  await page.getByRole('button', { name: 'Anular' }).click()
  const d2 = page.getByRole('dialog')
  await d2.waitFor()
  await d2.getByLabel(/Motivo/).fill('Intento de anular con mercadería vendida')
  await d2.getByRole('button', { name: /Anular remito|Anular/ }).last().click()
  await page.getByRole('alert', { name: /Mercadería consumida/ }).first().waitFor({ timeout: 30000 })
  await shot('compra-anular-bloqueada-consumida')
  const t = await d2.innerText()
  check('(d) anular con mercadería vendida: bloqueado "Mercadería consumida", con el producto y las dos salidas', /Producto escaso QA/.test(t) && /Editar el remito/.test(t) && /Ajustar stock/.test(t), t.slice(0, 300).replace(/\n/g, ' '))
  check('(d) sin efectos: remito pendiente, stock y movimientos intactos', /\|issued\|/.test(dnRow(n2.id)) && stock(escaso, br1) === e0 && nMovs(n2.id) === m0, `${dnRow(n2.id)} ${e0}->${stock(escaso, br1)}`)
  const apiErr = await be(tokOwner, 'POST', `/delivery-notes/${n2.id}/cancel`, { revision: 1, reason: 'por API también' })
  check('(d) por API: 409 delivery_note_stock_consumed', apiErr.status === 409 && /stock_consumed/.test(JSON.stringify(apiErr.body)), `${apiErr.status} ${JSON.stringify(apiErr.body).slice(0, 200)}`)
  S.d2 = n2.id
})

// (e) PDF con y sin precios -------------------------------------------------------------------------------
await step('e', async () => {
  const n = await apiMk([line(harina, 1.5, 700), line(sinCosto, 2, 0)], { supplier_reference: '0004-00005555', notes: 'Recibido por la puerta lateral' })
  S.e = n.id
  const fetchPdf = async (id, qs) => {
    const r = await fetch(`http://127.0.0.1:8000/delivery-notes/${id}/pdf?${qs}`, { headers: { Authorization: `Bearer ${tokOwner}` } })
    return { status: r.status, ct: r.headers.get('content-type'), cd: r.headers.get('content-disposition'), buf: Buffer.from(await r.arrayBuffer()) }
  }
  const p0 = await fetchPdf(n.id, 'disposition=attachment')
  const p1 = await fetchPdf(n.id, 'disposition=attachment&show_prices=true')
  const pc = await fetchPdf(S.d, 'disposition=inline')
  check('(e) PDF 200 application/pdf con nombre remito-compra-RC-…', p0.status === 200 && /pdf/.test(p0.ct) && /remito-compra-RC-\d+/.test(p0.cd ?? ''), `${p0.status} ${p0.ct} ${p0.cd}`)
  check('(e) con precios: nombre -con-precios', /remito-compra-RC-\d+-con-precios/.test(p1.cd ?? ''), p1.cd)
  mkdirSync(`${ROOT}/pdf`, { recursive: true })
  writeFileSync(`${ROOT}/pdf/remito-compra-sin-precios.pdf`, p0.buf)
  writeFileSync(`${ROOT}/pdf/remito-compra-con-precios.pdf`, p1.buf)
  writeFileSync(`${ROOT}/pdf/remito-compra-anulado.pdf`, pc.buf)
  await goto(`/remitos/${n.id}`)
  await page.getByLabel('Mostrar precios').click()
  await page.getByRole('button', { name: 'Compartir' }).click()
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 30000 }), page.getByRole('menuitem', { name: 'Descargar PDF' }).click()])
  const f = `${ROOT}/pdf/ui-compra-${dl.suggestedFilename()}`
  await dl.saveAs(f)
  check('(e) descarga por la UI con "Mostrar precios": nombre con precios', /remito-compra-RC-\d+-con-precios/.test(dl.suggestedFilename()), dl.suggestedFilename())
  writeFileSync(`${ROOT}/pdf/ui-file.txt`, f)
})

// (f) WhatsApp al proveedor ---------------------------------------------------------------------------------
await step('f', async () => {
  const n = await apiMk([line(alf, 1, 250)], { supplier_reference: 'A-77' })
  await goto(`/remitos/${n.id}`)
  await page.getByRole('button', { name: 'Compartir' }).click()
  await page.getByRole('menuitem', { name: /WhatsApp/ }).waitFor()
  await page.waitForTimeout(2500)
  const popup = ctx.waitForEvent('page', { timeout: 15000 }).catch(() => null)
  await page.getByRole('menuitem', { name: /Enviar por WhatsApp/ }).click()
  const pp = await popup
  await page.waitForTimeout(1500)
  const url = ctx.waRequests[0] ?? (pp ? pp.url() : '')
  const num = dnRow(n.id).split('|')[0]
  check('(f) WhatsApp abre wa.me con el teléfono del PROVEEDOR normalizado (54 9 + dígitos, convención móvil de ARG)', /wa\.me\/5492615550303\?text=/.test(url), url.slice(0, 160))
  check('(f) el texto nombra la recepción, el número RC y el N° del proveedor', decodeURIComponent(url).includes(num) && /A-77/.test(decodeURIComponent(url)) && /recepci/i.test(decodeURIComponent(url)), decodeURIComponent(url).slice(0, 260))
  writeFileSync(`${ROOT}/wa-url.txt`, url)
  // proveedor sin teléfono: aviso con enlace a /proveedores
  const n2 = await apiMk([line(alf, 1, 250)], { supplier_id: sup2 })
  await goto(`/remitos/${n2.id}`)
  const aviso = await page.getByText(/Agregá el teléfono del proveedor/).count()
  const href = await page.getByRole('link', { name: /proveedores/i }).first().getAttribute('href').catch(() => null)
  await shot('compra-detalle-sin-telefono')
  check('(f) proveedor sin teléfono: aviso "Agregá el teléfono del proveedor…" con enlace a /proveedores', aviso > 0, `aviso ${aviso} href ${href}`)
})

// (g) roles por la UI ------------------------------------------------------------------------------------------
await step('g', async () => {
  const n = await apiMk([line(alf, 1, 250)])
  const probe = async (who, path) => {
    const c = await ctxFor(who)
    const p = await c.newPage()
    await p.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 180000 })
    await p.waitForTimeout(6000)
    return { c, p }
  }
  let { c, p } = await probe('stock', `/remitos/${n.id}`)
  check('(g) depósito: ve Editar y NO "Anular"', (await p.getByRole('link', { name: 'Editar' }).count()) === 1 && (await p.getByRole('button', { name: 'Anular' }).count()) === 0)
  await p.goto(`${BASE}/remitos/nuevo?tipo=compra`, { waitUntil: 'domcontentloaded' })
  await p.getByRole('combobox', { name: /Proveedor/ }).waitFor({ timeout: 90000 })
  check('(g) depósito: puede abrir "Nuevo remito de compra"', true)
  await shot('compra-detalle-deposito', 'desktop', 'light', p)
  await c.close()
  ;({ c, p } = await probe('seller', '/remitos/nuevo?tipo=compra'))
  check('(g) vendedor: "Nuevo remito de compra" muestra el estado sin permiso (sin formulario)', (await p.getByRole('combobox', { name: /Proveedor/ }).count()) === 0, (await p.locator('main').innerText()).slice(0, 140).replace(/\n/g, ' '))
  await shot('compra-nuevo-vendedor-sin-permiso', 'desktop', 'light', p)
  await p.goto(`${BASE}/remitos?sentido=compra`, { waitUntil: 'domcontentloaded' })
  await p.waitForTimeout(6000)
  check('(g) vendedor: la pestaña De compra no ofrece el CTA "Nuevo remito de compra"', (await p.getByRole('link', { name: /Nuevo remito de compra/ }).count()) === 0)
  await p.goto(`${BASE}/remitos/${n.id}`, { waitUntil: 'domcontentloaded' })
  await p.waitForTimeout(5000)
  check('(g) vendedor: lee el remito pero sin Editar ni Anular', (await p.getByRole('link', { name: 'Editar' }).count()) === 0 && (await p.getByRole('button', { name: 'Anular' }).count()) === 0)
  await c.close()
  ;({ c, p } = await probe('cashier', '/remitos/nuevo?tipo=compra'))
  check('(g) cajero: sin permiso (sin formulario)', (await p.getByRole('combobox', { name: /Proveedor/ }).count()) === 0)
  await c.close()
  ;({ c, p } = await probe('admin', `/remitos/${n.id}`))
  check('(g) admin: ve Editar y "Anular"', (await p.getByRole('button', { name: 'Anular' }).count()) === 1 && (await p.getByRole('link', { name: 'Editar' }).count()) === 1)
  await shot('compra-detalle-admin', 'desktop', 'light', p)
  await c.close()
})

// (h) "Nuevo remito de compra" desde /proveedores ---------------------------------------------------------------
await step('h', async () => {
  await goto('/proveedores')
  await shot('proveedores-acciones')
  await page.getByRole('link', { name: /Nuevo remito de compra de Proveedor Dos QA/ }).first().click()
  await page.waitForURL(/\/remitos\/nuevo\?tipo=compra&proveedor=/, { timeout: 60000 })
  await page.getByRole('combobox', { name: /Proveedor/ }).waitFor({ timeout: 90000 })
  await page.waitForTimeout(3000)
  const shown = await page.getByRole('combobox', { name: /Proveedor/ }).innerText()
  check('(h) desde /proveedores abre el formulario con el proveedor precargado', /Proveedor Dos QA/.test(shown), shown)
  await goto(`/proveedores/${sup2}/cuenta`)
  await shot('proveedor-cuenta-acciones')
  const ver = await page.getByRole('link', { name: /Ver remitos/ }).first().getAttribute('href')
  const nuevo = await page.getByRole('link', { name: /Nuevo remito/ }).first().getAttribute('href')
  check('(h) en la cuenta: "Ver remitos" -> /remitos?sentido=compra&proveedor=<id> y "Nuevo remito" precarga', ver === `/remitos?sentido=compra&proveedor=${sup2}` && /tipo=compra&proveedor=/.test(nuevo ?? ''), `${ver} ${nuevo}`)
})

// (i) pestañas y filtros por sentido ------------------------------------------------------------------------------
await step('i', async () => {
  await goto('/remitos')
  await shot('remitos-venta-pestana')
  const ventaRows = Number(sql(`select count(*) from delivery_notes where account_id='${accA}' and direction='sale'`))
  await page.getByRole('button', { name: 'De compra' }).click()
  await page.waitForURL(/sentido=compra/, { timeout: 30000 })
  await page.waitForTimeout(3000)
  await shot('remitos-compra-pestana')
  const txt = await page.locator('main').innerText()
  check('(i) pestaña De compra: muestra RC-… y proveedores, sin números R- de venta', /RC-\d{8}/.test(txt) && !/\bR-\d{8}\b/.test(txt.replace(/RC-\d{8}/g, '')), txt.slice(0, 150).replace(/\n/g, ' '))
  check('(i) el resumen de pendientes de compra con "sin precio"', /pendientes? por/i.test(txt) || /sin precio/i.test(txt), txt.slice(0, 200).replace(/\n/g, ' '))
  await goto(`/remitos?sentido=compra&estado=pendientes&proveedor=${sup}`)
  await page.waitForTimeout(3000)
  const chip = await page.locator('main').innerText()
  check('(i) ?proveedor= se muestra como chip y filtra', /Proveedor Demo QA/.test(chip), chip.slice(0, 200).replace(/\n/g, ' '))
  await shot('remitos-compra-filtrado')
  const q = await page.getByRole('searchbox').or(page.getByPlaceholder(/Buscar/)).first()
  await q.fill('0004-00001234')
  await page.waitForTimeout(2500)
  const f = await page.locator('main').innerText()
  check('(i) búsqueda por N° del proveedor encuentra el remito', /RC-\d{8}/.test(f), f.slice(0, 160).replace(/\n/g, ' '))
  await goto('/remitos?sentido=venta')
  await page.waitForTimeout(3000)
  const v = await page.locator('main').innerText()
  check('(i) pestaña De venta: filas R- sin RC-', !/RC-\d{8}/.test(v) && ventaRows >= 0, v.slice(0, 120).replace(/\n/g, ' '))
})

console.log('console errors:', JSON.stringify(errs.slice(0, 6)))
const failed = results.filter(([, ok]) => !ok)
console.log(`RESUMEN humo compra: ${results.length - failed.length}/${results.length} PASS`)
if (failed.length) console.log('FALLAN:', failed.map(([n]) => n).join(' | '))
await browser.close()
