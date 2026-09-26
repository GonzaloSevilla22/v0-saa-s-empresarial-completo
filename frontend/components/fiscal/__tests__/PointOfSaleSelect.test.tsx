/**
 * punto-venta-seleccion (D7, tasks 3.5/3.6) — selector ÚNICO de punto de venta.
 *
 * Hasta este change el bloque <Select> de PV estaba copiado en
 * EmitirComprobanteDialog y en EmitirSuscripcionDialog; el diálogo revivido lo
 * suma a los dos caminos de facturación de ventas → tercer uso, Regla de Tres.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"

import { PointOfSaleSelect } from "@/components/fiscal/PointOfSaleSelect"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"

const base = {
  fiscalProfileId: "fp-1",
  accountId: "acc-1",
  branchId: null,
  createdAt: "2026-09-26T00:00:00Z",
}
const PV1_INACTIVE: PointOfSale = { ...base, id: "pv-1", numero: 1, isActive: false, isDefault: false }
const PV3: PointOfSale = { ...base, id: "pv-3", numero: 3, isActive: true, isDefault: false }
const PV9999_DEFAULT: PointOfSale = { ...base, id: "pv-9999", numero: 9999, isActive: true, isDefault: true }

describe("PointOfSaleSelect", () => {
  it("con un solo PV activo lo muestra como texto (sin combobox)", () => {
    render(<PointOfSaleSelect pointsOfSale={[PV1_INACTIVE, PV3]} value="pv-3" onValueChange={vi.fn()} />)
    expect(screen.queryByRole("combobox")).toBeNull()
    expect(screen.getByText("PV 0003")).toBeInTheDocument()
    expect(screen.getByText(/Único PV activo/)).toBeInTheDocument()
    // El inactivo nunca aparece.
    expect(screen.queryByText("PV 0001")).toBeNull()
  })

  it("con varios activos muestra un combobox con etiqueta asociada", () => {
    render(<PointOfSaleSelect pointsOfSale={[PV3, PV9999_DEFAULT]} value="" onValueChange={vi.fn()} />)
    expect(screen.getByRole("combobox", { name: "Punto de venta" })).toBeInTheDocument()
  })

  it("lista sólo los activos, marca el predeterminado y devuelve el id elegido", async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()
    render(
      <PointOfSaleSelect
        pointsOfSale={[PV1_INACTIVE, PV3, PV9999_DEFAULT]}
        value=""
        onValueChange={onValueChange}
      />,
    )
    await user.click(screen.getByRole("combobox", { name: "Punto de venta" }))

    const options = screen.getAllByRole("option")
    expect(options.map((o) => o.textContent)).toEqual(["PV 0003", "PV 9999Predeterminado"])
    expect(screen.queryByRole("option", { name: /0001/ })).toBeNull()

    await user.click(screen.getByRole("option", { name: /PV 9999/ }))
    expect(onValueChange).toHaveBeenCalledWith("pv-9999")
  })

  it("TRIANGULATE: el valor recibido se refleja en el trigger", () => {
    render(<PointOfSaleSelect pointsOfSale={[PV3, PV9999_DEFAULT]} value="pv-3" onValueChange={vi.fn()} />)
    expect(screen.getByRole("combobox", { name: "Punto de venta" })).toHaveTextContent("PV 0003")
  })

  it("sin PV activos no renderiza nada (el contenedor muestra su propio aviso)", () => {
    const { container } = render(
      <PointOfSaleSelect pointsOfSale={[PV1_INACTIVE]} value="" onValueChange={vi.fn()} />,
    )
    expect(container).toBeEmptyDOMElement()
  })
})
