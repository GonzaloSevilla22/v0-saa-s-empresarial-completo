// Red-team de la TANDA B de remitos-compra (conversión remito -> compra, borrado y edición de la compra nacida de un remito,
// puente purchases.source_delivery_note_id) contra GoTrue + PostgREST + FastAPI + Postgres reales (stack LOCAL).
// Cada ataque lleva su control positivo. Imprime PASS/FAIL. Sin credenciales: todo por env (ver lib.mjs).
import { readFileSync } from 'node:fs'
import { login, USERS, sql, be, rest, check, results, API, ANON } from './lib.mjs'

const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b'
const IDS = { ...JSON.parse(readFileSync(`${SP}/ids.json`, 'utf8')), ...JSON.parse(readFileSync(`${SP}/ids-b.json`, 'utf8')) }
const { accA, accB, br1, brB, client, harina, alf, aceite, prodB, sup, sup2, supB, sinCosto, kg, cashboxId } = IDS
const stockAll = (pid) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}'`))
const movTotal = () => Number(sql(`select count(*) from stock_movements where account_id in ('${accA}','${accB}')`))
const dnStatus = (id) => sql(`select status from delivery_notes where id='${id}'`)
const dnRev = (id) => Number(sql(`select revision from delivery_notes where id='${id}'`))
const purchaseRows = (dn) => Number(sql(`select count(*) from purchases where source_delivery_note_id='${dn}'`))
const opsOfDn = (dn) => Number(sql(`select count(distinct operation_id) from purchases where source_delivery_note_id='${dn}'`))
const opOfDn = (dn) => sql(`select operation_id from purchases where source_delivery_note_id='${dn}' limit 1`)
const rowsOfOp = (op) => sql(`select string_agg(id::text, ',' order by created_at, id) from purchases where operation_id='${op}'`).split(',')
const purchasesTotal = () => Number(sql(`select count(*) from purchases where account_id in ('${accA}','${accB}')`))
const cashN = () => Number(sql(`select count(*) from cash_movements cm join cash_sessions s on s.id=cm.session_id join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${accA}'`))
const bankN = () => Number(sql(`select count(*) from bank_movements where account_id='${accA}'`))
const supN = () => Number(sql(`select count(*) from supplier_account_movements m join supplier_accounts s on s.id=m.supplier_account_id where s.account_id='${accA}'`))
const line = (pid, q = 1, price = 100, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })
const key = () => crypto.randomUUID()
const mk = (tok, items, extra = {}) => be(tok, 'POST', '/delivery-notes', { direction: 'purchase', supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, items, ...extra }, { 'Idempotency-Key': key() })
const pmId = (kind) => sql(`select id from payment_methods where account_id='${accA}' and kind='${kind}' and is_active order by sort_order, created_at limit 1`)
const conv = (tok, id, body = {}, k = key(), extra = {}) =>
  be(tok, 'POST', `/delivery-notes/${id}/convert-to-purchase`, { expected_revision: dnRev(id), payment_method_id: pmId('transfer'), ...body }, k === null ? extra : { 'Idempotency-Key': k, ...extra })
const code = (r) => r.body?.code ?? r.body?.detail?.code ?? r.body?.detail ?? ''
const txt = (r) => JSON.stringify(r.body ?? '').slice(0, 240)
const guard = (r) => /delivery_note_source_protected/.test(JSON.stringify(r.body ?? ''))
const info = (m) => console.log('INFO  ' + m)
const snapDb = () => `${purchasesTotal()}|${movTotal()}|${stockAll(harina)}|${stockAll(alf)}|${cashN()}|${bankN()}|${supN()}`

const T = {}
for (const [n, cred] of Object.entries(USERS)) T[n] = await login(...cred)
// la caja tiene que estar abierta para los controles de efectivo
{
  const cur = await be(T.owner, 'GET', `/cashboxes/${cashboxId}/current-session`)
  if (!(cur.status === 200 && cur.body?.status === 'open')) await be(T.owner, 'POST', `/cashboxes/${cashboxId}/sessions/open`, { opening_balance: 1000 })
}

// ───────────────────────── 0. controles positivos: dos roles distintos convierten
let r = await mk(T.owner, [line(alf, 2, 250)])
const base = r.body
check('(0) control positivo: recibir un remito de compra 201', r.status === 201, `${r.status} ${txt(r)}`)
const s0 = stockAll(alf), m0 = movTotal()
r = await conv(T.stock, base.id)
check('(0) control positivo: el depósito (stock) convierte el remito en compra (200)', r.status === 200 && r.body?.replayed === false && dnStatus(base.id) === 'converted', `${r.status} ${txt(r)}`)
check('(0) la conversión no vuelve a sumar el stock ni escribe movimientos', stockAll(alf) === s0 && movTotal() === m0, `${s0}->${stockAll(alf)} mov ${m0}->${movTotal()}`)
const dnPur = (await mk(T.owner, [line(alf, 1, 250)])).body
r = await conv(T.purchases, dnPur.id)
check('(0) control positivo: purchases convierte el remito en compra (200)', r.status === 200 && dnStatus(dnPur.id) === 'converted', `${r.status} ${txt(r)}`)

// ───────────────────────── 1. integridad del puente por PostgREST (el trigger del puente)
const opBase = opOfDn(base.id)
const [rowBase] = rowsOfOp(opBase)
const dn2 = (await mk(T.owner, [line(alf, 1, 250)])).body // remito pendiente válido: a donde se intenta apuntar
const direct = await be(T.owner, 'POST', '/purchases', { org_id: accA, items: [{ product_id: aceite, quantity: 1, amount: 100 }, { product_id: alf, quantity: 1, amount: 100 }], branch_id: br1, supplier_id: sup, payment_method_id: pmId('transfer') }, { 'Idempotency-Key': key() })
check('(1) control positivo: compra directa por la API (201)', direct.status === 201, `${direct.status} ${txt(direct)}`)
const opDirect = direct.body.operation_id
const [rowDirect, rowDirect2] = rowsOfOp(opDirect)
const rowState = (id) => sql(`select coalesce(source_delivery_note_id::text,'-')||'|'||coalesce(operation_id::text,'-')||'|'||coalesce(description,'')||'|'||amount from purchases where id='${id}'`)
const attacks = []
for (const who of ['owner', 'seller', 'stock', 'purchases']) {
  const tok = T[who]
  const b0 = rowState(rowBase), d0 = rowState(rowDirect), n0 = purchasesTotal()
  // control positivo: una escritura legítima sobre una compra directa pasa por el trigger del puente
  const okPatch = await rest(tok, 'PATCH', `purchases?id=eq.${rowDirect}`, { description: `rt-${who}` })
  const okApplied = sql(`select description from purchases where id='${rowDirect}'`) === `rt-${who}`
  info(`(1) ${who}: PATCH legítimo (description) de una compra directa -> ${okPatch.status} aplicado=${okApplied}`)
  await rest(tok, 'PATCH', `purchases?id=eq.${rowDirect}`, { description: null })
  const forge = await rest(tok, 'PATCH', `purchases?id=eq.${rowDirect}`, { source_delivery_note_id: dn2.id })
  const clear = await rest(tok, 'PATCH', `purchases?id=eq.${rowBase}`, { source_delivery_note_id: null })
  const change = await rest(tok, 'PATCH', `purchases?id=eq.${rowBase}`, { source_delivery_note_id: dn2.id })
  const touch = await rest(tok, 'PATCH', `purchases?id=eq.${rowBase}`, { description: 'tocada' })
  const split = await rest(tok, 'PATCH', `purchases?id=eq.${rowBase}`, { operation_id: crypto.randomUUID() })
  const mixUpd = await rest(tok, 'PATCH', `purchases?id=eq.${rowDirect}`, { operation_id: opBase })
  const mixIns = await rest(tok, 'POST', 'purchases', { account_id: accA, product_id: alf, quantity: 1, amount: 1, total: 1, operation_id: opBase, branch_id: br1, supplier_id: sup, date: new Date().toISOString() })
  const insOrigin = await rest(tok, 'POST', 'purchases', { account_id: accA, product_id: alf, quantity: 1, amount: 1, total: 1, operation_id: crypto.randomUUID(), branch_id: br1, supplier_id: sup, date: new Date().toISOString(), source_delivery_note_id: dn2.id })
  const delOrigin = await rest(tok, 'DELETE', `purchases?id=eq.${rowBase}`)
  attacks.push({ who, forge, clear, change, touch, split, mixUpd, mixIns, insOrigin, delOrigin })
  const isOwner = who === 'owner'
  const rejected = (a, name) => {
    const ok = a.status >= 400 && (guard(a) || !isOwner)
    check(`(1) ${who}: ${name} rechazado por el puente`, ok, `${a.status} ${JSON.stringify(a.body).slice(0, 110)}`)
  }
  rejected(forge, 'FORJAR el origen en una compra directa (PATCH source_delivery_note_id)')
  rejected(clear, 'LIMPIAR el origen de una compra de remito')
  rejected(change, 'CAMBIAR el origen a otro remito')
  rejected(touch, 'tocar CUALQUIER columna de una fila con origen')
  rejected(split, 'PARTIR la compra (UPDATE operation_id de una fila con origen)')
  rejected(mixUpd, 'MEZCLAR: llevar una compra directa a la operación convertida (UPDATE operation_id)')
  rejected(mixIns, 'MEZCLAR: INSERT con operation_id de la compra convertida')
  rejected(insOrigin, 'INSERT con source_delivery_note_id')
  rejected(delOrigin, 'DELETE de una fila con origen')
  check(`(1) ${who}: ningún ataque dejó rastro (filas, origen, operación, descripción)`, rowState(rowBase) === b0 && rowState(rowDirect) === d0.replace(/rt-[a-z]+/, '') || rowState(rowDirect) === d0, `${rowState(rowBase)} / ${rowState(rowDirect)} compras ${n0}->${purchasesTotal()}`)
  check(`(1) ${who}: la compra del remito sigue intacta (origen, operación) y el remito sigue converted`, purchaseRows(base.id) === 1 && opsOfDn(base.id) === 1 && dnStatus(base.id) === 'converted')
}
{
  const ownerAttempts = attacks.find((a) => a.who === 'owner')
  check('(1) owner: el rechazo es el del TRIGGER (P0403 delivery_note_source_protected), no una RLS', Object.values(ownerAttempts).filter((v) => v && typeof v === 'object' && 'status' in v).every((a) => guard(a)), Object.entries(ownerAttempts).filter(([k, v]) => k !== 'who' && !guard(v)).map(([k]) => k).join(','))
}
// borrado de una compra directa: control positivo (el trigger no estorba lo legítimo)
{
  const del = await rest(T.owner, 'DELETE', `purchases?id=eq.${rowDirect2}`)
  check('(1) control positivo: DELETE directo de una fila de compra directa pasa por el trigger', del.status < 300 && sql(`select count(*) from purchases where id='${rowDirect2}'`) === '0', `${del.status} ${txt(del)}`)
}
{
  const anon = await fetch(`${API}/rest/v1/purchases?id=eq.${rowBase}`, { method: 'PATCH', headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ source_delivery_note_id: null }) })
  check('(1) anon no puede tocar purchases (ni el origen)', anon.status >= 400 || rowState(rowBase).startsWith(base.id), `${anon.status}`)
}

// ───────────────────────── 2. funciones por PostgREST: la firma pública no admite un origen; el núcleo y los helpers no se exponen
{
  const nDirect = purchasesTotal()
  const withOrigin = await rest(T.owner, 'POST', 'rpc/rpc_create_purchase_operation', {
    p_idempotency_key: key(), p_date: new Date().toISOString().slice(0, 10), p_description: 'rt', p_items: [{ product_id: alf, quantity: 1, amount: 100 }], p_source_delivery_note_id: dn2.id,
  })
  check('(2) rpc_create_purchase_operation con un parámetro de origen: la firma pública no lo admite (sin función)', withOrigin.status >= 400 && (withOrigin.body?.code === 'PGRST202' || /Could not find the function|function .* does not exist/i.test(JSON.stringify(withOrigin.body))) && purchasesTotal() === nDirect, `${withOrigin.status} ${txt(withOrigin)}`)
  const legitDesc = `rt-legit-${crypto.randomUUID().slice(0, 8)}`
  const legit = await rest(T.owner, 'POST', 'rpc/rpc_create_purchase_operation', {
    p_idempotency_key: key(), p_date: new Date().toISOString().slice(0, 10), p_description: legitDesc, p_items: [{ product_id: alf, quantity: 1, amount: 100 }], p_supplier_id: sup, p_branch_id: br1,
  })
  check('(2) control positivo: la misma llamada SIN origen crea una compra directa (sin source_delivery_note_id)', legit.status < 300 && purchasesTotal() === nDirect + 1 && sql(`select count(*) from purchases where description='${legitDesc}' and source_delivery_note_id is null`) === '1', `${legit.status} ${txt(legit)}`)
  const core = await rest(T.owner, 'POST', 'rpc/_purchase_operation_core', { p_account_id: accA, p_idempotency_key: key(), p_source_delivery_note_id: dn2.id })
  check('(2) _purchase_operation_core no está expuesto a authenticated', core.status >= 400 && purchasesTotal() === nDirect + 1 && dnStatus(dn2.id) === 'issued', `${core.status} ${txt(core)}`)
  const coreAnon = await fetch(`${API}/rest/v1/rpc/_purchase_operation_core`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' }, body: '{}' })
  check('(2) _purchase_operation_core no está expuesto a anon', coreAnon.status >= 400, `${coreAnon.status}`)
  const rpcSeller = await rest(T.seller, 'POST', 'rpc/rpc_convert_delivery_note_to_purchase', { p_idempotency_key: key(), p_delivery_note_id: dn2.id, p_expected_revision: dnRev(dn2.id), p_payment_method_id: pmId('transfer') })
  check('(2) seller por la RPC de conversión de PostgREST: rechazado sin efectos', rpcSeller.status >= 400 && dnStatus(dn2.id) === 'issued' && purchaseRows(dn2.id) === 0, `${rpcSeller.status} ${txt(rpcSeller)}`)
}

// ───────────────────────── 3. la conversión por la API
{
  const ghost = crypto.randomUUID()
  const f = await conv(T.b, dn2.id, { payment_method_id: pmId('transfer'), expected_revision: dnRev(dn2.id) })
  const g = await conv(T.b, ghost, { payment_method_id: pmId('transfer'), expected_revision: 1 })
  check('(3) convertir el remito de OTRA cuenta = 404 idéntico al inexistente', f.status === 404 && g.status === 404 && code(f) === code(g), `ajeno ${f.status}/${code(f)} inexistente ${g.status}/${code(g)}`)
  check('(3) el remito ajeno quedó intacto', dnStatus(dn2.id) === 'issued' && purchaseRows(dn2.id) === 0)
  const sale = (await be(T.owner, 'POST', '/delivery-notes', { client_id: client, branch_id: br1, items: [{ product_id: alf, quantity: 1, price: 500, subtotal: 500 }] }, { 'Idempotency-Key': key() })).body
  const viaPurchase = await conv(T.owner, sale.id)
  check('(3) un remito de VENTA por la ruta de compra se rechaza sin efectos', viaPurchase.status >= 400 && dnStatus(sale.id) === 'issued', `${viaPurchase.status} ${txt(viaPurchase)}`)
  const ghostRoute = await be(T.owner, 'POST', `/delivery-notes/${dn2.id}/convert`, { expected_revision: dnRev(dn2.id), payment_method_id: pmId('transfer') }, { 'Idempotency-Key': key() })
  check('(3) un remito de COMPRA por la ruta de venta se rechaza sin efectos', ghostRoute.status >= 400 && dnStatus(dn2.id) === 'issued' && purchaseRows(dn2.id) === 0, `${ghostRoute.status} ${txt(ghostRoute)}`)
  for (const who of ['seller', 'cashier', 'viewer']) {
    if (!T[who]) continue
    const x = await conv(T[who], dn2.id)
    check(`(3) ${who} no convierte (403)`, x.status === 403 && dnStatus(dn2.id) === 'issued', `${x.status} ${code(x)}`)
  }
  const noKey = await conv(T.owner, dn2.id, {}, null)
  check('(3) sin Idempotency-Key = 422', noKey.status === 422 && dnStatus(dn2.id) === 'issued', `${noKey.status}`)
  const noPm = await be(T.owner, 'POST', `/delivery-notes/${dn2.id}/convert-to-purchase`, { expected_revision: dnRev(dn2.id) }, { 'Idempotency-Key': key() })
  check('(3) sin forma de pago = 422 (obligatoria, OQ-RC4)', noPm.status === 422 && dnStatus(dn2.id) === 'issued', `${noPm.status} ${txt(noPm)}`)
  // se sube la revisión del remito con una edición real (mismo contenido) para que la revisión 1 quede VIEJA
  const staleRev = dnRev(dn2.id)
  const bump = await be(T.owner, 'PUT', `/delivery-notes/${dn2.id}`, { direction: 'purchase', revision: staleRev, supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, items: [line(alf, 1, 250)] })
  check('(3) preparación: editar el remito sube su revisión', bump.status === 200 && dnRev(dn2.id) === staleRev + 1, `${bump.status} rev ${staleRev}->${dnRev(dn2.id)}`)
  const stale = await conv(T.owner, dn2.id, { expected_revision: staleRev })
  check('(3) revisión vieja = delivery_note_changed, sin efectos', stale.status >= 400 && /delivery_note_changed/.test(JSON.stringify(stale.body)) && dnStatus(dn2.id) === 'issued', `${stale.status} ${txt(stale)}`)
  const early = await conv(T.owner, dn2.id, { date: '2000-01-01' })
  check('(3) fecha anterior a la recepción rechazada, sin efectos', early.status >= 400 && /delivery_note_purchase_date_before_receipt/.test(JSON.stringify(early.body)) && dnStatus(dn2.id) === 'issued', `${early.status} ${txt(early)}`)
  const extra = await be(T.owner, 'POST', `/delivery-notes/${dn2.id}/convert-to-purchase`, { expected_revision: dnRev(dn2.id), payment_method_id: pmId('transfer'), supplier_id: sup2, branch_id: brB, items: [line(prodB, 99, 1)], source_delivery_note_id: crypto.randomUUID() }, { 'Idempotency-Key': key() })
  info(`(3) cuerpo con supplier_id / branch_id / items / source_delivery_note_id de más -> ${extra.status} ${txt(extra)}`)
  check('(3) campos de más (proveedor, sucursal, líneas, origen) no cambian la compra: sale del remito', (extra.status >= 400 && dnStatus(dn2.id) === 'issued') || (extra.status === 200 && sql(`select count(*) from purchases where source_delivery_note_id='${dn2.id}' and supplier_id='${sup}' and branch_id='${br1}'`) === '1'), `${extra.status}`)
  if (dnStatus(dn2.id) === 'issued') { /* sigue pendiente para lo que viene */ }
}
{
  // precio 0 -> no convierte
  const z = (await mk(T.owner, [line(harina, 1, 700, { unit_id: kg }), line(sinCosto, 2, 0)])).body
  const x = await conv(T.owner, z.id)
  check('(3) con una línea en precio 0 la conversión se rechaza (delivery_note_price_required), sin efectos', x.status >= 400 && /delivery_note_price_required/.test(JSON.stringify(x.body)) && dnStatus(z.id) === 'issued' && purchaseRows(z.id) === 0, `${x.status} ${txt(x)}`)
  // proveedor dado de baja -> no convierte; revivido, sí
  const sd = (await mk(T.owner, [line(alf, 1, 250)], { supplier_id: sup2 })).body
  sql(`update suppliers set deleted_at = now() where id='${sup2}'`)
  const y = await conv(T.owner, sd.id)
  sql(`update suppliers set deleted_at = null where id='${sup2}'`)
  check('(3) con el proveedor dado de baja la conversión se rechaza (delivery_note_supplier_unavailable)', y.status >= 400 && /delivery_note_supplier_unavailable/.test(JSON.stringify(y.body)) && dnStatus(sd.id) === 'issued', `${y.status} ${txt(y)}`)
  const y2 = await conv(T.owner, sd.id)
  check('(3) control positivo: con el proveedor vigente, convierte', y2.status === 200 && dnStatus(sd.id) === 'converted', `${y2.status}`)
  // sucursal desactivada -> no convierte
  const bd = (await mk(T.owner, [line(alf, 1, 250)], { branch_id: IDS.br2 })).body
  // el guard de vaciado (P0428) impide desactivar una sucursal con stock: se salta SÓLO para armar el escenario
  sql(`set session_replication_role = replica; update branches set is_active = false where id='${IDS.br2}'`)
  const w = await conv(T.owner, bd.id)
  sql(`set session_replication_role = replica; update branches set is_active = true where id='${IDS.br2}'`)
  check('(3) con la sucursal del remito desactivada la conversión se rechaza, sin efectos', w.status >= 400 && dnStatus(bd.id) === 'issued' && purchaseRows(bd.id) === 0, `${w.status} ${txt(w)}`)
}

// ───────────────────────── 3b. recursos AJENOS (otra cuenta): proveedor, sucursal, forma de pago, cuenta bancaria, sesión de caja, centro de costo
{
  const dnCount = () => Number(sql(`select count(*) from delivery_notes where account_id='${accA}'`))
  const n0 = dnCount()
  const fSup = await mk(T.owner, [line(alf, 1, 250)], { supplier_id: supB })
  const fBr = await mk(T.owner, [line(alf, 1, 250)], { branch_id: brB })
  check('(3b) crear un remito de compra con el PROVEEDOR de otra cuenta se rechaza (404/422) y no deja rastro', fSup.status >= 400 && fSup.status !== 500 && dnCount() === n0, `${fSup.status} ${txt(fSup)}`)
  check('(3b) crear un remito de compra con la SUCURSAL de otra cuenta se rechaza (404/422) y no deja rastro', fBr.status >= 400 && fBr.status !== 500 && dnCount() === n0, `${fBr.status} ${txt(fBr)}`)
  const ctl = await mk(T.owner, [line(alf, 1, 250)])
  check('(3b) control positivo: el mismo remito con proveedor y sucursal PROPIOS se recibe (201)', ctl.status === 201, `${ctl.status}`)
  const x = ctl.body
  // recursos de la cuenta B
  const pmB = sql(`select id from payment_methods where account_id='${accB}' order by created_at limit 1`)
  await be(T.b, 'POST', '/bank-accounts', { name: 'Banco de B', bank_name: 'Banco B' })
  const baB = (await be(T.b, 'GET', '/bank-accounts')).body?.[0]?.id
  // la cuenta B tiene que TENER un centro de costo y una sesión de caja abierta: si no, se crean por la API (como el dueño de B)
  let ccB = sql(`select id from cost_centers where account_id='${accB}' order by created_at limit 1`)
  if (!ccB) { await be(T.b, 'POST', '/cost-centers', { name: 'Centro de B' }); ccB = sql(`select id from cost_centers where account_id='${accB}' order by created_at limit 1`) }
  let csB = sql(`select s.id from cash_sessions s join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${accB}' and s.status='open' limit 1`)
  if (!csB) {
    const cb = await be(T.b, 'POST', '/cashboxes', { branch_id: brB, name: 'Caja de B' })
    const cbId = cb.body?.id ?? sql(`select c.id from cashboxes c join branches b on b.id=c.branch_id where b.account_id='${accB}' limit 1`)
    await be(T.b, 'POST', `/cashboxes/${cbId}/sessions/open`, { opening_balance: 100 })
    csB = sql(`select s.id from cash_sessions s join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${accB}' and s.status='open' limit 1`)
  }
  info(`(3b) recursos de B disponibles: forma de pago ${!!pmB}, cuenta bancaria ${!!baB}, centro de costo ${!!ccB}, sesión de caja ${!!csB}`)
  const s3b = snapDb()
  const probe = async (name, body) => {
    const r = await conv(T.owner, x.id, body)
    check(`(3b) convertir con ${name} de OTRA cuenta se rechaza, sin efectos y el remito sigue pendiente`, r.status >= 400 && r.status !== 500 && dnStatus(x.id) === 'issued' && purchaseRows(x.id) === 0 && snapDb() === s3b, `${r.status} ${txt(r)}`)
  }
  if (pmB) await probe('la FORMA DE PAGO', { payment_method_id: pmB })
  if (baB) await probe('la CUENTA BANCARIA', { bank_account_id: baB })
  if (ccB) await probe('el CENTRO DE COSTO', { cost_center_id: ccB })
  if (csB) await probe('la SESIÓN DE CAJA', { payment_method_id: pmId('cash'), cash_session_id: csB })
  const okOwn = await conv(T.owner, x.id)
  check('(3b) control positivo: con los recursos PROPIOS el mismo remito se convierte (200)', okOwn.status === 200 && dnStatus(x.id) === 'converted' && purchaseRows(x.id) === 1, `${okOwn.status} ${txt(okOwn)}`)
}

// ───────────────────────── 4. idempotencia: clave reutilizada y doble conversión
{
  const a = (await mk(T.owner, [line(alf, 1, 250)])).body
  const b = (await mk(T.owner, [line(alf, 1, 250)])).body
  const K = key()
  const r1 = await conv(T.owner, a.id, {}, K)
  const r2 = await conv(T.owner, a.id, {}, K)
  check('(4) la misma clave sobre el MISMO remito = replay (misma compra, replayed:true), sin duplicar', r1.status === 200 && r2.status === 200 && r2.body?.replayed === true && r1.body?.operation_id === r2.body?.operation_id && opsOfDn(a.id) === 1, `${r1.status}/${r2.status} ${txt(r2)}`)
  const sb = snapDb()
  const r3 = await conv(T.owner, b.id, {}, K)
  check('(4) la misma clave sobre OTRO remito = idempotency_key_conflict, el otro remito intacto', r3.status >= 400 && /idempotency_key_conflict/.test(JSON.stringify(r3.body)) && dnStatus(b.id) === 'issued' && purchaseRows(b.id) === 0 && snapDb() === sb, `${r3.status} ${txt(r3)}`)
  const r4 = await conv(T.owner, a.id)
  check('(4) segunda conversión del mismo remito con otra clave = rechazada (delivery_note_invalid_state), una sola compra', r4.status >= 400 && /delivery_note_invalid_state/.test(JSON.stringify(r4.body)) && opsOfDn(a.id) === 1, `${r4.status} ${txt(r4)}`)
  const r5 = await conv(T.owner, b.id, { payment_method_id: pmId('cash'), cash_session_id: crypto.randomUUID() })
  check('(4) control: una sesión de caja inventada se rechaza y no deja rastro', r5.status >= 400 && dnStatus(b.id) === 'issued' && purchaseRows(b.id) === 0, `${r5.status} ${txt(r5)}`)
}

// ───────────────────────── 5. concurrencia: 10 conversiones simultáneas = 1 compra
{
  const c = (await mk(T.owner, [line(harina, 2, 700, { unit_id: kg }), line(alf, 3, 250)])).body
  const before = { h: stockAll(harina), a: stockAll(alf), mov: movTotal(), cash: cashN() }
  const res = await Promise.all(Array.from({ length: 10 }, () => conv(T.owner, c.id, { payment_method_id: pmId('cash'), cash_session_id: sql(`select id from cash_sessions where status='open' and cashbox_id='${cashboxId}' limit 1`) })))
  const ok = res.filter((x) => x.status === 200 && x.body?.replayed === false).length
  const rejected = res.filter((x) => x.status >= 400).length
  check('(5) 10 conversiones concurrentes (10 claves): exactamente 1 gana', ok === 1 && ok + rejected === 10, res.map((x) => x.status).join(','))
  check('(5) una sola compra, un solo remito converted, un solo movimiento de caja, el stock intacto', opsOfDn(c.id) === 1 && purchaseRows(c.id) === 2 && dnStatus(c.id) === 'converted' && cashN() === before.cash + 1 && stockAll(harina) === before.h && stockAll(alf) === before.a && movTotal() === before.mov, `ops ${opsOfDn(c.id)} filas ${purchaseRows(c.id)} caja ${before.cash}->${cashN()}`)
  const d = (await mk(T.owner, [line(alf, 1, 250)])).body
  const K = key()
  const same = await Promise.all(Array.from({ length: 10 }, () => conv(T.owner, d.id, {}, K)))
  const okS = same.filter((x) => x.status === 200)
  check('(5) 10 conversiones concurrentes con la MISMA clave: una compra y el resto son replay o rechazos limpios', opsOfDn(d.id) === 1 && okS.length >= 1 && okS.filter((x) => x.body?.replayed === false).length === 1, same.map((x) => `${x.status}${x.body?.replayed ? 'R' : ''}`).join(','))
  // conversión vs anulación concurrentes: gana una sola, coherente
  const e = (await mk(T.owner, [line(alf, 1, 250)])).body
  const [rc, rx] = await Promise.all([conv(T.owner, e.id), be(T.owner, 'POST', `/delivery-notes/${e.id}/cancel`, { revision: dnRev(e.id), reason: 'carrera red-team' })])
  const st = dnStatus(e.id)
  check('(5) conversión contra anulación concurrentes: gana UNA, el estado es coherente con la compra', (st === 'converted' && purchaseRows(e.id) === 1 && rx.status >= 400) || (st === 'canceled' && purchaseRows(e.id) === 0 && rc.status >= 400), `conv ${rc.status} cancel ${rx.status} estado ${st} filas ${purchaseRows(e.id)}`)
}

// ───────────────────────── 6. edición y borrado de la compra nacida de un remito
{
  const g = (await mk(T.owner, [line(alf, 2, 250), line(aceite, 1, 400)])).body
  const rg = await conv(T.stock, g.id, { payment_method_id: pmId('cash'), cash_session_id: sql(`select id from cash_sessions where status='open' and cashbox_id='${cashboxId}' limit 1`) })
  check('(6) preparación: remito convertido en efectivo con caja', rg.status === 200, `${rg.status} ${txt(rg)}`)
  const opG = opOfDn(g.id), idsG = rowsOfOp(opG)
  const date = new Date().toISOString().slice(0, 10)
  for (const who of ['owner', 'admin', 'stock', 'purchases']) {
    const s = snapDb()
    const upd = await be(T[who], 'PUT', '/purchases/operation', { purchase_ids: idsG, date, description: 'edición indebida', items: [{ product_id: alf, quantity: 5, amount: 250 }] })
    check(`(6) ${who}: editar la compra de un remito se rechaza (delivery_note_purchase_locked) sin efectos`, upd.status >= 400 && /delivery_note_purchase_locked|P0403|Permission/.test(JSON.stringify(upd.body)) && snapDb() === s, `${upd.status} ${txt(upd)}`)
  }
  // compra directa SIN forma de pago (con dinero posteado una compra es inmutable por una regla preexistente, ajena al remito)
  const ctl = await be(T.owner, 'POST', '/purchases', { org_id: accA, items: [{ product_id: aceite, quantity: 1, amount: 100 }], branch_id: br1, supplier_id: sup }, { 'Idempotency-Key': key() })
  const updDirect = await be(T.owner, 'PUT', '/purchases/operation', { purchase_ids: rowsOfOp(ctl.body.operation_id), date, description: 'edición legítima', items: [{ product_id: aceite, quantity: 2, amount: 100 }] })
  check('(6) control positivo: editar una compra DIRECTA sigue funcionando', updDirect.status === 200, `${updDirect.status} ${txt(updDirect)}`)

  // borrado: roles
  for (const who of ['seller', 'cashier', 'stock', 'purchases']) {
    const s = snapDb()
    const del = await be(T[who], 'DELETE', `/purchases?operation_id=${opG}`)
    check(`(6) ${who}: borrar la compra de un remito se rechaza, sin efectos y el remito sigue converted`, del.status >= 400 && snapDb() === s && dnStatus(g.id) === 'converted' && purchaseRows(g.id) === 2, `${del.status} ${txt(del)}`)
  }
  const delB = await be(T.b, 'DELETE', `/purchases?operation_id=${opG}`)
  check('(6) otra cuenta no puede borrar la compra (sin efectos)', purchaseRows(g.id) === 2 && dnStatus(g.id) === 'converted', `${delB.status}`)
  // borrado legítimo + dos borrados concurrentes
  const sBefore = { al: stockAll(alf), ac: stockAll(aceite), mov: movTotal(), cash: cashN() }
  const dels = await Promise.all([be(T.admin, 'DELETE', `/purchases?operation_id=${opG}`), be(T.owner, 'DELETE', `/purchases?operation_id=${opG}`)])
  check('(6) dos borrados concurrentes de la misma compra: el remito se reabre UNA vez y la caja se compensa UNA vez', dnStatus(g.id) === 'issued' && purchaseRows(g.id) === 0 && cashN() === sBefore.cash + 1 && /issued>converted\s+converted>issued$/.test(sql(`select string_agg(coalesce(from_status,'-')||'>'||to_status, ' ' order by occurred_at, id) from document_status_history where document_id='${g.id}'`)), `${dels.map((x) => x.status)} caja ${sBefore.cash}->${cashN()} estado ${dnStatus(g.id)}`)
  check('(6) el borrado NO toca el stock: ni resta ni repone (la mercadería entró con el remito)', stockAll(alf) === sBefore.al && stockAll(aceite) === sBefore.ac && movTotal() === sBefore.mov, `alf ${sBefore.al}->${stockAll(alf)} aceite ${sBefore.ac}->${stockAll(aceite)} mov ${sBefore.mov}->${movTotal()}`)
  // reabierto: se puede anular (el stock recibido sale) y no se puede reconvertir uno anulado
  const rx = await be(T.admin, 'POST', `/delivery-notes/${g.id}/cancel`, { revision: dnRev(g.id), reason: 'red-team' })
  check('(6) el remito reabierto se puede anular (admin) y entonces no se convierte', rx.status === 200 && dnStatus(g.id) === 'canceled', `${rx.status} ${txt(rx)}`)
  const again = await conv(T.owner, g.id)
  check('(6) un remito anulado no se convierte', again.status >= 400 && purchaseRows(g.id) === 0, `${again.status} ${txt(again)}`)
  // fila forjada en stock_movements apuntando a la compra: el borrado no revierte stock
  const h = (await mk(T.owner, [line(alf, 1, 250)])).body
  await conv(T.owner, h.id)
  const opH = opOfDn(h.id)
  const forged = await rest(T.owner, 'POST', 'stock_movements', { account_id: accA, product_id: alf, branch_id: br1, type: 'purchase', quantity_delta: 500, reference_type: 'purchase', reference_id: opH })
  info(`(6) INSERT directo en stock_movements apuntando a la compra por PostgREST -> ${forged.status} ${JSON.stringify(forged.body).slice(0, 100)}`)
  const sAl = stockAll(alf)
  const dh = await be(T.owner, 'DELETE', `/purchases?operation_id=${opH}`)
  check('(6) borrar la compra con un movimiento de stock forjado apuntándola NO revierte stock (el remito manda)', dh.status < 300 && stockAll(alf) === sAl && dnStatus(h.id) === 'issued', `${dh.status} stock ${sAl}->${stockAll(alf)}`)
}

// ───────────────────────── 7. regresión de la compra directa: borrado y edición siguen como antes
{
  const d = await be(T.owner, 'POST', '/purchases', { org_id: accA, items: [{ product_id: harina, quantity: 3, amount: 700, unit_id: kg }], branch_id: br1, supplier_id: sup, payment_method_id: pmId('transfer') }, { 'Idempotency-Key': key() })
  const sBefore = stockAll(harina)
  const del = await be(T.owner, 'DELETE', `/purchases?operation_id=${d.body.operation_id}`)
  check('(7) borrar una compra DIRECTA repone el stock (la regresión no cambió ese camino)', d.status === 201 && del.status < 300 && stockAll(harina) === sBefore - 3, `${sBefore}->${stockAll(harina)}`)
  const sell = await be(T.seller, 'POST', '/purchases', { org_id: accA, items: [{ product_id: alf, quantity: 1, amount: 100 }], branch_id: br1 }, { 'Idempotency-Key': key() })
  info(`(7) control de rol de compra directa: seller -> ${sell.status} (la compra directa exige rol de compras)`)
}

const bad = results.filter(([, ok]) => !ok)
console.log(`\n══ ${results.length - bad.length}/${results.length} PASS`)
process.exit(bad.length ? 1 : 0)
