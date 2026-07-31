/**
 * billing-pro-trial (D1/D3, tasks 7.1/7.3): getEffectivePlan es el ESPEJO en
 * TypeScript de la definición normativa `public.get_effective_plan(account_id)`
 * (SQL, migración 20260817000001). Esta tabla de casos es la MISMA tabla
 * compartida referenciada por el gate SQL de la migración (D3 design.md) —
 * exenta, trial vigente, trial vencido, sin trial, cuenta inexistente,
 * billing_plan ausente. Un cambio de precedencia en cualquiera de las dos
 * implementaciones debe romper esta prueba (task 7.3).
 */
import { describe, it, expect } from "vitest"
import { getEffectivePlan, type EffectivePlanInput } from "@/lib/plan-utils"

const HOUR = 60 * 60 * 1000

function isoIn(msFromNow: number): string {
  return new Date(Date.now() + msFromNow).toISOString()
}

describe("getEffectivePlan — parity table (billing-pro-trial D1/D3)", () => {
  it("exempt account resolves to 'pro' regardless of billingPlan/trial", () => {
    const input: EffectivePlanInput = {
      billingPlan: "gratis",
      trialPlan: null,
      trialExpiresAt: undefined,
      billingExempt: true,
    }
    expect(getEffectivePlan(input)).toBe("pro")
  })

  it("exemption has precedence over an already-expired trial", () => {
    const input: EffectivePlanInput = {
      billingPlan: "gratis",
      trialPlan: "pro",
      trialExpiresAt: isoIn(-HOUR),
      billingExempt: true,
    }
    expect(getEffectivePlan(input)).toBe("pro")
  })

  it("active trial (not expired) returns trialPlan", () => {
    const input: EffectivePlanInput = {
      billingPlan: "gratis",
      trialPlan: "pro",
      trialExpiresAt: isoIn(10 * 24 * HOUR),
      billingExempt: false,
    }
    expect(getEffectivePlan(input)).toBe("pro")
  })

  it("expired trial falls back to billingPlan", () => {
    const input: EffectivePlanInput = {
      billingPlan: "gratis",
      trialPlan: "pro",
      trialExpiresAt: isoIn(-1000),
      billingExempt: false,
    }
    expect(getEffectivePlan(input)).toBe("gratis")
  })

  it("no trial (null trialPlan) uses billingPlan", () => {
    const input: EffectivePlanInput = {
      billingPlan: "pro",
      trialPlan: null,
      trialExpiresAt: undefined,
      billingExempt: false,
    }
    expect(getEffectivePlan(input)).toBe("pro")
  })

  it("missing/invalid billingPlan resolves to 'gratis' (fail-closed, never 'pro')", () => {
    const input = {
      billingPlan: undefined as unknown as EffectivePlanInput["billingPlan"],
      trialPlan: null,
      trialExpiresAt: undefined,
      billingExempt: false,
    }
    expect(getEffectivePlan(input)).toBe("gratis")
  })

  it("nonexistent-account shape (all fields absent) resolves to 'gratis'", () => {
    const input = {
      billingPlan: undefined as unknown as EffectivePlanInput["billingPlan"],
      trialPlan: undefined as unknown as EffectivePlanInput["trialPlan"],
      trialExpiresAt: undefined,
      billingExempt: undefined,
    }
    expect(getEffectivePlan(input)).toBe("gratis")
  })

  it("billingStatus is NOT read — result is identical across all 5 status values (D1/D6)", () => {
    const base = {
      billingPlan: "inicial" as const,
      trialPlan: null,
      trialExpiresAt: undefined,
      billingExempt: false,
    }
    const statuses = ["active", "trialing", "expired", "cancelled", "cancelling"]
    const results = statuses.map((billingStatus) =>
      getEffectivePlan({ ...base, billingStatus } as EffectivePlanInput & { billingStatus: string })
    )
    expect(new Set(results).size).toBe(1)
    expect(results[0]).toBe("inicial")
  })
})

describe("getEffectivePlan — divergence detector (task 7.3)", () => {
  it("would be caught by this parity table if precedence were broken", () => {
    // Simulates the deliberately-broken variant D3 warns about: exemption
    // checked AFTER the trial instead of before. If someone "fixes" the real
    // implementation to match this broken one, this test starts failing —
    // proving the table is not a tautology.
    function brokenGetEffectivePlan(user: EffectivePlanInput) {
      const now = new Date()
      const trialActive =
        user.trialPlan != null && user.trialExpiresAt != null && new Date(user.trialExpiresAt) > now
      if (trialActive) return user.trialPlan
      if (user.billingExempt) return "pro"
      return user.billingPlan ?? "gratis"
    }

    const exemptWithExpiredTrial: EffectivePlanInput = {
      billingPlan: "gratis",
      trialPlan: "pro",
      trialExpiresAt: isoIn(-HOUR),
      billingExempt: true,
    }

    expect(getEffectivePlan(exemptWithExpiredTrial)).toBe("pro")
    expect(brokenGetEffectivePlan(exemptWithExpiredTrial)).toBe("pro") // agrees here

    const exemptWithActiveTrial: EffectivePlanInput = {
      billingPlan: "gratis",
      trialPlan: "avanzado",
      trialExpiresAt: isoIn(10 * 24 * HOUR),
      billingExempt: true,
    }

    // Real implementation: exemption wins → 'pro'. Broken one: trial wins → 'avanzado'.
    expect(getEffectivePlan(exemptWithActiveTrial)).toBe("pro")
    expect(brokenGetEffectivePlan(exemptWithActiveTrial)).toBe("avanzado")
    expect(getEffectivePlan(exemptWithActiveTrial)).not.toBe(brokenGetEffectivePlan(exemptWithActiveTrial))
  })
})
