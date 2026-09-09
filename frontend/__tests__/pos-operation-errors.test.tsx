/**
 * PosPage — errores de operación cableados al helper canónico
 * (candidato "POS sin wirear a operation-errors", origen sucursal-guard-
 * vaciado-auditoria G3).
 *
 * Antes de este fix, /ventas/pos traducía el error de la RPC con su propio
 * `friendlyError` local: un genérico "Stock insuficiente para completar la
 * venta." sin nombre de producto y sin ninguna acción — a diferencia del
 * formulario de venta (sale-form.tsx), que ya usaba `humanizeOperationError`
 * (lib/operation-errors) para nombrar el producto y ofrecer "Transferir
 * stock". Mismo patrón que `frontend/__tests__/lib/operation-errors.test.ts`
 * y el `sale-form-*` que ejercitan el mismo helper.
 *
 * Mockea las mismas dependencias pesadas que pos-payment-methods.test.tsx,
 * pero con un ProductPicker funcional (select simple) para poder ejercitar
 * agregar-al-carrito → cobrar → error.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"

const PRODUCT_ID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"
const PRODUCT = {
  id: PRODUCT_ID,
  name: "Top Pupera Liso Talle 1 Violeta",
  category: "Ropa",
  cost: 100,
  price: 200,
  margin: 50,
  stock: 10,
  minStock: 1,
  isVariant: false,
}

const PM_CASH = { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash" as const, isActive: true, sortOrder: 1, createdAt: "2026-01-01" }

const { routerPush, quickSaleMutateAsync, toastError } = vi.hoisted(() => ({
  routerPush: vi.fn(),
  quickSaleMutateAsync: vi.fn(),
  toastError: vi.fn(),
}))

vi.mock("next/navigation", () => ({ useRouter: () => ({ push: routerPush }) }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: toastError } }))

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT] }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [] }) }))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Showroom" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cb-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: { id: "sess-1" }, isLoading: false }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }),
}))
vi.mock("@/hooks/use-idempotency-key", () => ({
  useIdempotencyKey: () => ({ idempotencyKey: "idem-1", resetIdempotencyKey: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales-orders", () => ({
  useQuickSale: () => ({ mutateAsync: quickSaleMutateAsync, isPending: false }),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [PM_CASH], isLoading: false }),
}))
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: [], isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: () => ({ data: null, isLoading: false }),
}))
vi.mock("@/components/three/Celebration3D", () => ({ Celebration3D: () => null }))
vi.mock("@/components/shared/NoWriteAccessBanner", () => ({ NoWriteAccessBanner: () => null }))
// ProductPicker funcional (select simple) — a diferencia de
// pos-payment-methods.test.tsx, acá SÍ hace falta agregar un producto real
// al carrito para ejercitar el submit.
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({
    products,
    onValueChange,
  }: {
    products: { id: string; name: string }[]
    onValueChange: (id: string) => void
  }) => (
    <select aria-label="Producto" onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Elegí un producto</option>
      {products.map((p) => (
        <option key={p.id} value={p.id}>{p.name}</option>
      ))}
    </select>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, listContent, footerContent }: { children: React.ReactNode; listContent?: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{listContent}{footerContent}</>
  ),
}))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({ options, onValueChange }: { options: { value: string; label: string }[]; onValueChange: (v: string) => void }) => (
    <select aria-label="Cliente" onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Consumidor final</option>
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  ),
}))

import PosPage from "@/app/(dashboard)/ventas/pos/page"

beforeEach(() => {
  vi.clearAllMocks()
})

/** Selecciona el producto de prueba y lo agrega al carrito. */
function addProductToCart() {
  fireEvent.change(screen.getByLabelText("Producto"), { target: { value: PRODUCT_ID } })
  fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
}

describe("PosPage — error de stock insuficiente muestra el mensaje canónico", () => {
  it("nombra el producto, la sucursal, y ofrece 'Transferir stock'", async () => {
    quickSaleMutateAsync.mockRejectedValue(
      new Error(`stock_insuficiente para producto ${PRODUCT_ID}: disponible 0, solicitado 1`),
    )

    render(<PosPage />)
    addProductToCart()
    fireEvent.click(screen.getByRole("button", { name: /^cobrar/i }))

    await waitFor(() => expect(toastError).toHaveBeenCalled())

    const [message, options] = toastError.mock.calls[0]
    expect(message).toContain("Top Pupera Liso Talle 1 Violeta")
    expect(message).toContain("Showroom")
    expect(message).not.toContain(PRODUCT_ID)
    expect(options.action).toEqual({
      label: "Transferir stock",
      onClick: expect.any(Function),
    })

    options.action.onClick()
    expect(routerPush).toHaveBeenCalledWith(`/stock?product=${PRODUCT_ID}`)
  })

  it("un error genérico no reconocido conserva su propio texto amigable, sin acción", async () => {
    quickSaleMutateAsync.mockRejectedValue(new Error("branch_closed: la sucursal está cerrada"))

    render(<PosPage />)
    addProductToCart()
    fireEvent.click(screen.getByRole("button", { name: /^cobrar/i }))

    await waitFor(() => expect(toastError).toHaveBeenCalled())

    const [message, options] = toastError.mock.calls[0]
    expect(message).toMatch(/sucursal está cerrada/i)
    expect(options).toBeUndefined()
  })

  // minors (5): un mensaje de stock con una redacción que humanizeOperationError
  // no reconoce (STOCK_ERROR exige "para producto <uuid>") caía antes en el
  // texto crudo de la RPC — friendlyError ahora lo atrapa como ÚLTIMO recurso,
  // después de humanizeOperationError, sin duplicar su regex.
  it("un mensaje de stock con redacción no reconocida muestra el genérico de stock, sin acción", async () => {
    quickSaleMutateAsync.mockRejectedValue(new Error("stock_insuficiente: revisar el pedido"))

    render(<PosPage />)
    addProductToCart()
    fireEvent.click(screen.getByRole("button", { name: /^cobrar/i }))

    await waitFor(() => expect(toastError).toHaveBeenCalled())

    const [message, options] = toastError.mock.calls[0]
    expect(message).toBe("Stock insuficiente para completar la venta.")
    expect(options).toBeUndefined()
  })
})
