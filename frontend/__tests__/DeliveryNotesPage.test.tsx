/**
 * remitos-venta (D11, tarea 5.4) — `/remitos`: listado paginado.
 *
 * Invariantes bajo test:
 *  - pestañas de estado (Todos, Pendientes, Convertidos, Anulados) que resuelve
 *    el SERVIDOR, búsqueda con debounce y paginación; SIN pestañas de sentido;
 *  - el contrato único de la URL de D11: `?estado=`, `?sucursal=` y `?cliente=`,
 *    combinables: `estado` preselecciona la pestaña y los otros dos se aplican
 *    como chips removibles;
 *  - el resumen "N remitos pendientes por $ X" que manda el servidor;
 *  - tabla en desktop y tarjetas en móvil con el mismo contenido;
 *  - estado vacío explicativo con CTA, y el CTA "Nuevo remito" sólo con
 *    `CAN_DELIVER_SALE`, evaluado sobre el CONJUNTO de roles.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { DeliveryNoteListItem } from "@/lib/delivery-note-types"

const mocks = vi.hoisted(() => ({
  searchParams: { value: new URLSearchParams() },
  replace: vi.fn(),
  useDeliveryNotes: vi.fn(),
  useOrgRole: vi.fn(),
}))

vi.mock("next/navigation", () => ({
  useSearchParams: () => mocks.searchParams.value,
  useRouter: () => ({ replace: mocks.replace, push: vi.fn() }),
  usePathname: () => "/remitos",
}))
vi.mock("@/hooks/data/use-delivery-notes", () => ({
  useDeliveryNotes: (filters: unknown) => mocks.useDeliveryNotes(filters),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))
vi.mock("@/hooks/ui/use-debounce", () => ({ useDebounce: <T,>(value: T) => value }))
vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({
    branches: [
      { id: "b-1", name: "Centro" },
      { id: "b-2", name: "Norte" },
    ],
    isLoading: false,
  }),
}))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [{ id: "c-1", name: "Ana Pérez" }, { id: "c-2", name: "Beto Sosa" }] }),
}))

import DeliveryNotesPage from "@/app/(dashboard)/remitos/page"

function row(overrides: Partial<DeliveryNoteListItem> & { id: string }): DeliveryNoteListItem {
  return {
    direction: "sale",
    number: 12,
    number_label: "R-00000012",
    status: "issued",
    revision: 1,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: "2615551234",
    branch_id: "b-1",
    branch_name: "Centro",
    issued_on: "2026-10-02",
    item_count: 3,
    total: "12345.00",
    created_at: "2026-10-02T15:00:00Z",
    updated_at: null,
    ...overrides,
  }
}

function listResult(items: DeliveryNoteListItem[], extra: Record<string, unknown> = {}, summary = { pending_count: 0, pending_total: "0" }) {
  return {
    data: { items, total: items.length, page: 0, pages: items.length ? 1 : 0, summary },
    isLoading: false,
    isError: false,
    ...extra,
  }
}

function lastFilters(): Record<string, unknown> {
  const calls = mocks.useDeliveryNotes.mock.calls
  return calls[calls.length - 1][0] as Record<string, unknown>
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.searchParams.value = new URLSearchParams()
  mocks.useOrgRole.mockReturnValue({ role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false })
  mocks.useDeliveryNotes.mockReturnValue(listResult([row({ id: "dn-1" })]))
})

describe("DeliveryNotesPage — listado", () => {
  it("muestra una fila por remito con número, cliente, sucursal, ítems, total y estado", () => {
    mocks.useDeliveryNotes.mockReturnValue(
      listResult([
        row({ id: "dn-1", number_label: "R-00000012", client_name: "Ana Pérez", branch_name: "Centro", item_count: 3, total: "12345.00", status: "issued" }),
        row({ id: "dn-2", number_label: "R-00000013", client_name: "Beto Sosa", branch_name: "Norte", item_count: 1, total: "500", status: "converted" }),
        row({ id: "dn-3", number_label: "R-00000014", status: "canceled" }),
      ]),
    )
    render(<DeliveryNotesPage />)

    const first = screen.getByTestId("delivery-note-row-dn-1")
    expect(within(first).getByText("R-00000012")).toBeInTheDocument()
    expect(within(first).getByText("Ana Pérez")).toBeInTheDocument()
    expect(within(first).getByText("Centro")).toBeInTheDocument()
    expect(first).toHaveTextContent(/12\.345/)
    expect(first).toHaveTextContent(/\b3\b/)
    expect(within(first).getByText("Pendiente")).toBeInTheDocument()

    expect(within(screen.getByTestId("delivery-note-row-dn-2")).getByText("Convertido en venta")).toBeInTheDocument()
    expect(within(screen.getByTestId("delivery-note-row-dn-3")).getByText("Anulado")).toBeInTheDocument()
  })

  it("cada fila lleva al detalle del remito y en móvil hay una tarjeta equivalente", () => {
    render(<DeliveryNotesPage />)
    const link = within(screen.getByTestId("delivery-note-row-dn-1")).getByRole("link", { name: "R-00000012" })
    expect(link).toHaveAttribute("href", "/remitos/dn-1")
    const card = screen.getByTestId("delivery-note-card-dn-1")
    expect(card).toHaveAttribute("href", "/remitos/dn-1")
    expect(card).toHaveTextContent("Ana Pérez")
    expect(card).toHaveTextContent("R-00000012")
    expect(card).toHaveTextContent("Centro")
  })

  it("un remito cuyo cliente se dio de baja o sin número se rotula sin romper", () => {
    mocks.useDeliveryNotes.mockReturnValue(
      listResult([row({ id: "dn-9", client_id: null, client_name: null, number: null, number_label: null })]),
    )
    render(<DeliveryNotesPage />)
    expect(within(screen.getByTestId("delivery-note-row-dn-9")).getByText("Sin cliente")).toBeInTheDocument()
  })

  it("siempre pide los remitos de VENTA, con página 0 y tamaño 25", () => {
    render(<DeliveryNotesPage />)
    expect(lastFilters()).toMatchObject({ direction: "sale", page: 0, pageSize: 25 })
    expect(lastFilters().status).toBeUndefined()
  })

  it("no hay pestañas de sentido (De venta / De compra)", () => {
    render(<DeliveryNotesPage />)
    expect(screen.queryByRole("button", { name: /de venta/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /de compra/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("tab", { name: /compra/i })).not.toBeInTheDocument()
  })

  it("muestra el estado de carga y el de error", () => {
    mocks.useDeliveryNotes.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    const { unmount } = render(<DeliveryNotesPage />)
    expect(screen.getByRole("status")).toHaveTextContent(/cargando remitos/i)
    unmount()
    mocks.useDeliveryNotes.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<DeliveryNotesPage />)
    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudieron cargar los remitos/i)
  })
})

describe("DeliveryNotesPage — resumen de pendientes", () => {
  it("el encabezado dice cuántos remitos están pendientes y por cuánto", () => {
    mocks.useDeliveryNotes.mockReturnValue(
      listResult([row({ id: "dn-1" })], {}, { pending_count: 4, pending_total: "98765.5" }),
    )
    render(<DeliveryNotesPage />)
    const summary = screen.getByTestId("delivery-notes-summary")
    expect(summary).toHaveTextContent(/4 remitos pendientes por/i)
    expect(summary).toHaveTextContent(/98\.765,5/)
  })

  it("con uno solo usa el singular", () => {
    mocks.useDeliveryNotes.mockReturnValue(listResult([row({ id: "dn-1" })], {}, { pending_count: 1, pending_total: "100" }))
    render(<DeliveryNotesPage />)
    expect(screen.getByTestId("delivery-notes-summary")).toHaveTextContent(/1 remito pendiente por/i)
  })

  it("sin pendientes lo dice y no muestra un importe", () => {
    render(<DeliveryNotesPage />)
    expect(screen.getByTestId("delivery-notes-summary")).toHaveTextContent(/no hay remitos pendientes/i)
  })

  it("no aparece mientras carga ni si falla", () => {
    mocks.useDeliveryNotes.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    render(<DeliveryNotesPage />)
    expect(screen.queryByTestId("delivery-notes-summary")).not.toBeInTheDocument()
  })
})

describe("DeliveryNotesPage — pestañas, búsqueda y paginación", () => {
  it.each([
    ["Pendientes", "issued"],
    ["Convertidos", "converted"],
    ["Anulados", "canceled"],
  ])("la pestaña %s pide status=%s al servidor y 'Todos' lo quita", (label, status) => {
    render(<DeliveryNotesPage />)
    fireEvent.click(screen.getByRole("button", { name: label }))
    expect(lastFilters().status).toBe(status)
    expect(screen.getByRole("button", { name: label })).toHaveAttribute("aria-pressed", "true")
    fireEvent.click(screen.getByRole("button", { name: "Todos" }))
    expect(lastFilters().status).toBeUndefined()
  })

  it("cambiar de pestaña vuelve a la primera página y sincroniza ?estado= en la URL", () => {
    mocks.useDeliveryNotes.mockReturnValue({
      data: { items: [row({ id: "dn-1" })], total: 60, page: 0, pages: 3, summary: { pending_count: 0, pending_total: "0" } },
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNotesPage />)
    fireEvent.click(screen.getByRole("button", { name: /página siguiente/i }))
    expect(lastFilters().page).toBe(1)
    fireEvent.click(screen.getByRole("button", { name: "Pendientes" }))
    expect(lastFilters().page).toBe(0)
    expect(mocks.replace).toHaveBeenLastCalledWith("/remitos?estado=pendientes", { scroll: false })
    fireEvent.click(screen.getByRole("button", { name: "Todos" }))
    expect(mocks.replace).toHaveBeenLastCalledWith("/remitos", { scroll: false })
  })

  it("la búsqueda por cliente o número va al servidor y vuelve a la primera página", () => {
    render(<DeliveryNotesPage />)
    fireEvent.change(screen.getByRole("searchbox", { name: /buscar/i }), { target: { value: "R-12" } })
    expect(lastFilters()).toMatchObject({ q: "R-12", page: 0 })
  })

  it("pagina con anterior y siguiente y muestra el total", () => {
    mocks.useDeliveryNotes.mockReturnValue({
      data: { items: [row({ id: "dn-1" })], total: 60, page: 0, pages: 3, summary: { pending_count: 0, pending_total: "0" } },
      isLoading: false,
      isError: false,
    })
    render(<DeliveryNotesPage />)
    expect(screen.getByText(/Página 1 de 3 · 60 remitos/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /página anterior/i })).toBeDisabled()
    fireEvent.click(screen.getByRole("button", { name: /página siguiente/i }))
    expect(lastFilters().page).toBe(1)
    expect(screen.getByRole("button", { name: /página anterior/i })).not.toBeDisabled()
  })

  it("con una sola página no muestra paginación", () => {
    render(<DeliveryNotesPage />)
    expect(screen.queryByRole("button", { name: /página siguiente/i })).not.toBeInTheDocument()
  })
})

describe("DeliveryNotesPage — contrato de la URL (?estado=, ?sucursal=, ?cliente=)", () => {
  it("entra con los tres parámetros: preselecciona la pestaña y filtra por sucursal y cliente", () => {
    mocks.searchParams.value = new URLSearchParams("estado=pendientes&sucursal=b-2&cliente=c-1")
    render(<DeliveryNotesPage />)
    expect(lastFilters()).toMatchObject({ direction: "sale", status: "issued", branchId: "b-2", clientId: "c-1" })
    expect(screen.getByRole("button", { name: "Pendientes" })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByTestId("delivery-note-branch-filter")).toHaveTextContent("Norte")
    expect(screen.getByTestId("delivery-note-client-filter")).toHaveTextContent("Ana Pérez")
  })

  it.each([
    ["convertidos", "converted"],
    ["anulados", "canceled"],
    ["todos", undefined],
  ])("?estado=%s selecciona la pestaña correspondiente", (estado, status) => {
    mocks.searchParams.value = new URLSearchParams(`estado=${estado}`)
    render(<DeliveryNotesPage />)
    expect(lastFilters().status).toBe(status)
  })

  it("un ?estado= desconocido cae en 'Todos' sin romper", () => {
    mocks.searchParams.value = new URLSearchParams("estado=inventado")
    render(<DeliveryNotesPage />)
    expect(lastFilters().status).toBeUndefined()
    expect(screen.getByRole("button", { name: "Todos" })).toHaveAttribute("aria-pressed", "true")
  })

  it("sin parámetros no hay chips", () => {
    render(<DeliveryNotesPage />)
    expect(screen.queryByTestId("delivery-note-branch-filter")).not.toBeInTheDocument()
    expect(screen.queryByTestId("delivery-note-client-filter")).not.toBeInTheDocument()
  })

  it("quitar el chip de sucursal saca el filtro y lo borra de la URL conservando el resto", () => {
    mocks.searchParams.value = new URLSearchParams("estado=pendientes&sucursal=b-2&cliente=c-1")
    render(<DeliveryNotesPage />)
    fireEvent.click(within(screen.getByTestId("delivery-note-branch-filter")).getByRole("button", { name: /quitar filtro de sucursal/i }))
    expect(lastFilters().branchId).toBeUndefined()
    expect(lastFilters().clientId).toBe("c-1")
    expect(screen.queryByTestId("delivery-note-branch-filter")).not.toBeInTheDocument()
    expect(mocks.replace).toHaveBeenLastCalledWith("/remitos?estado=pendientes&cliente=c-1", { scroll: false })
  })

  it("quitar el chip de cliente saca el filtro y lo borra de la URL", () => {
    mocks.searchParams.value = new URLSearchParams("cliente=c-1")
    render(<DeliveryNotesPage />)
    fireEvent.click(within(screen.getByTestId("delivery-note-client-filter")).getByRole("button", { name: /quitar filtro de cliente/i }))
    expect(lastFilters().clientId).toBeUndefined()
    expect(mocks.replace).toHaveBeenLastCalledWith("/remitos", { scroll: false })
  })

  it("el nombre del chip cae a un rótulo genérico si la sucursal o el cliente no se conocen", () => {
    mocks.searchParams.value = new URLSearchParams("sucursal=b-desconocida&cliente=c-desconocido")
    render(<DeliveryNotesPage />)
    expect(screen.getByTestId("delivery-note-branch-filter")).toHaveTextContent(/sucursal/i)
    expect(screen.getByTestId("delivery-note-client-filter")).toHaveTextContent(/cliente/i)
  })

  it("'Nuevo remito' desde un listado filtrado por cliente lo lleva preseleccionado", () => {
    mocks.searchParams.value = new URLSearchParams("cliente=c-1")
    render(<DeliveryNotesPage />)
    expect(screen.getByRole("link", { name: /nuevo remito/i })).toHaveAttribute("href", "/remitos/nuevo?cliente=c-1")
  })
})

describe("DeliveryNotesPage — estados vacíos y permisos", () => {
  beforeEach(() => {
    mocks.useDeliveryNotes.mockReturnValue(listResult([]))
  })

  it("sin remitos explica qué es y que descuenta stock, con CTA", () => {
    render(<DeliveryNotesPage />)
    const empty = screen.getByTestId("delivery-notes-empty")
    expect(empty).toHaveTextContent(/todavía no hay remitos/i)
    expect(empty).toHaveTextContent(/descuenta stock al emitirse/i)
    expect(within(empty).getByRole("link", { name: /crear el primero/i })).toHaveAttribute("href", "/remitos/nuevo")
  })

  it("una búsqueda sin resultados lo dice y no ofrece crear", () => {
    render(<DeliveryNotesPage />)
    fireEvent.change(screen.getByRole("searchbox", { name: /buscar/i }), { target: { value: "zzz" } })
    const empty = screen.getByTestId("delivery-notes-empty")
    expect(empty).toHaveTextContent(/ningún remito coincide/i)
    expect(within(empty).queryByRole("link", { name: /crear el primero/i })).not.toBeInTheDocument()
  })

  it("una pestaña sin remitos lo dice con el sustantivo de la pestaña", () => {
    render(<DeliveryNotesPage />)
    fireEvent.click(screen.getByRole("button", { name: "Anulados" }))
    expect(screen.getByTestId("delivery-notes-empty")).toHaveTextContent(/no hay remitos anulados/i)
  })

  it("un cliente sin remitos lo dice", () => {
    mocks.searchParams.value = new URLSearchParams("cliente=c-1")
    render(<DeliveryNotesPage />)
    expect(screen.getByTestId("delivery-notes-empty")).toHaveTextContent(/este cliente todavía no tiene remitos/i)
  })

  it.each([
    [["owner"], true],
    [["admin"], true],
    [["seller"], true],
    [["stock"], true],
    [["cashier"], false],
    [["accountant"], false],
    [["viewer"], false],
    [["cashier", "stock"], true],
  ])("el CTA 'Nuevo remito' con roles %j: visible=%s", (roles, visible) => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles, rolesResolved: true, isWriter: false, isLoading: false })
    mocks.useDeliveryNotes.mockReturnValue(listResult([row({ id: "dn-1" })]))
    render(<DeliveryNotesPage />)
    const link = screen.queryByRole("link", { name: /nuevo remito/i })
    if (visible) expect(link).toBeInTheDocument()
    else expect(link).not.toBeInTheDocument()
  })

  it("mientras los roles no se resolvieron el CTA se muestra (fail-open: la barrera real es el servidor)", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: [], rolesResolved: false, isWriter: false, isLoading: true })
    mocks.useDeliveryNotes.mockReturnValue(listResult([row({ id: "dn-1" })]))
    render(<DeliveryNotesPage />)
    expect(screen.getByRole("link", { name: /nuevo remito/i })).toBeInTheDocument()
  })
})
