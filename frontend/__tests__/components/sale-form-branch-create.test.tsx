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
 * ventas-sucursal-por-defecto (D9): el selector de la venta ya NO ofrece «Sin
 * sucursal (general)» (`allowUnassigned={false}`, con el rótulo «Sucursal» dentro
 * del componente) y muestra la principal. Sin tocar el selector el estado sigue
 * en `null` y viaja `null`: el SERVIDOR resuelve la principal con datos vivos.
 * Este archivo fija lo que el FORMULARIO le entrega al selector y lo que el
 * selector le devuelve; el comportamiento del widget real (principal rotulada,
 * re-elegirla no emite) lo cubre BranchSelect-sin-sucursal.test.tsx.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import type { Product } from "@/lib/types"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"

const addSaleOperationMock = vi.fn().mockResolvedValue({ ok: true })
// Props con las que el formulario monta el selector (última render).
const branchSelectProps = vi.hoisted(() => ({
  last: null as null | { value: string | null; allowUnassigned?: boolean; label?: string; placeholder?: string },
}))

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
// Mock mínimo del selector con el MISMO contrato que el real con
// `allowUnassigned={false}` (`value` + `onChange(id)`): una opción por sucursal y
// la de la principal. NUNCA entrega `null`: ya no existe «Sin sucursal (general)».
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: (props: { value: string | null; onChange: (v: string | null) => void; allowUnassigned?: boolean; label?: string; placeholder?: string }) => {
    branchSelectProps.last = props
    return (
      <div>
        <button type="button" onClick={() => props.onChange("branch-a")}>elegir sucursal A</button>
        <button type="button" onClick={() => props.onChange("branch-b")}>elegir sucursal B</button>
        <button type="button" onClick={() => props.onChange("branch-principal")}>elegir la principal</button>
      </div>
    )
  },
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
const { toast } = await import("sonner")

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
  branchSelectProps.last = null
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

  it("sin tocar el selector, meta.branchId es null: el servidor resuelve la principal (no hay un id inventado en el cliente)", async () => {
    const call = await confirmSale()

    expect(call.meta.branchId).toBeNull()
  })

  it("elegir B y después volver a la principal manda el id de la principal (la última elección gana)", async () => {
    const call = await confirmSale(() => {
      fireEvent.click(screen.getByRole("button", { name: /elegir sucursal B/i }))
      fireEvent.click(screen.getByRole("button", { name: /elegir la principal/i }))
    })

    expect(call.meta.branchId).toBe("branch-principal")
  })

  it("monta el selector SIN la opción «Sin sucursal (general)» y con el rótulo «Sucursal» propio", () => {
    render(<SaleForm onSuccess={() => {}} />)

    expect(branchSelectProps.last?.allowUnassigned).toBe(false)
    expect(branchSelectProps.last?.label).toBe("Sucursal")
    expect(branchSelectProps.last?.placeholder).toBeUndefined()
    expect(branchSelectProps.last?.value).toBeNull()
  })

  // Ronda 1 de revisión: el selector lista `is_active = true` y una sucursal
  // CERRADA conserva `is_active = true`, así que se puede elegir. Desde este
  // fix la RPC la rechaza (P0422 `branch_closed`); antes se descartaba y la
  // venta salía de la sucursal por defecto. El usuario tiene que ver la salida,
  // no el token interno.
  it("si la RPC rechaza la sucursal elegida por cerrada, el toast explica la salida sin el token crudo", async () => {
    addSaleOperationMock.mockRejectedValueOnce(new Error("branch_closed: la sucursal está cerrada"))

    await confirmSale(clickBranch(/elegir sucursal A/i))

    await waitFor(() => expect(vi.mocked(toast.error)).toHaveBeenCalled())
    const [shown] = vi.mocked(toast.error).mock.calls[0]
    expect(shown).toMatch(/^Error al registrar la venta: La sucursal está cerrada/)
    expect(shown).toMatch(/Elegí otra sucursal o reabrila desde Sucursales/)
    expect(shown).not.toContain("branch_closed")
  })
})
