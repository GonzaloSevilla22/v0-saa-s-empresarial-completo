/**
 * Tests for `checkAiQuota`/`incrementAiUsage` (billing-edge-effective-plan,
 * section 4 — 8 Edge Functions of AI consume this module).
 *
 * Imports the REAL file `supabase/functions/_shared/ai-quota.ts` by relative
 * path (same convention as edge-effective-plan.test.ts, D6) and injects a
 * double of the Supabase client. `ai-quota.ts` has zero `Deno.*` references
 * at module scope, so — like `effective-plan.ts` — it is importable as-is.
 *
 * Run: pnpm vitest run __tests__/ai-quota.test.ts
 */

import { describe, it, expect, vi } from "vitest"
import {
  checkAiQuota,
  incrementAiUsage,
  type AiQuotaClient,
} from "../../supabase/functions/_shared/ai-quota"

interface ProfileCounters {
  ai_queries_used: number | null
  ai_advice_used: number | null
  usage_reset_at: string | null
}

interface PlanLimitsRow {
  max_ai_queries_per_month: number
  max_ai_advice_per_month: number
}

function makeClient(cfg: {
  effectivePlan?: { data: string | null; error: { message: string } | null }
  profile?: { data: ProfileCounters | null; error: { message: string } | null }
  limits?: { data: PlanLimitsRow | null; error: { message: string } | null }
}): { client: AiQuotaClient; rpcMock: ReturnType<typeof vi.fn>; fromMock: ReturnType<typeof vi.fn> } {
  const effectivePlan = cfg.effectivePlan ?? { data: "gratis", error: null }
  const profile = cfg.profile ?? { data: { ai_queries_used: 0, ai_advice_used: 0, usage_reset_at: null }, error: null }
  const limits = cfg.limits ?? { data: { max_ai_queries_per_month: 5, max_ai_advice_per_month: 3 }, error: null }

  const rpcMock = vi.fn(async (fn: string) => {
    if (fn === "rpc_my_effective_plan") return effectivePlan
    return { data: null, error: null }
  })

  const fromMock = vi.fn((table: string) => ({
    select: (_columns: string) => ({
      eq: (_col: string, _val: string) => ({
        single: async () => (table === "profiles" ? profile : limits),
      }),
    }),
  }))

  const client = {
    rpc: rpcMock,
    from: fromMock,
  } as unknown as AiQuotaClient

  return { client, rpcMock, fromMock }
}

// ─── task 4.1 (RED): pago real vs profiles stale ─────────────────────────────

describe("checkAiQuota (task 4.1 — el limite sigue al plan efectivo, no a profiles)", () => {
  it("allows the call when the effective plan is 'pro' (300) even though profiles would have said 'gratis' (5)", async () => {
    const { client } = makeClient({
      effectivePlan: { data: "pro", error: null },
      profile: { data: { ai_queries_used: 10, ai_advice_used: 0, usage_reset_at: null }, error: null },
      limits: { data: { max_ai_queries_per_month: 300, max_ai_advice_per_month: 20 }, error: null },
    })
    const result = await checkAiQuota(client, "user-1", "queries")
    expect(result.allowed).toBe(true)
    expect(result.body).toBeNull()
  })
})

// ─── task 4.3 (TRIANGULATE) ───────────────────────────────────────────────────

describe("checkAiQuota (task 4.3 — triangulation)", () => {
  it("cuenta exenta con billing_plan='gratis' obtiene el límite de 'pro'", async () => {
    const { client } = makeClient({
      effectivePlan: { data: "pro", error: null },
      profile: { data: { ai_queries_used: 250, ai_advice_used: 0, usage_reset_at: null }, error: null },
      limits: { data: { max_ai_queries_per_month: 300, max_ai_advice_per_month: 20 }, error: null },
    })
    expect((await checkAiQuota(client, "user-2", "queries")).allowed).toBe(true)
  })

  it("trial vencido (rpc ya resuelve el plan base) usa el límite del plan base, no el del trial", async () => {
    const { client } = makeClient({
      effectivePlan: { data: "inicial", error: null },
      profile: { data: { ai_queries_used: 30, ai_advice_used: 0, usage_reset_at: null }, error: null },
      limits: { data: { max_ai_queries_per_month: 30, max_ai_advice_per_month: 5 }, error: null },
    })
    const result = await checkAiQuota(client, "user-3", "queries")
    expect(result.allowed).toBe(false)
    expect(result.body).toEqual({
      ok: false,
      error: "quota_exceeded",
      resetAt: null,
      used: 30,
      limit: 30,
    })
  })

  it("contador por encima del limite → allowed:false con el cuerpo 429 intacto (D7)", async () => {
    const { client } = makeClient({
      effectivePlan: { data: "gratis", error: null },
      profile: { data: { ai_advice_used: 3, ai_queries_used: 0, usage_reset_at: "2026-08-01T00:00:00Z" }, error: null },
      limits: { data: { max_ai_queries_per_month: 5, max_ai_advice_per_month: 3 }, error: null },
    })
    const result = await checkAiQuota(client, "user-4", "advice")
    expect(result.allowed).toBe(false)
    expect(result.body).toEqual({
      ok: false,
      error: "quota_exceeded",
      resetAt: "2026-08-01T00:00:00Z",
      used: 3,
      limit: 3,
    })
  })

  it("plan_limits ilegible → fail-open conservado (D5)", async () => {
    const { client } = makeClient({
      effectivePlan: { data: "gratis", error: null },
      limits: { data: null, error: { message: "timeout" } },
    })
    const result = await checkAiQuota(client, "user-5", "queries")
    expect(result.allowed).toBe(true)
    expect(result.body).toBeNull()
  })

  it("profiles (contador) ilegible → fail-open conservado", async () => {
    const { client } = makeClient({
      effectivePlan: { data: "pro", error: null },
      profile: { data: null, error: { message: "not found" } },
    })
    const result = await checkAiQuota(client, "user-6", "queries")
    expect(result.allowed).toBe(true)
  })
})

// ─── task 4.4: incrementAiUsage intacto + el select de profiles solo pide contadores ──

describe("checkAiQuota / incrementAiUsage (task 4.4)", () => {
  it("incrementAiUsage sigue llamando a rpc_increment_ai_usage sin cambios (D3 — contador por usuario)", async () => {
    const { client, rpcMock } = makeClient({})
    await incrementAiUsage(client, "user-7", "advice")
    expect(rpcMock).toHaveBeenCalledWith("rpc_increment_ai_usage", { p_user_id: "user-7", p_counter: "advice" })
  })

  it("el select a profiles pide solo columnas de contador — nada de billing_plan/billing_status/trial_*", async () => {
    const { client, fromMock } = makeClient({})
    await checkAiQuota(client, "user-8", "queries")

    const profilesCall = fromMock.mock.results.find((_r, i) => fromMock.mock.calls[i][0] === "profiles")
    expect(profilesCall).toBeDefined()

    // Inspeccionamos qué columnas pidió el `.select(...)` de la tabla profiles.
    const selectSpy = vi.fn()
    const trackingFrom = (table: string) => ({
      select: (columns: string) => {
        if (table === "profiles") selectSpy(columns)
        return {
          eq: () => ({ single: async () => ({ data: { ai_queries_used: 0, ai_advice_used: 0, usage_reset_at: null }, error: null }) }),
        }
      },
    })
    const trackingClient = {
      rpc: vi.fn(async (fn: string) => (fn === "rpc_my_effective_plan" ? { data: "pro", error: null } : { data: null, error: null })),
      from: trackingFrom,
    } as unknown as AiQuotaClient

    await checkAiQuota(trackingClient, "user-9", "queries")
    expect(selectSpy).toHaveBeenCalledTimes(1)
    const requestedColumns = selectSpy.mock.calls[0][0] as string
    expect(requestedColumns).not.toMatch(/billing_plan|billing_status|trial_plan|trial_expires_at/)
    expect(requestedColumns).toMatch(/ai_queries_used/)
    expect(requestedColumns).toMatch(/ai_advice_used/)
    expect(requestedColumns).toMatch(/usage_reset_at/)
  })
})
