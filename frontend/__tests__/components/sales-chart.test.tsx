/**
 * tablero-explicable (D1-D3, task 1.3): el gráfico de ventas del Tablero con
 * rango elegible y comparación contra el período anterior, desde la fuente
 * canónica de /estadisticas (useSalesEvolution). Reemplaza a
 * sales-chart-art-bucketing / sales-chart-day-labels, que fijaban la
 * agregación en el cliente (sumar las 25 ventas más recientes) que se retira:
 * sus aserciones de rótulo de día pasan acá vía formatBucketLabel (fecha de
 * negocio por partes, sin huso).
 *
 * recharts no renderiza SVG útil en jsdom: se mockea ReportTimeSeriesChart
 * para capturar las props que el componente calcula.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

import type { SalesEvolution } from "@/lib/sales-statistics"

// ── Mocks ────────────────────────────────────────────────────────────────────

interface CapturedChart {
  data: Array<{ label: string; value: number; secondary?: number }>
  valueName: string
  secondaryName?: string
  ariaLabel: string
}
let chart: CapturedChart | null = null

vi.mock("@/components/charts/ReportTimeSeriesChart", () => ({
  ReportTimeSeriesChart: (props: CapturedChart) => {
    chart = props
    return <div data-testid="time-series-chart" />
  },
}))

// El componente NO puede volver a agregar ventas desde un listado paginado.
const useSalesMock = vi.fn(() => {
  throw new Error("SalesChart no debe llamar a useSales")
})
vi.mock("@/hooks/data/use-sales", () => ({ useSales: () => useSalesMock() }))

let planHistoryDays = 365
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { historyDays: planHistoryDays } }),
}))

interface EvolutionCall {
  start: string
  end: string
  bucket: string
  branchId?: string | null
  enabled?: boolean
}
const evolutionCalls: EvolutionCall[] = []
let respond: (call: EvolutionCall) => { data: SalesEvolution | undefined; isError?: boolean }

vi.mock("@/hooks/data/use-sales-statistics", () => ({
  useSalesEvolution: (params: EvolutionCall) => {
    evolutionCalls.push(params)
    if (params.enabled === false) return { data: undefined, isLoading: false, isError: false }
    const r = respond(params)
    return { data: r.data, isLoading: !r.data, isError: r.isError ?? false }
  },
}))

// ── Fixtures ─────────────────────────────────────────────────────────────────

function metrics(net: number, operations = 1) {
  return { revenue: net, creditNotes: 0, netRevenue: net, units: operations, operations, serviceRevenue: 0 }
}

function days(start: string, count: number): string[] {
  const [y, m, d] = start.split("-").map(Number)
  return Array.from({ length: count }, (_, i) =>
    new Date(Date.UTC(y, m - 1, d + i)).toISOString().slice(0, 10),
  )
}

function evolution(opts: {
  start: string
  end: string
  count: number
  perPoint: number
  prevStart: string
  prevEnd: string
  prevTotal: number
  clamped?: boolean
  bucket?: "day" | "week" | "month"
}): SalesEvolution {
  const keys = days(opts.start, opts.count)
  return {
    bucket: opts.bucket ?? "day",
    window: { start: opts.start, end: opts.end, historyDays: 30, clamped: opts.clamped ?? false },
    points: keys.map((k) => ({ bucketStart: k, bucketEnd: k, ...metrics(opts.perPoint) })),
    current: { start: opts.start, end: opts.end, ...metrics(opts.perPoint * opts.count, 60) },
    previous: { start: opts.prevStart, end: opts.prevEnd, ...metrics(opts.prevTotal, 40) },
  }
}

const AHORA = new Date("2026-11-06T15:00:00.000Z") // 12:00 ART del 6/nov/2026

import { SalesChart } from "@/components/dashboard/sales-chart"

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(AHORA)
  chart = null
  evolutionCalls.length = 0
  planHistoryDays = 365
  respond = (call) => {
    if (call.start === "2026-10-31") {
      return { data: evolution({ start: "2026-10-31", end: "2026-11-06", count: 7, perPoint: 1000, prevStart: "2026-10-24", prevEnd: "2026-10-30", prevTotal: 5000 }) }
    }
    if (call.start === "2026-10-24") {
      return { data: evolution({ start: "2026-10-24", end: "2026-10-30", count: 7, perPoint: 700, prevStart: "2026-10-17", prevEnd: "2026-10-23", prevTotal: 0 }) }
    }
    if (call.start === "2026-10-08") {
      return { data: evolution({ start: "2026-10-08", end: "2026-11-06", count: 30, perPoint: 500, prevStart: "2026-09-08", prevEnd: "2026-10-07", prevTotal: 12000 }) }
    }
    return { data: evolution({ start: call.start, end: call.end, count: 30, perPoint: 400, prevStart: "2026-09-08", prevEnd: "2026-10-07", prevTotal: 0 }) }
  }
})

afterEach(() => {
  vi.useRealTimers()
})

// ── Tests ────────────────────────────────────────────────────────────────────

describe("SalesChart — fuente canónica, rango y comparación", () => {
  it("por defecto pide los últimos 7 días argentinos con la sucursal del Tablero", () => {
    render(<SalesChart branchId="branch-1" />)

    const first = evolutionCalls[0]
    expect(first).toMatchObject({ start: "2026-10-31", end: "2026-11-06", bucket: "day", branchId: "branch-1" })
    expect(screen.getByText("Ventas · últimos 7 días")).toBeInTheDocument()
  })

  it("la suma de los puntos viene del read-model (60 ventas en el rango), nunca de useSales", () => {
    render(<SalesChart />)

    expect(useSalesMock).not.toHaveBeenCalled()
    expect(chart).not.toBeNull()
    expect(chart!.data).toHaveLength(7)
    expect(chart!.data.reduce((acc, p) => acc + p.value, 0)).toBe(7000)
  })

  it("rotula cada punto con el día calendario de su clave, sin corrimiento de huso (31/oct → 06/11)", () => {
    render(<SalesChart />)

    const labels = chart!.data.map((p) => p.label)
    expect(labels[0]).toBe("31/10")
    expect(labels[3]).toBe("03/11")
    expect(labels[6]).toBe("06/11")
  })

  it("la segunda consulta usa previous.start/end de la primera y sólo se habilita después", () => {
    render(<SalesChart />)

    const comparison = evolutionCalls.filter((c) => c.start === "2026-10-24")
    expect(comparison.length).toBeGreaterThan(0)
    expect(comparison[comparison.length - 1]).toMatchObject({ start: "2026-10-24", end: "2026-10-30", bucket: "day" })
    // El primer render (sin datos de la primera) llama a la segunda deshabilitada.
    const secondCalls = evolutionCalls.filter((c) => c.enabled !== undefined)
    expect(secondCalls[0].enabled).toBe(true) // con el mock síncrono la primera ya respondió
  })

  it("la segunda consulta queda deshabilitada mientras la primera no respondió", () => {
    respond = () => ({ data: undefined })
    render(<SalesChart />)

    const second = evolutionCalls.filter((c) => c.enabled !== undefined)
    expect(second.length).toBeGreaterThan(0)
    expect(second.every((c) => c.enabled === false)).toBe(true)
  })

  it("dibuja la serie del período anterior alineada por índice y la variación del total", () => {
    render(<SalesChart />)

    expect(chart!.secondaryName).toBe("Período anterior")
    expect(chart!.data.map((p) => p.secondary)).toEqual([700, 700, 700, 700, 700, 700, 700])
    // 7000 contra 5000 → +40 %
    expect(screen.getByText(/\+40%/)).toBeInTheDocument()
  })

  it("cambiar a 30 días pide start/end/bucket nuevos y su comparación", async () => {
    vi.useRealTimers()
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(AHORA)
    const user = userEvent.setup({ advanceTimers: () => {} })
    render(<SalesChart />)

    await user.click(screen.getByRole("radio", { name: "30 días" }))

    const last = evolutionCalls.filter((c) => c.enabled === undefined || c.enabled === true)
    expect(last.some((c) => c.start === "2026-10-08" && c.end === "2026-11-06" && c.bucket === "day")).toBe(true)
    expect(screen.getByText("Ventas · últimos 30 días")).toBeInTheDocument()
    expect(chart!.data).toHaveLength(30)
    // La comparación de 30 días usa el período anterior que informó la RPC.
    expect(evolutionCalls.some((c) => c.start === "2026-09-08" && c.end === "2026-10-07")).toBe(true)
  })

  it("con 90 días la granularidad pasa a semana", async () => {
    const user = userEvent.setup({ advanceTimers: () => {} })
    render(<SalesChart />)

    await user.click(screen.getByRole("radio", { name: "90 días" }))

    expect(evolutionCalls.some((c) => c.start === "2026-08-09" && c.end === "2026-11-06" && c.bucket === "week")).toBe(true)
  })

  it("con la comparación fuera del historial del plan no dibuja la serie anterior ni la variación y avisa con enlace a /planes", () => {
    respond = (call) => {
      if (call.start === "2026-10-31") {
        return { data: evolution({ start: "2026-10-31", end: "2026-11-06", count: 7, perPoint: 1000, prevStart: "2026-10-24", prevEnd: "2026-10-30", prevTotal: 5000 }) }
      }
      return { data: evolution({ start: "2026-10-26", end: "2026-10-30", count: 5, perPoint: 700, prevStart: "2026-10-17", prevEnd: "2026-10-23", prevTotal: 0, clamped: true }) }
    }
    render(<SalesChart />)

    expect(chart!.secondaryName).toBeUndefined()
    expect(chart!.data.every((p) => p.secondary === undefined)).toBe(true)
    expect(screen.queryByText(/vs\.? período anterior/i)).not.toBeInTheDocument()
    expect(screen.getByText(/El período anterior queda fuera del historial de tu plan/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /planes/i })).toHaveAttribute("href", "/planes")
  })

  it("si la primera consulta viene recortada se reutiliza el aviso de historial de /estadisticas", () => {
    respond = () => ({
      data: evolution({ start: "2026-10-31", end: "2026-11-06", count: 7, perPoint: 1000, prevStart: "2026-10-24", prevEnd: "2026-10-30", prevTotal: 5000, clamped: true }),
    })
    render(<SalesChart />)

    expect(screen.getByText(/Tu plan permite consultar 30 días de historial/)).toBeInTheDocument()
    expect(chart!.secondaryName).toBeUndefined()
  })

  it("sin base de comparación (anterior = 0) no inventa una variación", () => {
    respond = (call) => {
      if (call.start === "2026-10-31") {
        return { data: evolution({ start: "2026-10-31", end: "2026-11-06", count: 7, perPoint: 1000, prevStart: "2026-10-24", prevEnd: "2026-10-30", prevTotal: 0 }) }
      }
      return { data: evolution({ start: "2026-10-24", end: "2026-10-30", count: 7, perPoint: 0, prevStart: "2026-10-17", prevEnd: "2026-10-23", prevTotal: 0 }) }
    }
    render(<SalesChart />)

    expect(screen.queryByText(/vs\.? período anterior/i)).not.toBeInTheDocument()
  })

  it("el rango personalizado expone dos fechas y usa el rango elegido", async () => {
    const user = userEvent.setup({ advanceTimers: () => {} })
    render(<SalesChart />)

    await user.click(screen.getByRole("radio", { name: "Personalizado" }))

    expect(screen.getByRole("button", { name: "Fecha desde" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Fecha hasta" })).toBeInTheDocument()
    // Arranca con el rango que estaba activo (7 días).
    expect(screen.getByText(/Ventas · 31\/10\/2026 → 06\/11\/2026/)).toBeInTheDocument()
  })

  it("muestra un error legible si la consulta falla", () => {
    respond = () => ({ data: undefined, isError: true })
    render(<SalesChart />)

    expect(screen.getByRole("alert")).toHaveTextContent(/No pudimos cargar/)
  })
})
