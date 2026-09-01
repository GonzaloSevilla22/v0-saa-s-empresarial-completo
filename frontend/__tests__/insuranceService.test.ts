/**
 * fix/admin-seguros-timeseries: `processTimeSeries` alimentaba el gráfico
 * "Evolución temporal" de /admin/seguros con `{ name: "Ene".."Dic", value }`
 * — `TimeSeriesLinesChart` espera `{ period: string parseable; activations }`
 * y hace `new Date(d.period)`, así que "Ene" producía `Invalid Date` (eje/
 * extent D3 rotos). Además agregaba solo por nombre de mes: marzo 2026 y
 * marzo 2027 se mezclaban en el mismo bucket.
 *
 * Este test fija el contrato correcto: `period` es una fecha ISO real
 * (primero del mes, UTC), la agregación es por AÑO+mes, el resultado sale
 * ordenado cronológicamente, y el shape ya es el que consume el chart
 * directo — sin adapter en el JSX ni campo `umv_achieved` inventado.
 */

import { describe, it, expect, vi } from "vitest"

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({}),
}))

import { insuranceService } from "@/lib/services/insuranceService"

describe("insuranceService.processTimeSeries", () => {
  it("n=0: sin filas produce una serie vacía (no un bucket basura)", () => {
    expect(insuranceService.processTimeSeries([])).toEqual([])
  })

  it("n=1: una sola fila produce un único punto con activations=1 y period parseable como fecha real", () => {
    const result = insuranceService.processTimeSeries([{ created_at: "2026-03-05T12:00:00.000Z" }])

    expect(result).toHaveLength(1)
    expect(result[0]!.activations).toBe(1)
    expect(Number.isNaN(new Date(result[0]!.period).getTime())).toBe(false)
  })

  it("REGRESSION: el shape es { period, activations } directo — sin name/value/umv_achieved inventados", () => {
    const result = insuranceService.processTimeSeries([{ created_at: "2026-03-01T00:00:00.000Z" }])

    expect(result[0]).toEqual({ period: expect.any(String), activations: 1 })
    expect(result[0]).not.toHaveProperty("name")
    expect(result[0]).not.toHaveProperty("value")
    expect(result[0]).not.toHaveProperty("umv_achieved")
  })

  it("REGRESSION: agrega por AÑO+mes — marzo 2026 y marzo 2027 no se mezclan en el mismo bucket", () => {
    const result = insuranceService.processTimeSeries([
      { created_at: "2026-03-01T00:00:00.000Z" },
      { created_at: "2026-03-20T00:00:00.000Z" },
      { created_at: "2027-03-10T00:00:00.000Z" },
    ])

    expect(result).toHaveLength(2)
    const march2026 = result.find((p) => new Date(p.period).getUTCFullYear() === 2026)
    const march2027 = result.find((p) => new Date(p.period).getUTCFullYear() === 2027)
    expect(march2026?.activations).toBe(2)
    expect(march2027?.activations).toBe(1)
  })

  it("ordena los puntos cronológicamente ascendente, sin importar el orden de las filas de entrada", () => {
    const result = insuranceService.processTimeSeries([
      { created_at: "2026-08-01T00:00:00.000Z" },
      { created_at: "2026-01-01T00:00:00.000Z" },
      { created_at: "2026-05-01T00:00:00.000Z" },
    ])

    const times = result.map((p) => new Date(p.period).getTime())
    expect(times).toEqual([...times].sort((a, b) => a - b))
    expect(result.map((p) => new Date(p.period).getUTCMonth())).toEqual([0, 4, 7])
  })

  it("cada period cae en el primer día del mes (UTC), no en la fecha exacta de la fila", () => {
    const result = insuranceService.processTimeSeries([{ created_at: "2026-06-27T18:45:00.000Z" }])

    const d = new Date(result[0]!.period)
    expect(d.getUTCDate()).toBe(1)
    expect(d.getUTCMonth()).toBe(5) // junio, 0-indexed
    expect(d.getUTCFullYear()).toBe(2026)
  })
})
