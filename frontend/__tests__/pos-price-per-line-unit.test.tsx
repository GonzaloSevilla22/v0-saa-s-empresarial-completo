/**
 * Corrección del PR #584 (hallazgo BLOQUEANTE de la segunda revisión, POS):
 * el subtotal era precio por unidad BASE × cantidad en la unidad de la línea.
 * En el POS era una regresión nueva: el stock ya descontaba bien (0,1 kg) y el
 * cobro seguía multiplicado por el factor ($180.000 por 100 g a $1.800/kg).
 * Contrato D-F: el precio es por unidad de la LÍNEA — se re-expresa al elegir
 * la unidad, así el `subtotal` que `_c29_confirm_order_core` toma del cliente
 * es el correcto.
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
const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const DOC: UnitOfMeasure = { id: "u-doc", name: "Docena", symbol: "doc", type: "unit", factor: 12, baseUnitId: "u-u", isSystem: true }
const UNITS = [G, KG, U, DOC]
const TOMATE: Product = {
  id: "p-kg", name: "Tomate", category: "Verdulería", categoryId: "c1", cost: 600, price: 1800, margin: 40,
  stock: 10, minStock: 0.5, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}
const BOLSA: Product = {
  id: "p-uds", name: "Huevo", category: "Almacén", categoryId: "c1", cost: 50, price: 100, margin: 50,
  stock: 100, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-u",
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

describe("PosPage — el precio es por unidad de la LÍNEA (D-F)", () => {
  beforeEach(() => toastError.mockClear())

  it("100 g de un producto a $1.800/kg: subtotal $180 (no $180.000)", async () => {
    render(<PosPage />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    await pickUnit(/kilogramo/i, /^g — Gramo$/)
    fireEvent.change(inputUnder(/^Cantidad/), { target: { value: "100" } })
    expect(Number(inputUnder(/^Precio unit/).value)).toBe(1.8)
    expect(Number(inputUnder(/^Subtotal/).value)).toBe(180)
  })

  it("1 Docena de un producto a $100/u: subtotal $1.200 (no $100)", async () => {
    render(<PosPage />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Bolsa" }))
    await pickUnit(/unidad/i, /^doc — Docena$/)
    fireEvent.change(inputUnder(/^Cantidad/), { target: { value: "1" } })
    expect(Number(inputUnder(/^Subtotal/).value)).toBe(1200)
  })
})
