/**
 * v31-ia-ratelimit-budget (D8, tasks 4.3/4.4): `useAiUsage` expone el saldo de lecturas de
 * factura (`ocrUsed`/`ocrRemaining`, piso 0) y `usePlanLimits` el límite
 * `maxAiOcrPerMonth`, tanto desde `plan_limits` como desde el fallback de `lib/constants.ts`.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

import { useAiUsage } from "@/hooks/auth/use-ai-usage"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { PLAN_LIMITS } from "@/lib/constants"

const state = vi.hoisted(() => ({
  profile: { data: null as unknown, error: null as unknown },
  limits: { data: null as unknown, error: null as unknown },
  profilesSelect: vi.fn(),
  plan: "inicial",
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: (table: string) => ({
      select: (columns: string) => {
        if (table === "profiles") state.profilesSelect(columns)
        return {
          eq: () => ({
            single: async () => (table === "profiles" ? state.profile : state.limits),
          }),
        }
      },
    }),
  }),
}))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", effectivePlan: state.plan } }),
}))

function wrapper() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client }, children)
}

function dbLimits(ocr: number) {
  return {
    plan: "inicial", price_monthly: 0, max_users: 1, max_products: 1, max_clients: 1, max_suppliers: 1,
    max_operations_per_month: 1, history_days: 1, max_exports_per_month: 1, max_ai_queries_per_month: 30,
    max_ai_advice_per_month: 15, max_ai_ocr_per_month: ocr, max_branches: 1, has_product_profitability: false,
    has_comparative_reports: false, has_price_suggestion: false, has_branches_module: false,
    has_monthly_analysis: false, internal_roles: "none",
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  state.plan = "inicial"
  state.profile = { data: { ai_queries_used: 1, ai_advice_used: 2, ai_ocr_used: 12, usage_reset_at: null }, error: null }
  state.limits = { data: dbLimits(30), error: null }
})

describe("usePlanLimits — maxAiOcrPerMonth", () => {
  it("lo toma de plan_limits cuando la consulta responde", async () => {
    const { result } = renderHook(() => usePlanLimits(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.limits).toBeDefined())
    expect(result.current.limits?.maxAiOcrPerMonth).toBe(30)
  })

  it("cae al fallback estático de lib/constants.ts si la consulta falla (4 planes, 5/30/120/300)", async () => {
    expect(
      (["gratis", "inicial", "avanzado", "pro"] as const).map((p) => PLAN_LIMITS[p].maxAiOcrPerMonth),
    ).toEqual([5, 30, 120, 300])

    state.limits = { data: null, error: { message: "rls" } }
    state.plan = "avanzado"
    const { result } = renderHook(() => usePlanLimits(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.limits).toBeDefined())
    expect(result.current.limits?.maxAiOcrPerMonth).toBe(120)
  })
})

describe("useAiUsage — saldo de lecturas de factura", () => {
  it("ocrUsed y ocrRemaining salen del perfil y del límite del plan", async () => {
    const { result } = renderHook(() => useAiUsage(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.ocrUsed).toBe(12))
    expect(result.current.ocrRemaining).toBe(18)
    expect(state.profilesSelect.mock.calls[0][0]).toMatch(/ai_ocr_used/)
  })

  it("ocrRemaining no baja de 0 aunque el contador supere el límite", async () => {
    state.profile = { data: { ai_queries_used: 0, ai_advice_used: 0, ai_ocr_used: 35, usage_reset_at: null }, error: null }
    const { result } = renderHook(() => useAiUsage(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.ocrUsed).toBe(35))
    expect(result.current.ocrRemaining).toBe(0)
  })

  it("si el perfil no se puede leer, el uso es 0 (no inventa saldo negativo)", async () => {
    state.profile = { data: null, error: { message: "boom" } }
    const { result } = renderHook(() => useAiUsage(), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.ocrUsed).toBe(0)
    expect(result.current.ocrRemaining).toBe(30)
  })
})
