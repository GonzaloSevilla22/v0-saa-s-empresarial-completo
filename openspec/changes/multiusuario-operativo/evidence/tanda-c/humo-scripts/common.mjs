// Utilidades del humo local (multiusuario-operativo tanda C). Nada de esto va al producto: sólo evidencia.
import { execFileSync } from "node:child_process"
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs"

export const WT = "C:/Users/Usuario/Desktop/EIE/wt-multiusuario-c"
export const HUMO = "C:/Users/Usuario/AppData/Local/Temp/claude/C--Users-Usuario-Desktop-EIE-v0-saa-s-empresarial-completo/a1b376e9-d71b-476d-836f-f45b5fc02ca0/scratchpad/humo-c"
export const SHOTS = `${WT}/openspec/changes/multiusuario-operativo/evidence/tanda-c`
export const CONTAINER = "supabase_db_v0-saa-s-empresarial-completo"
export const BASE = "http://localhost:3000"
export const BACK = "http://127.0.0.1:8000"
export const MAILPIT = "http://127.0.0.1:54324"

export function statusEnv() {
  const out = execFileSync("npx", ["supabase", "status", "-o", "env"], { cwd: WT, shell: true, encoding: "utf8" })
  const env = {}
  for (const line of out.split(/\r?\n/)) {
    const i = line.indexOf("=")
    if (i < 1) continue
    env[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^"|"$/g, "")
  }
  return env
}

export function psql(sql) {
  return execFileSync("docker", ["exec", "-i", CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-At", "-v", "ON_ERROR_STOP=1"], {
    input: sql,
    encoding: "utf8",
  })
}
export const sql1 = (q) => psql(q).trim()

export function loadSecrets() {
  const p = `${HUMO}/secrets.json`
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null
}

export function saveSecrets(obj) {
  mkdirSync(HUMO, { recursive: true })
  writeFileSync(`${HUMO}/secrets.json`, JSON.stringify(obj))
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export const USERS = {
  owner: { email: "humoc-owner@test.local", name: "Dueña Roca", business: "Ferretería <Roca> & Hijos" },
  invitee: { email: "humoc-invitee@test.local", name: "Invitado Vera" },
  invitee2: { email: "humoc-invitee2@test.local", name: "Invitada Dos" },
  wrong: { email: "humoc-otra-identidad@test.local", name: "Otra Identidad" },
  other: { email: "humoc-zulema@test.local", name: "Otra Zulema", business: "Zulema Hnos" },
  seller: { email: "humoc-vendedor@test.local", name: "Vendedor Fijo" },
}

// ── Mailpit ────────────────────────────────────────────────────────────────
export async function mailTo(address) {
  const r = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:${address}`)}`)
  const list = await r.json()
  const out = []
  for (const m of list.messages ?? []) {
    const full = await (await fetch(`${MAILPIT}/api/v1/message/${m.ID}`)).json()
    out.push({ id: m.ID, subject: full.Subject, html: full.HTML, text: full.Text, created: m.Created })
  }
  return out
}
export async function clearMail() {
  await fetch(`${MAILPIT}/api/v1/messages`, { method: "DELETE" })
}
/** El primer href de la invitación en el HTML del email. */
export function invitationHref(html) {
  const m = [...html.matchAll(/href="([^"]*\/invitacion\/[^"]*)"/g)].map((x) => x[1])
  return m[0] ?? null
}
