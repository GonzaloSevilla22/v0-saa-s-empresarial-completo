/**
 * tablero-explicable (D1-D2, tasks 1.1/1.2): rango, granularidad y alineación
 * de la comparación del gráfico de ventas del Tablero. Funciones puras de la
 * capa canónica lib/sales-statistics.ts.
 */
import { describe, it, expect } from "vitest"
import {
  alignComparisonSeries,
  chartBucketFor,
  chartPresetLabel,
  chartPresetRange,
} from "@/lib/sales-statistics"

describe("chartBucketFor", () => {
  it("usa día hasta 31 días inclusive", () => {
    expect(chartBucketFor("2026-11-01", "2026-11-07")).toBe("day") // 7 días
    expect(chartBucketFor("2026-10-01", "2026-10-31")).toBe("day") // 31 días
  })

  it("pasa a semana desde 32 días y hasta 180", () => {
    expect(chartBucketFor("2026-10-01", "2026-11-01")).toBe("week") // 32 días
    expect(chartBucketFor("2026-05-11", "2026-11-06")).toBe("week") // 180 días
  })

  it("pasa a mes desde 181 días", () => {
    expect(chartBucketFor("2026-05-10", "2026-11-06")).toBe("month") // 181 días
    expect(chartBucketFor("2025-11-07", "2026-11-06")).toBe("month") // 365 días
  })

  it("un solo día es una serie diaria", () => {
    expect(chartBucketFor("2026-11-06", "2026-11-06")).toBe("day")
  })
})

describe("chartPresetRange", () => {
  const AHORA = new Date("2026-11-06T15:00:00.000Z") // 12:00 ART

  it("7d = [hoy-6, hoy] en día argentino", () => {
    expect(chartPresetRange("7d", AHORA)).toEqual({ start: "2026-10-31", end: "2026-11-06" })
  })

  it("30d y 90d cuentan hoy como el último día", () => {
    expect(chartPresetRange("30d", AHORA)).toEqual({ start: "2026-10-08", end: "2026-11-06" })
    expect(chartPresetRange("90d", AHORA)).toEqual({ start: "2026-08-09", end: "2026-11-06" })
  })

  it("a las 22:00 ART (01:00 UTC del día siguiente) hoy sigue siendo el día argentino", () => {
    const noche = new Date("2026-11-07T01:00:00.000Z") // 22:00 ART del 6
    expect(chartPresetRange("7d", noche)).toEqual({ start: "2026-10-31", end: "2026-11-06" })
  })

  it("el rango resultante tiene el bucket esperado", () => {
    const r30 = chartPresetRange("30d", AHORA)
    expect(chartBucketFor(r30.start, r30.end)).toBe("day")
    const r90 = chartPresetRange("90d", AHORA)
    expect(chartBucketFor(r90.start, r90.end)).toBe("week")
  })
})

describe("chartPresetLabel", () => {
  it("rotula los presets y el personalizado", () => {
    expect(chartPresetLabel("7d", "2026-10-31", "2026-11-06")).toBe("Ventas · últimos 7 días")
    expect(chartPresetLabel("90d", "2026-08-09", "2026-11-06")).toBe("Ventas · últimos 90 días")
    expect(chartPresetLabel("custom", "2026-10-01", "2026-10-15")).toBe("Ventas · 01/10/2026 → 15/10/2026")
  })
})

describe("alignComparisonSeries", () => {
  it("alinea por índice con el mismo largo", () => {
    expect(alignComparisonSeries([1, 2, 3], [10, 20, 30])).toEqual([10, 20, 30])
  })

  it("rellena con null cuando el anterior tiene menos puntos", () => {
    expect(alignComparisonSeries([1, 2, 3, 4], [10, 20])).toEqual([10, 20, null, null])
  })

  it("nunca devuelve más puntos que el actual", () => {
    expect(alignComparisonSeries([1, 2], [10, 20, 30, 40])).toEqual([10, 20])
  })

  it("sin período anterior devuelve todo null", () => {
    expect(alignComparisonSeries([1, 2, 3], [])).toEqual([null, null, null])
  })
})
