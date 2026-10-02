// Helpers comunes de la pasada funcional y visual de la tanda B (stack LOCAL).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { be, sql, check } from './lib-b.mjs'
import { OUT, measureOverflow } from './pwb-lib.mjs'

export const IDS = JSON.parse(readFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-presupuestos/ids-b.json', 'utf8'))
export const A = IDS.accA
export const prod = (sku) => sql(`select id from products where account_id='${A}' and sku='${sku}'`)
export const P = { harina: prod('QA-HARINA'), alf: prod('QA-ALF'), escaso: prod('QA-ESCASO') }
export const KG = sql(`select id from units_of_measure where account_id='${A}' and symbol='kg'`)
export const CLIENT = sql(`select id from clients where account_id='${A}' and name='Cliente Demo QA'`)
export const stock = (pid) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}'`))
export const cashCount = () => Number(sql(`select count(*) from cash_movements cm join cash_sessions s on s.id=cm.session_id join cashboxes c on c.id=s.cashbox_id join branches b on b.id=c.branch_id where b.account_id='${A}'`))
export const bankCount = () => Number(sql(`select count(*) from bank_movements where account_id='${A}'`))
export const ordersOf = (qid) => sql(`select coalesce(string_agg(status,','),'') from sales_orders where source_quote_id='${qid}'`)
export const quoteStatus = (qid) => sql(`select status from quotes where id='${qid}'`)

export function item(pid, q = 1, price = 1000, extra = {}) {
  return { product_id: pid, quantity: q, price, subtotal: q * price, ...extra }
}
export const isoIn = (days) => { const d = new Date(); d.setDate(d.getDate() + days); return d.toISOString().slice(0, 10) }

export async function mkQuote(tok, items, { send = true, valid = 10, notes = 'Prueba tanda B' } = {}) {
  const r = await be(tok, 'POST', '/quotes', { client_id: CLIENT, valid_until: isoIn(valid), notes, items })
  if (r.status !== 201) throw new Error('mkQuote ' + r.status + ' ' + JSON.stringify(r.body).slice(0, 200))
  if (send) await be(tok, 'POST', `/quotes/${r.body.id}/transition`, { action: 'send' })
  return r.body
}
export const stdItems = () => [item(P.harina, 2, 1200, { unit_id: KG }), item(P.alf, 3, 500)]

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
  const trigger = dialog.getByLabel(/cuenta/i).first()
  await trigger.click()
  await page.getByRole('option', { name: nameRe }).first().click()
}

export function pwShot(page, report) {
  return async (name, viewport, theme) => {
    mkdirSync(OUT, { recursive: true })
    await page.waitForTimeout(500)
    const file = `${OUT}/${name}-${viewport}-${theme}.png`
    await page.screenshot({ path: file, fullPage: false })
    const ov = await measureOverflow(page)
    report.push({ name, viewport, theme, docOverflow: ov.docOverflow, overflowCount: ov.count, issues: ov.issues })
    const flag = ov.docOverflow > 1 || ov.count > 0 ? '  <<< DESBORDE' : ''
    console.log(`shot ${name}-${viewport}-${theme} docOverflow=${ov.docOverflow} elementOverflow=${ov.count}${flag}`)
    if (flag) console.log('   ', JSON.stringify(ov.issues.slice(0, 4)))
  }
}
export { check, sql, be }
