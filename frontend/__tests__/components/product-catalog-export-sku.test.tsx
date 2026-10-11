/**
 * export-stock-productos-sku — el CSV que baja /productos con «Exportar»
 * (el que el usuario abre en Excel) no traía la columna SKU, aunque el
 * catálogo ya muestra y busca por `sku`. «Código» es el código de barras: no
 * es el SKU y no puede reemplazarlo.
 *
 * Contrato: una columna «SKU» justo después de «Nombre», para el producto
 * padre, para cada variante (con su SKU PROPIO, no el del padre) y para el
 * producto suelto; el producto sin SKU deja la celda vacía. «Código» conserva
 * su encabezado y su valor (barcode).
 *
 * Se usa el `exportToCSV` real y se lee el Blob que se descarga: lo que se
 * asserta es lo que Excel va a abrir, no un argumento intermedio.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ unitsById: new Map() }) }))
vi.mock("@/lib/format-unit", () => ({ formatStock: (n: number) => `${n}` }))
vi.mock("@/lib/unit-utils", () => ({ resolveUnit: () => null }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), warning: vi.fn(), info: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/products/product-import-dialog", () => ({ ProductImportDialog: () => null }))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false }),
}))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({ ProductCategorySelect: () => null }))

const { ProductCatalog } = await import("@/components/products/product-catalog")

const padre: Product = {
  id: "padre", name: "Zapatillas Nike", category: "Ropa", sku: "ZAP",
  cost: 0, price: 100, margin: 0, stock: 0, minStock: 0, isVariant: false, stockControlType: "variant_only",
  barcode: "7790000000001",
}
const variante41: Product = {
  id: "v41", name: "Zapatillas Nike 41", category: "Ropa", sku: "ZAP-41",
  cost: 50, price: 100, margin: 50, stock: 3, minStock: 1, isVariant: true, parentId: "padre",
  stockControlType: "tracked", barcode: "7790000000041",
}
const variante42SinSku: Product = {
  id: "v42", name: "Zapatillas Nike 42", category: "Ropa",
  cost: 50, price: 100, margin: 50, stock: 2, minStock: 1, isVariant: true, parentId: "padre",
  stockControlType: "tracked",
}
const aceite: Product = {
  id: "aceite", name: "Aceite de oliva", category: "Almacén", sku: "ACE-500",
  cost: 10, price: 20, margin: 50, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
  barcode: "7791234567890",
}
const yerbaSinSku: Product = {
  id: "yerba", name: "Yerba mate", category: "Almacén",
  cost: 10, price: 20, margin: 50, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
}

/** Click en «Exportar» y devuelve el CSV descargado, ya partido en celdas. */
async function exportedTable(products: Product[]): Promise<string[][]> {
  let captured: Blob | null = null
  vi.spyOn(URL, "createObjectURL").mockImplementation((blob) => {
    captured = blob as Blob
    return "blob:test"
  })
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined)

  render(
    <ProductCatalog
      products={products}
      onAdd={vi.fn()}
      onAddVariant={vi.fn()}
      onEdit={vi.fn()}
      onDelete={vi.fn()}
      isAtLimit={false}
    />,
  )
  fireEvent.click(screen.getByRole("button", { name: /exportar/i }))
  expect(captured).not.toBeNull()

  const text = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error)
    reader.readAsText(captured as unknown as Blob)
  })
  return text
    .replace(/^\uFEFF/, "")
    .split("\n")
    .map((line) => line.split(";").map((cell) => cell.replace(/^"|"$/g, "")))
}

function rowOf(table: string[][], nombre: string): Record<string, string> {
  const [header, ...rows] = table
  const row = rows.find((r) => r[header.indexOf("Nombre")] === nombre)
  if (!row) throw new Error(`No hay fila para "${nombre}" en el CSV`)
  return Object.fromEntries(header.map((h, i) => [h, row[i]]))
}

beforeEach(() => {
  vi.restoreAllMocks()
})
afterEach(() => {
  vi.restoreAllMocks()
})

describe("/productos — el CSV exportado lleva el SKU", () => {
  it("encabezado: «SKU» va justo después de «Nombre» y «Código» se conserva", async () => {
    const table = await exportedTable([aceite])
    const header = table[0]
    expect(header).toContain("SKU")
    expect(header.indexOf("SKU")).toBe(header.indexOf("Nombre") + 1)
    expect(header).toContain("Código")
  })

  it("un producto suelto con SKU lo lleva, y «Código» sigue siendo su código de barras", async () => {
    const fila = rowOf(await exportedTable([aceite, yerbaSinSku]), "Aceite de oliva")
    expect(fila["SKU"]).toBe("ACE-500")
    expect(fila["Código"]).toBe("7791234567890")
  })

  it("un producto sin SKU deja la celda vacía (no «undefined», no «null»)", async () => {
    const fila = rowOf(await exportedTable([aceite, yerbaSinSku]), "Yerba mate")
    expect(fila["SKU"]).toBe("")
  })

  it("el padre, cada variante y la variante sin SKU: cada fila lleva el suyo, no el del padre", async () => {
    const table = await exportedTable([padre, variante41, variante42SinSku, aceite])
    const fPadre = rowOf(table, "Zapatillas Nike")
    const f41 = rowOf(table, "Zapatillas Nike 41")
    const f42 = rowOf(table, "Zapatillas Nike 42")

    expect(fPadre["Tipo"]).toBe("Padre")
    expect(fPadre["SKU"]).toBe("ZAP")
    expect(f41["Tipo"]).toBe("Variante")
    expect(f41["SKU"]).toBe("ZAP-41")
    expect(f41["Código"]).toBe("7790000000041")
    // La variante sin SKU propio NO hereda el del padre.
    expect(f42["SKU"]).toBe("")
  })
})
