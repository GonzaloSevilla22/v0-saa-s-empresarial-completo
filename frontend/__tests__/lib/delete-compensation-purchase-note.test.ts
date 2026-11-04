/**
 * remitos-compra (tanda B, 7.7, D9) — `getDeleteCompensation` para la compra
 * nacida de un remito: borrarla NO devuelve el stock (la mercadería quedó recibida
 * con el remito), deja el remito otra vez pendiente y exige el rol de anularlo.
 *
 * El texto de la línea es el de D9 y es DISTINTO del de la venta ("entregada" /
 * "devolverla"): acá la mercadería entró, no salió. Las dos coexisten porque la
 * redacción sigue al documento.
 */
import { describe, it, expect } from "vitest"
import { getDeleteCompensation } from "@/lib/delete-compensation"

const NOTE = { sourceDeliveryNoteId: "dn-1", sourceDeliveryNoteLabel: "RC-00000012" }

describe("getDeleteCompensation — compra nacida de un remito", () => {
  it("avisa que el stock no vuelve y que el remito queda pendiente (texto de D9, en compra)", () => {
    const info = getDeleteCompensation({ ...NOTE, reversesStock: false }, "proveedor", "compra")
    expect(info.deletable).toBe(true)
    expect(info.notes).toEqual([
      "El stock no vuelve: la mercadería quedó recibida con el remito RC-00000012, que vuelve a quedar pendiente. Para sacarla del stock, anulá el remito.",
    ])
    expect(info.compensations.join(" ")).not.toMatch(/stock/i)
  })

  it("sin número no inventa uno", () => {
    const info = getDeleteCompensation({ sourceDeliveryNoteId: "dn-1", sourceDeliveryNoteLabel: null }, "proveedor", "compra")
    expect(info.notes?.[0]).toMatch(/quedó recibida con el remito, que vuelve a quedar pendiente/)
  })

  it("la venta conserva su redacción propia (entregada / devolverla)", () => {
    const info = getDeleteCompensation({ sourceDeliveryNoteId: "dn-1", sourceDeliveryNoteLabel: "R-00000007" }, "cliente")
    expect(info.notes?.[0]).toBe(
      "El stock no vuelve: la mercadería quedó entregada con el remito R-00000007, que vuelve a quedar pendiente. Para devolverla al stock, anulá el remito.",
    )
  })

  it("una compra directa no lleva la nota y conserva la línea de reversa de stock", () => {
    const info = getDeleteCompensation({ reversesStock: true }, "proveedor", "compra")
    expect(info.notes ?? []).toEqual([])
    expect(info.compensations).toContain("Se revertirá el ingreso de stock de esta compra (el stock vuelve al estado previo).")
  })

  it("enumera igual las compensaciones de los libros (cuenta corriente, caja, banco)", () => {
    const info = getDeleteCompensation(
      { ...NOTE, reversesStock: false, hasAccountCharge: true, hasCashMovement: true, hasBankMovement: true },
      "proveedor",
      "compra",
    )
    expect(info.compensations).toEqual([
      "Se revertirá el cargo registrado en la cuenta corriente del proveedor.",
      "Se registrará el ingreso correspondiente en la caja abierta actual.",
      "Se registrará el movimiento bancario inverso, pendiente de conciliar.",
    ])
  })

  describe("bloqueo por el remito de origen", () => {
    it("sin el rol de anular el remito: no borrable, con el motivo", () => {
      const info = getDeleteCompensation(
        { ...NOTE, sourceDeliveryNoteDeleteBlockedReason: "Borrar esta compra reabre el remito RC-00000012: requiere administrador o dueño." },
        "proveedor",
        "compra",
      )
      expect(info.deletable).toBe(false)
      expect(info.blockedReason).toBe("Borrar esta compra reabre el remito RC-00000012: requiere administrador o dueño.")
      expect(info.compensations).toEqual([])
    })

    it("sin un motivo de bloqueo del remito, el borrado sigue disponible", () => {
      expect(
        getDeleteCompensation({ ...NOTE, sourceDeliveryNoteDeleteBlockedReason: null }, "proveedor", "compra").deletable,
      ).toBe(true)
    })

    it("va ANTES que el bloqueo por caja cerrada (el servidor revisa el remito primero) y DESPUÉS del fiscal", () => {
      const both = getDeleteCompensation(
        { ...NOTE, isDeleteBlocked: true, sourceDeliveryNoteDeleteBlockedReason: "motivo del remito" },
        "proveedor",
        "compra",
      )
      expect(both.blockedReason).toBe("motivo del remito")

      const fiscal = getDeleteCompensation(
        { ...NOTE, isFiscallyLocked: true, sourceDeliveryNoteDeleteBlockedReason: "motivo del remito" },
        "cliente",
      )
      expect(fiscal.blockedReason).not.toBe("motivo del remito")
    })

    it("la caja cerrada sigue bloqueando cuando el remito no lo hace", () => {
      const info = getDeleteCompensation({ ...NOTE, isDeleteBlocked: true }, "proveedor", "compra")
      expect(info.deletable).toBe(false)
      expect(info.blockedReason).toMatch(/caja que ya está cerrada/)
    })
  })
})
