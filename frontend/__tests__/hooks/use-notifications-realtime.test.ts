/**
 * auth-hardening-jwt-cookies — Parte C, D1, tasks 19.6 y 19.9.
 *
 * El cliente de navegador pasa de `createBrowserClient` (que leía la cookie) a
 *
 *     createClient(url, anonKey, { accessToken: () => getAccessToken() })
 *
 * y con eso REST, Storage, Functions **y Realtime** toman el token del callback
 * (`supabase-js/index.mjs:135-138`, `:395`, `:527`).
 *
 * ── El gotcha que este archivo existe para fijar ────────────────────────────
 *
 * `supabase-js` llama `this.realtime.setAuth(token)` con un token **explícito**
 * al construir el cliente (`index.mjs:398`), y la documentación de `realtime-js`
 * dice qué implica:
 *
 *   "When a token is explicitly provided, it will be preserved across channel
 *    operations (including removeChannel and resubscribe). The `accessToken`
 *    callback will not be invoked until `setAuth()` is called without arguments."
 *   (`RealtimeClient.js:330-339`; la renovación automática está condicionada a
 *    `accessTokenValue` nulo, `:479`)
 *
 * O sea: el canal queda **pinneado** al token con que se construyó el cliente. Si
 * la renovación llamara `setAuth(await getAccessToken())`, el pin se perpetúa y
 * `use-notifications` + `FiscalDocumentBadge` se quedan **mudos al primer
 * vencimiento, sin ningún error visible** — la clase de falla que nadie reporta
 * porque no se ve.
 *
 * Por eso la renovación llama `realtime.setAuth()` **sin argumentos**, una sola
 * vez y en un solo lugar (`lib/supabase/client.ts`), no en cada hook que abre un
 * canal.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { RealtimeClient } from "@supabase/supabase-js"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

const SUPABASE_URL = "https://project.supabase.co"
const ANON_KEY = "anon-key-de-prueba"
const TOKEN = "access-token-1"
const NEXT_TOKEN = "access-token-2"

type ClientModule = typeof import("@/lib/supabase/client")
type Store = typeof import("@/lib/auth/access-token-store")

/**
 * Detalle interno de `realtime-js` que el control de no-vacuidad necesita: es
 * cómo la librería recuerda que el token está pinneado (`RealtimeClient.js:479`
 * condiciona la renovación automática a que NO lo esté). No está en los tipos
 * públicos, así que se declara acá en vez de recurrir a `any`.
 */
interface RealtimeTokenInternals {
  _isManualToken(): boolean
}

const internalsOf = (realtime: unknown) => realtime as RealtimeTokenInternals

let fetchMock: ReturnType<typeof vi.fn>
let setAuthSpy: ReturnType<typeof vi.spyOn<RealtimeClient, "setAuth">>

const expiresIn = (seconds: number) => Math.floor(Date.now() / 1000) + seconds

function respondWith(...tokens: string[]): void {
  for (const token of tokens) {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        access_token: token,
        expires_at: expiresIn(3600),
        user: { id: "u-1", email: "duenio@test.local" },
      }),
    } as unknown as Response)
  }
}

/** Módulos frescos: el store y el cliente son singletons de módulo. */
async function load(): Promise<{ client: ClientModule; store: Store }> {
  vi.resetModules()
  const store = (await import("@/lib/auth/access-token-store")) as Store
  const client = (await import("@/lib/supabase/client")) as ClientModule
  return { client, store }
}

/** Llamadas a `setAuth` que NO llevaron argumentos. */
function noArgCalls(): unknown[][] {
  return setAuthSpy.mock.calls.filter((call: unknown[]) => call.length === 0)
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", SUPABASE_URL)
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", ANON_KEY)
  fetchMock = vi.fn()
  vi.stubGlobal("fetch", fetchMock)
  // El espía va en el prototipo para capturar TAMBIÉN la llamada del constructor
  // de supabase-js, que es la que pone el pin.
  setAuthSpy = vi.spyOn(RealtimeClient.prototype, "setAuth")
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe("cliente de navegador — el token viene del callback", () => {
  it("configura `accessToken` y con eso Realtime recibe el callback", async () => {
    respondWith(TOKEN)
    const { client } = await load()

    const supabase = client.createClient()

    expect(typeof supabase.realtime.accessToken).toBe("function")
    expect(await supabase.realtime.accessToken!()).toBe(TOKEN)
  })

  it("`supabase.auth` LANZA: ninguna pantalla puede seguir usándolo", async () => {
    respondWith(TOKEN)
    const { client } = await load()

    const supabase = client.createClient()

    // Es la prueba de por qué 19.7 y 19.8 tienen que migrar los 29 archivos: con
    // `accessToken` configurado, `this.auth` es un Proxy que lanza en cualquier
    // acceso (`supabase-js/index.mjs:389`).
    expect(() => supabase.auth.getUser()).toThrow(/accessToken/)
    expect(() => supabase.auth.getSession()).toThrow(/accessToken/)
    expect(() => supabase.auth.onAuthStateChange(() => {})).toThrow(/accessToken/)
  })

  it("es un singleton: una sola conexión de Realtime por pestaña", async () => {
    respondWith(TOKEN)
    const { client } = await load()

    // `createBrowserClient` cacheaba el cliente en el navegador
    // (`createBrowserClient.js:8-14`). Perder esa propiedad al cambiar de
    // constructor abriría un websocket por cada `createClient()` del árbol.
    expect(client.createClient()).toBe(client.createClient())
  })
})

// ── 19.9 ────────────────────────────────────────────────────────────────────
describe("Realtime — la renovación llama setAuth() SIN argumentos", () => {
  it("tras una renovación hay una llamada sin argumentos", async () => {
    respondWith(TOKEN, NEXT_TOKEN)
    const { client, store } = await load()
    client.createClient()

    // El pin del constructor: una llamada CON token.
    await vi.waitFor(() => expect(setAuthSpy).toHaveBeenCalled())
    expect(setAuthSpy.mock.calls.some((call: unknown[]) => call.length === 1)).toBe(true)

    await store.refreshAccessToken()

    await vi.waitFor(() => expect(noArgCalls().length).toBeGreaterThan(0))
  })

  it("y el canal queda con el token NUEVO, no con el del arranque", async () => {
    respondWith(TOKEN, NEXT_TOKEN)
    const { client, store } = await load()
    const supabase = client.createClient()

    await vi.waitFor(() => expect(supabase.realtime.accessTokenValue).toBe(TOKEN))

    await store.refreshAccessToken()

    // Ésta es la aserción que importa: si la renovación llamara `setAuth(token)`,
    // el pin seguiría puesto y el valor se quedaría en el del arranque en cuanto
    // el canal se reconecte.
    await vi.waitFor(() => expect(supabase.realtime.accessTokenValue).toBe(NEXT_TOKEN))
  })

  it("el callback se vuelve a invocar después de la llamada sin argumentos", async () => {
    respondWith(TOKEN, NEXT_TOKEN)
    const { client, store } = await load()
    const supabase = client.createClient()
    await vi.waitFor(() => expect(supabase.realtime.accessTokenValue).toBe(TOKEN))

    await store.refreshAccessToken()
    await vi.waitFor(() => expect(noArgCalls().length).toBeGreaterThan(0))

    // Reconexión: `_setupConnectionHandlers` sólo vuelve a pedir el token por el
    // callback cuando NO hay un token manual pinneado (`RealtimeClient.js:479`).
    await supabase.realtime.setAuth()
    expect(await supabase.realtime.accessToken!()).toBe(NEXT_TOKEN)
  })

  // ── Control de no-vacuidad: el pin existe y SÓLO lo suelta la llamada sin
  // argumentos ───────────────────────────────────────────────────────────────
  //
  // Se hace sobre un cliente **desnudo** —construido acá, sin pasar por
  // `lib/supabase/client.ts`— justo porque nuestro módulo despinnea solo: con el
  // suscriptor puesto, el pin se suelta en la siguiente renovación y el gotcha
  // deja de ser observable. Éste es el comportamiento de la librería que hace
  // necesario ese suscriptor.
  it("el pin del constructor es real y sólo lo suelta setAuth() sin argumentos", async () => {
    const { createClient: createBare } = await import("@supabase/supabase-js")
    let current = TOKEN
    const bare = createBare(SUPABASE_URL, ANON_KEY, { accessToken: async () => current })

    // 1. El constructor pinnea con un token explícito (`index.mjs:398`).
    await vi.waitFor(() => expect(bare.realtime.accessTokenValue).toBe(TOKEN))
    expect(internalsOf(bare.realtime)._isManualToken()).toBe(true)

    // 2. El token del store cambia, pero nadie vuelve a preguntarle al callback.
    current = NEXT_TOKEN
    await bare.realtime.setAuth("token-pinneado-a-mano")
    expect(internalsOf(bare.realtime)._isManualToken()).toBe(true)
    expect(bare.realtime.accessTokenValue).toBe("token-pinneado-a-mano")

    // 3. Sólo la llamada SIN argumentos devuelve el control al callback.
    await bare.realtime.setAuth()
    expect(internalsOf(bare.realtime)._isManualToken()).toBe(false)
    expect(bare.realtime.accessTokenValue).toBe(NEXT_TOKEN)
  })

  it("al perder la sesión el canal también se re-evalúa", async () => {
    respondWith(TOKEN)
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({ access_token: null, expires_at: null, user: null }),
    } as unknown as Response)
    const { client, store } = await load()
    const supabase = client.createClient()
    await vi.waitFor(() => expect(supabase.realtime.accessTokenValue).toBe(TOKEN))

    await store.refreshAccessToken()

    await vi.waitFor(() => expect(noArgCalls().length).toBeGreaterThan(0))
  })
})

// ── El cableado vive en UN solo lugar ───────────────────────────────────────
describe("el re-enganche de Realtime no está copiado en los hooks", () => {
  const CHANNEL_CONSUMERS = [
    "hooks/data/use-notifications.ts",
    "components/fiscal/FiscalDocumentBadge.tsx",
  ]

  it.each(CHANNEL_CONSUMERS)("%s abre su canal con el cliente canónico", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    expect(source).toContain("@/lib/supabase/client")
    expect(source).toMatch(/\.channel\(/)
  })

  it.each(CHANNEL_CONSUMERS)("%s NO llama setAuth por su cuenta", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    expect(source).not.toContain("setAuth")
  })

  it("y el único sitio que lo llama es el módulo del cliente", () => {
    const source = fs.readFileSync(path.join(FRONTEND, "lib/supabase/client.ts"), "utf8")
    // Sin argumentos, literal: `setAuth(` con algo adentro sería el pin.
    expect(source).toMatch(/setAuth\(\)/)
  })
})
