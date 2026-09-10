/**
 * ProductImportDialog — cambiar de archivo desde el paso 2 (revisión
 * importador-productos-fastapi, ronda 2, finding major #1).
 *
 * Elegir un SEGUNDO archivo desde "Cambiar archivo" en el paso 2 disparaba
 * la simulación de servidor con las filas, el hash y la clave de
 * idempotencia del archivo ANTERIOR: `handleFile` reseteaba el ref
 * síncrono pero dejaba `prepared`/`fileHash`/`idempotencyKey` viejos hasta
 * que el `await prepareProductImport(...)` resolvía, y React corría el
 * efecto de simulación automática ANTES de esa resolución. El usuario
 * confirmaba un lote cuyo veredicto de servidor nunca se calculó para el
 * archivo que en verdad iba a importar.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { RawImportRow } from "@/lib/import/types"

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

const rowsByFile: Record<string, RawImportRow[]> = {}

const categoriesMock = [
  { id: "cat-otros", accountId: "a", name: "Otros", isActive: true, sortOrder: 7, createdAt: "" },
]

const mutateAsyncMock = vi.fn()

vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: categoriesMock, isLoading: false }),
}))
// El mock devuelve filas DISTINTAS según el nombre del archivo elegido —
// así la prueba puede distinguir "se simuló el archivo viejo" de "se
// simuló el archivo nuevo" sin espiar el parser real.
vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn(async (file: File) => ({ ok: true, rows: rowsByFile[file.name] ?? [] })),
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

beforeEach(() => {
  vi.clearAllMocks()
  mutateAsyncMock.mockResolvedValue({
    committed: true, importId: null, inserted: 1, updated: 0,
    errors: [], newCategories: [], replayed: false, dryRun: true,
  })
  rowsByFile["uno.csv"] = [raw({ lineNumber: 2, nombre: "ARCHIVO-UNO" })]
  rowsByFile["dos.csv"] = [raw({ lineNumber: 2, nombre: "ARCHIVO-DOS" })]
})

describe("ProductImportDialog — cambiar de archivo desde el paso 2", () => {
  it("la simulación automática del SEGUNDO archivo viaja con SUS filas y SU nombre, no los del primero", async () => {
    render(<ProductImportDialog open onOpenChange={vi.fn()} onComplete={vi.fn()} />)

    const inputA = document.querySelector('input[type="file"]') as HTMLInputElement

    const fileA = new File(["Nombre\nARCHIVO-UNO"], "uno.csv", { type: "text/csv" })
    fireEvent.change(inputA, { target: { files: [fileA] } })

    await screen.findByText(/ARCHIVO-UNO/i)
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(1))
    expect(mutateAsyncMock.mock.calls[0][0].fileName).toBe("uno.csv")
    expect(mutateAsyncMock.mock.calls[0][0].rows[0].name).toBe("ARCHIVO-UNO")

    fireEvent.click(screen.getByRole("button", { name: /cambiar archivo/i }))

    // El paso 1 (con el `<input type="file">`) se REMONTA al volver del
    // paso 2 — es una rama JSX distinta, no el mismo nodo del DOM — así
    // que hay que volver a resolver el input después del click.
    const inputB = document.querySelector('input[type="file"]') as HTMLInputElement
    const fileB = new File(["Nombre\nARCHIVO-DOS"], "dos.csv", { type: "text/csv" })
    fireEvent.change(inputB, { target: { files: [fileB] } })

    // El paso 2 vuelve a mostrar las filas del archivo NUEVO.
    await screen.findByText(/ARCHIVO-DOS/i)
    // Y una SEGUNDA simulación se dispara — la del archivo B.
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(2))

    const secondCallArgs = mutateAsyncMock.mock.calls[1][0]
    expect(secondCallArgs.fileName).toBe("dos.csv")
    expect(secondCallArgs.rows).toHaveLength(1)
    expect(secondCallArgs.rows[0].name).toBe("ARCHIVO-DOS")

    // Sanity: la clave de idempotencia del segundo lote es DISTINTA de la
    // del primero (una por archivo elegido, D8/task 8.7) y el hash del
    // archivo también cambió — ninguno de los dos siguió siendo el de A.
    const firstCallArgs = mutateAsyncMock.mock.calls[0][0]
    expect(secondCallArgs.idempotencyKey).not.toBe(firstCallArgs.idempotencyKey)
    expect(secondCallArgs.fileHash).not.toBe(firstCallArgs.fileHash)
  })
})
