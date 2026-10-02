/**
 * presupuestos-modulo (D9/D10, tarea 5.8) — `/presupuestos/[id]`: detalle.
 *
 * Invariantes bajo test:
 *  - acciones por estado y rol (tabla de D10), decididas con `hasCapability`;
 *  - `DocumentShareMenu` con `onShared` -> `send` SOLO si el usuario tiene
 *    `CAN_QUOTE` y el presupuesto está en `draft`; su falla no muestra error; un
 *    cajero descarga y el estado no cambia;
 *  - "Marcar como enviado", "Rechazar" (motivo opcional), "Duplicar",
 *    "Eliminar" con confirmación sólo en un `draft` nunca enviado;
 *  - "Modificado después de enviado", historial, precio de lista de hoy;
 *  - "Venta" (tanda B): habilitada en draft/sent vigentes con CAN_QUOTE, abre el
 *    diálogo de conversión; deshabilitada y explicada si está vencido; ausente
 *    sin permiso o fuera de draft/sent;
 *  - "Venta generada" (accepted): enlace a la orden, estado de su comprobante y,
 *    si la orden se canceló, "La venta generada fue eliminada" (OQ-P12);
 *  - accesibilidad: avisos en `aria-live`, retorno del foco al cerrar los modales.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within, act } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import type { QuoteApiRow, QuoteItemApiRow } from "@/lib/quote-types"
import type { Product, UnitOfMeasure } from "@/lib/types"

const mocks = vi.hoisted(() => ({
  params: { id: "q-1" },
  push: vi.fn(),
  useQuote: vi.fn(),
  transition: vi.fn(),
  deleteQuote: vi.fn(),
  useOrgRole: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
  shareProps: vi.fn(),
  fetchQuotePdf: vi.fn(),
  useSalesOrder: vi.fn(),
  convertDialog: vi.fn(),
}))

const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const REMERA: Product = {
  id: "p-remera", name: "Remera", category: "Ropa", cost: null, price: 1500, margin: null, stock: 5,
  minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-u",
}

vi.mock("next/navigation", () => ({
  useParams: () => mocks.params,
  useRouter: () => ({ push: mocks.push }),
}))
vi.mock("sonner", () => ({ toast: { error: mocks.toastError, success: mocks.toastSuccess, info: vi.fn() } }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { businessName: "Negocio propio del vendedor" } }) }))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [REMERA], isLoading: false }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [U], unitsById: new Map([[U.id, U]]), loading: false, error: null }),
}))
vi.mock("@/hooks/data/use-quotes", () => ({
  useQuote: (id: string) => mocks.useQuote(id),
  useTransitionQuote: () => ({ mutateAsync: mocks.transition, isPending: false }),
  useDeleteQuote: () => ({ mutateAsync: mocks.deleteQuote, isPending: false }),
  fetchQuotePdf: (...args: unknown[]) => mocks.fetchQuotePdf(...args),
}))
vi.mock("@/hooks/data/use-sales-orders", () => ({
  useSalesOrder: (id: string | null) => mocks.useSalesOrder(id),
}))
vi.mock("@/components/fiscal/FiscalInvoiceSummary", () => ({
  FiscalInvoiceSummary: ({ fiscal }: { fiscal: { label: string | null; status: string } }) => (
    <p data-testid="fiscal-summary">
      {fiscal.status} {fiscal.label}
    </p>
  ),
}))
vi.mock("@/components/quotes/ConvertQuoteDialog", () => ({
  ConvertQuoteDialog: (props: { quote: { id: string }; open: boolean; onOpenChange: (open: boolean) => void }) => {
    mocks.convertDialog(props)
    return props.open ? (
      <div role="dialog" aria-label="Pasar a venta (mock)">
        <button type="button" onClick={() => props.onOpenChange(false)}>
          Cerrar diálogo (mock)
        </button>
      </div>
    ) : null
  },
}))
vi.mock("@/components/shared/DocumentShareMenu", () => ({
  DocumentShareMenu: (props: {
    fileName: string
    shareText: string
    shareTitle: string
    clientPhone?: string | null
    onShared?: () => void
  }) => {
    mocks.shareProps(props)
    return (
      <button type="button" onClick={() => props.onShared?.()}>
        Compartir (mock)
      </button>
    )
  },
}))

import QuoteDetailPage from "@/app/(dashboard)/presupuestos/[id]/page"

function line(overrides: Partial<QuoteItemApiRow> & { id: string }): QuoteItemApiRow {
  return {
    quote_id: "q-1",
    product_id: "p-remera",
    unit_id: "u-u",
    unit_symbol: "u",
    quantity: "2.0000",
    price: "1500",
    subtotal: "3000",
    name_snapshot: "Remera",
    sku_snapshot: null,
    line_no: 1,
    ...overrides,
  }
}

function quote(overrides: Partial<QuoteApiRow> = {}): QuoteApiRow {
  return {
    id: "q-1",
    number: 12,
    number_label: "P-00000012",
    status: "draft",
    revision: 1,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: "2615551234",
    branch_id: null,
    valid_until: "2999-10-16",
    notes: "Entrega en 48 hs",
    total: "3000.00",
    sent_at: null,
    created_at: "2026-10-01T15:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    is_expired: false,
    sales_order_id: null,
    issuer_name: "Kiosco Lola",
    items: [line({ id: "i-1" })],
    history: [
      { from_status: null, to_status: "draft", performed_by: "u-1", occurred_at: "2026-10-01T15:00:00Z", reason: null },
    ],
    ...overrides,
  }
}

function setQuote(q: QuoteApiRow) {
  mocks.useQuote.mockReturnValue({ data: q, isLoading: false, isError: false })
}

function asRoles(roles: string[], resolved = true) {
  mocks.useOrgRole.mockReturnValue({ role: roles[0], roles, rolesResolved: resolved, isWriter: true, isLoading: false })
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.params = { id: "q-1" }
  asRoles(["owner"])
  setQuote(quote())
  mocks.transition.mockResolvedValue(quote({ status: "sent" }))
  mocks.deleteQuote.mockResolvedValue(undefined)
  mocks.useSalesOrder.mockReturnValue({ data: undefined, isLoading: false, isError: false })
})

describe("QuoteDetailPage — cabecera y contenido", () => {
  it("muestra número, estado, cliente (con enlace a su ficha) y teléfono", () => {
    render(<QuoteDetailPage />)

    expect(screen.getByRole("heading", { name: /P-00000012/ })).toBeInTheDocument()
    expect(document.querySelector('[data-status="draft"]')).toHaveTextContent("Borrador")
    expect(screen.getByRole("link", { name: "Ana Pérez" })).toHaveAttribute("href", "/clientes/c-1")
    expect(screen.getByText(/2615551234/)).toBeInTheDocument()
  })

  it("lista las líneas en sólo lectura con cantidad, unidad, precio y subtotal, y el total", () => {
    render(<QuoteDetailPage />)

    const table = screen.getByRole("table", { name: /líneas del presupuesto/i })
    expect(within(table).getByText("Remera")).toBeInTheDocument()
    expect(within(table).getByText(/2\s*u/)).toBeInTheDocument()
    expect(table).toHaveTextContent(/1\.500/)
    expect(screen.getByTestId("quote-total")).toHaveTextContent(/3\.000/)
  })

  it("muestra las notas", () => {
    render(<QuoteDetailPage />)

    expect(screen.getByText("Entrega en 48 hs")).toBeInTheDocument()
  })

  it("una línea de servicio muestra su descripción (sin producto)", () => {
    setQuote(quote({ items: [line({ id: "i-2", product_id: null, unit_id: null, unit_symbol: null, name_snapshot: "Flete" })] }))
    render(<QuoteDetailPage />)

    expect(screen.getByText("Flete")).toBeInTheDocument()
  })

  it("el precio de lista de hoy aparece, sólo informativo, cuando difiere del cotizado", () => {
    setQuote(quote({ items: [line({ id: "i-1", price: "1000", subtotal: "2000" })] }))
    render(<QuoteDetailPage />)

    expect(screen.getByText(/lista hoy/i)).toHaveTextContent(/1\.500/)
  })

  it("si el precio cotizado coincide con el de lista no muestra nada", () => {
    render(<QuoteDetailPage />)

    expect(screen.queryByText(/lista hoy/i)).not.toBeInTheDocument()
  })

  it("muestra el historial de estados con su motivo", () => {
    setQuote(
      quote({
        status: "rejected",
        history: [
          { from_status: null, to_status: "draft", performed_by: "u-1", occurred_at: "2026-10-01T15:00:00Z", reason: null },
          { from_status: "draft", to_status: "rejected", performed_by: "u-1", occurred_at: "2026-10-02T15:00:00Z", reason: "Muy caro" },
        ],
      }),
    )
    render(<QuoteDetailPage />)

    const history = screen.getByRole("list", { name: /historial/i })
    expect(within(history).getAllByRole("listitem")).toHaveLength(2)
    expect(history).toHaveTextContent(/rechazado/i)
    expect(history).toHaveTextContent("Muy caro")
  })

  it("'Modificado después de enviado' sólo si se editó tras el envío", () => {
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z", updated_at: "2026-10-02T09:00:00Z" }))
    const { unmount } = render(<QuoteDetailPage />)
    expect(screen.getByRole("status", { name: /modificado/i })).toHaveTextContent(/reenvialo/i)
    unmount()

    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z", updated_at: null }))
    render(<QuoteDetailPage />)
    expect(screen.queryByText(/modificado después de enviado/i)).not.toBeInTheDocument()
  })

  it("un enviado vencido avisa el vencimiento y propone editar o duplicar", () => {
    setQuote(quote({ status: "sent", is_expired: true, valid_until: "2026-09-20", sent_at: "2026-09-10T12:00:00Z" }))
    render(<QuoteDetailPage />)

    const notice = screen.getByRole("status", { name: /vencido/i })
    expect(notice).toHaveTextContent(/20\/09\/2026/)
    expect(notice).toHaveTextContent(/editalo para ampliar la validez o duplicalo/i)
    expect(screen.getByText("Vencido")).toBeInTheDocument() // el badge muestra el estado derivado
  })

  it("accepted con orden generada: 'Venta generada' con enlace a la orden", () => {
    setQuote(quote({ status: "accepted", sales_order_id: "so-9", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    const region = screen.getByRole("region", { name: /venta generada/i })
    expect(within(region).getByRole("link", { name: /ver venta/i })).toHaveAttribute("href", "/ventas/ordenes/so-9")
  })

  it("mientras carga muestra un aviso, y si falla ofrece volver al listado", () => {
    mocks.useQuote.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    const { unmount } = render(<QuoteDetailPage />)
    expect(screen.getByText(/cargando presupuesto/i)).toBeInTheDocument()
    unmount()

    mocks.useQuote.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<QuoteDetailPage />)
    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudo cargar/i)
    expect(screen.getByRole("link", { name: /volver a presupuestos/i })).toHaveAttribute("href", "/presupuestos")
  })
})

describe("QuoteDetailPage — tabla de líneas en móvil (hallazgo de la pasada visual 7.3)", () => {
  // A 375 px la tabla tenía `min-w-[480px]` dentro de un contenedor con scroll
  // horizontal: "Precio unit." y "Subtotal" quedaban escondidos detrás del scroll.
  // Sin ancho mínimo y con relleno corto en móvil, las cuatro columnas entran en
  // la tarjeta (el contenedor con scroll queda sólo como red de seguridad para
  // importes enormes).
  it("la tabla no fuerza un ancho mínimo y usa relleno corto en móvil", () => {
    render(<QuoteDetailPage />)
    const table = screen.getByRole("table", { name: /líneas del presupuesto/i })

    expect(table.className).not.toMatch(/min-w-\[/)
    const cells = Array.from(table.querySelectorAll("th, td"))
    expect(cells.length).toBeGreaterThan(0)
    for (const cell of cells) {
      expect(cell.className).toMatch(/\bpx-2\b/)
      expect(cell.className).toMatch(/\bsm:px-4\b/)
    }
  })

  it("las cuatro columnas siguen presentes (Descripción, Cant., Precio unit., Subtotal)", () => {
    render(<QuoteDetailPage />)
    const table = screen.getByRole("table", { name: /líneas del presupuesto/i })

    const headers = within(table).getAllByRole("columnheader").map((h) => h.textContent)
    expect(headers).toEqual(["Descripción", "Cant.", "Precio unit.", "Subtotal"])
  })
})

describe("QuoteDetailPage — acciones por estado y rol (D10)", () => {
  const has = (name: RegExp) =>
    screen.queryAllByRole("button", { name }).length + screen.queryAllByRole("link", { name }).length > 0

  it("draft nunca enviado, owner: Editar, Compartir, Venta, Marcar como enviado, Rechazar, Duplicar y Eliminar", () => {
    render(<QuoteDetailPage />)

    expect(screen.getByRole("link", { name: /^editar$/i })).toHaveAttribute("href", "/presupuestos/q-1/editar")
    expect(screen.getByRole("button", { name: /compartir/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /^venta$/i })).toBeInTheDocument()
    expect(has(/marcar como enviado/i)).toBe(true)
    expect(has(/rechazar/i)).toBe(true)
    expect(screen.getByRole("link", { name: /duplicar/i })).toHaveAttribute("href", "/presupuestos/nuevo?duplicar=q-1")
    expect(has(/eliminar/i)).toBe(true)
  })

  it("sent: sin Eliminar ni Marcar como enviado", () => {
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    expect(has(/eliminar/i)).toBe(false)
    expect(has(/marcar como enviado/i)).toBe(false)
    expect(has(/rechazar/i)).toBe(true)
    expect(has(/^editar$/i)).toBe(true)
  })

  it("draft reabierto (ya salió una vez): no se elimina", () => {
    setQuote(quote({ status: "draft", sent_at: "2026-09-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    expect(has(/eliminar/i)).toBe(false)
  })

  it.each(["expired", "rejected"] as const)("%s: Editar (reabre), Compartir y Duplicar; sin Venta ni Rechazar", (status) => {
    setQuote(quote({ status, sent_at: "2026-09-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    expect(has(/^editar$/i)).toBe(true)
    expect(has(/compartir/i)).toBe(true)
    expect(has(/duplicar/i)).toBe(true)
    expect(has(/^venta$/i)).toBe(false)
    expect(has(/rechazar/i)).toBe(false)
  })

  it("accepted: sólo Compartir y Duplicar (y ver la venta); no se edita", () => {
    setQuote(quote({ status: "accepted", sales_order_id: "so-9", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    expect(has(/^editar$/i)).toBe(false)
    expect(has(/rechazar/i)).toBe(false)
    expect(has(/eliminar/i)).toBe(false)
    expect(has(/compartir/i)).toBe(true)
    expect(has(/duplicar/i)).toBe(true)
  })

  it("un usuario sólo cashier descarga y comparte, pero no ve ninguna acción de escritura", () => {
    asRoles(["cashier"])
    render(<QuoteDetailPage />)

    expect(has(/compartir/i)).toBe(true)
    for (const name of [/^editar$/i, /^venta$/i, /marcar como enviado/i, /rechazar/i, /duplicar/i, /eliminar/i]) {
      expect(has(name)).toBe(false)
    }
  })

  it("un usuario sólo seller tiene todas las acciones del dueño", () => {
    asRoles(["seller"])
    render(<QuoteDetailPage />)

    expect(has(/^editar$/i)).toBe(true)
    expect(has(/rechazar/i)).toBe(true)
    expect(has(/eliminar/i)).toBe(true)
  })

  it("'Venta' está HABILITADA en un presupuesto vigente y ya no promete 'la próxima entrega'", () => {
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    expect(screen.getByRole("button", { name: /^venta$/i })).toBeEnabled()
    expect(screen.queryByText(/próxima entrega/i)).not.toBeInTheDocument()
  })

  it("'Venta' abre el diálogo de conversión con ESTE presupuesto, y se cierra", () => {
    render(<QuoteDetailPage />)
    expect(screen.queryByRole("dialog", { name: /pasar a venta/i })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /^venta$/i }))
    const dialog = screen.getByRole("dialog", { name: /pasar a venta/i })
    expect(mocks.convertDialog).toHaveBeenLastCalledWith(
      expect.objectContaining({ open: true, quote: expect.objectContaining({ id: "q-1" }) }),
    )

    fireEvent.click(within(dialog).getByRole("button", { name: /cerrar diálogo/i }))
    expect(screen.queryByRole("dialog", { name: /pasar a venta/i })).not.toBeInTheDocument()
  })

  it("'Venta' en un vencido queda deshabilitada y se explica por el vencimiento", () => {
    setQuote(quote({ status: "sent", is_expired: true, valid_until: "2026-09-20", sent_at: "2026-09-10T12:00:00Z" }))
    render(<QuoteDetailPage />)

    const sale = screen.getByRole("button", { name: /^venta$/i })
    expect(sale).toBeDisabled()
    expect(sale).toHaveAccessibleDescription(/vencido el 20\/09\/2026/i)
    fireEvent.click(sale)
    expect(screen.queryByRole("dialog", { name: /pasar a venta/i })).not.toBeInTheDocument()
  })

  it("sin permiso (cashier) no hay 'Venta' ni diálogo", () => {
    asRoles(["cashier"])
    render(<QuoteDetailPage />)

    expect(screen.queryByRole("button", { name: /^venta$/i })).not.toBeInTheDocument()
    expect(mocks.convertDialog).not.toHaveBeenCalled()
  })
})

describe("QuoteDetailPage — 'Venta generada' (presupuesto convertido)", () => {
  function accepted() {
    setQuote(quote({ status: "accepted", sales_order_id: "so-9", sent_at: "2026-10-01T16:00:00Z" }))
  }
  const order = (overrides: Record<string, unknown> = {}) => ({
    id: "so-9",
    status: "confirmed",
    fiscal_document_id: null,
    ...overrides,
  })

  it("consulta la orden generada y enlaza a ella", () => {
    accepted()
    mocks.useSalesOrder.mockReturnValue({ data: order(), isLoading: false, isError: false })
    render(<QuoteDetailPage />)

    expect(mocks.useSalesOrder).toHaveBeenCalledWith("so-9")
    const region = screen.getByRole("region", { name: /venta generada/i })
    expect(within(region).getByRole("link", { name: /ver venta/i })).toHaveAttribute("href", "/ventas/ordenes/so-9")
  })

  it("un presupuesto abierto no consulta ninguna orden", () => {
    render(<QuoteDetailPage />)
    expect(mocks.useSalesOrder).toHaveBeenCalledWith(null)
  })

  it("sin comprobante: lo dice", () => {
    accepted()
    mocks.useSalesOrder.mockReturnValue({ data: order(), isLoading: false, isError: false })
    render(<QuoteDetailPage />)

    expect(within(screen.getByRole("region", { name: /venta generada/i })).getByText(/sin comprobante/i)).toBeInTheDocument()
  })

  it("con comprobante: muestra su estado y número", () => {
    accepted()
    mocks.useSalesOrder.mockReturnValue({
      data: order({
        fiscal_document_id: "fd-1",
        fiscal_document_status: "authorized",
        fiscal_punto_de_venta: 3,
        fiscal_number: 501,
      }),
      isLoading: false,
      isError: false,
    })
    render(<QuoteDetailPage />)

    expect(screen.getByTestId("fiscal-summary")).toHaveTextContent("authorized 0003-00000501")
  })

  it("si la orden fue cancelada: 'La venta generada fue eliminada', sin enlace a la orden", () => {
    accepted()
    mocks.useSalesOrder.mockReturnValue({ data: order({ status: "canceled" }), isLoading: false, isError: false })
    render(<QuoteDetailPage />)

    const region = screen.getByRole("region", { name: /venta generada/i })
    expect(within(region).getByText(/la venta generada fue eliminada/i)).toBeInTheDocument()
    expect(within(region).getByText(/duplicá el presupuesto/i)).toBeInTheDocument()
    expect(within(region).queryByRole("link", { name: /ver venta/i })).not.toBeInTheDocument()
    expect(within(region).queryByText(/sin comprobante/i)).not.toBeInTheDocument()
  })

  it("si la orden no se pudo leer, igual muestra la venta generada con su enlace", () => {
    accepted()
    mocks.useSalesOrder.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<QuoteDetailPage />)

    const region = screen.getByRole("region", { name: /venta generada/i })
    expect(within(region).getByRole("link", { name: /ver venta/i })).toBeInTheDocument()
    expect(within(region).queryByText(/sin comprobante/i)).not.toBeInTheDocument()
  })
})

describe("QuoteDetailPage — compartir marca como enviado", () => {
  it("el menú recibe el nombre del archivo, el texto con el nombre y el total, y el teléfono", () => {
    render(<QuoteDetailPage />)

    const props = mocks.shareProps.mock.calls[0][0]
    expect(props.fileName).toBe("presupuesto-P-00000012.pdf")
    expect(props.clientPhone).toBe("2615551234")
    expect(props.shareText).toContain("Ana Pérez")
    expect(props.shareText).toContain("P-00000012")
    expect(props.shareText).toContain("Kiosco Lola")
    expect(props.shareText).toMatch(/3\.000/)
  })

  it("firma con el emisor del PDF (issuer_name), no con el negocio del perfil de quien comparte", () => {
    setQuote(quote({ issuer_name: "Sumar" }))
    render(<QuoteDetailPage />)

    const text = mocks.shareProps.mock.calls[0][0].shareText as string
    expect(text.endsWith("Sumar")).toBe(true)
    expect(text).not.toContain("Negocio propio del vendedor")
  })

  it("sin emisor resuelto el texto sale sin firma (no cae al perfil del usuario)", () => {
    setQuote(quote({ issuer_name: null }))
    render(<QuoteDetailPage />)

    const text = mocks.shareProps.mock.calls[0][0].shareText as string
    expect(text).not.toContain("Negocio propio del vendedor")
    expect(text.endsWith("válido hasta el 16/10/2999.")).toBe(true)
  })

  it("un draft con permiso: al compartir pasa a 'enviado' (send) sin mostrar error", async () => {
    render(<QuoteDetailPage />)

    fireEvent.click(screen.getByRole("button", { name: /compartir \(mock\)/i }))

    await waitFor(() => expect(mocks.transition).toHaveBeenCalledWith({ quoteId: "q-1", action: "send" }))
    expect(mocks.toastError).not.toHaveBeenCalled()
  })

  it("si marcar como enviado falla, NO muestra error (la descarga ya funcionó)", async () => {
    mocks.transition.mockRejectedValue(new Error("boom"))
    render(<QuoteDetailPage />)

    fireEvent.click(screen.getByRole("button", { name: /compartir \(mock\)/i }))

    await waitFor(() => expect(mocks.transition).toHaveBeenCalled())
    expect(mocks.toastError).not.toHaveBeenCalled()
  })

  it("un cajero comparte y el estado NO cambia: el menú no recibe onShared", () => {
    asRoles(["cashier"])
    render(<QuoteDetailPage />)

    expect(mocks.shareProps.mock.calls[0][0].onShared).toBeUndefined()
    fireEvent.click(screen.getByRole("button", { name: /compartir \(mock\)/i }))
    expect(mocks.transition).not.toHaveBeenCalled()
  })

  it("un presupuesto ya enviado no vuelve a marcarse: el menú no recibe onShared", () => {
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    expect(mocks.shareProps.mock.calls[0][0].onShared).toBeUndefined()
  })

  it("un usuario con permiso sobre un draft ve el menú con onShared", () => {
    render(<QuoteDetailPage />)

    expect(typeof mocks.shareProps.mock.calls[0][0].onShared).toBe("function")
  })

  it("al marcarse como enviado se anuncia en una región aria-live", async () => {
    render(<QuoteDetailPage />)

    fireEvent.click(screen.getByRole("button", { name: /compartir \(mock\)/i }))

    const live = await screen.findByRole("status", { name: /aviso de envío/i })
    expect(live).toHaveAttribute("aria-live", "polite")
    await waitFor(() => expect(live).toHaveTextContent(/marcado como enviado/i))
  })

  it("'Marcar como enviado' dispara send y avisa", async () => {
    render(<QuoteDetailPage />)

    fireEvent.click(screen.getByRole("button", { name: /marcar como enviado/i }))

    await waitFor(() => expect(mocks.transition).toHaveBeenCalledWith({ quoteId: "q-1", action: "send" }))
    expect(mocks.toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/enviado/i))
  })

  it("si 'Marcar como enviado' falla, sí avisa con un mensaje traducido", async () => {
    mocks.transition.mockRejectedValue(new Error("quote_invalid_state"))
    render(<QuoteDetailPage />)

    fireEvent.click(screen.getByRole("button", { name: /marcar como enviado/i }))

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.toastError.mock.calls[0][0]).not.toBe("quote_invalid_state")
  })

  it("la función que baja el PDF pide el presupuesto por su id", async () => {
    render(<QuoteDetailPage />)

    const props = mocks.shareProps.mock.calls[0][0] as { fetchPdf: (d: "inline" | "attachment") => Promise<unknown> }
    mocks.fetchQuotePdf.mockResolvedValue(null)
    await props.fetchPdf("attachment")

    expect(mocks.fetchQuotePdf).toHaveBeenCalledWith("q-1", "attachment")
  })
})

describe("QuoteDetailPage — rechazar", () => {
  it("abre el diálogo, manda el motivo recortado, cierra y devuelve el foco al botón", async () => {
    const user = userEvent.setup()
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    const opener = screen.getByRole("button", { name: /^rechazar$/i })
    await user.click(opener)
    const dialog = await screen.findByRole("dialog", { name: /rechazar presupuesto/i })
    const reason = within(dialog).getByLabelText(/motivo/i)
    await waitFor(() => expect(reason).toHaveFocus()) // foco inicial en el campo
    await user.type(reason, "  Muy caro  ")
    await user.click(within(dialog).getByRole("button", { name: /rechazar presupuesto/i }))

    await waitFor(() =>
      expect(mocks.transition).toHaveBeenCalledWith({ quoteId: "q-1", action: "reject", reason: "Muy caro" }),
    )
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    await waitFor(() => expect(opener).toHaveFocus())
  })

  it("el motivo es opcional: sin escribir nada manda reject sin motivo", async () => {
    const user = userEvent.setup()
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    await user.click(screen.getByRole("button", { name: /^rechazar$/i }))
    const dialog = await screen.findByRole("dialog", { name: /rechazar presupuesto/i })
    await user.click(within(dialog).getByRole("button", { name: /rechazar presupuesto/i }))

    await waitFor(() => expect(mocks.transition).toHaveBeenCalledWith({ quoteId: "q-1", action: "reject", reason: undefined }))
  })

  it("cancelar cierra sin rechazar y devuelve el foco", async () => {
    const user = userEvent.setup()
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    const opener = screen.getByRole("button", { name: /^rechazar$/i })
    await user.click(opener)
    const dialog = await screen.findByRole("dialog", { name: /rechazar presupuesto/i })
    await user.click(within(dialog).getByRole("button", { name: /cancelar/i }))

    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    expect(mocks.transition).not.toHaveBeenCalled()
    await waitFor(() => expect(opener).toHaveFocus())
  })

  it("si el rechazo falla muestra el error traducido y deja el diálogo abierto", async () => {
    const user = userEvent.setup()
    mocks.transition.mockRejectedValue(new Error("quote_invalid_state"))
    setQuote(quote({ status: "sent", sent_at: "2026-10-01T16:00:00Z" }))
    render(<QuoteDetailPage />)

    await user.click(screen.getByRole("button", { name: /^rechazar$/i }))
    const dialog = await screen.findByRole("dialog", { name: /rechazar presupuesto/i })
    await user.click(within(dialog).getByRole("button", { name: /rechazar presupuesto/i }))

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(screen.getByRole("dialog", { name: /rechazar presupuesto/i })).toBeInTheDocument()
  })
})

describe("QuoteDetailPage — eliminar", () => {
  it("pide confirmación, elimina y vuelve al listado", async () => {
    const user = userEvent.setup()
    render(<QuoteDetailPage />)

    await user.click(screen.getByRole("button", { name: /eliminar/i }))
    const dialog = await screen.findByRole("alertdialog")
    expect(dialog).toHaveTextContent(/P-00000012/)
    expect(mocks.deleteQuote).not.toHaveBeenCalled() // todavía no: falta confirmar

    await user.click(within(dialog).getByRole("button", { name: /^eliminar$/i }))

    await waitFor(() => expect(mocks.deleteQuote).toHaveBeenCalledWith("q-1"))
    await waitFor(() => expect(mocks.push).toHaveBeenCalledWith("/presupuestos"))
  })

  // Hallazgo de la pasada visual (7.3): con el detalle todavía montado, el hook
  // borraba la entrada de caché y el observador la reconstruía y volvía a pedir
  // GET /quotes/<id> -> 404 en consola (y, si llegaba antes que la navegación,
  // el cartel de "no se pudo cargar"). Una vez eliminado, la pantalla deja de
  // observar ese presupuesto.
  it("tras eliminar deja de observar el detalle: no vuelve a pedir un presupuesto que ya no existe", async () => {
    const user = userEvent.setup()
    render(<QuoteDetailPage />)
    expect(mocks.useQuote).toHaveBeenLastCalledWith("q-1")

    await user.click(screen.getByRole("button", { name: /eliminar/i }))
    const dialog = await screen.findByRole("alertdialog")
    await user.click(within(dialog).getByRole("button", { name: /^eliminar$/i }))

    await waitFor(() => expect(mocks.push).toHaveBeenCalledWith("/presupuestos"))
    expect(mocks.useQuote).toHaveBeenLastCalledWith(null)
  })

  it("si la eliminación falla sigue observando el detalle (el presupuesto existe)", async () => {
    const user = userEvent.setup()
    mocks.deleteQuote.mockRejectedValue(new Error("quote_not_deletable"))
    render(<QuoteDetailPage />)

    await user.click(screen.getByRole("button", { name: /eliminar/i }))
    const dialog = await screen.findByRole("alertdialog")
    await user.click(within(dialog).getByRole("button", { name: /^eliminar$/i }))

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.useQuote).toHaveBeenLastCalledWith("q-1")
  })

  it("cancelar no elimina y devuelve el foco al botón Eliminar", async () => {
    const user = userEvent.setup()
    render(<QuoteDetailPage />)

    const opener = screen.getByRole("button", { name: /eliminar/i })
    await user.click(opener)
    const dialog = await screen.findByRole("alertdialog")
    await user.click(within(dialog).getByRole("button", { name: /cancelar/i }))

    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument())
    expect(mocks.deleteQuote).not.toHaveBeenCalled()
    await waitFor(() => expect(opener).toHaveFocus())
  })

  it("si el servidor lo rechaza (ya se había enviado) muestra el motivo y no navega", async () => {
    const user = userEvent.setup()
    mocks.deleteQuote.mockRejectedValue(new Error("quote_not_deletable"))
    render(<QuoteDetailPage />)

    await user.click(screen.getByRole("button", { name: /eliminar/i }))
    const dialog = await screen.findByRole("alertdialog")
    await user.click(within(dialog).getByRole("button", { name: /^eliminar$/i }))

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.toastError.mock.calls[0][0]).not.toBe("quote_not_deletable")
    expect(mocks.push).not.toHaveBeenCalled()
  })
})
