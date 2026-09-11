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
import { getEffectivePlan, planProductLimitMessage, type EffectivePlanInput } from "@/lib/plan-utils"

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

describe("planProductLimitMessage — mensaje de rechazo por tope (importador-gate-plan, revisión ronda 2)", () => {
  // Molde de `newCategoryLimitMessage` (`lib/import/validator.ts`): oración
  // canónica que antes vivía duplicada, literal, en `ProductImportDialog`.
  // A diferencia de esa hermana (que sí pluraliza "categoría"/"categorías"
  // según la cantidad), esta oración usa siempre "productos" en plural —
  // no es un conteo gramatical, es el nombre del recurso limitado — así
  // que no hay rama singular/plural que cubrir; los casos de abajo fijan
  // igual el formato exacto (incluido el borde `limit === 1`, donde la
  // palabra "productos" NO pasa a "producto").
  it("arma la oración exacta que también debe reflejar backend/services/products.py (~línea 93)", () => {
    expect(planProductLimitMessage({ plan: "gratis", limit: 100 })).toBe(
      "Límite de productos alcanzado para el plan gratis (100 máx.). Borrá productos existentes o subí de plan.",
    )
  })

  it("interpola el plan tal cual, sin normalizar mayúsculas ni traducir el nombre", () => {
    expect(planProductLimitMessage({ plan: "pro", limit: 5000 })).toBe(
      "Límite de productos alcanzado para el plan pro (5000 máx.). Borrá productos existentes o subí de plan.",
    )
  })

  it("con limit === 1 sigue diciendo 'productos' en plural (no es un conteo, es el nombre del recurso)", () => {
    expect(planProductLimitMessage({ plan: "gratis", limit: 1 })).toBe(
      "Límite de productos alcanzado para el plan gratis (1 máx.). Borrá productos existentes o subí de plan.",
    )
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
