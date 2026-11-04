/**
 * ProductImportDialog — aviso de que el stock de un producto que YA existe no se
 * modifica (importador-productos-stock-apertura).
 *
 * El stock del archivo es de APERTURA: el servidor lo aplica sólo a los productos que
 * el lote CREA (con su movimiento «Stock inicial (importación)»). Reimportar un SKU
 * existente actualiza sus datos pero conserva su saldo. Sin este aviso en el paso de
 * revisión, el usuario que carga un archivo con la columna Stock esperando "corregir
 * el stock" no se enteraba de que no pasó nada con él. El veredicto de la simulación
 * (`updated`) dice cuántos productos del archivo ya existen.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { RawImportRow } from "@/lib/import/types"

vi.mock("@/lib/bank-statement-parser", () => ({
  hashFileSHA256: vi.fn(async (file: File) => `hash-${file.name}-${file.size}`),
}))

let parsedRows: RawImportRow[] = []

const categoriesMock = [
  { id: "cat-otros", accountId: "a", name: "Otros", isActive: true, sortOrder: 7, createdAt: "" },
]

const mutateAsyncMock = vi.fn()

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
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: { enabled: false, layouts: [] }, isLoading: false, isError: false, error: null }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))

const { ProductImportDialog } = await import("@/components/products/product-import-dialog")

function raw(over: Partial<RawImportRow> & { lineNumber: number }): RawImportRow {
  return {
    tipo: "Producto", nombre: "Producto", sku: "", sku_padre: "", producto_padre: "",
    precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "", codigo_balanza: "", attributes: {},
    ...over,
  }
}

function verdict(over: { inserted: number; updated: number }) {
  return {
    committed: true, importId: null, errors: [], newCategories: [],
    plan: { plan: "gratis", limit: 100, before: 10, after: 10 + over.inserted, added: over.inserted, exceeded: false },
    replayed: false, dryRun: true,
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

beforeEach(() => {
  vi.clearAllMocks()
  parsedRows = [
    raw({ lineNumber: 2, nombre: "Remera", sku: "REM-1", stock: "20" }),
    raw({ lineNumber: 3, nombre: "Pantalón", sku: "PAN-1", stock: "8" }),
  ]
})

describe("ProductImportDialog — el stock de los productos que ya existen no se modifica", () => {
  it("avisa en el paso de revisión, con la cantidad de existentes y cómo corregir el stock (Importar ajuste en Stock)", async () => {
    mutateAsyncMock.mockResolvedValueOnce(verdict({ inserted: 0, updated: 2 }))
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())

    const region = await screen.findByRole("region", { name: /stock de los productos que ya existen/i })
    expect(region).toHaveTextContent(/el stock del archivo solo se carga en los productos nuevos/i)
    expect(region).toHaveTextContent(/2 productos ya existen/i)
    expect(region).toHaveTextContent(/conservan el stock que tienen/i)
    expect(region).toHaveTextContent(/Importar ajuste/)
    expect(region).toHaveTextContent(/Stock/)
  })

  it("usa el singular cuando es uno solo", async () => {
    mutateAsyncMock.mockResolvedValueOnce(verdict({ inserted: 1, updated: 1 }))
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())

    const region = await screen.findByRole("region", { name: /stock de los productos que ya existen/i })
    expect(region).toHaveTextContent(/1 producto ya existe/i)
    expect(region).toHaveTextContent(/conserva el stock que tiene/i)
  })

  it("NO aparece si el archivo sólo trae productos nuevos (updated = 0)", async () => {
    mutateAsyncMock.mockResolvedValueOnce(verdict({ inserted: 2, updated: 0 }))
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())
    await screen.findByRole("button", { name: /importar 2 filas/i })

    expect(screen.queryByRole("region", { name: /stock de los productos que ya existen/i })).not.toBeInTheDocument()
  })

  it("NO aparece si hay productos existentes pero el archivo no trae stock (celdas vacías)", async () => {
    parsedRows = [
      raw({ lineNumber: 2, nombre: "Remera", sku: "REM-1", stock: "" }),
      raw({ lineNumber: 3, nombre: "Pantalón", sku: "PAN-1", stock: "" }),
    ]
    mutateAsyncMock.mockResolvedValueOnce(verdict({ inserted: 0, updated: 2 }))
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())
    await screen.findByRole("button", { name: /importar 2 filas/i })

    expect(screen.queryByRole("region", { name: /stock de los productos que ya existen/i })).not.toBeInTheDocument()
  })

  it("el aviso no bloquea la confirmación", async () => {
    mutateAsyncMock.mockResolvedValueOnce(verdict({ inserted: 0, updated: 2 }))
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())
    await screen.findByRole("region", { name: /stock de los productos que ya existen/i })

    expect(screen.getByRole("button", { name: /importar 2 filas/i })).toBeEnabled()
  })
})

describe("ProductImportDialog — la ayuda de columnas del paso 1 explica el stock de apertura", () => {
  it("Stock: sólo se carga en productos nuevos; Precio y Stock mínimo vacíos conservan", () => {
    render(<ProductImportDialog open onOpenChange={vi.fn()} onComplete={vi.fn()} />)

    expect(screen.getByText(/solo se carga en productos nuevos/i)).toBeInTheDocument()
    expect(screen.getByText(/vacío en un producto existente = conserva el precio/i)).toBeInTheDocument()
    expect(screen.getByText(/vacío en un producto existente = conserva el mínimo/i)).toBeInTheDocument()
  })
})
