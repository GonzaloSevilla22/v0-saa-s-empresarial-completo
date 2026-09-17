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

/**
 * Marcas de que el archivo **puede** construir un cliente de servidor.
 *
 * Es `createServerClient` y no `@supabase/ssr` (revisión adversarial pre-merge): el
 * paquete exporta también `createBrowserClient`, así que nombrarlo no distingue
 * servidor de navegador — el `lib/supabase/client.ts` anterior a esta parte, el
 * ofensor que el change tuvo que migrar, quedaba exento por esa vía.
 */
const SERVER_CLIENT_SOURCES = [
  "createServerClient",
  "@/lib/supabase/server",
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

/** Líneas de código (sin comentarios ni strings de doc) de una fuente. */
function codeOf(source: string): string[] {
  return source.split(/\r?\n/).filter((line) => {
    const trimmed = line.trimStart()
    return (
      trimmed !== "" &&
      !trimmed.startsWith("//") &&
      !trimmed.startsWith("*") &&
      !trimmed.startsWith("/*")
    )
  })
}

/** Líneas de código (sin comentarios ni strings de doc) de un archivo. */
function codeLines(absolute: string): string[] {
  return codeOf(fs.readFileSync(absolute, "utf8"))
}

/**
 * ¿La fuente tiene capacidad de servidor?
 *
 * Se mira el **código**, no la fuente cruda: los archivos que este change toca
 * quedan con prosa que nombra el patrón viejo ("antes usaba el cliente de
 * `@supabase/ssr`"), y un marcador que matchee comentarios exime a un módulo de
 * navegador por explicar de qué se viene. Cuatro módulos estaban exentos así, uno de
 * ellos justo donde vivía el `getSession()` del navegador antes de la Parte B
 * (`lib/api/python-client.ts`).
 */
export function hasServerCapability(source: string): boolean {
  if (/^\s*["']use server["']/m.test(source)) return true
  const code = codeOf(source).join("\n")
  return SERVER_CLIENT_SOURCES.some((marker) => code.includes(marker))
}

function isServerFile(absolute: string): boolean {
  return hasServerCapability(fs.readFileSync(absolute, "utf8"))
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

  // ── Precisión del marcador (revisión adversarial pre-merge) ──────────────
  //
  // El marcador era el nombre del **paquete** `@supabase/ssr`, buscado como
  // substring en la fuente **cruda**. Dos agujeros, los dos reales:
  //
  //  1. `@supabase/ssr` exporta también `createBrowserClient`, así que el paquete
  //     no distingue servidor de navegador. Medido: el `lib/supabase/client.ts`
  //     anterior a esta parte —el archivo que este change tuvo que migrar— daba
  //     `server = true`. El candado habría eximido justo al ofensor.
  //  2. `includes()` matchea comentarios, y estos archivos quedan con prosa que
  //     nombra el patrón viejo. Cuatro módulos alcanzables desde el navegador
  //     estaban exentos por mencionarlo en un comentario, uno de ellos
  //     (`lib/api/python-client.ts`) es exactamente donde vivía el `getSession()`
  //     del navegador antes de la Parte B.
  //
  // El marcador pasa a ser la **capacidad**: `createServerClient` (export que sólo
  // usa el servidor) o uno de los dos módulos de servidor del repo, en una línea de
  // código, no en un comentario.
  it("el marcador de servidor es una capacidad y no una mención", () => {
    expect(
      hasServerCapability(`// este módulo NO usa @supabase/ssr ni @/lib/supabase/server\nexport const x = 1`),
    ).toBe(false)
    expect(
      hasServerCapability(` * Convive con @/lib/auth/route-session, que sí es de servidor.\nexport const y = 2`),
    ).toBe(false)

    // El caso que más importa: el cliente de NAVEGADOR sale del mismo paquete.
    expect(
      hasServerCapability(`import { createBrowserClient } from "@supabase/ssr"\nexport const c = createBrowserClient(u, k)`),
    ).toBe(false)

    expect(
      hasServerCapability(`import { createServerClient } from "@supabase/ssr"`),
    ).toBe(true)
    expect(hasServerCapability(`import { createClient } from "@/lib/supabase/server"`)).toBe(true)
    expect(
      hasServerCapability(`import { serverClientForRequest } from "@/lib/auth/route-session"`),
    ).toBe(true)
    expect(hasServerCapability(`"use server"\nexport async function a() {}`)).toBe(true)
  })

  it("los cuatro módulos de navegador que estaban exentos por un comentario ya no lo están", () => {
    for (const file of [
      "lib/api/python-client.ts",
      "lib/cookies.ts",
      "lib/supabase/cookie-options.ts",
      "lib/auth/route-access.ts",
    ]) {
      expect(isServerFile(path.join(FRONTEND, file)), file).toBe(false)
    }
  })

  it("y los que sí son de servidor siguen reconocidos", () => {
    for (const file of [
      "lib/supabase/middleware.ts",
      "lib/auth/route-session.ts",
      "app/auth/actions.ts",
      "app/api/auth/token/route.ts",
      "app/(dashboard)/planes/page.tsx",
    ]) {
      expect(isServerFile(path.join(FRONTEND, file)), file).toBe(true)
    }
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
