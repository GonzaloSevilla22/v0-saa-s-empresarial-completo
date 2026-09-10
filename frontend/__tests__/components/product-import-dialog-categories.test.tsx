/**
 * productos-categorias-sku — ProductImportDialog (tasks 16.1 RED, 16.5
 * TRIANGULATE) + template desde el catálogo (D10).
 *
 *  - el paso 2 lista las categorías a crear (nombre + filas) ANTES de
 *    confirmar; sin categorías nuevas no hay bloque;
 *  - superar el tope muestra el error explicativo y bloquea el botón;
 *  - el template se genera con las categorías reales de la cuenta (las 7
 *    legacy de respaldo si el catálogo está vacío) y el SKU del Padre no
 *    lleva espacio a la izquierda;
 *  - el panel "Columnas del CSV" dice la verdad sobre Categoría y SKU.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { RawImportRow } from "@/lib/import/types"
import type { ProductCategory } from "@/lib/types"
import { buildTemplateCsv } from "@/lib/import/template"

// importador-productos-fastapi (fix de CI, misma causa que #542): el diálogo
// hashea el archivo con `hashFileSHA256` (`lib/bank-statement-parser.ts`, vía
// `crypto.subtle.digest` sobre `File.arrayBuffer()`) antes de simular. En el
// jsdom de CI (Node 20) ese `arrayBuffer()` no es aceptado por
// `SubtleCrypto.digest` (`ERR_INVALID_ARG_TYPE`), la simulación nunca resuelve
// y el paso 2 jamás aparece — localmente (Node 24) sí pasa. Mock idéntico al
// de `gastos.a11y.test.tsx`; el hash real no es objeto de estos tests.
vi.mock("@/lib/bank-statement-parser", () => ({
  // Determinístico por archivo (nombre + tamaño): dos archivos distintos deben
  // dar hashes distintos — el test de cambio de archivo lo asserta.
  hashFileSHA256: vi.fn(async (file: File) => `hash-${file.name}-${file.size}`),
}))

let parsedRows: RawImportRow[] = []
let categoriesMock = [
  { id: "cat-ropa",  accountId: "a", name: "Ropa",  isActive: true,  sortOrder: 2, createdAt: "" },
  { id: "cat-otros", accountId: "a", name: "Otros", isActive: true,  sortOrder: 7, createdAt: "" },
]

// Veredicto de la SIMULACIÓN de servidor (dry_run) que dispara el paso 2 al
// entrar (D7) — por default, sin errores ni categorías propias (el aviso de
// categorías nuevas del cliente sigue mostrándose hasta que este veredicto
// llegue; los tests que lo necesitan lo esperan explícitamente con waitFor).
let dryRunResult = {
  committed: false,
  importId: null,
  inserted: 0,
  updated: 0,
  errors: [] as Array<{ row: number | null; message: string }>,
  newCategories: [] as Array<{ name: string; rows: number }>,
  replayed: false,
  dryRun: true,
}
const mutateAsyncMock = vi.fn(async () => dryRunResult)

vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: categoriesMock, isLoading: false }),
}))
vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn(async () => ({ ok: true, rows: parsedRows })),
}))
vi.mock("@/hooks/data/use-products", () => ({
  useImportProducts: () => ({
    importMutation: { mutateAsync: mutateAsyncMock },
    invalidateImportData: vi.fn(),
  }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))

const { ProductImportDialog } = await import("@/components/products/product-import-dialog")

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "", attributes: {},
    ...over,
  }
}

async function openWithFile() {
  render(<ProductImportDialog open onOpenChange={vi.fn()} onComplete={vi.fn()} />)
  const input = document.querySelector('input[type="file"]') as HTMLInputElement
  const file = new File(["Nombre\nX"], "productos.csv", { type: "text/csv" })
  fireEvent.change(input, { target: { files: [file] } })
  await screen.findByText(/filas ·/i)
}

describe("buildTemplateCsv (D10)", () => {
  it("usa las categorías reales de la cuenta y no deja espacio antes del SKU del Padre", () => {
    const catalog: ProductCategory[] = [
      { id: "1", accountId: "a", name: "Bebidas", isActive: true, sortOrder: 1, createdAt: "" },
      { id: "2", accountId: "a", name: "Limpieza", isActive: true, sortOrder: 2, createdAt: "" },
      { id: "3", accountId: "a", name: "Vieja", isActive: false, sortOrder: 3, createdAt: "" },
    ]
    const csv = buildTemplateCsv(catalog)
    const lines = csv.split("\n")
    expect(lines[0]).toBe("Tipo;Nombre;Precio;Costo;Categoría;Stock;Stock mínimo;Código;SKU")
    expect(csv).toMatch(/;Bebidas;/)
    expect(csv).toMatch(/;Limpieza;/)
    expect(csv).not.toMatch(/Vieja/)
    expect(csv).not.toMatch(/; ZAP-NIKE/)
    expect(csv).toMatch(/;;;;;;;ZAP-NIKE/)
  })

  it("con el catálogo vacío usa las legacy como respaldo", () => {
    const csv = buildTemplateCsv([])
    expect(csv).toMatch(/;Ropa;/)
    expect(csv).toMatch(/;Alimentos;/)
  })
})

describe("ProductImportDialog — categorías nuevas en el paso de revisión", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    categoriesMock = [
      { id: "cat-ropa",  accountId: "a", name: "Ropa",  isActive: true, sortOrder: 2, createdAt: "" },
      { id: "cat-otros", accountId: "a", name: "Otros", isActive: true, sortOrder: 7, createdAt: "" },
    ]
    dryRunResult = {
      committed: false, importId: null, inserted: 0, updated: 0,
      errors: [], newCategories: [], replayed: false, dryRun: true,
    }
  })

  it("el paso 1 declara que la categoría se crea y que el SKU coincidente actualiza", () => {
    render(<ProductImportDialog open onOpenChange={vi.fn()} onComplete={vi.fn()} />)
    expect(screen.getByText(/se crea si no existe/i)).toBeInTheDocument()
    expect(screen.getByText(/actualiza/i)).toBeInTheDocument()
  })

  it("lista las categorías a crear con su conteo antes de confirmar", async () => {
    // D7: el anuncio final proviene del VEREDICTO DEL SERVIDOR (la
    // simulación) — se configura acá para que coincida con la conjetura del
    // cliente, y el test espera a que la simulación asíncrona resuelva.
    dryRunResult = { ...dryRunResult, newCategories: [{ name: "Ferretería", rows: 2 }] }
    parsedRows = [
      raw({ lineNumber: 2, nombre: "Martillo", categoria: "Ferretería" }),
      raw({ lineNumber: 3, nombre: "Tenaza", categoria: "ferretería" }),
      raw({ lineNumber: 4, nombre: "Remera", categoria: "ropa" }),
    ]
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())

    const block = await screen.findByRole("region", { name: /categorías nuevas/i })
    expect(block).toHaveTextContent(/1 categoría nueva/i)
    expect(block).toHaveTextContent(/Ferretería/)
    expect(block).toHaveTextContent(/2 filas/)
    expect(block).not.toHaveTextContent(/Ropa/)
    expect(screen.getByRole("button", { name: /importar 3 filas/i })).toBeEnabled()
  })

  it("sin categorías nuevas no hay bloque de anuncio", async () => {
    parsedRows = [raw({ lineNumber: 2, nombre: "Remera", categoria: "Ropa" })]
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())
    expect(screen.queryByRole("region", { name: /categorías nuevas/i })).not.toBeInTheDocument()
  })

  it("superar el tope bloquea la importación con un error explicativo", async () => {
    parsedRows = Array.from({ length: 51 }, (_, i) => raw({ lineNumber: i + 2, nombre: `P${i}`, categoria: `Cat ${i}` }))
    await openWithFile()

    const alert = screen.getByRole("alert")
    expect(alert).toHaveTextContent(/51/)
    expect(alert).toHaveTextContent(/50/)
    expect(alert).toHaveTextContent(/mape/i)
    expect(screen.getByRole("button", { name: /importar/i })).toBeDisabled()
  })
})
