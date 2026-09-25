/**
 * Corrección del PR #584 (hallazgo bajo, `ventas/pos/page.tsx:369/387`): el
 * toast de "Stock insuficiente" del mostrador mostraba el número pelado
 * ("disponible: 0.55") — sin unidad, en un producto llevado en kg mientras
 * la línea se carga en gramos. El disponible está SIEMPRE en la unidad BASE
 * del producto y se informa con su símbolo: "0.550 kg", "3 uds".
 *
 * Mocks: mismo molde que pos-payment-methods.test.tsx, con un ProductPicker
 * que elige el producto con un botón.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Product, UnitOfMeasure } from "@/lib/types"

const toastError = vi.fn()

const PM_CASH = { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash" as const, isActive: true, sortOrder: 1, createdAt: "2026-01-01" }
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

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [TOMATE, BOLSA] }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [{ id: "client-1", name: "Cliente Uno" }] }),
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Casa Central" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: () => ({ data: [{ id: "cb-1" }] }),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: { id: "sess-1" }, isLoading: false }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: UNITS, unitsById: new Map(UNITS.map((u) => [u.id, u])) }),
}))
vi.mock("@/hooks/use-idempotency-key", () => ({
  useIdempotencyKey: () => ({ idempotencyKey: "idem-1", resetIdempotencyKey: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales-orders", () => ({
  useQuickSale: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [PM_CASH], isLoading: false }),
}))
// pos-banco-movimientos (D9): la grilla del POS ahora también llama a
// useBankAccounts para el chip de destino — sin cuentas cargadas por
// default (D9: "cero render" cuando la organización no tiene bancos), ni
// una de estas ventas ejercita el destino bancario.
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: [], isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useCustomerAccount: () => ({ data: null, isLoading: false }),
}))
vi.mock("@/components/three/Celebration3D", () => ({ Celebration3D: () => null }))
vi.mock("@/components/shared/NoWriteAccessBanner", () => ({ NoWriteAccessBanner: () => null }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ onValueChange }: { onValueChange: (id: string) => void }) => (
    <>
      <button type="button" onClick={() => onValueChange("p-kg")}>elegir Tomate</button>
      <button type="button" onClick={() => onValueChange("p-uds")}>elegir Bolsa</button>
    </>
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


const { default: PosPage } = await import("@/app/(dashboard)/ventas/pos/page")

function quantityInput(): HTMLInputElement {
  const label = screen.getByText(/^Cantidad/)
  const input = label.parentElement?.querySelector("input")
  if (!input) throw new Error("no se encontró el input de cantidad")
  return input as HTMLInputElement
}

async function pickGrams() {
  const user = userEvent.setup()
  const trigger = screen.getAllByRole("combobox").find((el) => /kilogramo/i.test(el.textContent ?? ""))
  if (!trigger) throw new Error("no se encontró el selector de unidad")
  await user.click(trigger)
  await user.click(await screen.findByRole("option", { name: /^g — Gramo$/ }))
}

describe("PosPage — stock insuficiente se informa en la unidad BASE", () => {
  beforeEach(() => toastError.mockClear())

  it("producto en kg, línea en gramos: 'disponible: 0.550 kg'", async () => {
    render(<PosPage />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    await pickGrams()
    fireEvent.change(quantityInput(), { target: { value: "1000" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).toHaveBeenCalledWith("Stock insuficiente (disponible: 0.550 kg)")
  })

  it("acumular gramos en una línea existente también informa '0.550 kg'", async () => {
    render(<PosPage />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    await pickGrams()
    fireEvent.change(quantityInput(), { target: { value: "500" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    await pickGrams()
    fireEvent.change(quantityInput(), { target: { value: "500" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).toHaveBeenCalledWith("Stock insuficiente (disponible: 0.550 kg)")
  })

  it("producto sin unidad base: 'disponible: 3 uds'", () => {
    render(<PosPage />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Bolsa" }))
    fireEvent.change(quantityInput(), { target: { value: "5" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(toastError).toHaveBeenCalledWith("Stock insuficiente (disponible: 3 uds)")
  })
})
