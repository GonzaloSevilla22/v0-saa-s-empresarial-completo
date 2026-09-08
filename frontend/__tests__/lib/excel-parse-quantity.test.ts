/**
 * candidatos-importadores (cierre de los dos heredados de `product-import-decimal-stock`,
 * PR #524): helper canónico de cantidades, único punto que hoy fija las reglas
 * duplicadas entre `lib/import/validator.ts` (stock / stock_minimo del importador
 * de productos) y `lib/stock-import-parser.ts` (cantidad del importador de
 * ajustes). Mismo contrato de texto/es-AR que `parseAmount`, con:
 *   - coma sin punto SIEMPRE decimal (`loneCommaIsDecimal`);
 *   - 2+ puntos sin coma → inválido (parseFloat se detendría en el 2do punto
 *     y leería un valor parcial en silencio — el bug que corrigió stock);
 *   - agrupación de miles con un solo separador ("1.500", "1,500") → se lee
 *     como decimal pero avisa la ambigüedad;
 *   - `integer: true` → redondea hacia arriba (Math.ceil) con aviso;
 *   - `maxDecimals` → redondea con aviso cuando el texto trae más decimales;
 *   - un valor negativo es inválido por defecto; `allowNegative: true` lo deja
 *     pasar tal cual (usado por el importador de ajustes, que arma su propio
 *     error "no puede ser negativa" en vez de zeroearlo en silencio);
 *   - `silent: true` no genera ningún texto de warning (mismo importador,
 *     que ya tiene su propio canal de errores/warnings por fila).
 */

import { describe, it, expect } from "vitest"
import { parseQuantity } from "@/lib/excel"

describe("parseQuantity — modo decimal (label Cantidad, maxDecimals 4)", () => {
  const opts = { label: "Cantidad", maxDecimals: 4 } as const

  it('"1,5" → 1.5 sin warning', () => {
    const r = parseQuantity("1,5", opts)
    expect(r).toEqual({ value: 1.5, warnings: [], invalid: false })
  })

  it('"1.5" (punto único no ambiguo) → 1.5 sin warning', () => {
    const r = parseQuantity("1.5", opts)
    expect(r).toEqual({ value: 1.5, warnings: [], invalid: false })
  })

  it('"1.500" (grupo de miles, punto único) → 1.5 con warning de ambigüedad', () => {
    const r = parseQuantity("1.500", opts)
    expect(r.value).toBe(1.5)
    expect(r.invalid).toBe(false)
    expect(r.warnings).toEqual([
      'Cantidad ambigua: "1.500" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it('"1,500" (agrupación con coma) → 1.5 con warning de ambigüedad', () => {
    const r = parseQuantity("1,500", opts)
    expect(r.value).toBe(1.5)
    expect(r.warnings).toEqual([
      'Cantidad ambigua: "1,500" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it('"1.500 kg" (ruido) → el detector mira el texto limpio y avisa igual', () => {
    const r = parseQuantity("1.500 kg", opts)
    expect(r.value).toBe(1.5)
    expect(r.warnings).toEqual([
      'Cantidad ambigua: "1.500 kg" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it('"1.234.567" (2+ puntos sin coma) → inválido, no lectura parcial', () => {
    const r = parseQuantity("1.234.567", opts)
    expect(r).toEqual({
      value: null,
      invalid: true,
      warnings: ['Cantidad inválida: "1.234.567" — se usará 0.'],
    })
  })

  it('"1,2345" (4 decimales exactos) → 1.2345 sin warning', () => {
    const r = parseQuantity("1,2345", opts)
    expect(r).toEqual({ value: 1.2345, warnings: [], invalid: false })
  })

  it('"1,23456" (más de 4 decimales) → redondea a 1.2346 con warning', () => {
    const r = parseQuantity("1,23456", opts)
    expect(r.value).toBe(1.2346)
    expect(r.warnings).toEqual([
      'Cantidad "1,23456" se redondeó a 1,2346 (máximo 4 decimales).',
    ])
  })

  it('"2,5" → 2.5 sin warning (no aplica redondeo, no llega a 4 decimales)', () => {
    const r = parseQuantity("2,5", opts)
    expect(r).toEqual({ value: 2.5, warnings: [], invalid: false })
  })

  it('"0,4" → 0.4 sin warning', () => {
    const r = parseQuantity("0,4", opts)
    expect(r).toEqual({ value: 0.4, warnings: [], invalid: false })
  })

  it('"-1" → inválido por defecto (negativo)', () => {
    const r = parseQuantity("-1", opts)
    expect(r).toEqual({
      value: null,
      invalid: true,
      warnings: ['Cantidad inválida: "-1" — se usará 0.'],
    })
  })

  it('"abc" → inválido', () => {
    const r = parseQuantity("abc", opts)
    expect(r.invalid).toBe(true)
    expect(r.value).toBeNull()
  })

  it('" 3 " (con espacios) → 3', () => {
    const r = parseQuantity(" 3 ", opts)
    expect(r).toEqual({ value: 3, warnings: [], invalid: false })
  })

  it('"" (vacío) → celda no cargada: inválido sin warning (no cita una cadena vacía)', () => {
    const r = parseQuantity("", opts)
    expect(r).toEqual({ value: null, invalid: true, warnings: [] })
  })

  it('"   " (sólo espacios) → mismo contrato que vacío', () => {
    const r = parseQuantity("   ", opts)
    expect(r).toEqual({ value: null, invalid: true, warnings: [] })
  })
})

describe("parseQuantity — modo entero (label Cantidad, integer true)", () => {
  const opts = { label: "Cantidad", integer: true } as const

  it('"2,5" → redondea hacia arriba a 3 con warning', () => {
    const r = parseQuantity("2,5", opts)
    expect(r.value).toBe(3)
    expect(r.warnings).toEqual(['Cantidad "2,5" no admite decimales: se usará 3.'])
  })

  it('"0,4" → redondea hacia arriba a 1 con warning', () => {
    const r = parseQuantity("0,4", opts)
    expect(r.value).toBe(1)
    expect(r.warnings).toEqual(['Cantidad "0,4" no admite decimales: se usará 1.'])
  })

  it('"-1" → inválido con el texto de entero', () => {
    const r = parseQuantity("-1", opts)
    expect(r).toEqual({
      value: null,
      invalid: true,
      warnings: [
        'Cantidad inválida: "-1" — debe ser un entero ≥ 0, se usará 0 (sin umbral de alerta).',
      ],
    })
  })

  it('"abc" → inválido con el texto de entero', () => {
    const r = parseQuantity("abc", opts)
    expect(r.invalid).toBe(true)
    expect(r.warnings).toEqual([
      'Cantidad inválida: "abc" — debe ser un entero ≥ 0, se usará 0 (sin umbral de alerta).',
    ])
  })

  it('"1.500" (ambigüedad + no entero) → dos warnings, en orden: ambigüedad, luego entero', () => {
    const r = parseQuantity("1.500", opts)
    expect(r.value).toBe(2)
    expect(r.warnings).toEqual([
      'Cantidad ambigua: "1.500" — se interpretó como 1,5. Usá coma para decimales y ningún separador para miles.',
      'Cantidad "1.500" no admite decimales: se usará 2.',
    ])
  })

  it('"3" (entero exacto) → 3 sin warning', () => {
    const r = parseQuantity("3", opts)
    expect(r).toEqual({ value: 3, warnings: [], invalid: false })
  })

  it('" 3 " (con espacios) → 3 sin warning', () => {
    const r = parseQuantity(" 3 ", opts)
    expect(r).toEqual({ value: 3, warnings: [], invalid: false })
  })

  it('"" (vacío) → inválido sin warning (ni siquiera el texto de entero)', () => {
    const r = parseQuantity("", opts)
    expect(r).toEqual({ value: null, invalid: true, warnings: [] })
  })
})

describe("parseQuantity — allowNegative + silent (uso del importador de ajustes de stock)", () => {
  const opts = { label: "Cantidad", allowNegative: true, silent: true } as const

  it('"-1,5" → -1.5, sin warnings, no invalid (el caller decide si es un error)', () => {
    const r = parseQuantity("-1,5", opts)
    expect(r).toEqual({ value: -1.5, warnings: [], invalid: false })
  })

  it('"1,250" (ambiguo) → 1.25 sin warning (silent la suprime)', () => {
    const r = parseQuantity("1,250", opts)
    expect(r).toEqual({ value: 1.25, warnings: [], invalid: false })
  })

  it('"abc" → invalid true, value null, sin warning (silent)', () => {
    const r = parseQuantity("abc", opts)
    expect(r).toEqual({ value: null, warnings: [], invalid: true })
  })

  it('"1.234.567" (2+ puntos) → invalid true, sin warning (silent)', () => {
    const r = parseQuantity("1.234.567", opts)
    expect(r).toEqual({ value: null, warnings: [], invalid: true })
  })

  it('"" (vacío) → invalid true, sin warning (mismo contrato, silent ya lo garantizaba)', () => {
    const r = parseQuantity("", opts)
    expect(r).toEqual({ value: null, warnings: [], invalid: true })
  })
})
