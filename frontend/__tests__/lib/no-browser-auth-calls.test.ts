/**
 * auth-hardening-jwt-cookies — Parte C, D1, task 19.7.
 *
 * Con el cliente de navegador configurado con `accessToken` (19.6), **cualquier**
 * acceso a `supabase.auth.*` lanza en runtime: `this.auth` es un Proxy cuyo `get`
 * tira `"accessing supabase.auth.<prop> is not possible"`
 * (`supabase-js/index.mjs:389`). No hay deprecación, no hay aviso: la pantalla
 * explota la primera vez que se usa.
 *
 * El inventario congelado de 17.2 midió **32** archivos de navegador con esas
 * llamadas (más 9 que ya corrían en el servidor y siguen siendo legítimos). Este
 * candado recorre el árbol y falla si queda una.
 *
 * ── Cómo distingue navegador de servidor ────────────────────────────────────
 *
 * Por **capacidad**, no por una lista de nombres que envejece: un archivo tiene
 * derecho a `supabase.auth` si construye su cliente con un constructor de
 * servidor (`@/lib/supabase/server`, `@supabase/ssr` directo o el helper
 * compartido `@/lib/auth/route-session`). Cualquier otro archivo que lo toque está
 * usando el cliente de navegador, y en producción lanza.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

/** Árboles de código de aplicación. `__tests__/` y `e2e/` no son código. */
const ROOTS = ["app", "components", "hooks", "lib", "contexts", "providers"]

/**
 * Operaciones de `supabase.auth` que el inventario de 17.2 encontró en el árbol,
 * más las que la librería expone y alguien podría agregar mañana.
 */
const AUTH_OPERATIONS = [
  "getUser",
  "getSession",
  "getClaims",
  "signOut",
  "signIn",
  "signInWithPassword",
  "signInWithOtp",
  "signInWithOAuth",
  "signUp",
  "updateUser",
  "onAuthStateChange",
  "resetPasswordForEmail",
  "resend",
  "refreshSession",
  "setSession",
  "exchangeCodeForSession",
  "verifyOtp",
] as const

const AUTH_CALL = new RegExp(String.raw`auth\s*\.\s*(${AUTH_OPERATIONS.join("|")})\b`)

/** Marcas de que el cliente de ese archivo es de servidor. */
const SERVER_CLIENT_SOURCES = [
  "@/lib/supabase/server",
  "@supabase/ssr",
  "@/lib/auth/route-session",
]

function walk(dir: string, found: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === ".next") continue
      walk(full, found)
    } else if (/\.tsx?$/.test(entry.name)) {
      found.push(full)
    }
  }
  return found
}

const SOURCE_FILES = ROOTS.flatMap((root) => walk(path.join(FRONTEND, root)))

/** Líneas de código (sin comentarios ni strings de doc) de un archivo. */
function codeLines(absolute: string): string[] {
  return fs
    .readFileSync(absolute, "utf8")
    .split(/\r?\n/)
    .filter((line) => {
      const trimmed = line.trimStart()
      return (
        trimmed !== "" &&
        !trimmed.startsWith("//") &&
        !trimmed.startsWith("*") &&
        !trimmed.startsWith("/*")
      )
    })
}

function isServerFile(absolute: string): boolean {
  const source = fs.readFileSync(absolute, "utf8")
  if (/^\s*["']use server["']/m.test(source)) return true
  return SERVER_CLIENT_SOURCES.some((marker) => source.includes(marker))
}

const relative = (absolute: string) => path.relative(FRONTEND, absolute).replace(/\\/g, "/")

interface AuthUsage {
  file: string
  server: boolean
  lines: string[]
}

const USAGES: AuthUsage[] = SOURCE_FILES.map((absolute) => ({
  file: relative(absolute),
  server: isServerFile(absolute),
  lines: codeLines(absolute).filter((line) => AUTH_CALL.test(line)),
})).filter((usage) => usage.lines.length > 0)

describe("ningún código de navegador llama a supabase.auth", () => {
  it("el barrido encuentra archivos (el test no es vacuo por no leer nada)", () => {
    expect(SOURCE_FILES.length).toBeGreaterThan(200)
    // Y sigue habiendo llamadas legítimas en el servidor: si esto fuera 0, el
    // detector estaría roto, no el árbol limpio.
    expect(USAGES.length).toBeGreaterThan(0)
  })

  it("no queda ninguna llamada en código de navegador", () => {
    const offenders = USAGES.filter((usage) => !usage.server)
    const detail = offenders
      .map((usage) => `${usage.file}: ${usage.lines.map((l) => l.trim()).join(" | ")}`)
      .join("\n")
    expect(offenders.map((o) => o.file), `\n${detail}`).toEqual([])
  })

  it("las que quedan son todas de archivos con cliente de servidor", () => {
    // Aserción por capacidad, no por identidad de lista: lo que autoriza a un
    // archivo no es su nombre, es de dónde saca el cliente.
    for (const usage of USAGES) {
      expect(usage.server, `${usage.file} usa supabase.auth sin cliente de servidor`).toBe(true)
    }
  })

  it("el detector reconoce una llamada (no es vacuo por la regex)", () => {
    const ofensivas = [
      "const { data: { user } } = await supabase.auth.getUser()",
      "const { data: session } = await supabase.auth.getSession()",
      "supabase.auth.onAuthStateChange((event) => {})",
      "await supabase.auth.signOut({ scope: 'local' })",
      "await client.auth . refreshSession()",
    ]
    for (const line of ofensivas) expect(AUTH_CALL.test(line), line).toBe(true)
  })

  it("y no confunde otras cosas llamadas auth", () => {
    const inocentes = [
      'import { getAuthHeaders } from "@/lib/api/auth-headers"',
      "const headers = await getAuthHeaders()",
      "await supabase.realtime.setAuth()",
      'const { data } = await supabase.from("profiles").select("*")',
    ]
    for (const line of inocentes) expect(AUTH_CALL.test(line), line).toBe(false)
  })

  it("el cliente de navegador ya no puede construir un `auth`", () => {
    // La causa raíz: mientras el módulo pase `accessToken`, `supabase.auth` es un
    // Proxy que lanza. Si alguien lo quitara, el candado de arriba seguiría verde
    // y la regresión pasaría inadvertida.
    //
    // Se mira el CÓDIGO, no el archivo entero: el encabezado del módulo nombra
    // `createBrowserClient` para explicar de qué se viene, y eso no es una
    // llamada.
    const code = codeLines(path.join(FRONTEND, "lib/supabase/client.ts")).join("\n")
    expect(code).toContain("accessToken")
    expect(code).not.toContain("createBrowserClient")
  })
})
