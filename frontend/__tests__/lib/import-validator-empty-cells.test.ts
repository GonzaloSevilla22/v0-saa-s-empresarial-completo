/**
 * importador-productos-stock-apertura — celda vacía = conservar, NUNCA 0.
 *
 * Hasta este fix el validador arrancaba `price = 0`, `stock = 0` y
 * `minStock = 0`, así que una celda vacía de Precio, Stock o Stock mínimo viajaba
 * al servidor como un 0 declarado y, al ACTUALIZAR un producto por SKU, pisaba el
 * precio y el umbral de alerta vigentes. El contrato del backend ya era
 * null-preserving (`ProductImportRowIn`, D12 de productos-costo-nullable: "NINGÚN
 * campo opcional tiene un default numérico") y `rpc_bulk_upsert_products` ya usaba
 * COALESCE: lo que faltaba era que el CLIENTE dejara de inventar el 0.
 *
 *   - celda vacía  → `null` (alta: precio 0 / sin stock; edición: conserva)
 *   - "0" declarado → `0` (un cero escrito es un cero, igual que el costo)
 *   - valor inválido de Stock / Stock mínimo → 0 con aviso (comportamiento previo,
 *     cubierto por import-validator-quantities.test.ts)
 *   - fila Padre: sus celdas de precio y stock no se leen — equivalen a vacías
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { validateImportRows } from "@/lib/import/validator"
import type { RawImportRow } from "@/lib/import/types"

vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn(),
}))

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "SKU-1", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "3", stock_minimo: "2", codigo: "", codigo_balanza: "", attributes: {},
    ...over,
  }
}

describe("validateImportRows — celda vacía conserva (null), nunca 0", () => {
  it("Precio vacío → price null", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "" })])
    expect(rows[0].price).toBeNull()
    expect(rows[0].errors).toEqual([])
    expect(rows[0].warnings).toEqual([])
  })

  it("Precio con sólo espacios → price null", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "   " })])
    expect(rows[0].price).toBeNull()
  })

  it('Precio "0" declarado → 0 (un cero escrito es un cero)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "0" })])
    expect(rows[0].price).toBe(0)
  })

  it('Precio "1500,50" → 1500.5 (el valor informado no cambia)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "1500,50" })])
    expect(rows[0].price).toBe(1500.5)
  })

  it("Stock vacío → stock null", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "" })])
    expect(rows[0].stock).toBeNull()
    expect(rows[0].warnings).toEqual([])
  })

  it('Stock "0" declarado → 0', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "0" })])
    expect(rows[0].stock).toBe(0)
  })

  it('Stock "2,5" → 2.5 (el valor informado no cambia)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "2,5" })])
    expect(rows[0].stock).toBe(2.5)
  })

  it('Stock inválido ("abc") sigue cayendo a 0 con aviso — es un valor escrito, no una celda vacía', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "abc" })])
    expect(rows[0].stock).toBe(0)
    expect(rows[0].warnings.join(" ")).toMatch(/Stock inválido/)
  })

  it("Stock mínimo vacío → minStock null", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "" })])
    expect(rows[0].minStock).toBeNull()
    expect(rows[0].warnings).toEqual([])
  })

  it('Stock mínimo "0" declarado → 0 ("sin umbral" deliberado)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "0" })])
    expect(rows[0].minStock).toBe(0)
  })

  it('Stock mínimo "7" → 7', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "7" })])
    expect(rows[0].minStock).toBe(7)
  })

  it("las tres celdas vacías a la vez en una Variante → null, null, null", () => {
    const { rows } = validateImportRows([
      raw({ lineNumber: 2, tipo: "Variante", precio: "", stock: "", stock_minimo: "" }),
    ])
    expect(rows[0].price).toBeNull()
    expect(rows[0].stock).toBeNull()
    expect(rows[0].minStock).toBeNull()
  })

  it("fila Padre: precio y stock no se leen (equivalen a vacíos) → null, aunque la celda traiga un valor", () => {
    const { rows } = validateImportRows([
      raw({ lineNumber: 2, tipo: "Padre", precio: "999", stock: "50" }),
    ])
    expect(rows[0].price).toBeNull()
    expect(rows[0].stock).toBeNull()
  })
})

describe("prepareProductImport — apiRows lleva null por cada celda vacía", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("un Producto con las tres celdas vacías viaja con price/stock/minStock null (no 0)", async () => {
    const { parseImportFile } = await import("@/lib/import/parser")
    vi.mocked(parseImportFile).mockResolvedValueOnce({
      ok: true,
      rows: [raw({ lineNumber: 2, nombre: "Yerba", sku: "YM-1", precio: "", stock: "", stock_minimo: "" })],
    })
    const { prepareProductImport } = await import("@/lib/import/importer")

    const prepared = await prepareProductImport(new File(["x"], "p.csv", { type: "text/csv" }))

    expect(prepared.apiRows).toHaveLength(1)
    expect(prepared.apiRows[0].price).toBeNull()
    expect(prepared.apiRows[0].stock).toBeNull()
    expect(prepared.apiRows[0].minStock).toBeNull()
  })

  it("un Producto con valores viaja con ellos (el cero declarado también)", async () => {
    const { parseImportFile } = await import("@/lib/import/parser")
    vi.mocked(parseImportFile).mockResolvedValueOnce({
      ok: true,
      rows: [raw({ lineNumber: 2, nombre: "Yerba", sku: "YM-1", precio: "850", stock: "0", stock_minimo: "4" })],
    })
    const { prepareProductImport } = await import("@/lib/import/importer")

    const prepared = await prepareProductImport(new File(["x"], "p.csv", { type: "text/csv" }))

    expect(prepared.apiRows[0].price).toBe(850)
    expect(prepared.apiRows[0].stock).toBe(0)
    expect(prepared.apiRows[0].minStock).toBe(4)
  })

  it("una fila Padre viaja con price y stock null (su stock no se carga: lo llevan las variantes)", async () => {
    const { parseImportFile } = await import("@/lib/import/parser")
    vi.mocked(parseImportFile).mockResolvedValueOnce({
      ok: true,
      rows: [raw({ lineNumber: 2, tipo: "Padre", nombre: "Zapatillas", sku: "ZAP", precio: "100", stock: "9", stock_minimo: "" })],
    })
    const { prepareProductImport } = await import("@/lib/import/importer")

    const prepared = await prepareProductImport(new File(["x"], "p.csv", { type: "text/csv" }))

    expect(prepared.apiRows[0].price).toBeNull()
    expect(prepared.apiRows[0].stock).toBeNull()
  })
})
