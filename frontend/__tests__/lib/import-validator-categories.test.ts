/**
 * productos-categorias-sku — validador del importador (tasks 15.2/15.4 RED,
 * 15.7 TRIANGULATE).
 *
 *  - una categoría desconocida YA NO se reescribe a "Otros": se marca como
 *    "a crear" y se anuncia en el resumen (nombre + filas);
 *  - una existente se resuelve case-insensitive y tolerante a espacios al
 *    nombre canónico del catálogo;
 *  - una fila con error fatal no aporta categoría a crear;
 *  - el tope (50) se detecta en el resumen;
 *  - dos filas con el mismo SKU en el archivo se advierten;
 *  - VALID_CATEGORIES no existe más (ninguna capa conserva una lista fija).
 */

import { describe, it, expect } from "vitest"
import { validateImportRows } from "@/lib/import/validator"
import * as importTypes from "@/lib/import/types"
import type { RawImportRow } from "@/lib/import/types"

const CATALOG = [
  { id: "cat-ropa",  name: "Ropa",  isActive: true },
  { id: "cat-otros", name: "Otros", isActive: true },
  { id: "cat-salud", name: "Salud", isActive: false },
]

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "", attributes: {},
    ...over,
  }
}

describe("validateImportRows — categorías contra el catálogo del tenant", () => {
  it("una categoría desconocida se marca como nueva (sin reescribir a Otros ni warning)", () => {
    const { rows, newCategories, newCategoryLimitExceeded } = validateImportRows(
      [raw({ lineNumber: 2, nombre: "Martillo", categoria: "Ferretería" })], CATALOG,
    )
    expect(rows[0].category).toBe("Ferretería")
    expect(rows[0].categoryIsNew).toBe(true)
    expect(rows[0].warnings.join(" ")).not.toMatch(/Otros/)
    expect(newCategories).toEqual([{ name: "Ferretería", rows: 1 }])
    expect(newCategoryLimitExceeded).toBe(false)
  })

  it("resuelve case-insensitive y tolerante a espacios al nombre canónico, sin crear", () => {
    const { rows, newCategories } = validateImportRows([
      raw({ lineNumber: 2, nombre: "A", categoria: "ropa" }),
      raw({ lineNumber: 3, nombre: "B", categoria: "Ropa " }),
      raw({ lineNumber: 4, nombre: "C", categoria: "  ROPA" }),
      raw({ lineNumber: 5, nombre: "D", categoria: "Ropa   de  trabajo" }),
    ], CATALOG)
    expect(rows.slice(0, 3).map((r) => r.category)).toEqual(["Ropa", "Ropa", "Ropa"])
    expect(rows.slice(0, 3).every((r) => r.categoryIsNew === false)).toBe(true)
    expect(rows[3].category).toBe("Ropa de trabajo")
    expect(rows[3].categoryIsNew).toBe(true)
    expect(newCategories).toEqual([{ name: "Ropa de trabajo", rows: 1 }])
  })

  it("una existente pero DESACTIVADA se reutiliza (no se duplica)", () => {
    const { rows, newCategories } = validateImportRows([raw({ lineNumber: 2, categoria: "salud" })], CATALOG)
    expect(rows[0].category).toBe("Salud")
    expect(rows[0].categoryIsNew).toBe(false)
    expect(newCategories).toEqual([])
  })

  it("fila sin categoría: queda vacía (el servidor imputa la default) y no crea nada", () => {
    const { rows, newCategories } = validateImportRows([raw({ lineNumber: 2, categoria: "" })], CATALOG)
    expect(rows[0].category).toBe("")
    expect(rows[0].categoryIsNew).toBe(false)
    expect(newCategories).toEqual([])
  })

  it("una fila con error fatal no aporta categoría a crear", () => {
    const { rows, newCategories } = validateImportRows([
      raw({ lineNumber: 2, nombre: "", categoria: "Fantasma" }),
      raw({ lineNumber: 3, nombre: "OK", categoria: "Ferretería" }),
      raw({ lineNumber: 4, nombre: "OK2", categoria: "ferretería " }),
    ], CATALOG)
    expect(rows[0].errors.length).toBeGreaterThan(0)
    expect(newCategories).toEqual([{ name: "Ferretería", rows: 2 }])
  })

  it("tope de categorías nuevas: 50 pasa, 51 lo excede", () => {
    const mk = (n: number) => Array.from({ length: n }, (_, i) => raw({ lineNumber: i + 2, nombre: `P${i}`, categoria: `Cat ${i}` }))
    expect(validateImportRows(mk(50), CATALOG).newCategoryLimitExceeded).toBe(false)
    const over = validateImportRows(mk(51), CATALOG)
    expect(over.newCategoryLimitExceeded).toBe(true)
    expect(over.maxNewCategories).toBe(50)
    expect(importTypes.MAX_NEW_CATEGORIES_PER_IMPORT).toBe(50)
  })

  it("sin catálogo (cuenta vacía) toda categoría informada es nueva", () => {
    const { rows, newCategories } = validateImportRows([raw({ lineNumber: 2, categoria: "Ropa" })], [])
    expect(rows[0].categoryIsNew).toBe(true)
    expect(newCategories).toEqual([{ name: "Ropa", rows: 1 }])
  })
})

describe("validateImportRows — SKU repetido dentro del archivo (task 15.4)", () => {
  it("dos filas con el mismo SKU y nombres distintos se advierten nombrando las líneas", () => {
    const { rows } = validateImportRows([
      raw({ lineNumber: 2, nombre: "Remera roja", sku: "REM-001" }),
      raw({ lineNumber: 3, nombre: "Remera azul", sku: "rem-001" }),
      raw({ lineNumber: 4, nombre: "Otra", sku: "OTR-1" }),
    ], CATALOG)
    expect(rows[0].warnings.join(" ")).toMatch(/SKU "REM-001".*(línea|L)\s*3/i)
    expect(rows[1].warnings.join(" ")).toMatch(/SKU "rem-001".*(línea|L)\s*2/i)
    expect(rows[2].warnings).toEqual([])
  })

  it("las filas sin SKU nunca se consideran repetidas entre sí", () => {
    const { rows } = validateImportRows([
      raw({ lineNumber: 2, nombre: "A" }),
      raw({ lineNumber: 3, nombre: "B" }),
    ], CATALOG)
    expect(rows.every((r) => r.warnings.length === 0)).toBe(true)
  })
})

describe("ninguna capa conserva una lista fija de categorías", () => {
  it("VALID_CATEGORIES ya no se exporta desde lib/import/types", () => {
    expect(importTypes).not.toHaveProperty("VALID_CATEGORIES")
  })
})
