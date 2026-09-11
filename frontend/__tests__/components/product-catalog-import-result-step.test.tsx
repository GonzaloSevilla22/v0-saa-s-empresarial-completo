/**
 * ProductCatalog — el paso 3 (resultado del lote) de ProductImportDialog
 * queda VISIBLE tras confirmar (revisión importador-productos-fastapi,
 * ronda 2, finding major #2).
 *
 * El único montaje real de `ProductImportDialog` (en `ProductCatalog`)
 * pasaba un `onComplete` que CERRABA el diálogo (`setImportDialogOpen
 * (false)`), y `ProductImportDialog.handleImport` llama a `setStep(3)`
 * seguido INMEDIATAMENTE de `onComplete()` — el diálogo se desmontaba
 * (`open` pasa a `false`) antes de que el paso 3 pintara un solo frame. El
 * change agrega la UI del paso 3 y una spec normativa que lo declara
 * obligatorio; sin este test nada lo ejercitaba (todos los tests de
 * `ProductImportDialog` en aislamiento pasan `onComplete={vi.fn()}`, un
 * no-op que nunca cierra nada).
 *
 * Este test monta `ProductCatalog` con el cableado REAL del padre (mismo
 * patrón que `product-catalog-search-collapse.test.tsx`) para ejercitar el
 * bug tal como ocurría en producción.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product, ProductImportPlanVerdict } from "@/lib/types"
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

// ─── Mocks (mismo set que product-catalog-search-collapse.test.tsx) ──────────
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false, createProductCategory: vi.fn() }),
}))

const mutateAsyncMock = vi.fn()
vi.mock("@/hooks/data/use-products", () => ({
  useImportProducts: () => ({
    importMutation: { mutateAsync: mutateAsyncMock },
    invalidateImportData: vi.fn(),
  }),
}))
vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn(async () => ({
    ok: true,
    rows: [
      {
        tipo: "Producto", nombre: "Producto nuevo", sku: "", sku_padre: "", producto_padre: "",
        precio: "10", costo: "5", categoria: "", stock: "0", stock_minimo: "0", codigo: "", attributes: {},
        lineNumber: 2,
      } satisfies RawImportRow,
    ],
  })),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true, role: "owner", isLoading: false }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ unitsById: new Map() }),
}))
vi.mock("@/lib/format", () => ({ formatMoney: (n: number) => `$${n}` }))
vi.mock("@/lib/format-unit", () => ({ formatStock: (n: number) => `${n}` }))
vi.mock("@/lib/unit-utils", () => ({ resolveUnit: () => null }))
// exportToCSV mockeado (sólo dispara una descarga de archivo, sin sentido
// en jsdom); parseAmount/parseQuantity/amountAmbiguityWarning REALES —
// lib/import/validator.ts los usa para normalizar precio/costo/stock.
vi.mock("@/lib/excel", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/excel")>()),
  exportToCSV: vi.fn(),
}))
const toastErrorMock = vi.fn()
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: toastErrorMock, info: vi.fn() } }))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: { id: "u", email: "e@e.com" },
    profile: { plan: "gratis", billing_plan: "gratis" },
    loading: false,
  }),
  AuthProvider: ({ children }: { children: React.ReactNode }) => children,
}))

const product: Product = {
  id: "p-1", name: "Producto existente", category: "Ropa",
  cost: 100, price: 200, margin: 50, stock: 5, minStock: 1,
  isVariant: false, stockControlType: "tracked",
}

// Import a nivel de módulo — mismo motivo que product-catalog-search-collapse
// (los vi.mock de arriba ya están hoisted; un import dinámico dentro del
// primer test puede exceder el testTimeout bajo contención).
const { ProductCatalog } = await import("@/components/products/product-catalog")

describe("ProductCatalog — paso 3 del importador queda visible tras confirmar", () => {
  // `mutateAsyncMock` es un mock de módulo compartido entre TODOS los `it()`
  // de este archivo (no hay `clearMocks`/`resetMocks` en vitest.config.ts):
  // sin este reset, la 2ª prueba en adelante encontraría la cola de
  // `mockResolvedValueOnce` de la prueba anterior ya consumida y el conteo
  // de llamadas acumulado rompería los `toHaveBeenCalledTimes`.
  beforeEach(() => {
    mutateAsyncMock.mockReset()
  })

  it("no cierra el diálogo al terminar el lote — el resultado se ve", async () => {
    mutateAsyncMock
      // Simulación (dryRun: true) al entrar al paso 2.
      .mockResolvedValueOnce({
        committed: true, importId: null, inserted: 1, updated: 0,
        errors: [], newCategories: [],
        plan: { plan: "gratis", limit: 100, before: 1, after: 2, added: 1, exceeded: false },
        replayed: false, dryRun: true,
      })
      // Confirmación real (dryRun: false).
      .mockResolvedValueOnce({
        committed: true, importId: "imp-1", inserted: 1, updated: 0,
        errors: [], newCategories: [],
        plan: { plan: "gratis", limit: 100, before: 1, after: 2, added: 1, exceeded: false },
        replayed: false, dryRun: false,
      })

    render(
      <ProductCatalog
        products={[product]}
        onAdd={vi.fn()}
        onEdit={vi.fn()}
        onAddVariant={vi.fn()}
        onDelete={async () => {}}
        isAtLimit={false}
        onImportComplete={vi.fn()}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: /importar csv/i }))

    const input = document.querySelector('input[type="file"]') as HTMLInputElement
    const file = new File(["Nombre\nProducto nuevo"], "productos.csv", { type: "text/csv" })
    fireEvent.change(input, { target: { files: [file] } })

    // Paso 2: espera el veredicto de la simulación.
    await screen.findByText(/filas ·/i)
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(1))
    const confirmButton = await screen.findByRole("button", { name: /importar 1 fila/i })
    expect(confirmButton).toBeEnabled()

    fireEvent.click(confirmButton)

    // La confirmación real dispara la SEGUNDA llamada.
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(2))

    // El diálogo SIGUE ABIERTO (el bug lo cerraba acá) y el paso 3 se ve.
    expect(await screen.findByText(/1 producto importado correctamente/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /cerrar/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /importar otro archivo/i })).toBeInTheDocument()
  })

  // Revisión adversarial, ronda 2 (finding minor #6): la nota "Te quedan N
  // productos en tu plan" del paso 3 (`ProductImportDialog`, bloque
  // `totalErr === 0 && planVerdict?.limit != null`) pluraliza con la MISMA
  // expresión que ya cubre visualmente CHANGES.md («Te quedan 3
  // productos…» / «Te quedan 1 producto…», medido en la pasada visual de
  // `importador-gate-plan`) — hasta este change ningún test automatizado la
  // ejercitaba en ninguno de sus tres casos (singular, plural, sin tope).
  async function importOneProductWithPlan(plan: ProductImportPlanVerdict | null) {
    const confirmResult = {
      committed: true, importId: "imp-1", inserted: 1, updated: 0,
      errors: [], newCategories: [], plan, replayed: false, dryRun: false,
    }
    mutateAsyncMock
      // Simulación (dryRun: true) al entrar al paso 2 — mismo veredicto que
      // el de la confirmación: un replay no recomputa nada distinto acá.
      .mockResolvedValueOnce({ ...confirmResult, importId: null, dryRun: true })
      .mockResolvedValueOnce(confirmResult)

    render(
      <ProductCatalog
        products={[product]}
        onAdd={vi.fn()}
        onEdit={vi.fn()}
        onAddVariant={vi.fn()}
        onDelete={async () => {}}
        isAtLimit={false}
        onImportComplete={vi.fn()}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: /importar csv/i }))

    const input = document.querySelector('input[type="file"]') as HTMLInputElement
    const file = new File(["Nombre\nProducto nuevo"], "productos.csv", { type: "text/csv" })
    fireEvent.change(input, { target: { files: [file] } })

    await screen.findByText(/filas ·/i)
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(1))
    const confirmButton = await screen.findByRole("button", { name: /importar 1 fila/i })
    fireEvent.click(confirmButton)
    await waitFor(() => expect(mutateAsyncMock).toHaveBeenCalledTimes(2))

    // Ancla del paso 3 — sin esto, un `findByText` de la nota podría
    // resolver antes de que React termine de pintar el paso.
    expect(await screen.findByText(/1 producto importado correctamente/i)).toBeInTheDocument()
  }

  it("nota del paso 3 en singular cuando limit - after === 1", async () => {
    await importOneProductWithPlan({ plan: "gratis", limit: 100, before: 98, after: 99, added: 1, exceeded: false })

    expect(await screen.findByText("Te quedan 1 producto en tu plan gratis.")).toBeInTheDocument()
  })

  it("nota del paso 3 en plural cuando limit - after !== 1", async () => {
    await importOneProductWithPlan({ plan: "gratis", limit: 100, before: 96, after: 97, added: 1, exceeded: false })

    expect(await screen.findByText("Te quedan 3 productos en tu plan gratis.")).toBeInTheDocument()
  })

  it("no renderiza la nota cuando plan es null (ventana de deploy sin veredicto)", async () => {
    await importOneProductWithPlan(null)

    expect(screen.queryByText(/Te quedan/i)).not.toBeInTheDocument()
  })
})
