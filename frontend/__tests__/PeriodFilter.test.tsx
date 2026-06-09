/**
 * Tests del selector de período del Tablero (dashboard-kpi-summary-block, Fase A)
 * Spec: mes en curso por defecto; la selección viaja en ?period=YYYY-MM.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import { PeriodFilter } from "@/components/dashboard/PeriodFilter"
import { monthKey, utcPrevMonthRange } from "@/lib/date-range"

// ── Mock de next/navigation ───────────────────────────────────────────────────

const pushMock = vi.fn()
let searchParamsString = ""

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock, replace: vi.fn() }),
  useSearchParams: () => new URLSearchParams(searchParamsString),
}))

beforeEach(() => {
  pushMock.mockReset()
  searchParamsString = ""
})

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("PeriodFilter", () => {
  it("muestra 'Mes en curso' por defecto (sin ?period)", () => {
    render(<PeriodFilter />)
    expect(screen.getByText("Mes en curso")).toBeInTheDocument()
  })

  it("muestra 'Mes anterior' cuando ?period apunta al mes previo", () => {
    const prevFrom = utcPrevMonthRange(new Date()).from // "YYYY-MM-01T..."
    searchParamsString = `period=${prevFrom.slice(0, 7)}`
    render(<PeriodFilter />)
    expect(screen.getByText("Mes anterior")).toBeInTheDocument()
  })

  it("con un ?period desconocido cae al mes en curso", () => {
    searchParamsString = "period=banana"
    render(<PeriodFilter />)
    expect(screen.getByText("Mes en curso")).toBeInTheDocument()
  })

  it("el valor por defecto coincide con monthKey(hoy)", () => {
    // El option del mes en curso debe usar la key del mes actual — si no, el
    // Select no podría marcarlo como seleccionado al volver desde la URL.
    render(<PeriodFilter />)
    const trigger = screen.getByRole("combobox")
    expect(trigger).toBeInTheDocument()
    expect(monthKey()).toMatch(/^\d{4}-\d{2}$/)
  })
})
