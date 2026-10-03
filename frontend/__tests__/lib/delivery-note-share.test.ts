/**
 * remitos-venta (D11, tarea 4.3) — `lib/delivery-note-share.ts`: el texto corto
 * que acompaña al PDF del remito por WhatsApp. Función pura.
 */
import { describe, it, expect } from "vitest"
import { buildDeliveryNoteShareText } from "@/lib/delivery-note-share"

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
