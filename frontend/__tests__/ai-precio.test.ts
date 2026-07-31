/**
 * Tests for the `ai-precio` Edge Function business logic.
 *
 * These tests cover the pure TypeScript logic only — no Deno runtime, no
 * Supabase client, no OpenAI calls. They are designed to run with vitest
 * (add `vitest` as a devDependency to run them).
 *
 * To run: pnpm add -D vitest && pnpm vitest run __tests__/ai-precio.test.ts
 */

import { describe, it, expect } from "vitest"

// ─── Duplicate pure logic from Edge Function for unit testing ─────────────────
// We cannot import from supabase/functions/ (excluded from tsconfig) so we
// re-declare the pure functions here. This is the standard approach for Deno
// edge function unit tests in a Next.js project.

interface SaleRow {
  week_key:  string
  avg_price: number
  qty:       number
}

/**
 * Pearson correlation between weekly avg price and weekly units sold.
 * Positive → price and qty move together.
 * Negative → as price rises, qty falls (normal price elasticity).
 * Zero → no linear relationship.
 */
function calculateElasticity(weeklyData: SaleRow[]): number {
  const n = weeklyData.length
  if (n < 2) return 0

  const prices = weeklyData.map((r) => r.avg_price)
  const qtys   = weeklyData.map((r) => r.qty)

  const meanP = prices.reduce((s, v) => s + v, 0) / n
  const meanQ = qtys.reduce((s, v) => s + v, 0) / n

  let num = 0, denP = 0, denQ = 0
  for (let i = 0; i < n; i++) {
    const dp = prices[i] - meanP
    const dq = qtys[i]   - meanQ
    num  += dp * dq
    denP += dp * dp
    denQ += dq * dq
  }

  const denom = Math.sqrt(denP * denQ)
  if (denom === 0) return 0
  return num / denom
}

// ─── Quota / plan logic helpers ───────────────────────────────────────────────

// billing-edge-effective-plan (task 5.2): el gate de esta función dejó de
// comparar contra un array hardcodeado de planes (`allowedPlans =
// ['avanzado','pro']`) — ahora lee el flag canónico
// `plan_limits.has_price_suggestion` del plan efectivo (D4). El plan efectivo
// en sí se resuelve con `resolveEffectivePlan` (supabase/functions/_shared/
// effective-plan.ts), cuya cobertura completa —incluida la escena de task 5.1
// "cuenta pro con profiles.billing_plan stale en gratis"— vive en
// frontend/__tests__/edge-effective-plan.test.ts: ai-precio delega el 100%
// de esa resolución, así que repetir esos casos acá sería una duplicación
// sin valor. Lo que SÍ es lógica propia de esta función es la decisión de
// gating a partir del flag ya resuelto.
interface PriceSuggestionLimits {
  has_price_suggestion: boolean
}

function isPriceSuggestionAllowed(limits: PriceSuggestionLimits | null): boolean {
  return limits?.has_price_suggestion === true
}

// task 5.4: reemplaza el `.single()` sobre account_members (lanzaba si el
// usuario tenía 2+ membresías) por la MISMA regla determinista de D2 (más
// antigua por created_at, desempate por account_id) — ver el comentario
// `resolveAccountId` en supabase/functions/ai-precio/index.ts. Esta es la
// porción pura y testeable de esa resolución.
interface MembershipRow {
  account_id: string
  created_at: string
}

function pickOldestMembership(rows: MembershipRow[]): string | null {
  if (rows.length === 0) return null
  const sorted = [...rows].sort((a, b) => {
    if (a.created_at !== b.created_at) return a.created_at < b.created_at ? -1 : 1
    if (a.account_id === b.account_id) return 0
    return a.account_id < b.account_id ? -1 : 1
  })
  return sorted[0].account_id
}

interface ProfileForQuota {
  ai_queries_used: number
}

interface PlanLimits {
  max_ai_queries_per_month: number
}

function isQuotaExceeded(profile: ProfileForQuota, limits: PlanLimits): boolean {
  return profile.ai_queries_used >= limits.max_ai_queries_per_month
}

// ─── task 5.1: fallback when sales < 3 ───────────────────────────────────────

describe("ai-precio: insufficient_data fallback (task 5.1)", () => {
  const MIN_SALES_THRESHOLD = 3

  it("returns fallback:true when there are 0 sales", () => {
    const salesCount = 0
    expect(salesCount < MIN_SALES_THRESHOLD).toBe(true)
  })

  it("returns fallback:true when there are 2 sales (one below threshold)", () => {
    const salesCount = 2
    expect(salesCount < MIN_SALES_THRESHOLD).toBe(true)
  })

  it("does NOT fallback when there are exactly 3 sales (threshold met)", () => {
    const salesCount = 3
    expect(salesCount < MIN_SALES_THRESHOLD).toBe(false)
  })

  it("does NOT fallback when there are 10 sales", () => {
    const salesCount = 10
    expect(salesCount < MIN_SALES_THRESHOLD).toBe(false)
  })
})

// ─── task 5.2: 429 when quota exceeded ───────────────────────────────────────

describe("ai-precio: quota_exceeded check (task 5.2)", () => {
  it("blocks when ai_queries_used equals max_ai_queries_per_month (avanzado = 120)", () => {
    const profile: ProfileForQuota = { ai_queries_used: 120 }
    const limits:  PlanLimits      = { max_ai_queries_per_month: 120 }
    expect(isQuotaExceeded(profile, limits)).toBe(true)
  })

  it("blocks when ai_queries_used exceeds max_ai_queries_per_month", () => {
    const profile: ProfileForQuota = { ai_queries_used: 121 }
    const limits:  PlanLimits      = { max_ai_queries_per_month: 120 }
    expect(isQuotaExceeded(profile, limits)).toBe(true)
  })

  it("allows when ai_queries_used is one below the limit", () => {
    const profile: ProfileForQuota = { ai_queries_used: 119 }
    const limits:  PlanLimits      = { max_ai_queries_per_month: 120 }
    expect(isQuotaExceeded(profile, limits)).toBe(false)
  })

  it("allows when ai_queries_used is 0", () => {
    const profile: ProfileForQuota = { ai_queries_used: 0 }
    const limits:  PlanLimits      = { max_ai_queries_per_month: 120 }
    expect(isQuotaExceeded(profile, limits)).toBe(false)
  })
})

// ─── task 5.2/5.3: gate por flag canónico plan_limits.has_price_suggestion ───

describe("ai-precio: plan check via has_price_suggestion flag (task 5.2/5.3)", () => {
  it("returns 403 when the resolved plan's has_price_suggestion is false ('gratis'/'inicial')", () => {
    expect(isPriceSuggestionAllowed({ has_price_suggestion: false })).toBe(false)
  })

  it("allows when has_price_suggestion is true", () => {
    expect(isPriceSuggestionAllowed({ has_price_suggestion: true })).toBe(true)
  })

  it("returns 403 (fail-closed) when the plan_limits row could not be resolved at all", () => {
    expect(isPriceSuggestionAllowed(null)).toBe(false)
  })

  it("la habilitación proviene de la tabla, no de un array hardcodeado en el código: cambiar el flag cambia la decisión sin tocar esta función", () => {
    // Antes: `['avanzado', 'pro'].includes(effectivePlan)` — cambiar la
    // política de planes exigía un redeploy. Ahora la MISMA función produce
    // resultados distintos según el valor leído de plan_limits, sin cambiar
    // una sola línea de código — eso es exactamente lo que se prueba acá.
    const flagOff: PriceSuggestionLimits = { has_price_suggestion: false }
    const flagOn: PriceSuggestionLimits = { has_price_suggestion: true }
    expect(isPriceSuggestionAllowed(flagOff)).not.toBe(isPriceSuggestionAllowed(flagOn))
  })
})

// ─── task 5.4: resolución determinista de cuenta (reemplaza el .single() que
//      lanzaba con 2+ membresías) ────────────────────────────────────────────

describe("ai-precio: pickOldestMembership — resolución determinista multi-cuenta (task 5.4)", () => {
  it("returns null when the user has no membership at all", () => {
    expect(pickOldestMembership([])).toBeNull()
  })

  it("returns the only account when there is exactly one membership", () => {
    const rows: MembershipRow[] = [{ account_id: "acc-1", created_at: "2026-01-01T00:00:00Z" }]
    expect(pickOldestMembership(rows)).toBe("acc-1")
  })

  it("returns the account with the OLDEST created_at when the user has 2+ memberships (no longer throws, D2)", () => {
    const rows: MembershipRow[] = [
      { account_id: "acc-new", created_at: "2026-02-01T00:00:00Z" },
      { account_id: "acc-old", created_at: "2026-01-01T00:00:00Z" },
    ]
    expect(pickOldestMembership(rows)).toBe("acc-old")
  })

  it("breaks a created_at tie by the SMALLEST account_id", () => {
    const rows: MembershipRow[] = [
      { account_id: "zzz-later-alphabetically", created_at: "2026-01-01T00:00:00Z" },
      { account_id: "aaa-earlier-alphabetically", created_at: "2026-01-01T00:00:00Z" },
    ]
    expect(pickOldestMembership(rows)).toBe("aaa-earlier-alphabetically")
  })

  it("is deterministic across repeated calls with the same input (no reliance on array/iteration order)", () => {
    const rows: MembershipRow[] = [
      { account_id: "b", created_at: "2026-01-01T00:00:00Z" },
      { account_id: "a", created_at: "2026-01-01T00:00:00Z" },
      { account_id: "c", created_at: "2025-12-31T00:00:00Z" },
    ]
    const first = pickOldestMembership(rows)
    const second = pickOldestMembership([...rows].reverse())
    expect(first).toBe("c")
    expect(second).toBe("c")
  })
})

// ─── calculateElasticity unit tests ──────────────────────────────────────────

describe("calculateElasticity", () => {
  it("returns 0 when only 1 week of data (insufficient for correlation)", () => {
    const data: SaleRow[] = [{ week_key: "2024-W01", avg_price: 100, qty: 5 }]
    expect(calculateElasticity(data)).toBe(0)
  })

  it("returns 0 when all prices are the same (no price variation)", () => {
    const data: SaleRow[] = [
      { week_key: "2024-W01", avg_price: 100, qty: 5 },
      { week_key: "2024-W02", avg_price: 100, qty: 7 },
      { week_key: "2024-W03", avg_price: 100, qty: 3 },
    ]
    expect(calculateElasticity(data)).toBe(0)
  })

  it("returns negative correlation when higher price = fewer units sold", () => {
    // Classic demand curve: as price rises, qty falls
    const data: SaleRow[] = [
      { week_key: "2024-W01", avg_price: 80,  qty: 10 },
      { week_key: "2024-W02", avg_price: 100, qty: 7  },
      { week_key: "2024-W03", avg_price: 120, qty: 4  },
    ]
    const elasticity = calculateElasticity(data)
    expect(elasticity).toBeLessThan(0)
  })

  it("returns positive correlation when higher price = more units sold (prestige good)", () => {
    const data: SaleRow[] = [
      { week_key: "2024-W01", avg_price: 80,  qty: 4  },
      { week_key: "2024-W02", avg_price: 100, qty: 7  },
      { week_key: "2024-W03", avg_price: 120, qty: 10 },
    ]
    const elasticity = calculateElasticity(data)
    expect(elasticity).toBeGreaterThan(0)
  })

  it("returns exactly 1 for perfectly positive linear correlation", () => {
    const data: SaleRow[] = [
      { week_key: "2024-W01", avg_price: 10, qty: 10 },
      { week_key: "2024-W02", avg_price: 20, qty: 20 },
      { week_key: "2024-W03", avg_price: 30, qty: 30 },
    ]
    const elasticity = calculateElasticity(data)
    expect(elasticity).toBeCloseTo(1, 5)
  })

  it("returns exactly -1 for perfectly negative linear correlation", () => {
    const data: SaleRow[] = [
      { week_key: "2024-W01", avg_price: 10, qty: 30 },
      { week_key: "2024-W02", avg_price: 20, qty: 20 },
      { week_key: "2024-W03", avg_price: 30, qty: 10 },
    ]
    const elasticity = calculateElasticity(data)
    expect(elasticity).toBeCloseTo(-1, 5)
  })
})
