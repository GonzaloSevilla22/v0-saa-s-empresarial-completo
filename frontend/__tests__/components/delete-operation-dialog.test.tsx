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

  // cobranzas-reverso (task 11.3): documentos "cobro"/"pago" — la anulación
  // de un cobro/pago de cuenta corriente, con su propia redacción (repone
  // deuda, no "revierte cargo") y el asiento contable SIEMPRE enumerado
  // (D5: nace con el reverso, no se difiere).
  it("anular un cobro EN EFECTIVO enumera deuda + caja (salida) + asiento", () => {
    const info = getDeleteCompensation({ hasCashMovement: true }, "cliente", "cobro")
    expect(info.deletable).toBe(true)
    expect(info.compensations).toHaveLength(3)
    expect(info.compensations[0]).toMatch(/repondrá la deuda del cliente/i)
    expect(info.compensations[1]).toMatch(/salida.*caja/i)
    expect(info.compensations[2]).toMatch(/asiento contable/i)
    expect(info.compensations.some((c) => /bancario/i.test(c))).toBe(false)
  })

  it("anular un cobro BANCARIO enumera deuda + banco + asiento, sin mencionar la caja", () => {
    const info = getDeleteCompensation({ hasBankMovement: true }, "cliente", "cobro")
    expect(info.compensations).toHaveLength(3)
    expect(info.compensations[0]).toMatch(/repondrá la deuda del cliente/i)
    expect(info.compensations[1]).toMatch(/bancario/i)
    expect(info.compensations[2]).toMatch(/asiento contable/i)
    expect(info.compensations.some((c) => /caja/i.test(c))).toBe(false)
  })

  it("anular un pago a proveedor EN EFECTIVO dice INGRESO en caja (repone), no salida", () => {
    const info = getDeleteCompensation({ hasCashMovement: true }, "proveedor", "pago")
    expect(info.compensations[0]).toMatch(/repondrá la deuda con el proveedor/i)
    expect(info.compensations[1]).toMatch(/ingreso.*caja/i)
    expect(info.compensations.some((c) => /salida/i.test(c))).toBe(false)
  })

  it("anular un cobro SIN caja ni banco (ninguna pata posteada) igual enumera deuda + asiento", () => {
    const info = getDeleteCompensation({}, "cliente", "cobro")
    expect(info.compensations).toHaveLength(2)
    expect(info.compensations[0]).toMatch(/repondrá la deuda/i)
    expect(info.compensations[1]).toMatch(/asiento contable/i)
  })

  it("anulación de cobro bloqueada por caja cerrada usa la razón propia de 'cobro' (verbo anular, no borrar)", () => {
    const info = getDeleteCompensation({ isDeleteBlocked: true }, "cliente", "cobro")
    expect(info.deletable).toBe(false)
    expect(info.blockedReason).toMatch(/no se puede anular/i)
    expect(info.blockedReason).toMatch(/abrí la caja/i)
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
