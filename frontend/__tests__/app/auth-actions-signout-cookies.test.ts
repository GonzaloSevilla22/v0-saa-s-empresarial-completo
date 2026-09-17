// @vitest-environment node
/**
 * auth-hardening-jwt-cookies — Parte C, D1/D6. Revisión adversarial pre-merge
 * (MAJOR: escenario normativo sin una sola aserción ejecutable).
 *
 * La spec de `session-cookies` dice, del cierre de sesión manual:
 *
 *   > **THEN** el servidor revoca la sesión contra el proveedor **y borra las
 *   > cookies de sesión en la misma respuesta**
 *
 * La primera mitad estaba asertada (`auth-actions.test.ts` mira el `scope` con el
 * que se llama al proveedor). La segunda **no**: el borrado de cookies no lo hace
 * nuestro código, lo hace `@supabase/ssr` al pasar por `removeItem` → `setAll` con
 * `value: ""` y `maxAge: 0` (`cookies.js:192-210`), y un doble del cliente de
 * servidor —que es lo que usa la suite de acciones— no puede observarlo.
 *
 * Este archivo corre la acción contra el `createServerClient` **real** y doblando
 * sólo la red hacia GoTrue, con un almacén de cookies de mentira en el lugar de
 * `next/headers`. Así se observa lo que el escenario promete: la revocación y el
 * borrado, con los atributos compartidos, en la misma respuesta.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import {
  ANON_KEY,
  SESSION_COOKIE,
  SUPABASE_URL,
  gotrueDouble,
  jarWithSession,
  makeSession,
  type GoTrueDouble,
} from "../lib/helpers/gotrue-double"

// ── Almacén de cookies en el lugar de `next/headers` ────────────────────────

interface CookieSet {
  name: string
  value: string
  options?: Record<string, unknown>
}

const jar: Record<string, string> = {}
const written: CookieSet[] = []

const cookieStore = {
  getAll: () => Object.entries(jar).map(([name, value]) => ({ name, value })),
  set: (name: string, value: string, options?: Record<string, unknown>) => {
    written.push({ name, value, options })
    if (options?.maxAge === 0) delete jar[name]
    else jar[name] = value
  },
}

vi.mock("next/headers", () => ({
  cookies: () => cookieStore,
  headers: async () => new Headers({ host: "aliadata.com.ar", "x-forwarded-proto": "https" }),
}))

import { signOutAction } from "@/app/auth/actions"

let gotrue: GoTrueDouble
const realFetch = globalThis.fetch

/** ¿Esa escritura es un borrado? Valor vacío + expiración inmediata. */
function isDeletion(entry: CookieSet): boolean {
  return entry.value === "" && entry.options?.maxAge === 0
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", SUPABASE_URL)
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", ANON_KEY)
  vi.stubEnv("NODE_ENV", "production")

  for (const key of Object.keys(jar)) delete jar[key]
  Object.assign(jar, jarWithSession(makeSession()))
  written.length = 0

  gotrue = gotrueDouble({ user: undefined })
  globalThis.fetch = gotrue.fetch
})

afterEach(() => {
  globalThis.fetch = realFetch
  vi.unstubAllEnvs()
})

describe("signOutAction — revoca y borra en la misma respuesta", () => {
  it("revoca contra el proveedor con scope local", async () => {
    const result = await signOutAction()

    expect(result).toEqual({ ok: true })
    expect(gotrue.logoutCalls().length).toBe(1)
    // D6/OQ-3: el `signOut()` pelado de la librería es GLOBAL y tiraba abajo el POS
    // del mostrador cuando el dueño cerraba sesión en el celular.
    expect(gotrue.logoutCalls()[0].url).toContain("scope=local")
  })

  it("borra la cookie de sesión (la mitad del escenario que no estaba asertada)", async () => {
    await signOutAction()

    const sessionWrites = written.filter((entry) => entry.name.startsWith("sb-"))
    expect(sessionWrites.length).toBeGreaterThan(0)
    for (const entry of sessionWrites) {
      expect(isDeletion(entry), `${entry.name} no es un borrado: ${JSON.stringify(entry)}`).toBe(
        true,
      )
    }
    // Y el tarro queda efectivamente sin sesión.
    expect(jar[SESSION_COOKIE]).toBeUndefined()
  })

  it("el borrado lleva los atributos compartidos (una cookie con otro Path no se borra)", async () => {
    await signOutAction()

    const deletion = written.find((entry) => entry.name.startsWith("sb-") && isDeletion(entry))
    expect(deletion).toBeDefined()
    // El navegador sólo borra la cookie si el `Path` (y el resto de los atributos de
    // identidad) coinciden con los de la que se escribió.
    expect(deletion!.options).toMatchObject({ path: "/", sameSite: "lax", httpOnly: true })
    expect(deletion!.options).toHaveProperty("secure", true)
  })

  it("el scope global sigue siendo pedible y explícito (closeAllSessions)", async () => {
    await signOutAction({ scope: "global" })

    expect(gotrue.logoutCalls()[0].url).toContain("scope=global")
  })

  it("control: sin cierre de sesión no hay ningún borrado", async () => {
    // Sin este control no se sabría si los borrados de arriba los produce la acción
    // o el propio arranque del cliente de servidor.
    expect(written.filter(isDeletion)).toEqual([])
    expect(jar[SESSION_COOKIE]).toBeDefined()
  })
})
