/**
 * remitos-venta (tareas 5.1/5.2) — `DeliveryNoteForm`: alta y edición de un
 * remito de venta. Compuesto con las piezas compartidas del carrito, pero con la
 * diferencia central: el remito MUEVE STOCK, así que
 *
 *  - la sucursal es obligatoria y el stock que se muestra y se hace cumplir es el
 *    de la SUCURSAL elegida (nunca el agregado `product.stock` del catálogo);
 *  - en la edición hay UNA sola contabilidad: disponible = stock de la sucursal
 *    + lo que el remito ya retiene en ella (cero si se cambia de sucursal), y
 *    todas las líneas cuentan contra él;
 *  - antes de guardar se avisa qué stock sale y qué stock vuelve.
 *
 * Los selectores pesados se reemplazan por dobles simples (igual que en
 * `QuoteForm.test`); el lector de códigos (`BarcodeScannerInput`) queda REAL.
 */
import React from "react"
import { createPortal } from "react-dom"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, act, within } from "@testing-library/react"
import "@testing-library/jest-dom"

import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"
import type { Branch, Client, ClientAddress, Product, UnitOfMeasure } from "@/lib/types"
import type { DeliveryNoteApiRow, DeliveryNoteItemApiRow } from "@/lib/delivery-note-types"
import { scanBurst } from "../helpers/scanner-keys"

const mocks = vi.hoisted(() => ({
  createMutate: vi.fn(),
  updateMutate: vi.fn(),
  push: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
  toastInfo: vi.fn(),
  invalidateQueries: vi.fn(),
  branchStockCalls: [] as string[],
  branchSelectProps: [] as Array<{ required?: boolean; alwaysVisible?: boolean }>,
}))

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS = [KG, U]

const HUEVO: Product = {
  id: "p-huevo", name: "Huevo", category: "Almacén", categoryId: "c1", cost: 50, price: 100, margin: 50,
  // El agregado del catálogo dice 12: NUNCA es el que manda en el remito.
  stock: 12, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-u", barcode: "HUEVOBC",
}
const QUESO: Product = {
  id: "p-queso", name: "Queso", category: "Fiambres", categoryId: "c1", cost: 600, price: 1800, margin: 60,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", barcode: "QUESOBC",
}
const TOMATE: Product = {
  id: "p-tomate", name: "Tomate", category: "Verdulería", categoryId: "c1", cost: 2, price: 4.8, margin: 40,
  stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg", scalePlu: 261,
}
const PRODUCTS = [HUEVO, QUESO, TOMATE]

const CLIENT_ANA: Client = { id: "c-ana", name: "Ana Pérez", email: "", phone: "2615551234", lastPurchase: "-", totalSpent: 0 }
const CLIENT_BETO: Client = { id: "c-beto", name: "Beto Sosa", email: "", phone: "", lastPurchase: "-", totalSpent: 0 }
const CLIENT_NUEVO: Client = { id: "c-nuevo", name: "Carla Nueva", email: "", phone: "2615559999", lastPurchase: "-", totalSpent: 0 }

function branch(id: string, name: string, createdAt: string, overrides: Partial<Branch> = {}): Branch {
  return {
    id, accountId: "a-1", name, address: null, isActive: true, createdAt, status: "active",
    openedAt: null, closedAt: null, createdBy: null, deactivatedAt: null, deactivatedBy: null, ...overrides,
  }
}
const CENTRO = branch("b-1", "Centro", "2026-01-01T00:00:00Z")
const NORTE = branch("b-2", "Norte", "2026-02-01T00:00:00Z")

// Stock por sucursal y producto, en su unidad base.
let stockByBranch: Record<string, Record<string, number>> = {}
let branchesList: Branch[] = []
let addressesByClient: Record<string, ClientAddress[]> = {}
let scaleSettings = { ...FACTORY_SCALE_SETTINGS, enabled: true }

function address(overrides: Partial<ClientAddress> = {}): ClientAddress {
  return {
    id: "ad-1", accountId: "a-1", clientId: "c-ana", alias: null, street: "San Martín 100", city: "Mendoza",
    province: "Mendoza", postalCode: null, notes: null, isPrimary: true, createdAt: "2026-01-01T00:00:00Z", updatedAt: null,
    ...overrides,
  }
}

vi.mock("sonner", () => ({
  toast: { error: mocks.toastError, success: mocks.toastSuccess, info: mocks.toastInfo },
}))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: mocks.push }) }))
vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries: mocks.invalidateQueries }),
}))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: PRODUCTS }) }))
vi.mock("@/hooks/data/use-clients", () => ({ useClients: () => ({ clients: [CLIENT_ANA, CLIENT_BETO] }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: UNITS, unitsById: new Map(UNITS.map((u) => [u.id, u])) }),
}))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: scaleSettings, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useCreateDeliveryNote: () => ({ mutateAsync: mocks.createMutate, isPending: false }),
  useUpdateDeliveryNote: () => ({ mutateAsync: mocks.updateMutate, isPending: false }),
}))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: branchesList, isLoading: false }),
}))
vi.mock("@/hooks/data/use-branch-stock", () => ({
  useBranchStock: (branchId: string) => {
    mocks.branchStockCalls.push(branchId)
    const byProduct = stockByBranch[branchId] ?? {}
    return {
      branchStock: Object.entries(byProduct).map(([productId, quantity]) => ({
        id: `${branchId}-${productId}`, accountId: "a-1", productId, branchId, quantity, minStock: 0, productName: productId, productSku: null,
      })),
      isLoading: false,
      isError: false,
    }
  },
}))
vi.mock("@/hooks/data/use-client-addresses", () => ({
  useClientAddresses: (clientId: string | null) => ({ data: clientId ? (addressesByClient[clientId] ?? []) : undefined }),
}))
vi.mock("@/components/branches/BranchSelect", () => ({
  BranchSelect: ({
    value, onChange, required, alwaysVisible,
  }: { value: string | null; onChange: (v: string | null) => void; required?: boolean; alwaysVisible?: boolean }) => {
    mocks.branchSelectProps.push({ required, alwaysVisible })
    return (
      <select aria-label="Sucursal" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
        <option value="">Elegí la sucursal</option>
        <option value="b-1">Centro</option>
        <option value="b-2">Norte</option>
      </select>
    )
  },
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
    items, onRemove, onUpdateQty, maxQtyMap,
  }: {
    items: Array<{ id: string; productName: string; quantity: number; subtotal: number; badge?: string }>
    onRemove: (id: string) => void
    onUpdateQty: (id: string, qty: number) => void
    maxQtyMap?: Record<string, number>
  }) => (
    <ul data-testid="cart">
      {items.map((i) => (
        <li key={i.id} data-testid="cart-item" data-max={maxQtyMap?.[i.id] ?? ""}>
          <span>{i.productName}</span>
          <span data-testid="line-qty">{i.quantity}</span>
          <span data-testid="line-subtotal">{i.subtotal}</span>
          {i.badge ? <span data-testid="line-badge">{i.badge}</span> : null}
          <input
            aria-label={`cantidad ${i.productName}`}
            type="number"
            value={i.quantity}
            onChange={(e) => onUpdateQty(i.id, Number(e.target.value))}
          />
          <button type="button" onClick={() => onRemove(i.id)}>{`quitar ${i.productName}`}</button>
        </li>
      ))}
    </ul>
  ),
}))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({
    children, listContent, footerContent,
  }: { children: React.ReactNode; listContent?: React.ReactNode; footerContent?: React.ReactNode }) => (
    <div data-testid="cart-shell">
      {children}
      {listContent}
      {footerContent}
    </div>
  ),
}))
vi.mock("@/components/shared/responsive-modal", () => ({
  ResponsiveModal: ({ open, title, children }: { open: boolean; title: string; children: React.ReactNode }) =>
    open ? createPortal(<div role="dialog" aria-label={title}>{children}</div>, document.body) : null,
}))
vi.mock("@/components/forms/client-form", () => ({
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

const { DeliveryNoteForm } = await import("@/components/delivery-notes/DeliveryNoteForm")

// ── helpers ───────────────────────────────────────────────────────────────────

function itemRow(overrides: Partial<DeliveryNoteItemApiRow> & { id: string }): DeliveryNoteItemApiRow {
  return {
    delivery_note_id: "dn-1",
    product_id: "p-huevo",
    unit_id: "u-u",
    quantity: "3",
    price: "90",
    subtotal: "270",
    quantity_base: "3",
    name_snapshot: "Huevo",
    sku_snapshot: null,
    unit_cost_snapshot: null,
    iva_rate_snapshot: null,
    line_no: 1,
    ...overrides,
  }
}

function deliveryNote(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return {
    id: "dn-1",
    direction: "sale",
    number: 12,
    number_label: "R-00000012",
    status: "issued",
    revision: 3,
    client_id: "c-ana",
    client_name: "Ana Pérez",
    client_phone: "2615551234",
    branch_id: "b-1",
    branch_name: "Centro",
    issued_on: "2026-10-02",
    delivery_address: "Calle Falsa 123",
    notes: "Entrega por la mañana",
    total: "270",
    created_at: "2026-10-02T12:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    items: [itemRow({ id: "i-1" })],
    history: [],
    ...overrides,
  }
}

const cartItems = () => screen.queryAllByTestId("cart-item")
const selectClient = (id: string) => fireEvent.change(screen.getByLabelText("Cliente"), { target: { value: id } })
const selectBranch = (id: string) => fireEvent.change(screen.getByLabelText("Sucursal"), { target: { value: id } })
const submitBtn = () => screen.getByRole("button", { name: /emitir remito|guardar cambios/i })

function addProduct(name: "Huevo" | "Queso" | "Tomate", quantity: string) {
  fireEvent.click(screen.getByRole("button", { name: `elegir ${name}` }))
  fireEvent.change(screen.getByLabelText(/^Cantidad( \(|$)/), { target: { value: quantity } })
  fireEvent.click(screen.getByRole("button", { name: /agregar al remito/i }))
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.branchStockCalls.length = 0
  mocks.branchSelectProps.length = 0
  scaleSettings = { ...FACTORY_SCALE_SETTINGS, enabled: true }
  branchesList = [CENTRO, NORTE]
  stockByBranch = {
    "b-1": { "p-huevo": 2, "p-queso": 5, "p-tomate": 10 },
    "b-2": { "p-huevo": 10, "p-queso": 0, "p-tomate": 0 },
  }
  addressesByClient = {}
  mocks.createMutate.mockResolvedValue({ id: "dn-new", number_label: "R-00000013" })
  mocks.updateMutate.mockResolvedValue({ id: "dn-1" })
})

// ── alta ──────────────────────────────────────────────────────────────────────

describe("DeliveryNoteForm — alta", () => {
  it("emite con cliente, sucursal y líneas: manda el payload completo y navega al detalle", async () => {
    render(<DeliveryNoteForm />)
    selectClient("c-ana")
    addProduct("Huevo", "2")
    fireEvent.click(submitBtn())

    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalledTimes(1))
    expect(mocks.createMutate).toHaveBeenCalledWith({
      direction: "sale",
      client_id: "c-ana",
      branch_id: "b-1",
      delivery_address: null,
      notes: null,
      items: [{ product_id: "p-huevo", unit_id: "u-u", quantity: 2, price: 100, subtotal: 200 }],
    })
    await waitFor(() => expect(mocks.push).toHaveBeenCalledWith("/remitos/dn-new"))
  })

  it("el cliente es obligatorio: sin cliente no llama a la API y lo avisa", () => {
    render(<DeliveryNoteForm />)
    addProduct("Huevo", "1")
    fireEvent.click(submitBtn())
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/cliente/i))
    expect(mocks.createMutate).not.toHaveBeenCalled()
  })

  it("sin líneas no se emite", () => {
    render(<DeliveryNoteForm />)
    selectClient("c-ana")
    fireEvent.click(submitBtn())
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/producto/i))
    expect(mocks.createMutate).not.toHaveBeenCalled()
  })

  it("'Nuevo cliente' abre el alta en el lugar y preselecciona al cliente creado", async () => {
    render(<DeliveryNoteForm />)
    fireEvent.click(screen.getByRole("button", { name: /nuevo cliente/i }))
    fireEvent.click(await screen.findByRole("button", { name: /crear cliente \(mock\)/i }))
    expect((screen.getByLabelText("Cliente") as HTMLSelectElement).value).toBe("c-nuevo")
    addProduct("Huevo", "1")
    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalled())
    expect(mocks.createMutate.mock.calls[0][0].client_id).toBe("c-nuevo")
  })

  it("el cliente de ?cliente= llega preseleccionado", () => {
    render(<DeliveryNoteForm initialClientId="c-beto" />)
    expect((screen.getByLabelText("Cliente") as HTMLSelectElement).value).toBe("c-beto")
  })

  it("no ofrece 'Agregar concepto': un remito sólo lleva productos", () => {
    render(<DeliveryNoteForm />)
    expect(screen.queryByText(/agregar concepto/i)).not.toBeInTheDocument()
    expect(screen.queryByRole("group", { name: /concepto/i })).not.toBeInTheDocument()
  })

  it("el domicilio y las notas viajan recortados; vacíos viajan como null", async () => {
    render(<DeliveryNoteForm />)
    selectClient("c-ana")
    fireEvent.change(screen.getByLabelText(/domicilio de entrega/i), { target: { value: "  Belgrano 45  " } })
    fireEvent.change(screen.getByLabelText(/^notas/i), { target: { value: "   " } })
    addProduct("Huevo", "1")
    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalled())
    expect(mocks.createMutate.mock.calls[0][0].delivery_address).toBe("Belgrano 45")
    expect(mocks.createMutate.mock.calls[0][0].notes).toBeNull()
  })
})

// ── sucursal ──────────────────────────────────────────────────────────────────

describe("DeliveryNoteForm — sucursal obligatoria y visible", () => {
  it("con varias sucursales operativas precarga la más antigua y usa el selector required + alwaysVisible", () => {
    render(<DeliveryNoteForm />)
    expect((screen.getByLabelText("Sucursal") as HTMLSelectElement).value).toBe("b-1")
    expect(mocks.branchSelectProps.length).toBeGreaterThan(0)
    expect(mocks.branchSelectProps.every((p) => p.required === true && p.alwaysVisible === true)).toBe(true)
  })

  it("cuenta sin módulo de sucursales y una sola activa: se ve como texto, sin selector, y se puede emitir", async () => {
    branchesList = [CENTRO]
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    expect(screen.queryByLabelText("Sucursal")).not.toBeInTheDocument()
    expect(screen.getByText(/Sale de:/).textContent).toMatch(/Sale de:\s*Centro/)
    addProduct("Huevo", "1")
    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.createMutate).toHaveBeenCalled())
    expect(mocks.createMutate.mock.calls[0][0].branch_id).toBe("b-1")
  })

  it("las sucursales cerradas o inactivas no precargan: se elige la operativa más antigua", () => {
    branchesList = [
      branch("b-0", "Vieja cerrada", "2025-01-01T00:00:00Z", { status: "closed" }),
      branch("b-9", "Inactiva", "2025-06-01T00:00:00Z", { isActive: false }),
      NORTE,
      CENTRO,
    ]
    render(<DeliveryNoteForm />)
    expect((screen.getByLabelText("Sucursal") as HTMLSelectElement).value).toBe("b-1")
  })

  it("sin ninguna sucursal operativa no se agregan líneas y se explica por qué", () => {
    branchesList = []
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    expect(screen.getByRole("alert", { name: /sin sucursal/i })).toBeInTheDocument()
    addProduct("Huevo", "1")
    expect(cartItems()).toHaveLength(0)
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/sucursal/i))
  })

  it("sin sucursal elegida (la desmarcó) no se agregan líneas", () => {
    render(<DeliveryNoteForm />)
    selectBranch("")
    addProduct("Huevo", "1")
    expect(cartItems()).toHaveLength(0)
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/sucursal/i))
  })

  it("pide el stock de la sucursal elegida (no el agregado) y avisa que emitir lo descuenta", () => {
    render(<DeliveryNoteForm />)
    expect(mocks.branchStockCalls).toContain("b-1")
    expect(screen.getByRole("status", { name: /efecto en el stock/i })).toHaveTextContent(
      "Al emitir, se descuenta del stock de Centro.",
    )
    selectBranch("b-2")
    expect(mocks.branchStockCalls).toContain("b-2")
    expect(screen.getByRole("status", { name: /efecto en el stock/i })).toHaveTextContent(
      "Al emitir, se descuenta del stock de Norte.",
    )
  })
})

// ── stock por sucursal ────────────────────────────────────────────────────────

describe("DeliveryNoteForm — stock de la sucursal elegida", () => {
  it("bloquea lo que supera el stock de la sucursal aunque el agregado del catálogo alcance, con el disponible y 'Transferir stock'", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    // Huevo: 2 en Centro, 10 en Norte, 12 en el agregado.
    addProduct("Huevo", "3")

    expect(cartItems()).toHaveLength(0)
    const alert = screen.getByRole("alert", { name: /stock insuficiente/i })
    expect(alert).toHaveTextContent(/disponible: 2/i)
    expect(alert).toHaveTextContent(/Centro/)
    const link = within(alert).getByRole("link", { name: /transferir stock/i })
    expect(link).toHaveAttribute("href", "/stock?product=p-huevo")
  })

  it("lo que alcanza se agrega y limpia el bloqueo anterior", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    addProduct("Huevo", "3")
    expect(screen.getByRole("alert", { name: /stock insuficiente/i })).toBeInTheDocument()
    addProduct("Huevo", "2")
    expect(cartItems()).toHaveLength(1)
    expect(screen.queryByRole("alert", { name: /stock insuficiente/i })).not.toBeInTheDocument()
  })

  it("el chequeo es acumulativo: dos altas del mismo producto suman contra el disponible", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    addProduct("Huevo", "2")
    addProduct("Huevo", "1")
    expect(cartItems()).toHaveLength(1)
    expect(screen.getByTestId("line-qty")).toHaveTextContent("2")
    expect(screen.getByRole("alert", { name: /stock insuficiente/i })).toBeInTheDocument()
  })

  it("el input de cantidad no supera el disponible (maxQtyMap)", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    addProduct("Huevo", "1")
    expect(cartItems()[0]).toHaveAttribute("data-max", "2")
  })

  it("cambiar de sucursal recalcula el disponible y re-valida TODAS las líneas, sin borrarlas", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    addProduct("Huevo", "2")
    addProduct("Queso", "4")
    expect(cartItems()).toHaveLength(2)

    // Norte: Huevo 10 (alcanza) y Queso 0 (no alcanza).
    selectBranch("b-2")

    expect(cartItems()).toHaveLength(2)
    const flagged = cartItems().filter((li) => within(li).queryByTestId("line-badge")?.textContent?.match(/no alcanza/i))
    expect(flagged).toHaveLength(1)
    expect(within(flagged[0]).getByText("Queso")).toBeInTheDocument()
    expect(screen.getByRole("alert", { name: /no alcanza el stock/i })).toHaveTextContent(/Norte/)

    fireEvent.click(submitBtn())
    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/no alcanza el stock de Norte/i))
    expect(mocks.createMutate).not.toHaveBeenCalled()

    // Al volver a Centro vuelve a alcanzar y se puede emitir.
    selectBranch("b-1")
    expect(screen.queryByRole("alert", { name: /no alcanza el stock/i })).not.toBeInTheDocument()
  })

  it("lector de códigos: un producto con stock en la sucursal se agrega; sin stock en la sucursal se rechaza", () => {
    stockByBranch["b-1"]["p-queso"] = 0
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    act(() => scanBurst("HUEVOBC"))
    expect(cartItems()).toHaveLength(1)
    // El agregado del catálogo dice 10 de queso, pero la sucursal tiene 0.
    act(() => scanBurst("QUESOBC"))
    expect(cartItems()).toHaveLength(1)
  })

  it("lector de códigos: la tercera unidad escaneada de un producto con 2 en la sucursal se rechaza", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    act(() => scanBurst("HUEVOBC"))
    act(() => scanBurst("HUEVOBC"))
    act(() => scanBurst("HUEVOBC"))
    expect(cartItems()).toHaveLength(1)
    expect(screen.getByTestId("line-qty")).toHaveTextContent("2")
  })

  it("etiqueta de balanza: agrega la línea con el importe de la etiqueta si hay stock en la sucursal", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    act(() => scanBurst("2002610013638")) // Tomate, PLU 261, importe $13,63
    expect(cartItems()).toHaveLength(1)
    expect(Number(screen.getByTestId("line-subtotal").textContent)).toBeCloseTo(13.63, 2)
  })

  it("etiqueta de balanza: sin stock del producto en la sucursal elegida se rechaza", () => {
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    selectBranch("b-2") // Tomate: 0 en Norte
    act(() => scanBurst("2002610013638"))
    expect(cartItems()).toHaveLength(0)
  })
})

// ── domicilio de entrega ──────────────────────────────────────────────────────

describe("DeliveryNoteForm — domicilio de entrega", () => {
  it("se precarga con el domicilio principal del cliente elegido", () => {
    addressesByClient = { "c-ana": [address()] }
    render(<DeliveryNoteForm />)
    selectClient("c-ana")
    expect(screen.getByLabelText(/domicilio de entrega/i)).toHaveValue("San Martín 100, Mendoza, Mendoza")
  })

  it("si el usuario ya lo editó, cambiar de cliente no lo pisa", () => {
    addressesByClient = {
      "c-ana": [address()],
      "c-beto": [address({ id: "ad-2", clientId: "c-beto", street: "Otra calle 9" })],
    }
    render(<DeliveryNoteForm />)
    selectClient("c-ana")
    fireEvent.change(screen.getByLabelText(/domicilio de entrega/i), { target: { value: "Lo escribí yo" } })
    selectClient("c-beto")
    expect(screen.getByLabelText(/domicilio de entrega/i)).toHaveValue("Lo escribí yo")
  })

  it("si no lo editó, cambiar de cliente lo reemplaza por el del nuevo cliente", () => {
    addressesByClient = {
      "c-ana": [address()],
      "c-beto": [address({ id: "ad-2", clientId: "c-beto", street: "Otra calle 9", city: null, province: null })],
    }
    render(<DeliveryNoteForm />)
    selectClient("c-ana")
    selectClient("c-beto")
    expect(screen.getByLabelText(/domicilio de entrega/i)).toHaveValue("Otra calle 9")
  })

  it("un cliente sin domicilios deja el campo vacío y editable", () => {
    render(<DeliveryNoteForm />)
    selectClient("c-beto")
    const field = screen.getByLabelText(/domicilio de entrega/i)
    expect(field).toHaveValue("")
    expect(field).not.toBeDisabled()
  })
})

// ── edición ───────────────────────────────────────────────────────────────────

describe("DeliveryNoteForm — edición con una sola contabilidad", () => {
  it("rehidrata cliente, sucursal, domicilio, notas y líneas, y guarda con la revision que cargó", async () => {
    stockByBranch["b-1"]["p-huevo"] = 0
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    expect((screen.getByLabelText("Cliente") as HTMLSelectElement).value).toBe("c-ana")
    expect((screen.getByLabelText("Sucursal") as HTMLSelectElement).value).toBe("b-1")
    expect(screen.getByLabelText(/domicilio de entrega/i)).toHaveValue("Calle Falsa 123")
    expect(screen.getByLabelText(/^notas/i)).toHaveValue("Entrega por la mañana")
    expect(cartItems()).toHaveLength(1)

    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.updateMutate).toHaveBeenCalledTimes(1))
    expect(mocks.updateMutate).toHaveBeenCalledWith({
      deliveryNoteId: "dn-1",
      payload: {
        revision: 3,
        client_id: "c-ana",
        branch_id: "b-1",
        delivery_address: "Calle Falsa 123",
        notes: "Entrega por la mañana",
        items: [{ product_id: "p-huevo", unit_id: "u-u", quantity: 3, price: 90, subtotal: 270 }],
      },
    })
    await waitFor(() => expect(mocks.push).toHaveBeenCalledWith("/remitos/dn-1"))
  })

  it("retenido 3 con la sucursal en 0: una línea nueva de 2 se rechaza (el disponible es 3, lo requerido 5)", () => {
    stockByBranch["b-1"]["p-huevo"] = 0
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    addProduct("Huevo", "2")
    expect(screen.getByRole("alert", { name: /stock insuficiente/i })).toHaveTextContent(/disponible: 3/i)
    expect(screen.getByTestId("line-qty")).toHaveTextContent("3")
  })

  it("el tope del input de cantidad es lo retenido más el stock de la sucursal", () => {
    stockByBranch["b-1"]["p-huevo"] = 4
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    expect(cartItems()[0]).toHaveAttribute("data-max", "7")
  })

  it("al cambiar de sucursal lo retenido deja de sumar: con 1 en la nueva, la línea de 3 ya no alcanza", () => {
    stockByBranch["b-1"]["p-huevo"] = 0
    stockByBranch["b-2"]["p-huevo"] = 1
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    expect(screen.queryByRole("alert", { name: /no alcanza el stock/i })).not.toBeInTheDocument()

    selectBranch("b-2")

    expect(cartItems()[0]).toHaveAttribute("data-max", "1")
    expect(screen.getByRole("alert", { name: /no alcanza el stock/i })).toBeInTheDocument()
    fireEvent.click(submitBtn())
    expect(mocks.updateMutate).not.toHaveBeenCalled()
  })

  it("al cambiar de sucursal con stock suficiente en la nueva se puede guardar y el payload lleva la sucursal nueva", async () => {
    stockByBranch["b-2"]["p-huevo"] = 8
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    selectBranch("b-2")
    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.updateMutate).toHaveBeenCalled())
    expect(mocks.updateMutate.mock.calls[0][0].payload.branch_id).toBe("b-2")
  })

  it("antes de guardar muestra 'Este cambio no mueve stock' si sólo cambian datos", () => {
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    expect(screen.getByRole("status", { name: /efecto en el stock/i })).toHaveTextContent("Este cambio no mueve stock")
    fireEvent.change(screen.getByLabelText(/^notas/i), { target: { value: "Otra nota" } })
    expect(screen.getByRole("status", { name: /efecto en el stock/i })).toHaveTextContent("Este cambio no mueve stock")
  })

  it("antes de guardar resume qué vuelve y qué sale cuando cambia una cantidad", () => {
    stockByBranch["b-1"]["p-huevo"] = 5
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    fireEvent.change(screen.getByLabelText("cantidad Huevo"), { target: { value: "4" } })
    const summary = screen.getByRole("status", { name: /efecto en el stock/i })
    expect(summary).toHaveTextContent("Vuelven 3 × Huevo a Centro")
    expect(summary).toHaveTextContent("Salen 4 × Huevo de Centro")
  })

  it("en la edición no dice 'Al emitir, se descuenta'", () => {
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    expect(screen.queryByText(/al emitir, se descuenta/i)).not.toBeInTheDocument()
  })

  it("delivery_note_changed: ofrece recargar sin pisar y el botón llama a onReload", async () => {
    const onReload = vi.fn()
    mocks.updateMutate.mockRejectedValue(new Error("delivery_note_changed: otra versión"))
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} onReload={onReload} />)
    fireEvent.click(submitBtn())
    const alert = await screen.findByRole("alert", { name: /remito modificado/i })
    expect(alert).toHaveTextContent(/otro usuario/i)
    fireEvent.click(within(alert).getByRole("button", { name: /recargar remito/i }))
    expect(onReload).toHaveBeenCalledTimes(1)
    expect(mocks.push).not.toHaveBeenCalled()
  })

  it("sin onReload, recargar invalida el detalle del remito", async () => {
    mocks.updateMutate.mockRejectedValue(new Error("delivery_note_changed"))
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    fireEvent.click(submitBtn())
    fireEvent.click(await screen.findByRole("button", { name: /recargar remito/i }))
    expect(mocks.invalidateQueries).toHaveBeenCalledWith({ queryKey: ["deliveryNotes", "detail", "dn-1"] })
  })
})

describe("DeliveryNoteForm — cliente dado de baja", () => {
  it("muestra el cliente congelado con el aviso y bloquea el guardado hasta elegir otro", async () => {
    render(<DeliveryNoteForm deliveryNote={deliveryNote({ client_id: "c-viejo", client_name: "Cliente Viejo", client_deleted: true })} />)
    expect(screen.getByRole("status", { name: /cliente dado de baja/i })).toHaveTextContent(
      "Cliente dado de baja — elegí uno vigente para guardar",
    )
    expect(screen.getByRole("status", { name: /cliente dado de baja/i })).toHaveTextContent(/Cliente Viejo/)

    fireEvent.click(submitBtn())
    expect(mocks.toastError).toHaveBeenCalledWith("Cliente dado de baja — elegí uno vigente para guardar.")
    expect(mocks.updateMutate).not.toHaveBeenCalled()

    selectClient("c-beto")
    expect(screen.queryByRole("status", { name: /cliente dado de baja/i })).not.toBeInTheDocument()
    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.updateMutate).toHaveBeenCalled())
    expect(mocks.updateMutate.mock.calls[0][0].payload.client_id).toBe("c-beto")
  })

  it("un cliente vivo no muestra ningún aviso", () => {
    render(<DeliveryNoteForm deliveryNote={deliveryNote()} />)
    expect(screen.queryByRole("status", { name: /cliente dado de baja/i })).not.toBeInTheDocument()
  })
})

describe("DeliveryNoteForm — producto dado de baja después de emitir", () => {
  const withDeleted = () =>
    deliveryNote({
      items: [
        itemRow({ id: "i-1" }),
        itemRow({ id: "i-2", product_id: "p-viejo", name_snapshot: "Producto viejo", quantity: "3", quantity_base: "3", line_no: 2, product_deleted: true }),
      ],
    })

  it("se muestra 'se conserva lo entregado' y NO bloquea el guardado", async () => {
    stockByBranch["b-1"]["p-huevo"] = 0
    render(<DeliveryNoteForm deliveryNote={withDeleted()} />)
    const badges = screen.getAllByTestId("line-badge").map((b) => b.textContent)
    expect(badges.some((text) => /Producto dado de baja — se conserva lo entregado/.test(text ?? ""))).toBe(true)

    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.updateMutate).toHaveBeenCalled())
    const items = mocks.updateMutate.mock.calls[0][0].payload.items as Array<{ product_id: string }>
    expect(items.map((i) => i.product_id)).toContain("p-viejo")
  })

  it("no admite aumentar la cantidad: su tope es lo que ya se entregó", () => {
    stockByBranch["b-1"]["p-viejo"] = 50
    render(<DeliveryNoteForm deliveryNote={withDeleted()} />)
    const deletedLine = cartItems().find((li) => within(li).queryByText("Producto viejo"))
    expect(deletedLine).toHaveAttribute("data-max", "3")
  })

  it("quitarla pide confirmación con lo que vuelve al stock y recién al confirmar se quita", async () => {
    render(<DeliveryNoteForm deliveryNote={withDeleted()} />)
    fireEvent.click(screen.getByRole("button", { name: "quitar Producto viejo" }))

    expect(cartItems()).toHaveLength(2)
    const dialog = await screen.findByRole("alertdialog")
    expect(dialog).toHaveTextContent("Quitarla devuelve 3 × Producto viejo al stock de Centro.")

    fireEvent.click(within(dialog).getByRole("button", { name: /quitar la línea/i }))
    await waitFor(() => expect(cartItems()).toHaveLength(1))
  })

  it("cancelar la confirmación deja la línea", async () => {
    render(<DeliveryNoteForm deliveryNote={withDeleted()} />)
    fireEvent.click(screen.getByRole("button", { name: "quitar Producto viejo" }))
    const dialog = await screen.findByRole("alertdialog")
    fireEvent.click(within(dialog).getByRole("button", { name: /cancelar/i }))
    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument())
    expect(cartItems()).toHaveLength(2)
  })

  it("quitar una línea de un producto vivo no pide confirmación", () => {
    render(<DeliveryNoteForm deliveryNote={withDeleted()} />)
    fireEvent.click(screen.getByRole("button", { name: "quitar Huevo" }))
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument()
    expect(cartItems()).toHaveLength(1)
  })
})

// ── errores del servidor ──────────────────────────────────────────────────────

describe("DeliveryNoteForm — errores del servidor", () => {
  it("stock_insuficiente del servidor se muestra accionable con el enlace a transferir stock", async () => {
    mocks.createMutate.mockRejectedValue(new Error("stock_insuficiente para producto 11111111-1111-1111-1111-111111111111"))
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    addProduct("Huevo", "1")
    fireEvent.click(submitBtn())
    const alert = await screen.findByRole("alert", { name: /stock insuficiente/i })
    expect(alert).toHaveTextContent(/sucursal del remito|remito/i)
    expect(within(alert).getByRole("link", { name: /transferir stock/i })).toHaveAttribute(
      "href",
      "/stock?product=11111111-1111-1111-1111-111111111111",
    )
    expect(mocks.push).not.toHaveBeenCalled()
  })

  it("otro error se muestra traducido en un aviso y no navega", async () => {
    mocks.createMutate.mockRejectedValue(new Error("delivery_note_branch_inactive"))
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    addProduct("Huevo", "1")
    fireEvent.click(submitBtn())
    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.push).not.toHaveBeenCalled()
  })

  it("un doble clic sobre Emitir manda una sola vez", async () => {
    let resolve: (value: unknown) => void = () => undefined
    mocks.createMutate.mockReturnValue(new Promise((r) => { resolve = r }))
    render(<DeliveryNoteForm initialClientId="c-ana" />)
    addProduct("Huevo", "1")
    const button = submitBtn()
    fireEvent.click(button)
    fireEvent.click(button)
    expect(mocks.createMutate).toHaveBeenCalledTimes(1)
    await act(async () => resolve({ id: "dn-new" }))
  })
})
