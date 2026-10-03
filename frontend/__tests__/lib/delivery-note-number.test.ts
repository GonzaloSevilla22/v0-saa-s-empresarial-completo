/**
 * remitos-venta (D2, tarea 4 — "formato de número con el fixture compartido") —
 * el prefijo `R` del remito de VENTA en `lib/internal-document-number.ts`.
 *
 * El fixture compartido (`internal_document_number_cases.json`) se indexa por
 * TIPO de secuencia (`delivery_note_sale` -> `R`), no por tabla, y lo recorren
 * pytest y vitest. Sumar ahí los casos `delivery_note_sale` es de la tarea 3.4
 * (backend, `numbering.py` y el mismo fixture, en un solo commit para que pytest
 * no vea un tipo sin prefijo): `internal-document-number.test.ts` ya recorre
 * cualquier `document_type` que traiga el fixture, así que esos casos corren solos
 * contra esta definición. Mientras tanto este archivo fija el contrato del
 * prefijo con casos propios — los mismos valores que el fixture va a traer.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import {
  formatDeliveryNoteNumber,
  formatInternalDocumentNumber,
  parseInternalDocumentNumberQuery,
} from "@/lib/internal-document-number"

describe("formatInternalDocumentNumber — delivery_note_sale", () => {
  it.each([
    [1, "R-00000001"],
    [12, "R-00000012"],
    [99999999, "R-99999999"],
    [123456789, "R-123456789"], // más de 8 dígitos: no se trunca
  ])("%i -> %s", (n, expected) => {
    expect(formatInternalDocumentNumber("delivery_note_sale", n)).toBe(expected)
  })

  it("el presupuesto sigue con su prefijo P", () => {
    expect(formatInternalDocumentNumber("quote", 12)).toBe("P-00000012")
  })
})

describe("parseInternalDocumentNumberQuery — formatos del remito", () => {
  it.each([
    ["R-12", 12],
    ["r-12", 12],
    ["R-00000012", 12],
    ["  R-00000012 ", 12],
    ["12", 12],
    ["00000012", 12],
  ])("%j -> %j", (query, expected) => {
    expect(parseInternalDocumentNumberQuery(query, "delivery_note_sale")).toBe(expected)
  })

  it.each(["R-", "R-12-3", "R-12a", "RC-12", "R-0", "Ramiro"])("%j no es un número de documento", (query) => {
    expect(parseInternalDocumentNumberQuery(query, "delivery_note_sale")).toBeNull()
  })

  it("los formatos del presupuesto se siguen leyendo en el listado de presupuestos, no en el de remitos", () => {
    expect(parseInternalDocumentNumberQuery("P-12", "quote")).toBe(12)
    expect(parseInternalDocumentNumberQuery("P-12", "delivery_note_sale")).toBeNull()
  })

  it.each([1, 12, 4321, 99999999, 123456789])("lo que se imprime se vuelve a encontrar (%i)", (n) => {
    expect(parseInternalDocumentNumberQuery(formatInternalDocumentNumber("delivery_note_sale", n), "delivery_note_sale")).toBe(n)
  })
})

describe("formatDeliveryNoteNumber — desde direction, nunca con un prefijo fijo", () => {
  it("venta: R-…", () => {
    expect(formatDeliveryNoteNumber("sale", 12)).toBe("R-00000012")
  })

  it("sin número (fila escrita en modo réplica) no hay etiqueta", () => {
    expect(formatDeliveryNoteNumber("sale", null)).toBeNull()
  })

  it("compra: RC-… (D2 de remitos-compra), nunca la R de venta ni el número pelado", () => {
    expect(formatDeliveryNoteNumber("purchase", 12)).toBe("RC-00000012")
    expect(formatDeliveryNoteNumber("purchase", 1)).toBe("RC-00000001")
  })

  it("compra: un número de más de 8 dígitos no se trunca", () => {
    expect(formatDeliveryNoteNumber("purchase", 123456789)).toBe("RC-123456789")
  })

  it("compra sin número (fila escrita en modo réplica) no hay etiqueta", () => {
    expect(formatDeliveryNoteNumber("purchase", null)).toBeNull()
  })

  it("el mismo número se rotula distinto según el sentido (cada sentido numera desde 1)", () => {
    expect(formatDeliveryNoteNumber("sale", 7)).toBe("R-00000007")
    expect(formatDeliveryNoteNumber("purchase", 7)).toBe("RC-00000007")
  })
})

describe("formatInternalDocumentNumber — delivery_note_purchase (remitos-compra, D2)", () => {
  it.each([
    [1, "RC-00000001"],
    [12, "RC-00000012"],
    [99999999, "RC-99999999"],
    [123456789, "RC-123456789"],
  ])("%i -> %s", (n, expected) => {
    expect(formatInternalDocumentNumber("delivery_note_purchase", n)).toBe(expected)
  })
})

describe("parseInternalDocumentNumberQuery — formatos del remito de compra", () => {
  it.each([
    ["RC-12", 12],
    ["rc-12", 12],
    ["RC-00000012", 12],
    ["  RC-00000012 ", 12],
    ["12", 12],
    ["00000012", 12],
  ])("%j -> %j", (query, expected) => {
    expect(parseInternalDocumentNumberQuery(query, "delivery_note_purchase")).toBe(expected)
  })

  it.each(["RC-", "RC-12-3", "RC-12a", "RC-0", "R-12", "R-00000012", "P-12", "Ramiro"])(
    "%j no es un número de la pestaña de compra",
    (query) => {
      expect(parseInternalDocumentNumberQuery(query, "delivery_note_purchase")).toBeNull()
    },
  )

  it("la R de venta no se lee en compra y la RC de compra no se lee en venta", () => {
    expect(parseInternalDocumentNumberQuery("R-12", "delivery_note_sale")).toBe(12)
    expect(parseInternalDocumentNumberQuery("R-12", "delivery_note_purchase")).toBeNull()
    expect(parseInternalDocumentNumberQuery("RC-12", "delivery_note_sale")).toBeNull()
    expect(parseInternalDocumentNumberQuery("RC-12", "delivery_note_purchase")).toBe(12)
  })

  it.each([1, 12, 4321, 99999999, 123456789])("lo que se imprime se vuelve a encontrar (%i)", (n) => {
    expect(
      parseInternalDocumentNumberQuery(formatInternalDocumentNumber("delivery_note_purchase", n), "delivery_note_purchase"),
    ).toBe(n)
  })
})

describe("fixture compartido", () => {
  const fixturePath = path.resolve(
    __dirname,
    "../../../backend/tests/fixtures/internal_document_number_cases.json",
  )
  const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf-8")) as {
    format_cases: { name: string; document_type: string; number: number; expected: string }[]
  }

  it("todo caso de remito de venta del fixture coincide con esta definición (vacío mientras la tarea 3.4 no lo sume)", () => {
    const cases = fixture.format_cases.filter((c) => c.document_type === "delivery_note_sale")
    for (const c of cases) {
      expect(formatInternalDocumentNumber("delivery_note_sale", c.number)).toBe(c.expected)
    }
  })
})
