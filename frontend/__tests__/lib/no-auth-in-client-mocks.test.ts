/**
 * auth-hardening-jwt-cookies — Parte C, D1, task 19.7b.
 *
 * En el espíritu del requisito ya vigente *"Los dobles de test no pueden divergir
 * del contrato real"* (`openspec/specs/backend-auth/spec.md`).
 *
 * El inventario de 17.2b midió **45** archivos de test que mockean
 * `@/lib/supabase/client`, de los cuales **22** exponían `auth` en el doble. Ese
 * `auth` ya no existe: con `accessToken` configurado, `supabase.auth` es un Proxy
 * que **lanza** en cualquier acceso (`supabase-js/index.mjs:389`). Un doble que lo
 * siga ofreciendo deja la suite en verde mientras producción explota — el modo de
 * falla más caro que puede tener una suite, porque su señal dice lo contrario de
 * la realidad.
 *
 * Este candado falla si un `vi.mock("@/lib/supabase/client", …)` expone `auth`.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")
const TESTS = path.join(FRONTEND, "__tests__")

const MOCK_TARGETS = ['vi.mock("@/lib/supabase/client"', "vi.mock('@/lib/supabase/client'"]

function walk(dir: string, found: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) walk(full, found)
    else if (/\.tsx?$/.test(entry.name)) found.push(full)
  }
  return found
}

/**
 * Cuerpo de la fábrica del `vi.mock`, desde el paréntesis de apertura hasta el
 * que lo cierra (balanceado). Se necesita el balanceo y no un `}))` al final de
 * línea: hay dobles anidados con varios niveles y un `indexOf` cortaría de más o
 * de menos.
 */
export function mockFactoryBodies(source: string): string[] {
  const bodies: string[] = []
  for (const target of MOCK_TARGETS) {
    let from = source.indexOf(target)
    while (from !== -1) {
      const open = source.indexOf("(", from)
      let depth = 0
      let end = -1
      for (let i = open; i < source.length; i += 1) {
        if (source[i] === "(") depth += 1
        else if (source[i] === ")") {
          depth -= 1
          if (depth === 0) {
            end = i
            break
          }
        }
      }
      bodies.push(source.slice(open, end === -1 ? source.length : end + 1))
      from = source.indexOf(target, from + target.length)
    }
  }
  return bodies
}

/** ¿El doble ofrece un `auth`? */
function exposesAuth(body: string): boolean {
  return /\bauth\s*:/.test(body)
}

/**
 * Identificadores que la fábrica **devuelve** en vez de declarar en línea:
 * `createClient: () => clienteDoble`, `createClient: vi.fn(() => doble)`,
 * `default: supabaseDouble`.
 *
 * Revisión adversarial pre-merge: el candado leía sólo el texto de adentro del
 * `vi.mock(...)`, así que con este patrón —el más frecuente entre los dobles que la
 * Parte C migró— no inspeccionaba nada.
 */
export function referencedIdentifiers(body: string): string[] {
  const names = new Set<string>()
  for (const match of body.matchAll(/=>\s*([A-Za-z_$][\w$]*)\s*[,)\s}]/g)) names.add(match[1])
  for (const match of body.matchAll(/:\s*([A-Za-z_$][\w$]*)\s*[,}]/g)) names.add(match[1])
  for (const match of body.matchAll(/\breturn\s+([A-Za-z_$][\w$]*)\b/g)) names.add(match[1])
  // `vi`, `undefined` y compañía no son dobles; no declaran nada en el archivo, así
  // que la resolución de abajo simplemente no los encuentra.
  return [...names]
}

/**
 * Cuerpo de la declaración de un identificador del archivo (`const doble = {…}`),
 * con paréntesis y llaves balanceados. `null` si no se declara acá.
 */
export function declarationBody(source: string, name: string): string | null {
  const declaration = new RegExp(String.raw`\b(?:const|let|var)\s+${name}\b[^=\n]*=`)
  const match = declaration.exec(source)
  if (!match) return null

  let depth = 0
  let started = false
  const from = match.index + match[0].length
  for (let i = from; i < source.length; i += 1) {
    const char = source[i]
    if (char === "{" || char === "(" || char === "[") {
      depth += 1
      started = true
    } else if (char === "}" || char === ")" || char === "]") {
      depth -= 1
      if (started && depth === 0) return source.slice(from, i + 1)
    } else if (!started && char === "\n") {
      // Declaración de una sola línea sin literal (`const x = y`): no hay cuerpo.
      return source.slice(from, i)
    }
  }
  return source.slice(from)
}

/**
 * Todo el texto que hay que inspeccionar por cada `vi.mock` del cliente: el cuerpo
 * de la fábrica **más** la declaración de los dobles que devuelve por referencia.
 */
export function mockScopes(source: string): string[] {
  const bodies = mockFactoryBodies(source)
  if (bodies.length === 0) return []

  const scopes = [...bodies]
  for (const identifier of referencedIdentifiers(bodies.join("\n"))) {
    const declared = declarationBody(source, identifier)
    if (declared !== null) scopes.push(declared)
  }
  return scopes
}

/**
 * El archivo del propio candado lleva dobles OFENSIVOS a propósito —son las
 * fixturas de los casos de no-vacuidad de abajo, en literales de plantilla— así
 * que se excluye del barrido. Se excluye por RUTA y no por heurística: una
 * heurística que distinga "fixtura" de "doble real" es exactamente la clase de
 * cosa que después deja pasar un doble real.
 */
const SELF = path.join(TESTS, "lib", "no-auth-in-client-mocks.test.ts")

const TEST_FILES = walk(TESTS).filter((absolute) => absolute !== SELF)

const MOCKING_FILES = TEST_FILES.map((absolute) => ({
  file: path.relative(FRONTEND, absolute).replace(/\\/g, "/"),
  bodies: mockScopes(fs.readFileSync(absolute, "utf8")),
})).filter((entry) => entry.bodies.length > 0)

describe("ningún doble de @/lib/supabase/client expone auth", () => {
  it("el barrido encuentra los dobles del inventario de 17.2b", () => {
    // Si este número cayera a 0, el candado estaría inerte y no habría forma de
    // notarlo desde los otros casos.
    expect(MOCKING_FILES.length).toBeGreaterThan(20)
  })

  it("la exclusión del propio archivo es de UNO solo, y existe", () => {
    // Si `SELF` dejara de coincidir con un archivo real (un renombre), la
    // exclusión quedaría inerte y el candado volvería a marcarse a sí mismo; si se
    // ampliara a un directorio, taparía dobles reales.
    expect(fs.existsSync(SELF)).toBe(true)
    expect(TEST_FILES).not.toContain(SELF)
  })

  it("ninguno ofrece `auth`", () => {
    const offenders = MOCKING_FILES.filter((entry) => entry.bodies.some(exposesAuth))
    expect(offenders.map((o) => o.file)).toEqual([])
  })

  it("el detector reconoce un doble con auth (no es vacuo)", () => {
    const ofensivo = `
      vi.mock("@/lib/supabase/client", () => ({
        createClient: () => ({
          auth: { getSession: vi.fn() },
          from: vi.fn(),
        }),
      }))
    `
    const bodies = mockFactoryBodies(ofensivo)
    expect(bodies).toHaveLength(1)
    expect(exposesAuth(bodies[0])).toBe(true)
  })

  it("y no marca un doble que sólo mockea datos", () => {
    const inocente = `
      vi.mock("@/lib/supabase/client", () => ({
        createClient: () => ({ from: vi.fn(), rpc: vi.fn(), channel: vi.fn() }),
      }))
    `
    expect(exposesAuth(mockFactoryBodies(inocente)[0])).toBe(false)
  })

  it("el balanceo no se come el doble siguiente", () => {
    // Un `}))` al final de línea cortaría este caso en el lugar equivocado.
    const anidado = `
      vi.mock("@/lib/supabase/client", () => ({
        createClient: () => ({ from: () => ({ select: () => ({ eq: vi.fn() }) }) }),
      }))
      vi.mock("@/lib/api/python-client", () => ({ get: vi.fn() }))
    `
    const bodies = mockFactoryBodies(anidado)
    expect(bodies).toHaveLength(1)
    expect(bodies[0]).not.toContain("python-client")
  })

  it("encuentra los dos estilos de comillas", () => {
    const conSimples = `vi.mock('@/lib/supabase/client', () => ({ createClient: () => ({ auth: {} }) }))`
    expect(exposesAuth(mockFactoryBodies(conSimples)[0])).toBe(true)
  })

  // ── El doble definido AFUERA de la fábrica (revisión adversarial pre-merge) ─
  //
  // El candado leía sólo el texto de adentro del `vi.mock(...)`, así que un doble
  // declarado afuera y devuelto por la fábrica no se inspeccionaba nunca. Y no es
  // un patrón hipotético: es el que usan tres de las suites que esta misma Parte C
  // migró (`auth-context-session-bus.test.tsx:67`,
  // `session-identity-services.test.ts:83`, `use-statistics-ai.test.tsx:28`). Hoy
  // ninguna expone `auth`, pero el candado era inerte para la forma más frecuente
  // entre los dobles que el change dejó.
  it("detecta un `auth` en un doble declarado afuera y devuelto por la fábrica", () => {
    const evasivo = `
      const clienteDoble = {
        auth: { getSession: vi.fn() },
        from: vi.fn(),
      }
      vi.mock("@/lib/supabase/client", () => ({
        createClient: () => clienteDoble,
      }))
    `
    const scopes = mockScopes(evasivo)
    expect(scopes.some(exposesAuth)).toBe(true)
  })

  it("y no marca el mismo patrón cuando el doble externo no tiene `auth`", () => {
    const inocente = `
      const clienteDoble = {
        from: vi.fn(),
        channel: vi.fn(),
      }
      vi.mock("@/lib/supabase/client", () => ({
        createClient: () => clienteDoble,
      }))
    `
    expect(mockScopes(inocente).some(exposesAuth)).toBe(false)
  })

  it("también cuando la fábrica envuelve el doble en `vi.fn()`", () => {
    const envuelto = `
      const supabaseMock = { auth: { getUser: vi.fn() } }
      vi.mock("@/lib/supabase/client", () => ({
        createClient: vi.fn(() => supabaseMock),
      }))
    `
    expect(mockScopes(envuelto).some(exposesAuth)).toBe(true)
  })

  it("resuelve la declaración externa de las tres suites reales que usan el patrón", () => {
    // Sin esto, los casos de arriba podrían pasar con fixturas mientras la
    // resolución falla contra el árbol real (indentación, tipos, `as never`).
    const reales: Array<[string, string]> = [
      ["lib/auth-context-session-bus.test.tsx", "clienteDoble"],
      ["lib/session-identity-services.test.ts", "supabaseDouble"],
      ["use-statistics-ai.test.tsx", "supabaseMock"],
    ]
    for (const [file, identifier] of reales) {
      const source = fs.readFileSync(path.join(TESTS, file), "utf8")
      expect(referencedIdentifiers(mockFactoryBodies(source).join("\n")), file).toContain(
        identifier,
      )
      const scopes = mockScopes(source)
      // El scope resuelto es más que la fábrica: incluye el cuerpo del doble.
      expect(scopes.length, file).toBeGreaterThan(mockFactoryBodies(source).length)
    }
  })
})
