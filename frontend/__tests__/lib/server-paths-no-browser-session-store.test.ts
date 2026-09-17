/**
 * auth-hardening-jwt-cookies — Parte C, D1. Revisión adversarial pre-merge
 * (BLOCKER: el store del navegador se metió en dos caminos que corren SÓLO en el
 * servidor).
 *
 * `lib/auth/access-token-store.ts` resuelve la identidad pidiéndole el token a
 * `GET /api/auth/token` con una ruta **relativa**, y por eso devuelve
 * `{ status: "unknown" }` en cuanto no hay `window` (`:208-212`). En el servidor
 * eso no es un modo degradado: `getSessionUser()` devuelve `null` **siempre**, así
 * que el camino que dependa de él falla el 100% de las veces. Y falla en silencio,
 * porque los dos sitios que lo llamaban estaban dentro de un `try/catch` y de un
 * `.catch()`.
 *
 * El síntoma medido en la revisión: `POST /api/ai/copilot` dejaba de persistir
 * **toda** conversación (`ai_conversations`) y de incluir el bloque de top
 * productos en el contexto de la IA.
 *
 * La causa raíz no es "esos dos archivos": es que **nada** impedía importar el
 * store del navegador desde un módulo alcanzable desde un Route Handler o una
 * Server Action. Este candado cierra eso por construcción: recorre el grafo de
 * importaciones desde cada entrada de servidor y falla si alcanza el store.
 *
 * ── Dónde para el recorrido ─────────────────────────────────────────────────
 *
 * En la frontera `"use client"`. Un módulo con esa directiva —y todo lo que
 * importe— corre en el navegador, que es justo donde el store **sí** es el camino
 * correcto. Sin esa parada, la primera pantalla cliente que un Server Component
 * renderice marcaría un falso positivo.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

/** El módulo que sólo tiene sentido en el navegador. */
const BROWSER_ONLY = "lib/auth/access-token-store"

const EXTENSIONS = [".ts", ".tsx"]

const relative = (absolute: string) => path.relative(FRONTEND, absolute).replace(/\\/g, "/")

function walk(dir: string, found: string[] = []): string[] {
  if (!fs.existsSync(dir)) return found
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

const APP_FILES = walk(path.join(FRONTEND, "app"))

function source(absolute: string): string {
  return fs.readFileSync(absolute, "utf8")
}

/** ¿Declara `"use client"` en su tope? Ahí termina el territorio del servidor. */
function isClientModule(absolute: string): boolean {
  return /^\s*["']use client["']/m.test(source(absolute))
}

/** ¿Declara `"use server"`? Entonces es una entrada de servidor. */
function isServerActionModule(absolute: string): boolean {
  return /^\s*["']use server["']/m.test(source(absolute))
}

/**
 * Entradas de servidor: los Route Handlers (`app/**\/route.ts`), los módulos de
 * Server Actions (`"use server"`) y el middleware. Son los tres contextos donde
 * no hay `window` y donde el store del navegador no puede funcionar.
 */
const SERVER_ENTRIES: string[] = [
  ...APP_FILES.filter((absolute) => /[\\/]route\.tsx?$/.test(absolute)),
  ...APP_FILES.filter(isServerActionModule),
  path.join(FRONTEND, "middleware.ts"),
].filter((absolute, index, all) => fs.existsSync(absolute) && all.indexOf(absolute) === index)

/**
 * Especificadores locales que el módulo carga **en runtime** (`@/…` y relativos;
 * nunca paquetes).
 *
 * Un `import type { X } from "…"` se borra al compilar: el módulo no se carga, así
 * que no puede arrastrar nada. Contarlo produce un falso positivo real y medido —
 * `app/actions/landing.ts` importa **sólo el tipo** `LandingSection` de
 * `lib/landing.ts`, que sí usa el cliente de navegador, y la primera versión de
 * este candado lo marcaba como si el Server Action dependiera de él.
 */
export function localImportSpecifiers(source: string): string[] {
  const specifiers: string[] = []
  const withFrom = /(?:^|[\s;{}])((?:import|export)\b[\s\S]*?)from\s*["']([^"']+)["']/g
  for (const match of source.matchAll(withFrom)) {
    const prefix = match[1]
    const lastKeyword = Math.max(prefix.lastIndexOf("import"), prefix.lastIndexOf("export"))
    const afterKeyword = prefix.slice(lastKeyword).replace(/^(?:import|export)/, "")
    // `import type {…} from` / `export type {…} from`: se borran al compilar.
    if (/^\s+type\s/.test(afterKeyword)) continue
    specifiers.push(match[2])
  }
  // `import("…")` dinámico y `import "…"` sin bindings.
  for (const match of source.matchAll(/import\s*\(\s*["']([^"']+)["']/g)) {
    specifiers.push(match[1])
  }
  for (const match of source.matchAll(/(?:^|\n)\s*import\s*["']([^"']+)["']/g)) {
    specifiers.push(match[1])
  }
  return specifiers.filter((s) => s.startsWith("@/") || s.startsWith("."))
}

function localImports(absolute: string): string[] {
  return localImportSpecifiers(source(absolute))
}

/** Resuelve un especificador local a un archivo del árbol, o `null`. */
export function resolveSpecifier(fromFile: string, specifier: string): string | null {
  const base = specifier.startsWith("@/")
    ? path.join(FRONTEND, specifier.slice(2))
    : path.resolve(path.dirname(fromFile), specifier)

  for (const candidate of [
    base,
    ...EXTENSIONS.map((ext) => `${base}${ext}`),
    ...EXTENSIONS.map((ext) => path.join(base, `index${ext}`)),
  ]) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate
  }
  return null
}

/**
 * Cadena de importaciones desde `entry` hasta el store del navegador, o `null` si
 * no lo alcanza. Devuelve la cadena (y no un booleano) porque el valor del
 * candado está en el mensaje: sin la cadena, el que lo rompa mañana ve "falla" sin
 * saber qué importó a qué.
 */
export function chainToBrowserStore(
  entry: string,
  options: { stopAtClientBoundary?: boolean } = {},
): string[] | null {
  const { stopAtClientBoundary = true } = options
  const seen = new Set<string>()
  const queue: Array<{ file: string; chain: string[] }> = [
    { file: entry, chain: [relative(entry)] },
  ]

  while (queue.length > 0) {
    const { file, chain } = queue.shift()!
    if (seen.has(file)) continue
    seen.add(file)

    // La frontera del navegador: de acá para abajo el store es correcto.
    if (stopAtClientBoundary && file !== entry && isClientModule(file)) continue

    for (const specifier of localImports(file)) {
      const resolved = resolveSpecifier(file, specifier)
      if (!resolved) continue
      const next = relative(resolved)
      if (next.replace(/\.tsx?$/, "") === BROWSER_ONLY) return [...chain, next]
      queue.push({ file: resolved, chain: [...chain, next] })
    }
  }

  return null
}

/** Módulos alcanzables desde una entrada, sin cruzar la frontera de cliente. */
function reachableFrom(entry: string): Set<string> {
  const seen = new Set<string>()
  const queue = [entry]
  while (queue.length > 0) {
    const file = queue.shift()!
    if (seen.has(file)) continue
    seen.add(file)
    if (file !== entry && isClientModule(file)) continue
    for (const specifier of localImports(file)) {
      const resolved = resolveSpecifier(file, specifier)
      if (resolved) queue.push(resolved)
    }
  }
  return seen
}

describe("ningún camino de servidor importa el store de token del navegador", () => {
  it("el barrido encuentra entradas de servidor de los tres tipos", () => {
    const routes = SERVER_ENTRIES.filter((f) => /[\\/]route\.tsx?$/.test(f))
    const actions = SERVER_ENTRIES.filter(isServerActionModule)

    expect(routes.length).toBeGreaterThan(3)
    expect(actions.map(relative)).toContain("app/auth/actions.ts")
    expect(SERVER_ENTRIES.map(relative)).toContain("middleware.ts")
  })

  it("el recorrido atraviesa el grafo de verdad (no es vacuo por no resolver nada)", () => {
    const fromCopilot = reachableFrom(path.join(FRONTEND, "app/api/ai/copilot/route.ts"))
    const alcanzados = [...fromCopilot].map(relative)

    // Dos saltos reales: la ruta importa el snapshot, que importa el canon de
    // ingresos. Si el resolvedor dejara de resolver `@/…`, esto cae.
    expect(alcanzados).toContain("lib/ai/buildBusinessSnapshot.ts")
    expect(alcanzados).toContain("lib/reporting/revenue-canon.ts")
    expect(fromCopilot.size).toBeGreaterThan(10)
  })

  it("ninguna entrada de servidor alcanza el store", () => {
    const offenders = SERVER_ENTRIES.map((entry) => ({
      entry: relative(entry),
      chain: chainToBrowserStore(entry),
    })).filter((usage) => usage.chain !== null)

    const detail = offenders.map((o) => o.chain!.join(" → ")).join("\n")
    expect(offenders.map((o) => o.entry), `\n${detail}`).toEqual([])
  })

  it("un `import type` no cuenta como dependencia de runtime, un import de valores sí", () => {
    // La precisión que este candado necesita para no ser ruido: `app/actions/landing.ts`
    // toma **sólo el tipo** `LandingSection` de `lib/landing.ts` (que usa el cliente
    // de navegador), y ese import desaparece al compilar.
    const soloTipo = `import type { LandingSection } from '@/lib/landing'`
    expect(localImportSpecifiers(soloTipo)).toEqual([])

    const valores = `import { getLandingSections } from '@/lib/landing'`
    expect(localImportSpecifiers(valores)).toEqual(["@/lib/landing"])

    // `import { type X, y }` sí carga el módulo: el tipo se borra, `y` no.
    const mixto = `import { type LandingSection, getLandingSections } from "@/lib/landing"`
    expect(localImportSpecifiers(mixto)).toEqual(["@/lib/landing"])

    // Y el caso real, entero: el Server Action no depende de `lib/landing`.
    const accionReal = source(path.join(FRONTEND, "app/actions/landing.ts"))
    expect(localImportSpecifiers(accionReal)).not.toContain("@/lib/landing")
    expect(localImportSpecifiers(accionReal)).toContain("@/lib/supabase/server")
  })

  it("el detector SÍ marca un camino de navegador que lo importa (control positivo)", () => {
    // `hooks/data/use-posts.ts` lo importa a propósito y es correcto que lo haga:
    // corre en el navegador. Se usa como control de que el detector encuentra el
    // store cuando está, en vez de estar siempre devolviendo `null`.
    const chain = chainToBrowserStore(path.join(FRONTEND, "hooks/data/use-posts.ts"))
    expect(chain).not.toBeNull()
    expect(chain!.at(-1)).toBe(`${BROWSER_ONLY}.ts`)
  })

  it("la frontera `use client` para el recorrido, y es ella la que evita el falso positivo", () => {
    // `app/layout.tsx` es un Server Component que renderiza `AuthProvider`, un
    // módulo `"use client"` que importa el store **a propósito** y correctamente
    // (`contexts/auth-context.tsx:25`). Es el falso positivo que la parada evita,
    // y la matriz se ejecuta en los dos sentidos: sin la parada, el mismo
    // recorrido sí lo alcanza.
    const layout = path.join(FRONTEND, "app/layout.tsx")
    expect(isClientModule(layout)).toBe(false)
    expect(isClientModule(path.join(FRONTEND, "contexts/auth-context.tsx"))).toBe(true)

    expect(chainToBrowserStore(layout)).toBeNull()

    const sinParada = chainToBrowserStore(layout, { stopAtClientBoundary: false })
    expect(sinParada).not.toBeNull()
    expect(sinParada!.join(" → ")).toContain("contexts/auth-context.tsx")
  })
})
