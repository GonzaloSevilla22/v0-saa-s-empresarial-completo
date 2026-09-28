/**
 * balanza-etiquetas-pos (task 4.4) — RED→GREEN de `resolveScan` (D6).
 */
import { describe, it, expect } from "vitest"
import { resolveScan, type ScanContext } from "@/lib/scan-resolution"
import { FACTORY_SCALE_SETTINGS, type ScaleSettings } from "@/lib/scale-layout"
import { generateEAN13 } from "@/lib/barcode-utils"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UNIT: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS = [KG, UNIT]
const UNITS_BY_ID = new Map(UNITS.map((u) => [u.id, u]))
const ENABLED_FACTORY: ScaleSettings = { ...FACTORY_SCALE_SETTINGS, enabled: true }

function product(overrides: Partial<Product> & { id: string; name: string; price: number }): Product {
  return {
    category: "Otros",
    cost: null,
    margin: null,
    stock: 1000,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    ...overrides,
  }
}

function ctx(products: Product[], settings: ScaleSettings = ENABLED_FACTORY): ScanContext {
  return { products, units: UNITS, unitsById: UNITS_BY_ID, settings }
}

describe("resolveScan — D6", () => {
  it("un código de barras declarado gana sobre la interpretación de balanza", () => {
    // Un barcode generado al azar que empieza con "20..." podría, sin este
    // orden, decodificarse como etiqueta en lugar de resolverse por su
    // barcode declarado (D6, por qué el código exacto va primero).
    const p = product({ id: "p1", name: "Envasado", price: 100, barcode: "2000123456782" })
    const r = resolveScan("2000123456782", ctx([p]))
    expect(r).toEqual({ kind: "product", product: p })
  })

  it("TRIANGULATE: más de un candidato por barcode case-insensitive → error", () => {
    const a = product({ id: "p1", name: "A", price: 1, barcode: "abc123" })
    const b = product({ id: "p2", name: "B", price: 1, barcode: "ABC123" })
    const r = resolveScan("Abc123", ctx([a, b]))
    expect(r).toEqual({ kind: "error", message: "El código coincide con 2 productos" })
  })

  it("una etiqueta válida resuelve a scale_line", () => {
    const p = product({ id: "p1", name: "Tomate", price: 4.8, baseUnitId: "u-kg", scalePlu: 261 })
    const r = resolveScan("2002610013638", ctx([p]))
    expect(r.kind).toBe("scale_line")
  })

  it("una etiqueta con la lectura deshabilitada se explica y sugiere activarla", () => {
    const r = resolveScan("2002610013638", ctx([], FACTORY_SCALE_SETTINGS))
    expect(r).toEqual({
      kind: "error",
      message:
        "Parece una etiqueta de balanza, pero la lectura de etiquetas está deshabilitada — activala en Configuración → Balanza",
    })
  })

  it("un SKU con forma de etiqueta no queda robado por la balanza (12 dígitos, missing_check_digit)", () => {
    const p = product({ id: "p1", name: "Producto raro", price: 10, sku: "200261001363" })
    const r = resolveScan("200261001363", ctx([p]))
    expect(r).toEqual({ kind: "product", product: p })
  })

  it("un SKU se resuelve cuando no es código de barras ni etiqueta", () => {
    const p = product({ id: "p1", name: "Zapatilla", price: 10, sku: "ZAP-01" })
    const r = resolveScan("zap-01", ctx([p]))
    expect(r).toEqual({ kind: "product", product: p })
  })

  it("un código desconocido informa el error de no encontrado", () => {
    const r = resolveScan("NOEXISTE", ctx([]))
    expect(r).toEqual({ kind: "error", message: 'Código "NOEXISTE" no encontrado' })
  })

  it("una etiqueta con una cabecera no configurada se explica con su número", () => {
    const r = resolveScan("2702610013637", ctx([]))
    expect(r).toEqual({
      kind: "error",
      message: "Parece una etiqueta de balanza (cabecera 27) que no coincide con ningún formato configurado — revisá Configuración → Balanza",
    })
  })

  it("TRIANGULATE: una etiqueta inválida (verificador incorrecto) sin SKU igual → error del decodificador, nunca 'no encontrado'", () => {
    const r = resolveScan("2002610013639", ctx([]))
    expect(r.kind).toBe("error")
    if (r.kind !== "error") throw new Error("expected error")
    expect(r.message).not.toContain("no encontrado")
    expect(r.message).toContain("dígito verificador")
  })

  it("TRIANGULATE: con un producto cuyo SKU es exactamente ese código inválido → resuelve el producto", () => {
    const p = product({ id: "p1", name: "Cualquiera", price: 5, sku: "2002610013639" })
    const r = resolveScan("2002610013639", ctx([p]))
    expect(r).toEqual({ kind: "product", product: p })
  })

  it("un padre con variantes queda excluido de la búsqueda por barcode y SKU", () => {
    const padre = product({ id: "padre", name: "Buzo", price: 0, barcode: "1234567890128", sku: "BUZO" })
    const variante = product({ id: "var1", name: "Talle M", price: 100, parentId: "padre" })
    const r = resolveScan("1234567890128", ctx([padre, variante]))
    expect(r).toEqual({ kind: "error", message: 'Código "1234567890128" no encontrado' })
  })

  it("REFACTOR: un barcode con cabecera 20-29 (como los que generateEAN13 a veces produce) se resuelve por su declaración, no como etiqueta", () => {
    // generateEAN13() reutilizado como referencia de que el generador PUEDE
    // producir códigos con cabecera 20-29 (~10% de las corridas) — acá se
    // fuerza uno determinístico con el mismo algoritmo de verificador.
    const base = "20" + "1234567890".slice(0, 10) // 12 dígitos: "201234567890"
    const digits = base.split("").map(Number)
    const sum = digits.reduce((acc, d, i) => acc + d * (i % 2 === 0 ? 1 : 3), 0)
    const check = (10 - (sum % 10)) % 10
    const code = base + String(check)
    const p = product({ id: "p1", name: "Producto con barcode 20xxxx", price: 20, barcode: code })
    const r = resolveScan(code, ctx([p]))
    expect(r).toEqual({ kind: "product", product: p })
    expect(generateEAN13()).toMatch(/^\d{13}$/) // sigue siendo el generador reutilizado, no reimplementado
  })
})
