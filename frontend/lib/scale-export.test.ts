/**
 * balanza-etiquetas-pos (task 4.5) — RED→GREEN de `buildScaleCsv` (D12).
 */
import { describe, it, expect } from "vitest"
import { buildScaleCsv } from "@/lib/scale-export"
import { FACTORY_SCALE_SETTINGS, type ScaleSettings } from "@/lib/scale-layout"
import type { Product, ProductCategory, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const L: UnitOfMeasure = { id: "u-l", name: "Litro", symbol: "L", type: "volume", factor: 1, isSystem: true }
const UNIT: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS = [KG, G, L, UNIT]

const ENABLED_FACTORY: ScaleSettings = { ...FACTORY_SCALE_SETTINGS, enabled: true }

const VERDULERIA: ProductCategory = { id: "cat-1", accountId: "acc-1", name: "Verdulería", isActive: true, sortOrder: 0, createdAt: "" }
const CATEGORIES = new Map([[VERDULERIA.id, VERDULERIA]])

function product(overrides: Partial<Product> & { id: string; name: string; price: number }): Product {
  return {
    category: "Otros",
    cost: null,
    margin: null,
    stock: 100,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    ...overrides,
  }
}

describe("buildScaleCsv — D12", () => {
  it("un producto de peso se exporta por kilo (31 campos, \\r\\n)", () => {
    const zanahoria = product({
      id: "p1",
      name: "Zanahoria orgánica",
      price: 1250,
      baseUnitId: "u-kg",
      scalePlu: 509,
      sku: "ZAN-01",
      categoryId: "cat-1",
    })
    const { csv, included, skipped } = buildScaleCsv([zanahoria], CATEGORIES, UNITS, ENABLED_FACTORY)
    expect(included).toBe(1)
    expect(skipped).toHaveLength(0)
    const line = csv.split("\r\n")[0]
    const fields = line.split(";")
    expect(fields).toHaveLength(31)
    expect(line).toBe(
      "Verduleria;509;Zanahoria organica;ZAN-01;1250,00;0,00;p;0;;;;;;;;;;;;;;;;;;;;;;;",
    )
    expect(csv.endsWith("\r\n")).toBe(true)
  })

  it("un producto por unidad se exporta con tipo u", () => {
    const lechuga = product({ id: "p2", name: "Lechuga", price: 4.5, baseUnitId: "u-un", scalePlu: 100 })
    const { csv } = buildScaleCsv([lechuga], CATEGORIES, UNITS, ENABLED_FACTORY)
    const fields = csv.split("\r\n")[0].split(";")
    expect(fields[4]).toBe("4,50")
    expect(fields[6]).toBe("u")
  })

  it("un producto con precio por gramo se exporta por kilo", () => {
    const p = product({ id: "p3", name: "A granel", price: 4.5, baseUnitId: "u-g", scalePlu: 300 })
    const { csv } = buildScaleCsv([p], CATEGORIES, UNITS, ENABLED_FACTORY)
    const fields = csv.split("\r\n")[0].split(";")
    expect(fields[4]).toBe("4500,00")
    expect(fields[6]).toBe("p")
  })

  it("productos que no se pueden exportar: sin precio y sin código de balanza", () => {
    const sinPrecio = product({ id: "p4", name: "Sin precio", price: 0, baseUnitId: "u-kg", scalePlu: 400 })
    const sinPlu = product({ id: "p5", name: "Sin PLU", price: 10, baseUnitId: "u-un" })
    const { included, skipped } = buildScaleCsv([sinPrecio, sinPlu], CATEGORIES, UNITS, ENABLED_FACTORY)
    expect(included).toBe(0)
    expect(skipped).toHaveLength(1)
    expect(skipped[0]).toMatchObject({ productId: "p4", reason: "no_price" })
  })

  it("TRIANGULATE: un padre con variantes se omite (aunque tenga precio)", () => {
    const padre = product({ id: "padre", name: "Buzo", price: 100, scalePlu: 900, stockControlType: "variant_only" })
    const { included, skipped } = buildScaleCsv([padre], CATEGORIES, UNITS, ENABLED_FACTORY)
    expect(included).toBe(0)
    expect(skipped[0].reason).toBe("parent")
  })

  it("TRIANGULATE: un producto medible que no es de peso (Litro) se omite", () => {
    const agua = product({ id: "p6", name: "Agua", price: 10, baseUnitId: "u-l", scalePlu: 700 })
    const { included, skipped } = buildScaleCsv([agua], CATEGORIES, UNITS, ENABLED_FACTORY)
    expect(included).toBe(0)
    expect(skipped[0].reason).toBe("not_sellable_by_scale")
  })

  it("un punto y coma en el nombre no rompe el archivo (31 campos, sin ;)", () => {
    const p = product({ id: "p7", name: "Papa; negra", price: 10, baseUnitId: "u-kg", scalePlu: 800 })
    const { csv } = buildScaleCsv([p], CATEGORIES, UNITS, ENABLED_FACTORY)
    const line = csv.split("\r\n")[0]
    expect(line.split(";")).toHaveLength(31)
    expect(line).not.toContain("Papa;")
    expect(line).toContain("Papa, negra")
  })

  it("un SKU demasiado largo no se trunca: código ERP vacío + aviso", () => {
    const p = product({ id: "p8", name: "Con SKU largo", price: 10, baseUnitId: "u-kg", scalePlu: 810, sku: "A".repeat(30) })
    const { csv, warnings } = buildScaleCsv([p], CATEGORIES, UNITS, ENABLED_FACTORY)
    const fields = csv.split("\r\n")[0].split(";")
    expect(fields[3]).toBe("")
    expect(warnings).toContainEqual({ productId: "p8", productName: "Con SKU largo", reason: "sku_too_long" })
  })

  it("un nombre con comillas dobles y simples no rompe el archivo (11.4 red-team): sin comillado RFC4180, pasan literales sin agregar campos", () => {
    const p = product({ id: "p10", name: `Dulce de "leche" 1kg`, price: 10, baseUnitId: "u-kg", scalePlu: 830 })
    const { csv } = buildScaleCsv([p], CATEGORIES, UNITS, ENABLED_FACTORY)
    const line = csv.split("\r\n")[0]
    const fields = line.split(";")
    expect(fields).toHaveLength(31)
    expect(line).toContain(`Dulce de "leche" 1kg`)
  })

  it("TRIANGULATE: nombre y sección con emoji/tildes/ñ se translitera a ASCII", () => {
    const p = product({ id: "p9", name: "Ñoquis 🥔 caseros", price: 10, baseUnitId: "u-un", scalePlu: 820 })
    const { csv } = buildScaleCsv([p], CATEGORIES, UNITS, ENABLED_FACTORY)
    const line = csv.split("\r\n")[0]
    // eslint-disable-next-line no-control-regex
    expect(/^[\x20-\x7e;]*$/.test(line)).toBe(true)
    expect(line).toContain("Noquis")
  })

  it("REFACTOR: un PLU más largo que el campo Código del formato habilitado se omite", () => {
    const settingsNarrowPlu: ScaleSettings = {
      enabled: true,
      layouts: [
        {
          kind: "weighed",
          enabled: true,
          segments: [
            { field: "fixed", digits: 2, value: "20" },
            { field: "plu", digits: 2 },
            { field: "amount", digits: 8, decimals: 2 },
          ],
        },
        ENABLED_FACTORY.layouts[1],
        ENABLED_FACTORY.layouts[2],
      ],
    }
    // scale_plu de 3 dígitos (261) no cabe en un campo Código de 2 dígitos.
    const p = product({ id: "p10", name: "Tomate", price: 10, baseUnitId: "u-kg", scalePlu: 261 })
    const { included, skipped } = buildScaleCsv([p], CATEGORIES, UNITS, settingsNarrowPlu)
    expect(included).toBe(0)
    expect(skipped[0].reason).toBe("plu_too_long")
  })

  it("sin productos exportables, el CSV queda vacío", () => {
    const { csv, included } = buildScaleCsv([], CATEGORIES, UNITS, ENABLED_FACTORY)
    expect(csv).toBe("")
    expect(included).toBe(0)
  })
})
