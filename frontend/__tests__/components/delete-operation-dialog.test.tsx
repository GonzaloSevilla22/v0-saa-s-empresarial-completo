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
  it("comprobante fiscal ya enviado a ARCA → no borrable, con razón que nombra la Nota de Crédito", () => {
    const info = getDeleteCompensation({ isFiscallyLocked: true, hasAccountCharge: true })
    expect(info.deletable).toBe(false)
    expect(info.blockedReason).toMatch(/Nota de Crédito/i)
    expect(info.compensations).toEqual([])
  })

  // ── venta-editable-sin-cae ───────────────────────────────────────────────

  it("el motivo por CAUSA REAL gana al genérico cuando el caller lo pasa", () => {
    const info = getDeleteCompensation({
      isFiscallyLocked: true,
      fiscalBlockedReason: "No editable: esta venta tiene un comprobante autorizado por ARCA (0003-00000004).",
    })
    expect(info.deletable).toBe(false)
    expect(info.blockedReason).toContain("0003-00000004")
    expect(info.blockedReason).not.toMatch(/Nota de Crédito/i)
  })

  it("comprobante PENDIENTE no enviado → borrable, y la anulación es la PRIMERA compensación", () => {
    const info = getDeleteCompensation({
      isFiscallyLocked: false,
      voidsPendingFiscalDocument: "0003-00000005",
      hasAccountCharge: true,
      hasCashMovement: true,
    })
    expect(info.deletable).toBe(true)
    expect(info.blockedReason).toBeNull()
    // Mismo orden que los guards del servidor: el fiscal corre primero.
    expect(info.compensations[0]).toContain("0003-00000005")
    expect(info.compensations[0]).toMatch(/anulará el comprobante pendiente/i)
    expect(info.compensations[0]).toMatch(/volver a emitirlo/i)
    expect(info.compensations).toHaveLength(3)
  })

  it("sin comprobante pendiente, NO se enumera ninguna anulación", () => {
    const info = getDeleteCompensation({ hasAccountCharge: true })
    expect(info.compensations.some((c) => /anular/i.test(c))).toBe(false)
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

// remitos-venta (tanda B, 7.6, D9): borrar la venta nacida de un remito NO
// devuelve stock (la mercadería quedó entregada) y el remito vuelve a pendiente.
// No es una compensación de un libro: es una advertencia propia, separada de la
// lista "Se va a compensar".
describe("getDeleteCompensation — venta nacida de un remito (remitos-venta D9)", () => {
  const LINE = /el stock no vuelve: la mercadería quedó entregada con el remito R-00000007, que vuelve a quedar pendiente\. para devolverla al stock, anulá el remito\./i

  it("con remito de origen suma la línea de D9 en `notes`, NO en las compensaciones", () => {
    const info = getDeleteCompensation({ sourceDeliveryNoteId: "dn-3", sourceDeliveryNoteLabel: "R-00000007", hasAccountCharge: true })
    expect(info.deletable).toBe(true)
    expect(info.notes).toHaveLength(1)
    expect(info.notes?.[0]).toMatch(LINE)
    expect(info.compensations).toHaveLength(1)
    expect(info.compensations.some((c) => /stock/i.test(c))).toBe(false)
  })

  it("sin remito de origen no hay ninguna nota", () => {
    expect(getDeleteCompensation({ hasAccountCharge: true }).notes ?? []).toEqual([])
    expect(getDeleteCompensation({ sourceDeliveryNoteId: null, sourceDeliveryNoteLabel: null }).notes ?? []).toEqual([])
  })

  it("un remito de origen sin número igual avisa, sin inventar uno", () => {
    const info = getDeleteCompensation({ sourceDeliveryNoteId: "dn-old", sourceDeliveryNoteLabel: null })
    expect(info.notes?.[0]).toMatch(/quedó entregada con el remito, que vuelve a quedar pendiente/i)
  })

  it("si la venta no es borrable (comprobante enviado a ARCA) no hay nota: el remito no se reabre", () => {
    const info = getDeleteCompensation({ isFiscallyLocked: true, sourceDeliveryNoteId: "dn-3", sourceDeliveryNoteLabel: "R-00000007" })
    expect(info.deletable).toBe(false)
    expect(info.notes ?? []).toEqual([])
  })
})

describe("DeleteOperationDialog — nota del remito de origen", () => {
  it("el diálogo muestra la nota de D9 aparte de la lista de compensaciones", () => {
    render(
      <DeleteOperationDialog
        label="esta venta"
        info={getDeleteCompensation({ sourceDeliveryNoteId: "dn-3", sourceDeliveryNoteLabel: "R-00000007", hasAccountCharge: true })}
        onConfirm={vi.fn()}
        isDeleting={false}
      />,
    )
    fireEvent.click(screen.getByTestId("delete-operation-trigger"))
    expect(screen.getByText(/el stock no vuelve: la mercadería quedó entregada con el remito R-00000007/i)).toBeInTheDocument()
    expect(screen.getByText("Se va a compensar:")).toBeInTheDocument()
  })

  it("sin notas, el diálogo no agrega ningún párrafo extra", () => {
    render(
      <DeleteOperationDialog
        label="esta venta"
        info={getDeleteCompensation({ hasAccountCharge: true })}
        onConfirm={vi.fn()}
        isDeleting={false}
      />,
    )
    fireEvent.click(screen.getByTestId("delete-operation-trigger"))
    expect(screen.queryByText(/el stock no vuelve/i)).not.toBeInTheDocument()
  })
})
