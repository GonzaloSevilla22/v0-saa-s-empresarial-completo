// Helpers de la verificación de la tanda B de remitos-venta (stack LOCAL únicamente).
import { readFileSync, mkdirSync } from 'node:fs'
import { be, sql, check, login, rest, USERS, results } from '../../scripts/lib.mjs'
import { OUT, measureOverflow } from './pw-b.mjs'

const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos'
export const IDS = { ...JSON.parse(readFileSync(`${SP}/ids.json`, 'utf8')), ...JSON.parse(readFileSync(`${SP}/ids-b.json`, 'utf8')) }
export const A = IDS.accA
export const { br1, br2, harina, alf, escaso, tres, aceite, client, client2, kg } = IDS
export { be, sql, check, login, rest, USERS, results }

export const stock = (pid, br = br1) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}' and branch_id='${br}'`))
export const stockAll = (pid) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}'`))
export const cashCount = () => Number(sql(`select count(*) from cash_movements cm join cash_sessions s on s.id=cm.session_id join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${A}'`))
export const cashSum = () => Number(sql(`select coalesce(sum(cm.amount),0) from cash_movements cm join cash_sessions s on s.id=cm.session_id join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${A}'`))
export const bankCount = () => Number(sql(`select count(*) from bank_movements where account_id='${A}'`))
export const nMovs = (ref) => Number(sql(`select count(*) from stock_movements where reference_id='${ref}'`))
export const movs = (ref) => sql(`select coalesce(string_agg(type||'/'||reference_type||':'||quantity_delta::float8, ' ' order by created_at, id),'') from stock_movements where reference_id='${ref}'`)
export const allStockMovs = () => Number(sql(`select count(*) from stock_movements where account_id='${A}'`))
export const dnStatus = (id) => sql(`select status from delivery_notes where id='${id}'`)
export const dnRev = (id) => Number(sql(`select revision from delivery_notes where id='${id}'`))
export const dnLabel = (id) => sql(`select 'R-'||lpad(number::text,8,'0') from delivery_notes where id='${id}'`)
export const ordersOfDn = (id) => sql(`select coalesce(string_agg(status,',' order by created_at),'') from sales_orders where source_delivery_note_id='${id}'`)
export const liveOrderOfDn = (id) => sql(`select id from sales_orders where source_delivery_note_id='${id}' and status<>'canceled'`)
export const opOfOrder = (so) => sql(`select sale_operation_id from sales_orders where id='${so}'`)
export const customerMovs = () => Number(sql(`select count(*) from customer_account_movements where account_id='${A}'`))
export const snap = () => ({
  h: stockAll(harina), a: stockAll(alf), e: stockAll(escaso), t: stockAll(tres), ac: stockAll(aceite),
  cash: cashCount(), bank: bankCount(), cust: customerMovs(), mov: allStockMovs(),
  orders: sql(`select count(*) from sales_orders where account_id='${A}'`),
  sales: sql(`select count(*) from sales where account_id='${A}'`),
  dns: sql(`select count(*) || '/' || count(*) filter (where status='issued') from delivery_notes where account_id='${A}'`),
  events: sql(`select count(*) from events where account_id='${A}'`),
})
export const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
export const line = (pid, q, price, extra = {}) => ({ product_id: pid, quantity: q, price, subtotal: q * price, ...extra })
export const stdLines = () => [line(harina, 2.5, 1200, { unit_id: kg }), line(alf, 4, 500)]
export const key = () => crypto.randomUUID()

export async function mkDn(tok, items = stdLines(), extra = {}) {
  const r = await be(tok, 'POST', '/delivery-notes', { client_id: client, branch_id: br1, items, ...extra }, { 'Idempotency-Key': key() })
  if (r.status !== 201) throw new Error('mkDn ' + r.status + ' ' + JSON.stringify(r.body).slice(0, 200))
  return r.body
}
export const convApi = (tok, id, body, k = key(), extra = {}) =>
  be(tok, 'POST', `/delivery-notes/${id}/convert`, body, k === null ? extra : { 'Idempotency-Key': k, ...extra })

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
export async function closeSession(tok) {
  const cur = await currentSession(tok)
  if (!cur) return
  const r = await be(tok, 'POST', `/sessions/${cur.id}/close`, { counted_balance: Number(cur.expected_balance ?? cur.opening_balance ?? 0) }, { 'Idempotency-Key': crypto.randomUUID() })
  if (r.status >= 300) throw new Error('close session ' + r.status + JSON.stringify(r.body))
}
export async function pickPaymentMethod(page, dialog, nameRe) {
  await dialog.getByLabel('Forma de pago').click()
  await page.getByRole('option', { name: nameRe }).first().click()
}
export async function pickBank(page, dialog, nameRe = /Banco QA/) {
  await dialog.getByLabel(/cuenta/i).first().click()
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
