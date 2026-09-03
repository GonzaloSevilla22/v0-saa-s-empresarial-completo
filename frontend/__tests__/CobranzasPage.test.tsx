/**
 * CobranzasPage — panel de deudores /cobranzas (cobranzas-panel, tasks
 * 5.1-5.4). Molde de ProveedoresPage.test.tsx.
 *
 * Invariantes bajo test:
 * - Cabecera con el total por cobrar (de useReceivablesSummary, D2).
 * - Una fila por deudor con saldo y antigüedades; la antigüedad ausente se
 *   muestra como "—" y NUNCA como 0 (D4/OQ-4).
 * - Estado vacío explicativo sin deudores (no una tabla vacía).
 * - El botón Cobrar abre un Dialog con el RegisterPaymentForm EXISTENTE
 *   (mockeado acá: su cobertura vive en RegisterPaymentForms.test.tsx) — D8.
 * - El acceso por fila navega a /clientes/[id]/cuenta con nombre accesible.
 * - "El panel no promete mora": rótulo "Último cargo", nota de vencimientos,
 *   y ni "mora" ni "vencido" en ninguna parte.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import "@testing-library/jest-dom"

const pushMock = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
}))

const useReceivablesMock = vi.fn()
const useReceivablesSummaryMock = vi.fn()
vi.mock("@/hooks/data/use-receivables", () => ({
  useReceivables: (params: unknown) => useReceivablesMock(params),
  useReceivablesSummary: () => useReceivablesSummaryMock(),
}))

vi.mock("@/components/customer-accounts/RegisterPaymentForm", () => ({
  RegisterPaymentForm: ({ clientId }: { clientId: string }) => (
    <div data-testid="register-payment-form-stub">{clientId}</div>
  ),
}))

import CobranzasPage from "@/app/(dashboard)/cobranzas/page"

const ROWS = [
  {
    clientId: "client-1",
    clientName: "Deudor Grande",
    balance: 167800,
    daysSinceLastCharge: 12,
    daysSinceLastPayment: 30,
    lastPaymentDate: "2026-08-03",
  },
  {
    clientId: "client-2",
    clientName: "Solo Ajuste",
    balance: 3000,
    daysSinceLastCharge: null,
    daysSinceLastPayment: null,
    lastPaymentDate: null,
  },
]

function pageReturn(overrides: Record<string, unknown> = {}) {
  return {
    data: { items: ROWS, total: 2, page: 0, pages: 1 },
    isLoading: false,
    isError: false,
    ...overrides,
  }
}

function summaryReturn(overrides: Record<string, unknown> = {}) {
  return {
    data: { totalReceivable: 170800, debtorCount: 2 },
    isLoading: false,
    isError: false,
    ...overrides,
  }
}

describe("CobranzasPage", () => {
  beforeEach(() => {
    pushMock.mockReset()
    useReceivablesMock.mockReset()
    useReceivablesSummaryMock.mockReset()
    useReceivablesMock.mockReturnValue(pageReturn())
    useReceivablesSummaryMock.mockReturnValue(summaryReturn())
  })

  it("muestra el total por cobrar en la cabecera (del resumen, D2)", () => {
    render(<CobranzasPage />)
    expect(screen.getByText("Total por cobrar")).toBeInTheDocument()
    // formatMoney es-AR: $ 170.800,00
    expect(screen.getAllByText(/170\.800/).length).toBeGreaterThan(0)
  })

  it("lista una fila por deudor con saldo y antigüedades", () => {
    render(<CobranzasPage />)
    expect(screen.getByText("Deudor Grande")).toBeInTheDocument()
    expect(screen.getByText("Solo Ajuste")).toBeInTheDocument()
    expect(screen.getAllByText(/167\.800/).length).toBeGreaterThan(0)
    expect(screen.getByText(/12 días/)).toBeInTheDocument()
    expect(screen.getByText(/30 días/)).toBeInTheDocument()
  })

  it("la antigüedad ausente se muestra como — y no como 0 (OQ-4)", () => {
    render(<CobranzasPage />)
    const row = screen.getByTestId("receivable-row-client-2")
    expect(within(row).getAllByText("—").length).toBeGreaterThanOrEqual(2)
    expect(within(row).queryByText(/0 días/)).not.toBeInTheDocument()
  })

  it("sin deudores muestra un estado vacío explicativo, no una tabla vacía", () => {
    useReceivablesMock.mockReturnValue(
      pageReturn({ data: { items: [], total: 0, page: 0, pages: 0 } }),
    )
    useReceivablesSummaryMock.mockReturnValue(
      summaryReturn({ data: { totalReceivable: 0, debtorCount: 0 } }),
    )
    render(<CobranzasPage />)
    expect(screen.getByTestId("receivables-empty")).toBeInTheDocument()
    expect(screen.queryByTestId("receivable-row-client-1")).not.toBeInTheDocument()
  })

  it("Cobrar abre un Dialog con el RegisterPaymentForm existente (D8)", () => {
    render(<CobranzasPage />)
    fireEvent.click(screen.getByTestId("receivable-collect-client-1"))
    expect(screen.getByTestId("register-payment-form-stub")).toHaveTextContent("client-1")
  })

  it("el acceso por fila navega a la cuenta corriente con nombre accesible", () => {
    render(<CobranzasPage />)
    const btn = screen.getByTestId("receivable-account-client-1")
    expect(btn).toHaveAccessibleName(/Deudor Grande/)
    fireEvent.click(btn)
    expect(pushMock).toHaveBeenCalledWith("/clientes/client-1/cuenta")
  })

  it("no promete mora: rótulo 'Último cargo', nota de vencimientos, sin 'mora'/'vencido'", () => {
    const { container } = render(<CobranzasPage />)
    expect(screen.getAllByText(/Último cargo/).length).toBeGreaterThan(0)
    expect(screen.getByText(/no registra vencimientos/i)).toBeInTheDocument()
    expect(container.textContent).not.toMatch(/mora/i)
    expect(container.textContent?.toLowerCase()).not.toContain("vencido")
  })

  it("la tabla scrollea en su contenedor (overflow-x-auto + min-w)", () => {
    const { container } = render(<CobranzasPage />)
    const scroller = container.querySelector(".overflow-x-auto")
    expect(scroller).not.toBeNull()
    expect(scroller?.querySelector("table")?.className).toMatch(/min-w-/)
  })
})
