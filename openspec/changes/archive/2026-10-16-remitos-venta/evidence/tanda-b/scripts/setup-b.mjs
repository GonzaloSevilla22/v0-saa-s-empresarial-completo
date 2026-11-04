// Siembra adicional de la verificación de la tanda B (stack LOCAL): perfil fiscal de HOMOLOGACION + punto de venta,
// cuenta bancaria y caja. Corre DESPUÉS de seed.mjs (ids.json). Nada de producción.
import { readFileSync, writeFileSync } from 'node:fs'
import { login, be, sql, USERS } from '../../scripts/lib.mjs'
const SP = 'C:/Users/Usuario/Desktop/EIE/scratchpad-remitos'
const IDS = JSON.parse(readFileSync(`${SP}/ids.json`, 'utf8'))
const tok = await login(...USERS.owner)
const accA = IDS.accA
const userId = sql("select id from auth.users where email='qa.e2e@local.test'")
if (sql(`select count(*) from fiscal_profiles where account_id='${accA}'`) === '0') {
  sql(`insert into fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada) values ('${accA}','20-12345678-6','monotributista','homologacion',true)`)
}
const fp = sql(`select id from fiscal_profiles where account_id='${accA}' limit 1`)
if (sql(`select count(*) from points_of_sale where account_id='${accA}' and is_active`) === '0') {
  sql(`insert into points_of_sale (fiscal_profile_id, account_id, numero, is_active) values ('${fp}','${accA}',9911,true)`)
}
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
const out = { userId, fp, cashboxId, bankId: banks[0].id }
writeFileSync(`${SP}/ids-b.json`, JSON.stringify(out, null, 1))
console.log('setup-b OK', Object.keys(out).join(','))
