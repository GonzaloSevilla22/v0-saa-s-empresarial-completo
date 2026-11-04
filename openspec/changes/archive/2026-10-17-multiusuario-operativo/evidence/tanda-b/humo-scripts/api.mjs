// Humo de la tanda B por la API REAL (GoTrue local ES256 + FastAPI con las dos palancas de tenencia ON + PostgREST):
// R3a-R3l del humo S20, y el red-team (producto/documento ajeno, observador, claim revocado).
// Uso: node api.mjs   (requiere stack.mjs up y seed.mjs)
import { writeFileSync, mkdirSync } from "node:fs"
import { SHOTS, psql, loadSecrets } from "./common.mjs"
import { TEAM } from "./seed.mjs"

const S = loadSecrets()
const API = S.api
const BACK = "http://127.0.0.1:8000"
const log = []
const note = (m) => {
  console.log(m)
  log.push(m)
}
let failed = 0
const ok = (cond, msg) => {
  if (!cond) failed++
  note(`${cond ? "PASS" : "FAIL"}: ${msg}`)
}
const today = new Date().toISOString().slice(0, 10)

async function login(email) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: S.anon, "content-type": "application/json" },
    body: JSON.stringify({ email, password: S.password }),
  })
  const b = await r.json()
  if (!b.access_token) throw new Error(`login ${email}: ${JSON.stringify(b).slice(0, 160)}`)
  const claims = JSON.parse(Buffer.from(b.access_token.split(".")[1], "base64url").toString())
  return { token: b.access_token, accountId: claims.app_metadata?.account_id, roles: claims.app_metadata?.account_roles, claims }
}

async function be(method, path, who, body, { header = true } = {}) {
  const headers = { Authorization: `Bearer ${who.token}`, "content-type": "application/json" }
  if (header && who.accountId) headers["X-Account-Id"] = who.accountId
  const r = await fetch(`${BACK}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined })
  let json = null
  const text = await r.text()
  try { json = text ? JSON.parse(text) : null } catch { json = { raw: text.slice(0, 200) } }
  return { status: r.status, body: json, ct: r.headers.get("content-type") ?? "" }
}

async function rpc(name, who, args) {
  const r = await fetch(`${API}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: S.anon, Authorization: `Bearer ${who.token}`, "content-type": "application/json" },
    body: JSON.stringify(args),
  })
  const text = await r.text()
  let json = null
  try { json = text ? JSON.parse(text) : null } catch { json = { raw: text.slice(0, 200) } }
  return { status: r.status, body: json }
}

const sql1 = (q) => psql(q).trim()
const idOf = (email) => sql1(`select id from auth.users where email='${email}'`)
const accOf = (email) => sql1(`select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${email}' order by am.created_at limit 1`)
const prodId = (sku) => sql1(`select id from public.products where sku='${sku}'`)
const stockOf = (pid) => Number(sql1(`select coalesce(sum(quantity),0) from public.branch_stock where product_id='${pid}'`))
const saleRows = (op) => sql1(`select count(*) || '|' || coalesce(min(user_id::text),'') || '|' || coalesce(min(account_id::text),'') from public.sales where operation_id='${op}'`).split("|")
const purRows = (op) => sql1(`select count(*) || '|' || coalesce(min(user_id::text),'') || '|' || coalesce(min(account_id::text),'') from public.purchases where operation_id='${op}'`).split("|")

const A = accOf(TEAM.owner.email)
const B = accOf(TEAM.other.email)
const U = Object.fromEntries(Object.entries(TEAM).map(([k, u]) => [k, idOf(u.email)]))
const MARTILLO = prodId("HUMOB-MARTILLO")
const CINTA = prodId("HUMOB-CINTA")
const TUERCA = prodId("HUMOB-TUERCA")
const key = (p) => `humob-${p}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`
const saleBody = (pid, q = 2, amount = 1000) => ({ idempotency_key: key("s"), org_id: A, date: today, items: [{ product_id: pid, quantity: q, amount }] })
const purBody = (pid, q = 3, amount = 600) => ({ idempotency_key: key("p"), org_id: A, date: today, items: [{ product_id: pid, quantity: q, amount }] })

// ── tokens reales: cada uno con la cuenta ACTIVA que emite el hook ─────────────
const who = {}
for (const k of Object.keys(TEAM)) who[k] = await login(TEAM[k].email)
ok(who.seller.accountId === A && who.admin.accountId === A && who.purchases.accountId === A && who.viewer.accountId === A,
  `el hook emite la cuenta del negocio como activa para los invitados (seller roles=${JSON.stringify(who.seller.roles)}, viewer roles=${JSON.stringify(who.viewer.roles)})`)

// ═══ R3a / R3b / R3k: vender un producto del DUEÑO por formulario ═══════════════
let s0 = stockOf(MARTILLO)
const rSeller = await be("POST", "/sales", who.seller, saleBody(MARTILLO, 2))
ok(rSeller.status === 201, `R3a: el VENDEDOR vende por formulario un producto del dueño -> ${rSeller.status}`)
const opSeller = rSeller.body?.operation_id
{
  const [n, author, acc] = saleRows(opSeller)
  ok(n === "1" && author === U.seller && acc === A && stockOf(MARTILLO) === s0 - 2, `   la venta quedó en el negocio, con el vendedor como autor, y el stock bajó 2 (${s0} -> ${stockOf(MARTILLO)})`)
}
const rAdmin = await be("POST", "/sales", who.admin, saleBody(MARTILLO, 1))
ok(rAdmin.status === 201, `R3b: el ADMINISTRADOR vende por formulario un producto del dueño -> ${rAdmin.status}`)
const rOwner = await be("POST", "/sales", who.owner, saleBody(CINTA, 1, 500))
ok(rOwner.status === 201, `el DUEÑO vende su propio producto (no regresión) -> ${rOwner.status}`)
const opOwnerSale = rOwner.body?.operation_id

// ═══ R3g: comprar un producto del dueño ═════════════════════════════════════════
s0 = stockOf(MARTILLO)
const rBuy = await be("POST", "/purchases", who.purchases, purBody(MARTILLO, 3))
ok(rBuy.status === 201, `R3g: COMPRAS carga una compra de un producto del dueño -> ${rBuy.status}`)
const opBuy = rBuy.body?.operation_id
{
  const [n, author, acc] = purRows(opBuy)
  ok(n === "1" && author === U.purchases && acc === A && stockOf(MARTILLO) === s0 + 3, `   la compra quedó en el negocio, con compras como autor, y el stock subió 3 (${s0} -> ${stockOf(MARTILLO)})`)
}
const rAdminBuy = await be("POST", "/purchases", who.admin, purBody(CINTA, 1, 300))
ok(rAdminBuy.status === 201, `el ADMINISTRADOR compra -> ${rAdminBuy.status}`)

// ═══ R3d / R3f / R3e: editar y borrar lo AJENO (dueño y admin) ═════════════════
{
  const ids = sql1(`select string_agg(id::text, ',') from public.sales where operation_id='${opSeller}'`).split(",")
  const upd = await be("PUT", "/sales/operation", who.owner, { sale_ids: ids, date: today, items: [{ product_id: MARTILLO, quantity: 4, amount: 1000 }] })
  ok(upd.status === 200, `R3d: el DUEÑO edita la venta del vendedor -> ${upd.status}`)
  const newOp = upd.body?.operation_id
  const [n, author] = saleRows(newOp)
  ok(author === U.seller, `   la edición del dueño CONSERVA al vendedor como autor de la venta (${author === U.seller ? "sí" : "no: " + author})`)
  // el vendedor edita y borra lo PROPIO después
  const ids2 = sql1(`select string_agg(id::text, ',') from public.sales where operation_id='${newOp}'`).split(",")
  const own = await be("PUT", "/sales/operation", who.seller, { sale_ids: ids2, date: today, items: [{ product_id: MARTILLO, quantity: 1, amount: 1000 }] })
  ok(own.status === 200, `el VENDEDOR edita su propia venta (tras la corrección del dueño) -> ${own.status}`)
  // y NO puede con lo del dueño
  const idsO = sql1(`select string_agg(id::text, ',') from public.sales where operation_id='${opOwnerSale}'`).split(",")
  const foreign = await be("PUT", "/sales/operation", who.seller, { sale_ids: idsO, date: today, items: [{ product_id: CINTA, quantity: 9, amount: 500 }] })
  ok(foreign.status === 403 && /insufficient_role|solo el due/i.test(JSON.stringify(foreign.body)), `el VENDEDOR NO edita la venta del dueño -> ${foreign.status} ${foreign.ct.split(";")[0]} (${JSON.stringify(foreign.body?.detail ?? "").slice(0, 90)})`)
  const delForeign = await be("DELETE", `/sales?operation_id=${opOwnerSale}`, who.seller)
  ok(delForeign.status === 403, `el VENDEDOR NO borra la venta del dueño -> ${delForeign.status}`)
  ok(saleRows(opOwnerSale)[0] === "1", `   la venta del dueño sigue intacta`)
  const adm = await be("PUT", "/sales/operation", who.admin, { sale_ids: idsO, date: today, items: [{ product_id: CINTA, quantity: 2, amount: 500 }] })
  ok(adm.status === 200, `R3f: el ADMINISTRADOR edita la venta del dueño -> ${adm.status}`)
  const delOwn = await be("DELETE", `/sales?operation_id=${own.body?.operation_id}`, who.seller)
  ok(delOwn.status === 204, `el VENDEDOR borra su propia venta -> ${delOwn.status}`)
  const rS = await be("POST", "/sales", who.seller, saleBody(MARTILLO, 1))
  const delByOwner = await be("DELETE", `/sales?operation_id=${rS.body?.operation_id}`, who.owner)
  ok(delByOwner.status === 204, `R3e: el DUEÑO borra una venta del vendedor -> ${delByOwner.status}`)
}
// compras: lo ajeno
{
  const idsP = sql1(`select string_agg(id::text, ',') from public.purchases where operation_id='${opBuy}'`).split(",")
  const foreign = await be("PUT", "/purchases/operation", who.admin, { purchase_ids: idsP, date: today, description: "corrige admin", items: [{ product_id: MARTILLO, quantity: 5, amount: 600 }] })
  ok(foreign.status === 200, `el ADMINISTRADOR edita la compra de compras -> ${foreign.status}`)
  const newOp = foreign.body?.operation_id ?? null
  const rP = await be("POST", "/purchases", who.owner, purBody(CINTA, 1, 300))
  const bad = await be("DELETE", `/purchases?operation_id=${rP.body?.operation_id}`, who.purchases)
  ok(bad.status === 403, `COMPRAS NO borra la compra del dueño -> ${bad.status}`)
  const good = await be("DELETE", `/purchases?operation_id=${rP.body?.operation_id}`, who.owner)
  ok(good.status === 204, `el DUEÑO borra su propia compra -> ${good.status}`)
}

// ═══ roles sin la capacidad: FastAPI y la base ══════════════════════════════════
{
  const v = await be("POST", "/sales", who.viewer, saleBody(MARTILLO))
  ok(v.status === 403, `el OBSERVADOR no vende por FastAPI -> ${v.status}`)
  const vp = await be("POST", "/purchases", who.viewer, purBody(MARTILLO))
  ok(vp.status === 403, `el OBSERVADOR no compra por FastAPI -> ${vp.status}`)
  const st = await be("POST", "/sales", who.stock, saleBody(MARTILLO))
  ok(st.status === 403, `el DEPÓSITO no vende por el formulario -> ${st.status}`)
  const sp = await be("POST", "/purchases", who.stock, purBody(MARTILLO))
  ok(sp.status === 403, `el DEPÓSITO no compra (recibe por remito) -> ${sp.status}`)
  const cp = await be("POST", "/purchases", who.seller, purBody(MARTILLO))
  ok(cp.status === 403, `el VENDEDOR no compra -> ${cp.status}`)
  // PostgREST directo (saltea FastAPI): la base es la autoridad
  const dv = await rpc("rpc_create_sale_operation_v2", who.viewer, { p_idempotency_key: key("d"), p_client_id: null, p_date: today, p_currency: "ARS", p_items: [{ product_id: MARTILLO, quantity: 1, amount: 1000 }] })
  ok(/P0401|unauthorized/.test(JSON.stringify(dv.body)), `PostgREST directo: el OBSERVADOR vende -> ${dv.status} ${JSON.stringify(dv.body).slice(0, 110)}`)
  const ds = await rpc("rpc_create_purchase_operation", who.stock, { p_idempotency_key: key("d"), p_date: today, p_description: "x", p_items: [{ product_id: MARTILLO, quantity: 1, amount: 600 }] })
  ok(/P0403|insufficient_role/.test(JSON.stringify(ds.body)), `PostgREST directo: el DEPÓSITO compra -> ${ds.status} ${JSON.stringify(ds.body).slice(0, 110)}`)
  const freshSale = await be("POST", "/sales", who.owner, saleBody(CINTA, 1, 500))
  const opFresh = freshSale.body?.operation_id
  const dd = await rpc("rpc_delete_sale_operation", who.viewer, { p_operation_id: opFresh })
  ok(/P0401|unauthorized/.test(JSON.stringify(dd.body)) && saleRows(opFresh)[0] === "1", `PostgREST directo: el OBSERVADOR borra una venta -> ${dd.status} ${JSON.stringify(dd.body).slice(0, 60)} y la venta sigue`)
  // R3h esperado: el vendedor no ajusta stock a mano
  const adj = await rpc("rpc_stock_adjustment", who.seller, { p_product_id: MARTILLO, p_quantity_delta: -1, p_type: "loss", p_reason: "humo" })
  ok(/P0403|insufficient_role/.test(JSON.stringify(adj.body)), `R3h (esperado): el vendedor no ajusta stock a mano -> ${adj.status} ${JSON.stringify(adj.body).slice(0, 90)}`)
}

// ═══ R3j / R3l: POS y venta de servicio quedan en el negocio ═══════════════════
{
  const pos = await be("POST", "/sales-orders/quick-sale", who.seller, { idempotency_key: key("pos"), items: [{ product_id: MARTILLO, quantity: 1, price: 1000, subtotal: 1000 }] })
  const posAcc = pos.body?.sales_order_id ? sql1(`select account_id from public.sales_orders where id='${pos.body.sales_order_id}'`) : ""
  ok(pos.status === 201 || pos.status === 200, `R3j: el POS del vendedor sobre un producto del negocio -> ${pos.status} (cuenta ${posAcc === A ? "negocio" : posAcc || "?"})`)
  const svc = await be("POST", "/sales", who.seller, { idempotency_key: key("svc"), org_id: A, date: today, items: [{ product_id: "", quantity: 1, amount: 250 }] })
  note(`   (la venta de servicio por FastAPI exige product_id; se verifica por PostgREST, como el formulario)`)
  const svcRpc = await rpc("rpc_create_sale_operation", who.seller, { p_idempotency_key: key("svc"), p_client_id: null, p_date: today, p_currency: "ARS", p_items: [{ amount: 250, quantity: 1 }] })
  const svcAcc = svcRpc.body?.operation_id ? sql1(`select account_id from public.sales where operation_id='${svcRpc.body.operation_id}' limit 1`) : ""
  ok(svcAcc === A, `R3l: la venta de servicio del vendedor quedó en el NEGOCIO (${svcAcc === A ? "correcto" : svcAcc || svcRpc.status})`)
}

// ═══ RED-TEAM ═══════════════════════════════════════════════════════════════════
{
  // producto de OTRA cuenta
  const ghost = "00000000-0000-0000-0000-00000000dead"
  const stB0 = stockOf(TUERCA)
  const rB = await be("POST", "/sales", who.seller, saleBody(TUERCA, 1, 20))
  const rG = await be("POST", "/sales", who.seller, saleBody(ghost, 1, 20))
  const norm = (m) => String(m ?? "").replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "<id>")
  ok(rB.status === 404 && rG.status === 404 && norm(rB.body?.detail) === norm(rG.body?.detail), `producto de OTRA cuenta -> ${rB.status}, indistinguible de uno inexistente (${rG.status}): "${norm(rB.body?.detail).slice(0, 70)}"`)
  const stB = stockOf(TUERCA)
  ok(stB === stB0, `   el stock de la cuenta ajena no se movió (${stB0} -> ${stB})`)
  const rBP = await be("POST", "/purchases", who.purchases, purBody(TUERCA, 1, 10))
  ok(rBP.status === 404, `compra de un producto de OTRA cuenta -> ${rBP.status}`)
  // documento de OTRA cuenta
  const rZ = await be("POST", "/sales", await login(TEAM.other.email), { idempotency_key: key("z"), org_id: B, date: today, items: [{ product_id: TUERCA, quantity: 1, amount: 20 }] })
  const opZ = rZ.body?.operation_id
  ok(rZ.status === 201, `(fixture) la dueña de la OTRA cuenta vende lo suyo -> ${rZ.status}`)
  const idsZ = sql1(`select string_agg(id::text, ',') from public.sales where operation_id='${opZ}'`).split(",")
  const upd = await be("PUT", "/sales/operation", who.owner, { sale_ids: idsZ, date: today, items: [{ product_id: MARTILLO, quantity: 1, amount: 1000 }] })
  ok(upd.status === 404 && saleRows(opZ)[0] === "1", `el DUEÑO de A edita una venta de B -> ${upd.status} y B no cambia`)
  const del = await be("DELETE", `/sales?operation_id=${opZ}`, who.owner)
  ok(del.status === 404 && saleRows(opZ)[0] === "1", `el DUEÑO de A borra una venta de B -> ${del.status} y B no cambia`)
  // el vendedor con su PERSONAL activa y un producto del negocio (cuenta no activa)
  psql(`update public.profiles set active_account_id = (select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${TEAM.seller.email}' order by am.created_at limit 1) where id='${U.seller}'`)
  const sellerP = await login(TEAM.seller.email)
  ok(sellerP.accountId !== A, `(fixture) el vendedor cambió a su cuenta PERSONAL (${sellerP.accountId === A ? "sigue en A" : "personal"})`)
  const na = await be("POST", "/sales", sellerP, saleBody(MARTILLO, 1))
  ok(na.status === 404, `con la PERSONAL activa, vender un producto del negocio (cuenta no activa) -> ${na.status}`)
  psql(`update public.profiles set active_account_id = '${A}' where id='${U.seller}'`)
  // claim revocado: se quita al vendedor del negocio y se reutiliza su token vigente
  const sellerA = await login(TEAM.seller.email)
  ok(sellerA.accountId === A, `(fixture) el vendedor vuelve al negocio y el token declara la cuenta A`)
  const memberId = sql1(`select id from public.account_members where user_id='${U.seller}' and account_id='${A}'`)
  psql(`delete from public.account_members where id='${memberId}'`)
  const rev = await be("POST", "/sales", sellerA, saleBody(MARTILLO, 1), { header: false })
  ok(rev.status === 403, `CLAIM REVOCADO: el token vigente de un miembro quitado -> ${rev.status} ${JSON.stringify(rev.body?.detail ?? "").slice(0, 70)}`)
  const revRpc = await rpc("rpc_create_sale_operation_v2", sellerA, { p_idempotency_key: key("r"), p_client_id: null, p_date: today, p_currency: "ARS", p_items: [{ product_id: MARTILLO, quantity: 1, amount: 1000 }] })
  ok(/P0403|sin cuenta activa/i.test(JSON.stringify(revRpc.body)), `CLAIM REVOCADO por PostgREST directo -> ${revRpc.status} ${JSON.stringify(revRpc.body).slice(0, 90)}`)
  // se restaura el miembro para no dejar el fixture roto
  const m = sql1(`insert into public.account_members (account_id, user_id, role, created_at) values ('${A}','${U.seller}','member', now() - interval '1 day') returning id`)
  psql(`insert into public.account_member_roles (account_id, member_id, role) values ('${A}', '${m.split("\n")[0]}', 'seller')`)
}

mkdirSync(SHOTS, { recursive: true })
writeFileSync(`${SHOTS}/humo-api.log`, log.join("\n") + `\n\nRESULTADO: ${failed === 0 ? "TODO PASS" : failed + " FAIL"}\n`)
console.log(failed === 0 ? "\nTODO PASS" : `\n${failed} FAIL`)
process.exit(failed === 0 ? 0 : 1)
