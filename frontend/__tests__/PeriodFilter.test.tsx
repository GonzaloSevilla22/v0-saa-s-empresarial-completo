/**
 * Tests del selector de período del Tablero (dashboard-kpi-summary-block, Fase A)
 * Spec: mes en curso por defecto; la selección viaja en ?period=YYYY-MM.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"
import { PeriodFilter } from "@/components/dashboard/PeriodFilter"
import { monthKey } from "@/lib/date-range"

// ── Mock de next/navigation ───────────────────────────────────────────────────

const pushMock = vi.fn()
let searchParamsString = ""

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock, replace: vi.fn() }),
  useSearchParams: () => new URLSearchParams(searchParamsString),
}))

// app-timezone-argentina: reloj fijo (instante absoluto ISO con Z) — este
// mismo test, con `new Date()` real, pasaba en local (huso ART/cercano) y
// fallaba en CI (UTC): "Mes anterior" comparaba contra un prevKey construido
// con componentes LOCALES del runtime y leído con monthKey (ART), lo que en
// un runtime UTC caía DOS meses atrás en vez de uno. Instante fijo = mismo
// resultado en cualquier huso de CI/dev.
const FIXED_INSTANT = "2026-06-17T15:00:00.000Z" // 12:00 ART, 17/jun/2026

beforeEach(() => {
  pushMock.mockReset()
  searchParamsString = ""
  vi.useFakeTimers()
  vi.setSystemTime(new Date(FIXED_INSTANT))
})

afterEach(() => {
  vi.useRealTimers()
})

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("PeriodFilter", () => {
  it("muestra 'Mes en curso' por defecto (sin ?period)", () => {
    render(<PeriodFilter />)
    expect(screen.getByText("Mes en curso")).toBeInTheDocument()
  })

  it("muestra 'Mes anterior' cuando ?period apunta al mes previo", () => {
    searchParamsString = "period=2026-05"
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
    expect(monthKey()).toBe("2026-06")
  })
})
