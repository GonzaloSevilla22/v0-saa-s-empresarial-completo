/**
 * SaleForm — la sucursal elegida llega al ALTA (fix ad-hoc
 * ventas-formulario-sucursal).
 *
 * El formulario ya guardaba la sucursal en su estado y ya la ponía en el
 * `meta` de `addSaleOperation`; el defecto estaba más abajo (el hook, el
 * esquema, el servicio y el repositorio la descartaban). Este archivo fija el
 * contrato de ESTE eslabón — "lo que el usuario elige es lo que `meta`
 * entrega" — para que una regresión del formulario (por ejemplo, volver a
 * armar el `meta` sin `branchId`) no quede tapada por los tests del hook, que
 * arman el `meta` a mano.
 *
 * Sin cambios de UI: el selector, su opción por defecto "Sin sucursal
 * (general)" y el opt-in de caja quedan como están.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import type { Product } from "@/lib/types"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"

const addSaleOperationMock = vi.fn().mockResolvedValue({ ok: true })

const REMERA: Product = {
  id: "p-remera", name: "Remera", category: "Ropa", categoryId: "c1", cost: 50, price: 100, margin: 50,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked",
}

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [REMERA], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [{ id: "client-1", name: "Cliente Uno" }], addClient: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ addSaleOperation: addSaleOperationMock, updateSaleOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
// Mock mínimo del selector con el MISMO contrato que el real
// (`value` + `onChange(id | null)`): una opción por sucursal y la de "Sin
// sucursal (general)", que entrega `null` — el widget real no importa acá, lo
// que importa es qué recibe el formulario.
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({ onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <div>
      <button type="button" onClick={() => onChange("branch-a")}>elegir sucursal A</button>
      <button type="button" onClick={() => onChange("branch-b")}>elegir sucursal B</button>
      <button type="button" onClick={() => onChange(null)}>sin sucursal</button>
    </div>
  ),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({ usePaymentMethods: () => ({ paymentMethods: [] }) }))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: null }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: FACTORY_SCALE_SETTINGS, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ onValueChange }: { onValueChange: (id: string) => void }) => (
    <button type="button" onClick={() => onValueChange("p-remera")}>elegir Remera</button>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({ options, onValueChange }: { options: { value: string; label: string }[]; onValueChange: (v: string) => void }) => (
    <select aria-label="Cliente" onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Consumidor final</option>
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  ),
}))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, footerContent }: { children: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{footerContent}</>
  ),
}))

const { SaleForm } = await import("@/components/forms/sale-form")

type AltaCall = { meta: { branchId: string | null; clientId: string; orgId: string } }

/** Arma una venta de una línea y la confirma; devuelve lo que el formulario
 * le entregó a `addSaleOperation`. */
async function confirmSale(chooseBranch?: () => void): Promise<AltaCall> {
  render(<SaleForm onSuccess={() => {}} />)
  fireEvent.click(screen.getByRole("button", { name: "elegir Remera" }))
  fireEvent.click(screen.getByRole("button", { name: /Agregar al carrito/i }))
  fireEvent.change(screen.getByLabelText("Cliente"), { target: { value: "client-1" } })
  chooseBranch?.()
  fireEvent.click(screen.getByRole("button", { name: /Confirmar venta/i }))
  await waitFor(() => expect(addSaleOperationMock).toHaveBeenCalledTimes(1))
  return addSaleOperationMock.mock.calls[0][0] as AltaCall
}

const clickBranch = (name: RegExp) => () => fireEvent.click(screen.getByRole("button", { name }))

afterEach(() => {
  vi.clearAllMocks()
})

describe("SaleForm (alta) — la sucursal elegida viaja en el meta", () => {
  it("entrega la sucursal elegida como meta.branchId", async () => {
    const call = await confirmSale(clickBranch(/elegir sucursal A/i))

    expect(call.meta.branchId).toBe("branch-a")
    expect(call.meta.clientId).toBe("client-1")
  })

  it("otra sucursal, otro valor (no hay un valor fijo ni se queda con la primera)", async () => {
    const call = await confirmSale(clickBranch(/elegir sucursal B/i))

    expect(call.meta.branchId).toBe("branch-b")
  })

  it("sin elegir ninguna, meta.branchId es null (la venta sigue sin sucursal)", async () => {
    const call = await confirmSale()

    expect(call.meta.branchId).toBeNull()
  })

  it("elegir una sucursal y volver a \"Sin sucursal (general)\" entrega null", async () => {
    const call = await confirmSale(() => {
      fireEvent.click(screen.getByRole("button", { name: /elegir sucursal A/i }))
      fireEvent.click(screen.getByRole("button", { name: /sin sucursal/i }))
    })

    expect(call.meta.branchId).toBeNull()
  })
})
