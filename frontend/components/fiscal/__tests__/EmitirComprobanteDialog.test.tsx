/**
 * punto-venta-seleccion (D10, tasks 4.1/4.2) — EmitirComprobanteDialog revivido.
 *
 * Era código muerto desde v22 (ningún consumidor). Ahora lo abre
 * EmitInvoiceButton cuando la cuenta tiene DOS o más PV activos:
 *   - abre con la preselección (última elección > predeterminado) y el
 *     confirmar habilitado; sin preselección, deshabilitado hasta elegir;
 *   - confirmar devuelve el id elegido; cancelar no emite;
 *   - la delegación ARCA no autorizada es un AVISO que NO bloquea (OQ-4);
 *   - tokens semánticos: ninguna clase de paleta literal (`amber-*`).
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"

import { EmitirComprobanteDialog } from "@/components/fiscal/EmitirComprobanteDialog"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"
import type { FiscalProfile } from "@/hooks/data/use-fiscal-profile"

const base = { fiscalProfileId: "fp-1", accountId: "acc-1", branchId: null, createdAt: "2026-09-26T00:00:00Z" }
const PV3: PointOfSale = { ...base, id: "pv-3", numero: 3, isActive: true, isDefault: false }
const PV9999: PointOfSale = { ...base, id: "pv-9999", numero: 9999, isActive: true, isDefault: true }

const PROFILE = {
  id: "fp-1",
  accountId: "acc-1",
  cuit: "27-21379033-7",
  ivaCondition: "monotributista",
  iibbCondition: null,
  ambiente: "produccion",
  delegacionAutorizada: true,
} as unknown as FiscalProfile

function renderDialog(overrides: Partial<React.ComponentProps<typeof EmitirComprobanteDialog>> = {}) {
  const onConfirm = vi.fn()
  const onOpenChange = vi.fn()
  const utils = render(
    <EmitirComprobanteDialog
      open
      onOpenChange={onOpenChange}
      pointsOfSale={[PV3, PV9999]}
      fiscalProfile={PROFILE}
      preselectedPointOfSaleId="pv-9999"
      onConfirm={onConfirm}
      isSubmitting={false}
      {...overrides}
    />,
  )
  return { ...utils, onConfirm, onOpenChange }
}

const confirmButton = () => screen.getByRole("button", { name: /Confirmar y enviar al ARCA/i })

describe("EmitirComprobanteDialog — elegir el punto de venta al facturar", () => {
  it("abre con la preselección marcada y el confirmar habilitado", () => {
    renderDialog()
    expect(screen.getByRole("combobox", { name: "Punto de venta" })).toHaveTextContent("PV 9999")
    expect(confirmButton()).toBeEnabled()
  })

  it("sin preselección y con varios activos, confirmar queda deshabilitado hasta elegir", async () => {
    const user = userEvent.setup()
    const { onConfirm } = renderDialog({ preselectedPointOfSaleId: null })
    expect(confirmButton()).toBeDisabled()

    await user.click(screen.getByRole("combobox", { name: "Punto de venta" }))
    await user.click(screen.getByRole("option", { name: /PV 0003/ }))
    expect(confirmButton()).toBeEnabled()
    await user.click(confirmButton())
    expect(onConfirm).toHaveBeenCalledWith("pv-3")
  })

  it("confirmar llama onConfirm con el id elegido (nunca vacío)", async () => {
    const user = userEvent.setup()
    const { onConfirm } = renderDialog()
    await user.click(confirmButton())
    expect(onConfirm).toHaveBeenCalledTimes(1)
    expect(onConfirm).toHaveBeenCalledWith("pv-9999")
  })

  it("cancelar no emite", async () => {
    const user = userEvent.setup()
    const { onConfirm, onOpenChange } = renderDialog()
    await user.click(screen.getByRole("button", { name: "Cancelar" }))
    expect(onConfirm).not.toHaveBeenCalled()
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it("delegación ARCA no autorizada: muestra el aviso y NO deshabilita confirmar (OQ-4)", () => {
    renderDialog({ fiscalProfile: { ...PROFILE, delegacionAutorizada: false } })
    expect(screen.getByText(/Delegación en ARCA no autorizada/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /Configurar autorización/ })).toHaveAttribute("href", "/configuracion/fiscal")
    expect(confirmButton()).toBeEnabled()
  })

  it("TRIANGULATE: una preselección que no está entre los activos no habilita confirmar", () => {
    renderDialog({ preselectedPointOfSaleId: "pv-de-otra-cuenta" })
    expect(confirmButton()).toBeDisabled()
  })

  it("mientras emite, confirmar y cancelar quedan deshabilitados", () => {
    renderDialog({ isSubmitting: true })
    expect(screen.getByRole("button", { name: /Enviando a ARCA/ })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Cancelar" })).toBeDisabled()
  })

  it("muestra el tipo de comprobante resuelto por la condición IVA", () => {
    renderDialog()
    expect(screen.getByText("Factura C")).toBeInTheDocument()
  })

  it("usa tokens semánticos: ninguna clase de paleta literal amber-*", () => {
    renderDialog({ fiscalProfile: { ...PROFILE, delegacionAutorizada: false } })
    const html = document.body.innerHTML
    expect(html).not.toMatch(/\bamber-\d/)
    expect(html).not.toMatch(/\byellow-\d/)
  })
})
