/**
 * presupuestos-modulo (D3, task 4.3) — `lib/internal-document-number.ts`.
 *
 * Los casos salen del MISMO archivo que recorre pytest
 * (`backend/tests/fixtures/internal_document_number_cases.json`), como el de
 * `scale_layout_cases.json`: una sola definición del formato `P-00000012`
 * por lenguaje, un solo contrato.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import {
  formatInternalDocumentNumber,
  parseInternalDocumentNumberQuery,
  type InternalDocumentType,
} from "@/lib/internal-document-number"

interface FormatCase {
  name: string
  document_type: InternalDocumentType
  number: number
  expected: string
}
interface QueryCase {
  name: string
  query: string
  document_type: InternalDocumentType
  expected: number | null
}

const fixturePath = path.resolve(
  __dirname,
  "../../../backend/tests/fixtures/internal_document_number_cases.json",
)
const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf-8")) as {
  format_cases: FormatCase[]
  query_cases: QueryCase[]
}

describe("formatInternalDocumentNumber — contrato compartido con pytest", () => {
  it("el fixture trae casos (la suite no pasa en vacío)", () => {
    expect(fixture.format_cases.length).toBeGreaterThanOrEqual(3)
  })
  it.each(fixture.format_cases.map((c) => [c.name, c] as const))("%s", (_name, c) => {
    expect(formatInternalDocumentNumber(c.document_type, c.number)).toBe(c.expected)
  })
})

describe("parseInternalDocumentNumberQuery — contrato compartido con pytest", () => {
  it("el fixture trae casos de número y de texto", () => {
    expect(fixture.query_cases.some((c) => c.expected !== null)).toBe(true)
    expect(fixture.query_cases.some((c) => c.expected === null)).toBe(true)
  })
  it.each(fixture.query_cases.map((c) => [c.name, c] as const))("%s", (_name, c) => {
    expect(parseInternalDocumentNumberQuery(c.query, c.document_type)).toBe(c.expected)
  })
})

describe("ida y vuelta", () => {
  it.each([1, 12, 4321, 99999999, 123456789])("lo que se imprime se vuelve a encontrar (%i)", (n) => {
    expect(parseInternalDocumentNumberQuery(formatInternalDocumentNumber("quote", n), "quote")).toBe(n)
  })
  it.each([1, 12, 123456789])("también para el remito de venta (%i)", (n) => {
    const label = formatInternalDocumentNumber("delivery_note_sale", n)
    expect(parseInternalDocumentNumberQuery(label, "delivery_note_sale")).toBe(n)
    // El prefijo del otro tipo no es de este listado: se busca como texto.
    expect(parseInternalDocumentNumberQuery(label, "quote")).toBeNull()
  })
})
