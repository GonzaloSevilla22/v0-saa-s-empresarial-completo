/**
 * presupuestos-modulo (D10, tarea 5.10) — pestaña "Presupuestos" de la ficha del
 * cliente: sus últimos 5 presupuestos (`useQuotes({clientId, pageSize: 5})`) y el
 * enlace al listado filtrado por ese cliente.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, within } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { QuoteListItem } from "@/lib/quote-types"

const mocks = vi.hoisted(() => ({ useQuotes: vi.fn(), useOrgRole: vi.fn() }))

vi.mock("next/navigation", () => ({ useParams: () => ({ id: "client-1" }) }))
vi.mock("@/hooks/data/use-quotes", () => ({ useQuotes: (filters: unknown) => mocks.useQuotes(filters) }))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))

import ClienteQuotesPage from "@/app/(dashboard)/clientes/[id]/presupuestos/page"

function row(overrides: Partial<QuoteListItem> & { id: string }): QuoteListItem {
  return {
    number: 1,
    number_label: "P-00000001",
    status: "sent",
    is_expired: false,
    client_id: "client-1",
    client_name: "Acme Corp",
    client_phone: null,
    valid_until: "2026-10-16",
    total: "1000",
    created_at: "2026-10-01T15:00:00Z",
    sent_at: null,
    updated_at: null,
    ...overrides,
  }
}

function result(items: QuoteListItem[], total = items.length, extra: Record<string, unknown> = {}) {
  return { data: { items, total, page: 0, pages: 1 }, isLoading: false, isError: false, ...extra }
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.useOrgRole.mockReturnValue({ role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false })
  mocks.useQuotes.mockReturnValue(result([row({ id: "q-1" }), row({ id: "q-2", number_label: "P-00000002", status: "draft" })]))
})

describe("ClienteQuotesPage", () => {
  it("pide los últimos 5 presupuestos de ESE cliente", () => {
    render(<ClienteQuotesPage />)

    expect(mocks.useQuotes).toHaveBeenCalledWith({ clientId: "client-1", pageSize: 5 })
  })

  it("muestra cada presupuesto con su número (enlace al detalle), estado y total", () => {
    render(<ClienteQuotesPage />)

    const first = screen.getByTestId("client-quote-q-1")
    expect(within(first).getByRole("link", { name: "P-00000001" })).toHaveAttribute("href", "/presupuestos/q-1")
    expect(within(first).getByText("Enviado")).toBeInTheDocument()
    expect(first).toHaveTextContent(/1\.000/)
    expect(within(screen.getByTestId("client-quote-q-2")).getByText("Borrador")).toBeInTheDocument()
  })

  it("un enviado con la validez pasada se ve vencido", () => {
    mocks.useQuotes.mockReturnValue(result([row({ id: "q-3", is_expired: true })]))
    render(<ClienteQuotesPage />)

    expect(within(screen.getByTestId("client-quote-q-3")).getByText("Vencido")).toBeInTheDocument()
  })

  it("enlaza al listado filtrado por el cliente", () => {
    render(<ClienteQuotesPage />)

    expect(screen.getByRole("link", { name: /ver todos/i })).toHaveAttribute("href", "/presupuestos?cliente=client-1")
  })

  it("cuando hay más de 5 aclara cuántos son en total", () => {
    mocks.useQuotes.mockReturnValue(result([row({ id: "q-1" })], 12))
    render(<ClienteQuotesPage />)

    expect(screen.getByRole("link", { name: /ver todos/i })).toHaveTextContent(/12/)
  })

  it("sin presupuestos explica y ofrece crear el primero para este cliente", () => {
    mocks.useQuotes.mockReturnValue(result([]))
    render(<ClienteQuotesPage />)

    const empty = screen.getByTestId("client-quotes-empty")
    expect(empty).toHaveTextContent(/todavía no tiene presupuestos/i)
    expect(within(empty).getByRole("link", { name: /nuevo presupuesto/i })).toHaveAttribute(
      "href",
      "/presupuestos/nuevo?cliente=client-1",
    )
    expect(screen.queryByRole("link", { name: /ver todos/i })).not.toBeInTheDocument()
  })

  it("sin presupuestos y sin permiso para presupuestar, el vacío no ofrece crear", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["cashier"], rolesResolved: true, isWriter: true, isLoading: false })
    mocks.useQuotes.mockReturnValue(result([]))
    render(<ClienteQuotesPage />)

    expect(within(screen.getByTestId("client-quotes-empty")).queryByRole("link")).not.toBeInTheDocument()
  })

  it("mientras carga muestra un aviso y si falla lo dice", () => {
    mocks.useQuotes.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    const { unmount } = render(<ClienteQuotesPage />)
    expect(screen.getByText(/cargando presupuestos/i)).toBeInTheDocument()
    unmount()

    mocks.useQuotes.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<ClienteQuotesPage />)
    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudieron cargar/i)
  })
})
