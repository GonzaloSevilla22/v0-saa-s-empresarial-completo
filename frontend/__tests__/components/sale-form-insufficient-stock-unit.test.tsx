/**
 * Corrección del PR #584 (hallazgo bajo, `sale-form.tsx:424/:443`): el toast
 * de "Stock insuficiente" mostraba el stock disponible —que SIEMPRE está en la
 * unidad BASE del producto— con el símbolo de la unidad elegida en la línea.
 * Producto en kg con 0,55 de stock, línea en gramos → "disponible: 0.550 g",
 * que es mil veces menos de lo que hay. Debe decir "0.550 kg".
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Product, UnitOfMeasure } from "@/lib/types"

const toastError = vi.fn()

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const UNITS = [G, KG]

const TOMATE: Product = {
  id: "p-kg", name: "Tomate", category: "Verdulería", categoryId: "c1", cost: 600, price: 1000, margin: 40,
  stock: 0.55, minStock: 0.5, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}
const BOLSA: Product = {
  id: "p-uds", name: "Bolsa", category: "Otros", categoryId: "c1", cost: 5, price: 10, margin: 50,
  stock: 3, minStock: 0, isVariant: false, stockControlType: "tracked",
}

vi.mock("sonner", () => ({ toast: { error: (...a: unknown[]) => toastError(...a), success: vi.fn() } }))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [TOMATE, BOLSA], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [], addClient: vi.fn() }) }))
vi.mock("@/hooks/data/use-sales", () => ({ useSales: () => ({ addSaleOperation: vi.fn(), updateSaleOperation: vi.fn() }) }))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: UNITS, unitsById: new Map(UNITS.map((u) => [u.id, u])) }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({ usePaymentMethods: () => ({ paymentMethods: [] }) }))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: null }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ onValueChange }: { onValueChange: (id: string) => void }) => (
    <>
      <button type="button" onClick={() => onValueChange("p-kg")}>elegir Tomate</button>
      <button type="button" onClick={() => onValueChange("p-uds")}>elegir Bolsa</button>
    </>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}))

const { SaleForm } = await import("@/components/forms/sale-form")

function quantityInput(): HTMLInputElement {
  const label = screen.getByText(/^Cantidad/)
  const input = label.parentElement?.querySelector("input")
  if (!input) throw new Error("no se encontró el input de cantidad")
  return input as HTMLInputElement
}

async function pickUnit(name: RegExp) {
  const user = userEvent.setup()
  const trigger = screen.getAllByRole("combobox").find((el) => /kilogramo|gramo|base/i.test(el.textContent ?? ""))
  if (!trigger) throw new Error("no se encontró el selector de unidad")
  await user.click(trigger)
  await user.click(await screen.findByRole("option", { name }))
}

describe("SaleForm — stock insuficiente se informa en la unidad BASE", () => {
  beforeEach(() => toastError.mockClear())

  it("producto en kg, línea en gramos: 'disponible: 0.550 kg' (no 'g')", async () => {
    render(<SaleForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    await pickUnit(/^g — Gramo$/)
    fireEvent.change(quantityInput(), { target: { value: "1000" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).toHaveBeenCalledWith("Stock insuficiente (disponible: 0.550 kg)")
  })

  it("producto en kg, línea en kg: 'disponible: 0.550 kg'", () => {
    render(<SaleForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    fireEvent.change(quantityInput(), { target: { value: "1" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).toHaveBeenCalledWith("Stock insuficiente (disponible: 0.550 kg)")
  })

  it("producto sin unidad base: 'disponible: 3 uds'", () => {
    render(<SaleForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Bolsa" }))
    fireEvent.change(quantityInput(), { target: { value: "5" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).toHaveBeenCalledWith("Stock insuficiente (disponible: 3 uds)")
  })
  it("acumular gramos en una línea existente también informa '0.550 kg'", async () => {
    render(<SaleForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    await pickUnit(/^g — Gramo$/)
    fireEvent.change(quantityInput(), { target: { value: "500" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    await pickUnit(/^g — Gramo$/)
    fireEvent.change(quantityInput(), { target: { value: "500" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).toHaveBeenCalledWith("Stock insuficiente (disponible: 0.550 kg)")
  })
})
