/**
 * balanza-etiquetas-pos (task 8.1) — RED→GREEN del lector de balanza en el
 * formulario de venta. `BarcodeScannerInput` se mantiene REAL (no mockeado):
 * los escaneos se simulan con `keydown` reales en `document` (mismo patrón
 * que `use-barcode-scanner-scale.test.tsx`, grupo 5, y `pos-scale-scanner.
 * test.tsx`, grupo 7). El formulario NO contiene lógica de etiquetas propia:
 * todo pasa por `resolveScan`/`addScannedProductLine`/`exceedsStock` (lib/).
 *
 * Códigos: `2002610013638` (Tomate, PLU 261, peso, importe 13,63 — tabla D5
 * del design), `2003000020007` (Papa, PLU 300, peso, importe 20,00 → 2 kg a
 * $10/kg), verificador EAN-13 calculado a mano.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, act } from "@testing-library/react"
import "@testing-library/jest-dom"
import { SaleForm } from "@/components/forms/sale-form"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"
import type { Product, UnitOfMeasure } from "@/lib/types"
import type { SaleOperation } from "@/lib/group-operations"
import type { Sale } from "@/lib/types"

/** Dispara un keydown real en `document`, como lo haría el lector físico. */
function pressKey(key: string) {
  document.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }))
}

/** Escanea un código completo (ráfaga rápida + Enter). */
function scan(code: string) {
  act(() => {
    for (const ch of code) pressKey(ch)
    pressKey("Enter")
  })
}

const SETTINGS_ENABLED = { ...FACTORY_SCALE_SETTINGS, enabled: true }
let scaleSettingsFixture = SETTINGS_ENABLED

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure  = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const UNITS = [G, KG]

const TOMATE: Product = {
  id: "p-tomate", name: "Tomate", category: "Verdulería", categoryId: "c1", cost: 2, price: 4.8, margin: 40,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", scalePlu: 261,
}
const PAPA: Product = {
  id: "p-papa", name: "Papa", category: "Verdulería", categoryId: "c1", cost: 5, price: 10, margin: 50,
  stock: 3, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", scalePlu: 300,
}
const PRODUCTS = [TOMATE, PAPA]

const addSaleOperationMock = vi.fn().mockResolvedValue({ ok: true })
const updateSaleOperationMock = vi.fn().mockResolvedValue({
  ok: true, operation_id: "op-1", voided_fiscal_document: null,
})

vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: PRODUCTS, addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [{ id: "client-1", name: "Cliente Uno" }], addClient: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ addSaleOperation: addSaleOperationMock, updateSaleOperation: updateSaleOperationMock }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
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
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: scaleSettingsFixture, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ value, onValueChange }: { value: string; onValueChange: (id: string) => void }) => (
    <div>
      <div data-testid="selected-product">{value}</div>
      {PRODUCTS.map((p) => (
        <button key={p.id} type="button" onClick={() => onValueChange(p.id)}>{`elegir ${p.name}`}</button>
      ))}
    </div>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({
  CartItemList: ({ items }: { items: Array<{ id: string; productName: string; subtotal: number }> }) => (
    <ul data-testid="cart">
      {items.map((i) => (
        <li key={i.id} data-testid="cart-item">{i.productName} — {i.subtotal}</li>
      ))}
    </ul>
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
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, listContent, footerContent }: { children: React.ReactNode; listContent?: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{listContent}{footerContent}</>
  ),
}))

function quantityInput(): HTMLInputElement {
  const label = screen.getByText(/^Cantidad/)
  const input = label.parentElement?.querySelector("input")
  if (!input) throw new Error("no se encontró el input de cantidad")
  return input as HTMLInputElement
}

function cartItemTexts(): string[] {
  return screen.queryAllByTestId("cart-item").map((el) => el.textContent ?? "")
}

function makeSale(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "sale-1", date: "2026-09-28", productId: TOMATE.id, productName: "Tomate",
    clientId: "client-1", clientName: "Cliente Uno", quantity: 1, unitPrice: 4.8, total: 4.8,
    currency: "ARS", operationId: "op-1", unitId: "u-kg", branchId: null, canal: null,
    paymentMethodId: null, isFiscallyLocked: false, ...overrides,
  }
}

function makeOperation(overrides: Partial<SaleOperation> = {}): SaleOperation {
  const item = makeSale()
  return {
    key: "op-1", operationId: "op-1", date: "2026-09-28", clientId: "client-1", clientName: "Cliente Uno",
    currency: "ARS", items: [item], total: 4.8, isGrouped: false, paymentMethodId: null, branchId: null,
    canal: null, unitId: "u-kg", isFiscallyLocked: false, fiscal: null, isPaymentLocked: false,
    hasAccountCharge: false, hasCashMovement: false, hasBankMovement: false, ...overrides,
  }
}

describe("SaleForm — lector de balanza (D6/D7/D8/D9)", () => {
  beforeEach(() => {
    addSaleOperationMock.mockClear()
    updateSaleOperationMock.mockClear()
    scaleSettingsFixture = SETTINGS_ENABLED
  })

  it("etiqueta válida agrega una línea con el subtotal EXACTO de la etiqueta", () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    scan("2002610013638")
    expect(cartItemTexts()).toEqual(["Tomate — 13.63"])
  })

  it("código común (+1) conserva la línea manual existente y NUNCA fusiona sobre una línea de balanza", () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    scan("2002610013638") // línea de balanza, Tomate, 13.63
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    fireEvent.change(quantityInput(), { target: { value: "1" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))

    const texts = cartItemTexts()
    expect(texts).toHaveLength(2)
    expect(texts).toContain("Tomate — 13.63") // intacta
  })

  it("dos etiquetas que juntas superan el stock: la segunda se rechaza (OQ-9)", () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    scan("2003000020007") // Papa, 2 kg
    expect(cartItemTexts()).toEqual(["Papa — 20"])
    scan("2003000020007") // 2+2=4 > 3 kg disponibles
    expect(cartItemTexts()).toEqual(["Papa — 20"])
  })

  it("etiqueta de 2 kg + alta manual de 2 kg del mismo producto (3 kg disponibles): la manual se rechaza", () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    scan("2003000020007") // Papa, 2 kg vía etiqueta
    fireEvent.click(screen.getByRole("button", { name: "elegir Papa" }))
    fireEvent.change(quantityInput(), { target: { value: "2" } }) // +2 kg → 4 kg > 3
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(cartItemTexts()).toEqual(["Papa — 20"]) // sigue habiendo sólo la línea de la etiqueta
  })

  it("línea manual 1 kg + etiqueta 1 kg + alta manual 1,5 kg (3 kg disponibles): la tercera se rechaza (rama de fusión)", () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Papa" }))
    fireEvent.change(quantityInput(), { target: { value: "1" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i })) // manual 1 kg

    scan("2003000010008") // Papa, PLU 300, importe $10,00 → 1 kg (etiqueta)
    expect(cartItemTexts()).toEqual(["Papa — 10", "Papa — 10"])

    fireEvent.click(screen.getByRole("button", { name: "elegir Papa" }))
    // fusiona con la línea manual de 1kg (única sin `source`) → total
    // 1(manual)+1(etiqueta)+1.5(nuevo)=3.5 > 3 kg disponibles.
    fireEvent.change(quantityInput(), { target: { value: "1.5" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))

    // Sigue habiendo sólo las dos líneas anteriores — la tercera se rechazó.
    expect(cartItemTexts()).toEqual(["Papa — 10", "Papa — 10"])
  })

  it("editar una venta con una línea persistida + alta manual del mismo producto y unidad: dos líneas, la persistida intacta", () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ items: [makeSale({ quantity: 1, unitPrice: 4.8, total: 4.8 })] })}
      />,
    )
    // La línea persistida ya está en el carrito (no hace falta agregarla).
    expect(cartItemTexts()).toEqual(["Tomate — 4.8"])

    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    fireEvent.change(quantityInput(), { target: { value: "1" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))

    const texts = cartItemTexts()
    expect(texts).toHaveLength(2)
    expect(texts).toContain("Tomate — 4.8") // la persistida no se tocó
  })

  it("el AlertDialog de anulación (confirmVoidOpen) suspende el lector", async () => {
    const PENDING_VOIDABLE_FISCAL = {
      documentId: "fd-pending", status: "pending_cae" as const, label: "0003-00000005",
      submittedToArca: false, frozen: false, voidable: true,
    }
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ isFiscallyLocked: false, fiscal: PENDING_VOIDABLE_FISCAL })}
      />,
    )
    // Dispara el diálogo de confirmación (venta-editable-sin-cae).
    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))
    await screen.findByRole("alertdialog")

    scan("2002610013638")
    // La línea persistida sigue siendo la única — el escaneo se descartó
    // porque el AlertDialog (con `data-scanner-modal`) no contiene al <form>.
    expect(cartItemTexts()).toEqual(["Tomate — 4.8"])
  })

  it("un producto de base kg (medible) leído por código común NO agrega 0,001 kg: queda elegido con el foco en Cantidad", async () => {
    // Tomate no tiene `barcode`, así que usamos su SKU exacto (D6 paso 3) —
    // el mismo camino de `addScannedProductLine` (medible → needsQuantity).
    const TOMATE_SKU = { ...TOMATE, id: "p-tomate-sku", sku: "TOM-1", scalePlu: undefined, name: "Tomate SKU" }
    PRODUCTS.push(TOMATE_SKU)
    render(<SaleForm onSuccess={vi.fn()} />)
    scan("TOM-1")
    expect(cartItemTexts()).toEqual([])
    await waitFor(() => expect(document.activeElement).toBe(quantityInput()))
    PRODUCTS.pop()
  })

  it("el foco en un campo NO queda con el código escrito (guardFocusedInput)", () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    // Un producto elegido (staged) para que el campo Descuento exista —
    // el escaneo de la etiqueta es independiente de ese alta manual en curso.
    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    const discountLabel = screen.getByText(/Descuento/i)
    const discountInput = discountLabel.parentElement?.querySelector("input") as HTMLInputElement
    discountInput.focus()
    scan("2002610013638")
    // El input NO conserva ningún carácter del código leído (value=0 se
    // muestra vacío, NumericInput — la restauración vuelve al mismo estado).
    expect(discountInput.value).toBe("")
    expect(cartItemTexts()).toEqual(["Tomate — 13.63"])
  })

  it("la venta confirmada desde el formulario queda con el total igual al importe de la etiqueta", async () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    scan("2002610013638")
    fireEvent.change(screen.getByLabelText("Cliente"), { target: { value: "client-1" } })
    fireEvent.click(screen.getByRole("button", { name: /Confirmar venta/i }))
    await waitFor(() => expect(addSaleOperationMock).toHaveBeenCalledTimes(1))
    const call = addSaleOperationMock.mock.calls[0][0] as { items: Array<{ subtotal: number }> }
    expect(call.items).toHaveLength(1)
    expect(call.items[0].subtotal).toBe(13.63)
  })
})
