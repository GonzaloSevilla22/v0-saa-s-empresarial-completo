/**
 * factura-fiscal-imprimible (D10, task 7.1) — FiscalInvoiceSummary: el bloque
 * del comprobante que se ve en /ventas y en /ventas/ordenes.
 *
 * Con el comprobante autorizado: badge, "Factura C 0003-00000501", el CAE
 * completo y copiable, su vencimiento y "Verificar en ARCA" (constatación
 * pública, pestaña nueva, sin `opener`). En cualquier otro estado, ni CAE ni
 * enlace: un pendiente no es una factura.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"

import type { SaleFiscalState } from "@/lib/types"

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => {
    const chan = { on: () => chan, subscribe: () => chan }
    return { channel: () => chan, removeChannel: vi.fn() }
  },
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))

import { FiscalInvoiceSummary } from "@/components/fiscal/FiscalInvoiceSummary"

const autorizado: SaleFiscalState = {
  documentId: "fd-1",
  status: "authorized",
  label: "0003-00000501",
  submittedToArca: true,
  frozen: false,
  voidable: false,
  cae: "71234567890123",
  caeDueDate: "2026-10-05",
  comprobanteType: "factura_c",
}

describe("FiscalInvoiceSummary", () => {
  beforeEach(() => vi.clearAllMocks())

  it("muestra la factura autorizada con su CAE y vencimiento", () => {
    render(<FiscalInvoiceSummary fiscal={autorizado} />)

    expect(screen.getByText(/Autorizado/)).toBeInTheDocument()
    expect(screen.getByText("Factura C 0003-00000501")).toBeInTheDocument()
    expect(screen.getByText("71234567890123")).toBeInTheDocument()
    expect(screen.getByText(/vence 05\/10\/2026/)).toBeInTheDocument()
  })

  it("el enlace «Verificar en ARCA» abre la constatación oficial en una pestaña nueva", () => {
    render(<FiscalInvoiceSummary fiscal={autorizado} />)

    const link = screen.getByRole("link", { name: /verificar en arca/i })
    expect(link).toHaveAttribute("href", "https://servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx")
    expect(link).toHaveAttribute("target", "_blank")
    expect(link).toHaveAttribute("rel", "noopener noreferrer")
  })

  it("el CAE se copia con un botón accesible", async () => {
    const user = userEvent.setup()
    const writeText = vi.spyOn(navigator.clipboard, "writeText").mockResolvedValue()
    render(<FiscalInvoiceSummary fiscal={autorizado} />)

    await user.click(screen.getByRole("button", { name: "Copiar CAE 71234567890123" }))

    expect(writeText).toHaveBeenCalledWith("71234567890123")
  })

  it.each([
    ["pending_cae", { status: "pending_cae" as const, cae: null, caeDueDate: null }],
    ["voided", { status: "voided" as const, cae: null, caeDueDate: null }],
    ["congelado", { status: "pending_cae" as const, frozen: true, cae: null, caeDueDate: null }],
  ])("%s: no muestra CAE ni enlace de verificación", (_nombre, overrides) => {
    render(<FiscalInvoiceSummary fiscal={{ ...autorizado, ...overrides }} />)

    expect(screen.queryByText("71234567890123")).toBeNull()
    expect(screen.queryByRole("link", { name: /verificar en arca/i })).toBeNull()
    expect(screen.queryByRole("button", { name: /copiar cae/i })).toBeNull()
  })

  it("sin tipo conocido muestra sólo el número", () => {
    render(<FiscalInvoiceSummary fiscal={{ ...autorizado, comprobanteType: null }} />)

    expect(screen.getByText("0003-00000501")).toBeInTheDocument()
  })

  it("el CAE no desborda en móvil: tabular y con corte", () => {
    render(<FiscalInvoiceSummary fiscal={autorizado} />)

    const cae = screen.getByText("71234567890123")
    expect(cae.className).toMatch(/tabular-nums/)
    expect(cae.className).toMatch(/break-all/)
  })
})
