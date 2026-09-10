/**
 * Accesibilidad — importador-productos-fastapi (task 9.8). Molde:
 * `__tests__/a11y/gastos.a11y.test.tsx`.
 *
 * Cubre lo que el task pide explícitamente:
 *   - el estado de carga de la simulación de servidor se anuncia
 *     (`role="status"`, `aria-live="polite"`) — un lector de pantalla tiene
 *     que enterarse de que el servidor está validando, no sólo verlo;
 *   - la tabla de revisión es navegable: cada fila expone su nombre, su
 *     línea y sus mensajes como texto real, alcanzable sin depender del
 *     color de un ícono;
 *   - el motivo por el que el botón de confirmar está deshabilitado queda
 *     ASOCIADO al botón vía `aria-describedby` (mismo hallazgo que la
 *     auditoría de `gastos-forma-pago`: un botón deshabilitado sin motivo
 *     atado no le dice nada a quien no ve el texto de al lado).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { RawImportRow } from "@/lib/import/types"

let parsedRows: RawImportRow[] = []

vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false }),
}))
vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn(async () => ({ ok: true, rows: parsedRows })),
}))
const mutateAsyncMock = vi.fn(async () => ({
  committed: false, importId: null, inserted: 0, updated: 0,
  errors: [] as Array<{ row: number | null; message: string }>,
  newCategories: [], replayed: false, dryRun: true,
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
  const { fireEvent } = await import("@testing-library/react")
  fireEvent.change(input, { target: { files: [file] } })
  await screen.findByText(/filas ·/i)
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("ProductImportDialog — accesibilidad (task 9.8)", () => {
  it("el estado de carga de la simulación se anuncia con role=status", async () => {
    parsedRows = [raw({ lineNumber: 2, nombre: "Producto válido" })]
    await openWithFile()

    // Mientras la promesa de mutateAsync no resolvió, el badge de carga
    // tiene que estar anunciado como región de estado.
    expect(screen.getByRole("status")).toHaveTextContent(/validando con el servidor/i)

    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())
  })

  it("la fila de revisión es navegable por texto — nombre, línea y motivo del error, no sólo color", async () => {
    parsedRows = [
      raw({ lineNumber: 2, nombre: "" }), // Nombre requerido → error de CLIENTE
      raw({ lineNumber: 3, nombre: "Remera" }),
    ]
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())

    expect(screen.getByText(/sin nombre/i)).toBeInTheDocument()
    expect(screen.getByText(/nombre requerido/i)).toBeInTheDocument()
    expect(screen.getByText("L2")).toBeInTheDocument()
    expect(screen.getByText("Remera")).toBeInTheDocument()
    expect(screen.getByText("L3")).toBeInTheDocument()
  })

  it("el botón de confirmar deshabilitado queda ASOCIADO a su motivo vía aria-describedby", async () => {
    // Única fila, con error de CLIENTE (nombre vacío) — apiRows queda vacío
    // y la simulación de servidor nunca se dispara (nada válido que mandar).
    parsedRows = [raw({ lineNumber: 2, nombre: "" })]
    await openWithFile()

    const button = await screen.findByRole("button", { name: /importar 0 filas/i })
    expect(button).toBeDisabled()

    const describedById = button.getAttribute("aria-describedby")
    expect(describedById).toBeTruthy()
    const reason = document.getElementById(describedById as string)
    expect(reason).not.toBeNull()
    expect(reason).toHaveTextContent(/fila con error/i)
    expect(reason).toHaveTextContent(/todo o nada/i)
  })
})
