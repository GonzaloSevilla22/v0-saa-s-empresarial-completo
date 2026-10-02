// Red-team de la tanda B (conversión presupuesto -> venta). Stack LOCAL únicamente.
import { login, USERS, results } from './lib-b.mjs'
import {
  IDS, A, P, KG, CLIENT, stock, cashCount, bankCount, ordersOf, quoteStatus, item, mkQuote, stdItems,
  ensureSession, currentSession, check, sql, be,
} from './fbh.mjs'
import { rest } from './lib-b.mjs'

const API = process.env.SUPABASE_URL
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL
const tokA = await login(...USERS.owner)
const tokS = await login(...USERS.seller)
const tokC = await login(...USERS.cashier)
const tokB = await login(...USERS.b)
const key = () => crypto.randomUUID()
const pmCash = sql(`select id from payment_methods where account_id='${A}' and kind='cash' and is_active limit 1`)
const pmCredit = sql(`select id from payment_methods where account_id='${A}' and kind='credit' and is_active limit 1`)
const pmTransfer = sql(`select id from payment_methods where account_id='${A}' and kind='transfer' and is_active limit 1`)

// ---- recursos del tenant B
const accB = sql("select account_id from account_members where user_id=(select id from auth.users where email='qa.b@local.test') order by created_at limit 1")
const branchB = sql(`select id from branches where account_id='${accB}' limit 1`)
const pmB = sql(`select id from payment_methods where account_id='${accB}' and kind='cash' limit 1`)
const pmBt = sql(`select id from payment_methods where account_id='${accB}' and kind='transfer' limit 1`)
let bankB = ((await be(tokB, 'GET', '/bank-accounts')).body || [])[0]?.id
if (!bankB) { await be(tokB, 'POST', '/bank-accounts', { name: 'Banco de B' }); bankB = ((await be(tokB, 'GET', '/bank-accounts')).body || [])[0]?.id }
let cbB = ((await be(tokB, 'GET', `/branches/${branchB}/cashboxes`)).body || [])[0]?.id
if (!cbB) cbB = (await be(tokB, 'POST', '/cashboxes', { branch_id: branchB, name: 'Caja B' })).body.id
let sesB = (await be(tokB, 'GET', `/cashboxes/${cbB}/current-session`)).body
if (!sesB?.id || sesB.status !== 'open') { await be(tokB, 'POST', `/cashboxes/${cbB}/sessions/open`, { opening_balance: 10 }); sesB = (await be(tokB, 'GET', `/cashboxes/${cbB}/current-session`)).body }
const sesA = await ensureSession(tokA)
// ---- una sucursal 2 de A (si el plan la admite) para el cruce sesión-de-otra-sucursal
let branchA2 = sql(`select id from branches where account_id='${A}' and id<>'${IDS.branchId}' limit 1`)

const conv = (tok, qid, body, k = key(), extra = {}) =>
  be(tok, 'POST', `/quotes/${qid}/convert`, body, k === null ? extra : { 'Idempotency-Key': k, ...extra })
const base = (q, over = {}) => ({ expected_revision: q.revision, payment_method_id: pmCash, cash_session_id: sesA.id, ...over })
const snapshotCounts = () => ({
  h: stock(P.harina), a: stock(P.alf), cash: cashCount(), bank: bankCount(),
  orders: sql(`select count(*) from sales_orders where account_id='${A}'`),
  sales: sql(`select count(*) from sales where account_id='${A}'`),
  events: sql(`select count(*) from events where account_id='${A}'`),
})
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

// 1. ids ajenos por campo
{
  const q = await mkQuote(tokA, stdItems())
  const s0 = snapshotCounts()
  const qB = await mkQuote(tokB, [item(sql(`select id from products where account_id='${accB}' limit 1`), 1, 999)], { send: true }).catch(() => null)
  let r = await conv(tokB, q.id, { expected_revision: q.revision, payment_method_id: pmB })
  check('quote de A convertido por B -> 404', r.status === 404, `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
  r = await conv(tokA, q.id, base(q, { branch_id: branchB }))
  check('sucursal ajena -> 404/422 sin efectos', [404, 422].includes(r.status), `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await conv(tokA, q.id, base(q, { payment_method_id: pmB }))
  check('forma de pago ajena -> 4xx sin efectos', r.status >= 400 && r.status < 500, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await conv(tokA, q.id, { expected_revision: q.revision, payment_method_id: pmTransfer, bank_account_id: bankB })
  check('cuenta bancaria ajena -> 4xx sin efectos', r.status >= 400 && r.status < 500, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await conv(tokA, q.id, base(q, { cash_session_id: sesB.id }))
  check('sesión de caja ajena -> 4xx sin efectos', r.status >= 400 && r.status < 500, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await conv(tokA, q.id, { expected_revision: q.revision, payment_method_id: crypto.randomUUID() })
  check('forma de pago inexistente -> 4xx', r.status >= 400 && r.status < 500, `${r.status}`)
  r = await conv(tokA, q.id, base(q, { cash_session_id: crypto.randomUUID() }))
  check('sesión inexistente -> 4xx', r.status >= 400 && r.status < 500, `${r.status}`)
  r = await conv(tokA, q.id, base(q, { branch_id: crypto.randomUUID() }))
  check('sucursal inexistente -> 4xx', r.status >= 400 && r.status < 500, `${r.status}`)
  check('ningún efecto de los 8 ataques', same(s0, snapshotCounts()) && quoteStatus(q.id) === 'sent' && ordersOf(q.id) === '', JSON.stringify([s0, snapshotCounts()]))
  // efectivo SIN sesión
  r = await conv(tokA, q.id, { expected_revision: q.revision, payment_method_id: pmCash })
  check('efectivo sin sesión de caja -> 4xx (cash_requires_session)', r.status >= 400 && r.status < 500, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  check('  ...sin efectos', same(s0, snapshotCounts()) && quoteStatus(q.id) === 'sent')
  // sucursal 2 de A con la sesión de caja de la sucursal principal
  if (branchA2) {
    r = await conv(tokA, q.id, base(q, { branch_id: branchA2 }))
    check('sesión de OTRA sucursal de la misma cuenta -> 4xx', r.status >= 400 && r.status < 500, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
    check('  ...sin efectos', same(s0, snapshotCounts()))
  } else console.log('INFO  la cuenta A tiene una sola sucursal: cruce sesión/sucursal cubierto por el gate SQL (bloques de P0422)')
  // y el caso feliz después de los ataques sigue funcionando
  r = await conv(tokA, q.id, base(q))
  check('tras los ataques la conversión legítima funciona', r.status === 200 && r.body?.replayed === false, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  // el atacante B no puede LEER la venta
  const so = r.body?.sales_order_id
  const rd = await be(tokB, 'GET', `/sales-orders/${so}`)
  check('B no lee la orden de A', rd.status === 404 || rd.status === 403, String(rd.status))
}

// 2. replay y conflicto de clave por HTTP
{
  const q1 = await mkQuote(tokA, stdItems()); const q2 = await mkQuote(tokA, stdItems())
  const k = key()
  const r1 = await conv(tokA, q1.id, base(q1), k)
  const s1 = snapshotCounts()
  const r2 = await conv(tokA, q1.id, base(q1), k)
  check('replay misma clave+mismo presupuesto -> 200 replayed:true misma venta', r2.status === 200 && r2.body?.replayed === true && r2.body.sales_order_id === r1.body.sales_order_id, `${r2.status} ${JSON.stringify(r2.body).slice(0, 160)}`)
  check('  ...sin escribir', same(s1, snapshotCounts()))
  const r3 = await conv(tokA, q2.id, base(q2), k)
  check('misma clave sobre OTRO presupuesto -> 409 idempotency_key_conflict', r3.status === 409 && /idempotency_key_conflict/.test(JSON.stringify(r3.body)), `${r3.status} ${JSON.stringify(r3.body).slice(0, 160)}`)
  check('  ...q2 intacto', quoteStatus(q2.id) === 'sent' && ordersOf(q2.id) === '')
  const r4 = await be(tokA, 'POST', `/quotes/${q2.id}/convert`, base(q2))
  check('sin Idempotency-Key -> 422', r4.status === 422, `${r4.status} ${JSON.stringify(r4.body).slice(0, 120)}`)
  const r5 = await be(tokA, 'POST', `/quotes/${q2.id}/convert`, { ...base(q2), idempotency_key: key() })
  check('clave en el body (fallback deprecado) sigue andando o se rechaza sin romper', [200, 422].includes(r5.status), String(r5.status))
  if (r5.status === 200) ordersOf(q2.id)
}

// 3. validación de entrada y de estado
{
  const q = await mkQuote(tokA, stdItems())
  const s0 = snapshotCounts()
  let r = await conv(tokA, q.id, { payment_method_id: pmCash, cash_session_id: sesA.id })
  check('sin expected_revision -> 422', r.status === 422, String(r.status))
  r = await conv(tokA, q.id, base(q, { expected_revision: 0 }))
  check('expected_revision 0 -> 422', r.status === 422, String(r.status))
  r = await conv(tokA, q.id, base(q, { expected_revision: q.revision + 7 }))
  check('versión vieja/ajena -> 409 quote_changed', r.status === 409 && /quote_changed/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
  r = await conv(tokA, q.id, base(q, { skip_stock: true, force: true, stock_check: false, unsafe: 1 }))
  check('campos extra tipo skip_stock no cambian nada (200 convierte normal o 422)', [200, 422].includes(r.status), String(r.status))
  check('conversión por HTTP con id no uuid -> 422', (await conv(tokA, 'no-es-uuid', base(q))).status === 422)
  const s1 = snapshotCounts()
  // cajero
  const qc = await mkQuote(tokA, stdItems())
  const rc = await conv(tokC, qc.id, { expected_revision: qc.revision, payment_method_id: pmCash, cash_session_id: sesA.id })
  check('cajero -> 403 insufficient_role', rc.status === 403, `${rc.status} ${JSON.stringify(rc.body).slice(0, 120)}`)
  check('  ...q intacto', quoteStatus(qc.id) === 'sent' && ordersOf(qc.id) === '')
  const rs = await conv(tokS, qc.id, { expected_revision: qc.revision, payment_method_id: pmCash, cash_session_id: sesA.id })
  check('vendedor convierte -> 200', rs.status === 200, `${rs.status} ${JSON.stringify(rs.body).slice(0, 120)}`)
  // estados no convertibles
  const rj = await mkQuote(tokA, stdItems()); await be(tokA, 'POST', `/quotes/${rj.id}/transition`, { action: 'reject', reason: 'x' })
  r = await conv(tokA, rj.id, base(rj))
  check('rechazado -> 409 quote_invalid_state', r.status === 409 && /quote_invalid_state/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 100)}`)
  const done = await conv(tokA, rs.body.quote_id, base({ revision: 1 }))
  check('ya convertido (otra clave) -> 409 quote_invalid_state', done.status === 409, `${done.status} ${JSON.stringify(done.body).slice(0, 100)}`)
  const ex = await mkQuote(tokA, stdItems()); sql(`update quotes set valid_until=current_date-2 where id='${ex.id}'`)
  r = await conv(tokA, ex.id, base(ex))
  check('vencido -> 409 quote_expired', r.status === 409 && /quote_expired/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 100)}`)
  // producto dado de baja / cliente de baja
  const pdel = sql(`insert into products (user_id, account_id, name, sku, cost, price) values ('${IDS.userId}','${A}','Baja QA','QA-BAJA-'||floor(random()*1e6)::int,1,10) returning id`).split('\n')[0]
  sql(`select public.c21_apply_branch_stock_delta('${A}','${pdel}','${IDS.branchId}',5)`)
  const qd = await mkQuote(tokA, [item(pdel, 1, 10)])
  sql(`select public.c21_apply_branch_stock_delta('${A}','${pdel}','${IDS.branchId}',-5)`)
  sql(`update products set deleted_at=now() where id='${pdel}'`)
  const s2 = snapshotCounts()
  r = await conv(tokA, qd.id, base(qd))
  check('producto dado de baja -> 404 quote_product_unavailable', r.status === 404 && /quote_product_unavailable|Baja QA/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  check('  ...sin efectos', same(s2, snapshotCounts()) && quoteStatus(qd.id) === 'sent')
}

// 4. superficie PostgREST (authenticated)
{
  const q = await mkQuote(tokA, stdItems())
  const s0 = snapshotCounts()
  let r = await rest(tokA, 'POST', 'rpc/rpc_accept_quote', { p_quote_id: q.id })
  check('rpc_accept_quote por PostgREST (owner) -> 403/42501 o 404', [401, 403, 404].includes(r.status), `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
  r = await rest(tokA, 'POST', 'rpc/_quote_accept_core', { p_quote_id: q.id, p_branch_id: null })
  check('_quote_accept_core por PostgREST (owner) -> 403/404', [401, 403, 404].includes(r.status), `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
  const anon = await fetch(`${API}/rest/v1/rpc/rpc_convert_quote_to_sale`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_idempotency_key: key(), p_quote_id: q.id, p_expected_revision: 1, p_payment_method_id: pmCash }) })
  check('rpc_convert_quote_to_sale como anon -> 401/403', [401, 403].includes(anon.status), String(anon.status))
  r = await rest(tokC, 'POST', 'rpc/rpc_convert_quote_to_sale', { p_idempotency_key: key(), p_quote_id: q.id, p_expected_revision: q.revision, p_payment_method_id: pmCash, p_cash_session_id: sesA.id })
  check('cajero por PostgREST -> rechazado (P0403)', r.status >= 400 && /P0403|insufficient_role|403/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await rest(tokB, 'POST', 'rpc/rpc_convert_quote_to_sale', { p_idempotency_key: key(), p_quote_id: q.id, p_expected_revision: q.revision, p_payment_method_id: pmB })
  check('tenant B por PostgREST sobre quote de A -> quote_not_found', r.status >= 400 && /quote_not_found|P0404/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await rest(tokA, 'POST', 'rpc/rpc_convert_quote_to_sale', { p_idempotency_key: key(), p_quote_id: q.id, p_expected_revision: null, p_payment_method_id: pmCash, p_cash_session_id: sesA.id })
  check('p_expected_revision NULL -> P0400', r.status >= 400 && /quote_revision_required|P0400/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await rest(tokA, 'POST', 'rpc/rpc_convert_quote_to_sale', { p_idempotency_key: '  ', p_quote_id: q.id, p_expected_revision: q.revision, p_payment_method_id: pmCash, p_cash_session_id: sesA.id })
  check('clave vacía -> P0400', r.status >= 400 && /idempotency_key is required|P0400/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  r = await rest(tokA, 'POST', 'rpc/rpc_convert_quote_to_sale', { p_idempotency_key: key(), p_quote_id: q.id, p_expected_revision: q.revision, p_payment_method_id: pmCash, p_cash_session_id: sesA.id, p_skip_stock: true })
  check('parámetro inexistente p_skip_stock -> rechazado (PGRST202, la firma no admite saltear stock)', r.status === 404 || r.status === 400, `${r.status} ${JSON.stringify(r.body).slice(0, 140)}`)
  const sig = sql("select pg_get_function_arguments('public.rpc_convert_quote_to_sale(text,uuid,integer,uuid,uuid,uuid,uuid,text)'::regprocedure)")
  check('la firma pública no tiene ningún parámetro de stock', !/stock/i.test(sig), sig)
  const acl = sql(`select string_agg(p.proname||':'||coalesce(array_to_string(p.proacl,','),'NULL'),' | ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('_quote_accept_core','rpc_accept_quote','rpc_convert_quote_to_sale')`)
  console.log('INFO ACLs:', acl)
  check('núcleo y aceptación SIN EXECUTE para authenticated/anon', !/_quote_accept_core:[^|]*(authenticated|anon)/.test(acl) && !/rpc_accept_quote:[^|]*(authenticated|anon)/.test(acl))
  check('PostgREST no cambió el estado (todo rechazado)', same(s0, snapshotCounts()) && quoteStatus(q.id) === 'sent' && ordersOf(q.id) === '', JSON.stringify([s0, snapshotCounts()]))
}

// 5. concurrencia: 10 conversiones del MISMO presupuesto
{
  const q = await mkQuote(tokA, stdItems())
  const [h0, a0, c0] = [stock(P.harina), stock(P.alf), cashCount()]
  const rs = await Promise.all(Array.from({ length: 10 }, () => conv(tokA, q.id, base(q))))
  const ok = rs.filter((r) => r.status === 200)
  const codes = rs.map((r) => r.status).sort().join(',')
  check('10 conversiones, claves distintas, mismo presupuesto -> exactamente 1 venta', ok.length === 1 && ordersOf(q.id) === 'confirmed', `${codes} :: ${ordersOf(q.id)}`)
  check('  ...stock bajó UNA vez', stock(P.harina) === h0 - 2 && stock(P.alf) === a0 - 3, `${h0}->${stock(P.harina)} ${a0}->${stock(P.alf)}`)
  check('  ...UN solo movimiento de caja', cashCount() === c0 + 1, `${c0}->${cashCount()}`)
  check('  ...los 9 restantes son 409 quote_invalid_state sin 5xx', rs.filter((r) => r.status !== 200).every((r) => r.status === 409), codes)
  const q2 = await mkQuote(tokA, stdItems()); const k = key(); const c1 = cashCount()
  const rs2 = await Promise.all(Array.from({ length: 10 }, () => conv(tokA, q2.id, base(q2), k)))
  const fresh = rs2.filter((r) => r.status === 200 && r.body?.replayed === false)
  const replays = rs2.filter((r) => r.status === 200 && r.body?.replayed === true)
  check('10 conversiones con la MISMA clave -> 1 nueva + 9 replays, una sola venta', fresh.length === 1 && replays.length === 9 && cashCount() === c1 + 1, `${fresh.length}/${replays.length} ${rs2.map((r) => r.status).join(',')}`)
  // misma clave en dos presupuestos en paralelo
  const qa = await mkQuote(tokA, stdItems()); const qb = await mkQuote(tokA, stdItems()); const kk = key()
  const rr = await Promise.all([conv(tokA, qa.id, base(qa), kk), conv(tokA, qb.id, base(qb), kk)])
  const oks = rr.filter((r) => r.status === 200).length
  const st = [quoteStatus(qa.id), quoteStatus(qb.id)].sort().join(',')
  const huérfanas = sql(`select count(*) from sales_orders where account_id='${A}' and status='draft'`)
  check('misma clave en 2 presupuestos en paralelo -> sólo uno convierte, el otro 409 y revierte', oks === 1 && rr.some((r) => r.status === 409) && st === 'accepted,sent' && huérfanas === '0', `${rr.map((r) => r.status)} ${st} drafts=${huérfanas}`)
}

console.log(`\nRESUMEN RED-TEAM: ${results.filter((r) => r[1]).length} PASS / ${results.filter((r) => !r[1]).length} FAIL`)
process.exit(results.some((r) => !r[1]) ? 1 : 0)
