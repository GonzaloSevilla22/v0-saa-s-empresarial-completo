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


const mk = async () => (await be(A, 'POST', '/quotes', { client_id: clientA, valid_until: valid, items: [item(p2, 1, 500)] })).body
// concurrente: 6 ediciones con la MISMA revision -> exactamente 1 gana, las demas quote_changed
let q = await mk()
let rs = await Promise.all(Array.from({length:6}, (_, i) => be(A, 'PUT', `/quotes/${q.id}`, { revision: q.revision, client_id: clientA, branch_id: null, valid_until: valid, notes: 'e'+i, items: [item(p2, i+1, 500)] })))
let ok = rs.filter(x=>x.status===200).length, ch = rs.filter(x=>x.status===409 && x.body?.code==='quote_changed').length
check('6 ediciones concurrentes con la misma revision: 1 gana, 5 quote_changed', ok===1 && ch===5, `ok=${ok} changed=${ch} otros=${rs.map(x=>x.status).join(',')}`)
const fin = (await be(A,'GET',`/quotes/${q.id}`)).body
check('revision final = 2 y total coherente con las lineas', fin.revision===2 && Number(fin.total)===fin.items.reduce((a,i)=>a+Number(i.subtotal),0), `rev ${fin.revision} total ${fin.total}`)
// concurrente: 6 send a la vez sobre un draft -> todos 200 (idempotente), un solo evento draft->sent
q = await mk()
rs = await Promise.all(Array.from({length:6}, () => be(A, 'POST', `/quotes/${q.id}/transition`, { action: 'send' })))
const hist = sql(`select count(*) from document_status_history where document_type='quote' and document_id='${q.id}' and to_status='sent'`)
check('6 send concurrentes: sin 5xx y un solo historial draft->sent', rs.every(x=>x.status<500) && hist==='1', `${rs.map(x=>x.status).join(',')} hist=${hist}`)
// concurrente: send vs reject vs delete sobre un draft
q = await mk()
rs = await Promise.all([be(A,'POST',`/quotes/${q.id}/transition`,{action:'send'}), be(A,'POST',`/quotes/${q.id}/transition`,{action:'reject'}), be(A,'DELETE',`/quotes/${q.id}`), be(A,'DELETE',`/quotes/${q.id}`)])
check('send/reject/delete/delete concurrentes: sin 5xx', rs.every(x=>x.status<500), rs.map(x=>x.status).join(','))
const st = sql(`select coalesce((select status from quotes where id='${q.id}'),'(borrado)')`)
const orphan = sql(`select count(*) from quote_items where quote_id='${q.id}'`)
check('estado final consistente (sin items huerfanos si se borro)', st!=='(borrado)' || orphan==='0', `estado=${st} items=${orphan}`)
const bad = results.filter(([, ok]) => !ok)
console.log(`
TOTAL ${results.length}  FAIL ${bad.length}`)
process.exit(bad.length ? 1 : 0)
