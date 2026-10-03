// Siembra de la tanda B (stack LOCAL): perfil fiscal de homologación + PV, productos, cuenta bancaria, caja.
import { writeFileSync } from 'node:fs'
import { login, be, sql, USERS } from './lib-b.mjs'

const tok = await login(...USERS.owner)
const accA = sql("select account_id from account_members where user_id=(select id from auth.users where email='qa.e2e@local.test') order by created_at limit 1")
const userId = sql("select id from auth.users where email='qa.e2e@local.test'")
const branches = (await be(tok, 'GET', '/branches')).body
const branchId = (Array.isArray(branches) ? branches : branches.items)[0].id

// Perfil fiscal de HOMOLOGACION (nunca producción) + un punto de venta.
if (sql(`select count(*) from fiscal_profiles where account_id='${accA}'`) === '0') {
  sql(`insert into fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada) values ('${accA}','20-12345678-6','monotributista','homologacion',true)`)
}
const fp = sql(`select id from fiscal_profiles where account_id='${accA}' limit 1`)
if (sql(`select count(*) from points_of_sale where account_id='${accA}' and is_active`) === '0') {
  sql(`insert into points_of_sale (fiscal_profile_id, account_id, numero, is_active) values ('${fp}','${accA}',9911,true)`)
}

// Producto con poco stock (para el caso de stock insuficiente).
const unit = sql(`select id from units_of_measure where account_id='${accA}' and symbol='u'`)
if (sql(`select count(*) from products where account_id='${accA}' and sku='QA-ESCASO'`) === '0') {
  const pid = sql(`insert into products (user_id, account_id, name, sku, cost, price, base_unit_id) values ('${userId}','${accA}','Producto escaso QA','QA-ESCASO',100,300,'${unit}') returning id`).split('\n')[0]
  sql(`select public.c21_apply_branch_stock_delta('${accA}','${pid}','${branchId}',1)`)
}

// Cuenta bancaria
let banks = (await be(tok, 'GET', '/bank-accounts')).body
if (!banks || banks.length === 0) {
  const r = await be(tok, 'POST', '/bank-accounts', { name: 'Banco QA', bank_name: 'Banco de prueba' })
  console.log('bank create', r.status)
  banks = (await be(tok, 'GET', '/bank-accounts')).body
}
const pms = (await be(tok, 'GET', '/payment-methods')).body
const cashboxes = (await be(tok, 'GET', `/branches/${branchId}/cashboxes`)).body
let cashboxId = cashboxes?.[0]?.id
if (!cashboxId) {
  const r = await be(tok, 'POST', '/cashboxes', { branch_id: branchId, name: 'Caja QA' })
  console.log('cashbox create', r.status)
  cashboxId = r.body.id
}
const out = {
  accA, userId, branchId, fp, cashboxId,
  bankId: banks[0].id,
  pm: Object.fromEntries((Array.isArray(pms) ? pms : pms.items ?? []).map((p) => [p.kind + (p.name ? ':' + p.name : ''), p.id])),
  pmNames: (Array.isArray(pms) ? pms : pms.items ?? []).map((p) => `${p.kind}:${p.name}`),
}
writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-presupuestos/ids-b.json', JSON.stringify(out, null, 1))
console.log(JSON.stringify({ ...out, pm: undefined }, null, 1))
