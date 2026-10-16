// Regresión de la tanda B (el diálogo de conversión compartido se tocó): presupuesto -> Venta por la UI real SIGUE descontando
// stock con movimiento sale/sale. Stack LOCAL. Lee stock y movimientos de la base local antes y después.
import { readFileSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, consoleCollector } from './pw-lib.mjs'
import { login, USERS, sql, be, check, results } from './lib.mjs'

const IDS = JSON.parse(readFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b/ids.json', 'utf8'))
const { accA, br1, alf, client } = IDS
const stock = (pid, br) => Number(sql(`select coalesce(sum(quantity),0) from branch_stock where product_id='${pid}' and branch_id='${br}'`))
const tok = await login(...USERS.owner)
const AUTH = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b/qa-auth-owner.json'
const browser = await chromium.launch()
await uiLogin(browser, ...USERS.owner, AUTH)
const ctx = await newCtx(browser, 'desktop', 'light', AUTH)
const page = await ctx.newPage()
const errs = consoleCollector(page)

const q = await be(tok, 'POST', '/quotes', { client_id: client, valid_until: new Date(Date.now() + 864e6).toISOString().slice(0, 10), items: [{ product_id: alf, quantity: 3, price: 500, subtotal: 1500 }] })
check('(presupuesto) se crea (201)', q.status === 201, `${q.status} ${JSON.stringify(q.body).slice(0, 120)}`)
const s0 = stock(alf, br1)
const m0 = Number(sql(`select count(*) from stock_movements where account_id='${accA}'`))
await page.goto(`${BASE}/presupuestos/${q.body.id}`, { waitUntil: 'domcontentloaded', timeout: 180000 })
await page.getByRole('button', { name: /^Venta$/ }).waitFor({ timeout: 120000 })
await page.getByRole('button', { name: /^Venta$/ }).click()
const d = page.getByRole('dialog')
await d.getByText('Pasar a venta').first().waitFor({ timeout: 60000 })
await page.waitForTimeout(1500)
await d.getByLabel('Forma de pago').click()
await page.getByRole('option', { name: /Otro/ }).first().click()
await page.waitForTimeout(500)
await d.getByRole('button', { name: 'Registrar venta' }).click()
await page.getByText(/Venta registrada/).first().waitFor({ timeout: 60000 })
const s1 = stock(alf, br1)
check('(presupuesto) presupuesto -> Venta: el stock BAJA 3 (el flujo de venta sigue descontando)', s1 === s0 - 3, `${s0}->${s1}`)
const op = sql(`select sale_operation_id from sales_orders where account_id='${accA}' and source_quote_id='${q.body.id}' limit 1`)
check('(presupuesto) existe la venta nacida del presupuesto', !!op, op)
const mv = sql(`select coalesce(string_agg(distinct type||'/'||reference_type, ','),'') from stock_movements where reference_id in (select id from sales where operation_id='${op}')`)
check('(presupuesto) el movimiento de stock es sale/sale y hay uno nuevo por línea', /^sale\/sale$/.test(mv) && Number(sql(`select count(*) from stock_movements where account_id='${accA}'`)) === m0 + 1, `${mv} movs ${m0}->${sql(`select count(*) from stock_movements where account_id='${accA}'`)}`)
console.log('console errors:', JSON.stringify(errs.slice(0, 4)))
const failed = results.filter(([, ok]) => !ok)
console.log(`RESUMEN presupuesto -> venta: ${results.length - failed.length}/${results.length} PASS`)
await browser.close()
process.exit(failed.length ? 1 : 0)
