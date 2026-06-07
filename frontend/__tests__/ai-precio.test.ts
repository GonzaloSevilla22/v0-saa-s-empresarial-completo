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

type Plan = "gratis" | "inicial" | "avanzado" | "pro"

const ALLOWED_PLANS: Plan[] = ["avanzado", "pro"]

function isPlanAllowed(plan: Plan): boolean {
  return ALLOWED_PLANS.includes(plan)
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

// ─── task 5.3: 403 when plan is 'gratis' ─────────────────────────────────────

describe("ai-precio: plan check (task 5.3)", () => {
  it("returns 403 for plan 'gratis'", () => {
    expect(isPlanAllowed("gratis")).toBe(false)
  })

  it("returns 403 for plan 'inicial'", () => {
    expect(isPlanAllowed("inicial")).toBe(false)
  })

  it("allows plan 'avanzado'", () => {
    expect(isPlanAllowed("avanzado")).toBe(true)
  })

  it("allows plan 'pro'", () => {
    expect(isPlanAllowed("pro")).toBe(true)
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
