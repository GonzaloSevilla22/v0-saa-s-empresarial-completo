/**
 * accounts-profiles-privilege-columns — candado estático: el navegador no
 * escribe columnas de privilegio.
 *
 * La migración 20261053000001 revoca el UPDATE de TABLA de `authenticated`
 * sobre `public.accounts` y `public.profiles`, y le devuelve por COLUMNA sólo
 * las 11 de perfil y preferencias. Cualquier `.from('profiles').update({...})`
 * con una clave fuera de esa allow-list, y cualquier escritura directa sobre
 * `accounts`, deja de funcionar en producción con
 * `42501 permission denied for table` — y lo hace en runtime, cuando el usuario
 * aprieta el botón, no en el build.
 *
 * Este candado es el espejo en el frontend de
 * `supabase/tests/test_accounts_privilege_columns.sql`: la misma allow-list,
 * comprobada del otro lado del cable. Si alguien agrega mañana una escritura de
 * `billing_plan` o un reseteo de contadores desde el navegador, falla acá en
 * lugar de fallar en producción.
 *
 * Origen concreto: `upgradePlan()` / `downgradePlan()` de
 * `contexts/auth-context.tsx` hacían `.from('profiles').update({plan})` desde el
 * navegador — un auto-otorgamiento de plan cableado a los botones "Actualizar a
 * Pro" / "Cambiar a Gratis" de `/configuracion`, que hasta hoy sólo fallaba
 * porque `trg_prevent_profile_escalation` lo rechazaba. Se retiraron y los
 * botones pasan a `/planes`, el camino real (MercadoPago).
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

/** Árboles de código de aplicación (`__tests__/` y `e2e/` no son código). */
const ROOTS = ["app", "components", "hooks", "lib", "contexts", "providers"]

/**
 * MISMA lista que el `GRANT UPDATE (...)` de la sección 2 de
 * 20261053000001_accounts_profiles_privilege_columns.sql y que
 * `v_allowed_profile_cols` del gate SQL.
 */
const PROFILE_WRITABLE_COLUMNS = new Set([
  "name",
  "last_name",
  "business_name",
  "phone",
  "locality",
  "bio",
  "avatar_url",
  "currency",
  "timezone",
  "date_format",
  "language",
])

function walk(dir: string, acc: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name.startsWith(".")) continue
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) walk(full, acc)
    else if (/\.(ts|tsx)$/.test(entry.name)) acc.push(full)
  }
  return acc
}

const FILES = ROOTS.flatMap((r) => {
  const dir = path.join(FRONTEND, r)
  return fs.existsSync(dir) ? walk(dir) : []
})

/**
 * Extrae los pares `.from('<tabla>')` … `.update(`/`.insert(`/`.delete(` del
 * texto, con el trozo que sigue al `.update(` para poder leer las claves.
 * Deliberadamente simple: es un detector, y un falso positivo se resuelve
 * agregando la columna a la allow-list de los DOS lados (acá y en la migración).
 */
interface TableWrite {
  file: string
  table: string
  op: string
  payload: string
}

function tableWrites(file: string, src: string): TableWrite[] {
  const out: TableWrite[] = []
  const re = /\.from\(\s*["'](accounts|profiles)["']\s*\)([\s\S]{0,400}?)\.(update|insert|delete|upsert)\(([\s\S]{0,400}?)\)/g
  let m: RegExpExecArray | null
  while ((m = re.exec(src)) !== null) {
    // Si entre el `.from()` y el `.update()` aparece otro `.from(`, el match
    // cruzó dos cadenas distintas: no es una escritura de esta tabla.
    if (m[2].includes(".from(")) continue
    out.push({ file, table: m[1], op: m[3], payload: m[4] })
  }
  return out
}

function payloadKeys(payload: string): string[] {
  // Claves de un objeto literal (`billing_plan:`, `"plan":`, `plan :`).
  return [...payload.matchAll(/(?:^|[{,\s])["']?([a-z_][a-z0-9_]*)["']?\s*:/gi)].map((m) => m[1])
}

describe("el navegador no escribe columnas de privilegio de accounts/profiles", () => {
  it("nadie escribe public.accounts por PostgREST (sólo RPCs SECURITY DEFINER o el backend)", () => {
    const offenders = FILES.flatMap((f) =>
      tableWrites(path.relative(FRONTEND, f).replace(/\\/g, "/"), fs.readFileSync(f, "utf8")),
    ).filter((w) => w.table === "accounts")

    expect(
      offenders.map((o) => `${o.file}: .from('accounts').${o.op}(`),
      "accounts no tiene NINGUNA columna escribible por `authenticated` (allow-list vacía en 20261053000001): toda escritura va por una RPC SECURITY DEFINER o por el contexto de servicio del backend",
    ).toEqual([])
  })

  it("los update de public.profiles sólo tocan columnas de la allow-list", () => {
    const bad: string[] = []
    for (const f of FILES) {
      const rel = path.relative(FRONTEND, f).replace(/\\/g, "/")
      for (const w of tableWrites(rel, fs.readFileSync(f, "utf8"))) {
        if (w.table !== "profiles") continue
        if (w.op !== "update") {
          bad.push(`${rel}: .from('profiles').${w.op}( — authenticated no tiene INSERT/DELETE sobre profiles`)
          continue
        }
        for (const key of payloadKeys(w.payload)) {
          if (!PROFILE_WRITABLE_COLUMNS.has(key)) {
            bad.push(`${rel}: .from('profiles').update({ ${key}: … }) — fuera de la allow-list`)
          }
        }
      }
    }

    expect(
      bad,
      "una columna fuera de la allow-list de 20261053000001 falla en producción con 42501 permission denied, en runtime y sin aviso en el build",
    ).toEqual([])
  })

  it("la allow-list del candado es la misma que la de la migración y la del gate SQL", () => {
    const migration = fs.readFileSync(
      path.resolve(FRONTEND, "..", "supabase", "migrations", "20261053000001_accounts_profiles_privilege_columns.sql"),
      "utf8",
    )
    const granted = migration
      .slice(migration.indexOf("GRANT UPDATE ("), migration.indexOf(") ON public.profiles TO authenticated"))
      .split("\n")
      .map((l) => l.trim().replace(/,$/, ""))
      .filter((l) => /^[a-z_]+$/.test(l))

    expect(new Set(granted)).toEqual(PROFILE_WRITABLE_COLUMNS)
  })
})
