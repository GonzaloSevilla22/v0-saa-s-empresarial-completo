import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { DeleteOperationDialog } from "@/components/shared/delete-operation-dialog"
import { getDeleteCompensation } from "@/lib/delete-compensation"

// delete-guard-ledgers (task 9.1 RED / 9.5 TRIANGULATE): el control de
// borrado se deshabilita con su razón visible cuando la operación tiene
// comprobante fiscal emitido (mismo patrón que el lock de edición ya
// montado); cuando es borrable pero tiene dinero posteado, el diálogo
// enumera qué se va a compensar antes de confirmar; sin dinero posteado,
// confirma sin enumerar.

describe("getDeleteCompensation (operation-delete-compensation, derivado de lectura)", () => {
  it("comprobante fiscal emitido → no borrable, con razón que nombra la Nota de Crédito", () => {
    const info = getDeleteCompensation({ isInvoiced: true, hasAccountCharge: true })
    expect(info.deletable).toBe(false)
    expect(info.blockedReason).toMatch(/Nota de Crédito/i)
    expect(info.compensations).toEqual([])
  })

  it("sin comprobante, con cargo + caja + banco → enumera los tres", () => {
    const info = getDeleteCompensation(
      { hasAccountCharge: true, hasCashMovement: true, hasBankMovement: true },
      "cliente",
    )
    expect(info.deletable).toBe(true)
    expect(info.compensations).toHaveLength(3)
    expect(info.compensations.some((c) => /cuenta corriente del cliente/i.test(c))).toBe(true)
    expect(info.compensations.some((c) => /caja/i.test(c))).toBe(true)
    expect(info.compensations.some((c) => /bancario/i.test(c))).toBe(true)
  })

  it("proveedor: el texto de cuenta corriente nombra al proveedor, no al cliente", () => {
    const info = getDeleteCompensation({ hasAccountCharge: true }, "proveedor")
    expect(info.compensations[0]).toMatch(/proveedor/i)
  })

  it("sin dinero posteado → borrable, sin nada que enumerar (task 9.5)", () => {
    const info = getDeleteCompensation({})
    expect(info.deletable).toBe(true)
    expect(info.compensations).toEqual([])
  })
})

describe("DeleteOperationDialog", () => {
  it("no borrable: el control aparece deshabilitado con la razón visible (task 9.1)", () => {
    render(
      <DeleteOperationDialog
        label="esta venta"
        info={{ deletable: false, blockedReason: "No se puede borrar: tiene comprobante fiscal.", compensations: [] }}
        onConfirm={vi.fn()}
        isDeleting={false}
      />,
    )
    const btn = screen.getByTestId("delete-operation-blocked")
    expect(btn).toBeDisabled()
    expect(btn).toHaveAttribute("title", "No se puede borrar: tiene comprobante fiscal.")
    // No debe existir el trigger normal de borrado en este estado.
    expect(screen.queryByTestId("delete-operation-trigger")).toBeNull()
  })

  it("borrable con dinero posteado: el diálogo enumera las compensaciones antes de confirmar", () => {
    render(
      <DeleteOperationDialog
        label="esta venta"
        info={{
          deletable: true,
          blockedReason: null,
          compensations: ["Se revertirá el cargo registrado en la cuenta corriente del cliente."],
        }}
        onConfirm={vi.fn()}
        isDeleting={false}
      />,
    )
    fireEvent.click(screen.getByTestId("delete-operation-trigger"))
    expect(screen.getByText(/Se va a compensar/i)).toBeInTheDocument()
    expect(screen.getByText(/cuenta corriente del cliente/i)).toBeInTheDocument()
  })

  it("borrable sin dinero posteado: confirma sin enumerar nada (task 9.5)", () => {
    render(
      <DeleteOperationDialog
        label="esta venta"
        info={{ deletable: true, blockedReason: null, compensations: [] }}
        onConfirm={vi.fn()}
        isDeleting={false}
      />,
    )
    fireEvent.click(screen.getByTestId("delete-operation-trigger"))
    expect(screen.getByText(/¿Eliminar esta venta\?/i)).toBeInTheDocument()
    expect(screen.queryByText(/Se va a compensar/i)).toBeNull()
  })

  it("confirmar invoca onConfirm", () => {
    const onConfirm = vi.fn()
    render(
      <DeleteOperationDialog
        label="esta venta"
        info={{ deletable: true, blockedReason: null, compensations: [] }}
        onConfirm={onConfirm}
        isDeleting={false}
      />,
    )
    fireEvent.click(screen.getByTestId("delete-operation-trigger"))
    fireEvent.click(screen.getByRole("button", { name: /^Eliminar$/ }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })
})
