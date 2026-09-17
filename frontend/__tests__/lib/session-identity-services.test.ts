/**
 * auth-hardening-jwt-cookies — Parte C, D1, task 19.8b.
 *
 * Los servicios que no son React resolvían la identidad con
 * `supabase.auth.getUser()` sobre el cliente de **navegador**. Con `accessToken`
 * configurado (19.6) ese acceso **lanza** (`supabase-js/index.mjs:389`), así que
 * la identidad pasa a `getSessionUser()` (`lib/auth/access-token-store.ts`), que
 * la toma del `user` que viaja con el token y **no cuesta una llamada extra**.
 *
 * En componentes y hooks la identidad sale de `useAuth()`, que además trae perfil,
 * cuenta y plan; acá no hay hooks, así que el store es el "contexto de sesión".
 *
 * Cada familia se ejercita con dos casos —hay identidad / no hay sesión— porque
 * las dos ramas importan: la primera escribe `user_id` en una fila y la segunda
 * tiene que **negarse**, no escribir `undefined` y dejar que la RLS decida.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

const getSessionUserMock = vi.fn()

vi.mock("@/lib/auth/access-token-store", () => ({
  getSessionUser: () => getSessionUserMock(),
}))

// El doble del cliente **no** expone `auth`: es justo el contrato que
// desaparece, y el candado de 19.7b falla si alguien lo devuelve.
const insertPayloads: Record<string, unknown[]> = {}
const selectFilters: Record<string, unknown> = {}
const storageUploads: string[] = []
const storageRemovals: string[][] = []
const invoked: Array<{ name: string; body: unknown }> = []

function rowBuilder(table: string) {
  const chain = {
    select: () => chain,
    eq: (_column: string, value: unknown) => {
      selectFilters[table] = value
      return chain
    },
    order: () => chain,
    limit: () => chain,
    single: async () => ({ data: { id: "row-1", recommendation: [] }, error: null }),
    maybeSingle: async () => ({ data: { id: "row-1" }, error: null }),
    then: undefined,
  }
  return chain
}

const supabaseDouble = {
  from: (table: string) => ({
    insert: (payload: unknown) => {
      insertPayloads[table] = Array.isArray(payload) ? payload : [payload]
      return {
        select: () => ({
          single: async () => ({ data: { id: "row-1" }, error: null }),
        }),
      }
    },
    select: () => rowBuilder(table),
  }),
  schema: () => supabaseDouble,
  storage: {
    from: () => ({
      upload: async (path: string) => {
        storageUploads.push(path)
        return { error: null }
      },
      remove: async (paths: string[]) => {
        storageRemovals.push(paths)
        return { error: null }
      },
    }),
  },
  functions: {
    invoke: async (name: string, options?: { body?: unknown }) => {
      invoked.push({ name, body: options?.body })
      return { data: { ok: true, result: { items: [] } }, error: null }
    },
  },
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => supabaseDouble,
}))

const USER = { id: "11111111-1111-4111-8111-111111111111", email: "duenio@test.local" }

beforeEach(() => {
  getSessionUserMock.mockReset()
  getSessionUserMock.mockResolvedValue(USER)
  for (const key of Object.keys(insertPayloads)) delete insertPayloads[key]
  for (const key of Object.keys(selectFilters)) delete selectFilters[key]
  storageUploads.length = 0
  storageRemovals.length = 0
  invoked.length = 0
})

// ── lib/supabase/services.ts:48 / :64 ───────────────────────────────────────
describe("services.ts — createClient y createExpense escriben el user_id de la sesión", () => {
  it("createClient (el de la tabla `clients`) escribe el id de la sesión", async () => {
    const { services } = await import("@/lib/supabase/services")

    await services.createClient({ name: "Mostrador" })

    expect(insertPayloads.clients?.[0]).toMatchObject({ user_id: USER.id, name: "Mostrador" })
  })

  it("sin sesión se niega en vez de insertar una fila sin dueño", async () => {
    getSessionUserMock.mockResolvedValue(null)
    const { services } = await import("@/lib/supabase/services")

    await expect(services.createClient({ name: "Mostrador" })).rejects.toThrow()
    expect(insertPayloads.clients).toBeUndefined()
  })

  it("createExpense escribe el id de la sesión", async () => {
    const { services } = await import("@/lib/supabase/services")

    await services.createExpense({ amount: 1500 })

    expect(insertPayloads.expenses?.[0]).toMatchObject({ user_id: USER.id, amount: 1500 })
  })

  it("createExpense sin sesión se niega", async () => {
    getSessionUserMock.mockResolvedValue(null)
    const { services } = await import("@/lib/supabase/services")

    await expect(services.createExpense({ amount: 1500 })).rejects.toThrow()
    expect(insertPayloads.expenses).toBeUndefined()
  })
})

// ── lib/services/aiCopilotService.ts:34 / :51 ───────────────────────────────
describe("aiCopilotService — la identidad ya no sale del cliente que recibe", () => {
  it("el historial se filtra por el usuario de la sesión", async () => {
    const { aiCopilotService } = await import("@/lib/services/aiCopilotService")

    await aiCopilotService.getConversationHistory(supabaseDouble as never)

    expect(selectFilters.ai_conversations).toBe(USER.id)
  })

  it("guardar una conversación la ata al usuario de la sesión", async () => {
    const { aiCopilotService } = await import("@/lib/services/aiCopilotService")

    await aiCopilotService.saveConversation(supabaseDouble as never, "¿precio?", "así")

    expect(insertPayloads.ai_conversations?.[0]).toMatchObject({
      user_id: USER.id,
      question: "¿precio?",
      answer: "así",
    })
  })

  it("sin sesión ninguna de las dos toca la base", async () => {
    getSessionUserMock.mockResolvedValue(null)
    const { aiCopilotService } = await import("@/lib/services/aiCopilotService")

    await expect(
      aiCopilotService.getConversationHistory(supabaseDouble as never),
    ).rejects.toThrow()
    await expect(
      aiCopilotService.saveConversation(supabaseDouble as never, "q", "a"),
    ).rejects.toThrow()
    expect(insertPayloads.ai_conversations).toBeUndefined()
  })
})

// ── lib/services/fairAdvisorService.ts:46 ──────────────────────────────────
describe("fairAdvisorService — la última recomendación es la del usuario de la sesión", () => {
  it("filtra por el id de la sesión", async () => {
    const { fairAdvisorService } = await import("@/lib/services/fairAdvisorService")

    await fairAdvisorService.getLastRecommendation()

    expect(selectFilters.fair_recommendations).toBe(USER.id)
  })

  it("sin sesión se niega", async () => {
    getSessionUserMock.mockResolvedValue(null)
    const { fairAdvisorService } = await import("@/lib/services/fairAdvisorService")

    await expect(fairAdvisorService.getLastRecommendation()).rejects.toThrow()
  })
})

// ── lib/services/invoiceOcrService.ts:68 ───────────────────────────────────
describe("invoiceOcrService — el prefijo del objeto de Storage es el id de la sesión", () => {
  const pdf = () =>
    new File([new Uint8Array([1, 2, 3])], "factura.pdf", { type: "application/pdf" })

  it("sube bajo el prefijo del usuario y registra el documento a su nombre", async () => {
    const { invoiceOcrService } = await import("@/lib/services/invoiceOcrService")

    await invoiceOcrService.processInvoice(pdf(), () => {})

    // El prefijo NO es cosmético: la policy de Storage del bucket `invoices` lo
    // usa para decidir quién puede leer el objeto.
    expect(storageUploads[0].startsWith(`${USER.id}/`)).toBe(true)
    expect(insertPayloads.invoice_documents?.[0]).toMatchObject({ user_id: USER.id })
  })

  it("sin sesión no sube nada", async () => {
    getSessionUserMock.mockResolvedValue(null)
    const { invoiceOcrService } = await import("@/lib/services/invoiceOcrService")

    await expect(invoiceOcrService.processInvoice(pdf(), () => {})).rejects.toThrow()
    expect(storageUploads).toEqual([])
  })
})
