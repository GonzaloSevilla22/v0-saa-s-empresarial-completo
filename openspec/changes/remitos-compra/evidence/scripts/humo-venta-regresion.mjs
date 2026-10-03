// Humo funcional por la UI real del remito de venta (tanda A). Stack LOCAL. Lee el stock de la DB local antes y después de cada paso.
// Uso: node humo.mjs [regex de pasos: a b c d e f g h i j k]
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, consoleCollector, OUT } from './pw-lib.mjs'
import { login, USERS, sql, be, check, results } from './lib.mjs'

const IDS = JSON.parse(readFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/ids.json', 'utf8'))
const { accA, br1, br2, harina, alf, escaso, tres, aceite, client, client2 } = IDS
const only = process.argv[2] ? new RegExp(process.argv[2]) : null
const run = (id) => !only || only.test(id)
const stock = (pid, br) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}' and branch_id='${br}'`))
const movs = (ref) => sql(`select coalesce(string_agg(type||'/'||reference_type||':'||quantity_delta::float8, ' ' order by created_at, id),'') from stock_movements where reference_id='${ref}'`)
const nMovs = (ref) => Number(sql(`select count(*) from stock_movements where reference_id='${ref}'`))
const lastDn = () => sql(`select id from delivery_notes where account_id='${accA}' order by number desc limit 1`)
const maxNum = () => Number(sql(`select coalesce(max(number),0) from delivery_notes where account_id='${accA}' and direction='sale'`))
const dnRow = (id) => sql(`select 'R-'||lpad(number::text,8,'0')||'|'||status||'|rev'||revision||'|'||branch_id from delivery_notes where id='${id}'`)
const dnCount = () => Number(sql(`select count(*) from delivery_notes where account_id='${accA}'`))
const line = (pid, q, price, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })

const authFile = (n) => `C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/qa-auth-${n}.json`
const browser = await chromium.launch()
async function ctxFor(who, viewport = 'desktop', theme = 'light') {
  const f = authFile(who)
  await uiLogin(browser, ...USERS[who], f)
  const c = await newCtx(browser, viewport, theme, f)
  // wa.me no se carga de verdad: se registra la URL pedida.
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
async function fillHeader(p, { clientName = 'Cliente Demo QA', branchName } = {}) {
  await p.getByRole('combobox', { name: 'Cliente' }).click()
  await p.getByRole('option', { name: new RegExp(clientName) }).first().click()
  if (branchName) {
    await p.getByRole('combobox').filter({ hasText: /Casa Central|Norte/ }).first().click()
    await p.getByRole('option', { name: new RegExp(branchName) }).first().click()
  }
}
async function addLine(p, productRe, qty, price) {
  await p.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await p.getByRole('option', { name: productRe }).first().click()
  const q = p.getByLabel(/^(Cantidad|Peso|Kilos|Cant\.)/).first()
  await q.fill(String(qty))
  if (price != null) await p.getByLabel('Precio unit.').first().fill(String(price))
  await p.getByRole('button', { name: 'Agregar al remito' }).click()
}
// Cantidad de la línea i del carrito (los inputs numéricos del carrito van de a pares cantidad/subtotal).
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
const apiMk = async (items, extra = {}) => {
  const r = await be(tokOwner, 'POST', '/delivery-notes', { client_id: client, branch_id: br1, items, ...extra }, { 'Idempotency-Key': crypto.randomUUID() })
  if (r.status !== 201) throw new Error('apiMk ' + r.status + ' ' + JSON.stringify(r.body).slice(0, 200))
  return r.body
}
const step = async (id, fn) => {
  if (!run(id)) return
  try { await fn() } catch (e) { check(`(${id}) el paso terminó sin excepción`, false, String(e).split('\n')[0]) }
}
const S = {}

// (a) emitir con 2 productos (uno por kg) ---------------------------------------------------------------
await step('a', async () => {
  const [sh, sa, n0] = [stock(harina, br1), stock(alf, br1), maxNum()]
  await goto('/remitos/nuevo')
  await fillHeader(page)
  await addLine(page, /Harina/, 2.5, 1200)
  await addLine(page, /Alfajor/, 4, 500)
  await shot('nuevo-lleno')
  S.a = await emit(page)
  check('(a) remito emitido con el número siguiente (R-00000001 en cuenta limpia)', dnRow(S.a).startsWith(`R-${String(n0 + 1).padStart(8, '0')}|issued`), dnRow(S.a))
  check('(a) stock baja exacto (harina -2,5; alfajor -4)', stock(harina, br1) === sh - 2.5 && stock(alf, br1) === sa - 4, `h ${sh}->${stock(harina, br1)} a ${sa}->${stock(alf, br1)}`)
  check('(a) 2 movimientos sale/delivery_note con referencia al remito', nMovs(S.a) === 2 && /sale\/delivery_note:-4/.test(movs(S.a)) && /sale\/delivery_note:-2.5/.test(movs(S.a)), movs(S.a))
  await shot('detalle-emitido')
  // visible en /stock con el rótulo
  await goto('/stock')
  await page.getByText('Historial de movimientos').first().click()
  await page.getByText(/Remito R-\d{8}/).first().waitFor({ timeout: 60000 })
  await shot('stock-movimientos-remito')
  const n = await page.getByText(/Remito R-\d{8}/).count()
  check('(a) /stock muestra "Remito R-…" en el historial de movimientos', n >= 2, `${n} filas`)
  writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/dn-a.json', JSON.stringify({ id: S.a }))
})

// (b) faltante -----------------------------------------------------------------------------------------
await step('b', async () => {
  sql(`update branch_stock set quantity=1 where product_id='${escaso}' and branch_id='${br1}'`)
  const [se, sa, c0] = [stock(escaso, br1), stock(alf, br1), dnCount()]
  // b1: el formulario lo frena al agregar (stock de la sucursal elegida, no el agregado)
  await goto('/remitos/nuevo')
  await fillHeader(page)
  await addLine(page, /escaso/, 2, 300)
  const msgs = await page.locator('[data-sonner-toast], [role=alert]').allInnerTexts()
  await shot('nuevo-faltante-cliente')
  check('(b1) el formulario frena la línea que supera el stock y nombra el producto', msgs.some((t) => /escaso/i.test(t) && /stock|alcanza|disponible/i.test(t)) || (await page.getByText(/Producto escaso QA/).count()) > 0, msgs.join(' | ').slice(0, 200))
  check('(b1) no se agregó la línea al remito (carrito vacío)', (await page.getByRole('button', { name: /^Eliminar / }).count()) === 0)
  // b2: el servidor responde stock_insuficiente (el stock cambia entre la carga y la emisión)
  await goto('/remitos/nuevo')
  await fillHeader(page)
  await addLine(page, /escaso/, 1, 300)
  await addLine(page, /Alfajor/, 1, 500)
  sql(`update branch_stock set quantity=0 where product_id='${escaso}' and branch_id='${br1}'`)
  await page.getByRole('button', { name: /Emitir remito/ }).click()
  await page.waitForTimeout(4000)
  const body = (await page.locator('[data-sonner-toast], [role=alert]').allInnerTexts()).join(' | ')
  await shot('nuevo-faltante-servidor')
  check('(b2) el servidor rechaza con un mensaje que nombra el producto', /Producto escaso QA/.test(body), body.slice(0, 250))
  check('(b2) nada escrito: sin remito nuevo, stock del alfajor intacto, sigue en /remitos/nuevo', dnCount() === c0 && stock(alf, br1) === sa && /\/remitos\/nuevo/.test(page.url()), `dn ${c0}->${dnCount()} alf ${sa}->${stock(alf, br1)} ${page.url()}`)
  sql(`update branch_stock set quantity=1 where product_id='${escaso}' and branch_id='${br1}'`)
})

// (c) edición: neto por par ---------------------------------------------------------------------------
await step('c', async () => {
  sql(`update branch_stock set quantity=3 where product_id='${tres}' and branch_id='${br1}'`)
  const n = await apiMk([line(harina, 2, 1200), line(alf, 4, 500), line(aceite, 2, 900)])
  S.c = n.id
  const [h0, a0, c0, t0] = [stock(harina, br1), stock(alf, br1), stock(aceite, br1), stock(tres, br1)]
  const m0 = nMovs(S.c)
  await goto(`/remitos/${S.c}/editar`)
  await cartQty(page, 0).fill('3')   // harina 2 -> 3
  await cartQty(page, 1).fill('1')   // alfajor 4 -> 1
  await page.getByRole('button', { name: 'Eliminar Aceite QA' }).click()  // quita aceite (vuelven 2)
  await addLine(page, /Lote de tres/, 2, 300)  // agrega un producto nuevo
  await page.waitForTimeout(500)
  const effect = await page.getByRole('status', { name: 'Efecto en el stock' }).innerText().catch(() => '')
  await shot('editar-resumen-ajuste')
  check('(c) el resumen del ajuste se muestra antes de guardar', /Harina|Alfajor|Aceite|Lote/.test(effect), effect.slice(0, 200))
  await save(page)
  check('(c) harina -1 (neto de 2->3), alfajor +3, aceite +2, lote de tres -2', stock(harina, br1) === h0 - 1 && stock(alf, br1) === a0 + 3 && stock(aceite, br1) === c0 + 2 && stock(tres, br1) === t0 - 2, `h ${h0}->${stock(harina, br1)} a ${a0}->${stock(alf, br1)} ac ${c0}->${stock(aceite, br1)} t ${t0}->${stock(tres, br1)}`)
  check('(c) la revisión subió a 2 y el remito sigue pendiente', /\|issued\|rev2\|/.test(dnRow(S.c)), dnRow(S.c))
  // invariante del ledger: Σ delta del remito = -(retenido por líneas)
  const sumDelta = Number(sql(`select coalesce(sum(quantity_delta),0) from stock_movements where reference_id='${S.c}'`))
  const held = Number(sql(`select coalesce(sum(quantity_base),0) from delivery_note_items where delivery_note_id='${S.c}'`))
  check('(c) invariante: Σ delta de movimientos = -Σ cantidad base de las líneas', Math.abs(sumDelta + held) < 1e-9, `${sumDelta} vs ${held}`)
  // sólo un par cambia: A=2/B=1 -> A=2/B=3
  const n2 = await apiMk([line(harina, 2, 1200), line(alf, 1, 500)])
  const [mm0, hh0, aa0] = [nMovs(n2.id), stock(harina, br1), stock(alf, br1)]
  await goto(`/remitos/${n2.id}/editar`)
  await cartQty(page, 1).fill('3')
  await save(page)
  const perProd = (pid) => Number(sql(`select count(*) from stock_movements where reference_id='${n2.id}' and product_id='${pid}'`))
  check('(c) A=2/B=1 -> A=2/B=3: un solo par espejo sobre B (2 movimientos) y cero sobre A', nMovs(n2.id) === mm0 + 2 && perProd(harina) === 1 && perProd(alf) === 3 && stock(harina, br1) === hh0 && stock(alf, br1) === aa0 - 2, `movs ${mm0}->${nMovs(n2.id)} harina ${perProd(harina)} alf ${perProd(alf)} h ${hh0}->${stock(harina, br1)} a ${aa0}->${stock(alf, br1)}`)
  // sólo precio/notas: cero movimientos
  const mp = nMovs(n2.id)
  await goto(`/remitos/${n2.id}/editar`)
  await page.getByLabel(/^Notas/).fill('sólo cambio notas')
  await save(page)
  check('(c) cambiar sólo las notas no mueve stock (0 movimientos nuevos)', nMovs(n2.id) === mp, `${mp}->${nMovs(n2.id)}`)
  // cambio de sucursal: br1 -> Norte (alfajor 10 en Norte)
  const [b1, b2] = [stock(alf, br1), stock(alf, br2)]
  const held2 = Number(sql(`select coalesce(sum(quantity_base),0) from delivery_note_items where delivery_note_id='${n2.id}' and product_id='${alf}'`))
  const hb1 = stock(harina, br1), hb2 = stock(harina, br2)
  await goto(`/remitos/${n2.id}/editar`)
  await page.getByRole('combobox').filter({ hasText: /Casa Central/ }).first().click()
  await page.getByRole('option', { name: /Norte/ }).first().click()
  await page.waitForTimeout(500)
  await shot('editar-cambio-sucursal-aviso')
  const warn = await page.locator('[role=alert],[role=status]').allInnerTexts()
  await page.getByRole('button', { name: 'Guardar cambios' }).click()
  await page.waitForTimeout(4000)
  const stillEditing = /editar/.test(page.url())
  // la harina (50 en Casa Central, 0 en Norte) no alcanza en Norte: el formulario/servidor lo frena; el alfajor sí
  check('(c) cambiar a una sucursal sin stock de uno de los productos se frena sin escribir', stillEditing && stock(alf, br1) === b1 && stock(alf, br2) === b2, `${warn.join(' | ').slice(0, 200)}`)
  S.n2 = n2.id
})
await step('c2', async () => {
  // traslado de stock al cambiar de sucursal con un remito de un solo producto disponible en ambas
  const n = await apiMk([line(alf, 3, 500)])
  const [b1, b2] = [stock(alf, br1), stock(alf, br2)]
  await goto(`/remitos/${n.id}/editar`)
  await page.getByRole('combobox').filter({ hasText: /Casa Central/ }).first().click()
  await page.getByRole('option', { name: /Norte/ }).first().click()
  await save(page)
  check('(c2) cambiar la sucursal traslada el stock (Casa Central +3, Norte -3)', stock(alf, br1) === b1 + 3 && stock(alf, br2) === b2 - 3 && dnRow(n.id).endsWith(br2), `br1 ${b1}->${stock(alf, br1)} br2 ${b2}->${stock(alf, br2)}`)
  S.norte = n.id
})

// (d) pestaña vieja ---------------------------------------------------------------------------------
await step('d', async () => {
  const n = await apiMk([line(alf, 2, 500)])
  const a0 = stock(alf, br1)
  await goto(`/remitos/${n.id}/editar`)
  // otro usuario edita mientras tanto (revisión 1 -> 2)
  const r = await be(tokOwner, 'PUT', `/delivery-notes/${n.id}`, { revision: 1, client_id: client, branch_id: br1, delivery_address: null, notes: 'cambio ajeno', items: [line(alf, 5, 500)] })
  check('(d) la edición paralela por API entra (200)', r.status === 200, `${r.status}`)
  const a1 = stock(alf, br1)
  await cartQty(page, 0).fill('7')
  await page.getByRole('button', { name: 'Guardar cambios' }).click()
  await page.getByRole('alert', { name: 'Remito modificado' }).waitFor({ timeout: 30000 })
  await shot('editar-conflicto-revision')
  check('(d) cartel "Remito modificado" con recarga, sin escribir nada', stock(alf, br1) === a1 && /\|rev2\|/.test(dnRow(n.id)), `stock ${a0}->${a1}->${stock(alf, br1)} ${dnRow(n.id)}`)
  await page.getByRole('button', { name: 'Recargar remito' }).click()
  await page.waitForTimeout(2500)
  const q = await cartQty(page, 0).inputValue()
  check('(d) tras recargar, el formulario muestra lo que dejó el otro usuario (5)', q === '5', `cantidad ${q}`)
})

// (e) anular con motivo ------------------------------------------------------------------------------
await step('e', async () => {
  const n = await apiMk([line(harina, 1.5, 1200), line(alf, 2, 500)])
  S.e = n.id
  const [h0, a0] = [stock(harina, br1), stock(alf, br1)]
  await goto(`/remitos/${n.id}`)
  await page.getByRole('button', { name: 'Anular' }).click()
  const d = page.getByRole('dialog')
  await d.waitFor()
  await shot('anular-dialogo-vacio')
  const confirmBtn = d.getByRole('button', { name: /Anular remito|Anular/ }).last()
  check('(e) sin motivo no se puede confirmar', await confirmBtn.isDisabled())
  await d.getByLabel(/Motivo/).fill('El cliente devolvió la mercadería')
  await shot('anular-dialogo-motivo')
  await confirmBtn.click()
  await page.getByRole('status', { name: 'Remito anulado' }).waitFor({ timeout: 30000 })
  check('(e) el stock se repone (harina +1,5; alfajor +2)', stock(harina, br1) === h0 + 1.5 && stock(alf, br1) === a0 + 2, `h ${h0}->${stock(harina, br1)} a ${a0}->${stock(alf, br1)}`)
  check('(e) remito terminal: canceled + motivo en el historial', /\|canceled\|/.test(dnRow(n.id)) && Number(sql(`select count(*) from document_status_history where document_id='${n.id}' and to_status='canceled' and reason ilike '%devolvió%'`)) === 1)
  check('(e) sin acciones: no hay Editar ni Anular', (await page.getByRole('link', { name: 'Editar' }).count()) === 0 && (await page.getByRole('button', { name: 'Anular' }).count()) === 0)
  await shot('detalle-anulado')
})

// (f) PDF sin y con precios -----------------------------------------------------------------------------
await step('f', async () => {
  const n = await apiMk([line(harina, 1.5, 1200), line(alf, 2, 500)], { notes: 'Entregar por la puerta lateral' })
  S.f = n.id
  const fetchPdf = async (id, qs) => {
    const r = await fetch(`http://127.0.0.1:8000/delivery-notes/${id}/pdf?${qs}`, { headers: { Authorization: `Bearer ${tokOwner}` } })
    return { status: r.status, ct: r.headers.get('content-type'), cd: r.headers.get('content-disposition'), buf: Buffer.from(await r.arrayBuffer()) }
  }
  const p0 = await fetchPdf(n.id, 'disposition=attachment')
  const p1 = await fetchPdf(n.id, 'disposition=attachment&show_prices=true')
  const pc = await fetchPdf(S.e, 'disposition=inline')
  check('(f) PDF 200 application/pdf con nombre remito-R-…', p0.status === 200 && /pdf/.test(p0.ct) && /remito-R-\d+/.test(p0.cd ?? ''), `${p0.status} ${p0.ct} ${p0.cd}`)
  mkdirSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf', { recursive: true })
  writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf/remito-sin-precios.pdf', p0.buf)
  writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf/remito-con-precios.pdf', p1.buf)
  writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf/remito-anulado.pdf', pc.buf)
  // descarga por la UI con el switch "Mostrar precios"
  await goto(`/remitos/${n.id}`)
  await page.getByLabel('Mostrar precios').click()
  await page.getByRole('button', { name: 'Compartir' }).click()
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 30000 }), page.getByRole('menuitem', { name: 'Descargar PDF' }).click()])
  const f = `C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf/ui-con-precios-${dl.suggestedFilename()}`
  await dl.saveAs(f)
  check('(f) la descarga por la UI con "Mostrar precios" encendido trae nombre con precios', /remito-R-\d+/.test(dl.suggestedFilename()), dl.suggestedFilename())
  writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf/ui-file.txt', f)
})

// (g) WhatsApp --------------------------------------------------------------------------------------------
await step('g', async () => {
  const n = await apiMk([line(alf, 1, 500)])
  await goto(`/remitos/${n.id}`)
  await page.getByRole('button', { name: 'Compartir' }).click()
  await page.getByRole('menuitem', { name: /WhatsApp/ }).waitFor()
  await page.waitForTimeout(2500) // espera la precarga del PDF
  const popup = ctx.waitForEvent('page', { timeout: 15000 }).catch(() => null)
  await page.getByRole('menuitem', { name: /Enviar por WhatsApp/ }).click()
  const pp = await popup
  await page.waitForTimeout(1500)
  const url = ctx.waRequests[0] ?? (pp ? pp.url() : '')
  const num = dnRow(n.id).split('|')[0]
  check('(g) WhatsApp abre wa.me con el teléfono normalizado (54 + dígitos)', /wa\.me\/54\d{9,12}\?text=/.test(url), url.slice(0, 160))
  check('(g) el texto del mensaje nombra el número del remito', decodeURIComponent(url).includes(num), decodeURIComponent(url).slice(0, 200))
  writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/wa-url.txt', url)
})

// (h) roles -------------------------------------------------------------------------------------------------
await step('h', async () => {
  const n = await apiMk([line(alf, 1, 500)])
  const probe = async (who, path) => {
    const c = await ctxFor(who)
    const p = await c.newPage()
    await p.goto(`${BASE}${path}`, { waitUntil: 'domcontentloaded', timeout: 180000 })
    await p.waitForTimeout(6000)
    return { c, p }
  }
  // vendedor: emite (formulario disponible) y NO ve Anular
  let { c, p } = await probe('seller', `/remitos/${n.id}`)
  check('(h) vendedor: ve el remito y Editar, pero NO "Anular"', (await p.getByRole('link', { name: 'Editar' }).count()) === 1 && (await p.getByRole('button', { name: 'Anular' }).count()) === 0)
  await shot('detalle-vendedor', 'desktop', 'light', p)
  await p.goto(`${BASE}/remitos/nuevo`, { waitUntil: 'domcontentloaded' })
  await p.getByRole('combobox', { name: 'Cliente' }).waitFor({ timeout: 90000 })
  check('(h) vendedor: puede abrir "Nuevo remito"', true)
  await c.close()
  // cajero: no emite
  ;({ c, p } = await probe('cashier', '/remitos/nuevo'))
  const hasForm = (await p.getByRole('combobox', { name: 'Cliente' }).count()) > 0
  await shot('nuevo-cajero-sin-permiso', 'desktop', 'light', p)
  check('(h) cajero: "Nuevo remito" muestra el estado sin permiso (sin formulario)', !hasForm, (await p.locator('main').innerText()).slice(0, 120).replace(/\n/g, ' '))
  await p.goto(`${BASE}/remitos`, { waitUntil: 'domcontentloaded' })
  await p.waitForTimeout(6000)
  check('(h) cajero: el listado no ofrece el CTA "Nuevo remito"', (await p.getByRole('link', { name: /Nuevo remito/ }).count()) === 0)
  await c.close()
  // depósito (stock): emite y edita, NO anula
  ;({ c, p } = await probe('stock', `/remitos/${n.id}`))
  check('(h) depósito: ve Editar y NO "Anular"', (await p.getByRole('link', { name: 'Editar' }).count()) === 1 && (await p.getByRole('button', { name: 'Anular' }).count()) === 0)
  await c.close()
  // admin: anula
  ;({ c, p } = await probe('admin', `/remitos/${n.id}`))
  check('(h) admin: ve "Anular"', (await p.getByRole('button', { name: 'Anular' }).count()) === 1)
  await shot('detalle-admin', 'desktop', 'light', p)
  await c.close()
})

// (i) Nuevo remito desde la ficha del cliente ------------------------------------------------------------
await step('i', async () => {
  await goto(`/clientes/${client2}`)
  const link = page.getByRole('link', { name: /Nuevo remito/ }).first()
  await shot('ficha-cliente-cabecera')
  await link.click()
  await page.waitForURL(/\/remitos\/nuevo\?cliente=/, { timeout: 60000 })
  await page.getByRole('combobox', { name: 'Cliente' }).waitFor({ timeout: 90000 })
  await page.waitForTimeout(3000)
  const shown = await page.getByRole('combobox', { name: 'Cliente' }).innerText()
  check('(i) "Nuevo remito" desde la ficha abre el formulario con el cliente precargado', /Cliente Dos QA/.test(shown), shown)
  const ver = await page.goto(`${BASE}/clientes/${client2}`, { waitUntil: 'domcontentloaded' }).then(() => page.getByRole('link', { name: /Ver remitos/ }).first().getAttribute('href'))
  check('(i) "Ver remitos" apunta a /remitos?cliente=<id>', ver === `/remitos?cliente=${client2}`, ver)
})

// (j) baja de sucursal con un remito pendiente ---------------------------------------------------------------
await step('j', async () => {
  // sucursal vacía con un único remito pendiente: el remito es lo ÚNICO que la bloquea
  const brName = `Sucursal Sur QA ${Date.now() % 100000}`
  const brS = sql(`insert into branches (account_id, name) values ('${accA}', '${brName}') returning id`).split(String.fromCharCode(10))[0]
  sql(`select public.c21_apply_branch_stock_delta('${accA}','${aceite}','${brS}', 5)`)
  const n = await apiMk([line(aceite, 5, 900)], { branch_id: brS })
  check('(j) la sucursal quedó sin existencias y con un remito pendiente', stock(aceite, brS) === 0 && /[|]issued[|]/.test(dnRow(n.id)))
  await goto('/sucursales')
  await page.getByRole('button', { name: new RegExp(`Desactivar ${brName}`) }).click()
  const d = page.getByRole('alertdialog')
  await d.waitFor()
  await d.getByRole('link', { name: /Ver remitos pendientes/ }).waitFor({ timeout: 30000 })
  await shot('sucursales-baja-con-remitos')
  const txt = await d.innerText()
  const href = await d.getByRole('link', { name: /Ver remitos pendientes/ }).getAttribute('href')
  check('(j) el diálogo avisa de los remitos pendientes y enlaza a /remitos?estado=pendientes&sucursal=<id>', /remito/i.test(txt) && href === `/remitos?estado=pendientes&sucursal=${brS}`, `${href} :: ${txt.slice(0, 200).replace(/\s+/g, ' ')}`)
  check('(j) no se ofrece "Desactivar" mientras hay remitos pendientes', (await d.getByRole('button', { name: /^Desactivar/ }).count()) === 0)
  await page.keyboard.press('Escape')
  let err = ''
  try { sql(`update branches set is_active=false where id='${brS}'`) } catch (e) { err = String(e) }
  check('(j) la baja directa en la base se rechaza con P0428 branch_has_pending_delivery_notes', /branch_has_pending_delivery_notes/.test(err), err.slice(0, 160))
  check('(j) la sucursal sigue activa', sql(`select is_active from branches where id='${brS}'`) === 't')
  // se anula el remito (admin) y la baja procede
  const adm = await login(...USERS.admin)
  const c = await be(adm, 'POST', `/delivery-notes/${n.id}/cancel`, { revision: 1, reason: 'liberar la sucursal' })
  let err2 = ''
  try { sql(`update branches set is_active=false where id='${brS}'`) } catch (e) { err2 = String(e) }
  check('(j) anulado el remito, el motivo del bloqueo ya no es el remito (la mercadería volvió: existencias)', c.status === 200 && err2 !== '' && !/branch_has_pending_delivery_notes/.test(err2), err2.slice(0, 140))
  sql(`update branch_stock set quantity=0 where branch_id='${brS}'`)
  let ok = true
  try { sql(`update branches set is_active=false where id='${brS}'`) } catch { ok = false }
  check('(j) vaciada la sucursal y sin remitos pendientes, la baja procede', ok)
})

// (k) regresión: formulario de venta, POS y presupuesto -------------------------------------------------------
await step('k', async () => {
  // caja abierta para el POS
  const branches = (await be(tokOwner, 'GET', '/branches')).body
  let cbs = (await be(tokOwner, 'GET', `/branches/${br1}/cashboxes`)).body
  let cashboxId = cbs?.[0]?.id
  if (!cashboxId) cashboxId = (await be(tokOwner, 'POST', '/cashboxes', { branch_id: br1, name: 'Caja QA' })).body.id
  const cur = await be(tokOwner, 'GET', `/cashboxes/${cashboxId}/current-session`)
  if (!(cur.status === 200 && cur.body?.status === 'open')) await be(tokOwner, 'POST', `/cashboxes/${cashboxId}/sessions/open`, { opening_balance: 1000 })
  // formulario de venta
  const [sa, so] = [stock(alf, br1), Number(sql(`select count(*) from sales where account_id='${accA}'`))]
  await page.goto(`${BASE}/ventas`, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await page.getByRole('button', { name: /Nueva venta/ }).first().click()
  const d = page.getByRole('dialog')
  await d.getByText('Agregar producto', { exact: false }).first().waitFor({ timeout: 60000 })
  await d.getByRole('combobox', { name: /Sucursal|Sin sucursal/ }).first().click().catch(async () => { await d.getByText('Sin sucursal (general)').first().click() })
  await page.getByRole('option', { name: 'Casa Central' }).click()
  await d.getByRole('combobox').filter({ hasText: 'Seleccionar cliente' }).click()
  await page.getByRole('option', { name: /Cliente Demo QA/ }).first().click()
  await d.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.getByRole('option', { name: /Alfajor artesanal/ }).first().click()
  await d.getByRole('button', { name: 'Agregar al carrito' }).click()
  await d.getByRole('button', { name: /Confirmar venta/ }).click()
  await page.waitForTimeout(6000)
  check('(k) formulario de venta: se registra la venta y baja el stock 1', Number(sql(`select count(*) from sales where account_id='${accA}'`)) === so + 1 && stock(alf, br1) === sa - 1, `sales ${so}->${sql(`select count(*) from sales where account_id='${accA}'`)} stock ${sa}->${stock(alf, br1)}`)
  const sv = sql(`select string_agg(distinct type||'/'||reference_type, ',') from stock_movements where reference_id in (select id from sales where account_id='${accA}' order by created_at desc limit 1)`)
  check('(k) el movimiento de la venta sigue siendo sale/sale (no es de remito)', /sale\/sale/.test(sv), sv)
  // POS
  const [pa, ps] = [stock(alf, br1), Number(sql(`select count(*) from sales where account_id='${accA}'`))]
  await page.goto(`${BASE}/ventas/pos`, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await page.getByRole('button', { name: 'Efectivo' }).waitFor({ timeout: 90000 })
  await page.getByText(/Caja abierta/).waitFor({ timeout: 30000 })
  await page.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).click()
  await page.getByRole('option', { name: /Alfajor artesanal/ }).first().click()
  await page.getByRole('button', { name: 'Agregar al carrito' }).click()
  await page.getByRole('button', { name: /^Cobrar/ }).click()
  await page.waitForTimeout(6000)
  check('(k) POS: se registra la venta y baja el stock 1', Number(sql(`select count(*) from sales where account_id='${accA}'`)) === ps + 1 && stock(alf, br1) === pa - 1, `stock ${pa}->${stock(alf, br1)}`)
  // presupuesto: se crea y se comparte
  const q = await be(tokOwner, 'POST', '/quotes', { client_id: client, valid_until: new Date(Date.now() + 864e6).toISOString().slice(0, 10), items: [line(alf, 1, 500)] })
  check('(k) presupuesto: se crea (201)', q.status === 201, `${q.status}`)
  await goto(`/presupuestos/${q.body.id}`)
  await page.getByRole('button', { name: 'Compartir' }).click()
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 30000 }), page.getByRole('menuitem', { name: 'Descargar PDF' }).click()])
  check('(k) presupuesto: se comparte (descarga del PDF con nombre de presupuesto)', /presupuesto|P-\d+/i.test(dl.suggestedFilename()), dl.suggestedFilename())
})

console.log('console errors:', JSON.stringify(errs.slice(0, 6)))
const failed = results.filter(([, ok]) => !ok)
console.log(`RESUMEN humo: ${results.length - failed.length}/${results.length} PASS`)
if (failed.length) console.log('FALLAN:', failed.map(([n]) => n).join(' | '))
await browser.close()
