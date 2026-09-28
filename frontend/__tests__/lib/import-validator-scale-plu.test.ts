/**
 * balanza-etiquetas-pos (task 10.2 RED→GREEN) — columna "Código balanza"
 * (D14): entero 1-999.999; celda vacía = ausente; duplicados en el archivo
 * son error de fila; una fila "Padre" con PLU es error de fila; y el aviso
 * no bloqueante cuando la columna "Código" decodifica como etiqueta de
 * balanza válida contra la configuración de la cuenta.
 */

import { describe, it, expect } from "vitest"
import { validateImportRows } from "@/lib/import/validator"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"
import type { RawImportRow } from "@/lib/import/types"

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "",
    codigo_balanza: "", attributes: {},
    ...over,
  }
}

describe("validateImportRows — Código balanza (balanza-etiquetas-pos D14)", () => {
  it("celda vacía → scalePlu null (ausente)", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2 })])
    expect(rows[0].scalePlu).toBeNull()
    expect(rows[0].errors).toHaveLength(0)
  })

  it("un entero válido en rango se asigna", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, codigo_balanza: "509" })])
    expect(rows[0].scalePlu).toBe(509)
    expect(rows[0].errors).toHaveLength(0)
  })

  it.each(["0", "1000000", "abc", "1.5"])("fuera de rango o no entero (%s) → error de fila", (value) => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, codigo_balanza: value })])
    expect(rows[0].scalePlu).toBeNull()
    expect(rows[0].errors.some((e) => /código balanza inválido/i.test(e))).toBe(true)
  })

  it("una fila Padre con código de balanza es error de fila", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, tipo: "Padre", codigo_balanza: "509" })])
    expect(rows[0].scalePlu).toBeNull()
    expect(rows[0].errors.some((e) => /se asigna a cada variante/i.test(e))).toBe(true)
  })

  it("dos filas con el mismo código de balanza: error de fila en las dos", () => {
    const { rows } = validateImportRows([
      raw({ lineNumber: 2, nombre: "Tomate", codigo_balanza: "509" }),
      raw({ lineNumber: 3, nombre: "Zapallo", codigo_balanza: "509" }),
    ])
    expect(rows[0].errors.some((e) => /repetido en el archivo/i.test(e))).toBe(true)
    expect(rows[1].errors.some((e) => /repetido en el archivo/i.test(e))).toBe(true)
  })

  it("dos códigos de balanza DISTINTOS no generan error", () => {
    const { rows } = validateImportRows([
      raw({ lineNumber: 2, nombre: "Tomate", codigo_balanza: "509" }),
      raw({ lineNumber: 3, nombre: "Zapallo", codigo_balanza: "300" }),
    ])
    expect(rows[0].errors).toHaveLength(0)
    expect(rows[1].errors).toHaveLength(0)
  })

  it("sin settings de balanza: no avisa aunque el Código sea una etiqueta válida", () => {
    const { rows } = validateImportRows([raw({ lineNumber: 2, codigo: "2002610013638" })])
    expect(rows[0].warnings.some((w) => /etiqueta de balanza/i.test(w))).toBe(false)
  })

  it("con settings habilitados: avisa si el Código decodifica como etiqueta de balanza", () => {
    const settings = { ...FACTORY_SCALE_SETTINGS, enabled: true }
    const { rows } = validateImportRows([raw({ lineNumber: 2, codigo: "2002610013638" })], [], settings)
    expect(rows[0].warnings.some((w) => /etiqueta de balanza/i.test(w))).toBe(true)
    // No bloquea: sigue siendo válido pese al aviso.
    expect(rows[0].errors).toHaveLength(0)
  })

  it("con settings habilitados: un código de barras común no genera el aviso", () => {
    const settings = { ...FACTORY_SCALE_SETTINGS, enabled: true }
    const { rows } = validateImportRows([raw({ lineNumber: 2, codigo: "7790001234567" })], [], settings)
    expect(rows[0].warnings.some((w) => /etiqueta de balanza/i.test(w))).toBe(false)
  })
})
