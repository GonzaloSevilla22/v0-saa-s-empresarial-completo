/**
 * export-stock-productos-sku — el CSV que baja /stock con «Exportar» (la tabla
 * de existencias) no traía el SKU: Producto, Categoría, Stock actual y Stock
 * mínimo, sin forma de saber de qué producto hablaba cada fila cuando dos se
 * llaman parecido. El «Exportar inventario» de la Edge Function ya lo traía.
 *
 * Contrato: una columna «SKU» justo después de «Producto»; el producto sin SKU
 * deja la celda vacía.
 *
 * Se usa el DataTable y el `exportToCSV` reales y se lee el Blob descargado:
 * lo que se asserta es el archivo que abre Excel. Mocks espejo de
 * stock-page-adjust-capability.test.tsx (la página arrastra demasiados hooks
 * para renderizarla sin ellos).
 */
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false }),
}))
vi.mock("next/navigation", () => ({ useSearchParams: () => new URLSearchParams() }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ isAdmin: false, user: null }) }))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({
    products: [
      {
        id: "p1", name: "Tomate", category: "Verdulería", sku: "TOM-001", price: 1000, cost: 600,
        stock: 8, minStock: 2, createdAt: "2026-09-24T00:00:00Z", stockControlType: "tracked",
      },
      {
        id: "p2", name: "Lechuga", category: "Verdulería", price: 500, cost: 300,
        stock: 4, minStock: 1, createdAt: "2026-09-24T00:00:00Z", stockControlType: "tracked",
      },
    ],
  }),
}))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: null }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }),
}))
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({}) }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/stock/stock-adjustment-modal", () => ({ StockAdjustmentModal: () => null }))
vi.mock("@/components/stock/stock-import-adjustment-dialog", () => ({ StockImportAdjustmentDialog: () => null }))
vi.mock("@/components/stock/stock-movements-panel", () => ({ StockMovementsPanel: () => null }))
vi.mock("@/components/stock/low-stock-alert", () => ({ LowStockAlert: () => null }))
vi.mock("@/components/admin/ModuleMetricsWrapper", () => ({ ModuleMetricsWrapper: () => null }))
vi.mock("@/components/export/ExportButton", () => ({ ExportButton: () => null }))
vi.mock("@/components/branches/TransferStockAction", () => ({ TransferStockAction: () => null }))
vi.mock("@/components/stock/ProductBranchBreakdown", () => ({ ProductBranchBreakdown: () => null }))
vi.mock("@/components/forms/product-form", () => ({ ProductForm: () => null }))

import StockPage from "@/app/(dashboard)/stock/page"

/** Click en «Exportar» (la del DataTable) y devuelve el CSV descargado, partido en celdas. */
async function exportedTable(): Promise<string[][]> {
  let captured: Blob | null = null
  vi.spyOn(URL, "createObjectURL").mockImplementation((blob) => {
    captured = blob as Blob
    return "blob:test"
  })
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined)

  render(<StockPage />)
  fireEvent.click(screen.getByRole("button", { name: /^exportar$/i }))
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

function rowOf(table: string[][], producto: string): Record<string, string> {
  const [header, ...rows] = table
  const row = rows.find((r) => r[header.indexOf("Producto")] === producto)
  if (!row) throw new Error(`No hay fila para "${producto}" en el CSV`)
  return Object.fromEntries(header.map((h, i) => [h, row[i]]))
}

beforeEach(() => {
  vi.restoreAllMocks()
})
afterEach(() => {
  vi.restoreAllMocks()
})

describe("/stock — el CSV exportado lleva el SKU", () => {
  it("encabezado: «SKU» va justo después de «Producto» y las demás columnas se conservan", async () => {
    const header = (await exportedTable())[0]
    expect(header).toContain("SKU")
    expect(header.indexOf("SKU")).toBe(header.indexOf("Producto") + 1)
    expect(header).toEqual(expect.arrayContaining(["Categoría", "Stock actual", "Stock mínimo"]))
  })

  it("el producto con SKU lo lleva en su fila", async () => {
    const fila = rowOf(await exportedTable(), "Tomate")
    expect(fila["SKU"]).toBe("TOM-001")
    expect(fila["Stock actual"]).toBe("8")
  })

  it("el producto sin SKU deja la celda vacía (no «undefined», no «null»)", async () => {
    const fila = rowOf(await exportedTable(), "Lechuga")
    expect(fila["SKU"]).toBe("")
    expect(fila["Stock actual"]).toBe("4")
  })
})
