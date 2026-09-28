/**
 * balanza-etiquetas-pos (task 7.1) — RED→GREEN del lector de balanza en el
 * POS (`/ventas/pos`). `BarcodeScannerInput` se mantiene REAL (no mockeado):
 * los escaneos se simulan con `keydown` reales en `document`, como lo haría
 * el lector físico (mismo patrón que `use-barcode-scanner-scale.test.tsx`,
 * grupo 5). La página NO contiene lógica de etiquetas propia: todo pasa por
 * `resolveScan`/`addScannedProductLine`/`exceedsStock` (lib/).
 *
 * Códigos usados (verificador EAN-13 calculado a mano, fábrica salvo
 * mención): `2002610013638` (peso, PLU 261, importe 13,63 — tabla D5 del
 * design), `2003000020007` (peso, PLU 300, importe 20,00), `2099990010005`
 * (peso, PLU 9999 sin asignar), `2005000050008` (peso, PLU 500, importe
 * 50,00 — para forzar `sale_mode_mismatch` contra un producto por unidades),
 * `2200000045003` (Varios, tabla D5 del design).
 *
 * `con el ProductPicker (Popover) abierto no suspende`: Popover nunca marca
 * `data-scanner-modal` (garantía genérica, ya cubierta por el hook en el
 * grupo 5) — acá el picker está mockeado, así que nunca suspende por
 * construcción; lo que este archivo agrega es la suspensión real cuando SÍ
 * hay un diálogo modal (la hoja de cuenta bancaria).
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, beforeAll } from "vitest"
import { render, screen, fireEvent, waitFor, act } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product, UnitOfMeasure } from "@/lib/types"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"

beforeAll(() => {
  // ResponsiveModal (useIsMobile) necesita matchMedia — fuerza la rama Dialog.
  window.matchMedia = (query: string): MediaQueryList =>
    ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList
})

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

const toastError = vi.fn()
const toastSuccess = vi.fn()

const SETTINGS_ENABLED = { ...FACTORY_SCALE_SETTINGS, enabled: true }

const PM_CASH: { id: string; accountId: string; name: string; kind: "cash"; isActive: boolean; sortOrder: number; createdAt: string } =
  { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash", isActive: true, sortOrder: 1, createdAt: "2026-01-01" }
const PM_TRANSFER: { id: string; accountId: string; name: string; kind: "transfer"; isActive: boolean; sortOrder: number; createdAt: string } =
  { id: "pm-transfer", accountId: "a", name: "Transferencia", kind: "transfer", isActive: true, sortOrder: 2, createdAt: "2026-01-01" }

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure  = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const UNITS = [G, KG]

// PLU 261, base kg, $4,80/kg — código de fábrica de la tabla D5 del design.
const TOMATE: Product = {
  id: "p-tomate", name: "Tomate", category: "Verdulería", categoryId: "c1", cost: 2, price: 4.8, margin: 40,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", scalePlu: 261,
}
// PLU 300, base kg, $10/kg, stock 3kg — para el rechazo acumulativo.
const PAPA: Product = {
  id: "p-papa", name: "Papa", category: "Verdulería", categoryId: "c1", cost: 5, price: 10, margin: 50,
  stock: 3, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", scalePlu: 300,
}
// Sin unidad base (por unidades), con código de barras común y SKU — sin PLU.
const LECHUGA: Product = {
  id: "p-lechuga", name: "Lechuga", category: "Verdulería", categoryId: "c1", cost: 2, price: 4.5, margin: 55,
  stock: 20, minStock: 0, isVariant: false, stockControlType: "tracked", barcode: "LECHBC", sku: "LECH-1",
}
// Base kg (medible) con código de barras común — para needsQuantity.
const BANANA: Product = {
  id: "p-banana", name: "Banana", category: "Verdulería", categoryId: "c1", cost: 3, price: 5, margin: 40,
  stock: 15, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", barcode: "BANBC",
}
// Por unidades con PLU asignado — para forzar sale_mode_mismatch con un
// código de la cabecera de PESO.
const CAJA: Product = {
  id: "p-caja", name: "Caja de fruta", category: "Otros", categoryId: "c1", cost: 20, price: 25, margin: 20,
  stock: 5, minStock: 0, isVariant: false, stockControlType: "tracked", scalePlu: 500,
}

const PRODUCTS = [TOMATE, PAPA, LECHUGA, BANANA, CAJA]

vi.mock("sonner", () => ({ toast: { error: (...a: unknown[]) => toastError(...a), success: (...a: unknown[]) => toastSuccess(...a) } }))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mockOrgRole() }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: PRODUCTS }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [] }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [{ id: "branch-1", name: "Casa Central" }] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cb-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: { id: "sess-1" }, isLoading: false }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: UNITS, unitsById: new Map(UNITS.map((u) => [u.id, u])) }),
}))
vi.mock("@/hooks/use-idempotency-key", () => ({
  useIdempotencyKey: () => ({ idempotencyKey: "idem-1", resetIdempotencyKey: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales-orders", () => ({ useQuickSale: () => mockQuickSale() }))
vi.mock("@/hooks/data/use-payment-methods", () => ({ usePaymentMethods: () => mockPaymentMethods() }))
vi.mock("@/hooks/data/use-bank-accounts", () => ({ useBankAccounts: () => mockBankAccounts() }))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: null, isLoading: false }) }))
vi.mock("@/hooks/data/use-scale-settings", () => ({ useScaleSettings: () => mockScaleSettings() }))
vi.mock("@/components/three/Celebration3D", () => ({ Celebration3D: () => null }))
vi.mock("@/components/shared/NoWriteAccessBanner", () => ({ NoWriteAccessBanner: () => null }))
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
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, listContent, footerContent }: { children: React.ReactNode; listContent?: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{listContent}{footerContent}</>
  ),
}))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: () => <select aria-label="Cliente"><option value="">Consumidor final</option></select>,
}))

let orgRole = { isWriter: true }
let quickSaleMutateAsync: () => Promise<unknown> = vi.fn().mockResolvedValue({ sales_order_id: "so-1", total: 0 })
let paymentMethodsFixture: Array<typeof PM_CASH | typeof PM_TRANSFER> = [PM_CASH]
let bankAccountsFixture: Array<{ id: string; name: string; isActive: boolean }> = []
let scaleSettingsFixture = SETTINGS_ENABLED

function mockOrgRole() { return orgRole }
function mockQuickSale() { return { mutateAsync: quickSaleMutateAsync, isPending: false } }
function mockPaymentMethods() { return { paymentMethods: paymentMethodsFixture, isLoading: false } }
function mockBankAccounts() { return { data: bankAccountsFixture, isLoading: false, isError: false, error: null } }
function mockScaleSettings() { return { settings: scaleSettingsFixture, isLoading: false, isError: false, error: null } }

const { default: PosPage } = await import("@/app/(dashboard)/ventas/pos/page")

function quantityInput(): HTMLInputElement {
  const label = screen.getByText(/^Cantidad/)
  const input = label.parentElement?.querySelector("input")
  if (!input) throw new Error("no se encontró el input de cantidad")
  return input as HTMLInputElement
}

function cartItemTexts(): string[] {
  return screen.queryAllByTestId("cart-item").map((el) => el.textContent ?? "")
}

describe("PosPage — lector de balanza (D6/D7/D8/D9/D10)", () => {
  beforeEach(() => {
    toastError.mockClear()
    toastSuccess.mockClear()
    orgRole = { isWriter: true }
    quickSaleMutateAsync = vi.fn().mockResolvedValue({ sales_order_id: "so-1", total: 0 })
    paymentMethodsFixture = [PM_CASH]
    bankAccountsFixture = []
    scaleSettingsFixture = SETTINGS_ENABLED
  })

  it("etiqueta válida agrega una línea con el subtotal EXACTO de la etiqueta", () => {
    render(<PosPage />)
    scan("2002610013638")
    expect(cartItemTexts()).toEqual(["Tomate — 13.63"])
    expect(toastError).not.toHaveBeenCalled()
  })

  it("dos etiquetas del mismo PLU agregan DOS líneas (nunca se fusionan)", () => {
    render(<PosPage />)
    scan("2002610013638")
    scan("2002610013638")
    expect(cartItemTexts()).toEqual(["Tomate — 13.63", "Tomate — 13.63"])
  })

  it("stock 3 kg y dos etiquetas de 2 kg: la segunda se rechaza (chequeo acumulativo, OQ-9)", () => {
    render(<PosPage />)
    scan("2003000020007") // Papa, PLU 300, $20 / $10/kg = 2 kg
    expect(cartItemTexts()).toEqual(["Papa — 20"])
    scan("2003000020007")
    expect(cartItemTexts()).toEqual(["Papa — 20"]) // no se agregó una segunda
    expect(toastError).toHaveBeenCalledWith(expect.stringMatching(/Stock insuficiente/i))
  })

  it("etiqueta primero y después alta manual del mismo producto y unidad: dos líneas, el subtotal de la etiqueta queda intacto", async () => {
    render(<PosPage />)
    scan("2002610013638") // Tomate, 2,84 kg, subtotal 13.63
    expect(cartItemTexts()).toEqual(["Tomate — 13.63"])

    fireEvent.click(screen.getByRole("button", { name: "elegir Tomate" }))
    fireEvent.change(quantityInput(), { target: { value: "1" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))

    const texts = cartItemTexts()
    expect(texts).toHaveLength(2)
    expect(texts).toContain("Tomate — 13.63") // la línea de la etiqueta no se tocó
  })

  it("código de barras común agrega con addScannedProductLine (producto por unidades)", () => {
    render(<PosPage />)
    scan("LECHBC")
    expect(cartItemTexts()).toEqual(["Lechuga — 4.5"])
  })

  it("SKU agrega con addScannedProductLine", () => {
    render(<PosPage />)
    scan("LECH-1")
    expect(cartItemTexts()).toEqual(["Lechuga — 4.5"])
  })

  it("un producto de base kg (medible) leído por código común NO agrega 0,001 kg: queda elegido con el foco en Cantidad", async () => {
    render(<PosPage />)
    scan("BANBC")
    expect(cartItemTexts()).toEqual([])
    expect(screen.getByTestId("selected-product").textContent).toBe("p-banana")
    await waitFor(() => expect(document.activeElement).toBe(quantityInput()))
  })

  it("PLU sin asignar: error, no agrega", () => {
    render(<PosPage />)
    scan("2099990010005")
    expect(cartItemTexts()).toEqual([])
  })

  it("modo de venta incompatible (sale_mode_mismatch): error, no agrega", () => {
    render(<PosPage />)
    // CAJA es por unidades (sin baseUnitId) con PLU 500, pero el código es
    // de la cabecera de PESO (20) — el modo no coincide.
    scan("2005000050008")
    expect(cartItemTexts()).toEqual([])
  })

  it("etiqueta de Varios (multi_item): error, no agrega", () => {
    render(<PosPage />)
    scan("2200000045003")
    expect(cartItemTexts()).toEqual([])
  })

  it("con la hoja de cuenta bancaria abierta, el lector se suspende: no se agrega nada", async () => {
    paymentMethodsFixture = [PM_CASH, PM_TRANSFER]
    bankAccountsFixture = [{ id: "b-1", name: "Banco Test", isActive: true }]
    render(<PosPage />)

    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: "Transferencia" }))
    await user.click(screen.getByRole("button", { name: /Elegir cuenta/i }))
    // El sheet está abierto (Dialog en desktop) — confirmamos que el diálogo
    // de cuenta bancaria está en pantalla antes de escanear.
    expect(await screen.findByText("Cuenta bancaria destino")).toBeInTheDocument()

    scan("2002610013638")
    expect(cartItemTexts()).toEqual([])
  })

  it("mientras `submitting` el lector se suspende: no se agrega nada", async () => {
    quickSaleMutateAsync = vi.fn(() => new Promise(() => {})) // nunca resuelve
    // Un ítem manual en el carrito para poder confirmar.
    render(<PosPage />)
    fireEvent.click(screen.getByRole("button", { name: "elegir Lechuga" }))
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(cartItemTexts()).toEqual(["Lechuga — 4.5"])

    fireEvent.click(screen.getByRole("button", { name: /^Cobrar/ }))
    await waitFor(() => expect(screen.getByRole("button", { name: /Procesando venta/i })).toBeInTheDocument())

    scan("2002610013638")
    // Sigue habiendo sólo la línea manual — nada nuevo se agregó mientras
    // `submitting` es true.
    expect(cartItemTexts()).toEqual(["Lechuga — 4.5"])
  })

  it("sin permiso de escritura el lector se suspende: no se agrega nada", () => {
    orgRole = { isWriter: false }
    render(<PosPage />)
    scan("2002610013638")
    expect(cartItemTexts()).toEqual([])
  })

  it("el payload de quick-sale lleva items[].subtotal EXACTAMENTE igual al importe de la etiqueta", async () => {
    render(<PosPage />)
    scan("2002610013638")
    fireEvent.click(screen.getByRole("button", { name: /^Cobrar/ }))
    await waitFor(() => expect(quickSaleMutateAsync).toHaveBeenCalledTimes(1))
    const payload = (quickSaleMutateAsync as unknown as { mock: { calls: unknown[][] } }).mock.calls[0][0] as {
      items: Array<{ subtotal: number; price: number }>
    }
    expect(payload.items).toHaveLength(1)
    expect(payload.items[0].subtotal).toBe(13.63)
  })
})
