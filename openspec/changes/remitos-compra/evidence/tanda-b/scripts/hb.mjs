// Helpers de la verificación de la tanda B de remitos-compra (conversión remito -> compra). Stack LOCAL únicamente.
// Sin credenciales de prod, sin imprimir env. Lee todo lo que importa DIRECTO de la base local.
import { readFileSync, mkdirSync } from 'node:fs'
import { be, sql, check, login, rest, USERS, results } from './lib.mjs'
import { OUT, measureOverflow } from './pw-lib.mjs'

export const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b'
const read = (f) => JSON.parse(readFileSync(`${SP}/${f}`, 'utf8'))
export const IDS = { ...read('ids.json'), ...read('ids-b.json') }
export const A = IDS.accA
export const { br1, br2, harina, alf, escaso, tres, aceite, sinCosto, sup, sup2, kg } = IDS
export { be, sql, check, login, rest, USERS, results }

// ── Lecturas de la base ──────────────────────────────────────────────────────────────────────────────
export const stock = (pid, br = br1) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}' and branch_id='${br}'`))
export const stockAll = (pid) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}'`))
export const cashCount = () => Number(sql(`select count(*) from cash_movements cm join cash_sessions s on s.id=cm.session_id join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${A}'`))
export const cashSum = () => Number(sql(`select coalesce(sum(cm.amount),0) from cash_movements cm join cash_sessions s on s.id=cm.session_id join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${A}'`))
export const cashTypes = (op) => sql(`select coalesce(string_agg(movement_type||':'||amount::float8, ' ' order by created_at, id),'') from cash_movements where reference_id='${op}'`)
export const bankCount = () => Number(sql(`select count(*) from bank_movements where account_id='${A}'`))
export const nMovs = (ref) => Number(sql(`select count(*) from stock_movements where reference_id='${ref}'`))
export const movs = (ref) => sql(`select coalesce(string_agg(type||'/'||reference_type||':'||quantity_delta::float8, ' ' order by created_at, id),'') from stock_movements where reference_id='${ref}'`)
export const allStockMovs = () => Number(sql(`select count(*) from stock_movements where account_id='${A}'`))
export const dnStatus = (id) => sql(`select status from delivery_notes where id='${id}'`)
export const dnRev = (id) => Number(sql(`select revision from delivery_notes where id='${id}'`))
export const dnLabel = (id) => sql(`select 'RC-'||lpad(number::text,8,'0') from delivery_notes where id='${id}'`)
export const dnHistory = (id) => sql(`select coalesce(string_agg(coalesce(from_status,'-')||'>'||to_status, ' ' order by occurred_at, id),'') from document_status_history where document_id='${id}' and document_type='delivery_note_purchase'`)
export const purchaseRows = (dn) => Number(sql(`select count(*) from purchases where source_delivery_note_id='${dn}'`))
export const opOfDn = (dn) => sql(`select operation_id from purchases where source_delivery_note_id='${dn}' limit 1`)
export const opsOfDn = (dn) => sql(`select count(distinct operation_id) from purchases where source_delivery_note_id='${dn}'`)
export const purchaseTotal = (op) => Number(sql(`select coalesce(sum(total),0) from purchases where operation_id='${op}'`))
export const supplierMovs = (supplier = sup) => Number(sql(`select count(*) from supplier_account_movements m join supplier_accounts s on s.id=m.supplier_account_id where s.account_id='${A}' and s.supplier_id='${supplier}'`))
export const supplierMovTypes = (supplier = sup) => sql(`select coalesce(string_agg(m.movement_type||':'||m.amount::float8||coalesce('@'||m.due_date::text,''), ' ' order by m.created_at, m.id),'') from supplier_account_movements m join supplier_accounts s on s.id=m.supplier_account_id where s.account_id='${A}' and s.supplier_id='${supplier}'`)
export const supplierBalance = (supplier = sup) => Number(sql(`select coalesce((select balance from supplier_accounts where account_id='${A}' and supplier_id='${supplier}'),0)`))
export const events = () => Number(sql(`select count(*) from events where account_id='${A}'`))
export const purchasesCount = () => Number(sql(`select count(*) from purchases where account_id='${A}'`))
export const snap = () => ({
  h: stockAll(harina), a: stockAll(alf), e: stockAll(escaso), t: stockAll(tres), ac: stockAll(aceite), sc: stockAll(sinCosto),
  cash: cashCount(), bank: bankCount(), supMovs: supplierMovs(), mov: allStockMovs(), purchases: purchasesCount(),
  dns: sql(`select count(*) || '/' || count(*) filter (where status='issued') from delivery_notes where account_id='${A}'`),
})
export const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
export const line = (pid, q, price, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })
export const stdLines = () => [line(harina, 2.5, 700, { unit_id: kg }), line(alf, 4, 250)]
export const key = () => crypto.randomUUID()
export const pmId = (kind) => sql(`select id from payment_methods where account_id='${A}' and kind='${kind}' and is_active order by sort_order, created_at limit 1`)

// ── API ──────────────────────────────────────────────────────────────────────────────────────────────
export async function mkDn(tok, items = stdLines(), extra = {}) {
  const r = await be(tok, 'POST', '/delivery-notes', { direction: 'purchase', supplier_id: sup, branch_id: br1, supplier_reference: null, notes: null, items, ...extra }, { 'Idempotency-Key': key() })
  if (r.status !== 201) throw new Error('mkDn ' + r.status + ' ' + JSON.stringify(r.body).slice(0, 200))
  return r.body
}
export const convApi = (tok, id, body, k = key(), extra = {}) =>
  be(tok, 'POST', `/delivery-notes/${id}/convert-to-purchase`, body, k === null ? extra : { 'Idempotency-Key': k, ...extra })
export const convBody = (dn, kind = 'transfer', extra = {}) => ({ expected_revision: dnRev(dn), payment_method_id: pmId(kind), ...extra })
export const delPurchase = (tok, op) => be(tok, 'DELETE', `/purchases?operation_id=${op}`)
export const updPurchase = (tok, ids, body) => be(tok, 'PUT', '/purchases/operation', { purchase_ids: ids, date: new Date().toISOString().slice(0, 10), description: 'edición', items: [], ...body })
export const code = (r) => r.body?.code ?? r.body?.detail?.code ?? r.body?.detail ?? ''
export const txt = (r) => JSON.stringify(r.body ?? '').slice(0, 240)

// ── Caja ─────────────────────────────────────────────────────────────────────────────────────────────
export async function currentSession(tok) {
  const r = await be(tok, 'GET', `/cashboxes/${IDS.cashboxId}/current-session`)
  return r.status === 200 && r.body && r.body.id && r.body.status === 'open' ? r.body : null
}
export async function ensureSession(tok, opening = 1000) {
  const cur = await currentSession(tok)
  if (cur) return cur
  const r = await be(tok, 'POST', `/cashboxes/${IDS.cashboxId}/sessions/open`, { opening_balance: opening })
  if (r.status >= 300) throw new Error('open session ' + r.status + JSON.stringify(r.body))
  return await currentSession(tok)
}

// ── Playwright ───────────────────────────────────────────────────────────────────────────────────────
export async function pickPaymentMethod(page, dialog, nameRe) {
  await dialog.getByLabel('Forma de pago').click()
  await page.getByRole('option', { name: nameRe }).first().click()
}
export function pwShot(page, report) {
  return async (name, viewport, theme) => {
    mkdirSync(OUT, { recursive: true })
    await page.waitForTimeout(500)
    await page.screenshot({ path: `${OUT}/${name}-${viewport}-${theme}.png`, fullPage: false })
    const ov = await measureOverflow(page)
    report.push({ name, viewport, theme, docOverflow: ov.docOverflow, overflowCount: ov.count, issues: ov.issues })
    const flag = ov.docOverflow > 1 || ov.count > 0 ? '  <<< DESBORDE' : ''
    console.log(`shot ${name}-${viewport}-${theme} docOverflow=${ov.docOverflow} elementOverflow=${ov.count}${flag}`)
    if (flag) console.log('   ', JSON.stringify(ov.issues.slice(0, 4)))
  }
}
