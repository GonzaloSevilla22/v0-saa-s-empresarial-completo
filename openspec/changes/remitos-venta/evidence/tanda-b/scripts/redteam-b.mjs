// Red-team de la tanda B (conversión remito -> venta, borrado y edición de la venta nacida de un remito).
// GoTrue + PostgREST + FastAPI + Postgres reales (stack LOCAL únicamente). Cada ataque lleva su control positivo.
import { readFileSync } from 'node:fs'
import { API, ANON } from '../../scripts/lib.mjs'
import {
  IDS, A, br1, br2, harina, alf, escaso, client, kg, snap, same, line, stdLines, key, mkDn, convApi, ensureSession, currentSession,
  stockAll, stock, cashCount, nMovs, dnStatus, dnRev, ordersOfDn, liveOrderOfDn, opOfOrder, login, USERS, rest, be, sql, check, results,
} from './hb.mjs'

const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos'
const { accB, brB, clientB, prodB } = JSON.parse(readFileSync(`${SP}/ids.json`, 'utf8'))
const T = {}
for (const [n, cred] of Object.entries(USERS)) T[n] = await login(...cred)
const pm = (kind, acc = A) => sql(`select id from payment_methods where account_id='${acc}' and kind='${kind}' and is_active limit 1`)
const pmCash = pm('cash'); const pmOther = pm('other'); const pmCredit = pm('credit'); const pmTransfer = pm('transfer')
const pmB = pm('other', accB)
const sesA = await ensureSession(T.owner)
// Re-ejecutable: deja el stock de los productos escasos en su valor de siembra.
const resetScarce = () => { sql(`update branch_stock set quantity=5000 where product_id in ('${harina}','${alf}') and branch_id='${br1}'`); sql(`update branch_stock set quantity=1 where product_id='${escaso}' and branch_id='${br1}'`); sql(`update branch_stock set quantity=3 where product_id='${IDS.tres}' and branch_id='${br1}'`) }
resetScarce()
const code = (r) => r.body?.code ?? ''
const txt = (r) => JSON.stringify(r.body ?? {}).slice(0, 220)
const body = (dn, over = {}) => ({ expected_revision: dn.revision, payment_method_id: pmOther, ...over })
const bodyCash = (dn, over = {}) => ({ expected_revision: dn.revision, payment_method_id: pmCash, cash_session_id: sesA.id, ...over })

// remito de B (para los cruces entre cuentas)
const dnB = (await be(T.b, 'POST', '/delivery-notes', { client_id: clientB, branch_id: brB, items: [line(prodB, 1, 999)] }, { 'Idempotency-Key': key() })).body
check('(0) control positivo: B emite su propio remito', !!dnB?.id, JSON.stringify(dnB).slice(0, 100))

// ───────────────────────── 1. superficie PostgREST de la conversión y de las tablas
{
  const dn = await mkDn(T.owner)
  const s0 = snap()
  const rpcBody = (over = {}) => ({ p_idempotency_key: key(), p_delivery_note_id: dn.id, p_expected_revision: dn.revision, p_payment_method_id: pmOther, ...over })
  const anon = await fetch(`${API}/rest/v1/rpc/rpc_convert_delivery_note_to_sale`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify(rpcBody()) })
  check('(1) rpc_convert_delivery_note_to_sale como anon -> 401/403', [401, 403].includes(anon.status), String(anon.status))
  let r = await rest(T.stock, 'POST', 'rpc/rpc_convert_delivery_note_to_sale', rpcBody())
  check('(1) rol stock por PostgREST -> rechazado (P0403 insufficient_role)', r.status >= 400 && /P0403|insufficient_role/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await rest(T.b, 'POST', 'rpc/rpc_convert_delivery_note_to_sale', rpcBody({ p_payment_method_id: pmB }))
  check('(1) tenant B por PostgREST sobre el remito de A -> delivery_note_not_found (P0404)', r.status >= 400 && /delivery_note_not_found|P0404/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await rest(T.owner, 'POST', 'rpc/rpc_convert_delivery_note_to_sale', rpcBody({ p_expected_revision: null }))
  check('(1) p_expected_revision NULL -> P0400 delivery_note_revision_required', r.status >= 400 && /delivery_note_revision_required|P0400/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await rest(T.owner, 'POST', 'rpc/rpc_convert_delivery_note_to_sale', rpcBody({ p_idempotency_key: '  ' }))
  check('(1) clave vacía -> P0400', r.status >= 400 && /idempotency_key is required|P0400/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await rest(T.owner, 'POST', 'rpc/rpc_convert_delivery_note_to_sale', rpcBody({ p_payment_method_id: null }))
  check('(1) sin forma de pago -> P0400 payment_method_required', r.status >= 400 && /payment_method_required|P0400/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await rest(T.owner, 'POST', 'rpc/rpc_convert_delivery_note_to_sale', rpcBody({ p_skip_stock: true }))
  check('(1) parámetro inexistente p_skip_stock -> rechazado (PGRST202): la firma no admite saltear el stock', r.status === 404 || r.status === 400, `${r.status} ${txt(r)}`)
  const sig = sql("select pg_get_function_arguments('public.rpc_convert_delivery_note_to_sale(text,uuid,integer,uuid,uuid,uuid,text)'::regprocedure)")
  const sigCore = sql("select pg_get_function_arguments('public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)'::regprocedure)")
  check('(1) la RPC pública no tiene parámetro de stock/skip y el núcleo ninguno de stock, remito ni skip (la decisión la toma la columna persistida de la orden)', !/stock|skip/i.test(sig) && !/stock|delivery|remito|skip/i.test(sigCore), `${sig} || ${sigCore}`)
  // escritura directa sobre sales_orders
  const ord = sql(`select id from sales_orders where account_id='${A}' order by created_at desc limit 1`) || null
  if (ord) {
    const before = sql(`select coalesce(source_delivery_note_id::text,'NULL') from sales_orders where id='${ord}'`)
    const pr = await rest(T.owner, 'PATCH', `sales_orders?id=eq.${ord}`, { source_delivery_note_id: dn.id })
    check('(1) PATCH directo de sales_orders.source_delivery_note_id sobre una orden existente no tiene efecto (RLS sin política de escritura)', sql(`select coalesce(source_delivery_note_id::text,'NULL') from sales_orders where id='${ord}'`) === before, `${pr.status} antes=${before}`)
  }
  // el escenario peligroso: marcar con origen de remito un BORRADOR sin origen para que se confirme sin descontar stock
  const draft = sql(`insert into sales_orders (account_id, branch_id, client_id, status, total, created_by) values ('${A}','${br1}','${client}','draft',1,'${IDS.userId}') returning id`).split('\n')[0]
  const pd = await rest(T.owner, 'PATCH', `sales_orders?id=eq.${draft}`, { source_delivery_note_id: dn.id })
  check('(1) PATCH directo para marcar un BORRADOR sin origen con un remito no tiene efecto (vector de "confirmar sin descontar stock")', sql(`select coalesce(source_delivery_note_id::text,'NULL') from sales_orders where id='${draft}'`) === 'NULL', `${pd.status} ${JSON.stringify(pd.body).slice(0, 80)}`)
  sql(`delete from sales_orders where id='${draft}'`)
  const n0 = sql(`select count(*) from sales_orders where account_id='${A}'`)
  const ins = await rest(T.owner, 'POST', 'sales_orders', { account_id: A, branch_id: br1, client_id: client, source_delivery_note_id: dn.id, status: 'draft', total: 1 })
  check('(1) INSERT directo de una orden con origen de remito rechazado', ins.status >= 400 && sql(`select count(*) from sales_orders where account_id='${A}'`) === n0, `${ins.status} ${txt(ins)}`)
  const pay = await rest(T.owner, 'POST', 'rpc/_delivery_note_payload', { p_dn_id: dn.id })
  check('(1) _delivery_note_payload no está expuesto a authenticated', pay.status >= 400, `${pay.status}`)
  check('(1) ningún efecto de la superficie PostgREST', same(s0, snap()) && dnStatus(dn.id) === 'issued', JSON.stringify([s0, snap()]))
  // control positivo: la conversión legítima funciona por PostgREST con el rol correcto
  r = await rest(T.seller, 'POST', 'rpc/rpc_convert_delivery_note_to_sale', rpcBody())
  check('(1) control positivo: el vendedor convierte por PostgREST', r.status === 200 && dnStatus(dn.id) === 'converted', `${r.status} ${txt(r)}`)
}

// ───────────────────────── 2. clave reutilizada
{
  const d1 = await mkDn(T.owner); const d2 = await mkDn(T.owner); const k = key()
  const s0 = snap()
  const r1 = await convApi(T.owner, d1.id, body(d1), k)
  const s1 = snap()
  check('(2) control positivo: la primera conversión con la clave responde 200 replayed:false', r1.status === 200 && r1.body?.replayed === false, `${r1.status} ${txt(r1)}`)
  const r2 = await convApi(T.owner, d1.id, body(d1), k)
  check('(2) replay misma clave + mismo remito -> 200 replayed:true, misma orden', r2.status === 200 && r2.body?.replayed === true && r2.body.sales_order_id === r1.body.sales_order_id, `${r2.status} ${txt(r2)}`)
  check('(2) el replay no escribe nada', same(s1, snap()))
  const r3 = await convApi(T.owner, d2.id, body(d2), k)
  check('(2) la MISMA clave sobre OTRO remito -> 409 idempotency_key_conflict', r3.status === 409 && /idempotency_key_conflict/.test(JSON.stringify(r3.body)), `${r3.status} ${txt(r3)}`)
  check('(2) el otro remito queda intacto (issued, sin orden)', dnStatus(d2.id) === 'issued' && ordersOfDn(d2.id) === '')
  check('(2) el conflicto no deja huérfanas ni movimientos', snap().orders === s1.orders && snap().mov === s1.mov && snap().cash === s1.cash, JSON.stringify([s1, snap()]))
  // clave de una EMISIÓN reutilizada para convertir
  const ke = key()
  const em = await be(T.owner, 'POST', '/delivery-notes', { client_id: client, branch_id: br1, items: [line(alf, 1, 500)] }, { 'Idempotency-Key': ke })
  // El ledger de idempotencia es (usuario, operation_kind, clave): la clave de una EMISIÓN vive en otro espacio que la de
  // una CONVERSIÓN (mismo diseño que el presupuesto). Usarla para convertir no es un conflicto ni hace replay de la emisión.
  const dk = await mkDn(T.owner)
  const r4 = await convApi(T.owner, dk.id, body(dk), ke)
  check('(2) la clave de una emisión usada para convertir NO hace replay de la emisión: convierte ESE remito (operation_kind distinto)', r4.status === 200 && r4.body?.replayed === false && r4.body.delivery_note_id === dk.id && dnStatus(dk.id) === 'converted', `${r4.status} ${txt(r4)}`)
  const r5 = await convApi(T.owner, d2.id, body(d2), null)
  check('(2) sin Idempotency-Key -> 422', r5.status === 422, `${r5.status} ${txt(r5)}`)
  const r6 = await be(T.owner, 'POST', `/delivery-notes/${d2.id}/convert`, { ...body(d2), idempotency_key: key() })
  check('(2) clave sólo en el body (fallback deprecado) NO se acepta para la conversión -> 422', r6.status === 422 && dnStatus(d2.id) === 'issued', `${r6.status} ${txt(r6)}`)
  const rok = await convApi(T.owner, d2.id, body(d2))
  check('(2) tras los ataques la conversión legítima funciona', rok.status === 200 && rok.body?.replayed === false, `${rok.status} ${txt(rok)}`)
}

// ───────────────────────── 3. roles, tenencia, validación y estados
{
  const dn = await mkDn(T.owner)
  const s0 = snap()
  let r = await convApi(T.stock, dn.id, body(dn))
  check('(3) rol stock convirtiendo por HTTP -> 403', r.status === 403, `${r.status} ${txt(r)}`)
  r = await convApi(T.b, dn.id, body(dn, { payment_method_id: pmB }))
  check('(3) remito de A convertido por B -> 404', r.status === 404, `${r.status} ${txt(r)}`)
  r = await convApi(T.owner, dnB.id, body(dnB))
  check('(3) remito de B convertido por A -> 404', r.status === 404, `${r.status} ${txt(r)}`)
  r = await convApi(T.owner, dn.id, body(dn, { payment_method_id: pmB }))
  check('(3) forma de pago ajena -> 4xx', r.status >= 400 && r.status < 500, `${r.status} ${txt(r)}`)
  r = await convApi(T.owner, dn.id, body(dn, { payment_method_id: crypto.randomUUID() }))
  check('(3) forma de pago inexistente -> 4xx', r.status >= 400 && r.status < 500, `${r.status}`)
  r = await convApi(T.owner, crypto.randomUUID(), body(dn))
  check('(3) remito inexistente -> 404', r.status === 404, `${r.status}`)
  r = await convApi(T.owner, 'no-es-uuid', body(dn))
  check('(3) id no uuid -> 422', r.status === 422, `${r.status}`)
  r = await convApi(T.owner, dn.id, { payment_method_id: pmOther })
  check('(3) sin expected_revision -> 422', r.status === 422, `${r.status}`)
  r = await convApi(T.owner, dn.id, body(dn, { expected_revision: 0 }))
  check('(3) expected_revision 0 -> 422', r.status === 422, `${r.status}`)
  r = await convApi(T.owner, dn.id, body(dn, { expected_revision: dn.revision + 7 }))
  check('(3) versión vieja/ajena -> 409 delivery_note_changed', r.status === 409 && /delivery_note_changed/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await convApi(T.owner, dn.id, body(dn, { cash_session_id: crypto.randomUUID(), payment_method_id: pmCash }))
  check('(3) efectivo con sesión de caja inexistente -> 4xx', r.status >= 400 && r.status < 500, `${r.status} ${txt(r)}`)
  r = await convApi(T.owner, dn.id, { expected_revision: dn.revision, payment_method_id: pmCash })
  const cur = await currentSession(T.owner)
  check('(3) efectivo SIN sesión de caja -> 4xx (cash_requires_session)', r.status >= 400 && r.status < 500, `${r.status} ${txt(r)} sesión=${!!cur}`)
  r = await convApi(T.owner, dn.id, body(dn, { payment_method_id: pmTransfer, bank_account_id: crypto.randomUUID() }))
  check('(3) cuenta bancaria inexistente -> 4xx', r.status >= 400 && r.status < 500, `${r.status} ${txt(r)}`)
  r = await convApi(T.owner, dn.id, body(dn, { branch_id: br2, skip_stock: true, force: true, stock_check: false }))
  check('(3) campos extra (branch_id, skip_stock, force) se ignoran o se rechazan, nunca se obedecen', [200, 422].includes(r.status), `${r.status}`)
  if (r.status === 200) {
    check('(3)   ...y la venta quedó en la sucursal del remito, con el stock intacto', sql(`select branch_id from sales_orders where id='${r.body.sales_order_id}'`) === br1 && snap().h === s0.h && snap().a === s0.a, sql(`select branch_id from sales_orders where id='${r.body.sales_order_id}'`))
  } else {
    check('(3)   ...sin efectos', same(s0, snap()))
  }
  // estados no convertibles
  const dc = await mkDn(T.owner)
  await be(T.admin, 'POST', `/delivery-notes/${dc.id}/cancel`, { revision: dc.revision, reason: 'prueba de estado' })
  const s2 = snap()
  r = await convApi(T.owner, dc.id, body(dc, { expected_revision: dnRev(dc.id) }))
  check('(3) remito ANULADO -> 409 delivery_note_invalid_state', r.status === 409 && /delivery_note_invalid_state/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await convApi(T.owner, dn.id, body(dn, { expected_revision: dnRev(dn.id) }))
  check('(3) remito ya CONVERTIDO (otra clave) -> 409 delivery_note_invalid_state', r.status === 409, `${r.status} ${txt(r)}`)
  // cliente dado de baja
  const dcl = await mkDn(T.owner, [line(alf, 1, 500)], { client_id: IDS.client2 })
  sql(`update clients set deleted_at=now() where id='${IDS.client2}'`)
  const s3 = snap()
  r = await convApi(T.owner, dcl.id, body(dcl))
  check('(3) cliente dado de baja -> 4xx delivery_note_client_unavailable', r.status >= 400 && r.status < 500 && /client_unavailable|client/i.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  check('(3)   ...sin efectos', same(s3, snap()) && dnStatus(dcl.id) === 'issued')
  sql(`update clients set deleted_at=null where id='${IDS.client2}'`)
  // producto dado de baja DESPUÉS de emitir: convierte igual (la conversión no relee el maestro)
  const dp = await mkDn(T.owner, [line(escaso, 1, 300)])
  sql(`update products set deleted_at=now() where id='${escaso}'`)
  r = await convApi(T.owner, dp.id, body(dp))
  sql(`update products set deleted_at=null where id='${escaso}'`)
  check('(3) producto dado de baja tras emitir: la conversión igual procede (usa los snapshots del remito)', r.status === 200, `${r.status} ${txt(r)}`)
  // roles que sí
  const d3 = await mkDn(T.owner); const d4 = await mkDn(T.owner)
  r = await convApi(T.cashier, d3.id, body(d3))
  check('(3) control positivo: el cajero convierte (forma que no es caja)', r.status === 200, `${r.status} ${txt(r)}`)
  r = await convApi(T.seller, d4.id, body(d4))
  check('(3) control positivo: el vendedor convierte', r.status === 200, `${r.status} ${txt(r)}`)
  const dad = await mkDn(T.owner)
  r = await convApi(T.admin, dad.id, body(dad))
  check('(3) control positivo: el admin convierte', r.status === 200, `${r.status} ${txt(r)}`)
}

// ───────────────────────── 4. órdenes FABRICADAS contra el núcleo (como postgres) y confirmadas por PostgREST
{
  const fab = (dnId, { branch, bump = 0, acc = A, client: cl } = {}) => {
    const o = sql(`insert into sales_orders (account_id, branch_id, client_id, source_delivery_note_id, status, total, created_by)
      select '${acc}', ${branch ? `'${branch}'` : 'dn.branch_id'}, ${cl ? `'${cl}'` : 'dn.client_id'}, dn.id, 'draft', dn.total, '${IDS.userId}'
      from delivery_notes dn where dn.id='${dnId}' returning id`).split('\n')[0]
    sql(`insert into sales_order_items (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal, name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      select '${o}', '${acc}', product_id, unit_id, quantity + ${bump}, price, price * (quantity + ${bump}), name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      from delivery_note_items where delivery_note_id='${dnId}'`)
    return o
  }
  const unfab = (o) => { sql(`delete from sales_order_items where sales_order_id='${o}'`); sql(`delete from sales_orders where id='${o}'`) }
  const core = (tok, order, over = {}) => rest(tok, 'POST', 'rpc/_c29_confirm_order_core', { p_idempotency_key: key(), p_sales_order_id: order, p_payment_method: null, p_payment_method_id: pmOther, ...over })
  const mismatch = (r) => r.status >= 400 && /delivery_note_order_mismatch|P0409|P0404|P0401/.test(JSON.stringify(r.body))

  const dn = await mkDn(T.owner)
  const dnOther = await mkDn(T.owner, [line(alf, 2, 500)])
  const s0 = snap()
  // F1: origen de OTRA cuenta
  let o = fab(dnB.id)
  const sf = snap() // con la orden fabricada ya insertada (borrador)
  let r = await core(T.owner, o)
  check('(4) F1 orden de A con origen un remito de B -> rechazada por el núcleo', mismatch(r), `${r.status} ${txt(r)}`)
  check('(4)   ...sin efectos (stock, caja, ventas)', same(sf, snap()) && dnStatus(dnB.id) === 'issued', JSON.stringify([sf, snap()]))
  unfab(o)
  // F2: origen inexistente -> la FK (NO ACTION) impide fabricarla
  let n0 = sql(`select count(*) from sales_orders`)
  let fk = ''
  try { sql(`insert into sales_orders (account_id, branch_id, source_delivery_note_id, status, total, created_by) values ('${A}','${br1}','${crypto.randomUUID()}','draft',1,'${IDS.userId}')`) } catch (e) { fk = String(e) }
  check('(4) F2 origen inexistente: la FK impide siquiera fabricar la orden (23503)', /23503|foreign key/i.test(fk) && sql(`select count(*) from sales_orders`) === n0, fk.slice(0, 120))
  // F3: remito ya convertido: el índice único parcial impide una 2ª orden viva
  const dcv = await mkDn(T.owner)
  const rc = await convApi(T.owner, dcv.id, body(dcv))
  let dup = ''
  try { fab(dcv.id) } catch (e) { dup = String(e) }
  check('(4) F3 remito ya convertido: el índice único parcial impide fabricar una 2ª orden viva (23505)', rc.status === 200 && /23505|duplicate key|unique/i.test(dup), dup.slice(0, 140))
  // F4: líneas distintas (una unidad de más)
  o = fab(dn.id, { bump: 1 })
  const s4 = snap()
  r = await core(T.owner, o)
  check('(4) F4 líneas distintas a las del remito -> P0409 delivery_note_order_mismatch', r.status >= 400 && /delivery_note_order_mismatch/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  check('(4)   ...sin efectos', same(s4, snap()) && dnStatus(dn.id) === 'issued')
  unfab(o)
  // F5: remito anulado
  const dcan = await mkDn(T.owner)
  await be(T.admin, 'POST', `/delivery-notes/${dcan.id}/cancel`, { revision: dcan.revision, reason: 'prueba F5' })
  const s5 = snap()
  o = fab(dcan.id)
  const s5b = snap()
  r = await core(T.owner, o)
  check('(4) F5 origen = remito ANULADO -> rechazada', mismatch(r), `${r.status} ${txt(r)}`)
  check('(4)   ...sin efectos', same(s5b, snap()))
  unfab(o)
  // F6: sucursal distinta
  const s67 = snap()
  o = fab(dn.id, { branch: br2 })
  r = await core(T.owner, o)
  check('(4) F6 sucursal de la orden distinta de la del remito -> rechazada', mismatch(r), `${r.status} ${txt(r)}`)
  unfab(o)
  // F7: cliente distinto
  o = fab(dn.id, { client: IDS.client2 })
  r = await core(T.owner, o)
  check('(4) F7 cliente de la orden distinto del remito -> rechazada', mismatch(r), `${r.status} ${txt(r)}`)
  unfab(o)
  check('(4)   ...sin efectos tras F6-F7 (las órdenes fabricadas ya retiradas)', same(s67, snap()) && dnStatus(dn.id) === 'issued', JSON.stringify([s67, snap()]))
  // F8: orden de otra cuenta confirmada por B (no es suya)
  o = fab(dn.id)
  r = await core(T.b, o, { p_payment_method_id: pmB })
  check('(4) F8 B no puede confirmar la orden de A por el núcleo', r.status >= 400, `${r.status} ${txt(r)}`)
  unfab(o)
  // control positivo: orden EXACTA -> confirma sin tocar el stock (rama del remito)
  const dok = await mkDn(T.owner)
  const sok = snap()
  o = fab(dok.id)
  r = await core(T.owner, o)
  const sok1 = snap()
  check('(4) control positivo: una orden exacta confirma por el núcleo SIN mover stock (rama de remito)', r.status === 200 && sok1.h === sok.h && sok1.a === sok.a && sok1.mov === sok.mov, `${r.status} ${txt(r)} mov ${sok.mov}->${sok1.mov}`)
  check('(4) control: el núcleo registró la venta (sales +1) pero sin movimientos', Number(sok1.sales) > Number(sok.sales))
}

// ───────────────────────── 5. editar la venta de un remito por la API
{
  const dn = await mkDn(T.owner)
  await convApi(T.owner, dn.id, body(dn))
  const op = opOfOrder(liveOrderOfDn(dn.id))
  const ids = sql(`select string_agg(id::text,',') from sales where operation_id='${op}'`).split(',')
  const s0 = snap()
  const upd = (tok) => be(tok, 'PUT', '/sales/operation', { sale_ids: ids, date: new Date().toISOString().slice(0, 10), client_id: client, currency: 'ARS', items: [{ product_id: alf, quantity: 1, amount: 500 }] })
  let r = await upd(T.owner)
  check('(5) editar la venta de un remito por la API (owner) -> 409 delivery_note_sale_locked', r.status === 409 && /delivery_note_sale_locked/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  r = await upd(T.admin)
  check('(5) ...ni el admin (lo frena la ownership previa o el guard del remito; en ambos casos sin efectos)', [403, 409].includes(r.status) && same(s0, snap()), `${r.status} ${txt(r)}`)
  r = await rest(T.owner, 'POST', 'rpc/rpc_atomic_update_sale_operation', { p_sale_ids: ids, p_client_id: client, p_date: new Date().toISOString().slice(0, 10), p_currency: 'ARS', p_items: [{ product_id: alf, quantity: 1, amount: 500 }] })
  check('(5) tampoco por PostgREST directo -> P0423', r.status >= 400 && /delivery_note_sale_locked|P0423/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  check('(5) sin efectos', same(s0, snap()))
  // control positivo: una venta normal (POS-like por API) sí se edita
  const sale = await be(T.owner, 'POST', '/sales', { org_id: A, client_id: client, date: new Date().toISOString().slice(0, 10), currency: 'ARS', items: [{ product_id: alf, quantity: 1, amount: 500 }] }, { 'Idempotency-Key': key() })
  if (sale.status === 201) {
    const sids = sql(`select string_agg(id::text,',') from sales where operation_id='${sale.body.operation_id}'`).split(',')
    const e2 = await be(T.owner, 'PUT', '/sales/operation', { sale_ids: sids, date: new Date().toISOString().slice(0, 10), client_id: client, currency: 'ARS', items: [{ product_id: alf, quantity: 2, amount: 1000 }] })
    check('(5) control positivo: una venta normal SÍ se edita', e2.status === 200, `${e2.status} ${txt(e2)}`)
  } else check('(5) control positivo: se pudo crear una venta normal', false, `${sale.status} ${txt(sale)}`)
}

// ───────────────────────── 6. borrar la venta de un remito con la sucursal del remito desactivada
{
  sql(`update branch_stock set quantity=10 where branch_id='${br2}' and product_id='${alf}'`)
  const d = await mkDn(T.owner, [line(alf, 2, 500)], { branch_id: br2 })
  const rc = await convApi(T.owner, d.id, body(d))
  check('(6) setup: remito en la sucursal 2 emitido y convertido', rc.status === 200, `${rc.status} ${txt(rc)}`)
  const op = opOfOrder(liveOrderOfDn(d.id))
  // re-ejecutable: se anulan los remitos pendientes que hayan quedado en la sucursal 2 (P0428 los cuenta)
  for (const id of sql(`select id from delivery_notes where branch_id='${br2}' and status='issued'`).split('\n').filter(Boolean)) await be(T.admin, 'POST', `/delivery-notes/${id}/cancel`, { revision: dnRev(id), reason: 'limpieza de la corrida' })
  sql(`update branch_stock set quantity=0 where branch_id='${br2}'`)
  sql(`update branches set is_active=false where id='${br2}'`)
  const s0 = snap()
  const r = await be(T.owner, 'DELETE', `/sales?operation_id=${op}`)
  check('(6) borrar con la sucursal del remito desactivada -> 4xx P0422 delivery_note_branch_inactive', r.status >= 400 && r.status < 500 && /delivery_note_branch_inactive|P0422/.test(JSON.stringify(r.body)), `${r.status} ${txt(r)}`)
  check('(6) cero efectos: remito sigue converted, orden viva, stock y caja iguales', dnStatus(d.id) === 'converted' && liveOrderOfDn(d.id) !== '' && same(s0, snap()), JSON.stringify([s0, snap()]))
  sql(`update branches set is_active=true where id='${br2}'`)
  const r2 = await be(T.owner, 'DELETE', `/sales?operation_id=${op}`)
  const s1 = snap()
  check('(6) control positivo: reactivada la sucursal, el borrado procede y el remito vuelve a issued', r2.status === 204 && dnStatus(d.id) === 'issued', `${r2.status} ${dnStatus(d.id)}`)
  check('(6)   ...sin tocar el stock (los movimientos no cambian)', s1.mov === s0.mov && s1.h === s0.h && s1.a === s0.a, `${s0.mov}->${s1.mov}`)
  sql(`update branch_stock set quantity=10 where branch_id='${br2}' and product_id='${alf}'`)
}

// ───────────────────────── 7. concurrencia
{
  const dn = await mkDn(T.owner)
  const s0 = snap()
  const rs = await Promise.all(Array.from({ length: 10 }, () => convApi(T.owner, dn.id, bodyCash(dn))))
  const ok = rs.filter((r) => r.status === 200)
  const codes = rs.map((r) => r.status).sort().join(',')
  const s1 = snap()
  check('(7) 10 conversiones concurrentes (claves distintas) del MISMO remito -> exactamente 1 venta', ok.length === 1 && ordersOfDn(dn.id) === 'confirmed' && dnStatus(dn.id) === 'converted', `${codes} :: ${ordersOfDn(dn.id)}`)
  check('(7)   ...los otros 9 son 409 sin 5xx', rs.filter((r) => r.status !== 200).every((r) => r.status === 409), codes)
  check('(7)   ...el stock NO cambió y hay UN solo movimiento de caja', s1.h === s0.h && s1.a === s0.a && s1.mov === s0.mov && s1.cash === s0.cash + 1, `cash ${s0.cash}->${s1.cash} mov ${s0.mov}->${s1.mov}`)
  const d2 = await mkDn(T.owner); const k = key(); const c0 = cashCount()
  const rs2 = await Promise.all(Array.from({ length: 10 }, () => convApi(T.owner, d2.id, bodyCash(d2), k)))
  const fresh = rs2.filter((r) => r.status === 200 && r.body?.replayed === false)
  const replays = rs2.filter((r) => r.status === 200 && r.body?.replayed === true)
  check('(7) 10 conversiones con la MISMA clave -> 1 nueva + 9 replays, una sola venta y un solo movimiento de caja', fresh.length === 1 && replays.length === 9 && cashCount() === c0 + 1, `${fresh.length}/${replays.length} ${rs2.map((r) => r.status).join(',')}`)
  const da = await mkDn(T.owner); const db = await mkDn(T.owner); const kk = key()
  const rr = await Promise.all([convApi(T.owner, da.id, body(da), kk), convApi(T.owner, db.id, body(db), kk)])
  const st = [dnStatus(da.id), dnStatus(db.id)].sort().join(',')
  const drafts = sql(`select count(*) from sales_orders where account_id='${A}' and status='draft'`)
  check('(7) misma clave sobre 2 remitos en paralelo -> sólo uno convierte, el otro 409 y revierte sin dejar borradores', rr.filter((r) => r.status === 200).length === 1 && rr.some((r) => r.status === 409) && st === 'converted,issued' && drafts === '0', `${rr.map((r) => r.status)} ${st} drafts=${drafts}`)
  // conversión vs anulación del mismo remito en paralelo
  const dx = await mkDn(T.owner)
  const [cx, ax] = await Promise.all([
    convApi(T.owner, dx.id, body(dx)),
    be(T.admin, 'POST', `/delivery-notes/${dx.id}/cancel`, { revision: dx.revision, reason: 'carrera contra la conversión' }),
  ])
  const stx = dnStatus(dx.id)
  check('(7) conversión vs anulación en paralelo: gana exactamente una y el estado es coherente', [cx.status, ax.status].filter((s) => s === 200).length === 1 && ((stx === 'converted' && ordersOfDn(dx.id) === 'confirmed') || (stx === 'canceled' && ordersOfDn(dx.id) === '')), `${cx.status}/${ax.status} ${stx} ${ordersOfDn(dx.id)}`)
}

resetScarce()
// ───────────────────────── 8. fila forjada en stock_movements: no se revierte por rpc_reverse_stock_movement
{
  const dn = await mkDn(T.owner, [line(escaso, 1, 300)])
  const forge = await rest(T.owner, 'POST', 'stock_movements', { account_id: A, product_id: escaso, type: 'sale', quantity_delta: -1000, reference_id: dn.id, reference_type: 'delivery_note', branch_id: br1 })
  check('(8) control: la fila forjada entra por PostgREST (política preexistente)', forge.status < 300, `${forge.status}`)
  await convApi(T.owner, dn.id, body(dn))
  const se0 = stock(escaso, br1)
  const rv = await rest(T.owner, 'POST', 'rpc/rpc_reverse_stock_movement', { p_reference_id: dn.id, p_reference_type: 'delivery_note', p_reason: 'intento' })
  check('(8) rpc_reverse_stock_movement NO acepta reference_type delivery_note: el stock no se mueve', rv.status >= 400 && stock(escaso, br1) === se0, `${rv.status} ${txt(rv)} stock ${se0}->${stock(escaso, br1)}`)
  // y borrar la venta (que no revierte stock) tampoco consume la fila forjada
  const op = opOfOrder(liveOrderOfDn(dn.id))
  const del = await be(T.owner, 'DELETE', `/sales?operation_id=${op}`)
  check('(8) borrar la venta del remito con la fila forjada presente no repone stock', del.status === 204 && stock(escaso, br1) === se0, `${del.status} stock ${se0}->${stock(escaso, br1)}`)
  // control positivo preexistente: una fila forjada reference_type='sale' SÍ se revierte hoy
  const refS = crypto.randomUUID()
  const f2 = await rest(T.owner, 'POST', 'stock_movements', { account_id: A, product_id: escaso, type: 'sale', quantity_delta: -1, reference_id: refS, reference_type: 'sale', branch_id: br1 })
  const sf0 = stock(escaso, br1)
  const rv2 = await rest(T.owner, 'POST', 'rpc/rpc_reverse_stock_movement', { p_reference_id: refS, p_reference_type: 'sale', p_reason: 'control positivo' })
  check('(8) control positivo preexistente: reference_type=sale forjada SÍ se revierte (candidato 9.1)', f2.status < 300 && rv2.status < 300 && stock(escaso, br1) === sf0 + 1, `forja ${f2.status} rpc ${rv2.status} stock ${sf0}->${stock(escaso, br1)}`)
}

const failed = results.filter(([, ok]) => !ok)
console.log(`\nRESUMEN RED-TEAM B: ${results.length - failed.length}/${results.length} PASS`)
if (failed.length) { console.log('FALLAN:', failed.map(([n]) => n).join(' | ')); process.exit(1) }
