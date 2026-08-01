/**
 * mp-real-subscriptions (D2bis, task 8.3 RED / 8.4 GREEN) —
 * CancelSubscriptionModal muestra la fecha del período REALMENTE pagado
 * (backend) cuando hay una suscripción real; si no, degrada al estimado
 * legacy de 30 días (no-regresión con la palanca apagada).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
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

const getSubscriptionStatusMock = vi.fn()
const cancelSubscriptionMock = vi.fn()
vi.mock("@/lib/api/subscriptions-client", () => ({
  getSubscriptionStatus: (...args: unknown[]) => getSubscriptionStatusMock(...args),
  cancelSubscription: (...args: unknown[]) => cancelSubscriptionMock(...args),
}))

import { CancelSubscriptionModal } from "@/components/billing/CancelSubscriptionModal"

beforeEach(() => {
  vi.clearAllMocks()
  global.fetch = vi.fn()
})

async function openDialog() {
  const user = userEvent.setup()
  render(<CancelSubscriptionModal currentPlan="avanzado" />)
  await user.click(screen.getByRole("button", { name: /cancelar suscripción/i }))
  return user
}

// Mediodía UTC — no ambiguo respecto de la zona horaria local del entorno
// de test (Mendoza es UTC-3; medianoche UTC correría al día anterior local).
const NEXT_PAYMENT_DATE = "2026-09-15T12:00:00Z"

describe("CancelSubscriptionModal — fecha real del período pagado (task 8.3)", () => {
  it("muestra next_payment_date del backend cuando hay suscripción real, no un estimado", async () => {
    getSubscriptionStatusMock.mockResolvedValue({
      enabled: true,
      data: {
        id: "sub-1", plan: "avanzado", status: "authorized",
        next_payment_date: NEXT_PAYMENT_DATE,
        amount: null, currency: "ARS", retry_state: "none",
      },
    })

    await openDialog()

    expect(await screen.findByText(/15 de septiembre de 2026/i)).toBeInTheDocument()
  })

  it("degrada al estimado legacy de 30 días cuando la palanca está OFF (no-regresión)", async () => {
    getSubscriptionStatusMock.mockResolvedValue({ enabled: false })

    await openDialog()

    // No debe reventar ni mostrar una fecha `Invalid Date` — cae al legacy.
    await waitFor(() => {
      expect(getSubscriptionStatusMock).toHaveBeenCalled()
    })
    expect(screen.queryByText(/Invalid Date/i)).not.toBeInTheDocument()
  })
})

describe("CancelSubscriptionModal — cancelación (task 8.4)", () => {
  it("con suscripción real, confirmar llama a cancelSubscription (backend), no al endpoint legacy", async () => {
    getSubscriptionStatusMock.mockResolvedValue({
      enabled: true,
      data: {
        id: "sub-1", plan: "avanzado", status: "authorized",
        next_payment_date: NEXT_PAYMENT_DATE,
        amount: null, currency: "ARS", retry_state: "none",
      },
    })
    cancelSubscriptionMock.mockResolvedValue({
      enabled: true,
      data: { ok: true, plan_expires_at: NEXT_PAYMENT_DATE },
    })

    const user = await openDialog()
    await screen.findByText(/15 de septiembre de 2026/i)
    await user.click(screen.getByRole("button", { name: /confirmar cancelación/i }))

    await waitFor(() => expect(cancelSubscriptionMock).toHaveBeenCalled())
    expect(global.fetch).not.toHaveBeenCalled()
  })

  it("sin suscripción real, confirmar llama al endpoint legacy /api/billing/cancel", async () => {
    getSubscriptionStatusMock.mockResolvedValue({ enabled: false })
    ;(global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      json: async () => ({ ok: true }),
    })

    const user = await openDialog()
    await waitFor(() => expect(getSubscriptionStatusMock).toHaveBeenCalled())
    await user.click(screen.getByRole("button", { name: /confirmar cancelación/i }))

    await waitFor(() =>
      expect(global.fetch).toHaveBeenCalledWith("/api/billing/cancel", expect.objectContaining({ method: "POST" })),
    )
    expect(cancelSubscriptionMock).not.toHaveBeenCalled()
  })
})
