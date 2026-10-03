/**
 * remitos-venta (D11, tarea 4.3) — `lib/delivery-note-share.ts`: el texto corto
 * que acompaña al PDF del remito por WhatsApp. Función pura.
 */
import { describe, it, expect } from "vitest"
import { buildDeliveryNoteShareText, deliveryNoteFileName } from "@/lib/delivery-note-share"

describe("buildDeliveryNoteShareText", () => {
  it("el texto completo de D11", () => {
    expect(
      buildDeliveryNoteShareText({
        clientName: "Ana",
        numberLabel: "R-00000012",
        issuedOn: "2026-10-02",
        businessName: "Kiosco Lola",
      }),
    ).toBe("Hola Ana, te envío el remito R-00000012 de la mercadería entregada el 02/10/2026. Kiosco Lola")
  })

  it("sin nombre de cliente: saludo genérico", () => {
    expect(
      buildDeliveryNoteShareText({ clientName: null, numberLabel: "R-00000007", issuedOn: "2026-01-09" }),
    ).toBe("Hola, te envío el remito R-00000007 de la mercadería entregada el 09/01/2026.")
  })

  it("sin negocio: la oración queda sin cola", () => {
    const text = buildDeliveryNoteShareText({
      clientName: "Ana",
      numberLabel: "R-00000012",
      issuedOn: "2026-10-02",
      businessName: "   ",
    })
    expect(text.endsWith("el 02/10/2026.")).toBe(true)
  })

  it("recorta los espacios del nombre y no corre el día de una fecha de negocio (sin pasar por Date)", () => {
    expect(
      buildDeliveryNoteShareText({
        clientName: "  Ana  ",
        numberLabel: "R-00000001",
        issuedOn: "2026-03-01T00:00:00Z",
      }),
    ).toBe("Hola Ana, te envío el remito R-00000001 de la mercadería entregada el 01/03/2026.")
  })

  it("sin número de remito (fila sin numerar) omite el número y no inventa uno", () => {
    const text = buildDeliveryNoteShareText({ clientName: "Ana", numberLabel: null, issuedOn: "2026-10-02" })
    expect(text).toBe("Hola Ana, te envío el remito de la mercadería entregada el 02/10/2026.")
  })
})

describe("deliveryNoteFileName", () => {
  it("sin precios: remito-R-00000012.pdf", () => {
    expect(deliveryNoteFileName("sale", "R-00000012", false)).toBe("remito-R-00000012.pdf")
  })

  it("con precios el nombre lo distingue para no confundir las dos variantes", () => {
    expect(deliveryNoteFileName("sale", "R-00000012", true)).toBe("remito-R-00000012-con-precios.pdf")
  })

  it("sin número (fila sin numerar) no inventa uno", () => {
    expect(deliveryNoteFileName("sale", null, false)).toBe("remito.pdf")
    expect(deliveryNoteFileName("sale", null, true)).toBe("remito-con-precios.pdf")
  })
})

// ── remitos-compra (D10/D11, tarea 4.6) ────────────────────────────────────────

describe("buildDeliveryNoteShareText — remito de compra", () => {
  it("el texto completo de D11: recepción, número del proveedor y negocio", () => {
    expect(
      buildDeliveryNoteShareText({
        direction: "purchase",
        supplierName: "Distribuidora Andina",
        supplierReference: "0004-00012345",
        numberLabel: "RC-00000012",
        issuedOn: "2026-10-03",
        businessName: "Kiosco Lola",
      }),
    ).toBe(
      "Hola Distribuidora Andina, te confirmo la recepción de la mercadería del remito RC-00000012 " +
        "(tu remito N° 0004-00012345) el 03/10/2026. Kiosco Lola",
    )
  })

  it("sin número del proveedor: omite el paréntesis (no inventa uno)", () => {
    const text = buildDeliveryNoteShareText({
      direction: "purchase",
      supplierName: "Andina",
      supplierReference: "   ",
      numberLabel: "RC-00000012",
      issuedOn: "2026-10-03",
    })
    expect(text).toBe("Hola Andina, te confirmo la recepción de la mercadería del remito RC-00000012 el 03/10/2026.")
    expect(text).not.toMatch(/tu remito/)
  })

  it("sin nombre del proveedor y sin número: saludo genérico y 'el remito'", () => {
    expect(
      buildDeliveryNoteShareText({ direction: "purchase", supplierName: null, numberLabel: null, issuedOn: "2026-01-09" }),
    ).toBe("Hola, te confirmo la recepción de la mercadería del remito el 09/01/2026.")
  })

  it("una compra no usa el nombre del cliente ni el texto de entrega de venta", () => {
    const text = buildDeliveryNoteShareText({
      direction: "purchase",
      clientName: "Ana",
      supplierName: "Andina",
      numberLabel: "RC-00000001",
      issuedOn: "2026-03-01T00:00:00Z",
    })
    expect(text).not.toMatch(/Ana|entregada|te envío/)
    expect(text).toContain("01/03/2026")
  })

  it("sin direction el texto es el de venta (retrocompatible)", () => {
    expect(
      buildDeliveryNoteShareText({ clientName: "Ana", numberLabel: "R-00000012", issuedOn: "2026-10-02" }),
    ).toBe("Hola Ana, te envío el remito R-00000012 de la mercadería entregada el 02/10/2026.")
  })
})

describe("deliveryNoteFileName — por sentido", () => {
  it("compra sin precios: remito-compra-RC-00000012.pdf", () => {
    expect(deliveryNoteFileName("purchase", "RC-00000012", false)).toBe("remito-compra-RC-00000012.pdf")
  })

  it("compra con precios: lleva -con-precios", () => {
    expect(deliveryNoteFileName("purchase", "RC-00000012", true)).toBe("remito-compra-RC-00000012-con-precios.pdf")
  })

  it("compra sin número (fila sin numerar) no inventa uno", () => {
    expect(deliveryNoteFileName("purchase", null, false)).toBe("remito-compra.pdf")
    expect(deliveryNoteFileName("purchase", null, true)).toBe("remito-compra-con-precios.pdf")
  })

  it("el nombre de venta no cambia: remito-R-…", () => {
    expect(deliveryNoteFileName("sale", "R-00000012", false)).toBe("remito-R-00000012.pdf")
  })
})
