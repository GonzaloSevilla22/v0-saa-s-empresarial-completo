/**
 * remitos-venta (D11, tarea 5.6) — `/remitos/[id]`: detalle.
 *
 * Invariantes bajo test:
 *  - cabecera: número, estado, cliente (enlace), sucursal de origen, fecha,
 *    domicilio y "Modificado el …" sólo con `revision > 1`;
 *  - acciones por estado y rol (matriz de D11), decididas con `hasCapability`
 *    sobre el CONJUNTO de roles; "Venta" (tanda B, `CAN_SELL`) sólo en un remito
 *    pendiente: abre `ConvertDeliveryNoteDialog`, se deshabilita explicando el
 *    motivo si el cliente fue dado de baja y el diálogo sigue montado mientras
 *    está abierto aunque el remito pase a convertido;
 *  - `DocumentShareMenu` con el switch "Mostrar precios" (apagado por defecto)
 *    FUERA del desplegable y con su Label; el menú se monta con `key={showPrices}`
 *    para descartar la precarga: cambiar el switch y enviar comparte la variante
 *    elegida;
 *  - remito convertido: "Venta generada", enlace a la orden, leyenda de eliminar
 *    la venta o de nota de crédito si la venta está facturada (D9);
 *  - historial con el motivo de la anulación; "Anular" abre el diálogo.
 */
import React, { useEffect } from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { DeliveryNoteApiRow, DeliveryNoteItemApiRow } from "@/lib/delivery-note-types"

const mocks = vi.hoisted(() => ({
  params: { id: "dn-1" },
  useDeliveryNote: vi.fn(),
  useOrgRole: vi.fn(),
  useSalesOrder: vi.fn(),
  fetchPdf: vi.fn(),
  shareMounts: vi.fn(),
  shareProps: vi.fn(),
  cancelDialog: vi.fn(),
  convertDialog: vi.fn(),
}))

vi.mock("next/navigation", () => ({
  useParams: () => mocks.params,
  useRouter: () => ({ push: vi.fn() }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))
vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useDeliveryNote: (id: string | null) => mocks.useDeliveryNote(id),
  fetchDeliveryNotePdf: (...args: unknown[]) => mocks.fetchPdf(...args),
}))
vi.mock("@/hooks/data/use-sales-orders", () => ({ useSalesOrder: (id: string | null) => mocks.useSalesOrder(id) }))
vi.mock("@/components/fiscal/FiscalInvoiceSummary", () => ({
  FiscalInvoiceSummary: ({ fiscal }: { fiscal: { label: string | null; status: string } }) => (
    <p data-testid="fiscal-summary">
      {fiscal.status} {fiscal.label}
    </p>
  ),
}))
vi.mock("@/components/shared/DocumentShareMenu", () => ({
  DocumentShareMenu: (props: {
    fetchPdf: (disposition: "inline" | "attachment") => Promise<Blob | null>
    fileName: string
    shareText: string
    shareTitle: string
    clientPhone?: string | null
    onShared?: () => void
  }) => {
    useEffect(() => {
      mocks.shareMounts()
    }, [])
    mocks.shareProps(props)
    return (
      <div role="group" aria-label="Menú de compartir (mock)">
        <button type="button" onClick={() => void props.fetchPdf("attachment")}>
          Descargar (mock)
        </button>
        <span data-testid="share-file">{props.fileName}</span>
        <span data-testid="share-text">{props.shareText}</span>
        <span data-testid="share-phone">{props.clientPhone ?? ""}</span>
        <span data-testid="share-has-on-shared">{props.onShared ? "si" : "no"}</span>
      </div>
    )
  },
}))
vi.mock("@/components/delivery-notes/CancelDeliveryNoteDialog", () => ({
  CancelDeliveryNoteDialog: (props: { deliveryNote: { id: string }; open: boolean; onOpenChange: (open: boolean) => void }) => {
    mocks.cancelDialog(props)
    return props.open ? (
      <div role="dialog" aria-label="Anular remito (mock)">
        <button type="button" onClick={() => props.onOpenChange(false)}>
          cerrar anulación
        </button>
      </div>
    ) : null
  },
}))

vi.mock("@/components/delivery-notes/ConvertDeliveryNoteDialog", () => ({
  ConvertDeliveryNoteDialog: (props: {
    deliveryNote: { id: string; status: string }
    open: boolean
    onOpenChange: (open: boolean) => void
  }) => {
    mocks.convertDialog(props)
    return props.open ? (
      <div role="dialog" aria-label="Pasar a venta (mock)">
        <span data-testid="convert-dialog-note-status">{props.deliveryNote.status}</span>
        <button type="button" onClick={() => props.onOpenChange(false)}>
          cerrar venta
        </button>
      </div>
    ) : null
  },
}))

import DeliveryNoteDetailPage from "@/app/(dashboard)/remitos/[id]/page"

function item(overrides: Partial<DeliveryNoteItemApiRow> & { id: string }): DeliveryNoteItemApiRow {
  return {
    delivery_note_id: "dn-1",
    product_id: "p-1",
    unit_id: "u-u",
    unit_symbol: "u",
    quantity: "3.0000",
    price: "1500.0000",
    subtotal: "4500.0000",
    quantity_base: "3.0000",
    name_snapshot: "Remera",
    sku_snapshot: null,
    unit_cost_snapshot: null,
    iva_rate_snapshot: null,
    line_no: 1,
    ...overrides,
  }
}

function note(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return {
    id: "dn-1",
    direction: "sale",
    number: 12,
    number_label: "R-00000012",
    status: "issued",
    revision: 1,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: "2615551234",
    client_deleted: false,
    branch_id: "b-1",
    branch_name: "Sucursal Centro",
    issued_on: "2026-10-02",
    delivery_address: "San Martín 100, Mendoza",
    notes: null,
    total: "4500.0000",
    created_at: "2026-10-02T15:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    issuer_name: "Kiosco Lola",
    items: [item({ id: "i-1" })],
    history: [{ from_status: null, to_status: "issued", performed_by: "u-1", occurred_at: "2026-10-02T15:00:00Z", reason: null }],
    ...overrides,
  }
}

function setRoles(roles: string[]) {
  mocks.useOrgRole.mockReturnValue({ role: "member", roles, rolesResolved: true, isWriter: false, isLoading: false })
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.params = { id: "dn-1" }
  setRoles(["owner"])
  mocks.useDeliveryNote.mockReturnValue({ data: note(), isLoading: false, isError: false })
  mocks.useSalesOrder.mockReturnValue({ data: undefined })
  mocks.fetchPdf.mockResolvedValue(new Blob(["pdf"]))
})

describe("DeliveryNoteDetailPage — cabecera y contenido", () => {
  it("muestra número, estado, cliente con enlace, sucursal, fecha y domicilio", () => {
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByRole("heading", { name: "R-00000012" })).toBeInTheDocument()
    expect(screen.getByText("Pendiente")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Ana Pérez" })).toHaveAttribute("href", "/clientes/c-1")
    expect(screen.getByText(/Tel\. 2615551234/)).toBeInTheDocument()
    expect(screen.getByText("Sucursal Centro")).toBeInTheDocument()
    expect(screen.getByText("02/10/2026")).toBeInTheDocument()
    expect(screen.getByText("San Martín 100, Mendoza")).toBeInTheDocument()
  })

  it("pide el remito de la URL", () => {
    mocks.params = { id: "dn-42" }
    render(<DeliveryNoteDetailPage />)
    expect(mocks.useDeliveryNote).toHaveBeenCalledWith("dn-42")
  })

  it("'Modificado el …' sólo aparece si el remito se editó (revision > 1)", () => {
    const { unmount } = render(<DeliveryNoteDetailPage />)
    expect(screen.queryByText(/modificado el/i)).not.toBeInTheDocument()
    unmount()
    mocks.useDeliveryNote.mockReturnValue({
      data: note({ revision: 3, updated_at: "2026-10-03T10:30:00Z" }),
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByText(/modificado el/i)).toBeInTheDocument()
  })

  it("sin domicilio no inventa una fila de domicilio", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ delivery_address: null }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)
    expect(screen.queryByText(/domicilio de entrega/i)).not.toBeInTheDocument()
  })

  it("las líneas muestran cantidad con su unidad, precio, subtotal y el total", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({
        items: [
          item({ id: "i-1" }),
          item({ id: "i-2", name_snapshot: "Queso", quantity: "0.4500", unit_symbol: "kg", price: "1800.0000", subtotal: "810.0000", line_no: 2 }),
        ],
        total: "5310.0000",
      }),
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNoteDetailPage />)
    const table = screen.getByRole("table", { name: /líneas del remito/i })
    const rows = within(table).getAllByRole("row")
    expect(rows).toHaveLength(3) // encabezado + 2 líneas
    expect(rows[1]).toHaveTextContent("Remera")
    expect(rows[1]).toHaveTextContent(/3\s*u/)
    expect(rows[1]).toHaveTextContent(/1\.500/)
    expect(rows[1]).toHaveTextContent(/4\.500/)
    expect(rows[2]).toHaveTextContent("Queso")
    expect(rows[2]).toHaveTextContent(/0,45\s*kg/)
    expect(screen.getByTestId("delivery-note-total")).toHaveTextContent(/5\.310/)
  })

  it("una línea de un producto dado de baja lo aclara", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({ items: [item({ id: "i-1", product_deleted: true, name_snapshot: "Producto viejo" })] }),
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByText(/producto dado de baja/i)).toBeInTheDocument()
  })

  it("muestra las notas si las hay", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ notes: "Entregar por la mañana" }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByRole("region", { name: "Notas" })).toHaveTextContent("Entregar por la mañana")
  })

  it("el cliente dado de baja se muestra sin enlace y con el aviso", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ client_deleted: true }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)
    expect(screen.queryByRole("link", { name: "Ana Pérez" })).not.toBeInTheDocument()
    expect(screen.getByText(/cliente dado de baja/i)).toBeInTheDocument()
  })

  it("carga y error", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    const { unmount } = render(<DeliveryNoteDetailPage />)
    expect(screen.getByRole("status")).toHaveTextContent(/cargando remito/i)
    unmount()
    mocks.useDeliveryNote.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudo cargar el remito/i)
  })
})

describe("DeliveryNoteDetailPage — historial", () => {
  it("lista las transiciones con su rótulo y el motivo de la anulación", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({
        status: "canceled",
        history: [
          { from_status: null, to_status: "issued", performed_by: "u-1", occurred_at: "2026-10-02T15:00:00Z", reason: null },
          { from_status: "issued", to_status: "canceled", performed_by: "u-1", occurred_at: "2026-10-03T09:00:00Z", reason: "Cliente devolvió todo" },
        ],
      }),
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNoteDetailPage />)
    const history = screen.getByRole("list", { name: /historial de estados/i })
    const entries = within(history).getAllByRole("listitem")
    expect(entries).toHaveLength(2)
    expect(entries[0]).toHaveTextContent("Emitido")
    expect(entries[1]).toHaveTextContent("Anulado")
    expect(entries[1]).toHaveTextContent("Cliente devolvió todo")
  })

  it("un remito anulado muestra el motivo en un aviso destacado", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({
        status: "canceled",
        history: [{ from_status: "issued", to_status: "canceled", performed_by: "u-1", occurred_at: "2026-10-03T09:00:00Z", reason: "Se cargó dos veces" }],
      }),
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByRole("status", { name: /remito anulado/i })).toHaveTextContent("Se cargó dos veces")
  })
})

describe("DeliveryNoteDetailPage — acciones por estado y rol (D11)", () => {
  const actionNames = () => ({
    editar: screen.queryByRole("link", { name: /^editar$/i }),
    anular: screen.queryByRole("button", { name: /^anular$/i }),
    venta: screen.queryByRole("button", { name: /^venta$/i }),
    verVenta: screen.queryByRole("link", { name: /ver venta/i }),
    compartir: screen.queryByRole("group", { name: /menú de compartir/i }),
  })

  it.each([
    [["owner"], { editar: true, anular: true, venta: true }],
    [["admin"], { editar: true, anular: true, venta: true }],
    [["seller"], { editar: true, anular: false, venta: true }],
    [["stock"], { editar: true, anular: false, venta: false }],
    [["cashier"], { editar: false, anular: false, venta: true }],
    [["viewer"], { editar: false, anular: false, venta: false }],
    [["cashier", "admin"], { editar: true, anular: true, venta: true }],
    [["stock", "cashier"], { editar: true, anular: false, venta: true }],
  ])("remito pendiente con roles %j", (roles, expected) => {
    setRoles(roles)
    render(<DeliveryNoteDetailPage />)
    const a = actionNames()
    expect(a.compartir).toBeInTheDocument()
    expect(!!a.editar).toBe(expected.editar)
    expect(!!a.anular).toBe(expected.anular)
    // "Venta" (CAN_SELL): el cajero cobra lo que se llevó; el depósito (stock) emite pero no cobra.
    expect(!!a.venta).toBe(expected.venta)
  })

  it("Venta abre el diálogo de conversión con ESTE remito y Cancelar lo cierra", () => {
    render(<DeliveryNoteDetailPage />)
    expect(screen.queryByRole("dialog", { name: /pasar a venta/i })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /^venta$/i }))
    expect(screen.getByRole("dialog", { name: /pasar a venta/i })).toBeInTheDocument()
    expect(mocks.convertDialog.mock.calls.at(-1)?.[0].deliveryNote.id).toBe("dn-1")
    fireEvent.click(screen.getByRole("button", { name: /cerrar venta/i }))
    expect(screen.queryByRole("dialog", { name: /pasar a venta/i })).not.toBeInTheDocument()
  })

  it("cliente dado de baja: Venta queda deshabilitada y el motivo está visible y asociado al botón", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ client_deleted: true }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)

    const venta = screen.getByRole("button", { name: /^venta$/i })
    expect(venta).toBeDisabled()
    expect(venta).toHaveAccessibleDescription(/el cliente fue dado de baja: editá el remito y elegí uno vigente/i)
    expect(screen.getByText(/el cliente fue dado de baja: editá el remito y elegí uno vigente/i)).toBeVisible()
    fireEvent.click(venta)
    expect(screen.queryByRole("dialog", { name: /pasar a venta/i })).not.toBeInTheDocument()
  })

  it("un remito con cliente vigente no muestra ningún motivo bajo los botones", () => {
    render(<DeliveryNoteDetailPage />)
    expect(screen.queryByText(/el cliente fue dado de baja: editá el remito/i)).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /^venta$/i })).toBeEnabled()
  })

  it("al convertir, el remito pasa a convertido pero el diálogo SIGUE montado (si no, 'Venta registrada' desaparecería)", () => {
    const view = render(<DeliveryNoteDetailPage />)
    fireEvent.click(screen.getByRole("button", { name: /^venta$/i }))
    expect(screen.getByRole("dialog", { name: /pasar a venta/i })).toBeInTheDocument()

    mocks.useDeliveryNote.mockReturnValue({
      data: note({ status: "converted", converted_sales_order_id: "so-7" }),
      isLoading: false,
      isError: false,
    })
    view.rerender(<DeliveryNoteDetailPage />)

    expect(screen.getByRole("dialog", { name: /pasar a venta/i })).toBeInTheDocument()
    expect(screen.getByTestId("convert-dialog-note-status")).toHaveTextContent("converted")
    // Y el detalle ya no ofrece convertir de nuevo.
    expect(screen.queryByRole("button", { name: /^venta$/i })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ver venta/i })).toHaveAttribute("href", "/ventas/ordenes/so-7")
  })

  it("el diálogo no se monta en un remito convertido o anulado que nunca lo abrió", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({ status: "converted", converted_sales_order_id: "so-7" }),
      isLoading: false,
      isError: false,
    })
    const { unmount } = render(<DeliveryNoteDetailPage />)
    expect(mocks.convertDialog).not.toHaveBeenCalled()
    unmount()
    mocks.useDeliveryNote.mockReturnValue({ data: note({ status: "canceled" }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)
    expect(mocks.convertDialog).not.toHaveBeenCalled()
  })

  it("sin CAN_SELL el diálogo tampoco se monta", () => {
    setRoles(["stock"])
    render(<DeliveryNoteDetailPage />)
    expect(mocks.convertDialog).not.toHaveBeenCalled()
  })

  it("Editar lleva a la pantalla de edición del remito", () => {
    render(<DeliveryNoteDetailPage />)
    expect(actionNames().editar).toHaveAttribute("href", "/remitos/dn-1/editar")
  })

  it("Anular abre el diálogo de anulación con este remito y Volver lo cierra", () => {
    render(<DeliveryNoteDetailPage />)
    expect(screen.queryByRole("dialog", { name: /anular remito/i })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /^anular$/i }))
    expect(screen.getByRole("dialog", { name: /anular remito/i })).toBeInTheDocument()
    expect(mocks.cancelDialog.mock.calls.at(-1)?.[0].deliveryNote.id).toBe("dn-1")
    fireEvent.click(screen.getByRole("button", { name: /cerrar anulación/i }))
    expect(screen.queryByRole("dialog", { name: /anular remito/i })).not.toBeInTheDocument()
  })

  it("remito convertido: Compartir y Ver venta, sin Editar ni Anular, y la explicación de eliminar la venta", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({ status: "converted", converted_sales_order_id: "so-7" }),
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNoteDetailPage />)
    const a = actionNames()
    expect(a.compartir).toBeInTheDocument()
    expect(a.verVenta).toHaveAttribute("href", "/ventas/ordenes/so-7")
    expect(a.editar).not.toBeInTheDocument()
    expect(a.anular).not.toBeInTheDocument()
    expect(screen.getByText(/eliminá la venta: el remito vuelve a quedar pendiente/i)).toBeInTheDocument()
    expect(screen.getByRole("region", { name: /venta generada/i })).toBeInTheDocument()
  })

  it("remito convertido cuya venta tiene comprobante autorizado: leyenda de nota de crédito y estado del comprobante", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({ status: "converted", converted_sales_order_id: "so-7" }),
      isLoading: false,
      isError: false,
    })
    mocks.useSalesOrder.mockReturnValue({
      data: {
        id: "so-7",
        status: "confirmed",
        fiscal_document_id: "fd-1",
        fiscal_document_status: "authorized",
        fiscal_punto_de_venta: 3,
        fiscal_number: 501,
      },
    })
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByTestId("fiscal-summary")).toHaveTextContent(/authorized/)
    expect(screen.getByText(/nota de crédito/i)).toBeInTheDocument()
    expect(screen.queryByText(/eliminá la venta: el remito vuelve a quedar pendiente/i)).not.toBeInTheDocument()
  })

  it("remito anulado: sólo Compartir (PDF con sello)", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ status: "canceled" }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)
    const a = actionNames()
    expect(a.compartir).toBeInTheDocument()
    expect(a.editar).not.toBeInTheDocument()
    expect(a.anular).not.toBeInTheDocument()
    expect(a.verVenta).not.toBeInTheDocument()
  })

  it("una venta sin consultar no rompe: sin orden no hay región de comprobante", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ status: "converted" }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)
    expect(screen.queryByTestId("fiscal-summary")).not.toBeInTheDocument()
  })
})

describe("DeliveryNoteDetailPage — compartir con y sin precios", () => {
  it("el switch 'Mostrar precios' está apagado por defecto, con su Label, y NO vive dentro del menú de compartir", () => {
    render(<DeliveryNoteDetailPage />)
    const toggle = screen.getByRole("switch", { name: /mostrar precios/i })
    expect(toggle).toHaveAttribute("aria-checked", "false")
    const menu = screen.getByRole("group", { name: /menú de compartir/i })
    expect(menu).not.toContainElement(toggle)
  })

  it("por defecto el PDF se pide SIN precios y el archivo no lleva el sufijo", () => {
    render(<DeliveryNoteDetailPage />)
    fireEvent.click(screen.getByRole("button", { name: /descargar \(mock\)/i }))
    expect(mocks.fetchPdf).toHaveBeenCalledWith("dn-1", "attachment", false)
    expect(screen.getByTestId("share-file")).toHaveTextContent("remito-R-00000012.pdf")
  })

  it("cambiar el switch y enviar comparte la variante elegida (con precios) y remonta el menú para descartar la precarga", () => {
    render(<DeliveryNoteDetailPage />)
    expect(mocks.shareMounts).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole("switch", { name: /mostrar precios/i }))

    expect(screen.getByRole("switch", { name: /mostrar precios/i })).toHaveAttribute("aria-checked", "true")
    expect(mocks.shareMounts).toHaveBeenCalledTimes(2)
    fireEvent.click(screen.getByRole("button", { name: /descargar \(mock\)/i }))
    expect(mocks.fetchPdf).toHaveBeenLastCalledWith("dn-1", "attachment", true)
    expect(screen.getByTestId("share-file")).toHaveTextContent("remito-R-00000012-con-precios.pdf")
  })

  it("volver a apagar el switch vuelve a la variante sin precios", () => {
    render(<DeliveryNoteDetailPage />)
    const toggle = screen.getByRole("switch", { name: /mostrar precios/i })
    fireEvent.click(toggle)
    fireEvent.click(toggle)
    fireEvent.click(screen.getByRole("button", { name: /descargar \(mock\)/i }))
    expect(mocks.fetchPdf).toHaveBeenLastCalledWith("dn-1", "attachment", false)
    expect(mocks.shareMounts).toHaveBeenCalledTimes(3)
  })

  it("el texto de WhatsApp usa el nombre del cliente, el número, la fecha y el emisor del PDF", () => {
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByTestId("share-text")).toHaveTextContent(
      "Hola Ana Pérez, te envío el remito R-00000012 de la mercadería entregada el 02/10/2026. Kiosco Lola",
    )
    expect(screen.getByTestId("share-phone")).toHaveTextContent("2615551234")
  })

  it("compartir NO cambia el estado del remito: el menú no recibe onShared", () => {
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByTestId("share-has-on-shared")).toHaveTextContent("no")
  })

  it("un remito anulado también se puede compartir (PDF con sello)", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ status: "canceled" }), isLoading: false, isError: false })
    render(<DeliveryNoteDetailPage />)
    expect(screen.getByRole("group", { name: /menú de compartir/i })).toBeInTheDocument()
    expect(screen.getByRole("switch", { name: /mostrar precios/i })).toBeInTheDocument()
  })
})
