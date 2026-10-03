/**
 * remitos-venta (D11, tarea 5.5) — `/remitos/nuevo` y `/remitos/[id]/editar`.
 *
 * Son páginas finas: resuelven de dónde viene el formulario (`?cliente=`, el
 * remito a editar) y NO montan el `DeliveryNoteForm` hasta que el catálogo, las
 * unidades y las sucursales cargaron: el formulario rehidrata las líneas UNA vez
 * al montar (con el catálogo vacío todos los productos figurarían como dados de
 * baja) y, sin las sucursales, mostraría un falso "no hay sucursal".
 *
 * Estados de página con `DocumentPageStates`: sin `CAN_DELIVER_SALE`, error o no
 * encontrado (un remito ajeno es indistinguible de uno inexistente), y no
 * editable (convertido: enlace a la venta e instrucción de eliminarla; anulado:
 * el motivo).
 */
import React, { useEffect } from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { DeliveryNoteApiRow } from "@/lib/delivery-note-types"

const mocks = vi.hoisted(() => ({
  searchParams: new URLSearchParams(),
  params: { id: "dn-1" },
  useDeliveryNote: vi.fn(),
  useOrgRole: vi.fn(),
  useProducts: vi.fn(),
  useUnitsOfMeasure: vi.fn(),
  useBranches: vi.fn(),
  mounts: vi.fn(),
}))

vi.mock("next/navigation", () => ({
  useSearchParams: () => mocks.searchParams,
  useParams: () => mocks.params,
  useRouter: () => ({ push: vi.fn() }),
}))
vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useDeliveryNote: (id: string | null) => mocks.useDeliveryNote(id),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => mocks.useProducts() }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => mocks.useBranches() }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => mocks.useUnitsOfMeasure() }))
vi.mock("@/components/delivery-notes/DeliveryNoteForm", () => ({
  DeliveryNoteForm: (props: {
    deliveryNote?: DeliveryNoteApiRow
    direction?: "sale" | "purchase"
    initialClientId?: string
    initialSupplierId?: string
  }) => {
    useEffect(() => {
      mocks.mounts()
    }, [])
    return (
      <div
        data-testid="delivery-note-form"
        data-note={props.deliveryNote?.id ?? ""}
        data-revision={props.deliveryNote?.revision ?? ""}
        data-client={props.initialClientId ?? ""}
        data-supplier={props.initialSupplierId ?? ""}
        data-direction={props.deliveryNote?.direction ?? props.direction ?? "sale"}
      />
    )
  },
}))

import NewDeliveryNotePage from "@/app/(dashboard)/remitos/nuevo/page"
import EditDeliveryNotePage from "@/app/(dashboard)/remitos/[id]/editar/page"

function note(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return {
    id: "dn-1",
    direction: "sale",
    number: 12,
    number_label: "R-00000012",
    status: "issued",
    revision: 3,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: null,
    branch_id: "b-1",
    branch_name: "Centro",
    issued_on: "2026-10-02",
    delivery_address: null,
    notes: null,
    total: "100",
    created_at: "2026-10-02T12:00:00Z",
    created_by: "u-1",
    updated_at: null,
    updated_by: null,
    items: [],
    history: [],
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.searchParams = new URLSearchParams()
  mocks.params = { id: "dn-1" }
  mocks.useOrgRole.mockReturnValue({ role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false })
  mocks.useProducts.mockReturnValue({ products: [], isLoading: false })
  mocks.useBranches.mockReturnValue({ branches: [], isLoading: false })
  mocks.useUnitsOfMeasure.mockReturnValue({ units: [], unitsById: new Map(), loading: false, error: null })
  mocks.useDeliveryNote.mockReturnValue({ data: note(), isLoading: false, isError: false })
})

describe("/remitos/nuevo", () => {
  it("monta un formulario vacío con el título y la advertencia de que descuenta stock", () => {
    render(<NewDeliveryNotePage />)
    expect(screen.getByRole("heading", { name: "Nuevo remito" })).toBeInTheDocument()
    expect(screen.getByText(/descuenta stock/i)).toBeInTheDocument()
    const form = screen.getByTestId("delivery-note-form")
    expect(form).toHaveAttribute("data-note", "")
    expect(form).toHaveAttribute("data-client", "")
  })

  it("?cliente= llega como cliente preseleccionado", () => {
    mocks.searchParams = new URLSearchParams("cliente=c-77")
    render(<NewDeliveryNotePage />)
    expect(screen.getByTestId("delivery-note-form")).toHaveAttribute("data-client", "c-77")
  })

  it.each([
    ["productos", { useProducts: { products: [], isLoading: true } }],
    ["unidades", { useUnitsOfMeasure: { units: [], unitsById: new Map(), loading: true, error: null } }],
    ["sucursales", { useBranches: { branches: [], isLoading: true } }],
  ])("mientras cargan los %s no monta el formulario", (_label, override) => {
    for (const [hook, value] of Object.entries(override)) {
      ;(mocks as unknown as Record<string, ReturnType<typeof vi.fn>>)[hook].mockReturnValue(value)
    }
    render(<NewDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/cargando/i)
  })

  it.each([
    [["owner"], true],
    [["seller"], true],
    [["stock"], true],
    [["admin"], true],
    [["cashier"], false],
    [["viewer"], false],
    [["accountant"], false],
  ])("con roles %j el formulario visible=%s", (roles, visible) => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles, rolesResolved: true, isWriter: false, isLoading: false })
    render(<NewDeliveryNotePage />)
    if (visible) {
      expect(screen.getByTestId("delivery-note-form")).toBeInTheDocument()
    } else {
      expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
      expect(screen.getByRole("status")).toHaveTextContent(/tu rol no permite emitir remitos/i)
      expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos")
    }
  })

  it("el enlace de volver lleva al listado", () => {
    render(<NewDeliveryNotePage />)
    expect(screen.getByRole("link", { name: /volver al listado/i })).toHaveAttribute("href", "/remitos")
  })
})

describe("/remitos/[id]/editar", () => {
  it("monta el formulario con el remito y lo vuelve a montar cuando cambia la revisión", () => {
    const { rerender } = render(<EditDeliveryNotePage />)
    const form = screen.getByTestId("delivery-note-form")
    expect(form).toHaveAttribute("data-note", "dn-1")
    expect(mocks.mounts).toHaveBeenCalledTimes(1)

    // Un refresco de fondo con la misma revisión NO remonta (no se pierde lo tipeado).
    mocks.useDeliveryNote.mockReturnValue({ data: note({ total: "200" }), isLoading: false, isError: false })
    rerender(<EditDeliveryNotePage />)
    expect(mocks.mounts).toHaveBeenCalledTimes(1)

    // Otra revisión (el usuario eligió "Recargar") sí.
    mocks.useDeliveryNote.mockReturnValue({ data: note({ revision: 4 }), isLoading: false, isError: false })
    rerender(<EditDeliveryNotePage />)
    expect(mocks.mounts).toHaveBeenCalledTimes(2)
    expect(screen.getByTestId("delivery-note-form")).toHaveAttribute("data-revision", "4")
  })

  it("el título nombra al remito por su número", () => {
    render(<EditDeliveryNotePage />)
    expect(screen.getByRole("heading", { name: "Editar R-00000012" })).toBeInTheDocument()
  })

  it("pide el remito de la URL", () => {
    mocks.params = { id: "dn-99" }
    render(<EditDeliveryNotePage />)
    expect(mocks.useDeliveryNote).toHaveBeenCalledWith("dn-99")
  })

  it("sin permiso para emitir y editar muestra el motivo en lugar del formulario", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["cashier"], rolesResolved: true, isWriter: false, isLoading: false })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/tu rol no permite editar remitos/i)
  })

  it("un remito inexistente o ajeno muestra el mismo error, con enlace al listado", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<EditDeliveryNotePage />)
    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudo cargar el remito/i)
    expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos")
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
  })

  it.each([
    ["el remito", { data: undefined, isLoading: true, isError: false }],
    ["los productos", null],
  ])("mientras cargan %s no monta el formulario", (_label, noteResult) => {
    if (noteResult) mocks.useDeliveryNote.mockReturnValue(noteResult)
    else mocks.useProducts.mockReturnValue({ products: [], isLoading: true })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/cargando/i)
  })

  it("un remito convertido no abre el editor: explica que hay que eliminar la venta y enlaza a ella", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({ status: "converted", converted_sales_order_id: "so-7" }),
      isLoading: false,
      isError: false,
    })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/eliminá la venta/i)
    expect(screen.getByRole("link", { name: /ver la venta/i })).toHaveAttribute("href", "/ventas/ordenes/so-7")
  })

  it("un remito convertido sin orden conocida igual explica y vuelve al detalle", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ status: "converted" }), isLoading: false, isError: false })
    render(<EditDeliveryNotePage />)
    expect(screen.getByRole("status")).toHaveTextContent(/eliminá la venta/i)
    expect(screen.queryByRole("link", { name: /ver la venta/i })).not.toBeInTheDocument()
  })

  it("un remito anulado no abre el editor y muestra el motivo de la anulación", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: note({
        status: "canceled",
        history: [
          { from_status: null, to_status: "issued", performed_by: "u-1", occurred_at: "2026-10-02T12:00:00Z", reason: null },
          { from_status: "issued", to_status: "canceled", performed_by: "u-1", occurred_at: "2026-10-02T13:00:00Z", reason: "Cliente devolvió todo" },
        ],
      }),
      isLoading: false,
      isError: false,
    })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByText(/anulado y no se puede modificar/i)).toBeInTheDocument()
    expect(screen.getByText(/Cliente devolvió todo/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ver el remito/i })).toHaveAttribute("href", "/remitos/dn-1")
  })

  it("un remito anulado sin motivo registrado no inventa uno", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: note({ status: "canceled", history: [] }), isLoading: false, isError: false })
    render(<EditDeliveryNotePage />)
    expect(screen.getByText(/anulado y no se puede modificar/i)).toBeInTheDocument()
    expect(screen.queryByText(/motivo:/i)).not.toBeInTheDocument()
  })
})

// ══ remitos-compra (D11, tarea 5.5): las dos páginas en sentido compra ═════════

function purchaseNote(overrides: Partial<DeliveryNoteApiRow> = {}): DeliveryNoteApiRow {
  return note({
    direction: "purchase",
    number: 7,
    number_label: "RC-00000007",
    client_id: null,
    client_name: null,
    supplier_id: "s-1",
    supplier_name: "Distribuidora Sur",
    supplier_reference: "0004-00001234",
    ...overrides,
  })
}

const setRoles = (roles: string[]) =>
  mocks.useOrgRole.mockReturnValue({ role: "member", roles, rolesResolved: true, isWriter: false, isLoading: false })

describe("/remitos/nuevo?tipo=compra", () => {
  it("monta el formulario en sentido compra con el título y la advertencia de que SUMA stock", () => {
    mocks.searchParams = new URLSearchParams("tipo=compra")
    render(<NewDeliveryNotePage />)
    expect(screen.getByRole("heading", { name: "Nuevo remito de compra" })).toBeInTheDocument()
    expect(screen.getByText(/suma stock/i)).toBeInTheDocument()
    expect(screen.queryByText(/descuenta stock/i)).not.toBeInTheDocument()
    expect(screen.getByTestId("delivery-note-form")).toHaveAttribute("data-direction", "purchase")
  })

  it("?proveedor= llega como proveedor preseleccionado y no como cliente", () => {
    mocks.searchParams = new URLSearchParams("tipo=compra&proveedor=s-77&cliente=c-1")
    render(<NewDeliveryNotePage />)
    const form = screen.getByTestId("delivery-note-form")
    expect(form).toHaveAttribute("data-supplier", "s-77")
    expect(form).toHaveAttribute("data-client", "")
  })

  it("el enlace de volver lleva al listado DE COMPRA, no al de venta", () => {
    mocks.searchParams = new URLSearchParams("tipo=compra")
    render(<NewDeliveryNotePage />)
    expect(screen.getByRole("link", { name: /volver al listado/i })).toHaveAttribute("href", "/remitos?sentido=compra")
  })

  it.each([
    [["owner"], true],
    [["admin"], true],
    [["stock"], true],
    [["seller"], false],
    [["purchases"], false],
    [["cashier"], false],
    [["viewer"], false],
    [["accountant"], false],
  ])("con roles %j el formulario de compra visible=%s (CAN_RECEIVE_PURCHASE)", (roles, visible) => {
    mocks.searchParams = new URLSearchParams("tipo=compra")
    setRoles(roles)
    render(<NewDeliveryNotePage />)
    if (visible) {
      expect(screen.getByTestId("delivery-note-form")).toBeInTheDocument()
    } else {
      expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
      expect(screen.getByRole("status")).toHaveTextContent(/tu rol no permite recibir remitos de compra/i)
      expect(screen.getByRole("status")).toHaveTextContent(/encargado de stock/i)
      expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos?sentido=compra")
    }
  })

  it("un vendedor que puede emitir remitos de venta NO puede recibir mercadería", () => {
    setRoles(["seller"])
    mocks.searchParams = new URLSearchParams("tipo=venta")
    const { unmount } = render(<NewDeliveryNotePage />)
    expect(screen.getByTestId("delivery-note-form")).toBeInTheDocument()
    unmount()
    mocks.searchParams = new URLSearchParams("tipo=compra")
    render(<NewDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
  })

  it.each([
    ["productos", { useProducts: { products: [], isLoading: true } }],
    ["unidades", { useUnitsOfMeasure: { units: [], unitsById: new Map(), loading: true, error: null } }],
    ["sucursales", { useBranches: { branches: [], isLoading: true } }],
  ])("mientras cargan los %s no monta el formulario de compra", (_label, override) => {
    mocks.searchParams = new URLSearchParams("tipo=compra")
    for (const [hook, value] of Object.entries(override)) {
      ;(mocks as unknown as Record<string, ReturnType<typeof vi.fn>>)[hook].mockReturnValue(value)
    }
    render(<NewDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/cargando/i)
  })

  it.each([["venta"], ["otra-cosa"], [""]])("?tipo=%s sigue siendo el remito de venta", (tipo) => {
    mocks.searchParams = new URLSearchParams(tipo ? `tipo=${tipo}` : "")
    render(<NewDeliveryNotePage />)
    expect(screen.getByRole("heading", { name: "Nuevo remito" })).toBeInTheDocument()
    expect(screen.getByTestId("delivery-note-form")).toHaveAttribute("data-direction", "sale")
  })
})

describe("/remitos/[id]/editar de compra", () => {
  beforeEach(() => {
    mocks.useDeliveryNote.mockReturnValue({ data: purchaseNote(), isLoading: false, isError: false })
  })

  it("monta el formulario con el remito de compra y lo nombra por su número RC", () => {
    render(<EditDeliveryNotePage />)
    expect(screen.getByRole("heading", { name: "Editar RC-00000007" })).toBeInTheDocument()
    expect(screen.getByTestId("delivery-note-form")).toHaveAttribute("data-direction", "purchase")
  })

  it("la bajada habla de ajustar el stock sin atribuir la dirección", () => {
    render(<EditDeliveryNotePage />)
    expect(screen.getByText(/ajustan el stock sólo donde cambia/i)).toBeInTheDocument()
  })

  it.each([
    [["owner"], true],
    [["admin"], true],
    [["stock"], true],
    [["seller"], false],
    [["purchases"], false],
    [["cashier"], false],
  ])("con roles %j editar un remito de compra visible=%s", (roles, visible) => {
    setRoles(roles)
    render(<EditDeliveryNotePage />)
    if (visible) {
      expect(screen.getByTestId("delivery-note-form")).toBeInTheDocument()
    } else {
      expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
      expect(screen.getByRole("status")).toHaveTextContent(/tu rol no permite editar remitos/i)
      expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos?sentido=compra")
    }
  })

  it("un vendedor edita remitos de venta pero no los de compra (el permiso sigue al sentido del remito)", () => {
    setRoles(["seller"])
    mocks.useDeliveryNote.mockReturnValue({ data: note(), isLoading: false, isError: false })
    const { unmount } = render(<EditDeliveryNotePage />)
    expect(screen.getByTestId("delivery-note-form")).toBeInTheDocument()
    unmount()
    mocks.useDeliveryNote.mockReturnValue({ data: purchaseNote(), isLoading: false, isError: false })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
  })

  it("un rol sin ninguna de las dos capacidades ve el motivo sin esperar al remito", () => {
    setRoles(["viewer"])
    mocks.useDeliveryNote.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    render(<EditDeliveryNotePage />)
    expect(screen.getByRole("status")).toHaveTextContent(/tu rol no permite editar remitos/i)
  })

  it("un remito de compra convertido no abre el editor: dice que hay que eliminar la COMPRA y la enlaza", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: purchaseNote({ status: "converted", converted_operation_id: "op-9" }),
      isLoading: false,
      isError: false,
    })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/eliminá la compra/i)
    expect(screen.getByRole("status")).not.toHaveTextContent(/eliminá la venta/i)
    expect(screen.getByRole("link", { name: /ver la compra/i })).toHaveAttribute("href", "/compras")
  })

  it("convertido sin compra conocida vuelve al detalle, sin enlace a la compra", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: purchaseNote({ status: "converted" }), isLoading: false, isError: false })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByRole("link", { name: /ver la compra/i })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: /ver el remito/i })).toHaveAttribute("href", "/remitos/dn-1")
  })

  it("un remito de compra anulado no abre el editor y muestra el motivo", () => {
    mocks.useDeliveryNote.mockReturnValue({
      data: purchaseNote({
        status: "canceled",
        history: [
          { from_status: null, to_status: "issued", performed_by: "u-1", occurred_at: "2026-10-02T12:00:00Z", reason: null },
          { from_status: "issued", to_status: "canceled", performed_by: "u-1", occurred_at: "2026-10-02T13:00:00Z", reason: "El proveedor se llevó todo" },
        ],
      }),
      isLoading: false,
      isError: false,
    })
    render(<EditDeliveryNotePage />)
    expect(screen.queryByTestId("delivery-note-form")).not.toBeInTheDocument()
    expect(screen.getByText(/anulado y no se puede modificar/i)).toBeInTheDocument()
    expect(screen.getByText(/El proveedor se llevó todo/)).toBeInTheDocument()
  })

  it("el enlace de volver de un remito de compra anulado va al listado de compra", () => {
    mocks.useDeliveryNote.mockReturnValue({ data: purchaseNote({ status: "canceled" }), isLoading: false, isError: false })
    render(<EditDeliveryNotePage />)
    expect(screen.getByRole("link", { name: /volver a remitos/i })).toHaveAttribute("href", "/remitos?sentido=compra")
  })
})
