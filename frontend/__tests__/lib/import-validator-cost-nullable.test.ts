/**
 * productos-costo-nullable (task 7.2 RED/GREEN) — el importador distingue la
 * celda de costo VACÍA (sin costo) de "0" (costo cero declarado). Antes de
 * este change, `cost` defaulteaba a 0 tanto para celda vacía como para
 * celda ilegible; ahora `cost` es `number | null` y el warning de costo
 * ilegible avisa que quedará SIN costo, no que "se usará 0".
 */

import { describe, it, expect } from "vitest"
import { validateImportRows } from "@/lib/import/validator"
import type { RawImportRow } from "@/lib/import/types"

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "", attributes: {},
    ...over,
  }
}

describe("validateImportRows — costo opcional (productos-costo-nullable)", () => {
  it("celda de costo vacía → cost null, no 0", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, costo: "" })])
    expect(rows[0].cost).toBeNull()
  })

  it('celda de costo "0" explícito → cost 0 (declarado, distinto de null)', () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, costo: "0" })])
    expect(rows[0].cost).toBe(0)
  })

  it("costo ilegible → avisa que quedará SIN costo, no que se usará 0", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, costo: "abc" })])
    expect(rows[0].cost).toBeNull()
    expect(rows[0].warnings.some((w) => /se dejará sin costo/i.test(w))).toBe(true)
    expect(rows[0].warnings.some((w) => /se usará 0/i.test(w))).toBe(false)
  })

  it("fila de tipo Padre se importa sin costo, nunca con costo cero", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, tipo: "Padre", costo: "" })])
    expect(rows[0].cost).toBeNull()
  })

  // productos-costo-nullable (ronda 1 de revisión, finding nit): la celda de
  // costo de una fila Padre se IGNORA (D10 — el costo de cada variante es el
  // que cuenta), pero eso no debe silenciar el aviso de una columna mal
  // mapeada. Antes de este fix la guarda `rowType !== "Padre"` saltaba todo
  // el bloque — ni el warning de "costo ilegible" ni el de ambigüedad de
  // miles se emitían para un Padre, aunque el resultado final (cost null)
  // ya fuera correcto.
  it("Padre con costo ilegible: el resultado sigue siendo null, pero el warning se emite igual", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, tipo: "Padre", costo: "abc" })])
    expect(rows[0].cost).toBeNull()
    expect(rows[0].warnings.some((w) => /se dejará sin costo/i.test(w))).toBe(true)
  })

  it("Padre con costo ambiguo (miles con punto): avisa la ambigüedad aunque el valor se descarte", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, tipo: "Padre", costo: "1.500" })])
    expect(rows[0].cost).toBeNull()
    expect(rows[0].warnings.some((w) => /ambiguo/i.test(w))).toBe(true)
  })
})
