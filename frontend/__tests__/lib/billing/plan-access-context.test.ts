/**
 * planes-suscribirse-plan-vigente (grupo 5/6, D5) — línea de contexto del
 * plan efectivo: explica POR QUÉ se le ofrece pagar un plan que ya está
 * usando. Se deriva de los campos CRUDOS (`billing_exempt`,
 * `trial_expires_at`, `plan_expires_at`), NUNCA de `getEffectivePlan`
 * (D6: el espejo no lee `plan_expires_at` y heredaría esa divergencia
 * justo en el caso donde más importa).
 *
 * Precedencia idéntica a `getEffectivePlan` (D1 de billing-pro-trial):
 * cortesía > trial vigente > plan pago con vencimiento > sin motivo.
 */
import { describe, it, expect } from "vitest"
import { resolvePlanAccessContextLine } from "@/lib/billing/plan-access-context"

const HOUR = 60 * 60 * 1000
function isoIn(msFromNow: number): string {
  return new Date(Date.now() + msFromNow).toISOString()
}

describe("resolvePlanAccessContextLine — precedencia de motivos (D5)", () => {
  it("cortesía (billing_exempt=true): explica el acceso sin cargo", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: true,
      trialPlan: null,
      trialExpiresAt: null,
      billingPlan: "gratis",
      planExpiresAt: null,
    })
    expect(line).toMatch(/sin cargo/i)
  })

  it("trial vigente: menciona hasta cuándo va el trial", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: false,
      trialPlan: "pro",
      trialExpiresAt: isoIn(10 * 24 * HOUR),
      billingPlan: "gratis",
      planExpiresAt: null,
    })
    expect(line).toMatch(/prueba/i)
  })

  it("plan pago con vencimiento futuro: menciona cuándo se corta el acceso (caso real danielsevilla64)", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: false,
      trialPlan: null,
      trialExpiresAt: null,
      billingPlan: "pro",
      planExpiresAt: isoIn(30 * 24 * HOUR),
    })
    expect(line).toMatch(/vence/i)
  })

  it("sin motivo aplicable (plan pago sin vencimiento, sin trial, sin exención): no hay línea", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: false,
      trialPlan: null,
      trialExpiresAt: null,
      billingPlan: "avanzado",
      planExpiresAt: null,
    })
    expect(line).toBeNull()
  })

  it("plan gratis sin trial ni exención: no hay línea", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: false,
      trialPlan: null,
      trialExpiresAt: null,
      billingPlan: "gratis",
      planExpiresAt: null,
    })
    expect(line).toBeNull()
  })

  it("plan pago con vencimiento YA PASADO: no hay línea (evita 'vence el <fecha pasada>')", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: false,
      trialPlan: null,
      trialExpiresAt: null,
      billingPlan: "pro",
      planExpiresAt: isoIn(-HOUR),
    })
    expect(line).toBeNull()
  })

  it("trial vencido: cae a plan pago con vencimiento si aplica, no a la línea de trial", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: false,
      trialPlan: "pro",
      trialExpiresAt: isoIn(-HOUR),
      billingPlan: "pro",
      planExpiresAt: isoIn(30 * 24 * HOUR),
    })
    expect(line).toMatch(/vence/i)
    expect(line).not.toMatch(/prueba/i)
  })

  it("cortesía tiene precedencia sobre un trial vigente simultáneo", () => {
    const line = resolvePlanAccessContextLine({
      billingExempt: true,
      trialPlan: "pro",
      trialExpiresAt: isoIn(10 * 24 * HOUR),
      billingPlan: "gratis",
      planExpiresAt: null,
    })
    expect(line).toMatch(/sin cargo/i)
  })
})
