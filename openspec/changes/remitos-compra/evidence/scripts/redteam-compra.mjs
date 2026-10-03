// Red-team del remito de COMPRA (tanda A) contra GoTrue + PostgREST + FastAPI + Postgres reales (stack LOCAL).
// Cada ataque lleva su control positivo. Imprime PASS/FAIL. Sin credenciales: todo por env (ver lib.mjs).
import { readFileSync } from 'node:fs'
import { login, USERS, sql, be, rest, check, results, API, ANON } from './lib.mjs'

const IDS = JSON.parse(readFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/ids.json', 'utf8'))
const { accA, accB, br1, br2, brB, client, clientB, harina, alf, escaso, tres, aceite, prodB, sup, sup2, supB, sinCosto } = IDS
const stock = (pid, br) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}'${br ? ` and branch_id='${br}'` : ''}`))
const movs = (ref) => Number(sql(`select count(*) from stock_movements where reference_id='${ref}'`))
const dnCount = () => Number(sql(`select count(*) from delivery_notes where account_id in ('${accA}','${accB}')`))
const itemCount = () => Number(sql(`select count(*) from delivery_note_items where account_id in ('${accA}','${accB}')`))
const movTotal = () => Number(sql(`select count(*) from stock_movements where account_id in ('${accA}','${accB}')`))
const line = (pid, q = 1, price = 100, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })
const key = () => crypto.randomUUID()
const mkBody = (body) => ({ direction: 'purchase', supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, ...body })
const mk = (tok, body, k = key()) => be(tok, 'POST', '/delivery-notes', mkBody(body), { 'Idempotency-Key': k })
const put = (tok, id, rev, body) => be(tok, 'PUT', `/delivery-notes/${id}`, { direction: 'purchase', revision: rev, supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, ...body })
const cancel = (tok, id, rev, reason = 'prueba red-team') => be(tok, 'POST', `/delivery-notes/${id}/cancel`, { revision: rev, reason })
const get = (tok, id) => be(tok, 'GET', `/delivery-notes/${id}`)
const code = (r) => r.body?.code ?? r.body?.detail?.code ?? r.body?.detail ?? ''
const txt = (r) => JSON.stringify(r.body ?? '').slice(0, 220)

const info = (m) => console.log("INFO  " + m)
const T = {}
for (const [n, cred] of Object.entries(USERS)) T[n] = await login(...cred)

// ───────────────────────── 0. controles positivos
let r = await mk(T.owner, { items: [line(alf, 2, 250)] })
check('(0) control positivo: recibir 201 con número RC-', r.status === 201 && /^RC-\d{8}$/.test(r.body?.number_label ?? ''), `${r.status} ${r.body?.number_label} ${txt(r)}`)
const base = r.body
check('(0) control positivo: GET propio 200 y direction=purchase', (await get(T.owner, base.id)).status === 200 && sql(`select direction from delivery_notes where id='${base.id}'`) === 'purchase')

// ───────────────────────── 1. escritura directa por PostgREST (debe fallar)
for (const [who, tok] of [['owner', T.owner], ['seller', T.seller], ['b', T.b]]) {
  const n0 = dnCount(), i0 = itemCount(), m0 = movTotal()
  const ins = await rest(tok, 'POST', 'delivery_notes', { account_id: accA, direction: 'purchase', number: 9999, status: 'issued', supplier_id: sup, branch_id: br1, total: 1, issued_on: '2026-10-03' })
  check(`(1) ${who}: INSERT directo en delivery_notes (compra) rechazado`, ins.status >= 400 && dnCount() === n0, `${ins.status} ${JSON.stringify(ins.body).slice(0, 80)}`)
  const insI = await rest(tok, 'POST', 'delivery_note_items', { account_id: accA, delivery_note_id: base.id, product_id: alf, quantity: 1, price: 1, subtotal: 1 })
  check(`(1) ${who}: INSERT directo en delivery_note_items rechazado`, insI.status >= 400 && itemCount() === i0, `${insI.status}`)
  const before = sql(`select coalesce(notes,'')||'|'||status||'|'||total||'|'||coalesce(supplier_id::text,'') from delivery_notes where id='${base.id}'`)
  await rest(tok, 'PATCH', `delivery_notes?id=eq.${base.id}`, { notes: 'hack', status: 'canceled', total: 0, supplier_id: supB })
  check(`(1) ${who}: PATCH directo no cambia el remito (estado, total ni proveedor)`, sql(`select coalesce(notes,'')||'|'||status||'|'||total||'|'||coalesce(supplier_id::text,'') from delivery_notes where id='${base.id}'`) === before)
  await rest(tok, 'DELETE', `delivery_notes?id=eq.${base.id}`)
  await rest(tok, 'DELETE', `delivery_note_items?delivery_note_id=eq.${base.id}`)
  check(`(1) ${who}: DELETE directo no borra remito ni líneas`, dnCount() === n0 && itemCount() === i0)
  // forjar el ledger y el stock
  const sm = await rest(tok, 'POST', 'stock_movements', { account_id: accA, product_id: alf, branch_id: br1, type: 'purchase', quantity_delta: 500, reference_type: 'delivery_note', reference_id: base.id })
  info(`(1) ${who}: INSERT directo en stock_movements por PostgREST -> ${sm.status} (PREEXISTENTE: politica stock_movements_account_insert de 20260606000004; no es del change)`)
  const s0 = stock(alf, br1)
  await rest(tok, 'PATCH', `branch_stock?product_id=eq.${alf}`, { quantity: 99999 })
  info(`(1) ${who}: PATCH directo de branch_stock por PostgREST -> stock ${s0} -> ${stock(alf, br1)} (PREEXISTENTE: branch_stock_writer_update de 20260608000000; lo usa use-branch-stock.ts)`)
}
const own = await rest(T.owner, 'GET', `delivery_notes?id=eq.${base.id}&select=id`)
check('(1) control positivo: SELECT propio por PostgREST devuelve la fila', own.status === 200 && own.body.length === 1)
const foreign = await rest(T.b, 'GET', `delivery_notes?id=eq.${base.id}&select=id`)
check('(1) SELECT de otra cuenta por PostgREST devuelve 0 filas', foreign.status === 200 && foreign.body.length === 0)
const anon = await fetch(`${API}/rest/v1/delivery_notes?select=id`, { headers: { apikey: ANON, Authorization: `Bearer ${ANON}` } })
const anonBody = await anon.json().catch(() => null)
check('(1) anon no lee delivery_notes', anon.status >= 400 || (Array.isArray(anonBody) && anonBody.length === 0), `${anon.status}`)
for (const fn of ['_delivery_note_apply_stock', '_delivery_note_reverse_held', '_delivery_note_replace_content', '_delivery_note_assert_role_dir', '_delivery_note_lock_products', '_delivery_note_held_pairs']) {
  const rr = await rest(T.owner, 'POST', `rpc/${fn}`, {})
  check(`(1) helper interno ${fn} no expuesto a authenticated`, rr.status >= 400 && rr.status !== 500, `${rr.status} ${JSON.stringify(rr.body).slice(0, 80)}`)
}
// RPC pública llamada por PostgREST con rol sin permiso: sigue la FSM
{
  const n0 = dnCount(), s0 = stock(alf, br1)
  const rr = await rest(T.seller, 'POST', 'rpc/rpc_create_purchase_delivery_note', { p_idempotency_key: key(), p_supplier_id: sup, p_branch_id: br1, p_supplier_reference: null, p_notes: null, p_items: [line(alf, 5, 1)] })
  check('(1) seller por RPC directa de PostgREST: rechazado sin efectos', rr.status >= 400 && dnCount() === n0 && stock(alf, br1) === s0, `${rr.status} ${JSON.stringify(rr.body).slice(0, 100)}`)
}

// ───────────────────────── 2. otra cuenta por id: 404 idéntico al inexistente
const ghost = crypto.randomUUID()
const sample = async (tok, id) => ({
  get: await get(tok, id),
  pdf: await be(tok, 'GET', `/delivery-notes/${id}/pdf`),
  put: await put(tok, id, 1, { supplier_id: supB, branch_id: brB, items: [line(prodB, 1, 1)] }),
  cancel: await cancel(tok, id, 1, 'intento ajeno'),
})
const f = await sample(T.b, base.id), g = await sample(T.b, ghost)
for (const op of ['get', 'pdf', 'put', 'cancel']) {
  check(`(2) ${op} de remito ajeno = 404 idéntico al inexistente`, f[op].status === 404 && g[op].status === 404 && code(f[op]) === code(g[op]), `ajeno ${f[op].status}/${code(f[op])} inexistente ${g[op].status}/${code(g[op])}`)
}
check('(2) el remito ajeno quedó intacto', sql(`select status||'|'||revision from delivery_notes where id='${base.id}'`) === 'issued|1')
const lst = await be(T.b, 'GET', '/delivery-notes?direction=purchase')
check('(2) el listado de compra de B no contiene remitos de A', lst.status === 200 && lst.body.items.every((x) => x.id !== base.id), `total ${lst.body?.total}`)
const lstA = await be(T.owner, 'GET', '/delivery-notes?direction=purchase')
check('(2) control positivo: el listado de compra de A contiene el remito', lstA.status === 200 && lstA.body.items.some((x) => x.id === base.id) && lstA.body.items.every((x) => x.supplier_name != null || x.supplier_id), `total ${lstA.body?.total}`)

// ───────────────────────── 3. proveedor / producto / sucursal ajenos: 404 sin efectos
const snap = () => `${dnCount()}|${itemCount()}|${movTotal()}|${stock(alf)}|${stock(prodB)}`
{
  const s0 = snap()
  const a = await mk(T.owner, { supplier_id: supB, items: [line(alf, 1)] })
  const b = await mk(T.owner, { items: [line(prodB, 1)] })
  const c = await mk(T.owner, { branch_id: brB, items: [line(alf, 1)] })
  const d = await mk(T.b, { supplier_id: sup, branch_id: brB, items: [line(prodB, 1)] })
  const e = await mk(T.b, { supplier_id: supB, branch_id: br1, items: [line(prodB, 1)] })
  check('(3) proveedor ajeno -> 404 sin efectos', a.status === 404, `${a.status} ${code(a)}`)
  check('(3) producto ajeno -> 404 sin efectos', b.status === 404, `${b.status} ${code(b)}`)
  check('(3) sucursal ajena -> 404 sin efectos', c.status === 404, `${c.status} ${code(c)}`)
  check('(3) B con proveedor de A -> 404', d.status === 404, `${d.status} ${code(d)}`)
  check('(3) B con sucursal de A -> 404', e.status === 404, `${e.status} ${code(e)}`)
  check('(3) ninguno de los ataques dejó rastro (remitos, líneas, movimientos, stock)', snap() === s0, `${s0} -> ${snap()}`)
  // edición con ajenos
  const cur = (await get(T.owner, base.id)).body
  const pa = await put(T.owner, base.id, cur.revision, { supplier_id: supB, items: [line(alf, 2, 250)] })
  const pb = await put(T.owner, base.id, cur.revision, { branch_id: brB, items: [line(alf, 2, 250)] })
  const pc = await put(T.owner, base.id, cur.revision, { items: [line(prodB, 2, 250)] })
  check('(3) PUT con proveedor / sucursal / producto ajeno -> 404', pa.status === 404 && pb.status === 404 && pc.status === 404, `${pa.status} ${pb.status} ${pc.status}`)
  check('(3) PUT ajeno sin efectos', snap() === s0 && sql(`select revision from delivery_notes where id='${base.id}'`) === String(cur.revision))
}

// ───────────────────────── 4. el sentido: PUT/anulación cruzados, remito de venta por rutas de compra
{
  const sale = await be(T.owner, 'POST', '/delivery-notes', { client_id: client, branch_id: br1, items: [line(aceite, 1, 900)] }, { 'Idempotency-Key': key() })
  check('(4) control positivo: remito de venta 201 (R-)', sale.status === 201 && /^R-\d{8}$/.test(sale.body?.number_label ?? ''), `${sale.status} ${txt(sale)}`)
  const s0 = snap()
  const p1 = await put(T.owner, sale.body.id, 1, { items: [line(alf, 1, 1)] }) // cuerpo de compra sobre venta
  const p2 = await be(T.owner, 'PUT', `/delivery-notes/${base.id}`, { revision: 1, client_id: client, delivery_address: null, notes: null, branch_id: br1, items: [line(alf, 1, 1)] }) // cuerpo de venta (sin direction) sobre compra
  const p3 = await be(T.owner, 'PUT', `/delivery-notes/${base.id}`, { direction: 'sale', revision: 1, client_id: client, delivery_address: null, notes: null, branch_id: br1, items: [line(alf, 1, 1)] })
  check('(4) PUT de compra sobre un remito de venta -> 409 delivery_note_direction_mismatch', p1.status === 409 && /direction_mismatch/.test(JSON.stringify(p1.body)), `${p1.status} ${txt(p1)}`)
  check('(4) PUT de venta (sin direction) sobre un remito de compra -> 409', p2.status === 409 && /direction_mismatch/.test(JSON.stringify(p2.body)), `${p2.status} ${txt(p2)}`)
  check('(4) PUT con direction=sale sobre un remito de compra -> 409', p3.status === 409 && /direction_mismatch/.test(JSON.stringify(p3.body)), `${p3.status} ${txt(p3)}`)
  const p4 = await be(T.owner, 'PUT', `/delivery-notes/${base.id}`, { direction: 'otro', revision: 1, items: [] })
  check('(4) direction desconocida -> 422', p4.status === 422, `${p4.status}`)
  check('(4) los cruces no dejaron rastro', snap() === s0 && sql(`select status||'|'||revision from delivery_notes where id='${sale.body.id}'`) === 'issued|1')
  // anular la venta por la ruta común funciona con su propio sentido (control)
  const cn = await cancel(T.owner, sale.body.id, 1, 'control de anulación de venta')
  check('(4) control positivo: anular un remito de venta sigue funcionando', cn.status === 200 && sql(`select status from delivery_notes where id='${sale.body.id}'`) === 'canceled', `${cn.status} ${txt(cn)}`)
}

// ───────────────────────── 5. roles por sentido
{
  const s0 = snap()
  for (const who of ['seller', 'cashier', 'purchases']) {
    const rr = await mk(T[who], { items: [line(alf, 1)] })
    check(`(5) ${who} NO puede recibir: 403 sin efectos`, rr.status === 403 && snap() === s0, `${rr.status} ${code(rr)}`)
  }
  const st = await mk(T.stock, { items: [line(alf, 3, 250)] })
  check('(5) control positivo: stock recibe 201', st.status === 201, `${st.status} ${txt(st)}`)
  const stEdit = await put(T.stock, st.body.id, 1, { items: [line(alf, 4, 250)] })
  check('(5) control positivo: stock edita 200', stEdit.status === 200, `${stEdit.status} ${txt(stEdit)}`)
  for (const who of ['stock', 'seller', 'cashier', 'purchases']) {
    const cur = (await get(T.owner, st.body.id)).body
    const rr = await cancel(T[who], st.body.id, cur.revision, 'sin permiso')
    check(`(5) ${who} NO anula: 403 y el remito sigue pendiente`, rr.status === 403 && sql(`select status from delivery_notes where id='${st.body.id}'`) === 'issued', `${rr.status} ${code(rr)}`)
  }
  for (const who of ['seller', 'cashier', 'purchases']) {
    const cur = (await get(T.owner, st.body.id)).body
    const rr = await put(T[who], st.body.id, cur.revision, { items: [line(alf, 1, 250)] })
    check(`(5) ${who} NO edita: 403`, rr.status === 403, `${rr.status}`)
  }
  const cur = (await get(T.owner, st.body.id)).body
  const ad = await cancel(T.admin, st.body.id, cur.revision, 'anula el admin')
  check('(5) control positivo: admin anula 200', ad.status === 200 && sql(`select status from delivery_notes where id='${st.body.id}'`) === 'canceled', `${ad.status} ${txt(ad)}`)
  // lectura libre para todo miembro
  const rd = await get(T.cashier, st.body.id)
  check('(5) la lectura es libre para un miembro sin permiso de emitir', rd.status === 200)
}

// ───────────────────────── 6. editar / anular un anulado; doble anulación
{
  const n = await mk(T.owner, { items: [line(harina, 4, 700)] })
  const s1 = stock(harina, br1)
  const c1 = await cancel(T.owner, n.body.id, 1, 'primera anulación')
  const afterCancel = stock(harina, br1)
  check('(6) anular resta lo recibido del stock', c1.status === 200 && afterCancel === s1 - 4, `${s1} -> ${afterCancel}`)
  const c2 = await cancel(T.owner, n.body.id, 2, 'segunda anulación')
  check('(6) doble anulación -> 409, sin efectos', c2.status === 409 && stock(harina, br1) === afterCancel, `${c2.status} ${code(c2)}`)
  const e1 = await put(T.owner, n.body.id, 2, { items: [line(harina, 10, 700)] })
  check('(6) editar un anulado -> 409, sin efectos', e1.status === 409 && stock(harina, br1) === afterCancel, `${e1.status} ${code(e1)}`)
  const pdf = await be(T.owner, 'GET', `/delivery-notes/${n.body.id}/pdf`)
  check('(6) el PDF de un anulado sigue siendo 200 (sello ANULADO)', pdf.status === 200 && /pdf/.test(pdf.ct), `${pdf.status} ${pdf.ct}`)
}

// ───────────────────────── 7. idempotencia
{
  const k = key()
  const s1 = stock(aceite, br1), n0 = dnCount()
  const a = await mk(T.owner, { items: [line(aceite, 3, 400)] }, k)
  const b = await mk(T.owner, { items: [line(aceite, 3, 400)] }, k)
  check('(7) doble POST con la misma clave: mismo remito, una sola suma', a.status === 201 && b.status >= 200 && b.status < 300 && a.body.id === b.body.id && stock(aceite, br1) === s1 + 3 && dnCount() === n0 + 1, `${a.status}/${b.status} stock ${s1}->${stock(aceite, br1)}`)
  const c = await mk(T.owner, { items: [line(aceite, 9, 400)] }, k)
  check('(7) misma clave con otro cuerpo no suma de nuevo', stock(aceite, br1) === s1 + 3, `${c.status} stock ${stock(aceite, br1)}`)
  const d = await be(T.owner, 'POST', '/delivery-notes', mkBody({ items: [line(aceite, 1)] }))
  check('(7) sin Idempotency-Key -> 4xx sin efectos', d.status >= 400 && stock(aceite, br1) === s1 + 3, `${d.status}`)
  const cross = await mk(T.b, { supplier_id: supB, branch_id: brB, items: [line(prodB, 1, 1)] }, k)
  check('(7) la misma clave en otra cuenta no devuelve el remito de A', cross.status >= 400 || cross.body?.id !== a.body.id, `${cross.status} ${txt(cross)}`)
}

// ───────────────────────── 8. concurrencia: 10 recepciones simultáneas
{
  const s1 = stock(alf, br1), n0 = Number(sql(`select count(*) from delivery_notes where account_id='${accA}' and direction='purchase'`))
  const res = await Promise.all(Array.from({ length: 10 }, () => mk(T.owner, { items: [line(alf, 2, 250)] })))
  const ok = res.filter((x) => x.status === 201)
  const nums = res.map((x) => Number(x.body?.number_label?.slice(3))).sort((a, b) => a - b)
  check('(8) 10 recepciones concurrentes: 10 de 10 aceptadas', ok.length === 10, res.map((x) => x.status).join(','))
  check('(8) el stock sube exactamente 20 (todas suman)', stock(alf, br1) === s1 + 20, `${s1} -> ${stock(alf, br1)}`)
  check('(8) 10 números RC distintos y consecutivos, sin duplicados', new Set(nums).size === 10 && nums[9] - nums[0] === 9, nums.join(','))
  check('(8) 10 remitos nuevos y un movimiento por remito', Number(sql(`select count(*) from delivery_notes where account_id='${accA}' and direction='purchase'`)) === n0 + 10 && ok.every((x) => movs(x.body.id) === 1))
}

// ───────────────────────── 9. 6 ediciones con la misma revisión: gana una
{
  const n = await mk(T.owner, { items: [line(harina, 5, 700)] })
  const s1 = stock(harina, br1)
  const res = await Promise.all(Array.from({ length: 6 }, (_, i) => put(T.owner, n.body.id, 1, { items: [line(harina, 6 + i, 700)] })))
  const wins = res.filter((x) => x.status === 200)
  const finalQty = Number(sql(`select quantity from delivery_note_items where delivery_note_id='${n.body.id}'`))
  check('(9) 6 ediciones con la misma revisión: exactamente 1 gana', wins.length === 1 && res.filter((x) => x.status === 409).length === 5, res.map((x) => x.status).join(','))
  check('(9) el stock refleja sólo la edición ganadora (delta = final - 5)', stock(harina, br1) === s1 + (finalQty - 5), `${s1} -> ${stock(harina, br1)} final ${finalQty}`)
  check('(9) revisión 2 y un solo par de movimientos de edición', sql(`select revision from delivery_notes where id='${n.body.id}'`) === '2' && movs(n.body.id) === 3, `movs ${movs(n.body.id)}`)
}

// ───────────────────────── 10. anulación contra venta del POS del mismo stock (8 vueltas, los dos órdenes posibles)
{
  const pm = sql(`select id from payment_methods where account_id='${accA}' and kind='other' and deleted_at is null limit 1`)
  let negatives = 0, bothOk = 0, neither = 0, cancelWins = 0, saleWins = 0
  for (let i = 0; i < 8; i++) {
    sql(`update branch_stock set quantity=0 where product_id='${escaso}' and branch_id='${br1}'`)
    const n = await mk(T.owner, { items: [line(escaso, 5, 100)] })
    const sellBody = { items: [{ product_id: escaso, quantity: 5, price: 1 }], payment_method: 'other', payment_method_id: pm || undefined, branch_id: br1 }
    const calls = [() => cancel(T.owner, n.body.id, 1, 'carrera con el POS'), () => be(T.owner, 'POST', '/sales-orders/quick-sale', sellBody, { 'Idempotency-Key': key() })]
    if (i % 2) calls.reverse()
    const res = await Promise.all(calls.map((f) => f()))
    const c = i % 2 ? res[1] : res[0], s2 = i % 2 ? res[0] : res[1]
    const sOk = s2.status >= 200 && s2.status < 300, cOk = c.status === 200
    if (stock(escaso, br1) < 0 || Number(sql('select count(*) from branch_stock where quantity<0')) > 0) negatives++
    if (cOk && sOk) bothOk++
    else if (!cOk && !sOk) neither++
    else if (cOk) cancelWins++
    else saleWins++
    // limpieza: si ganó la venta el remito sigue pendiente; se lo deja (su mercadería ya se vendió)
  }
  check('(10) 8 carreras anulación vs venta POS: nunca stock negativo, nunca las dos exitosas, nunca ninguna', negatives === 0 && bothOk === 0 && neither === 0, `gana anulación ${cancelWins}, gana venta ${saleWins}, negativos ${negatives}, ambas ${bothOk}, ninguna ${neither}`)
  const solo = await be(T.owner, 'POST', '/sales-orders/quick-sale', { items: [{ product_id: aceite, quantity: 1, price: 1 }], payment_method: 'other', payment_method_id: pm || undefined, branch_id: br1 }, { 'Idempotency-Key': key() })
  check('(10) control positivo: la venta POS sola 2xx', solo.status >= 200 && solo.status < 300, solo.status)
}

// ───────────────────────── 11. fila forjada en stock_movements no cuenta como recibido
{
  const n = await mk(T.owner, { items: [line(tres, 2, 100)] })
  const base0 = stock(tres, br1)
  // forjar como postgres: un movimiento +50 de 'purchase' que apunta al remito
  sql(`insert into stock_movements (account_id, product_id, branch_id, type, quantity_delta, quantity_before, quantity_after, reference_type, reference_id) values ('${accA}','${tres}','${br1}','purchase',50,${base0},${base0 + 50},'delivery_note','${n.body.id}')`)
  sql(`update branch_stock set quantity=quantity+50 where product_id='${tres}' and branch_id='${br1}'`)
  const afterForge = stock(tres, br1)
  const e = await put(T.owner, n.body.id, 1, { items: [line(tres, 1, 100)] })
  check('(11) edición tras fila forjada: resta sólo 1 (la diferencia de líneas), no lo forjado', e.status === 200 && stock(tres, br1) === afterForge - 1, `${afterForge} -> ${stock(tres, br1)} ${e.status}`)
  const cur = (await get(T.owner, n.body.id)).body
  const c = await cancel(T.owner, n.body.id, cur.revision, 'tras forja')
  check('(11) anulación tras forja: resta sólo lo aportado por las líneas (1)', c.status === 200 && stock(tres, br1) === afterForge - 2, `${afterForge} -> ${stock(tres, br1)} ${c.status}`)
  sql(`update branch_stock set quantity=3 where product_id='${tres}' and branch_id='${br1}'`)
}

// ───────────────────────── 12. validaciones de cuerpo
{
  const s0 = snap()
  const bad = [
    ['cantidad 0', { items: [line(alf, 0, 1)] }],
    ['cantidad negativa', { items: [line(alf, -1, 1)] }],
    ['precio negativo', { items: [{ product_id: alf, quantity: 1, price: -5, subtotal: -5 }] }],
    ['sin líneas', { items: [] }],
    ['referencia de 101 caracteres', { supplier_reference: 'x'.repeat(101), items: [line(alf, 1)] }],
  ]
  for (const [name, body] of bad) {
    const rr = await mk(T.owner, body)
    check(`(12) ${name}: rechazado 4xx sin efectos`, rr.status >= 400 && rr.status < 500 && snap() === s0, `${rr.status}`)
  }
  const zero = await mk(T.owner, { items: [line(sinCosto, 2, 0)] })
  check('(12) control positivo: precio 0 admitido al recibir (missing_price_count=1)', zero.status === 201 && Number(zero.body?.missing_price_count) === 1, `${zero.status} ${txt(zero)}`)
  const forged = await mk(T.owner, { items: [{ product_id: alf, quantity: 2, price: 100, subtotal: 1 }] })
  check('(12) subtotal falso ignorado: total del servidor = 200', forged.status === 201 && Number(forged.body?.total) === 200, `${forged.status} total ${forged.body?.total}`)
}

// ───────────────────────── 13. baja de sucursal con remito de compra pendiente
{
  const brNew = sql(`insert into branches (account_id, name) values ('${accA}','Sucursal RT baja ${Date.now() % 100000}') returning id`).split('\n')[0]
  const n = await mk(T.owner, { branch_id: brNew, items: [line(alf, 1, 250)] })
  const upd = sql(`select 1`)
  const dr = await rest(T.owner, 'PATCH', `branches?id=eq.${brNew}`, { is_active: false })
  const still = sql(`select is_active from branches where id='${brNew}'`)
  check('(13) baja de sucursal con un remito de compra pendiente bloqueada (sigue activa)', still === 't', `${dr.status} ${JSON.stringify(dr.body).slice(0, 120)} is_active=${still}`)
  if (n.status === 201) await cancel(T.owner, n.body.id, 1, 'limpieza')
}

const fails = results.filter(([, ok]) => !ok)
console.log(`\nRESUMEN: ${results.length - fails.length}/${results.length} PASS`)
if (fails.length) { console.log('FALLAS:'); for (const [n] of fails) console.log(' -', n); process.exit(1) }
