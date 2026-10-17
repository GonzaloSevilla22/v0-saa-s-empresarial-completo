// Utilidades del humo local (multiusuario-operativo tanda A). Nada de esto se commitea.
import { execFileSync } from "node:child_process"
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs"

export const WT = "C:/Users/Usuario/Desktop/EIE/wt-multiusuario-b"
export const HUMO = "C:/Users/Usuario/AppData/Local/Temp/claude/C--Users-Usuario-Desktop-EIE-v0-saa-s-empresarial-completo/a1b376e9-d71b-476d-836f-f45b5fc02ca0/scratchpad/humo-b"
export const SHOTS = `${WT}/openspec/changes/multiusuario-operativo/evidence/tanda-b`
export const CONTAINER = "supabase_db_v0-saa-s-empresarial-completo"

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

export function loadSecrets() {
  const p = `${HUMO}/secrets.json`
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null
}

export function saveSecrets(obj) {
  mkdirSync(HUMO, { recursive: true })
  writeFileSync(`${HUMO}/secrets.json`, JSON.stringify(obj))
}

export const USERS = {
  solo: { email: "humo-solo@test.local", name: "Solo Uno", business: "Solo Negocio" },
  owner: { email: "humo-owner@test.local", name: "Dueña Roca", business: "Ferretería Roca" },
  multi: { email: "humo-multi@test.local", name: "Multi Dos", business: "Mi Kiosco" },
}
