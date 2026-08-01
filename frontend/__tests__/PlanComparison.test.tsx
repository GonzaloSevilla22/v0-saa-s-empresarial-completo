/**
 * mp-real-subscriptions (D2bis, task 8.1 RED / 8.2 GREEN) — PlanComparison
 * intenta el flujo nuevo de suscripciones primero; cae al legacy de pago
 * único cuando el backend responde que la palanca está apagada (503).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

const pushMock = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
}))

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}))

const createSubscriptionMock = vi.fn()
vi.mock("@/lib/api/subscriptions-client", () => ({
  createSubscription: (...args: unknown[]) => createSubscriptionMock(...args),
}))

import { PlanComparison } from "@/components/billing/PlanComparison"
import type { Plan, PlanLimits } from "@/lib/types"

const PLANS: PlanLimits[] = (["gratis", "inicial", "avanzado", "pro"] as Plan[]).map((plan) => ({
  plan,
  priceMonthly: plan === "gratis" ? 0 : 24900,
  maxUsers: 1,
  maxProducts: 100,
  maxOperationsPerMonth: 100,
  historyDays: 30,
  maxAiQueriesPerMonth: 5,
  maxExportsPerMonth: 0,
})) as unknown as PlanLimits[]

beforeEach(() => {
  vi.clearAllMocks()
  global.fetch = vi.fn()
})

describe("PlanComparison — flujo nuevo de suscripciones (task 8.1/8.2)", () => {
  it("cuando la palanca está ON, redirige al init_point devuelto por el backend (D2bis)", async () => {
    createSubscriptionMock.mockResolvedValue({
      enabled: true,
      data: {
        init_point: "https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=plan-1",
        intent_id: "intent-1",
        plan: "avanzado",
        expires_at: "2026-08-02T00:00:00Z",
      },
    })

    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="gratis" />)

    await user.click(screen.getByRole("button", { name: /pasarme a avanzado/i }))

    expect(createSubscriptionMock).toHaveBeenCalledWith("avanzado")
    expect(pushMock).toHaveBeenCalledWith(
      "https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=plan-1",
    )
    // El flujo legacy NUNCA se llamó — no hubo fetch a /api/billing/preferences.
    expect(global.fetch).not.toHaveBeenCalled()
  })

  it("cuando la palanca está OFF (503), degrada limpio al flujo legacy sin avisar al usuario (no-regresión)", async () => {
    createSubscriptionMock.mockResolvedValue({ enabled: false })
    ;(global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      json: async () => ({ ok: true, initPoint: "https://mercadopago.com/legacy-checkout" }),
    })

    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="gratis" />)

    await user.click(screen.getByRole("button", { name: /pasarme a avanzado/i }))

    expect(createSubscriptionMock).toHaveBeenCalledWith("avanzado")
    expect(global.fetch).toHaveBeenCalledWith(
      "/api/billing/preferences",
      expect.objectContaining({ method: "POST" }),
    )
    expect(pushMock).toHaveBeenCalledWith("https://mercadopago.com/legacy-checkout")
  })

  it("el plan gratis nunca dispara ningún flujo de pago", async () => {
    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="avanzado" />)

    await user.click(screen.getByRole("button", { name: /cancelar y bajar a gratis/i }))

    expect(createSubscriptionMock).not.toHaveBeenCalled()
    expect(global.fetch).not.toHaveBeenCalled()
  })
})
