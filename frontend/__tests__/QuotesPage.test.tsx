/**
 * presupuestos-modulo (D10, tarea 5.6) — `/presupuestos`: listado paginado.
 *
 * Invariantes bajo test:
 *  - pestañas de estado (Todos, Borradores, Enviados, Aceptados, Vencidos,
 *    Rechazados) que resuelve el SERVIDOR, búsqueda y paginación;
 *  - tabla en desktop y tarjetas en móvil con el mismo contenido;
 *  - "Vencido" derivado (`is_expired`) en la columna de validez y en el badge;
 *  - estado vacío explicativo con CTA;
 *  - el CTA "Nuevo presupuesto" sólo aparece con `CAN_QUOTE`, evaluado sobre el
 *    CONJUNTO de roles (un usuario sólo `seller` lo ve; uno sólo `cashier`, no);
 *  - el aviso "Validez por defecto: N días · Cambiar" lleva a Cobranzas.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within, act } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { QuoteListItem } from "@/lib/quote-types"

const mocks = vi.hoisted(() => ({
  useQuotes: vi.fn(),
  useOrgRole: vi.fn(),
  validityDays: { value: 15 as number | undefined },
}))

vi.mock("@/hooks/data/use-quotes", () => ({
  useQuotes: (filters: unknown) => mocks.useQuotes(filters),
  useQuoteSettings: () => ({
    data: mocks.validityDays.value === undefined ? undefined : { defaultQuoteValidityDays: mocks.validityDays.value },
  }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))

import QuotesPage from "@/app/(dashboard)/presupuestos/page"

function row(overrides: Partial<QuoteListItem> & { id: string }): QuoteListItem {
  return {
    number: 12,
    number_label: "P-00000012",
    status: "sent",
    is_expired: false,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: "2615551234",
    valid_until: "2026-10-16",
    total: "12345.00",
    created_at: "2026-10-01T15:00:00Z",
    sent_at: "2026-10-01T15:05:00Z",
    updated_at: null,
    ...overrides,
  }
}

function listResult(items: QuoteListItem[], extra: Record<string, unknown> = {}) {
  return {
    data: { items, total: items.length, page: 0, pages: items.length ? 1 : 0 },
    isLoading: false,
    isError: false,
    ...extra,
  }
}

function lastFilters(): Record<string, unknown> {
  const calls = mocks.useQuotes.mock.calls
  return calls[calls.length - 1][0] as Record<string, unknown>
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.validityDays.value = 15
  mocks.useOrgRole.mockReturnValue({ role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false })
  mocks.useQuotes.mockReturnValue(listResult([row({ id: "q-1" })]))
})

describe("QuotesPage — listado", () => {
  it("muestra una fila por presupuesto con número, cliente, total y estado", () => {
    mocks.useQuotes.mockReturnValue(
      listResult([
        row({ id: "q-1", number_label: "P-00000012", client_name: "Ana Pérez", total: "12345.00", status: "sent" }),
        row({ id: "q-2", number_label: "P-00000013", client_name: "Beto Sosa", total: "500", status: "draft" }),
      ]),
    )
    render(<QuotesPage />)

    const first = screen.getByTestId("quote-row-q-1")
    expect(within(first).getByText("P-00000012")).toBeInTheDocument()
    expect(within(first).getByText("Ana Pérez")).toBeInTheDocument()
    expect(first).toHaveTextContent(/12\.345/)
    expect(within(first).getByText("Enviado")).toBeInTheDocument()

    const second = screen.getByTestId("quote-row-q-2")
    expect(within(second).getByText("Borrador")).toBeInTheDocument()
  })

  it("cada fila lleva al detalle del presupuesto", () => {
    render(<QuotesPage />)

    const link = within(screen.getByTestId("quote-row-q-1")).getByRole("link", { name: "P-00000012" })
    expect(link).toHaveAttribute("href", "/presupuestos/q-1")
  })

  it("en móvil hay una tarjeta por presupuesto que lleva al mismo detalle", () => {
    render(<QuotesPage />)

    const card = screen.getByTestId("quote-card-q-1")
    expect(card).toHaveAttribute("href", "/presupuestos/q-1")
    expect(card).toHaveTextContent("Ana Pérez")
    expect(card).toHaveTextContent("P-00000012")
  })

  it("un presupuesto sin cliente (anterior al módulo) se rotula 'Sin cliente'", () => {
    mocks.useQuotes.mockReturnValue(
      listResult([row({ id: "q-9", client_id: null, client_name: null, number: null, number_label: null })]),
    )
    render(<QuotesPage />)

    expect(within(screen.getByTestId("quote-row-q-9")).getByText("Sin cliente")).toBeInTheDocument()
    expect(within(screen.getByTestId("quote-row-q-9")).getByText("—")).toBeInTheDocument() // sin número
  })

  it("is_expired muestra 'Vencido' en el badge y marca la validez en rojo, aunque el estado sea 'enviado'", () => {
    mocks.useQuotes.mockReturnValue(
      listResult([row({ id: "q-3", status: "sent", is_expired: true, valid_until: "2026-09-20" })]),
    )
    render(<QuotesPage />)

    const r = screen.getByTestId("quote-row-q-3")
    expect(within(r).getByText("Vencido")).toBeInTheDocument()
    expect(within(r).queryByText("Enviado")).not.toBeInTheDocument()
    expect(within(r).getByTestId("quote-valid-until")).toHaveClass("text-destructive")
  })

  it("un presupuesto vigente no marca la validez en rojo", () => {
    render(<QuotesPage />)

    expect(within(screen.getByTestId("quote-row-q-1")).getByTestId("quote-valid-until")).not.toHaveClass("text-destructive")
  })
})

describe("QuotesPage — filtros y paginación", () => {
  it("arranca en 'Todos', sin filtro de estado, en la primera página", () => {
    render(<QuotesPage />)

    expect(lastFilters()).toMatchObject({ page: 0 })
    expect(lastFilters().status).toBeUndefined()
    expect(screen.getByRole("button", { name: "Todos" })).toHaveAttribute("aria-pressed", "true")
  })

  it.each([
    ["Borradores", "draft"],
    ["Enviados", "sent"],
    ["Aceptados", "accepted"],
    ["Vencidos", "expired"],
    ["Rechazados", "rejected"],
  ])("la pestaña %s pide status=%s al servidor y vuelve a la primera página", (label, status) => {
    render(<QuotesPage />)

    fireEvent.click(screen.getByRole("button", { name: label }))

    expect(lastFilters()).toMatchObject({ status, page: 0 })
    expect(screen.getByRole("button", { name: label })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByRole("button", { name: "Todos" })).toHaveAttribute("aria-pressed", "false")
  })

  it("volver a 'Todos' quita el filtro de estado", () => {
    render(<QuotesPage />)

    fireEvent.click(screen.getByRole("button", { name: "Enviados" }))
    fireEvent.click(screen.getByRole("button", { name: "Todos" }))

    expect(lastFilters().status).toBeUndefined()
  })

  it("la búsqueda llega al servidor con la espera del debounce y reinicia la página", () => {
    vi.useFakeTimers()
    try {
      render(<QuotesPage />)

      fireEvent.change(screen.getByLabelText(/buscar/i), { target: { value: "P-12" } })
      expect(lastFilters().q).toBeUndefined() // todavía no: se está tipeando

      act(() => {
        vi.advanceTimersByTime(400)
      })
      expect(lastFilters()).toMatchObject({ q: "P-12", page: 0 })
    } finally {
      vi.useRealTimers()
    }
  })

  it("con más de una página muestra el paginado y avanza de página", () => {
    mocks.useQuotes.mockReturnValue({
      data: { items: [row({ id: "q-1" })], total: 60, page: 0, pages: 3 },
      isLoading: false,
      isError: false,
    })
    render(<QuotesPage />)

    expect(screen.getByText(/página 1 de 3/i)).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /página siguiente/i }))

    expect(lastFilters()).toMatchObject({ page: 1 })
  })

  it("con una sola página no muestra el paginado", () => {
    render(<QuotesPage />)

    expect(screen.queryByRole("button", { name: /página siguiente/i })).not.toBeInTheDocument()
  })
})

describe("QuotesPage — estados de carga, error y vacío", () => {
  it("mientras carga muestra un aviso de carga", () => {
    mocks.useQuotes.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    render(<QuotesPage />)

    expect(screen.getByText(/cargando presupuestos/i)).toBeInTheDocument()
  })

  it("ante un error lo dice y no deja la pantalla en blanco", () => {
    mocks.useQuotes.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<QuotesPage />)

    expect(screen.getByText(/no se pudieron cargar los presupuestos/i)).toBeInTheDocument()
  })

  it("sin presupuestos explica qué son y ofrece crear el primero", () => {
    mocks.useQuotes.mockReturnValue(listResult([]))
    render(<QuotesPage />)

    const empty = screen.getByTestId("quotes-empty")
    expect(empty).toHaveTextContent(/todavía no hay presupuestos/i)
    expect(within(empty).getByRole("link", { name: /crear el primero|nuevo presupuesto/i })).toHaveAttribute(
      "href",
      "/presupuestos/nuevo",
    )
  })

  it("filtrando una pestaña sin resultados dice que no hay en ese estado (sin invitar a crear)", () => {
    mocks.useQuotes.mockReturnValue(listResult([]))
    render(<QuotesPage />)

    fireEvent.click(screen.getByRole("button", { name: "Rechazados" }))

    const empty = screen.getByTestId("quotes-empty")
    expect(empty).toHaveTextContent(/no hay presupuestos rechazados/i)
    expect(within(empty).queryByRole("link")).not.toBeInTheDocument()
  })

  it("un empty por búsqueda lo aclara", () => {
    vi.useFakeTimers()
    try {
      mocks.useQuotes.mockReturnValue(listResult([]))
      render(<QuotesPage />)

      fireEvent.change(screen.getByLabelText(/buscar/i), { target: { value: "zzz" } })
      act(() => {
        vi.advanceTimersByTime(400)
      })

      expect(screen.getByTestId("quotes-empty")).toHaveTextContent(/ningún presupuesto coincide/i)
    } finally {
      vi.useRealTimers()
    }
  })
})

describe("QuotesPage — CTA según el rol (CAN_QUOTE sobre el conjunto de roles)", () => {
  it("un usuario sólo 'seller' ve 'Nuevo presupuesto'", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["seller"], rolesResolved: true, isWriter: true, isLoading: false })
    render(<QuotesPage />)

    expect(screen.getByRole("link", { name: /nuevo presupuesto/i })).toHaveAttribute("href", "/presupuestos/nuevo")
  })

  it("un usuario sólo 'cashier' NO lo ve (sí ve el listado)", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["cashier"], rolesResolved: true, isWriter: true, isLoading: false })
    render(<QuotesPage />)

    expect(screen.queryByRole("link", { name: /nuevo presupuesto/i })).not.toBeInTheDocument()
    expect(screen.getByTestId("quote-row-q-1")).toBeInTheDocument()
  })

  it("sin presupuestos y sin permiso, el vacío no invita a crear", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["cashier"], rolesResolved: true, isWriter: true, isLoading: false })
    mocks.useQuotes.mockReturnValue(listResult([]))
    render(<QuotesPage />)

    expect(within(screen.getByTestId("quotes-empty")).queryByRole("link")).not.toBeInTheDocument()
  })

  it("mientras el conjunto de roles no resolvió, el CTA se muestra (fail-open)", () => {
    // `roles` vale [role] = ["member"] para un vendedor: decidir sobre eso lo escondería.
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["member"], rolesResolved: false, isWriter: true, isLoading: true })
    render(<QuotesPage />)

    expect(screen.getByRole("link", { name: /nuevo presupuesto/i })).toBeInTheDocument()
  })

  it("owner y admin también lo ven", () => {
    for (const roles of [["owner"], ["admin"]]) {
      mocks.useOrgRole.mockReturnValue({ role: roles[0], roles, rolesResolved: true, isWriter: true, isLoading: false })
      const { unmount } = render(<QuotesPage />)
      expect(screen.getByRole("link", { name: /nuevo presupuesto/i })).toBeInTheDocument()
      unmount()
    }
  })
})

describe("QuotesPage — validez por defecto", () => {
  it("muestra los días de validez de la cuenta y lleva a la pestaña Cobranzas de Configuración", () => {
    mocks.validityDays.value = 20
    render(<QuotesPage />)

    const notice = screen.getByTestId("quote-validity-notice")
    expect(notice).toHaveTextContent(/validez por defecto: 20 días/i)
    expect(within(notice).getByRole("link", { name: /cambiar/i })).toHaveAttribute(
      "href",
      "/configuracion?tab=cobranzas",
    )
  })

  it("con 1 día usa el singular", () => {
    mocks.validityDays.value = 1
    render(<QuotesPage />)

    expect(screen.getByTestId("quote-validity-notice")).toHaveTextContent(/1 día(?!s)/)
  })

  it("mientras la configuración no cargó no inventa un valor", () => {
    mocks.validityDays.value = undefined
    render(<QuotesPage />)

    expect(screen.queryByTestId("quote-validity-notice")).not.toBeInTheDocument()
  })
})
