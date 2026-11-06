/**
 * productos-padre-variantes (task 10.1) — diálogo «Corregir unidad».
 *
 *  - al elegir la unidad nueva pide la VISTA PREVIA al servidor (dry-run): variantes,
 *    productos con stock, movimientos y un ejemplo con una cantidad real;
 *  - una unidad en conflicto se explica y deshabilita la confirmación;
 *  - confirmar repite la llamada sin dry-run;
 *  - un rechazo al aplicar sale en castellano y el diálogo no se cierra.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product, UnitOfMeasure } from "@/lib/types"
import { PythonApiError } from "@/lib/api/python-api-error"

const relabelMock = vi.fn()
const toastSuccess = vi.fn()
const toastError = vi.fn()

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, isSystem: true }

vi.mock("@/hooks/data/use-products", () => ({
  useRelabelProductUnit: () => ({ relabel: relabelMock, mutation: {} }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [UN, KG, G], unitsById: new Map([[UN.id, UN], [KG.id, KG], [G.id, G]]) }),
}))
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }))

const { RelabelUnitDialog } = await import("@/components/products/RelabelUnitDialog")

const PARENT: Product = {
  id: "parent-1", name: "Harina", category: "Almacén", categoryId: "c1",
  cost: null, price: 0, margin: null, stock: 0, minStock: 0, isVariant: false,
  stockControlType: "variant_only", baseUnitId: "u-un",
}

const PREVIEW = {
  changed: true, rootId: "parent-1", unitBefore: "u-un", unitAfter: "u-kg",
  variants: 3, variantsWithOwnUnit: 1, productsWithStock: 2, movements: 14, conflictUnit: null,
}

async function chooseUnit(user: ReturnType<typeof userEvent.setup>, name: RegExp) {
  await user.click(screen.getByRole("combobox"))
  await user.click(await screen.findByRole("option", { name }))
}

function renderDialog(over: Partial<React.ComponentProps<typeof RelabelUnitDialog>> = {}) {
  const onOpenChange = vi.fn()
  const onDone = vi.fn()
  render(
    <RelabelUnitDialog
      open
      onOpenChange={onOpenChange}
      product={PARENT}
      exampleQuantity={12}
      onDone={onDone}
      {...over}
    />,
  )
  return { onOpenChange, onDone }
}

describe("RelabelUnitDialog", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    relabelMock.mockResolvedValue(PREVIEW)
  })

  it("sin unidad elegida no llama al servidor y la confirmación está deshabilitada", () => {
    renderDialog()
    expect(screen.getByRole("heading", { name: /corregir unidad/i })).toBeInTheDocument()
    expect(relabelMock).not.toHaveBeenCalled()
    expect(screen.getByRole("button", { name: /confirmar corrección/i })).toBeDisabled()
  })

  it("al elegir la unidad pide la vista previa (dry-run) y muestra el impacto con un ejemplo real", async () => {
    const user = userEvent.setup()
    renderDialog()
    await chooseUnit(user, /kilogramo/i)

    await waitFor(() => expect(relabelMock).toHaveBeenCalledWith({ productId: "parent-1", baseUnitId: "u-kg", dryRun: true }))
    expect(await screen.findByText(/3 variantes/i)).toBeInTheDocument()
    expect(screen.getByText(/2 productos con stock/i)).toBeInTheDocument()
    expect(screen.getByText(/14 movimientos/i)).toBeInTheDocument()
    expect(screen.getByText(/12 u pasarán a leerse 12 kg/i)).toBeInTheDocument()
    expect(screen.getByText(/las cantidades quedan igual/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /confirmar corrección/i })).toBeEnabled()
    // La vista previa NO es la corrección.
    expect(relabelMock).toHaveBeenCalledTimes(1)
  })

  it("una unidad en conflicto se explica y la confirmación queda deshabilitada", async () => {
    relabelMock.mockResolvedValue({ ...PREVIEW, changed: false, conflictUnit: "u-g" })
    const user = userEvent.setup()
    renderDialog()
    await chooseUnit(user, /kilogramo/i)

    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(/gramo \(g\)/i)
    expect(alert).toHaveTextContent(/otra unidad/i)
    expect(screen.getByRole("button", { name: /confirmar corrección/i })).toBeDisabled()
  })

  it("confirmar repite la llamada SIN dry-run, avisa y cierra", async () => {
    const user = userEvent.setup()
    const { onOpenChange, onDone } = renderDialog()
    await chooseUnit(user, /kilogramo/i)
    await screen.findByText(/3 variantes/i)

    await user.click(screen.getByRole("button", { name: /confirmar corrección/i }))

    await waitFor(() => expect(relabelMock).toHaveBeenCalledTimes(2))
    expect(relabelMock).toHaveBeenLastCalledWith({ productId: "parent-1", baseUnitId: "u-kg", dryRun: false })
    await waitFor(() => expect(onDone).toHaveBeenCalled())
    expect(toastSuccess).toHaveBeenCalled()
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })

  it("un rechazo al aplicar sale en castellano y el diálogo queda abierto", async () => {
    const user = userEvent.setup()
    const { onOpenChange, onDone } = renderDialog()
    await chooseUnit(user, /kilogramo/i)
    await screen.findByText(/3 variantes/i)

    relabelMock.mockRejectedValueOnce(new PythonApiError("hay líneas en g", 409, { code: "unit_relabel_conflict" }))
    await user.click(screen.getByRole("button", { name: /confirmar corrección/i }))

    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(/otra unidad/i)
    expect(alert).not.toHaveTextContent("unit_relabel_conflict")
    expect(onDone).not.toHaveBeenCalled()
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
  })

  it("una vista previa que falla (403) se muestra en castellano y no habilita confirmar", async () => {
    relabelMock.mockRejectedValue(new PythonApiError("Rol de cuenta insuficiente", 403, { code: "insufficient_role" }))
    const user = userEvent.setup()
    renderDialog()
    await chooseUnit(user, /kilogramo/i)

    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(/administradores|dueño/i)
    expect(screen.getByRole("button", { name: /confirmar corrección/i })).toBeDisabled()
  })

  it("elegir la unidad que la familia ya tiene no ofrece confirmar", async () => {
    relabelMock.mockResolvedValue({ ...PREVIEW, changed: false, unitBefore: "u-un", unitAfter: "u-un" })
    const user = userEvent.setup()
    renderDialog()
    await chooseUnit(user, /^unidad/i)

    expect(await screen.findByText(/ya usa esa unidad/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /confirmar corrección/i })).toBeDisabled()
  })

  it("sin existencias usa un ejemplo de 1 unidad en vez de inventar stock", async () => {
    const user = userEvent.setup()
    renderDialog({ exampleQuantity: 0 })
    await chooseUnit(user, /kilogramo/i)
    expect(await screen.findByText(/1 u pasará a leerse 1 kg/i)).toBeInTheDocument()
  })
})
