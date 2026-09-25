/**
 * Corrección del PR #584 (hallazgo BLOQUEANTE de la segunda revisión): el
 * subtotal se calculaba como precio por unidad BASE × cantidad en la unidad
 * de la LÍNEA — 100 g de un producto a $1.800/kg cobraban $180.000. Con el
 * contrato D-F (precio por unidad de la línea, provisorio hasta el sign-off
 * del PO) el precio se re-expresa al elegir la unidad: $1,80/g → $180.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Product, UnitOfMeasure } from "@/lib/types"

const addSaleOperation = vi.fn().mockResolvedValue({ ok: true })

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const DOC: UnitOfMeasure = { id: "u-doc", name: "Docena", symbol: "doc", type: "unit", factor: 12, baseUnitId: "u-u", isSystem: true }
const UNITS = [G, KG, U, DOC]

const QUESO: Product = {
  id: "p-kg", name: "Queso", category: "Fiambres", categoryId: "c1", cost: 600, price: 1800, margin: 60,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}
const HUEVO: Product = {
  id: "p-u", name: "Huevo", category: "Almacén", categoryId: "c1", cost: 50, price: 100, margin: 50,
  stock: 100, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-u",
}

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [QUESO, HUEVO], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [], addClient: vi.fn() }) }))
vi.mock("@/hooks/data/use-sales", () => ({ useSales: () => ({ addSaleOperation, updateSaleOperation: vi.fn() }) }))
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
      <button type="button" onClick={() => onValueChange("p-kg")}>elegir Queso</button>
      <button type="button" onClick={() => onValueChange("p-u")}>elegir Huevo</button>
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

function inputUnder(label: RegExp): HTMLInputElement {
  const el = screen.getAllByText(label).find((n) => n.tagName === "LABEL")
  const input = el?.parentElement?.querySelector("input")
  if (!input) throw new Error(`no se encontró el input de ${label}`)
  return input as HTMLInputElement
}

async function pickUnit(name: RegExp) {
  const user = userEvent.setup()
  const trigger = screen
    .getAllByRole("combobox")
    .find((el) => /kilogramo|gramo|unidad|docena|base/i.test(el.textContent ?? ""))
  if (!trigger) throw new Error("no se encontró el selector de unidad")
  await user.click(trigger)
  await user.click(await screen.findByRole("option", { name }))
}

describe("SaleForm — el precio es por unidad de la LÍNEA (D-F)", () => {
  it("100 g de un producto a $1.800/kg: precio $1,80 y subtotal $180", async () => {
    render(<SaleForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Queso" }))
    await pickUnit(/^g — Gramo$/)
    fireEvent.change(inputUnder(/^Cantidad/), { target: { value: "100" } })
    expect(Number(inputUnder(/^Precio unit/).value)).toBe(1.8)
    expect(Number(inputUnder(/^Subtotal/).value)).toBe(180)
  })

  it("1 Docena de un producto a $100/u: subtotal $1.200", async () => {
    render(<SaleForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Huevo" }))
    await pickUnit(/^doc — Docena$/)
    fireEvent.change(inputUnder(/^Cantidad/), { target: { value: "1" } })
    expect(Number(inputUnder(/^Subtotal/).value)).toBe(1200)
  })

  it("volver de gramo a kg restituye el precio del catálogo", async () => {
    render(<SaleForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Queso" }))
    await pickUnit(/^g — Gramo$/)
    await pickUnit(/^kg — Kilogramo$/)
    expect(Number(inputUnder(/^Precio unit/).value)).toBe(1800)
  })
})
