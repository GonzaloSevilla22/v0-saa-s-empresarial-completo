// Red-team de la tanda C por la API REAL (GoTrue local + FastAPI con las dos palancas de tenencia + PostgREST).
// Uso: node redteam.mjs   (requiere stack.mjs up, seed.mjs)
import { writeFileSync, mkdirSync } from "node:fs"
import { SHOTS, BACK, psql, sql1, loadSecrets, USERS } from "./common.mjs"

const S = loadSecrets()
const API = S.api
const log = []
let failed = 0
const note = (m) => { console.log(m); log.push(m) }
const ok = (c, m) => { if (!c) failed++; note(`${c ? "PASS" : "FAIL"}: ${m}`) }

async function ensureUser(u) {
  await fetch(`${API}/auth/v1/admin/users`, {
    method: "POST",
    headers: { apikey: S.service, Authorization: `Bearer ${S.service}`, "content-type": "application/json" },
    body: JSON.stringify({ email: u.email, password: S.password, email_confirm: true, user_metadata: { name: u.name } }),
  })
}
async function login(email) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { apikey: S.anon, "content-type": "application/json" }, body: JSON.stringify({ email, password: S.password }),
  })
  const b = await r.json()
  if (!b.access_token) throw new Error(`login ${email}: ${JSON.stringify(b).slice(0, 160)}`)
  const claims = JSON.parse(Buffer.from(b.access_token.split(".")[1], "base64url").toString())
  return { token: b.access_token, accountId: claims.app_metadata?.account_id }
}
async function be(method, path, who, body, { header = true } = {}) {
  const headers = { "content-type": "application/json" }
  if (who) headers.Authorization = `Bearer ${who.token}`
  if (who && header && who.accountId) headers["X-Account-Id"] = who.accountId
  const r = await fetch(`${BACK}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined })
  const text = await r.text()
  let json = null
  try { json = text ? JSON.parse(text) : null } catch { json = { raw: text.slice(0, 200) } }
  return { status: r.status, body: json, text }
}
async function rest(method, path, who, body) {
  const r = await fetch(`${API}/rest/v1/${path}`, {
    method,
    headers: { apikey: S.anon, Authorization: `Bearer ${who.token}`, "content-type": "application/json", Prefer: "return=representation" },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await r.text()
  let json = null
  try { json = text ? JSON.parse(text) : null } catch { json = { raw: text.slice(0, 200) } }
  return { status: r.status, body: json, text }
}

const DEST = { email: "humoc-destino@test.local", name: "Destino Dos" }
await ensureUser(DEST)
await ensureUser(USERS.wrong)
await ensureUser(USERS.other)
const A = sql1(`select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${USERS.owner.email}' order by am.created_at limit 1`)
psql(`delete from public.account_invitations where account_id='${A}' and email in ('${DEST.email}','humoc-cuatro@test.local')`)
psql(`delete from public.account_members where user_id=(select id from auth.users where email='${DEST.email}') and account_id='${A}'`)
// El plan del negocio no limita el cupo y la ventana de topes está vacía.
psql(`update public.accounts set billing_plan='pro', billing_status='active', trial_plan=null, trial_expires_at=null where id='${A}'`)
psql(`delete from public.email_logs where event_type='org_invite' and metadata->>'account_id'='${A}'`)

const owner = await login(USERS.owner.email)
const seller = await login(USERS.seller.email)
const wrong = await login(USERS.wrong.email)
const other = await login(USERS.other.email)
const dest = await login(DEST.email)

// Una invitación pendiente real, dirigida a DEST.
const created = await be("POST", "/members/invitations", owner, { email: DEST.email, roles: ["seller"] })
ok(created.status === 201 && created.body?.token, `la invitación a ${DEST.email} se crea (201) y el invitador recibe el token para «Copiar link»`)
const T = created.body.token
const invId = created.body.id
const NONEXISTENT = "f".repeat(64)
const GENERIC = "invalid or expired invitation token"

// ── Identidad distinta ───────────────────────────────────────────────────────────
const pv = await be("GET", `/invitations/${T}`, wrong)
const pvNone = await be("GET", `/invitations/${NONEXISTENT}`, wrong)
ok(pv.status === 404 && pvNone.status === 404, `otra identidad: la vista previa da 404 (${pv.status}), igual que un token inexistente (${pvNone.status})`)
ok(JSON.stringify(pv.body) === JSON.stringify(pvNone.body), "   y el cuerpo del error es IDÉNTICO byte a byte (no revela que el token existe)")
ok(String(pv.body?.detail ?? "").includes(GENERIC), `   mensaje genérico: ${pv.body?.detail}`)
const ac = await be("POST", `/invitations/${T}/accept`, wrong)
ok(ac.status === 404 && JSON.stringify(ac.body) === JSON.stringify(pvNone.body.detail ? { ...pvNone.body } : pvNone.body) || ac.status === 404, `otra identidad: aceptar da 404 (${ac.status})`)
ok(sql1(`select count(*) from public.account_members where user_id=(select id from auth.users where email='${USERS.wrong.email}') and account_id='${A}'`) === "0", "   y NO se creó ninguna membresía para el intruso")
ok(sql1(`select status from public.account_invitations where id='${invId}'`) === "pending", "   la invitación sigue pendiente (el rechazo no la consume)")

// ── Token ajeno: el dueño de OTRA cuenta no administra la invitación de A ───────────
const cross1 = await be("POST", `/members/invitations/${invId}/resend`, other)
const cross2 = await be("DELETE", `/members/invitations/${invId}`, other)
const cross3 = await be("GET", `/members/invitations`, other)
ok(cross1.status === 404 && cross2.status === 404, `el dueño de otra cuenta no reenvía (${cross1.status}) ni revoca (${cross2.status}) la invitación de A: 404`)
ok(!JSON.stringify(cross3.body).includes(DEST.email), "   y su listado no contiene la invitación de A")
ok(sql1(`select status from public.account_invitations where id='${invId}'`) === "pending", "   la invitación de A no cambió")

// ── Invitar sin rol ─────────────────────────────────────────────────────────────
const sellerCreate = await be("POST", "/members/invitations", seller, { email: "humoc-cuatro@test.local", roles: ["viewer"] })
const sellerList = await be("GET", "/members/invitations", seller)
const sellerResend = await be("POST", `/members/invitations/${invId}/resend`, seller)
const sellerRevoke = await be("DELETE", `/members/invitations/${invId}`, seller)
ok([sellerCreate, sellerList, sellerResend, sellerRevoke].every((r) => r.status === 403), `un VENDEDOR no crea (${sellerCreate.status}), no lista (${sellerList.status}), no reenvía (${sellerResend.status}) ni revoca (${sellerRevoke.status}): 403`)
ok(sql1(`select count(*) from public.account_invitations where email='humoc-cuatro@test.local'`) === "0", "   y no quedó ninguna invitación")

// ── Por PostgREST (el atajo que NO existe) ───────────────────────────────────────
const mail = await rest("POST", "email_logs", owner, { event_type: "org_invite", recipient: "victima@example.com", subject: "Phishing", metadata: { token: "x" } })
ok([401, 403].includes(mail.status) || /permission|42501|row-level/i.test(mail.text), `INSERT directo en email_logs como DUEÑO -> ${mail.status} ${mail.text.slice(0, 80)}`)
ok(sql1(`select count(*) from public.email_logs where recipient='victima@example.com'`) === "0", "   y no quedó ninguna fila")
const insInv = await rest("POST", "account_invitations", seller, { account_id: A, email: "x@test.local", token: "t".repeat(64), invited_by: sql1(`select id from auth.users where email='${USERS.seller.email}'`), roles: ["owner"] })
ok(insInv.status !== 201, `INSERT directo en account_invitations como VENDEDOR (roles=owner) -> ${insInv.status}`)
const readInv = await rest("GET", "account_invitations?select=token,email", seller)
ok(readInv.status === 200 && Array.isArray(readInv.body) && readInv.body.length === 0, `un vendedor no LEE las invitaciones ni los tokens por PostgREST (${JSON.stringify(readInv.body).slice(0, 60)})`)
const acceptRpc = await rest("POST", "rpc/rpc_accept_invitation", wrong, { p_token: T })
ok(acceptRpc.status !== 200, `aceptar por PostgREST con otra identidad no funciona (${acceptRpc.status})`)

// ── Sin sesión ─────────────────────────────────────────────────────────────────
const anon1 = await be("GET", `/invitations/${T}`, null)
const anon2 = await be("POST", `/invitations/${T}/accept`, null)
const anon3 = await be("POST", "/members/invitations", null, { email: "a@b.co" })
ok([anon1, anon2, anon3].every((r) => r.status === 401), `sin sesión: vista previa ${anon1.status}, aceptar ${anon2.status}, invitar ${anon3.status} -> 401`)
const anonRpc = await fetch(`${API}/rest/v1/rpc/rpc_invitation_preview`, { method: "POST", headers: { apikey: S.anon, "content-type": "application/json" }, body: JSON.stringify({ p_token: T }) })
ok(anonRpc.status !== 200, `anon por PostgREST no ejecuta rpc_invitation_preview (${anonRpc.status})`)

// ── Payload hostil ───────────────────────────────────────────────────────────────
const hostile = [
  ["email con salto de línea (inyección de encabezados)", { email: "a@b.co\nBcc: x@y.z" }],
  ["all_users", { email: "all_users" }],
  ["email sin dominio", { email: "a@b" }],
  ["rol inyectado", { email: "a@b.co", roles: ["seller; drop table"] }],
]
for (const [label, payload] of hostile) {
  const r = await be("POST", "/members/invitations", owner, payload)
  ok(r.status === 422, `payload hostil «${label}» -> ${r.status}`)
}
ok(sql1(`select count(*) from public.email_logs where event_type='org_invite' and (recipient like '%Bcc%' or recipient = 'all_users')`) === "0", "   y no se encoló ningún email con ese destinatario")

// ── Pestaña desfasada ────────────────────────────────────────────────────────────
const stale = await be("POST", "/members/invitations", { ...owner, accountId: other.accountId }, { email: "humoc-cuatro@test.local" })
ok(stale.status === 409 && stale.body?.code === "account_switched", `X-Account-Id de OTRA cuenta al invitar -> ${stale.status} ${stale.body?.code}`)

// ── Token vencido ─────────────────────────────────────────────────────────────────
psql(`update public.account_invitations set expires_at = now() - interval '1 minute' where id='${invId}'`)
const exp1 = await be("GET", `/invitations/${T}`, dest)
const exp2 = await be("POST", `/invitations/${T}/accept`, dest)
ok(exp1.status === 404 && exp2.status === 404 && JSON.stringify(exp1.body) === JSON.stringify(pvNone.body), `token VENCIDO (aun para el invitado correcto): vista previa ${exp1.status}, aceptar ${exp2.status}, mismo error genérico`)
// reenviar la vencida la revive con token nuevo
psql(`update public.email_logs set created_at = created_at - interval '11 minutes' where metadata->>'invitation_id'='${invId}'`)
const revive = await be("POST", `/members/invitations/${invId}/resend`, owner)
ok(revive.status === 200 && revive.body?.token && revive.body.token !== T, `reenviar una VENCIDA la revive con token nuevo (${revive.status})`)
const T2 = revive.body.token
const oldStill = await be("GET", `/invitations/${T}`, dest)
ok(oldStill.status === 404, `   y el token viejo sigue muerto (${oldStill.status})`)

// ── Revocada ─────────────────────────────────────────────────────────────────────
const rev = await be("DELETE", `/members/invitations/${invId}`, owner)
ok(rev.status === 200 && rev.body?.status === "revoked", `el dueño revoca (${rev.status})`)
const revPreview = await be("GET", `/invitations/${T2}`, dest)
ok(revPreview.status === 404 && JSON.stringify(revPreview.body) === JSON.stringify(pvNone.body), "   la revocada: mismo error genérico para el invitado correcto")
const revResend = await be("POST", `/members/invitations/${invId}/resend`, owner)
ok(revResend.status === 409, `   y no se reenvía una revocada (${revResend.status})`)

// ── El listado nunca expone el token ─────────────────────────────────────────────
const list = await be("GET", "/members/invitations", owner)
ok(list.status === 200 && !list.text.includes(T) && !list.text.includes(T2) && !/"token"/.test(list.text), "el listado del dueño no contiene ningún token")

mkdirSync(SHOTS, { recursive: true })
writeFileSync(`${SHOTS}/redteam.log`, log.join("\n") + `\n\nRESULTADO: ${failed === 0 ? "TODO PASS" : failed + " FAIL"}\n`)
console.log(failed === 0 ? "\nTODO PASS" : `\n${failed} FAIL`)
process.exit(failed === 0 ? 0 : 1)
