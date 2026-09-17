// @vitest-environment node
/**
 * auth-hardening-jwt-cookies — Parte C, D1. Revisión adversarial pre-merge
 * (BLOCKER: la identidad del Copiloto se resolvía con el store del navegador
 * dentro de un Route Handler).
 *
 * Corre en el entorno **node** y eso ES el test: sin `window`, el store del token
 * devuelve `{ status: "unknown" }` por construcción (`access-token-store.ts:208-212`)
 * y `getSessionUser()` devuelve `null` **siempre**. `POST /api/ai/copilot` corre
 * exactamente ahí, así que hasta este arreglo:
 *
 *  - `buildBusinessSnapshot` entraba al `catch` en el 100% de las peticiones y la
 *    IA quedaba sin el bloque de top productos;
 *  - `saveConversation` lanzaba `Unauthorized` y **ninguna** conversación se
 *    persistía (pérdida de datos: `ai_conversations`, y el historial de
 *    `/copiloto-ia` dejaba de crecer).
 *
 * Los dos fallos eran invisibles: uno dentro de un `try/catch`, el otro dentro de
 * un `.catch()`. Y la suite estaba verde porque el doble de
 * `@/lib/auth/access-token-store` devolvía un usuario que el servidor **no puede
 * producir jamás** — el modo de falla que el candado de 17.2b/19.7b existe para
 * cerrar, acá del lado del store.
 *
 * Por eso este archivo **no mockea el store**: la identidad ahora llega por
 * parámetro desde el caller, que ya la tiene autenticada contra el proveedor
 * (`app/api/ai/copilot/route.ts` → `supabase.auth.getUser()` con el cliente de
 * servidor).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import type { SupabaseClient } from "@supabase/supabase-js"
import { getSessionUser, resolveAccessToken } from "@/lib/auth/access-token-store"
import { buildBusinessSnapshot } from "@/lib/ai/buildBusinessSnapshot"
import { aiCopilotService } from "@/lib/services/aiCopilotService"

const USER_ID = "11111111-1111-4111-8111-111111111111"

// ── Doble de datos ──────────────────────────────────────────────────────────

interface Recorded {
  /** Valor del `.eq()` por tabla, para ver con qué identidad se filtró. */
  filters: Record<string, unknown>
  inserts: Record<string, unknown[]>
  rankingArgs: Record<string, unknown> | null
}

function makeDouble(): { supabase: SupabaseClient; recorded: Recorded } {
  const recorded: Recorded = { filters: {}, inserts: {}, rankingArgs: null }

  const thenable = <T>(data: T) => ({
    select: () => thenable(data),
    eq: () => thenable(data),
    gte: () => thenable(data),
    lt: () => thenable(data),
    order: () => thenable(data),
    limit: () => thenable(data),
    then: (resolve: (value: { data: T; error: null }) => unknown) =>
      Promise.resolve({ data, error: null }).then(resolve),
  })

  const rpc = vi.fn((fn: string, args?: Record<string, unknown>) => {
    if (fn === "rpc_product_ranking") {
      recorded.rankingArgs = args ?? null
      return Promise.resolve({
        data: [
          {
            product_id: "p-1",
            product_name: "Remera negra",
            units: "4",
            revenue: "40000",
            gross_margin_pct: "35",
          },
        ],
        error: null,
      })
    }
    if (fn === "get_dashboard_critical_stock") return Promise.resolve({ data: 0, error: null })
    if (fn === "get_dashboard_critical_stock_items")
      return Promise.resolve({ data: [], error: null })
    return Promise.resolve({ data: [], error: null })
  })

  const from = vi.fn((table: string) => {
    if (table === "account_members") {
      return {
        select: () => ({
          eq: (_column: string, value: unknown) => {
            recorded.filters.account_members = value
            return {
              order: () => ({
                order: () => ({
                  limit: () => Promise.resolve({ data: [{ account_id: "acc-1" }], error: null }),
                }),
              }),
            }
          },
        }),
      }
    }

    if (table === "ai_conversations") {
      return {
        insert: (payload: unknown) => {
          recorded.inserts.ai_conversations = Array.isArray(payload) ? payload : [payload]
          return {
            select: () => ({
              single: async () => ({ data: { id: "row-1" }, error: null }),
            }),
          }
        },
        select: () => ({
          eq: (_column: string, value: unknown) => {
            recorded.filters.ai_conversations = value
            return {
              order: async () => ({ data: [{ id: "row-1" }], error: null }),
            }
          },
        }),
      }
    }

    return { select: () => thenable([]) }
  })

  return { supabase: { rpc, from } as unknown as SupabaseClient, recorded }
}

beforeEach(() => {
  vi.clearAllMocks()
})

// ── El control que explica por qué la identidad viaja por parámetro ─────────

describe("el store del token no puede resolver identidad en el servidor", () => {
  it("sin `window`, el store dice `unknown` y no hay usuario", async () => {
    expect(await resolveAccessToken()).toEqual({ status: "unknown" })
    expect(await getSessionUser()).toBeNull()
  })
})

// ── buildBusinessSnapshot ───────────────────────────────────────────────────

describe("buildBusinessSnapshot recibe la identidad del caller", () => {
  it("con el id del usuario autenticado arma el bloque de top productos", async () => {
    const { supabase, recorded } = makeDouble()

    const snapshot = await buildBusinessSnapshot(supabase, USER_ID)

    expect(snapshot.productos.top_rentables).toHaveLength(1)
    expect(snapshot.productos.top_rentables[0]).toMatchObject({
      nombre: "Remera negra",
      unidades: 4,
    })
    // Y la cuenta se resolvió con ESA identidad, no con una del store.
    expect(recorded.filters.account_members).toBe(USER_ID)
    expect(recorded.rankingArgs).toMatchObject({ p_account_id: "acc-1" })
  })

  it("sin identidad degrada igual que antes: omite el bloque y no lanza", async () => {
    const { supabase, recorded } = makeDouble()

    const snapshot = await buildBusinessSnapshot(supabase, null)

    expect(snapshot.productos.top_rentables).toEqual([])
    // No se consulta la cuenta de nadie con un `undefined`.
    expect(recorded.filters.account_members).toBeUndefined()
    expect(recorded.rankingArgs).toBeNull()
  })
})

// ── aiCopilotService ────────────────────────────────────────────────────────

describe("aiCopilotService recibe la identidad del caller", () => {
  it("guardar una conversación la ata al usuario que el caller autenticó", async () => {
    const { supabase, recorded } = makeDouble()

    await aiCopilotService.saveConversation(supabase, USER_ID, "¿precio?", "así")

    expect(recorded.inserts.ai_conversations?.[0]).toMatchObject({
      user_id: USER_ID,
      question: "¿precio?",
      answer: "así",
    })
  })

  it("el historial se filtra por esa misma identidad", async () => {
    const { supabase, recorded } = makeDouble()

    await aiCopilotService.getConversationHistory(supabase, USER_ID)

    expect(recorded.filters.ai_conversations).toBe(USER_ID)
  })

  it("sin identidad se niega y no escribe nada (la RLS no es la primera línea)", async () => {
    const { supabase, recorded } = makeDouble()

    await expect(aiCopilotService.saveConversation(supabase, "", "q", "a")).rejects.toThrow()
    await expect(aiCopilotService.getConversationHistory(supabase, "")).rejects.toThrow()
    expect(recorded.inserts.ai_conversations).toBeUndefined()
    expect(recorded.filters.ai_conversations).toBeUndefined()
  })
})
