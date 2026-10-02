/**
 * presupuestos-modulo (D10/D12, tarea 5.7) — `/presupuestos/nuevo` y
 * `/presupuestos/[id]/editar`.
 *
 * Son páginas finas: resuelven de dónde viene el formulario (`?cliente=`,
 * `?duplicar=`, el presupuesto a editar) y NO montan el `QuoteForm` hasta que el
 * catálogo y las unidades cargaron — el formulario rehidrata las líneas UNA vez
 * al montar, y con el catálogo vacío marcaría todos los productos como "no
 * disponibles".
 *
 * La edición de un presupuesto convertido muestra el motivo (`P0423`
 * traducido) y un enlace al detalle; la de un vencido o rechazado abre el
 * editor, que es quien avisa la reapertura.
 */
import React, { useEffect } from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { QuoteApiRow } from "@/lib/quote-types"

const mocks = vi.hoisted(() => ({
  searchParams: new URLSearchParams(),
  params: { id: "q-1" },
  useQuote: vi.fn(),
  useOrgRole: vi.fn(),
  useProducts: vi.fn(),
  useUnitsOfMeasure: vi.fn(),
  mounts: vi.fn(),
}))

vi.mock("next/navigation", () => ({
  useSearchParams: () => mocks.searchParams,
  useParams: () => mocks.params,
  useRouter: () => ({ push: vi.fn() }),
}))
vi.mock("@/hooks/data/use-quotes", () => ({ useQuote: (id: string | null) => mocks.useQuote(id) }))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => mocks.useProducts() }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => mocks.useUnitsOfMeasure() }))
vi.mock("@/components/quotes/QuoteForm", () => ({
  QuoteForm: (props: { quote?: QuoteApiRow; duplicateFrom?: QuoteApiRow; initialClientId?: string }) => {
    useEffect(() => {
      mocks.mounts()
    }, [])
    return (
      <div
        data-testid="quote-form"
        data-quote={props.quote?.id ?? ""}
        data-duplicate={props.duplicateFrom?.id ?? ""}
        data-client={props.initialClientId ?? ""}
      />
    )
  },
}))

import NewQuotePage from "@/app/(dashboard)/presupuestos/nuevo/page"
import EditQuotePage from "@/app/(dashboard)/presupuestos/[id]/editar/page"

function quote(overrides: Partial<QuoteApiRow> = {}): QuoteApiRow {
  return {
    id: "q-1",
    number: 12,
    number_label: "P-00000012",
    status: "sent",
    revision: 3,
    client_id: "c-1",
    client_name: "Ana Pérez",
    client_phone: "2615551234",
    branch_id: null,
    valid_until: "2026-10-16",
    notes: null,
    total: "100",
    sent_at: null,
    created_at: "2026-10-01T12:00:00Z",
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

const READY = { products: [], isLoading: false }

beforeEach(() => {
  vi.clearAllMocks()
  mocks.searchParams = new URLSearchParams()
  mocks.params = { id: "q-1" }
  mocks.useOrgRole.mockReturnValue({ role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false })
  mocks.useProducts.mockReturnValue(READY)
  mocks.useUnitsOfMeasure.mockReturnValue({ units: [], unitsById: new Map(), loading: false, error: null })
  mocks.useQuote.mockReturnValue({ data: quote(), isLoading: false, isError: false })
})

describe("/presupuestos/nuevo", () => {
  it("monta un formulario vacío", () => {
    render(<NewQuotePage />)

    const form = screen.getByTestId("quote-form")
    expect(form).toHaveAttribute("data-quote", "")
    expect(form).toHaveAttribute("data-duplicate", "")
    expect(form).toHaveAttribute("data-client", "")
  })

  it("?cliente= llega como cliente preseleccionado", () => {
    mocks.searchParams = new URLSearchParams("cliente=c-77")
    render(<NewQuotePage />)

    expect(screen.getByTestId("quote-form")).toHaveAttribute("data-client", "c-77")
  })

  it("?duplicar= carga ese presupuesto y lo pasa como origen del duplicado", () => {
    mocks.searchParams = new URLSearchParams("duplicar=q-5")
    mocks.useQuote.mockReturnValue({ data: quote({ id: "q-5" }), isLoading: false, isError: false })
    render(<NewQuotePage />)

    expect(mocks.useQuote).toHaveBeenCalledWith("q-5")
    expect(screen.getByTestId("quote-form")).toHaveAttribute("data-duplicate", "q-5")
  })

  it("sin ?duplicar= no pide ningún presupuesto", () => {
    render(<NewQuotePage />)

    expect(mocks.useQuote).toHaveBeenCalledWith(null)
  })

  it("mientras carga el presupuesto a duplicar no monta el formulario", () => {
    mocks.searchParams = new URLSearchParams("duplicar=q-5")
    mocks.useQuote.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    render(<NewQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
    expect(screen.getByText(/cargando/i)).toBeInTheDocument()
  })

  it("si el presupuesto a duplicar no se pudo cargar, lo dice con un enlace al listado", () => {
    mocks.searchParams = new URLSearchParams("duplicar=q-5")
    mocks.useQuote.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<NewQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudo cargar/i)
    expect(screen.getByRole("link", { name: /volver a presupuestos/i })).toHaveAttribute("href", "/presupuestos")
  })

  it("espera al catálogo: con los productos cargando no monta el formulario", () => {
    mocks.useProducts.mockReturnValue({ products: [], isLoading: true })
    render(<NewQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
  })

  it("espera a las unidades: con las unidades cargando no monta el formulario", () => {
    mocks.useUnitsOfMeasure.mockReturnValue({ units: [], unitsById: new Map(), loading: true, error: null })
    render(<NewQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
  })

  it("un usuario sin permiso para presupuestar ve el motivo y no el formulario", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["cashier"], rolesResolved: true, isWriter: true, isLoading: false })
    render(<NewQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/tu rol no permite/i)
  })

  it("un vendedor (sólo 'seller') sí lo ve", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["seller"], rolesResolved: true, isWriter: true, isLoading: false })
    render(<NewQuotePage />)

    expect(screen.getByTestId("quote-form")).toBeInTheDocument()
  })
})

describe("/presupuestos/[id]/editar", () => {
  it("carga el presupuesto por el id de la ruta y monta el formulario en modo edición", () => {
    mocks.params = { id: "q-9" }
    mocks.useQuote.mockReturnValue({ data: quote({ id: "q-9" }), isLoading: false, isError: false })
    render(<EditQuotePage />)

    expect(mocks.useQuote).toHaveBeenCalledWith("q-9")
    expect(screen.getByTestId("quote-form")).toHaveAttribute("data-quote", "q-9")
  })

  it.each(["draft", "sent", "expired", "rejected"] as const)(
    "un presupuesto %s se puede editar (el formulario avisa la reapertura cuando corresponde)",
    (status) => {
      mocks.useQuote.mockReturnValue({ data: quote({ status }), isLoading: false, isError: false })
      render(<EditQuotePage />)

      expect(screen.getByTestId("quote-form")).toBeInTheDocument()
    },
  )

  it("un presupuesto convertido en venta no abre el editor: muestra el motivo y un enlace al detalle", () => {
    mocks.useQuote.mockReturnValue({ data: quote({ status: "accepted" }), isLoading: false, isError: false })
    render(<EditQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/ya se convirtió en una venta/i)
    expect(screen.getByRole("link", { name: /ver el presupuesto/i })).toHaveAttribute("href", "/presupuestos/q-1")
  })

  it("mientras carga muestra un aviso y no monta el formulario", () => {
    mocks.useQuote.mockReturnValue({ data: undefined, isLoading: true, isError: false })
    render(<EditQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
    expect(screen.getByText(/cargando/i)).toBeInTheDocument()
  })

  it("si no se pudo cargar (inexistente o de otra cuenta) lo dice con un enlace al listado", () => {
    mocks.useQuote.mockReturnValue({ data: undefined, isLoading: false, isError: true })
    render(<EditQuotePage />)

    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudo cargar/i)
    expect(screen.getByRole("link", { name: /volver a presupuestos/i })).toHaveAttribute("href", "/presupuestos")
  })

  it("espera al catálogo antes de montar el formulario", () => {
    mocks.useProducts.mockReturnValue({ products: [], isLoading: true })
    render(<EditQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
  })

  it("un usuario sin permiso ve el motivo y no el editor", () => {
    mocks.useOrgRole.mockReturnValue({ role: "member", roles: ["cashier"], rolesResolved: true, isWriter: true, isLoading: false })
    render(<EditQuotePage />)

    expect(screen.queryByTestId("quote-form")).not.toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent(/tu rol no permite/i)
  })

  it("si la revisión cambia (otro usuario editó y se recargó) el formulario se vuelve a montar con los datos nuevos", () => {
    const { rerender } = render(<EditQuotePage />)
    expect(mocks.mounts).toHaveBeenCalledTimes(1)

    mocks.useQuote.mockReturnValue({ data: quote({ revision: 4 }), isLoading: false, isError: false })
    rerender(<EditQuotePage />)

    expect(mocks.mounts).toHaveBeenCalledTimes(2)
  })

  it("si la revisión no cambia el formulario NO se desmonta (no se pierde lo que el usuario tipeó)", () => {
    const { rerender } = render(<EditQuotePage />)

    mocks.useQuote.mockReturnValue({ data: quote({ notes: "refresco de fondo" }), isLoading: false, isError: false })
    rerender(<EditQuotePage />)

    expect(mocks.mounts).toHaveBeenCalledTimes(1)
  })
})
