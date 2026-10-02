// Red-team tanda A — presupuestos (stack LOCAL). Imprime PASS/FAIL por ítem.
import { spawnSync } from 'node:child_process'
const API = process.env.SUPABASE_URL
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY
const BE = 'http://127.0.0.1:8000'
if (!new URL(API).hostname.match(/^(localhost|127\.0\.0\.1)$/)) throw new Error('no local')

const results = []
const check = (name, ok, detail = '') => { results.push([name, ok]); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  -> ' + detail : ''}`) }

async function login(email, password) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }) })
  const j = await r.json(); if (!j.access_token) throw new Error('login ' + email + ' ' + r.status)
  return j.access_token
}
const sql = (q) => { const r = spawnSync('docker', ['exec', '-i', 'supabase_db_v0-saa-s-empresarial-completo', 'psql', '-X', '-tA', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-c', q], { encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout.trim() }
const be = async (tok, method, path, body, headers = {}) => {
  const r = await fetch(BE + path, { method, headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json', ...headers }, body: body ? JSON.stringify(body) : undefined })
  let j = null; const ct = r.headers.get('content-type') || ''
  if (ct.includes('json')) j = await r.json().catch(() => null)
  return { status: r.status, body: j, ct, r }
}
const rest = async (tok, method, path, body) => {
  const r = await fetch(`${API}/rest/v1/${path}`, { method, headers: { apikey: ANON, Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json', Prefer: 'return=representation' }, body: body ? JSON.stringify(body) : undefined })
  const t = await r.text(); let j; try { j = JSON.parse(t) } catch { j = t }
  return { status: r.status, body: j }
}

const A = await login('qa.e2e@local.test', process.env.RT_PASS_OWNER)
const SELL = await login('qa.seller@local.test', process.env.RT_PASS_SELLER)
const CASH = await login('qa.cashier@local.test', process.env.RT_PASS_CASHIER)
const B = await login('qa.b@local.test', process.env.RT_PASS_TENANT_B)

const accA = sql("select account_id from account_members where user_id=(select id from auth.users where email='qa.e2e@local.test') order by created_at limit 1")
const clientA = sql(`select id from clients where account_id='${accA}' and name='Cliente Demo QA'`)
const p1 = sql(`select id from products where account_id='${accA}' and sku='QA-HARINA'`)
const p2 = sql(`select id from products where account_id='${accA}' and sku='QA-ALF'`)
const kg = sql(`select id from units_of_measure where account_id='${accA}' and symbol='kg'`)
const prodB = sql("select id from products where sku='QA-B-SECRETO'")
const clientB = sql("select id from clients where name='Cliente de B'")
const item = (pid, q = 2, price = 1200, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })
const today = new Date(); today.setDate(today.getDate() + 10)
const valid = today.toISOString().slice(0, 10)

// --- Base: A crea un presupuesto
const c1 = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [item(p1, 2, 1200, { unit_id: kg }), item(p2, 3, 500)] })
check('A crea presupuesto (201, P-00000001)', c1.status === 201 && c1.body?.number_label === 'P-00000001', `${c1.status} ${c1.body?.number_label}`)
const qid = c1.body?.id
// B crea el suyo
const cb = await be(B, 'POST', '/quotes', { client_id: clientB, valid_until: valid, items: [{ product_id: prodB, quantity: 1, price: 999, subtotal: 999 }] })
check('B crea su presupuesto (201)', cb.status === 201, String(cb.status))
const qidB = cb.body?.id

// 1) escritura directa PostgREST con authenticated
let r = await rest(A, 'POST', 'quotes', { account_id: accA, client_id: clientA, status: 'draft', total: 1, valid_until: valid, created_by: '00000000-0000-0000-0000-000000000001' })
check('PostgREST INSERT quotes como authenticated rechazado', r.status >= 400 && /42501|permission|row-level/i.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
r = await rest(A, 'PATCH', `quotes?id=eq.${qid}`, { total: 1, status: 'accepted' })
check('PostgREST UPDATE quotes como authenticated rechazado', r.status >= 400, `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
r = await rest(A, 'DELETE', `quotes?id=eq.${qid}`)
check('PostgREST DELETE quotes como authenticated rechazado', r.status >= 400, `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
r = await rest(A, 'POST', 'quote_items', { quote_id: qid, account_id: accA, product_id: p1, quantity: 1, price: 1, subtotal: 1 })
check('PostgREST INSERT quote_items rechazado', r.status >= 400, `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
r = await rest(A, 'PATCH', `quote_items?quote_id=eq.${qid}`, { price: 1, subtotal: 1 })
check('PostgREST UPDATE quote_items rechazado', r.status >= 400, `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
r = await rest(A, 'DELETE', `quote_items?quote_id=eq.${qid}`)
check('PostgREST DELETE quote_items rechazado', r.status >= 400, `${r.status} ${JSON.stringify(r.body).slice(0, 120)}`)
const afterTotal = sql(`select total from quotes where id='${qid}'`)
check('el presupuesto quedó intacto tras los intentos directos', Number(afterTotal) === 3900, afterTotal)
// escritura directa con anon
r = await rest(ANON, 'POST', 'quotes', { account_id: accA })
check('PostgREST INSERT quotes como anon rechazado', r.status >= 400, String(r.status))
// lectura propia sigue permitida (RLS SELECT)
r = await rest(A, 'GET', `quotes?id=eq.${qid}&select=id,number`)
check('PostgREST SELECT propio sigue funcionando', r.status === 200 && r.body?.length === 1, `${r.status}`)
r = await rest(A, 'GET', `quotes?id=eq.${qidB}&select=id`)
check('PostgREST SELECT del presupuesto de B por A -> 0 filas', r.status === 200 && r.body?.length === 0, `${r.status} ${JSON.stringify(r.body)}`)
// RPC directa de B por A
r = await rest(A, 'POST', 'rpc/rpc_delete_quote', { p_quote_id: qidB })
check('rpc_delete_quote del presupuesto de B por A -> error P0404', r.status >= 400 && /quote_not_found|P0404/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 100)}`)
r = await rest(A, 'POST', 'rpc/_next_internal_document_number', { p_account_id: accA, p_document_type: 'quote' })
check('_next_internal_document_number no ejecutable por authenticated', r.status >= 400, `${r.status}`)
r = await rest(A, 'POST', 'rpc/_expire_overdue_quotes', {})
check('_expire_overdue_quotes no ejecutable por authenticated', r.status >= 400, `${r.status}`)

// 2) presupuesto de otra cuenta por id -> 404 en todos los endpoints
for (const [m, p, b] of [['GET', `/quotes/${qidB}`], ['PUT', `/quotes/${qidB}`, { revision: 1, client_id: clientA, branch_id: null, valid_until: valid, notes: null, items: [item(p1)] }], ['DELETE', `/quotes/${qidB}`], ['POST', `/quotes/${qidB}/transition`, { action: 'send' }], ['GET', `/quotes/${qidB}/pdf`]]) {
  r = await be(A, m, p, b)
  check(`${m} ${p.replace(qidB, '<B>')} de otra cuenta -> 404`, r.status === 404, String(r.status))
}
// listado no filtra por cuenta ajena
r = await be(A, 'GET', '/quotes?page_size=100')
check('listado de A no incluye el de B', r.status === 200 && !JSON.stringify(r.body).includes(qidB), `${r.status}`)
// B no ve el de A
r = await be(B, 'GET', `/quotes/${qid}`)
check('B no ve el presupuesto de A (404)', r.status === 404, String(r.status))

// 3) producto ajeno / cliente ajeno en alta y edición
r = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [item(prodB)] })
check('alta con producto de otra cuenta -> 404 product_not_found', r.status === 404 && /product_not_found/.test(JSON.stringify(r.body)), `${r.status} ${r.body?.code}`)
r = await be(A, 'POST', '/quotes', { client_id: clientB, valid_until: valid, items: [item(p1)] })
check('alta con cliente de otra cuenta -> 404 client_not_found', r.status === 404 && /client_not_found/.test(JSON.stringify(r.body)), `${r.status} ${r.body?.code}`)
r = await be(A, 'PUT', `/quotes/${qid}`, { revision: 1, client_id: clientA, branch_id: null, valid_until: valid, notes: null, items: [item(prodB)] })
check('edición con producto ajeno -> 404 y no altera', r.status === 404, `${r.status}`)
const nm = sql(`select count(*) from quote_items where quote_id='${qid}' and name_snapshot ilike '%SECRETO%'`)
check('ningún snapshot ajeno quedó en la base', nm === '0', nm)
r = await be(A, 'GET', `/quotes/${qid}`)
check('el presupuesto conserva 2 líneas y revision 1 tras el intento fallido', r.body?.items?.length === 2 && r.body?.revision === 1, `${r.body?.items?.length} rev ${r.body?.revision}`)

// 4) quote_changed (versión vieja)
r = await be(A, 'PUT', `/quotes/${qid}`, { revision: 1, client_id: clientA, branch_id: null, valid_until: valid, notes: 'v2', items: [item(p1, 1), item(p2, 1, 500)] })
check('edición válida con revision 1 -> 200 y revision 2', r.status === 200 && r.body?.revision === 2, `${r.status} rev ${r.body?.revision}`)
r = await be(A, 'PUT', `/quotes/${qid}`, { revision: 1, client_id: clientA, branch_id: null, valid_until: valid, notes: 'viejo', items: [item(p1, 9)] })
check('edición con versión vieja -> 409 quote_changed', r.status === 409 && r.body?.code === 'quote_changed', `${r.status} ${r.body?.code}`)
r = await be(A, 'GET', `/quotes/${qid}`)
check('quote_changed no escribió nada (notas v2, rev 2)', r.body?.notes === 'v2' && r.body?.revision === 2, `${r.body?.notes} ${r.body?.revision}`)

// 5) doble transición / transiciones inválidas
r = await be(A, 'POST', `/quotes/${qid}/transition`, { action: 'send' })
check('send desde draft -> 200 sent', r.status === 200 && r.body?.status === 'sent', `${r.status} ${r.body?.status}`)
const hist1 = (await be(A, 'GET', `/quotes/${qid}`)).body?.history?.length
r = await be(A, 'POST', `/quotes/${qid}/transition`, { action: 'send' })
const hist2 = (await be(A, 'GET', `/quotes/${qid}`)).body?.history?.length
check('doble send idempotente (200, sin historial duplicado)', r.status === 200 && hist1 === hist2, `${r.status} hist ${hist1}->${hist2}`)
r = await be(A, 'POST', `/quotes/${qid}/transition`, { action: 'reject', reason: 'caro' })
check('reject desde sent -> 200 rejected', r.status === 200 && r.body?.status === 'rejected', `${r.status} ${r.body?.status}`)
r = await be(A, 'POST', `/quotes/${qid}/transition`, { action: 'reject', reason: 'otra vez' })
check('doble reject -> 409 quote_invalid_state', r.status === 409 && r.body?.code === 'quote_invalid_state', `${r.status} ${r.body?.code}`)
r = await be(A, 'POST', `/quotes/${qid}/transition`, { action: 'send' })
check('send desde rejected -> 409 quote_invalid_state', r.status === 409 && r.body?.code === 'quote_invalid_state', `${r.status} ${r.body?.code}`)
r = await be(A, 'POST', `/quotes/${qid}/transition`, { action: 'accepted' })
check('transition accepted pedido por la API -> 422', r.status === 422, String(r.status))
// reapertura editando
r = await be(A, 'PUT', `/quotes/${qid}`, { revision: 2, client_id: clientA, branch_id: null, valid_until: valid, notes: 'reabierto', items: [item(p1, 1)] })
check('editar un rejected lo reabre como draft', r.status === 200 && r.body?.status === 'draft', `${r.status} ${r.body?.status}`)
// delete: sólo borrador que nunca se envió (este fue enviado)
r = await be(A, 'DELETE', `/quotes/${qid}`)
check('eliminar un presupuesto que fue enviado -> 409 quote_not_deletable', r.status === 409 && r.body?.code === 'quote_not_deletable', `${r.status} ${r.body?.code}`)

// 6) edición en accepted -> P0423
const cq = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [item(p2, 1, 500)] })
const qacc = cq.body?.id
sql(`update quotes set status='accepted' where id='${qacc}'`)
r = await be(A, 'PUT', `/quotes/${qacc}`, { revision: cq.body.revision, client_id: clientA, branch_id: null, valid_until: valid, notes: null, items: [item(p2, 5, 500)] })
check('editar un accepted -> 409 quote_locked_converted (P0423)', r.status === 409 && r.body?.code === 'quote_locked_converted', `${r.status} ${r.body?.code}`)
r = await be(A, 'POST', `/quotes/${qacc}/transition`, { action: 'reject' })
check('rechazar un accepted -> 409', r.status === 409, String(r.status))
r = await be(A, 'DELETE', `/quotes/${qacc}`)
check('eliminar un accepted -> 409 quote_not_deletable', r.status === 409, String(r.status))
r = await be(A, 'POST', `/quotes/${qacc}/accept`, {})
check('POST /quotes/{id}/accept retirado (404/405)', [404, 405].includes(r.status), String(r.status))

// 7) PDF: propio OK, vendedor no dueño ve emisor completo, cashier descarga sin cambiar estado
r = await be(A, 'GET', `/quotes/${qid}/pdf`)
check('PDF propio -> 200 application/pdf', r.status === 200 && r.ct.includes('pdf'), `${r.status} ${r.ct}`)
const pdfSeller = await be(SELL, 'GET', `/quotes/${qid}/pdf`)
check('PDF por un vendedor que no es el dueño -> 200', pdfSeller.status === 200 && pdfSeller.ct.includes('pdf'), `${pdfSeller.status}`)
const pdfCash = await be(CASH, 'GET', `/quotes/${qid}/pdf`)
check('PDF por un cajero -> 200 (leer es de cualquier miembro)', pdfCash.status === 200, `${pdfCash.status}`)

// 8) cashier contra cada endpoint de escritura
for (const [m, p, b, label] of [
  ['POST', '/quotes', { client_id: clientA, valid_until: valid, items: [item(p1)] }, 'crear'],
  ['PUT', `/quotes/${qid}`, { revision: 3, client_id: clientA, branch_id: null, valid_until: valid, notes: null, items: [item(p1)] }, 'editar'],
  ['POST', `/quotes/${qid}/transition`, { action: 'send' }, 'transition'],
  ['DELETE', `/quotes/${qid}`, undefined, 'eliminar'],
  ['PATCH', '/settings/quotes', { default_quote_validity_days: 30 }, 'validez por defecto'],
]) {
  r = await be(CASH, m, p, b)
  check(`cashier ${label} -> 403 insufficient_role`, r.status === 403 && r.body?.code === 'insufficient_role', `${r.status} ${r.body?.code}`)
}
r = await be(CASH, 'GET', '/quotes')
check('cashier listar -> 200', r.status === 200, String(r.status))
r = await be(CASH, 'GET', `/quotes/${qid}`)
check('cashier detalle -> 200', r.status === 200, String(r.status))
// cashier directo por RPC (PostgREST)
r = await rest(CASH, 'POST', 'rpc/rpc_create_quote', { p_client_id: clientA, p_branch_id: null, p_valid_until: valid, p_notes: null, p_items: [{ product_id: p1, quantity: 1, price: 1, subtotal: 1 }] })
check('cashier rpc_create_quote directa -> rechazada (insufficient_role)', r.status >= 400 && /insufficient_role/.test(JSON.stringify(r.body)), `${r.status} ${JSON.stringify(r.body).slice(0, 90)}`)
// seller no configura validez
r = await be(SELL, 'PATCH', '/settings/quotes', { default_quote_validity_days: 30 })
check('seller validez por defecto -> 403', r.status === 403, String(r.status))
r = await be(A, 'PATCH', '/settings/quotes', { default_quote_validity_days: 0 })
check('owner validez 0 -> 422', r.status === 422, String(r.status))
r = await be(A, 'PATCH', '/settings/quotes', { default_quote_validity_days: 366 })
check('owner validez 366 -> 422', r.status === 422, String(r.status))
r = await be(A, 'PATCH', '/settings/quotes', { default_quote_validity_days: 30 })
check('owner validez 30 -> 200', r.status === 200, String(r.status))
// seller puede crear
r = await be(SELL, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [item(p1)] })
check('seller crear -> 201', r.status === 201, String(r.status))

// 9) numeración concurrente vía HTTP (15 altas a la vez)
const N = 15
const before = Number(sql(`select coalesce(max(number),0) from quotes where account_id='${accA}'`))
const rs = await Promise.all(Array.from({ length: N }, () => be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [item(p2, 1, 500)] })))
const nums = rs.map((x) => x.body?.number).filter(Boolean).sort((a, b) => a - b)
const okAll = rs.every((x) => x.status === 201)
const distinct = new Set(nums).size === N
const contiguous = nums.every((n, i) => n === before + 1 + i)
check(`numeración concurrente HTTP (${N}): todas 201, distintas y correlativas`, okAll && distinct && contiguous, `${nums.join(',')}`)
// idempotencia de Idempotency-Key no aplica; unicidad a nivel DB
const dups = sql(`select count(*) from (select number from quotes where account_id='${accA}' group by number having count(*)>1) t`)
check('sin números duplicados en la cuenta', dups === '0', dups)

// 10) fuzz de inputs
r = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: '2020-01-01', items: [item(p1)] })
check('validez en el pasado -> 400 quote_valid_until_in_past', r.status === 400 && r.body?.code === 'quote_valid_until_in_past', `${r.status} ${r.body?.code}`)
r = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [] })
check('sin líneas -> 422', r.status === 422, String(r.status))
r = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [{ quantity: 1, price: 1, subtotal: 1 }] })
check('línea de servicio sin descripción -> 422', r.status === 422, String(r.status))
r = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, notes: 'x'.repeat(2001), items: [item(p1)] })
check('notas > 2000 -> 422', r.status === 422, String(r.status))
r = await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [{ description: "<script>alert(1)</script>'; DROP TABLE quotes;--", quantity: 1, price: 10, subtotal: 10 }] })
check('línea de servicio con texto hostil se guarda como dato (201)', r.status === 201 && r.body?.items?.[0]?.name_snapshot?.includes('<script>'), `${r.status}`)
const tbl = sql("select to_regclass('public.quotes') is not null")
check('la tabla quotes sigue existiendo', tbl === 't', tbl)
if (r.body?.id) { const pdf = await be(A, 'GET', `/quotes/${r.body.id}/pdf`); check('PDF con texto hostil se genera (200)', pdf.status === 200, String(pdf.status)) }
r = await be(A, 'GET', `/quotes/not-a-uuid`)
check('id inválido -> 422 (no 500)', r.status === 422, String(r.status))
r = await be(null ?? 'bad.token.here', 'GET', '/quotes')
check('token inválido -> 401', r.status === 401, String(r.status))
const noauth = await fetch(BE + '/quotes'); check('sin token -> 401/403', [401, 403].includes(noauth.status), String(noauth.status))

const bad = results.filter(([, ok]) => !ok)
console.log(`\nTOTAL ${results.length}  FAIL ${bad.length}`)
process.exit(bad.length ? 1 : 0)
