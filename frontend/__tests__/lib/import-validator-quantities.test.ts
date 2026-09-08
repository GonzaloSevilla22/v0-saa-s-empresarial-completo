/**
 * stock-import-decimal-comma (candidato heredado del PR #522) — el
 * importador de PRODUCTOS parseaba stock y stock mínimo con `parseInt`,
 * truncando en silencio una cantidad física con coma decimal ("1,5" → 1) o
 * con un punto decimal ("1.234" → 1, en vez de 1.234). Mismo defecto
 * que el PR #522 cerró en el importador de AJUSTES de stock
 * (`lib/stock-import-parser.ts`), acá para `lib/import/validator.ts`.
 *
 * `stock` usa `parseAmount(raw, { loneCommaIsDecimal: true })`: admite
 * decimales (branch_stock.quantity es numeric(15,4)), coma sin punto SIEMPRE
 * decimal; un punto solo se lee como decimal (mismo contrato que
 * precio/costo). Un texto con dos o más puntos y sin coma ("1.234.567") no
 * tiene lectura válida y se rechaza en vez de leerse parcialmente. Un punto
 * único con grupos de tres dígitos ("1.500") SÍ se interpreta como decimal
 * (1,5) pero avisa la ambigüedad, porque también podría ser 1500 en miles.
 * Más de 4 decimales se redondea con aviso (branch_stock.quantity es
 * numeric(15,4)).
 *
 * `stock_minimo` usa el mismo parseAmount pero además exige ENTERO
 * (products.min_stock / branch_stock.min_stock son integer en DB — un texto
 * no entero enviado a la RPC lanza 22P02 y aborta el lote completo). Un no
 * entero ≥ 0 se redondea hacia arriba (Math.ceil) con aviso — NaN o negativo
 * caen a 0 con aviso "sin umbral de alerta" (min_stock = 0 desactiva la
 * alerta de reposición, RN canónica de `lib/product-stock.ts`).
 */

import { describe, it, expect } from "vitest"
import { validateImportRows } from "@/lib/import/validator"
import type { RawImportRow } from "@/lib/import/types"
import { buildTemplateCsv } from "@/lib/import/template"
import { parseImportText } from "@/lib/import/parser"

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "", attributes: {},
    ...over,
  }
}

describe("validateImportRows — stock (cantidad física, admite decimales)", () => {
  it('"1,5" (coma decimal es-AR) → 1.5, sin warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1,5" })])
    expect(rows[0].stock).toBe(1.5)
    expect(rows[0].warnings).toEqual([])
  })

  it('"0,25" → 0.25', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "0,25" })])
    expect(rows[0].stock).toBe(0.25)
    expect(rows[0].warnings).toEqual([])
  })

  it('"12" (entero simple) → 12', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "12" })])
    expect(rows[0].stock).toBe(12)
    expect(rows[0].warnings).toEqual([])
  })

  it('"1,2345" (4 decimales exactos) → 1.2345 sin warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1,2345" })])
    expect(rows[0].stock).toBe(1.2345)
    expect(rows[0].warnings).toEqual([])
  })

  it('"abc" (no numérico) → 0 + warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "abc" })])
    expect(rows[0].stock).toBe(0)
    expect(rows[0].warnings.join(" ")).toMatch(/Stock inválido/)
  })

  it('"-3" (negativo) → 0 + warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "-3" })])
    expect(rows[0].stock).toBe(0)
    expect(rows[0].warnings.join(" ")).toMatch(/Stock inválido/)
  })

  it('"1,2,3" (dos comas) → 0 + warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1,2,3" })])
    expect(rows[0].stock).toBe(0)
    expect(rows[0].warnings.join(" ")).toMatch(/Stock inválido/)
  })

  it('"1.234.567" (2+ puntos sin coma) → 0 + warning (antes: 1.234 en silencio)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1.234.567" })])
    expect(rows[0].stock).toBe(0)
    expect(rows[0].warnings).toEqual([
      'Stock inválido: "1.234.567" — se usará 0.',
    ])
  })

  it('"1.500" (punto único, grupo de miles) → se lee como 1.5 pero avisa la ambigüedad (antes: 1.5 en silencio)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1.500" })])
    expect(rows[0].stock).toBe(1.5)
    expect(rows[0].warnings).toEqual([
      'Stock ambiguo: "1.500" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it('"1.5" (punto decimal simple) → 1.5 sin warning — mismo contrato que precio/costo: un punto suelto es decimal, nunca miles', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1.5" })])
    expect(rows[0].stock).toBe(1.5)
    expect(rows[0].warnings).toEqual([])
  })

  it('"1,500" (agrupación con coma, estilo en-US) → se lee como 1.5 pero avisa la ambigüedad (paridad con el importador de ajustes)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1,500" })])
    expect(rows[0].stock).toBe(1.5)
    expect(rows[0].warnings).toEqual([
      'Stock ambiguo: "1,500" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it('"1.500 kg" (ruido que parseAmount descarta) → el detector mira el texto limpio y avisa igual', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1.500 kg" })])
    expect(rows[0].stock).toBe(1.5)
    expect(rows[0].warnings).toEqual([
      'Stock ambiguo: "1.500 kg" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it('"1,23456" (más de 4 decimales) → se redondea a 4 con warning (antes: pasaba sin aviso)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock: "1,23456" })])
    expect(rows[0].stock).toBe(1.2346)
    expect(rows[0].warnings).toEqual([
      'Stock "1,23456" se redondeó a 1,2346 (máximo 4 decimales).',
    ])
  })

  it("fila Padre ignora el stock (comportamiento actual, sin cambios)", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, tipo: "Padre", stock: "1,5" })])
    expect(rows[0].stock).toBe(0)
    expect(rows[0].warnings).toEqual([])
  })
})

describe("validateImportRows — stock mínimo (entero, con aviso)", () => {
  it('"10" → 10, sin warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "10" })])
    expect(rows[0].minStock).toBe(10)
    expect(rows[0].warnings).toEqual([])
  })

  it('"1000" (sin separador) → 1000, sin warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "1000" })])
    expect(rows[0].minStock).toBe(1000)
    expect(rows[0].warnings).toEqual([])
  })

  it('"2,5" (no entero) → se redondea hacia arriba a 3 con warning (antes de este fix: 0 + "inválido"; antes del PR #522: 2 en silencio)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "2,5" })])
    expect(rows[0].minStock).toBe(3)
    expect(rows[0].warnings).toEqual([
      'Stock mínimo "2,5" no admite decimales: se usará 3.',
    ])
  })

  it('"0,4" (no entero, redondea a 1) → 1 + warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "0,4" })])
    expect(rows[0].minStock).toBe(1)
    expect(rows[0].warnings).toEqual([
      'Stock mínimo "0,4" no admite decimales: se usará 1.',
    ])
  })

  it('"-1" (negativo) → 0 + warning "sin umbral de alerta"', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "-1" })])
    expect(rows[0].minStock).toBe(0)
    expect(rows[0].warnings).toEqual([
      'Stock mínimo inválido: "-1" — debe ser un entero ≥ 0, se usará 0 (sin umbral de alerta).',
    ])
  })

  it('"1.500" (punto único, grupo de miles) → ambigüedad + ceil(1,5)=2, con sus dos warnings', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "1.500" })])
    expect(rows[0].minStock).toBe(2)
    expect(rows[0].warnings).toEqual([
      'Stock mínimo ambiguo: "1.500" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
      'Stock mínimo "1.500" no admite decimales: se usará 2.',
    ])
  })

  it("vacío → 0 sin warning", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, stock_minimo: "" })])
    expect(rows[0].minStock).toBe(0)
    expect(rows[0].warnings).toEqual([])
  })
})

describe("buildTemplateCsv → parseImportText → validateImportRows (ida y vuelta, R4)", () => {
  it('la fila de granel "Yerba suelta (kg)" conserva stock decimal y mínimo entero; Aceite conserva stock 30', () => {
    const csv = buildTemplateCsv([])
    const parsed = parseImportText(csv)
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return

    const { rows } = validateImportRows(parsed.rows)

    const yerba = rows.find((r) => r.name === "Yerba suelta (kg)")
    expect(yerba).toBeDefined()
    expect(yerba?.stock).toBe(2.5)
    expect(yerba?.minStock).toBe(1)
    expect(yerba?.warnings).toEqual([])

    const aceite = rows.find((r) => r.name.startsWith("Aceite"))
    expect(aceite).toBeDefined()
    expect(aceite?.stock).toBe(30)
  })
})
