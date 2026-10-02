/**
 * presupuestos-modulo (D12, tareas 5.3/5.4) — `QuoteForm`: alta, edición y
 * duplicado de un presupuesto, compuesto con las piezas compartidas del carrito
 * de la venta. Sin lógica de carrito propia: todo pasa por `lib/cart-utils`,
 * `lib/quote-lines` y `lib/quote-form`.
 *
 * Los selectores pesados (`ProductPicker`, `SearchableSelect`, `CartItemList`,
 * `ScrollableCartShell`) se reemplazan por dobles simples, igual que en los
 * tests de `sale-form`; el lector de códigos (`BarcodeScannerInput`) queda REAL
 * y se simula con `keydown` de ráfaga.
 */
import React from "react"
import { createPortal } from "react-dom"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, act, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"
import { argentinaToday } from "@/lib/date-range"
import { addDaysToIsoDate } from "@/lib/receivables-aging"
import type { Client, Product, UnitOfMeasure } from "@/lib/types"
import type { QuoteApiRow, QuoteItemApiRow } from "@/lib/quote-types"
import { scanBurst } from "../helpers/scanner-keys"

const mocks = vi.hoisted(() => ({
  createMutate: vi.fn(),
  updateMutate: vi.fn(),
  push: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
  toastInfo: vi.fn(),
  invalidateQueries: vi.fn(),
}))

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS = [G, KG, U]

const QUESO: Product = {
  id: "p-queso", name: "Queso", category: "Fiambres", categoryId: "c1", cost: 600, price: 1800, margin: 60,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}
const HUEVO: Product = {
  id: "p-huevo", name: "Huevo", category: "Almacén", categoryId: "c1", cost: 50, price: 100, margin: 50,
  stock: 2, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-u", barcode: "HUEVOBC",
}
const TOMATE: Product = {
  id: "p-tomate", name: "Tomate", category: "Verdulería", categoryId: "c1", cost: 2, price: 4.8, margin: 40,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", scalePlu: 261,
}
const PRODUCTS = [QUESO, HUEVO, TOMATE]

const CLIENT_CON_TEL: Client = {
  id: "c-ana", name: "Ana Pérez", email: "", phone: "2615551234", lastPurchase: "-", totalSpent: 0,
}
const CLIENT_SIN_TEL: Client = {
  id: "c-beto", name: "Beto Sosa", email: "", phone: "", lastPurchase: "-", totalSpent: 0,
}
const CLIENT_NUEVO: Client = {
  id: "c-nuevo", name: "Carla Nueva", email: "", phone: "2615559999", lastPurchase: "-", totalSpent: 0,
}

let scaleSettings = { ...FACTORY_SCALE_SETTINGS, enabled: true }
let validityDays = 15

vi.mock("sonner", () => ({
  toast: { error: mocks.toastError, success: mocks.toastSuccess, info: mocks.toastInfo },
}))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: mocks.push }) }))
vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries: mocks.invalidateQueries }),
}))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: PRODUCTS }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [CLIENT_CON_TEL, CLIENT_SIN_TEL] }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: UNITS, unitsById: new Map(UNITS.map((u) => [u.id, u])) }),
}))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: scaleSettings, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-quotes", () => ({
  useCreateQuote: () => ({ mutateAsync: mocks.createMutate, isPending: false }),
  useUpdateQuote: () => ({ mutateAsync: mocks.updateMutate, isPending: false }),
  useQuoteSettings: () => ({ data: { defaultQuoteValidityDays: validityDays } }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Sucursal" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">Sin sucursal</option>
      <option value="b-1">Centro</option>
    </select>
  ),
}))
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({
    options, value, onValueChange,
  }: { options: { value: string; label: string }[]; value: string; onValueChange: (v: string) => void }) => (
    <select aria-label="Cliente" value={value} onChange={(e) => onValueChange(e.target.value)}>
      <option value="">Elegí un cliente</option>
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  ),
}))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ onValueChange }: { onValueChange: (id: string) => void }) => (
    <div>
      {PRODUCTS.map((p) => (
        <button key={p.id} type="button" onClick={() => onValueChange(p.id)}>{`elegir ${p.name}`}</button>
      ))}
    </div>
  ),
}))
vi.mock("@/components/shared/cart-item-list", () => ({
  CartItemList: ({
    items, onRemove,
  }: {
    items: Array<{ id: string; productName: string; quantity: number; unitValue: number; subtotal: number; badge?: string }>
    onRemove: (id: string) => void
  }) => (
    <ul data-testid="cart">
      {items.map((i) => (
        <li key={i.id} data-testid="cart-item">
          <span>{i.productName}</span>
          <span data-testid="line-qty">{i.quantity}</span>
          <span data-testid="line-price">{i.unitValue}</span>
          <span data-testid="line-subtotal">{i.subtotal}</span>
          {i.badge ? <span data-testid="line-badge">{i.badge}</span> : null}
          <button type="button" onClick={() => onRemove(i.id)}>{`quitar ${i.productName}`}</button>
        </li>
      ))}
    </ul>
  ),
}))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({
    children, listContent, footerContent, className,
  }: { children: React.ReactNode; listContent?: React.ReactNode; footerContent?: React.ReactNode; className?: string }) => (
    <div data-testid="cart-shell" data-shell-class={className}>
      {children}
      {listContent}
      {footerContent}
    </div>
  ),
}))
vi.mock("@/components/shared/responsive-modal", () => ({
  ResponsiveModal: ({
    open, title, children,
  }: { open: boolean; title: string; children: React.ReactNode }) =>
    // Portal real, como el Dialog de Radix: los eventos de React suben por el
    // árbol de componentes aunque el DOM esté en <body>.
    open ? createPortal(<div role="dialog" aria-label={title}>{children}</div>, document.body) : null,
}))
vi.mock("@/components/forms/client-form", () => ({
  // Un <form> de verdad: su submit sube por el árbol de React hasta el
  // formulario del presupuesto si el modal estuviera dentro de él.
  ClientForm: ({ onSuccess }: { onSuccess: (c?: Client) => void }) => (
    <form
      onSubmit={(e) => {
        e.preventDefault()
        onSuccess(CLIENT_NUEVO)
      }}
    >
      <button type="submit">crear cliente (mock)</button>
    </form>
  ),
}))

const { QuoteForm } = await import("@/components/quotes/QuoteForm")

// ── helpers ───────────────────────────────────────────────────────────────────

const TODAY = argentinaToday()

function quoteRow(overrides: Partial<QuoteApiRow> = {}): QuoteApiRow {
  return {
    id: "q-1",
    number: 12,
    number_label: "P-00000012",
    status: "sent",
    revision: 3,
    client_id: "c-ana",
    client_name: "Ana Pérez",
    client_phone: "2615551234",
    branch_id: null,
    valid_until: addDaysToIsoDate(TODAY, 5),
    notes: "Entrega en 48 hs",
    total: "2700",
    sent_at: "2026-09-30T12:00:00Z",
    created_at: "2026-09-29T12:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    is_expired: false,
    sales_order_id: null,
    items: [],
    history: [],
    ...overrides,
  }
}

function itemRow(overrides: Partial<QuoteItemApiRow> & { id: string }): QuoteItemApiRow {
  return {
    quote_id: "q-1",
    product_id: "p-huevo",
    unit_id: "u-u",
    quantity: "3",
    price: "90",
    subtotal: "270",
    name_snapshot: "Huevo",
    sku_snapshot: null,
    line_no: 1,
    ...overrides,
  }
}

function cartItems() {
  return screen.queryAllByTestId("cart-item")
}

function addHuevo(quantity = "3", discount = "0") {
  fireEvent.click(screen.getByRole("button", { name: "elegir Huevo" }))
  fireEvent.change(screen.getByLabelText(/^Cantidad( \(|$)/), { target: { value: quantity } })
  if (discount !== "0") fireEvent.change(screen.getByLabelText(/^Descuento/), { target: { value: discount } })
  fireEvent.click(screen.getByRole("button", { name: /agregar al presupuesto/i }))
}

function selectClient(id: string) {
  fireEvent.change(screen.getByLabelText("Cliente"), { target: { value: id } })
}

function submit() {
  fireEvent.click(screen.getByRole("button", { name: /crear presupuesto|guardar cambios/i }))
}

beforeEach(() => {
  vi.clearAllMocks()
  scaleSettings = { ...FACTORY_SCALE_SETTINGS, enabled: true }
  validityDays = 15
  mocks.createMutate.mockResolvedValue({ id: "q-new" })
  mocks.updateMutate.mockResolvedValue({ id: "q-1" })
})

// ── alta ──────────────────────────────────────────────────────────────────────

describe("QuoteForm — cliente", () => {
  it("el cliente es obligatorio: sin cliente no llama a la API y lo avisa", () => {
    render(<QuoteForm />)
    addHuevo()

    submit()

    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/cliente/i))
    expect(mocks.createMutate).not.toHaveBeenCalled()
  })

  it("'Nuevo cliente' abre el alta en el lugar y preselecciona al cliente creado", async () => {
    render(<QuoteForm />)
    addHuevo()

    fireEvent.click(screen.getByRole("button", { name: /nuevo cliente/i }))
    const dialog = await screen.findByRole("dialog", { name: /nuevo cliente/i })
    fireEvent.click(within(dialog).getByRole("button", { name: /crear cliente \(mock\)/i }))

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    // el submit del alta de cliente NO dispara el guardado del presupuesto
    expect(mocks.toastError).not.toHaveBeenCalled()
    expect(mocks.createMutate).not.toHaveBeenCalled()
    expect(screen.getByLabelText("Cliente")).toHaveValue("c-nuevo")
    // y el teléfono del recién creado se ve (el alta devolvió el cliente completo)
    expect(screen.getByText(/2615559999/)).toBeInTheDocument()

    submit()
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    expect(mocks.createMutate.mock.calls[0][0]).toMatchObject({ client_id: "c-nuevo" })
  })

  it("un cliente sin teléfono avisa que WhatsApp abrirá el selector de contactos; con teléfono, no", () => {
    render(<QuoteForm />)

    selectClient("c-ana")
    expect(screen.queryByText(/sin teléfono/i)).not.toBeInTheDocument()

    selectClient("c-beto")
    expect(screen.getByText(/sin teléfono/i)).toBeInTheDocument()
    expect(screen.getByText(/selector de contactos/i)).toBeInTheDocument()
  })

  it("?cliente= (initialClientId) llega preseleccionado", () => {
    render(<QuoteForm initialClientId="c-ana" />)

    expect(screen.getByLabelText("Cliente")).toHaveValue("c-ana")
  })
})

describe("QuoteForm — líneas", () => {
  it("alta de un producto con descuento: el payload manda el precio efectivo y el subtotal", async () => {
    render(<QuoteForm initialClientId="c-ana" />)

    addHuevo("3", "10") // 3 × $100 − 10 % = $270 → precio efectivo $90

    expect(cartItems()).toHaveLength(1)
    expect(screen.getByTestId("line-subtotal")).toHaveTextContent("270")
    submit()

    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    const payload = mocks.createMutate.mock.calls[0][0]
    expect(payload.items).toEqual([
      { product_id: "p-huevo", unit_id: "u-u", quantity: 3, price: 90, subtotal: 270 },
    ])
  })

  it("alta con otra unidad: 500 g de un producto a $1.800/kg manda unit_id de gramos y precio por gramo", async () => {
    const user = userEvent.setup()
    render(<QuoteForm initialClientId="c-ana" />)

    fireEvent.click(screen.getByRole("button", { name: "elegir Queso" }))
    await user.click(screen.getByRole("combobox", { name: /unidad/i }))
    await user.click(await screen.findByRole("option", { name: /^g — Gramo$/ }))
    fireEvent.change(screen.getByLabelText(/^Cantidad( \(|$)/), { target: { value: "500" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al presupuesto/i }))

    submit()
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    const [line] = mocks.createMutate.mock.calls[0][0].items
    expect(line).toMatchObject({ product_id: "p-queso", unit_id: "u-g", quantity: 500 })
    expect(line.price).toBeCloseTo(1.8, 10)
    expect(line.subtotal).toBeCloseTo(900, 4)
  })

  it("una línea de servicio lleva descripción, sin producto, en el payload", async () => {
    render(<QuoteForm initialClientId="c-ana" />)

    fireEvent.change(screen.getByLabelText("Concepto: descripción"), { target: { value: "Flete a domicilio" } })
    fireEvent.change(screen.getByLabelText("Concepto: cantidad"), { target: { value: "1" } })
    fireEvent.change(screen.getByLabelText("Concepto: precio"), { target: { value: "3500" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar concepto/i }))

    expect(cartItems()).toHaveLength(1)
    expect(screen.getByText("Flete a domicilio")).toBeInTheDocument()
    expect(screen.getByTestId("line-badge")).toHaveTextContent(/concepto/i)

    submit()
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    expect(mocks.createMutate.mock.calls[0][0].items).toEqual([
      { product_id: null, unit_id: null, quantity: 1, price: 3500, subtotal: 3500, description: "Flete a domicilio" },
    ])
  })

  it("un concepto sin descripción no se agrega y avisa", () => {
    render(<QuoteForm initialClientId="c-ana" />)

    fireEvent.change(screen.getByLabelText("Concepto: precio"), { target: { value: "100" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar concepto/i }))

    expect(cartItems()).toHaveLength(0)
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/descripción/i))
  })

  it("productos y conceptos conservan el orden en que se cargaron", async () => {
    render(<QuoteForm initialClientId="c-ana" />)

    fireEvent.change(screen.getByLabelText("Concepto: descripción"), { target: { value: "Instalación" } })
    fireEvent.change(screen.getByLabelText("Concepto: precio"), { target: { value: "500" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar concepto/i }))
    addHuevo("1")

    submit()
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    const items = mocks.createMutate.mock.calls[0][0].items
    expect(items.map((i: { product_id: string | null }) => i.product_id)).toEqual([null, "p-huevo"])
  })

  it("quitar una línea la saca del payload", async () => {
    render(<QuoteForm initialClientId="c-ana" />)
    addHuevo("1")
    fireEvent.click(screen.getByRole("button", { name: /quitar huevo/i }))

    expect(cartItems()).toHaveLength(0)
    submit()
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/al menos/i))
    expect(mocks.createMutate).not.toHaveBeenCalled()
  })

  it("el stock insuficiente NO bloquea: la línea se agrega y se muestra el disponible", async () => {
    render(<QuoteForm initialClientId="c-ana" />)

    addHuevo("5") // el Huevo tiene stock 2

    expect(cartItems()).toHaveLength(1)
    const notice = screen.getByRole("status", { name: /stock/i })
    expect(notice).toHaveTextContent(/disponible/i)
    expect(notice).toHaveTextContent(/no reserva stock/i)

    submit()
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
  })
})

describe("QuoteForm — lector de códigos y etiqueta de balanza", () => {
  it("una etiqueta de balanza agrega la línea con el importe de la etiqueta", () => {
    render(<QuoteForm initialClientId="c-ana" />)

    act(() => scanBurst("2002610013638")) // Tomate, PLU 261, importe $13,63

    expect(cartItems()).toHaveLength(1)
    expect(within(screen.getByTestId("cart")).getByText(/^tomate$/i)).toBeInTheDocument()
    expect(Number(screen.getByTestId("line-subtotal").textContent)).toBeCloseTo(13.63, 2)
  })

  it("un código de barras de un producto por unidades agrega una línea y no se bloquea por stock", () => {
    render(<QuoteForm initialClientId="c-ana" />)

    act(() => scanBurst("HUEVOBC"))
    act(() => scanBurst("HUEVOBC"))
    act(() => scanBurst("HUEVOBC")) // la tercera unidad supera el stock 2

    // misma unidad y producto: se fusionan en una línea de 3
    expect(cartItems()).toHaveLength(1)
    expect(screen.getByTestId("line-qty")).toHaveTextContent("3")
    expect(screen.getByRole("status", { name: /stock/i })).toHaveTextContent(/disponible/i)
  })

  it("un código desconocido no agrega nada", () => {
    render(<QuoteForm initialClientId="c-ana" />)

    act(() => scanBurst("0000000000000"))

    expect(cartItems()).toHaveLength(0)
  })
})

describe("QuoteForm — validez y notas", () => {
  it("la validez arranca con el default de la cuenta", () => {
    validityDays = 20
    render(<QuoteForm />)

    expect(screen.getByLabelText(/válido hasta/i)).toHaveValue(addDaysToIsoDate(TODAY, 20))
  })

  it("el payload manda la validez elegida y las notas recortadas (o null si están vacías)", async () => {
    render(<QuoteForm initialClientId="c-ana" />)
    addHuevo("1")
    fireEvent.change(screen.getByLabelText(/válido hasta/i), { target: { value: addDaysToIsoDate(TODAY, 3) } })
    fireEvent.change(screen.getByLabelText(/notas/i), { target: { value: "  Entrega en 48 hs  " } })

    submit()
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    expect(mocks.createMutate.mock.calls[0][0]).toMatchObject({
      valid_until: addDaysToIsoDate(TODAY, 3),
      notes: "Entrega en 48 hs",
    })
  })

  it("sin notas manda null", async () => {
    render(<QuoteForm initialClientId="c-ana" />)
    addHuevo("1")

    submit()
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    expect(mocks.createMutate.mock.calls[0][0].notes).toBeNull()
  })

  it("una validez anterior a hoy no se envía", () => {
    render(<QuoteForm initialClientId="c-ana" />)
    addHuevo("1")
    fireEvent.change(screen.getByLabelText(/válido hasta/i), { target: { value: addDaysToIsoDate(TODAY, -1) } })

    submit()

    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/hoy/i))
    expect(mocks.createMutate).not.toHaveBeenCalled()
  })

  it("al crear, navega al detalle del presupuesto nuevo", async () => {
    render(<QuoteForm initialClientId="c-ana" />)
    addHuevo("1")

    submit()

    await waitFor(() => expect(mocks.push).toHaveBeenCalledWith("/presupuestos/q-new"))
    expect(mocks.toastSuccess).toHaveBeenCalled()
  })

  it("un error del servidor se traduce a un mensaje accionable y no navega", async () => {
    mocks.createMutate.mockRejectedValue(new Error("product_not_found"))
    render(<QuoteForm initialClientId="c-ana" />)
    addHuevo("1")

    submit()

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.toastError.mock.calls[0][0]).not.toBe("product_not_found")
    expect(mocks.push).not.toHaveBeenCalled()
  })
})

// ── duplicado ─────────────────────────────────────────────────────────────────

describe("QuoteForm — duplicar (?duplicar=)", () => {
  const source = quoteRow({
    status: "accepted",
    items: [itemRow({ id: "i1", price: "90", quantity: "3", subtotal: "270" })],
  })

  it("precarga cliente, notas y líneas con el precio de HOY y avisa lo que cambió", () => {
    render(<QuoteForm duplicateFrom={source} />)

    expect(screen.getByLabelText("Cliente")).toHaveValue("c-ana")
    expect(screen.getByLabelText(/notas/i)).toHaveValue("Entrega en 48 hs")
    expect(cartItems()).toHaveLength(1)
    expect(screen.getByTestId("line-price")).toHaveTextContent("100") // precio de hoy, no $90
    const notice = screen.getByRole("status", { name: /precios actualizados/i })
    expect(notice).toHaveTextContent(/huevo/i)
    expect(notice).toHaveTextContent(/descuentos no se copian/i)
  })

  it("la validez se recalcula desde hoy y guardar CREA un presupuesto nuevo", async () => {
    validityDays = 10
    render(<QuoteForm duplicateFrom={source} />)

    expect(screen.getByLabelText(/válido hasta/i)).toHaveValue(addDaysToIsoDate(TODAY, 10))
    submit()

    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    expect(mocks.updateMutate).not.toHaveBeenCalled()
  })
})

// ── edición ───────────────────────────────────────────────────────────────────

describe("QuoteForm — edición", () => {
  const sent = quoteRow({
    items: [
      itemRow({ id: "i1", price: "90", quantity: "3", subtotal: "270", line_no: 1 }),
      itemRow({
        id: "i2", product_id: null, unit_id: null, name_snapshot: "Flete", quantity: "1", price: "500",
        subtotal: "500", line_no: 2,
      }),
    ],
  })

  it("precarga las líneas persistidas con el precio efectivo y descuento 0", () => {
    render(<QuoteForm quote={sent} />)

    expect(cartItems()).toHaveLength(2)
    expect(screen.getAllByTestId("line-price")[0]).toHaveTextContent("90") // el cotizado, no el de hoy ($100)
    expect(screen.getByLabelText("Cliente")).toHaveValue("c-ana")
    expect(screen.getByLabelText(/válido hasta/i)).toHaveValue(addDaysToIsoDate(TODAY, 5))
    expect(screen.getByLabelText(/notas/i)).toHaveValue("Entrega en 48 hs")
  })

  it("guardar manda la revision cargada y reemplaza todas las líneas", async () => {
    render(<QuoteForm quote={sent} />)

    submit()

    await waitFor(() => expect(mocks.updateMutate).toHaveBeenCalledTimes(1))
    const { quoteId, payload } = mocks.updateMutate.mock.calls[0][0]
    expect(quoteId).toBe("q-1")
    expect(payload).toMatchObject({
      client_id: "c-ana",
      revision: 3,
      valid_until: addDaysToIsoDate(TODAY, 5),
      notes: "Entrega en 48 hs",
    })
    expect(payload.items).toEqual([
      { product_id: "p-huevo", unit_id: "u-u", quantity: 3, price: 90, subtotal: 270 },
      { product_id: null, unit_id: null, quantity: 1, price: 500, subtotal: 500, description: "Flete" },
    ])
    expect(mocks.createMutate).not.toHaveBeenCalled()
    await waitFor(() => expect(mocks.push).toHaveBeenCalledWith("/presupuestos/q-1"))
  })

  it("una línea cuyo producto ya no está vivo se marca 'Producto no disponible' y bloquea el guardado", () => {
    const withGone = quoteRow({
      items: [itemRow({ id: "i9", product_id: "p-baja", name_snapshot: "Buzo viejo", price: "2000", subtotal: "2000", quantity: "1" })],
    })
    render(<QuoteForm quote={withGone} />)

    expect(screen.getByTestId("line-badge")).toHaveTextContent(/producto no disponible/i)
    submit()

    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/no disponibles/i))
    expect(mocks.updateMutate).not.toHaveBeenCalled()

    // quitarla destraba el guardado de lo demás
    fireEvent.click(screen.getByRole("button", { name: /quitar buzo viejo/i }))
    expect(screen.queryByTestId("line-badge")).not.toBeInTheDocument()
  })

  it.each([
    ["expired" as const, false, /vencido/i],
    ["rejected" as const, false, /rechazado/i],
  ])("editar un presupuesto %s avisa que se reabre como borrador y exige validez de hoy en adelante", async (status, isExpired, label) => {
    const reopened = quoteRow({
      status,
      is_expired: isExpired,
      valid_until: addDaysToIsoDate(TODAY, -4),
      items: sent.items,
    })
    render(<QuoteForm quote={reopened} />)

    const notice = screen.getByRole("status", { name: /se reabre/i })
    expect(notice).toHaveTextContent(label)
    expect(notice).toHaveTextContent(/borrador/i)
    // la validez vieja no sirve: arranca con el default de la cuenta
    expect(screen.getByLabelText(/válido hasta/i)).toHaveValue(addDaysToIsoDate(TODAY, 15))

    // y una fecha pasada no se manda
    fireEvent.change(screen.getByLabelText(/válido hasta/i), { target: { value: addDaysToIsoDate(TODAY, -4) } })
    submit()
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/hoy/i))
    expect(mocks.updateMutate).not.toHaveBeenCalled()
  })

  it("un enviado vencido (el barrido aún no lo marcó) también pide ampliar la validez", () => {
    const overdue = quoteRow({ status: "sent", is_expired: true, valid_until: addDaysToIsoDate(TODAY, -1), items: sent.items })
    render(<QuoteForm quote={overdue} />)

    expect(screen.getByRole("status", { name: /vencido/i })).toBeInTheDocument()
    expect(screen.getByLabelText(/válido hasta/i)).toHaveValue(addDaysToIsoDate(TODAY, 15))
  })

  it("ante quote_changed avisa que otro usuario lo modificó y ofrece recargar, sin navegar", async () => {
    mocks.updateMutate.mockRejectedValue(new Error("quote_changed"))
    const onReload = vi.fn()
    render(<QuoteForm quote={sent} onReload={onReload} />)

    submit()

    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent(/otro usuario/i)
    expect(mocks.push).not.toHaveBeenCalled()

    fireEvent.click(within(alert).getByRole("button", { name: /recargar/i }))
    expect(onReload).toHaveBeenCalledTimes(1)
  })

  it("sin onReload, 'Recargar' invalida el detalle del presupuesto", async () => {
    mocks.updateMutate.mockRejectedValue(new Error("quote_changed"))
    render(<QuoteForm quote={sent} />)

    submit()
    const alert = await screen.findByRole("alert")
    fireEvent.click(within(alert).getByRole("button", { name: /recargar/i }))

    expect(mocks.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["quotes", "detail", "q-1"] })
  })
})

describe("QuoteForm — altura del carrito en móvil (hallazgo de la pasada visual 7.3)", () => {
  // La cabecera de la página (barra superior + padding + título) ocupa ~9,4 rem a
  // 375 px; el carrito compartido reserva sólo 8 rem por defecto (pensado para un
  // modal), así que "Crear presupuesto" quedaba 22 px debajo del borde inferior
  // del viewport y la página tenía su propio scroll. El presupuesto es una página,
  // no un modal: reserva lo que ocupa su cabecera en móvil y en escritorio.
  function shellClass(): string {
    return screen.getByTestId("cart-shell").getAttribute("data-shell-class") ?? ""
  }

  it("en móvil reserva 11 rem (no los 8 rem de un modal) para que el CTA entre en el viewport", () => {
    render(<QuoteForm />)

    const tokens = shellClass().split(/\s+/)
    expect(tokens).toContain("max-h-[calc(100dvh-11rem)]")
  })

  it("en escritorio sigue reservando 12 rem", () => {
    render(<QuoteForm />)

    expect(shellClass().split(/\s+/)).toContain("sm:max-h-[calc(100dvh-12rem)]")
  })
})
