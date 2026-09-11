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

vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false }),
}))
vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn(async () => ({ ok: true, rows: parsedRows })),
}))
const mutateAsyncMock = vi.fn(async () => ({
  committed: false, importId: null, inserted: 0, updated: 0,
  errors: [] as Array<{ row: number | null; message: string }>,
  newCategories: [],
  // importador-gate-plan (OQ-1, sign-off PO 2026-09-11): siempre presente.
  plan: { plan: "gratis", limit: 100, before: 0, after: 0, added: 0, exceeded: false },
  replayed: false, dryRun: true,
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
    // La mutación queda PENDIENTE a propósito: el estado de carga tiene que
    // seguir anunciado hasta que el servidor responda. Con el mock resolviendo
    // de inmediato había una carrera (bajo carga el badge ya no estaba al
    // assertear) — fallo real en CI del PR #548.
    mutateAsyncMock.mockImplementationOnce(() => new Promise(() => {}))
    await openWithFile()

    // Mientras la promesa de mutateAsync no resolvió, el badge de carga
    // tiene que estar anunciado como región de estado.
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(/validando con el servidor/i),
    )

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

  it("el bloqueo por límite de plan también asocia el botón deshabilitado a su motivo vía aria-describedby (OQ-1, sign-off PO 2026-09-11)", async () => {
    parsedRows = [raw({ lineNumber: 2, nombre: "Producto nuevo" })]
    mutateAsyncMock.mockResolvedValueOnce({
      committed: false, importId: null, inserted: 0, updated: 0,
      errors: [],
      newCategories: [],
      plan: { plan: "gratis", limit: 100, before: 100, after: 101, added: 1, exceeded: true },
      replayed: false, dryRun: true,
    })
    await openWithFile()
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalled())

    const button = await screen.findByRole("button", { name: /importar/i })
    expect(button).toBeDisabled()

    const describedById = button.getAttribute("aria-describedby")
    expect(describedById).toBe("product-import-plan-summary")
    const reason = document.getElementById(describedById as string)
    expect(reason).not.toBeNull()
    expect(reason).toHaveTextContent(/límite de productos/i)
    expect(reason).toHaveTextContent(/gratis/i)

    // El CTA "Ver planes" está adentro del mismo bloque de motivo.
    expect(reason).toHaveTextContent(/ver planes/i)
  })
})
