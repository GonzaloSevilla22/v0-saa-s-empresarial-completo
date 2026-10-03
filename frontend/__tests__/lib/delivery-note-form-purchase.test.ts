/**
 * remitos-compra (D11, tarea 4.6) — `lib/delivery-note-form.ts` por SENTIDO:
 * `validateDeliveryNoteDraft` para el remito de compra (proveedor obligatorio o
 * dado de baja, sucursal "a la que entra la mercadería", tope del número del
 * proveedor, mínimo por producto en la edición, sin control de faltante ni
 * domicilio) y el aviso de líneas sin precio. Funciones puras. Los casos de venta
 * siguen en `delivery-note-form.test.ts`, sin tocarlos.
 */
import { describe, it, expect } from "vitest"
import {
  DELIVERY_NOTE_NOTES_MAX,
  DELIVERY_NOTE_SUPPLIER_REFERENCE_MAX,
  PURCHASE_LINE_NO_PRICE_NOTICE,
  SUPPLIER_DELETED_SAVE_MESSAGE,
  buildDeliveryNoteItemsPayload,
  describeMissingPrices,
  missingPriceLineCount,
  validateDeliveryNoteDraft,
  type DeliveryNoteDraftCheck,
} from "@/lib/delivery-note-form"
import type { SaleCartItem } from "@/lib/cart-utils"

const ok: DeliveryNoteDraftCheck = {
  direction: "purchase",
  clientId: "",
  clientDeleted: false,
  supplierId: "s-andina",
  supplierDeleted: false,
  supplierReference: "0004-00012345",
  branchId: "b-1",
  branchName: "Centro",
  itemCount: 2,
  exceeding: [],
  belowMinimum: [],
  address: "",
  notes: "",
}

describe("validateDeliveryNoteDraft — remito de compra", () => {
  it("un borrador completo (sin cliente ni domicilio) no tiene problemas", () => {
    expect(validateDeliveryNoteDraft(ok)).toBeNull()
  })

  it("exige proveedor: 'Elegí un proveedor'", () => {
    expect(validateDeliveryNoteDraft({ ...ok, supplierId: "" })).toBe("Elegí un proveedor: el remito se recibe de alguien.")
  })

  it("el cliente no cuenta como contraparte de una compra", () => {
    expect(validateDeliveryNoteDraft({ ...ok, supplierId: "", clientId: "c-ana" })).toMatch(/proveedor/i)
  })

  it("un proveedor dado de baja bloquea con el aviso accionable", () => {
    expect(validateDeliveryNoteDraft({ ...ok, supplierDeleted: true })).toBe(SUPPLIER_DELETED_SAVE_MESSAGE)
    expect(SUPPLIER_DELETED_SAVE_MESSAGE).toBe("Proveedor dado de baja — elegí uno vigente para guardar.")
  })

  it("exige la sucursal a la que entra la mercadería", () => {
    const message = validateDeliveryNoteDraft({ ...ok, branchId: null })
    expect(message).toBe("Elegí la sucursal a la que entra la mercadería.")
  })

  it("exige al menos una línea", () => {
    expect(validateDeliveryNoteDraft({ ...ok, itemCount: 0 })).toMatch(/producto/i)
  })

  it("el proveedor falta antes que la sucursal (el primer problema es el que se muestra)", () => {
    expect(validateDeliveryNoteDraft({ ...ok, supplierId: "", branchId: null })).toMatch(/proveedor/i)
  })

  it("no controla faltante de stock en el alta: entra mercadería, no hay disponible que superar", () => {
    expect(validateDeliveryNoteDraft({ ...ok, exceeding: ["Huevo", "Queso"] })).toBeNull()
  })

  it("el domicilio de entrega no existe en compra: no se valida", () => {
    expect(validateDeliveryNoteDraft({ ...ok, address: "x".repeat(10_000) })).toBeNull()
  })

  it("el número del proveedor respeta su tope de 100 caracteres", () => {
    expect(DELIVERY_NOTE_SUPPLIER_REFERENCE_MAX).toBe(100)
    expect(validateDeliveryNoteDraft({ ...ok, supplierReference: "x".repeat(101) })).toMatch(/número del remito del proveedor/i)
    expect(validateDeliveryNoteDraft({ ...ok, supplierReference: "x".repeat(100) })).toBeNull()
    expect(validateDeliveryNoteDraft({ ...ok, supplierReference: undefined })).toBeNull()
  })

  it("las notas respetan su tope también en compra", () => {
    expect(validateDeliveryNoteDraft({ ...ok, notes: "x".repeat(DELIVERY_NOTE_NOTES_MAX + 1) })).toMatch(/notas/i)
    expect(validateDeliveryNoteDraft({ ...ok, notes: "x".repeat(DELIVERY_NOTE_NOTES_MAX) })).toBeNull()
  })

  it("en la edición, bajar de lo que sigue en la sucursal bloquea y nombra los productos y la sucursal", () => {
    const message = validateDeliveryNoteDraft({ ...ok, belowMinimum: ["Producto A", "Producto B"] })
    expect(message).toMatch(/Producto A/)
    expect(message).toMatch(/Producto B/)
    expect(message).toMatch(/Centro/)
    expect(message).toMatch(/ajustá el stock/i)
  })

  it("el mínimo no atribuye origen a la diferencia", () => {
    const message = validateDeliveryNoteDraft({ ...ok, belowMinimum: ["Producto A"] }) ?? ""
    expect(message).not.toMatch(/vendi|salieron|consumi/i)
  })
})

describe("validateDeliveryNoteDraft — venta no cambia con los campos nuevos", () => {
  const sale: DeliveryNoteDraftCheck = {
    clientId: "c-ana",
    clientDeleted: false,
    branchId: "b-1",
    branchName: "Centro",
    itemCount: 1,
    exceeding: [],
    address: "",
    notes: "",
  }

  it("sin direction es venta: exige cliente y controla el faltante", () => {
    expect(validateDeliveryNoteDraft({ ...sale, clientId: "" })).toMatch(/cliente/i)
    expect(validateDeliveryNoteDraft({ ...sale, exceeding: ["Huevo"] })).toMatch(/No alcanza el stock de Centro/)
  })

  it("un proveedor suelto o un mínimo no afectan a una venta", () => {
    expect(
      validateDeliveryNoteDraft({ ...sale, supplierId: "", supplierDeleted: true, belowMinimum: ["A"], supplierReference: "x".repeat(500) }),
    ).toBeNull()
  })

  it("la sucursal de venta sigue siendo 'de la que sale la mercadería'", () => {
    expect(validateDeliveryNoteDraft({ ...sale, branchId: null })).toBe("Elegí la sucursal de la que sale la mercadería.")
  })
})

function line(unitPrice: number, quantity: number, subtotal = unitPrice * quantity): SaleCartItem {
  return {
    id: `l-${Math.random()}`,
    productId: "p",
    productName: "P",
    unitPrice,
    quantity,
    discount: 0,
    subtotal,
  }
}

describe("líneas sin precio (precio 0 admitido al recibir, OQ-RC1)", () => {
  it("cuenta las líneas con precio 0", () => {
    expect(missingPriceLineCount([line(0, 5), line(100, 1), line(0, 2)])).toBe(2)
  })

  it("ninguna sin precio: 0", () => {
    expect(missingPriceLineCount([line(100, 1), line(0.01, 100)])).toBe(0)
  })

  it("sin líneas: 0", () => {
    expect(missingPriceLineCount([])).toBe(0)
  })

  it("el precio efectivo sale del subtotal (como lo manda el payload), no de unitPrice", () => {
    expect(missingPriceLineCount([line(100, 2, 0)])).toBe(1)
    expect(missingPriceLineCount([line(0, 2, 150)])).toBe(0)
  })

  it("describeMissingPrices: singular, plural y sin aviso", () => {
    expect(describeMissingPrices(0)).toBeNull()
    expect(describeMissingPrices(1)).toBe(
      "1 línea sin precio: lo vas a poder cargar antes de convertir el remito en compra.",
    )
    expect(describeMissingPrices(3)).toBe(
      "3 líneas sin precio: lo vas a poder cargar antes de convertir el remito en compra.",
    )
  })

  it("el aviso por línea nueva (costo nulo -> 0) es el de D11", () => {
    expect(PURCHASE_LINE_NO_PRICE_NOTICE).toBe(
      "Sin precio: lo vas a poder cargar antes de convertir el remito en compra",
    )
  })

  it("el payload manda precio 0 y subtotal 0 tal cual (el servidor los admite al recibir)", () => {
    expect(buildDeliveryNoteItemsPayload([line(0, 5, 0)])).toEqual([
      { product_id: "p", unit_id: null, quantity: 5, price: 0, subtotal: 0 },
    ])
  })
})
