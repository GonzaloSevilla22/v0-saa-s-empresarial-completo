/**
 * Corrección del PR #584 (hallazgo BLOQUEANTE de la segunda revisión, compra):
 * el costo de la línea es por unidad de la LÍNEA (contrato D-F) — 500 g de un
 * producto con costo $900/kg cuestan $450, no $450.000.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Product, UnitOfMeasure } from "@/lib/types"

// edicion-preserva-contexto (F1 §D11): espejo de sale-form-edit-context —
// PurchaseForm prefillea branchId desde editingOperation y lo reenvía en el
// payload de edición; unitId del ítem sobrevive el round-trip. F2 no aplica
// a compra (D6 — sin CAE propio), así que no hay banner/fieldset acá.

const updatePurchaseOperationMock = vi.fn().mockResolvedValue(undefined)

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const DOC: UnitOfMeasure = { id: "u-doc", name: "Docena", symbol: "doc", type: "unit", factor: 12, baseUnitId: "u-u", isSystem: true }
const UNITS = [G, KG, U, DOC]
const QUESO: Product = {
  id: "p-kg", name: "Queso", category: "Fiambres", categoryId: "c1", cost: 900, price: 1800, margin: 50,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}
const HUEVO: Product = {
  id: "p-u", name: "Huevo", category: "Almacén", categoryId: "c1", cost: 50, price: 100, margin: 50,
  stock: 100, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-u",
}

// productos-categorias-sku: purchase-form monta ProductCategorySelect en el alta
// inline de producto → use-product-categories → python-client (explota sin
// NEXT_PUBLIC_BACKEND_URL) y useOrgRole → react-query real (mockeado acá).
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false, createProductCategory: vi.fn(), createProductCategoryMutation: { isPending: false } }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true, role: "owner", isLoading: false }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [QUESO, HUEVO], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: vi.fn(), updatePurchaseOperation: updatePurchaseOperationMock }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: UNITS, unitsById: new Map(UNITS.map((u) => [u.id, u])) }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({ value }: { value: string | null }) => (
    <div data-testid="branch-select-value">{value ?? "null"}</div>
  ),
}))
// caja-compras-cobranzas: purchase-form.tsx ahora monta useCashOptin, que
// consulta useBranches/useCashboxes/useCurrentSession directo (no vía
// BranchSelect) — sin mockearlos, la cadena real llega a pythonClient y
// explota por falta de NEXT_PUBLIC_BACKEND_URL en el entorno de test.
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
// review B (FE-1/OQ-5 A): mock informativo (a diferencia de `() => null`)
// para poder verificar prefill + el patrón de "tocado" — value/onChange
// espejo del mock de BranchSelect de arriba.
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({
  CostCenterSelect: ({
    value,
    onChange,
  }: {
    value: string | null
    onChange: (v: string | null) => void
  }) => (
    <div>
      <div data-testid="cost-center-select-value">{value ?? "null"}</div>
      <button type="button" data-testid="cost-center-change" onClick={() => onChange("cc-2")}>
        cambiar
      </button>
      <button type="button" data-testid="cost-center-clear" onClick={() => onChange(null)}>
        limpiar
      </button>
    </div>
  ),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  // pos-banco-movimientos (D9): mock no-op, no ejercitado por este test
  // (edición no monta el selector de cuenta bancaria — D8).
  BankAccountDestinationSelect: () => null,
}))
// pos-banco-movimientos: PurchaseForm ahora llama a usePaymentMethods()
// directo (para resolver el kind de la forma elegida) — mock explícito en
// vez del useQuery real, que el mock estrecho de @tanstack/react-query de
// arriba no provee.
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }),
}))
// compras-proveedor-cuenta-corriente (D10): mismo motivo — mock explícito, no
// pythonClient real (que revienta sin NEXT_PUBLIC_BACKEND_URL en tests).
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({ suppliers: [], addSupplier: vi.fn() }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: () => ({ data: null }),
}))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ onValueChange }: { onValueChange: (id: string) => void }) => (
    <>
      <button type="button" onClick={() => onValueChange("p-kg")}>elegir Queso</button>
      <button type="button" onClick={() => onValueChange("p-u")}>elegir Huevo</button>
    </>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({
    children,
    footerContent,
  }: {
    children: React.ReactNode
    footerContent?: React.ReactNode
  }) => (
    <>
      {children}
      {footerContent}
    </>
  ),
}))

const { PurchaseForm } = await import("@/components/forms/purchase-form")

function inputUnder(label: RegExp): HTMLInputElement {
  const el = screen.getAllByText(label).find((n) => n.tagName === "LABEL")
  const input = el?.parentElement?.querySelector("input")
  if (!input) throw new Error(`no se encontró el input de ${label}`)
  return input as HTMLInputElement
}

async function pickUnit(current: RegExp, name: RegExp) {
  const user = userEvent.setup()
  const trigger = screen.getAllByRole("combobox").find((el) => current.test(el.textContent ?? ""))
  if (!trigger) throw new Error("no se encontró el selector de unidad")
  await user.click(trigger)
  await user.click(await screen.findByRole("option", { name }))
}

describe("PurchaseForm — el costo es por unidad de la LÍNEA (D-F)", () => {
  afterEach(() => vi.clearAllMocks())

  it("500 g de un producto a $900/kg de costo: costo $0,90 y subtotal $450", async () => {
    render(<PurchaseForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Queso" }))
    await pickUnit(/kilogramo/i, /^g — Gramo$/)
    fireEvent.change(inputUnder(/^Cantidad/), { target: { value: "500" } })
    expect(Number(inputUnder(/^Costo unitario/).value)).toBe(0.9)
    expect(Number(inputUnder(/^Subtotal/).value)).toBe(450)
  })

  it("2 Docenas de un producto a $50/u de costo: subtotal $1.200", async () => {
    render(<PurchaseForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Huevo" }))
    await pickUnit(/unidad/i, /^doc — Docena$/)
    fireEvent.change(inputUnder(/^Cantidad/), { target: { value: "2" } })
    expect(Number(inputUnder(/^Subtotal/).value)).toBe(1200)
  })
})
