/**
 * candidatos-importadores (cierre del 1er heredado de `product-import-decimal-stock`,
 * PR #524): precio y costo se leen con `parseAmount` default (un punto suelto
 * es SIEMPRE decimal — "1.500" → $1,5, mismo contrato que hoy) pero ahora
 * avisan cuando el texto también admite lectura como miles ("1.500" podría
 * ser $1500), igual que ya hace `stock`/`stock_minimo` desde el fix anterior.
 * NO cambia el contrato de lectura ("1,500" sigue siendo $1500 sin aviso —
 * convención es-AR, coma con grupo de tres dígitos = miles).
 *
 * El texto del warning muestra `formatNumber(value, 4)`, no `formatMoney`
 * (revisión adversarial: `formatMoney` redondea a 2 decimales y miente
 * cuando el valor leído tiene más — "12.345.678" se importa como 12.345,
 * pero `formatMoney` lo mostraría como $12,35).
 */

import { describe, it, expect } from "vitest"
import { validateImportRows } from "@/lib/import/validator"
import type { RawImportRow } from "@/lib/import/types"
import { formatNumber } from "@/lib/format"

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "", attributes: {},
    ...over,
  }
}

describe("validateImportRows — precio ambiguo (punto único, grupo de miles)", () => {
  it('"1.500" → $1,5 (contrato sin cambios) + warning de ambigüedad', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "1.500" })])
    expect(rows[0].price).toBe(1.5)
    expect(rows[0].warnings).toEqual([
      `Precio ambiguo: "1.500" — se interpretó como $ ${formatNumber(1.5, 4)}. Usá coma para decimales y ningún separador para miles.`,
    ])
  })

  it('"1,500" (coma, convención es-AR de miles) → $1500 SIN warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "1,500" })])
    expect(rows[0].price).toBe(1500)
    expect(rows[0].warnings).toEqual([])
  })

  it('"1500" (sin separador) → $1500 sin warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "1500" })])
    expect(rows[0].price).toBe(1500)
    expect(rows[0].warnings).toEqual([])
  })

  it('"1.234,56" (ambos separadores, sin ambigüedad) → $1234.56 sin warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, precio: "1.234,56" })])
    expect(rows[0].price).toBe(1234.56)
    expect(rows[0].warnings).toEqual([])
  })
})

describe("validateImportRows — costo ambiguo (mismo detector, rótulo distinto)", () => {
  it('"1.500" → $1,5 + warning de ambigüedad con rótulo "Costo"', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, costo: "1.500" })])
    expect(rows[0].cost).toBe(1.5)
    expect(rows[0].warnings).toEqual([
      `Costo ambiguo: "1.500" — se interpretó como $ ${formatNumber(1.5, 4)}. Usá coma para decimales y ningún separador para miles.`,
    ])
  })

  it('"1,500" → $1500 sin warning', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, costo: "1,500" })])
    expect(rows[0].cost).toBe(1500)
    expect(rows[0].warnings).toEqual([])
  })
})
