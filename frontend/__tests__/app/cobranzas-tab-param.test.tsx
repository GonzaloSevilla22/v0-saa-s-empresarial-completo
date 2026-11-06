/**
 * tablero-explicable (D6, task 3.4): /cobranzas?tab=payables abre «Por pagar»
 * (destino de la notificación PayablesOverdueDigest); sin parámetro o con un
 * valor desconocido abre «Por cobrar». Cambiar de pestaña no reescribe la URL.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

let searchParams = new URLSearchParams("")
const replaceMock = vi.fn()
const pushMock = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock, replace: replaceMock }),
  useSearchParams: () => searchParams,
}))

vi.mock("@/hooks/data/use-receivables", () => ({
  useReceivables: () => ({ data: { items: [], total: 0, page: 0, pages: 1 }, isLoading: false, isError: false }),
  useReceivablesSummary: () => ({ data: { totalReceivable: 0, overdueTotal: 0, debtorCount: 0 }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-payables", () => ({
  usePayables: () => ({ data: { items: [], total: 0, page: 0, pages: 1 }, isLoading: false, isError: false }),
  usePayablesSummary: () => ({ data: { totalPayable: 0, overdueTotal: 0, creditorCount: 0 }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: 30 }, isLoading: false }),
}))
vi.mock("@/components/customer-accounts/RegisterPaymentForm", () => ({
  RegisterPaymentForm: () => null,
}))
vi.mock("@/components/supplier-accounts/RegisterPaymentMadeForm", () => ({
  RegisterPaymentMadeForm: () => null,
}))

import CobranzasPage from "@/app/(dashboard)/cobranzas/page"

beforeEach(() => {
  searchParams = new URLSearchParams("")
  replaceMock.mockReset()
  pushMock.mockReset()
})

function selectedTab() {
  return screen.getAllByRole("tab").find((t) => t.getAttribute("aria-selected") === "true")
}

describe("CobranzasPage — ?tab=", () => {
  it("?tab=payables abre «Por pagar»", () => {
    searchParams = new URLSearchParams("tab=payables")
    render(<CobranzasPage />)
    expect(selectedTab()).toHaveTextContent(/Por pagar/)
  })

  it("sin parámetro abre «Por cobrar»", () => {
    render(<CobranzasPage />)
    expect(selectedTab()).toHaveTextContent(/Por cobrar/)
  })

  it("un valor desconocido abre «Por cobrar»", () => {
    searchParams = new URLSearchParams("tab=cualquier-cosa")
    render(<CobranzasPage />)
    expect(selectedTab()).toHaveTextContent(/Por cobrar/)
  })

  it("?tab=receivables abre «Por cobrar»", () => {
    searchParams = new URLSearchParams("tab=receivables")
    render(<CobranzasPage />)
    expect(selectedTab()).toHaveTextContent(/Por cobrar/)
  })

  it("cambiar de pestaña no reescribe la URL", async () => {
    const user = userEvent.setup()
    searchParams = new URLSearchParams("tab=payables")
    render(<CobranzasPage />)

    await user.click(screen.getByRole("tab", { name: /Por cobrar/ }))

    expect(selectedTab()).toHaveTextContent(/Por cobrar/)
    expect(replaceMock).not.toHaveBeenCalled()
    expect(pushMock).not.toHaveBeenCalled()
  })
})
