/**
 * ProductImportDialog — veredicto de servidor incompleto (revisión
 * importador-productos-fastapi, ronda 1).
 *
 * Tres huecos encontrados en `confirmDisabled`, ninguno cubierto por
 * `product-import-dialog-categories.test.tsx` (que sólo ejercita el camino
 * feliz y el tope de categorías):
 *
 *   1. Un dry run que FALLA (red, rechazo del servidor) dejaba el botón de
 *      confirmar HABILITADO sin que el usuario hubiera visto ningún
 *      veredicto — `confirmDisabled` sólo miraba errores por fila.
 *   2. Un error de servidor SIN fila asociada (`row: null`) no entraba a
 *      `serverVerdicts` (indexado por `row`) y por lo tanto no contaba en
 *      `errorCount` — se perdía en silencio y no bloqueaba nada.
 *   3. Un archivo YA importado (`replayed: true`) mostraba el mismo
 *      veredicto que uno nuevo — el usuario no se enteraba de que confirmar
 *      no iba a crear un lote nuevo.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { RawImportRow } from "@/lib/import/types"

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

beforeEach(() => {
  vi.clearAllMocks()
  parsedRows = [raw({ lineNumber: 2, nombre: "Remera" })]
})

describe("ProductImportDialog — dry run fallido bloquea la confirmación", () => {
  it("mantiene el botón deshabilitado y ofrece reintentar cuando la simulación rechaza", async () => {
    mutateAsyncMock.mockRejectedValueOnce(new Error("network down"))
    await openWithFile()

    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(1))

    expect(await screen.findByText(/no se pudo validar el archivo contra el servidor/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /importar/i })).toBeDisabled()

    // Reintentar dispara una segunda simulación — ahora exitosa.
    mutateAsyncMock.mockResolvedValueOnce({
      committed: true, importId: null, inserted: 1, updated: 0,
      errors: [], newCategories: [], replayed: false, dryRun: true,
    })
    fireEvent.click(screen.getByRole("button", { name: /reintentar/i }))

    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.getByRole("button", { name: /importar 1 fila/i })).toBeEnabled())
  })
})

describe("ProductImportDialog — error de servidor sin fila asociada", () => {
  it("bloquea la confirmación y lo muestra en un bloque general (no se descarta en silencio)", async () => {
    mutateAsyncMock.mockResolvedValueOnce({
      committed: false, importId: null, inserted: 0, updated: 0,
      errors: [{ row: null, sku: null, name: null, message: "cuota de categorías excedida" }],
      newCategories: [], replayed: false, dryRun: true,
    })
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())

    expect(await screen.findByText(/cuota de categorías excedida/i)).toBeInTheDocument()
    expect(screen.getByText(/error del servidor sin fila asociada/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /importar/i })).toBeDisabled()
  })
})

describe("ProductImportDialog — archivo ya importado (replay)", () => {
  it("avisa ANTES de confirmar y cambia el texto del botón", async () => {
    mutateAsyncMock.mockResolvedValueOnce({
      committed: true, importId: "existing-import-id", inserted: 3, updated: 0,
      errors: [], newCategories: [], replayed: true, dryRun: true,
    })
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())

    expect(await screen.findByText(/ya se había importado antes/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /confirmar \(ya importado\)/i })).toBeEnabled()
  })
})
