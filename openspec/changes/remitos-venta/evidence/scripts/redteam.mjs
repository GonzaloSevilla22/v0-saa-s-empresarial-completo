// Red-team del remito de venta (tanda A) contra GoTrue + PostgREST + FastAPI + Postgres reales (stack LOCAL).
// Cada ataque lleva su control positivo. Imprime PASS/FAIL. Sin credenciales: todo por env (ver lib.mjs).
import { readFileSync } from 'node:fs'
import { login, USERS, sql, be, rest, check, results, API, ANON } from './lib.mjs'

const IDS = JSON.parse(readFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos/ids.json', 'utf8'))
const { accA, accB, br1, br2, brB, client, clientB, harina, alf, escaso, tres, aceite, prodB, kg } = IDS
const stock = (pid, br) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}'${br ? ` and branch_id='${br}'` : ''}`))
const movs = (ref) => Number(sql(`select count(*) from stock_movements where reference_id='${ref}'`))
const dnCount = () => Number(sql(`select count(*) from delivery_notes where account_id in ('${accA}','${accB}')`))
const itemCount = () => Number(sql(`select count(*) from delivery_note_items where account_id in ('${accA}','${accB}')`))
const movTotal = () => Number(sql(`select count(*) from stock_movements where account_id in ('${accA}','${accB}')`))
const line = (pid, q = 1, price = 100, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })
const key = () => crypto.randomUUID()
const mk = (tok, body, k = key()) => be(tok, 'POST', '/delivery-notes', { client_id: client, branch_id: br1, ...body }, { 'Idempotency-Key': k })
const get = (tok, id) => be(tok, 'GET', `/delivery-notes/${id}`)
const code = (r) => r.body?.code ?? r.body?.detail?.code ?? ''

// Re-ejecutable: deja el stock de los dos productos de prueba en su valor de siembra (escaso 1, tres 3).
sql(`update branch_stock set quantity=1 where product_id='${escaso}' and branch_id='${br1}'`)
sql(`update branch_stock set quantity=3 where product_id='${tres}' and branch_id='${br1}'`)
const T = {}
for (const [n, cred] of Object.entries(USERS)) T[n] = await login(...cred)

// ───────────────────────── 0. control positivo: el camino sano funciona
let r = await mk(T.owner, { items: [line(alf, 2, 500)] })
check('(0) control positivo: emitir 201', r.status === 201 && /^R-\d{8}$/.test(r.body?.number_label ?? ''), `${r.status} ${r.body?.number_label}`)
const base = r.body
check('(0) control positivo: GET propio 200', (await get(T.owner, base.id)).status === 200)

// ───────────────────────── 1. escritura directa por PostgREST (debe fallar)
for (const [who, tok] of [['owner', T.owner], ['seller', T.seller], ['b', T.b]]) {
  const n0 = dnCount(), i0 = itemCount()
  const ins = await rest(tok, 'POST', 'delivery_notes', { account_id: accA, direction: 'sale', number: 9999, status: 'issued', client_id: client, branch_id: br1, total: 1, issued_on: '2026-10-02' })
  check(`(1) ${who}: INSERT directo en delivery_notes rechazado`, ins.status >= 400 && dnCount() === n0, `${ins.status} ${JSON.stringify(ins.body).slice(0, 80)}`)
  const insI = await rest(tok, 'POST', 'delivery_note_items', { account_id: accA, delivery_note_id: base.id, product_id: alf, quantity: 1, price: 1, subtotal: 1 })
  check(`(1) ${who}: INSERT directo en delivery_note_items rechazado`, insI.status >= 400 && itemCount() === i0, `${insI.status}`)
  const before = sql(`select notes||'|'||status||'|'||total from delivery_notes where id='${base.id}'`)
  await rest(tok, 'PATCH', `delivery_notes?id=eq.${base.id}`, { notes: 'hack', status: 'canceled', total: 0 })
  check(`(1) ${who}: PATCH directo no cambia el remito`, sql(`select notes||'|'||status||'|'||total from delivery_notes where id='${base.id}'`) === before)
  await rest(tok, 'PATCH', `delivery_note_items?delivery_note_id=eq.${base.id}`, { quantity: 99, quantity_base: 99 })
  check(`(1) ${who}: PATCH directo no cambia las líneas`, sql(`select sum(quantity)||'|'||sum(quantity_base) from delivery_note_items where delivery_note_id='${base.id}'`) === '2.0000|2.0000' || sql(`select sum(quantity)::int||'|'||sum(quantity_base)::int from delivery_note_items where delivery_note_id='${base.id}'`) === '2|2')
  await rest(tok, 'DELETE', `delivery_notes?id=eq.${base.id}`)
  await rest(tok, 'DELETE', `delivery_note_items?delivery_note_id=eq.${base.id}`)
  check(`(1) ${who}: DELETE directo no borra remito ni líneas`, dnCount() === n0 && itemCount() === i0)
}
// SELECT: propio visible por RLS (control positivo) y ajeno invisible
const own = await rest(T.owner, 'GET', `delivery_notes?id=eq.${base.id}&select=id`)
check('(1) control positivo: SELECT propio por PostgREST devuelve la fila', own.status === 200 && own.body.length === 1)
const foreign = await rest(T.b, 'GET', `delivery_notes?id=eq.${base.id}&select=id`)
check('(1) SELECT de otra cuenta por PostgREST devuelve 0 filas', foreign.status === 200 && foreign.body.length === 0, JSON.stringify(foreign.body).slice(0, 60))
const foreignI = await rest(T.b, 'GET', `delivery_note_items?delivery_note_id=eq.${base.id}&select=id`)
check('(1) SELECT de líneas ajenas devuelve 0 filas', foreignI.status === 200 && foreignI.body.length === 0)
const anon = await fetch(`${API}/rest/v1/delivery_notes?select=id`, { headers: { apikey: ANON, Authorization: `Bearer ${ANON}` } })
const anonBody = await anon.json().catch(() => null)
check('(1) anon no lee delivery_notes', anon.status >= 400 || (Array.isArray(anonBody) && anonBody.length === 0), `${anon.status}`)
// RPC directas: los helpers internos no son llamables por authenticated
for (const fn of ['_delivery_note_apply_stock', '_delivery_note_reverse_held', '_delivery_note_lock_products', '_delivery_note_insert_items', '_delivery_note_held_pairs']) {
  const rr = await rest(T.owner, 'POST', `rpc/${fn}`, {})
  check(`(1) helper interno ${fn} no expuesto a authenticated`, rr.status >= 400, `${rr.status}`)
}

// ───────────────────────── 2. otra cuenta por id: 404 idéntico al inexistente
const ghost = crypto.randomUUID()
const sample = async (tok, id) => ({
  get: await get(tok, id),
  pdf: await be(tok, 'GET', `/delivery-notes/${id}/pdf`),
  put: await be(tok, 'PUT', `/delivery-notes/${id}`, { delivery_address: null, notes: null, revision: 1, client_id: clientB, branch_id: brB, items: [line(prodB, 1, 1)] }),
  cancel: await be(tok, 'POST', `/delivery-notes/${id}/cancel`, { revision: 1, reason: 'intento ajeno' }),
})
const f = await sample(T.b, base.id), g = await sample(T.b, ghost)
for (const op of ['get', 'pdf', 'put', 'cancel']) {
  check(`(2) ${op} de remito ajeno = 404 idéntico al inexistente`, f[op].status === 404 && g[op].status === 404 && code(f[op]) === code(g[op]), `ajeno ${f[op].status}/${code(f[op])} inexistente ${g[op].status}/${code(g[op])}`)
}
check('(2) el remito ajeno quedó intacto', sql(`select status||'|'||revision from delivery_notes where id='${base.id}'`) === 'issued|1')
const lst = await be(T.b, 'GET', '/delivery-notes')
check('(2) el listado de B no contiene remitos de A', lst.status === 200 && lst.body.items.every((x) => x.id !== base.id) && lst.body.items.every((x) => x.client_name !== 'Cliente Demo QA'), `total ${lst.body?.total}`)

// ───────────────────────── 3. producto / cliente / sucursal ajenos: 404 sin efectos
const snap = () => `${dnCount()}|${itemCount()}|${movTotal()}|${stock(alf)}|${stock(prodB)}`
let s0 = snap()
r = await mk(T.owner, { items: [line(prodB, 1, 1)] })
check('(3) producto de otra cuenta -> 404 sin efectos', r.status === 404 && snap() === s0, `${r.status} ${code(r)}`)
r = await mk(T.owner, { client_id: clientB, items: [line(alf, 1, 1)] })
check('(3) cliente de otra cuenta -> 404 sin efectos', r.status === 404 && snap() === s0, `${r.status} ${code(r)}`)
r = await mk(T.owner, { branch_id: brB, items: [line(alf, 1, 1)] })
check('(3) sucursal de otra cuenta -> 404 sin efectos', r.status === 404 && snap() === s0, `${r.status} ${code(r)}`)
r = await mk(T.owner, { items: [line(alf, 1, 1, { unit_id: crypto.randomUUID() })] })
check('(3) unidad inexistente -> rechazo sin efectos', r.status >= 400 && snap() === s0, `${r.status} ${code(r)}`)
r = await mk(T.owner, { items: [] })
check('(3) sin ítems -> rechazo sin efectos', r.status >= 400 && snap() === s0, `${r.status}`)
r = await mk(T.owner, { items: [line(alf, -1, 1)] })
check('(3) cantidad negativa -> rechazo sin efectos', r.status >= 400 && snap() === s0, `${r.status}`)
r = await mk(T.owner, { items: [line(alf, 1, 1)] })
check('(3) control positivo: con datos propios emite', r.status === 201)
// PUT con cliente/producto ajeno sobre remito propio
const own2 = r.body
s0 = snap()
r = await be(T.owner, 'PUT', `/delivery-notes/${own2.id}`, { delivery_address: null, notes: null, revision: own2.revision, client_id: client, branch_id: br1, items: [line(prodB, 1, 1)] })
check('(3) PUT con producto ajeno -> 404 sin efectos', r.status === 404 && snap() === s0, `${r.status} ${code(r)}`)
r = await be(T.owner, 'PUT', `/delivery-notes/${own2.id}`, { delivery_address: null, notes: null, revision: own2.revision, client_id: clientB, branch_id: br1, items: [line(alf, 1, 1)] })
check('(3) PUT con cliente ajeno -> 404 sin efectos', r.status === 404 && snap() === s0, `${r.status} ${code(r)}`)

// ───────────────────────── 4. editar / anular un anulado, doble anulación
r = await mk(T.owner, { items: [line(alf, 3, 500)] })
const t4 = r.body
const st0 = stock(alf, br1)
let c1 = await be(T.admin, 'POST', `/delivery-notes/${t4.id}/cancel`, { revision: t4.revision, reason: 'prueba de anulación' })
check('(4) control positivo: admin anula', c1.status === 200 && stock(alf, br1) === st0 + 3, `${c1.status} stock ${st0}->${stock(alf, br1)}`)
const st1 = stock(alf, br1), m1 = movs(t4.id)
const c2 = await be(T.admin, 'POST', `/delivery-notes/${t4.id}/cancel`, { revision: c1.body?.revision ?? 2, reason: 'otra vez' })
check('(4) segunda anulación rechazada sin efectos', c2.status >= 400 && stock(alf, br1) === st1 && movs(t4.id) === m1, `${c2.status} ${code(c2)}`)
const c2b = await be(T.admin, 'POST', `/delivery-notes/${t4.id}/cancel`, { revision: t4.revision, reason: 'revision vieja' })
check('(4) anulación con revisión vieja sobre un anulado rechazada', c2b.status >= 400 && stock(alf, br1) === st1, `${c2b.status} ${code(c2b)}`)
const e1 = await be(T.owner, 'PUT', `/delivery-notes/${t4.id}`, { delivery_address: null, notes: null, revision: c1.body?.revision ?? 2, client_id: client, branch_id: br1, items: [line(alf, 5, 500)] })
check('(4) editar un anulado rechazado sin efectos', e1.status >= 400 && stock(alf, br1) === st1 && movs(t4.id) === m1, `${e1.status} ${code(e1)}`)
const hist = Number(sql(`select count(*) from document_status_history where document_id='${t4.id}' and to_status='canceled'`))
check('(4) historial: una sola anulación registrada', hist === 1, `${hist}`)
const cs = await be(T.admin, 'POST', `/delivery-notes/${own2.id}/cancel`, { revision: own2.revision, reason: '  ' })
check('(4) anular sin motivo (sólo espacios) rechazado', cs.status >= 400 && sql(`select status from delivery_notes where id='${own2.id}'`) === 'issued', `${cs.status} ${code(cs)}`)

// ───────────────────────── 5. roles
const rol = {}
for (const who of ['seller', 'stock', 'cashier', 'admin', 'owner']) rol[who] = await mk(T[who], { items: [line(alf, 1, 500)] })
check('(5) seller emite', rol.seller.status === 201, `${rol.seller.status}`)
check('(5) stock emite', rol.stock.status === 201, `${rol.stock.status}`)
check('(5) admin y owner emiten', rol.admin.status === 201 && rol.owner.status === 201)
check('(5) cashier NO emite (403, sin efectos)', rol.cashier.status === 403, `${rol.cashier.status} ${code(rol.cashier)}`)
for (const who of ['seller', 'stock', 'cashier']) {
  const tgt = who === 'cashier' ? rol.owner.body : rol[who].body
  const sb = stock(alf, br1)
  const cr = await be(T[who], 'POST', `/delivery-notes/${tgt.id}/cancel`, { revision: tgt.revision, reason: 'sin permiso' })
  check(`(5) ${who} NO anula (403) y el stock no cambia`, cr.status === 403 && stock(alf, br1) === sb && sql(`select status from delivery_notes where id='${tgt.id}'`) === 'issued', `${cr.status} ${code(cr)}`)
}
const ed = await be(T.stock, 'PUT', `/delivery-notes/${rol.stock.body.id}`, { delivery_address: null, notes: null, revision: rol.stock.body.revision, client_id: client, branch_id: br1, items: [line(alf, 2, 500)] })
check('(5) stock edita su remito', ed.status === 200, `${ed.status}`)
const edC = await be(T.cashier, 'PUT', `/delivery-notes/${rol.owner.body.id}`, { delivery_address: null, notes: null, revision: rol.owner.body.revision, client_id: client, branch_id: br1, items: [line(alf, 2, 500)] })
check('(5) cashier NO edita (403)', edC.status === 403, `${edC.status}`)
const ca = await be(T.admin, 'POST', `/delivery-notes/${rol.seller.body.id}/cancel`, { revision: rol.seller.body.revision, reason: 'anula admin' })
const co = await be(T.owner, 'POST', `/delivery-notes/${rol.admin.body.id}/cancel`, { revision: rol.admin.body.revision, reason: 'anula owner' })
check('(5) control positivo: admin y owner anulan', ca.status === 200 && co.status === 200, `${ca.status} ${co.status}`)
// lectura por rol
const rd = await Promise.all(['cashier', 'seller', 'stock'].map((w) => be(T[w], 'GET', '/delivery-notes')))
check('(5) los roles leen el listado', rd.every((x) => x.status === 200), rd.map((x) => x.status).join(','))

// ───────────────────────── 6. idempotencia: doble POST con la misma clave
const k = key()
const [d1, d2] = await Promise.all([mk(T.owner, { items: [line(alf, 1, 500)] }, k), mk(T.owner, { items: [line(alf, 1, 500)] }, k)])
const same = d1.body?.id && d1.body?.id === d2.body?.id
const nk = Number(sql(`select count(*) from delivery_notes where id='${d1.body?.id}'`))
check('(6) misma Idempotency-Key concurrente: un remito, ambos 2xx, uno replayed', [d1.status, d2.status].every((s) => s === 200 || s === 201) && same && nk === 1 && [d1.body.replayed, d2.body.replayed].filter(Boolean).length === 1, `${d1.status}/${d2.status} replayed ${d1.body?.replayed}/${d2.body?.replayed}`)
check('(6) un solo movimiento de stock por la clave repetida', movs(d1.body.id) === 1, `${movs(d1.body.id)}`)
const sb6 = stock(alf, br1)
const d3 = await mk(T.owner, { items: [line(alf, 1, 500)] }, k)
check('(6) tercer reintento: 200 replayed, sin descuento extra', d3.status === 200 && d3.body.replayed === true && stock(alf, br1) === sb6, `${d3.status} ${d3.body?.replayed}`)
const d4 = await mk(T.owner, { items: [line(alf, 7, 500)] }, k)
check('(6) misma clave con otro cuerpo: replay del original, no crea otro', d4.status < 300 ? d4.body.id === d1.body.id : d4.status === 409, `${d4.status}`)
const d5 = await be(T.owner, 'POST', '/delivery-notes', { client_id: client, branch_id: br1, items: [line(alf, 1, 500)] })
check('(6) sin Idempotency-Key -> 422', d5.status === 422, `${d5.status} ${code(d5)}`)
const kB = key()
const dB1 = await mk(T.owner, { items: [line(alf, 1, 500)] }, kB)
const dB2 = await be(T.b, 'POST', '/delivery-notes', { client_id: clientB, branch_id: brB, items: [line(prodB, 1, 1)] }, { 'Idempotency-Key': kB })
check('(6) la misma clave de otra cuenta no hace replay del remito ajeno', dB2.status !== 200 || dB2.body?.id !== dB1.body?.id, `${dB2.status}`)

// ───────────────────────── 7. 10 emisiones concurrentes sobre un stock que alcanza para 3
const sTres0 = stock(tres, br1)
const rs = await Promise.all(Array.from({ length: 10 }, () => mk(T.owner, { items: [line(tres, 1, 300)] })))
const okN = rs.filter((x) => x.status === 201).length
const ids7 = rs.filter((x) => x.status === 201).map((x) => x.body.id)
check('(7) exactamente 3 de 10 pasan', okN === 3, `${rs.map((x) => x.status).join(',')}`)
check('(7) el resto responde 409 stock_insuficiente (no 500)', rs.filter((x) => x.status !== 201).every((x) => x.status === 409), rs.filter((x) => x.status !== 201).map((x) => `${x.status}/${code(x)}`).join(' '))
check('(7) stock final 0, nunca negativo', stock(tres, br1) === 0 && sTres0 === 3, `${sTres0} -> ${stock(tres, br1)}`)
check('(7) 3 remitos y 3 movimientos, números consecutivos sin hueco', ids7.length === 3 && Number(sql(`select count(*) from stock_movements where reference_id in ('${ids7.join("','")}')`)) === 3)
const nums = sql(`select string_agg(number::text, ',' order by number) from delivery_notes where account_id='${accA}'`).split(',').map(Number)
check('(7) la numeración de la cuenta no tiene huecos', nums.every((n, i) => i === 0 || n === nums[i - 1] + 1), nums.join(','))
const sinNeg = Number(sql(`select count(*) from branch_stock where account_id='${accA}' and quantity < 0`))
check('(7) ningún branch_stock negativo en la cuenta', sinNeg === 0, `${sinNeg}`)

// ───────────────────────── 8. 6 ediciones concurrentes con la misma revisión
r = await mk(T.owner, { items: [line(aceite, 1, 900)] })
const n8 = r.body
const sa0 = stock(aceite, br1)
const es = await Promise.all(Array.from({ length: 6 }, (_, i) => be(T.owner, 'PUT', `/delivery-notes/${n8.id}`, { delivery_address: null, notes: null, revision: n8.revision, client_id: client, branch_id: br1, notes: `e${i}`, items: [line(aceite, i + 2, 900)] })))
const win = es.filter((x) => x.status === 200), lose = es.filter((x) => x.status === 409)
check('(8) 6 ediciones con la misma revisión: 1 gana, 5 conflicto', win.length === 1 && lose.length === 5, es.map((x) => `${x.status}/${code(x)}`).join(' '))
check('(8) los 5 perdedores dicen delivery_note_changed', lose.every((x) => code(x) === 'delivery_note_changed'), lose.map(code).join(','))
const qty = Number(sql(`select sum(quantity)::int from delivery_note_items where delivery_note_id='${n8.id}'`))
check('(8) el stock refleja SÓLO la edición ganadora', stock(aceite, br1) === sa0 - (qty - 1) && sql(`select revision from delivery_notes where id='${n8.id}'`) === '2', `qty ${qty} stock ${sa0}->${stock(aceite, br1)}`)
// edición vs anulación concurrentes
r = await mk(T.owner, { items: [line(aceite, 2, 900)] })
const n9 = r.body, sa9 = stock(aceite, br1)
const [ex, cx] = await Promise.all([
  be(T.owner, 'PUT', `/delivery-notes/${n9.id}`, { delivery_address: null, notes: null, revision: n9.revision, client_id: client, branch_id: br1, items: [line(aceite, 5, 900)] }),
  be(T.admin, 'POST', `/delivery-notes/${n9.id}/cancel`, { revision: n9.revision, reason: 'carrera' }),
])
const stFinal = sql(`select status from delivery_notes where id='${n9.id}'`)
check('(8) edición vs anulación: gana exactamente una; el stock es coherente', [ex.status, cx.status].filter((s) => s === 200).length === 1 && ((stFinal === 'canceled' && stock(aceite, br1) === sa9 + 2) || (stFinal === 'issued' && stock(aceite, br1) === sa9 - 3)), `${ex.status}/${cx.status} ${stFinal} stock ${sa9}->${stock(aceite, br1)}`)

// ───────────────────────── 9. fila forjada en stock_movements (RLS preexistente)
r = await mk(T.seller, { items: [line(escaso, 1, 300)] })
const n10 = r.body
const forge = await rest(T.owner, 'POST', 'stock_movements', { account_id: accA, product_id: escaso, type: 'sale', quantity_delta: -1000, reference_id: n10.id, reference_type: 'delivery_note', branch_id: br1 })
check('(9) control positivo: la fila forjada entra por PostgREST (RLS preexistente, candidato 9.1)', forge.status < 300, `${forge.status}`)
const se0 = stock(escaso, br1)
const e10 = await be(T.seller, 'PUT', `/delivery-notes/${n10.id}`, { delivery_address: null, notes: null, revision: n10.revision, client_id: client, branch_id: br1, items: [line(escaso, 1, 400)] })
check('(9) edición sólo de precio: cero movimientos nuevos y stock igual (no usa la fila forjada)', e10.status === 200 && stock(escaso, br1) === se0, `${e10.status}`)
const c10 = await be(T.admin, 'POST', `/delivery-notes/${n10.id}/cancel`, { revision: 2, reason: 'fila forjada' })
check('(9) la anulación devuelve sólo lo retenido por las líneas (+1), no lo forjado', c10.status === 200 && stock(escaso, br1) === se0 + 1, `stock ${se0}->${stock(escaso, br1)}`)
const rv = await rest(T.owner, 'POST', 'rpc/rpc_reverse_stock_movement', { p_reference_id: n10.id, p_reference_type: 'delivery_note', p_reason: 'intento' })
check('(9) rpc_reverse_stock_movement NO acepta reference_type delivery_note (stock intacto)', stock(escaso, br1) === se0 + 1, `rpc ${rv.status} ${JSON.stringify(rv.body).slice(0, 110)}`)
// control positivo preexistente (candidato 9.1): una fila forjada reference_type='sale' SI se revierte hoy
const refS = crypto.randomUUID()
const forged2 = await rest(T.owner, 'POST', 'stock_movements', { account_id: accA, product_id: escaso, type: 'sale', quantity_delta: -1, reference_id: refS, reference_type: 'sale', branch_id: br1 })
const sf0 = stock(escaso, br1)
const rv2 = await rest(T.owner, 'POST', 'rpc/rpc_reverse_stock_movement', { p_reference_id: refS, p_reference_type: 'sale', p_reason: 'control positivo' })
check('(9) control positivo preexistente: reference_type=sale forjada SI se revierte (candidato 9.1)', forged2.status < 300 && rv2.status < 300 && stock(escaso, br1) === sf0 + 1, `forja ${forged2.status} rpc ${rv2.status} stock ${sf0}->${stock(escaso, br1)} ${JSON.stringify(rv2.body).slice(0, 80)}`)

// ───────────────────────── 10. el kardex no queda con filas huérfanas del remito anulado
const sumDelta = Number(sql(`select coalesce(sum(quantity_delta),0) from stock_movements where reference_id='${t4.id}'`))
check('(10) remito anulado: Σ delta de sus movimientos = 0', sumDelta === 0, `${sumDelta}`)

const failed = results.filter(([, ok]) => !ok)
console.log(`\nRESUMEN: ${results.length - failed.length}/${results.length} PASS`)
if (failed.length) { console.log('FALLAN:', failed.map(([n]) => n).join(' | ')); process.exit(1) }
