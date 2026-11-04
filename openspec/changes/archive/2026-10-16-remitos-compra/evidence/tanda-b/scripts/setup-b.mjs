// Siembra adicional de la verificación de la tanda B de remitos-compra (stack LOCAL): cuenta bancaria, caja y un plazo
// de pago para el proveedor de la demo (para ver la cascada del vencimiento). Corre DESPUÉS de seed.mjs (ids.json).
import { readFileSync, writeFileSync } from 'node:fs'
import { login, be, sql, USERS } from './lib.mjs'

const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra-b'
const IDS = JSON.parse(readFileSync(`${SP}/ids.json`, 'utf8'))
const tok = await login(...USERS.owner)
const userId = sql("select id from auth.users where email='qa.e2e@local.test'")

let banks = (await be(tok, 'GET', '/bank-accounts')).body
if (!banks || banks.length === 0) {
  console.log('bank', (await be(tok, 'POST', '/bank-accounts', { name: 'Banco QA', bank_name: 'Banco de prueba' })).status)
  banks = (await be(tok, 'GET', '/bank-accounts')).body
}
const cashboxes = (await be(tok, 'GET', `/branches/${IDS.br1}/cashboxes`)).body
let cashboxId = cashboxes?.[0]?.id
if (!cashboxId) {
  const r = await be(tok, 'POST', '/cashboxes', { branch_id: IDS.br1, name: 'Caja QA' })
  console.log('cashbox', r.status)
  cashboxId = r.body.id
}
// El proveedor de la demo tiene un plazo de 15 días: la UI tiene que pre-cargar el vencimiento con él.
sql(`update suppliers set payment_terms_days = 15 where id='${IDS.sup}'`)
const out = { userId, cashboxId, bankId: banks[0].id }
writeFileSync(`${SP}/ids-b.json`, JSON.stringify(out, null, 1))
console.log('setup-b OK', Object.keys(out).join(','))
