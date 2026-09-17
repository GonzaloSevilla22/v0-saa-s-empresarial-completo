/**
 * auth-hardening-jwt-cookies — Parte C, D1, task 19.10.
 *
 * Realtime tiene su propio archivo (`__tests__/hooks/use-notifications-realtime.test.ts`)
 * porque tiene un gotcha propio: el pin del token. **Storage, Functions y REST no
 * tienen gotcha** — y justamente por eso hay que fijarlos: son los tres
 * transportes que un lector asume que "siguen funcionando" sin comprobarlo, y si
 * el callback no los alimentara, el síntoma sería un 401 en subir un avatar o en
 * leer una factura con OCR, no un error de compilación.
 *
 * La comprobación es la que importa y no una aproximación: se construye el
 * cliente REAL de `lib/supabase/client.ts` y se mira el `Authorization` del
 * `fetch` que SALE. Mockear `fetchWithAuth` probaría que mockeamos bien.
 *
 * Lo que esto cubre, por archivo (los de la task 19.10):
 *  - Storage: `components/settings/AvatarUpload.tsx`,
 *    `lib/services/invoiceOcrService.ts` (upload + remove).
 *  - Functions: `lib/services/invoiceOcrService.ts`, `components/ai/ai-summary-card.tsx`,
 *    `lib/services/aiInsightService.ts`, `lib/services/fairAdvisorService.ts`,
 *    `lib/supabase/services.ts`.
 *  - REST: todos los hooks de datos.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

const SUPABASE_URL = "https://project.supabase.co"
const ANON_KEY = "anon-key-de-prueba"
const TOKEN = "access-token-de-la-sesion"

const getAccessTokenMock = vi.fn()

vi.mock("@/lib/auth/access-token-store", () => ({
  getAccessToken: () => getAccessTokenMock(),
  subscribeToAccessToken: () => () => {},
}))

let fetchMock: ReturnType<typeof vi.fn>

/** Respuesta genérica que le sirve a los tres transportes. */
function okResponse(body: unknown = {}): Response {
  return {
    ok: true,
    status: 200,
    headers: new Headers({ "content-type": "application/json" }),
    json: async () => body,
    text: async () => JSON.stringify(body),
    clone() {
      return this as unknown as Response
    },
  } as unknown as Response
}

/** El `Authorization` de la llamada `n` que salió por `fetch`. */
function authorizationOf(call: number): string | null {
  const [request, init] = fetchMock.mock.calls[call] as [unknown, RequestInit | undefined]
  const fromInit = new Headers(init?.headers ?? {}).get("Authorization")
  if (fromInit) return fromInit
  // Storage y Functions pueden pasar un `Request` ya armado.
  if (request instanceof Request) return request.headers.get("Authorization")
  return null
}

async function freshClient() {
  vi.resetModules()
  const { createClient } = await import("@/lib/supabase/client")
  return createClient()
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", SUPABASE_URL)
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", ANON_KEY)
  getAccessTokenMock.mockReset().mockResolvedValue(TOKEN)
  fetchMock = vi.fn().mockResolvedValue(okResponse())
  vi.stubGlobal("fetch", fetchMock)
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
})

describe("el token del callback alimenta Storage (19.10)", () => {
  it("una subida al bucket viaja con el token de la sesión", async () => {
    const supabase = await freshClient()

    await supabase.storage
      .from("invoices")
      .upload("user-1/factura.jpg", new Blob(["x"]), { contentType: "image/jpeg" })

    expect(fetchMock).toHaveBeenCalled()
    expect(authorizationOf(0)).toBe(`Bearer ${TOKEN}`)
  })

  it("un borrado del bucket también (es el cleanup del OCR ante un fallo)", async () => {
    const supabase = await freshClient()

    await supabase.storage.from("invoices").remove(["user-1/factura.jpg"])

    expect(authorizationOf(0)).toBe(`Bearer ${TOKEN}`)
  })
})

describe("el token del callback alimenta Functions (19.10)", () => {
  it("`functions.invoke` viaja con el token de la sesión", async () => {
    const supabase = await freshClient()

    await supabase.functions.invoke("ai-resumen", { body: { period: "daily" } })

    expect(authorizationOf(0)).toBe(`Bearer ${TOKEN}`)
  })
})

describe("el token del callback alimenta REST (19.10)", () => {
  it("una consulta a PostgREST viaja con el token de la sesión", async () => {
    const supabase = await freshClient()

    await supabase.from("profiles").select("*").limit(1)

    expect(authorizationOf(0)).toBe(`Bearer ${TOKEN}`)
  })
})

describe("sin sesión los tres caen a la anon key, no rompen (19.5b)", () => {
  // Es la mitad que importa del contrato de `getAccessToken()`: si en vez de
  // resolver vacío lanzara, **toda** página pública que toque supabase-js se
  // rompería para un visitante anónimo. Acá se ve el efecto concreto:
  // `fetchWithAuth` hace `(await getAccessToken()) ?? supabaseKey`
  // (`supabase-js/index.mjs:112`).
  beforeEach(() => {
    getAccessTokenMock.mockResolvedValue(null)
  })

  it("REST sale con la anon key", async () => {
    const supabase = await freshClient()

    await supabase.from("posts").select("*").limit(1)

    expect(authorizationOf(0)).toBe(`Bearer ${ANON_KEY}`)
  })

  it("Storage sale con la anon key", async () => {
    const supabase = await freshClient()

    await supabase.storage.from("invoices").remove(["x"])

    expect(authorizationOf(0)).toBe(`Bearer ${ANON_KEY}`)
  })

  it("Functions sale con la anon key", async () => {
    const supabase = await freshClient()

    await supabase.functions.invoke("ai-resumen", { body: {} })

    expect(authorizationOf(0)).toBe(`Bearer ${ANON_KEY}`)
  })

  it("y ninguno de los tres lanza por no haber sesión", async () => {
    const supabase = await freshClient()

    await expect(supabase.from("posts").select("*")).resolves.toBeTruthy()
    await expect(
      supabase.functions.invoke("ai-resumen", { body: {} }),
    ).resolves.toBeTruthy()
  })
})
