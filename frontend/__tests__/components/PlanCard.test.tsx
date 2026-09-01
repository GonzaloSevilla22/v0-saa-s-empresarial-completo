/**
 * planes-suscribirse-plan-vigente (grupo 3, D3/D4) — PlanCard separa el
 * "destacado" (currentPlan, badge de plan efectivo) de la "disponibilidad
 * de contratación" (canContract + liveSubscriptionPlan, que gobiernan el
 * CTA). Antes de este change ambas cosas colapsaban en `isCurrent`, que es
 * exactamente el bug del incidente del 29-08 (`danielsevilla64`): tenía
 * acceso a PRO por cortesía, sin suscripción viva, y el botón estaba
 * deshabilitado igual.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import { PlanCard } from "@/components/billing/PlanCard"
import type { Plan, PlanLimits } from "@/lib/types"

function makeLimits(plan: Plan, priceMonthly: number): PlanLimits {
  return {
    plan,
    priceMonthly,
    maxUsers: 1,
    maxProducts: 100,
    maxClients: 50,
    maxSuppliers: 20,
    maxOperationsPerMonth: 100,
    historyDays: 30,
    maxExportsPerMonth: 0,
    maxAiQueriesPerMonth: 5,
    maxAiAdvicePerMonth: 3,
    maxBranches: 1,
    hasProductProfitability: false,
    hasComparativeReports: false,
    hasPriceSuggestion: false,
    hasBranchesModule: false,
    hasMonthlyAnalysis: false,
    internalRoles: "none",
  } as unknown as PlanLimits
}

const PRO_LIMITS = makeLimits("pro", 69900)
const INICIAL_LIMITS = makeLimits("inicial", 24900)
const GRATIS_LIMITS = makeLimits("gratis", 0)

describe("PlanCard — destacado vs. disponibilidad de contratación (3.2/3.4)", () => {
  it("plan efectivo + contratación disponible: badge de plan actual Y CTA habilitado (caso del incidente 29-08)", () => {
    const onSelect = vi.fn()
    render(
      <PlanCard
        plan="pro"
        currentPlan="pro"
        limits={PRO_LIMITS}
        onSelect={onSelect}
        canContract={true}
        liveSubscriptionPlan={null}
      />,
    )

    expect(screen.getByText("Plan actual")).toBeInTheDocument()
    const button = screen.getByRole("button", { name: /suscribirme a pro/i })
    expect(button).toBeEnabled()
  })

  it("plan efectivo + contratación NO disponible (suscripción viva): badge presente, sin CTA de compra, con el aviso OQ-5", () => {
    render(
      <PlanCard
        plan="pro"
        currentPlan="pro"
        limits={PRO_LIMITS}
        onSelect={vi.fn()}
        canContract={false}
        liveSubscriptionPlan="pro"
      />,
    )

    expect(screen.getByText("Plan actual")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /suscribirme/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /facturaci/i })).not.toBeInTheDocument()
    // OQ-5 (recomendación "decirlo"): se comunica explícitamente, no se disimula.
    expect(screen.getByText(/ya tenés una suscripción activa de este plan/i)).toBeInTheDocument()
  })

  it("plan gratis: nunca CTA de pago, con contratación disponible", () => {
    render(
      <PlanCard
        plan="gratis"
        currentPlan="pro"
        limits={GRATIS_LIMITS}
        onSelect={vi.fn()}
        canContract={true}
        liveSubscriptionPlan={null}
      />,
    )

    const button = screen.getByRole("button")
    expect(button).toBeDisabled()
  })

  it("plan gratis: nunca CTA de pago, sin contratación disponible", () => {
    render(
      <PlanCard
        plan="gratis"
        currentPlan="pro"
        limits={GRATIS_LIMITS}
        onSelect={vi.fn()}
        canContract={false}
        liveSubscriptionPlan="pro"
      />,
    )

    const button = screen.getByRole("button")
    expect(button).toBeDisabled()
  })

  it("tier inferior con contratación disponible: CTA de contratación, NO 'Cancelar y bajar'", () => {
    const onSelect = vi.fn()
    render(
      <PlanCard
        plan="inicial"
        currentPlan="pro"
        limits={INICIAL_LIMITS}
        onSelect={onSelect}
        canContract={true}
        liveSubscriptionPlan={null}
      />,
    )

    expect(screen.queryByText(/cancelar y bajar/i)).not.toBeInTheDocument()
    const button = screen.getByRole("button", { name: /suscribirme a inicial/i })
    expect(button).toBeEnabled()
  })

  it("tier inferior con suscripción viva (en otro tier): enlace a /facturación, sin acción de compra (D4)", async () => {
    const onSelect = vi.fn()
    const user = userEvent.setup()
    render(
      <PlanCard
        plan="inicial"
        currentPlan="pro"
        limits={INICIAL_LIMITS}
        onSelect={onSelect}
        canContract={false}
        liveSubscriptionPlan="pro"
      />,
    )

    expect(screen.queryByRole("button", { name: /suscribirme|pasarme|cancelar y bajar/i })).not.toBeInTheDocument()
    const link = screen.getByRole("link", { name: /facturaci/i })
    expect(link).toHaveAttribute("href", "/facturacion")

    await user.click(link)
    expect(onSelect).not.toHaveBeenCalled()
  })

  // qa-integral-modulos G10 (H21c): mientras el alta está en vuelo el botón
  // tiene que DECIR que está procesando — antes solo se deshabilitaba sin
  // señal visible, invitando al reintento en loop.
  it("loading: el CTA muestra estado de carga visible y queda deshabilitado (G10/H21c)", () => {
    render(
      <PlanCard
        plan="pro"
        currentPlan="inicial"
        limits={PRO_LIMITS}
        onSelect={vi.fn()}
        canContract={true}
        liveSubscriptionPlan={null}
        loading={true}
      />,
    )

    const btn = screen.getByRole("button")
    expect(btn).toBeDisabled()
    expect(btn).toHaveTextContent(/Procesando/i)
  })

  it("ninguna etiqueta visible anuncia una baja de plan cuando se ofrece contratación (3.5)", () => {
    render(
      <PlanCard
        plan="inicial"
        currentPlan="pro"
        limits={INICIAL_LIMITS}
        onSelect={vi.fn()}
        canContract={true}
        liveSubscriptionPlan={null}
      />,
    )

    expect(screen.queryByText(/cancelar y bajar/i)).not.toBeInTheDocument()
  })
})
