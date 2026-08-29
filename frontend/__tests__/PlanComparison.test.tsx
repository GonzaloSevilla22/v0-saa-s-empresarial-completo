/**
 * mp-real-subscriptions (D2bis, task 8.1 RED / 8.2 GREEN) — PlanComparison
 * intenta el flujo nuevo de suscripciones primero; cae al legacy de pago
 * único cuando el backend responde que la palanca está apagada (503).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

const pushMock = vi.fn()
const refreshMock = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock, refresh: refreshMock }),
}))

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}))

const createSubscriptionMock = vi.fn()
// planes-suscribirse-plan-vigente (D8, task 4.5): se preservan los demás
// exports reales del módulo (importOriginal) — se necesita la clase real
// `SubscriptionConflictError` para simular el 409 residual sin depender de
// matching de texto contra el `detail` crudo del backend.
vi.mock("@/lib/api/subscriptions-client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api/subscriptions-client")>()
  return {
    ...actual,
    createSubscription: (...args: unknown[]) => createSubscriptionMock(...args),
  }
})

import { PlanComparison } from "@/components/billing/PlanComparison"
import { SubscriptionConflictError } from "@/lib/api/subscriptions-client"
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

/**
 * planes-suscribirse-plan-vigente (grupo 4, D3/D4/D8) — regla única de
 * contratación: `tier !== 'gratis' && !billingExempt && !haySuscripcionViva`.
 * El caso central es el incidente del 29-08: `danielsevilla64` tenía PRO
 * como plan efectivo, sin suscripción viva, y no había CTA.
 */
describe("PlanComparison — regla única de contratación (grupo 4)", () => {
  it("cuenta sin suscripción viva y plan efectivo 'pro': el CTA de PRO contrata PRO (task 4.2, incidente 29-08)", async () => {
    createSubscriptionMock.mockResolvedValue({
      enabled: true,
      data: {
        init_point: "https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=plan-pro",
        intent_id: "intent-pro-1",
        plan: "pro",
        expires_at: "2026-08-29T00:00:00Z",
      },
    })

    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="pro" />)

    await user.click(screen.getByRole("button", { name: /suscribirme a pro/i }))

    expect(createSubscriptionMock).toHaveBeenCalledWith("pro")
    expect(pushMock).toHaveBeenCalledWith(
      "https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=plan-pro",
    )
  })

  it("con suscripción viva: ningún CTA visible dispara createSubscription (task 4.4)", async () => {
    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="avanzado" liveSubscriptionPlan="avanzado" />)

    expect(screen.queryByRole("button", { name: /suscribirme|pasarme/i })).not.toBeInTheDocument()

    const links = screen.getAllByRole("link", { name: /facturaci/i })
    expect(links.length).toBeGreaterThan(0)
    for (const link of links) {
      await user.click(link)
    }

    expect(createSubscriptionMock).not.toHaveBeenCalled()
    expect(global.fetch).not.toHaveBeenCalled()
  })

  it("con billingExempt=true: ningún CTA de contratación alcanzable en los cuatro tiers (task 4.4)", () => {
    render(<PlanComparison plans={PLANS} currentPlan="avanzado" billingExempt={true} />)

    // A lo sumo queda el botón de Gratis (siempre deshabilitado) — cero
    // botones de contratación habilitados en ningún tier.
    const buttons = screen.getAllByRole("button")
    for (const button of buttons) {
      expect(button).toBeDisabled()
    }
    expect(screen.queryByRole("link", { name: /facturaci/i })).not.toBeInTheDocument()
    expect(createSubscriptionMock).not.toHaveBeenCalled()
    expect(global.fetch).not.toHaveBeenCalled()
  })

  it("409 residual: mensaje propio (no el detail crudo) + router.refresh() (task 4.5, D8)", async () => {
    createSubscriptionMock.mockRejectedValue(
      new SubscriptionConflictError("Ya existe una suscripción viva para esta cuenta"),
    )
    const { toast } = await import("sonner")

    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="pro" />)

    await user.click(screen.getByRole("button", { name: /suscribirme a pro/i }))

    expect(toast.error).toHaveBeenCalledTimes(1)
    const [message] = (toast.error as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(message).not.toBe("Ya existe una suscripción viva para esta cuenta")
    expect(refreshMock).toHaveBeenCalledTimes(1)
  })

  it("error no-409: conserva el toast con el mensaje crudo, sin refresh (task 4.5, triangulación)", async () => {
    createSubscriptionMock.mockRejectedValue(new Error("Fallo de red inesperado"))
    const { toast } = await import("sonner")

    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="pro" />)

    await user.click(screen.getByRole("button", { name: /suscribirme a pro/i }))

    expect(toast.error).toHaveBeenCalledWith("Fallo de red inesperado")
    expect(refreshMock).not.toHaveBeenCalled()
  })

  it("con billingExempt=true: el comparativo con precios y features sigue completo (task 6.1)", () => {
    render(<PlanComparison plans={PLANS} currentPlan="avanzado" billingExempt={true} />)

    for (const name of ["Gratis", "Inicial", "Avanzado", "Pro"]) {
      expect(screen.getByRole("heading", { name })).toBeInTheDocument()
    }
    expect(screen.getAllByText("$24.900/mes").length).toBeGreaterThan(0)
    expect(screen.getByTestId("billing-exempt-notice")).toBeInTheDocument()
  })

  it("aviso de cortesía con canal de contacto configurado: incluye el link (task 6.2)", () => {
    render(
      <PlanComparison
        plans={PLANS}
        currentPlan="avanzado"
        billingExempt={true}
        contactUrl="https://wa.me/5492617635174"
      />,
    )

    const notice = screen.getByTestId("billing-exempt-notice")
    const link = within(notice).getByRole("link")
    expect(link).toHaveAttribute("href", "https://wa.me/5492617635174")
  })

  it("aviso de cortesía sin canal configurado: se muestra igual, sin link (task 6.2, OQ-2 triangulación)", () => {
    render(
      <PlanComparison plans={PLANS} currentPlan="avanzado" billingExempt={true} contactUrl={null} />,
    )

    const notice = screen.getByTestId("billing-exempt-notice")
    expect(notice).toBeInTheDocument()
    expect(within(notice).queryByRole("link")).not.toBeInTheDocument()
  })

  it("sin billingExempt: no se muestra el aviso de cortesía (task 6.2 triangulación)", () => {
    render(<PlanComparison plans={PLANS} currentPlan="avanzado" billingExempt={false} />)

    expect(screen.queryByTestId("billing-exempt-notice")).not.toBeInTheDocument()
  })

  it("palanca apagada (503) en el tier vigente: cae al flujo legacy igual que cualquier otro tier (task 4.6)", async () => {
    createSubscriptionMock.mockResolvedValue({ enabled: false })
    ;(global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      json: async () => ({ ok: true, initPoint: "https://mercadopago.com/legacy-pro-checkout" }),
    })

    const user = userEvent.setup()
    render(<PlanComparison plans={PLANS} currentPlan="pro" />)

    await user.click(screen.getByRole("button", { name: /suscribirme a pro/i }))

    expect(createSubscriptionMock).toHaveBeenCalledWith("pro")
    expect(global.fetch).toHaveBeenCalledWith(
      "/api/billing/preferences",
      expect.objectContaining({ method: "POST" }),
    )
    expect(pushMock).toHaveBeenCalledWith("https://mercadopago.com/legacy-pro-checkout")
  })
})
