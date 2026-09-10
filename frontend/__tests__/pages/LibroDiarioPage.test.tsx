/**
 * /reportes/libro-diario — asiento-contable-gastos (D9/D10, grupo 10).
 *
 * Hallazgo (2) del propose: `GET /journal-entries` existía completo desde
 * `journal-entry-outbox` con CERO consumidores en el frontend.
 *
 *  10.2 lista con fecha, documento, estado, líneas expandibles.
 *  10.3 filtros por rango de fechas, tipo de documento, estado; modo
 *       "asientos de un documento" desde los query params (enlace de 9.6).
 *  10.4 un asiento revertido se distingue de uno vigente sin abrirlo.
 *  10.6 estado vacío y de importación pendiente, sin bloquear nada.
 *  10.7 a11y: tabla anunciada, filtros etiquetados, expansión por teclado.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { JournalEntry } from "@/lib/types"

const mockUseSearchParams = vi.fn()
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
}))

let entriesFixture: JournalEntry[] = []
const setFiltersMock = vi.fn()
const setPageMock = vi.fn()
let filtersFixture: Record<string, string | null> = {}

vi.mock("@/hooks/data/use-journal-entries", () => ({
  useJournalEntries: (opts?: { initialFilters?: Record<string, string | null> }) => {
    // Espeja el comportamiento real: los filtros iniciales del query param
    // quedan en el estado devuelto (para el bloque "modo documento", 10.3).
    const filters = { ...opts?.initialFilters, ...filtersFixture }
    return {
      entries: entriesFixture,
      meta: { page: 0, pageSize: 25, totalCount: entriesFixture.length, pageCount: 1, from: 1, to: entriesFixture.length },
      isLoading: false,
      isError: false,
      error: null,
      filters,
      setFilters: setFiltersMock,
      setPage: setPageMock,
      setPageSize: vi.fn(),
    }
  },
}))

import LibroDiarioPage from "@/app/(dashboard)/reportes/libro-diario/page"

function makeEntry(overrides: Partial<JournalEntry> = {}): JournalEntry {
  return {
    id: "entry-1",
    accountId: "acc-1",
    postedAt: "2026-09-05T15:00:00Z",
    status: "posted",
    sourceDocType: "Expense",
    sourceDocRef: "exp-1",
    reversalOf: null,
    createdAt: "2026-09-05T15:00:00Z",
    lines: [
      { id: "l1", entryId: "entry-1", accountCode: "5300", side: "debit", amount: 1500, lineNo: 1, costCenterId: null },
      { id: "l2", entryId: "entry-1", accountCode: "1100", side: "credit", amount: 1500, lineNo: 2, costCenterId: null },
    ],
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  entriesFixture = [makeEntry()]
  filtersFixture = {}
  mockUseSearchParams.mockReturnValue(new URLSearchParams())
})

// ── 10.2 ──────────────────────────────────────────────────────────────────

describe("/reportes/libro-diario — lista (10.2)", () => {
  it("muestra fecha, documento y estado de cada asiento", () => {
    render(<LibroDiarioPage />)
    const table = screen.getByTestId("journal-entries-table")
    expect(within(table).getByText(/gasto/i)).toBeInTheDocument()
    expect(within(table).getByText(/vigente/i)).toBeInTheDocument()
  })

  it("expandir la fila muestra las líneas de débito y crédito", async () => {
    const user = userEvent.setup()
    render(<LibroDiarioPage />)

    expect(screen.queryByText("5300")).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: /expandir/i }))

    expect(screen.getByText("5300")).toBeInTheDocument()
    expect(screen.getByText("1100")).toBeInTheDocument()
    expect(screen.getAllByText(/débito/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/crédito/i).length).toBeGreaterThan(0)
  })
})

// ── 10.4 ──────────────────────────────────────────────────────────────────

describe("/reportes/libro-diario — vigente vs revertido (10.4)", () => {
  it("un asiento revertido se distingue de uno vigente SIN abrirlo", () => {
    entriesFixture = [
      makeEntry({ id: "e1", status: "posted" }),
      makeEntry({ id: "e2", status: "reversed", reversalOf: null }),
    ]
    render(<LibroDiarioPage />)

    const table = screen.getByTestId("journal-entries-table")
    expect(within(table).getByText(/^vigente$/i)).toBeInTheDocument()
    expect(within(table).getByText(/^revertido$/i)).toBeInTheDocument()
  })
})

// ── 10.3 ──────────────────────────────────────────────────────────────────

describe("/reportes/libro-diario — filtros (10.3)", () => {
  it("el filtro de fechas manda dateFrom/dateTo al hook", async () => {
    const user = userEvent.setup()
    render(<LibroDiarioPage />)

    await user.click(screen.getByRole("button", { name: /filtrar fechas/i }))
    const desde = screen.getByLabelText(/desde/i)
    await user.type(desde, "2026-09-01")

    expect(setFiltersMock).toHaveBeenCalled()
  })

  it("modo 'asientos de un documento': los query params llegan como filtros iniciales", () => {
    mockUseSearchParams.mockReturnValue(new URLSearchParams("source_doc_type=Expense&source_doc_ref=exp-9"))
    render(<LibroDiarioPage />)

    // El banner de modo-documento se muestra cuando hay sourceDocRef.
    expect(screen.getByText(/mostrando los asientos de/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /ver todos/i })).toBeInTheDocument()
  })

  it("filtro por estado ofrece 'Vigente' y 'Revertido'", async () => {
    const user = userEvent.setup()
    render(<LibroDiarioPage />)

    await user.click(screen.getByRole("combobox", { name: /estado del asiento/i }))
    expect(await screen.findByRole("option", { name: /^vigente$/i })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: /^revertido$/i })).toBeInTheDocument()
  })
})

// ── 10.6 ──────────────────────────────────────────────────────────────────

describe("/reportes/libro-diario — tolera el desfase del relay (10.6)", () => {
  it("estado vacío sin filtros explica la espera, no un error", () => {
    entriesFixture = []
    render(<LibroDiarioPage />)

    expect(screen.getByText(/todav[ií]a no hay asientos/i)).toBeInTheDocument()
    expect(screen.queryByText(/error/i)).not.toBeInTheDocument()
  })

  it("estado vacío CON filtro activo dice 'sin resultados', no 'todavía no hay'", () => {
    entriesFixture = []
    filtersFixture = { status: "posted" }
    render(<LibroDiarioPage />)

    expect(screen.getByText(/sin asientos para este filtro/i)).toBeInTheDocument()
  })

  it("el aviso de desfase asincrónico está siempre visible, sin bloquear la pantalla", () => {
    render(<LibroDiarioPage />)
    expect(screen.getByText(/postean de forma asincr[oó]nica/i)).toBeInTheDocument()
  })
})

// ── 10.7 — a11y ─────────────────────────────────────────────────────────────

describe("/reportes/libro-diario — accesibilidad (10.7)", () => {
  it("la tabla tiene un caption anunciado por el lector de pantalla", () => {
    render(<LibroDiarioPage />)
    const table = screen.getByTestId("journal-entries-table")
    expect(within(table).getByText(/libro diario/i)).toBeInTheDocument()
  })

  it("los filtros tienen nombre accesible (combobox con label)", () => {
    render(<LibroDiarioPage />)
    expect(screen.getByRole("combobox", { name: /tipo de documento/i })).toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: /estado del asiento/i })).toBeInTheDocument()
  })

  it("la expansión de líneas es operable por teclado (botón real con aria-expanded)", async () => {
    const user = userEvent.setup()
    render(<LibroDiarioPage />)

    const toggle = screen.getByRole("button", { name: /expandir/i })
    expect(toggle).toHaveAttribute("aria-expanded", "false")

    toggle.focus()
    await user.keyboard("{Enter}")

    expect(screen.getByRole("button", { name: /contraer/i })).toHaveAttribute("aria-expanded", "true")
  })
})
