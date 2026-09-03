/**
 * cobranzas-vencimientos (tasks 9.1-9.4) — /cobranzas con vencimientos.
 *
 * Invariantes bajo test:
 * - Columna de importe vencido y ESTADO en texto por fila (D15 — nunca sólo
 *   color); el deudor sin vencimiento se presenta como tal, no como al día.
 * - Cabecera con total por cobrar Y total vencido, distinguidos.
 * - El filtro de tramo viaja al SERVIDOR (el hook recibe bucket) y no
 *   reordena en el cliente.
 * - Pestañas Por cobrar / Por pagar en la misma pantalla; la de pagar abre
 *   el RegisterPaymentMadeForm EXISTENTE y tiene EmptyState propio.
 * - Botón de recordatorio por WhatsApp con nombre accesible; sin teléfono
 *   utilizable abre wa.me sin destinatario (no queda inoperante).
 * - La nota vieja "no registra vencimientos" fue retirada (REMOVED del delta)
 *   y en su lugar, sin plazos configurados, se explica y ofrece Configuración.
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

const usePayablesMock = vi.fn()
const usePayablesSummaryMock = vi.fn()
vi.mock("@/hooks/data/use-payables", () => ({
  usePayables: (params: unknown) => usePayablesMock(params),
  usePayablesSummary: () => usePayablesSummaryMock(),
}))

const useCollectionSettingsMock = vi.fn()
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => useCollectionSettingsMock(),
}))

vi.mock("@/components/customer-accounts/RegisterPaymentForm", () => ({
  RegisterPaymentForm: ({ clientId }: { clientId: string }) => (
    <div data-testid="register-payment-form-stub">{clientId}</div>
  ),
}))

vi.mock("@/components/supplier-accounts/RegisterPaymentMadeForm", () => ({
  RegisterPaymentMadeForm: ({ supplierId }: { supplierId: string }) => (
    <div data-testid="register-payment-made-form-stub">{supplierId}</div>
  ),
}))

import CobranzasPage from "@/app/(dashboard)/cobranzas/page"

const AGING_ROWS = [
  {
    clientId: "client-1",
    clientName: "Deudor Vencido",
    clientPhone: "261 555-1234",
    balance: 2500,
    daysSinceLastCharge: 12,
    daysSinceLastPayment: 30,
    lastPaymentDate: "2026-08-03",
    overdueTotal: 1500,
    amountCurrent: 300,
    amountOverdue1_30: 1000,
    amountOverdue31_60: 500,
    amountOverdue60Plus: 0,
    amountNoDueDate: 700,
    oldestDueDate: "2026-07-20",
    daysOverdueMax: 44,
  },
  {
    clientId: "client-2",
    clientName: "Sin Plazo",
    clientPhone: null,
    balance: 700,
    daysSinceLastCharge: 200,
    daysSinceLastPayment: null,
    lastPaymentDate: null,
    overdueTotal: 0,
    amountCurrent: 0,
    amountOverdue1_30: 0,
    amountOverdue31_60: 0,
    amountOverdue60Plus: 0,
    amountNoDueDate: 700,
    oldestDueDate: null,
    daysOverdueMax: null,
  },
]

const PAYABLE_ROWS = [
  {
    supplierId: "sup-1",
    supplierName: "Proveedor Vencido",
    balance: 800,
    daysSinceLastCharge: 15,
    daysSinceLastPayment: null,
    lastPaymentDate: null,
    overdueTotal: 500,
    amountCurrent: 0,
    amountOverdue1_30: 500,
    amountOverdue31_60: 0,
    amountOverdue60Plus: 0,
    amountNoDueDate: 300,
    oldestDueDate: "2026-08-23",
    daysOverdueMax: 10,
  },
]

function pageReturn(items: unknown[], overrides: Record<string, unknown> = {}) {
  return {
    data: { items, total: items.length, page: 0, pages: 1 },
    isLoading: false,
    isError: false,
    ...overrides,
  }
}

beforeEach(() => {
  pushMock.mockReset()
  useReceivablesMock.mockReset().mockReturnValue(pageReturn(AGING_ROWS))
  useReceivablesSummaryMock.mockReset().mockReturnValue({
    data: { totalReceivable: 3200, overdueTotal: 1500, debtorCount: 2 },
    isLoading: false,
  })
  usePayablesMock.mockReset().mockReturnValue(pageReturn(PAYABLE_ROWS))
  usePayablesSummaryMock.mockReset().mockReturnValue({
    data: { totalPayable: 800, overdueTotal: 500, creditorCount: 1 },
    isLoading: false,
  })
  useCollectionSettingsMock.mockReset().mockReturnValue({
    data: { defaultPaymentTermsDays: 30 },
    isLoading: false,
  })
})

describe("CobranzasPage — vencimientos (9.1/9.2)", () => {
  it("muestra importe vencido y estado EN TEXTO por fila", () => {
    render(<CobranzasPage />)
    const row = screen.getByTestId("receivable-row-client-1")
    expect(within(row).getAllByText(/1\.500/).length).toBeGreaterThan(0)
    expect(within(row).getByText("Vencido hace 44 días")).toBeInTheDocument()
  })

  it("el deudor sin vencimiento se presenta como tal — nunca al día", () => {
    render(<CobranzasPage />)
    const row = screen.getByTestId("receivable-row-client-2")
    expect(within(row).getByText("Sin vencimiento")).toBeInTheDocument()
    expect(within(row).queryByText("Al día")).not.toBeInTheDocument()
  })

  it("la cabecera distingue total por cobrar y total vencido", () => {
    render(<CobranzasPage />)
    expect(screen.getByText("Total por cobrar")).toBeInTheDocument()
    expect(screen.getByText("Total vencido")).toBeInTheDocument()
    expect(screen.getAllByText(/3\.200/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/1\.500/).length).toBeGreaterThan(0)
  })

  it("el filtro de tramo viaja al servidor (bucket en el hook)", () => {
    render(<CobranzasPage />)
    fireEvent.click(screen.getByTestId("aging-filter-overdue_60_plus"))
    const lastCall = useReceivablesMock.mock.calls.at(-1)?.[0] as { bucket?: string }
    expect(lastCall?.bucket).toBe("overdue_60_plus")
  })

  it("retiró la nota vieja y sin plazos configurados ofrece Configuración", () => {
    render(<CobranzasPage />)
    expect(screen.queryByText(/no registra vencimientos/i)).not.toBeInTheDocument()

    useCollectionSettingsMock.mockReturnValue({
      data: { defaultPaymentTermsDays: null },
      isLoading: false,
    })
    render(<CobranzasPage />)
    expect(screen.getByTestId("no-terms-hint")).toBeInTheDocument()
    expect(screen.getByTestId("no-terms-hint")).toHaveTextContent(/plazo/i)
    const link = within(screen.getByTestId("no-terms-hint")).getByRole("link")
    expect(link).toHaveAttribute("href", expect.stringContaining("/configuracion"))
  })
})

describe("CobranzasPage — pestaña Por pagar (9.3)", () => {
  it("alterna a Por pagar sin salir de la pantalla y muestra acreedores", () => {
    render(<CobranzasPage />)
    fireEvent.mouseDown(screen.getByRole("tab", { name: /por pagar/i }))
    fireEvent.click(screen.getByRole("tab", { name: /por pagar/i }))
    expect(screen.getByText("Proveedor Vencido")).toBeInTheDocument()
    expect(screen.getByText("Total por pagar")).toBeInTheDocument()
    expect(pushMock).not.toHaveBeenCalled()
  })

  it("la acción de pago abre el RegisterPaymentMadeForm existente", () => {
    render(<CobranzasPage />)
    fireEvent.mouseDown(screen.getByRole("tab", { name: /por pagar/i }))
    fireEvent.click(screen.getByRole("tab", { name: /por pagar/i }))
    fireEvent.click(screen.getByTestId("payable-pay-sup-1"))
    expect(screen.getByTestId("register-payment-made-form-stub")).toHaveTextContent("sup-1")
  })

  it("sin acreedores muestra un estado vacío propio", () => {
    usePayablesMock.mockReturnValue(pageReturn([]))
    usePayablesSummaryMock.mockReturnValue({
      data: { totalPayable: 0, overdueTotal: 0, creditorCount: 0 },
      isLoading: false,
    })
    render(<CobranzasPage />)
    fireEvent.mouseDown(screen.getByRole("tab", { name: /por pagar/i }))
    fireEvent.click(screen.getByRole("tab", { name: /por pagar/i }))
    expect(screen.getByTestId("payables-empty")).toBeInTheDocument()
  })
})

describe("CobranzasPage — recordatorio por WhatsApp (9.4)", () => {
  it("el botón tiene nombre accesible y abre wa.me con el mensaje", () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null)
    render(<CobranzasPage />)
    const btn = screen.getByTestId("receivable-remind-client-1")
    expect(btn).toHaveAccessibleName(/Deudor Vencido/)
    fireEvent.click(btn)
    expect(openSpy).toHaveBeenCalledTimes(1)
    const url = openSpy.mock.calls[0][0] as string
    expect(url).toMatch(/^https:\/\/wa\.me\/549261/)
    expect(url).toContain("text=")
    openSpy.mockRestore()
  })

  it("sin teléfono utilizable abre la mensajería sin destinatario (no queda inoperante)", () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null)
    render(<CobranzasPage />)
    fireEvent.click(screen.getByTestId("receivable-remind-client-2"))
    const url = openSpy.mock.calls[0][0] as string
    expect(url).toMatch(/^https:\/\/wa\.me\/\?text=/)
    openSpy.mockRestore()
  })
})
