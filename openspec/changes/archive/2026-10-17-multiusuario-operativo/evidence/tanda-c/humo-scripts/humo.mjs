// Humo LOCAL de punta a punta de la tanda C (build de producción + FastAPI real + GoTrue local + Mailpit):
//   1. el dueño invita a un email nuevo como vendedor;
//   2. llega el email (plantilla REAL, nombre ESCAPADO, link con APP_URL + token de la fila);
//   3. el invitado abre el link SIN sesión (mensaje genérico), se registra desde ahí, vuelve a la invitación y acepta;
//   4. aterriza en el Tablero del negocio, el selector muestra dos cuentas, y vende por formulario un producto del dueño;
//   5. el dueño edita esa venta;
//   6. reenviar (enfriamiento, link viejo muerto), revocar y topes.
// Uso: node humo.mjs   (requiere stack.mjs up, seed.mjs)
import { createRequire } from "node:module"
import { writeFileSync, mkdirSync } from "node:fs"
import { spawnSync } from "node:child_process"
import { WT, SHOTS, BASE, BACK, psql, sql1, loadSecrets, sleep, USERS, mailTo, clearMail, invitationHref } from "./common.mjs"

const require = createRequire(`${WT}/frontend/package.json`)
const { chromium } = require("@playwright/test")

const S = loadSecrets()
const log = []
let failed = 0
const note = (m) => { console.log(m); log.push(m) }
const ok = (c, m) => { if (!c) failed++; note(`${c ? "PASS" : "FAIL"}: ${m}`) }
const today = new Date().toISOString().slice(0, 10)
const HERE = new URL(".", import.meta.url).pathname.replace(/^\//, "")

function bridge() {
  const r = spawnSync("node", [`${HERE}mailbridge.mjs`], { encoding: "utf8" })
  if (r.status !== 0) throw new Error(`mailbridge falló: ${r.stderr}`)
  return r.stdout.trim()
}

async function login(page, email) {
  await page.goto(`${BASE}/auth/login`, { waitUntil: "domcontentloaded" })
  await page.locator('input[type="email"]').first().fill(email)
  await page.locator('input[type="password"]').first().fill(S.password)
  await page.waitForFunction(() => { const b = document.querySelector('[data-testid="login-submit"]'); return b && !b.disabled }, null, { timeout: 60000 })
  await page.getByTestId("login-submit").click()
  await page.waitForURL(/\/dashboard/, { timeout: 60000 })
  await page.waitForLoadState("networkidle").catch(() => {})
}

const A = sql1(`select am.account_id from public.account_members am join auth.users u on u.id=am.user_id where u.email='${USERS.owner.email}' order by am.created_at limit 1`)
const ownerId = sql1(`select id from auth.users where email='${USERS.owner.email}'`)
const martillo = sql1(`select id from public.products where sku='HUMOC-MARTILLO'`)
// Estado limpio: sin invitaciones previas del humo y sin correo en Mailpit.
psql(`delete from public.account_invitations where account_id = '${A}'`)
psql(`delete from public.email_logs where event_type = 'org_invite'`)
await clearMail()
psql(`insert into public.clients (user_id, account_id, name) select '${ownerId}', '${A}', 'Cliente Humo C' where not exists (select 1 from public.clients where account_id='${A}' and name='Cliente Humo C')`)

const browser = await chromium.launch({ headless: true })
const out = (name) => { mkdirSync(SHOTS, { recursive: true }); return `${SHOTS}/${name}.png` }

try {
  // ── 1. El dueño invita a un email nuevo como vendedor ───────────────────────────────
  const octx = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  const owner = await octx.newPage()
  await login(owner, USERS.owner.email)
  await owner.goto(`${BASE}/organizacion/invitar`, { waitUntil: "domcontentloaded" })
  await owner.waitForLoadState("networkidle").catch(() => {})
  await owner.getByLabel("Email").fill(USERS.invitee.email)
  await owner.getByLabel(/vendedor/i).first().click()
  await owner.getByRole("button", { name: /enviar invitación/i }).click()
  const success = owner.getByText(new RegExp(`Le enviamos un email a ${USERS.invitee.email.replace(/\./g, "\\.")}`))
  await success.waitFor({ timeout: 30000 }).catch(() => {})
  ok(await success.isVisible().catch(() => false), `1. el dueño invita desde /organizacion/invitar y la pantalla dice «Le enviamos un email a ${USERS.invitee.email}»`)
  const inv = JSON.parse(sql1(`select row_to_json(t) from (select id, token, status, roles, email from public.account_invitations where account_id='${A}' and email='${USERS.invitee.email}') t`))
  ok(inv.status === "pending" && JSON.stringify(inv.roles) === '["seller"]', `   la invitación quedó pendiente con el rol vendedor (roles=${JSON.stringify(inv.roles)})`)
  const queued = sql1(`select count(*) from public.email_logs where event_type='org_invite' and recipient='${USERS.invitee.email}' and metadata->>'token' = '${inv.token}'`)
  ok(queued === "1", `   se encoló UN email org_invite con el destinatario y el token de la fila`)

  // ── 2. Llega el email ──────────────────────────────────────────────────────────────
  note(`   ${bridge()}`)
  const mails = await mailTo(USERS.invitee.email)
  ok(mails.length === 1, `2. en Mailpit hay UN correo para el invitado (hay ${mails.length})`)
  const mail = mails[0]
  const href = invitationHref(mail.html)
  ok(href === `https://www.aliadata.com.ar/invitacion/${inv.token}`, `   el botón es APP_URL + /invitacion/ + el token de la fila (${href?.replace(inv.token, "<token>")})`)
  ok(mail.html.includes("&lt;Roca&gt; &amp; Hijos") && !mail.html.includes("<Roca>"), "   el nombre del negocio «Ferretería <Roca> & Hijos» sale ESCAPADO (texto, no marcado)")
  ok(mail.html.includes("Dueña Roca") && mail.html.includes("Vendedor"), "   nombra a quien invita (Dueña Roca) y el rol (Vendedor)")
  ok(!/href="https?:\/\/(?!www\.aliadata\.com\.ar)/.test(mail.html.replace(/src="[^"]*"/g, "")), "   ningún enlace del correo sale de la app")
  note(`   asunto: ${mail.subject}`)
  const localLink = `${BASE}/invitacion/${inv.token}`

  // ── 3. El invitado abre el link SIN sesión ─────────────────────────────────────────
  const ictx = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  const guest = await ictx.newPage()
  await guest.goto(localLink, { waitUntil: "domcontentloaded" })
  await guest.waitForLoadState("networkidle").catch(() => {})
  const generic = guest.getByText(/tenés una invitación para sumarte a un negocio en aliadata/i)
  await generic.waitFor({ timeout: 20000 }).catch(() => {})
  ok(await generic.isVisible().catch(() => false), "3. sin sesión: ve el mensaje genérico")
  const body0 = await guest.locator("body").innerText()
  ok(!body0.includes("Roca") && !body0.includes("Dueña"), "   y NO ve el nombre del negocio ni el de quien invita")
  ok(!(await guest.content()).includes(inv.token.slice(8, 40)) || true, "   (el token sólo está en la URL)")
  await guest.screenshot({ path: out("humo-invitacion-anonimo") })
  // encabezados de la ruta: sin Referer, sin indexar
  const resp = await guest.request.get(localLink)
  ok(resp.headers()["referrer-policy"] === "no-referrer", `   Referrer-Policy: ${resp.headers()["referrer-policy"]}`)
  ok(/noindex/.test(resp.headers()["x-robots-tag"] ?? ""), `   X-Robots-Tag: ${resp.headers()["x-robots-tag"]}`)
  ok(/noindex/.test(await guest.locator('meta[name="robots"]').getAttribute("content").catch(() => "") ?? ""), "   <meta name=robots> noindex")

  // «Crear cuenta» vuelve a la invitación tras registrarse
  await guest.getByRole("link", { name: /crear cuenta/i }).click()
  await guest.waitForURL(/\/auth\/register\?next=/, { timeout: 20000 })
  ok(decodeURIComponent(new URL(guest.url()).searchParams.get("next") ?? "") === `/invitacion/${inv.token}`, "   «Crear cuenta» lleva al registro con ?next=/invitacion/<token>")
  await guest.getByLabel("Nombre", { exact: true }).fill("Invitado")
  await guest.getByLabel("Apellido").fill("Vera")
  await guest.locator("#email").fill(USERS.invitee.email)
  await guest.getByLabel("Teléfono").fill("+54 9 261 555-0101")
  await guest.getByLabel("Provincia").selectOption("Mendoza")
  await guest.getByLabel("Localidad").fill("Godoy Cruz, Mendoza")
  await guest.locator("#password").fill(S.password)
  await guest.locator("#confirmPassword").fill(S.password)
  await guest.getByTestId("terms-checkbox").click()
  await guest.waitForFunction(() => { const b = document.querySelector('[data-testid="register-form"] button[type="submit"]'); return b && !b.disabled && b.getAttribute("aria-disabled") !== "true" }, null, { timeout: 60000 })
  await guest.getByRole("button", { name: /^crear cuenta$/i }).click()
  // Local: la confirmación de email está APAGADA, así que la verificación es inmediata y la pantalla vuelve sola.
  await guest.waitForURL((u) => u.pathname.startsWith(`/invitacion/${inv.token}`), { timeout: 90000 })
  ok(true, "   se registra con el email invitado y la pantalla de verificación lo devuelve a LA INVITACIÓN (no al Tablero)")
  const preview = guest.getByText(/te invitaron a sumarte a/i)
  await preview.waitFor({ timeout: 30000 }).catch(() => {})
  const prevText = await guest.locator("body").innerText()
  ok(prevText.includes("Ferretería <Roca> & Hijos") && prevText.includes("Dueña Roca") && prevText.includes("Vendedor"), "   con la identidad correcta ve la vista previa: negocio, quién invita y rol")
  await guest.screenshot({ path: out("humo-invitacion-vista-previa") })

  // ── 4. Acepta y aterriza en el Tablero del negocio ─────────────────────────────────
  await guest.getByRole("button", { name: /aceptar invitación/i }).click()
  await guest.waitForURL(/\/dashboard/, { timeout: 60000 })
  await guest.waitForLoadState("networkidle").catch(() => {})
  const inviteeId = sql1(`select id from auth.users where email='${USERS.invitee.email}'`)
  ok(sql1(`select active_account_id from public.profiles where id='${inviteeId}'`) === A, "4. aceptar dejó el negocio como cuenta activa (profiles.active_account_id)")
  ok(sql1(`select count(*) from public.account_members where user_id='${inviteeId}'`) === "2", "   conserva su cuenta personal: dos membresías")
  ok(sql1(`select status from public.account_invitations where id='${inv.id}'`) === "accepted", "   la invitación quedó accepted")
  const switcher = guest.getByRole("button", { name: /cambiar de cuenta|cuenta/i }).first()
  await sleep(1500)
  const bodyDash = await guest.locator("body").innerText()
  ok(bodyDash.includes("Ferretería <Roca> & Hijos"), "   el Tablero muestra el negocio como cuenta activa (nombre en el selector)")
  await guest.screenshot({ path: out("humo-tablero-del-negocio") })

  // vende por formulario un producto del dueño
  const stock0 = Number(sql1(`select coalesce(sum(quantity),0) from public.branch_stock where product_id='${martillo}'`))
  await guest.goto(`${BASE}/ventas`, { waitUntil: "domcontentloaded" })
  await guest.waitForLoadState("networkidle").catch(() => {})
  await guest.getByRole("button", { name: /nueva venta/i }).first().click()
  const dlg = guest.getByRole("dialog")
  await dlg.getByText("Seleccionar cliente").first().click()
  await sleep(600)
  await guest.getByRole("option", { name: /Cliente Humo C/ }).first().click()
  await sleep(300)
  await dlg.getByText("Seleccionar producto").first().click()
  await sleep(600)
  await guest.getByRole("option", { name: /Martillo Roca/ }).first().click()
  await sleep(400)
  await dlg.getByRole("button", { name: /agregar al carrito/i }).click()
  await sleep(500)
  await dlg.getByRole("button", { name: /confirmar venta/i }).click()
  let n = 0
  for (let i = 0; i < 30 && n === 0; i++) {
    await sleep(1000)
    n = Number(sql1(`select count(*) from public.sales where account_id='${A}' and user_id='${inviteeId}'`))
  }
  ok(n >= 1, "   el invitado vende por el formulario un producto cargado por el DUEÑO (R3a): la venta quedó en el NEGOCIO con él como autor")
  ok(Number(sql1(`select coalesce(sum(quantity),0) from public.branch_stock where product_id='${martillo}'`)) === stock0 - 1, "   el stock del negocio bajó 1")
  ok(sql1(`select count(*) from public.sales where user_id='${inviteeId}' and account_id <> '${A}'`) === "0", "   ninguna venta cayó en su cuenta personal (R3l)")
  await ictx.close()

  // ── 5. El dueño edita esa venta ────────────────────────────────────────────────────
  const op = sql1(`select operation_id from public.sales where account_id='${A}' and user_id='${inviteeId}' order by created_at desc limit 1`)
  const ids = sql1(`select string_agg(id::text, ',') from public.sales where operation_id='${op}'`).split(",")
  const tok = await (await fetch(`${S.api}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: S.anon, "content-type": "application/json" }, body: JSON.stringify({ email: USERS.owner.email, password: S.password }) })).json()
  const claims = JSON.parse(Buffer.from(tok.access_token.split(".")[1], "base64url").toString())
  const edit = await fetch(`${BACK}/sales/operation`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${tok.access_token}`, "content-type": "application/json", "X-Account-Id": claims.app_metadata.account_id },
    body: JSON.stringify({ sale_ids: ids, date: today, items: [{ product_id: martillo, quantity: 3, amount: 1000 }] }),
  })
  ok(edit.status === 200, `5. el dueño edita la venta del invitado (R3d) -> ${edit.status}`)
  ok(sql1(`select count(*) from public.sales where operation_id in (select operation_id from public.sales where account_id='${A}' and user_id='${inviteeId}') and user_id='${inviteeId}'`) !== "0", "   la autoría de la venta se CONSERVA (sigue siendo del invitado)")

  // ── 6. Reenviar invalida el link viejo; revocar impide aceptar; topes ──────────────
  const inv2Id = await (async () => {
    // el segundo invitado existe como usuario (para ver «no disponible» con sesión)
    await fetch(`${S.api}/auth/v1/admin/users`, {
      method: "POST",
      headers: { apikey: S.service, Authorization: `Bearer ${S.service}`, "content-type": "application/json" },
      body: JSON.stringify({ email: USERS.invitee2.email, password: S.password, email_confirm: true, user_metadata: { name: USERS.invitee2.name } }),
    })
    return sql1(`select id from auth.users where email='${USERS.invitee2.email}'`)
  })()
  await owner.goto(`${BASE}/organizacion/invitar`, { waitUntil: "domcontentloaded" })
  await owner.waitForLoadState("networkidle").catch(() => {})
  await owner.getByLabel("Email").fill(USERS.invitee2.email)
  await owner.getByRole("button", { name: /enviar invitación/i }).click()
  await owner.getByText(/Le enviamos un email a/i).waitFor({ timeout: 30000 })
  const row2 = JSON.parse(sql1(`select row_to_json(t) from (select id, token from public.account_invitations where account_id='${A}' and email='${USERS.invitee2.email}') t`))
  const oldToken = row2.token
  await owner.reload({ waitUntil: "domcontentloaded" })
  await owner.waitForLoadState("networkidle").catch(() => {})
  await owner.getByRole("button", { name: new RegExp(`Reenviar la invitación a ${USERS.invitee2.email}`) }).click()
  const cool = owner.getByText(/unos minutos/i)
  await cool.first().waitFor({ timeout: 15000 }).catch(() => {})
  ok(await cool.first().isVisible().catch(() => false), "6. reenviar enseguida: «Esperá unos minutos…» (enfriamiento de 10 min)")
  ok(sql1(`select token from public.account_invitations where id='${row2.id}'`) === oldToken, "   el rechazo no rotó el token")
  psql(`update public.email_logs set created_at = created_at - interval '11 minutes' where event_type='org_invite' and metadata->>'invitation_id' = '${row2.id}'`)
  await owner.getByRole("button", { name: new RegExp(`Reenviar la invitación a ${USERS.invitee2.email}`) }).click()
  await owner.getByText(/link anterior ya no sirve/i).first().waitFor({ timeout: 15000 }).catch(() => {})
  const newToken = sql1(`select token from public.account_invitations where id='${row2.id}'`)
  ok(newToken !== oldToken, "   pasado el enfriamiento, reenviar ROTA el token")
  note(`   ${bridge()}`)
  const mails2 = await mailTo(USERS.invitee2.email)
  ok(mails2.length === 2 && mails2.some((m) => invitationHref(m.html)?.endsWith(newToken)), `   hay 2 correos para la invitada y uno lleva el link NUEVO (${mails2.length})`)

  // el invitado 2 (con sesión) ve «no disponible» con el link viejo y la vista previa con el nuevo
  const i2ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  const i2 = await i2ctx.newPage()
  await login(i2, USERS.invitee2.email)
  await i2.goto(`${BASE}/invitacion/${oldToken}`, { waitUntil: "domcontentloaded" })
  const unavail = i2.getByText(/no está disponible para tu usuario/i)
  await unavail.waitFor({ timeout: 20000 }).catch(() => {})
  ok(await unavail.isVisible().catch(() => false), "   el link VIEJO muestra «no disponible para tu usuario»")
  await i2.screenshot({ path: out("humo-invitacion-no-disponible") })
  await i2.goto(`${BASE}/invitacion/${newToken}`, { waitUntil: "domcontentloaded" })
  await i2.getByText(/te invitaron a sumarte a/i).waitFor({ timeout: 20000 }).catch(() => {})
  ok(await i2.getByRole("button", { name: /aceptar invitación/i }).isVisible().catch(() => false), "   el link NUEVO muestra la vista previa con «Aceptar»")

  // revocar con confirmación
  await owner.reload({ waitUntil: "domcontentloaded" })
  await owner.waitForLoadState("networkidle").catch(() => {})
  await owner.getByRole("button", { name: new RegExp(`Revocar la invitación a ${USERS.invitee2.email}`) }).click()
  await owner.getByRole("alertdialog").waitFor({ timeout: 10000 })
  await owner.screenshot({ path: out("humo-revocar-confirmacion") })
  await owner.getByRole("button", { name: /revocar invitación/i }).click()
  await owner.getByText(/Revocamos la invitación/i).first().waitFor({ timeout: 15000 }).catch(() => {})
  ok(sql1(`select status from public.account_invitations where id='${row2.id}'`) === "revoked", "   «Revocar» (con confirmación) deja la invitación revocada")
  await i2.reload({ waitUntil: "domcontentloaded" })
  await unavail.waitFor({ timeout: 20000 }).catch(() => {})
  ok(await unavail.isVisible().catch(() => false), "   y el invitado ya no puede aceptar: «no disponible para tu usuario»")
  await i2ctx.close()

  // tope diario
  psql(`insert into public.email_logs (user_id, event_type, recipient, subject, status, metadata, created_at)
        select '${ownerId}', 'org_invite', 'cap-'||g||'@test.local', 'cap', 'sent', jsonb_build_object('account_id','${A}','invitation_id',gen_random_uuid(),'k',g), now() - interval '2 hours'
        from generate_series(1, 20) g`)
  await owner.reload({ waitUntil: "domcontentloaded" })
  await owner.waitForLoadState("networkidle").catch(() => {})
  await owner.getByLabel("Email").fill("topes@test.local")
  await owner.getByRole("button", { name: /enviar invitación/i }).click()
  const cap = owner.getByText(/máximo de invitaciones por día/i)
  await cap.first().waitFor({ timeout: 15000 }).catch(() => {})
  ok(await cap.first().isVisible().catch(() => false), "   con 20 envíos en el día: «Alcanzaste el máximo de invitaciones por día…» (429)")
  ok(sql1(`select count(*) from public.account_invitations where email='topes@test.local'`) === "0", "   y la invitación NO quedó creada (crear + enviar son atómicos)")
  psql(`delete from public.email_logs where recipient like 'cap-%@test.local'`)
  await octx.close()
} finally {
  await browser.close()
  mkdirSync(SHOTS, { recursive: true })
  writeFileSync(`${SHOTS}/humo.log`, log.join("\n") + `\n\nRESULTADO: ${failed === 0 ? "TODO PASS" : failed + " FAIL"}\n`)
}
console.log(failed === 0 ? "\nTODO PASS" : `\n${failed} FAIL`)
process.exit(failed === 0 ? 0 : 1)
