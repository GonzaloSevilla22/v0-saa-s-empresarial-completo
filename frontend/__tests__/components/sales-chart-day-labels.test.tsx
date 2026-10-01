import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render } from "@testing-library/react"
import { SalesChart } from "@/components/dashboard/sales-chart"

// tablero-menu-pulido (P1): el gráfico "Ventas últimos 7 días" rotulaba cada
// punto UN DÍA ATRÁS en navegadores con huso negativo (Argentina, UTC-3): el
// eje usaba `new Date("YYYY-MM-DD")`, que JS interpreta como medianoche UTC, y
// `toLocaleDateString` la lee en la zona LOCAL -> el jueves 1 salía "mié 30".
// Los buckets (`argentinaDaysAgo`) estaban bien; sólo fallaba el rótulo.
//
// El test fija el huso del proceso (`process.env.TZ`) en cada caso, así protege
// la regresión igual en la máquina del dev (Argentina) que en el CI (UTC): con
// el código viejo es ROJO en los husos negativos, y VERDE en todos con el fix.
//
// recharts no renderiza SVG útil en jsdom (ResponsiveContainer mide 0x0): se
// mockea `AreaChart` para capturar el `data` que calcula el componente.

let capturedData: Array<{ date: string; ventas: number }> = []

vi.mock("recharts", () => ({
  ResponsiveContainer: ({ children }: { children: React.ReactNode }) => <>{children}</>,
  AreaChart: ({ data }: { data: Array<{ date: string; ventas: number }> }) => {
    capturedData = data
    return null
  },
  Area: () => null,
  XAxis: () => null,
  YAxis: () => null,
  CartesianGrid: () => null,
  Tooltip: () => null,
}))

vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({ sales: [] }),
}))

// Día de la semana calculado sobre el día CALENDARIO de la clave, sin pasar por
// ningún huso: es la verdad contra la que se compara el rótulo del eje.
const SEMANA = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"] as const

function esperado(key: string): string {
  const [y, m, d] = key.split("-").map(Number)
  const dia = SEMANA[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]
  return `${dia} ${d}`
}

// 12:00 ART del jueves 1/oct/2026 -> los 7 buckets son vie 25/sep .. jue 1/oct
// (cruzan el borde de mes: 30/sep -> 1/oct).
const AHORA = new Date("2026-10-01T15:00:00.000Z")
const CLAVES = ["2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"]

// Husos negativos (donde nace el bug), UTC y positivo (control de que el fix no
// corrompe a quienes ya veían bien el gráfico).
const HUSOS = [
  "America/Argentina/Buenos_Aires",
  "Pacific/Honolulu",
  "UTC",
  "Pacific/Kiritimati",
] as const

describe("SalesChart — rótulos del eje X por día calendario (tablero-menu-pulido P1)", () => {
  const tzOriginal = process.env.TZ

  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(AHORA)
  })

  afterEach(() => {
    vi.useRealTimers()
    capturedData = []
    if (tzOriginal === undefined) delete process.env.TZ
    else process.env.TZ = tzOriginal
  })

  it.each(HUSOS)("huso %s: los 7 rótulos coinciden con el día calendario de cada bucket", (tz) => {
    process.env.TZ = tz
    render(<SalesChart />)

    expect(capturedData).toHaveLength(7)
    expect(capturedData.map((p) => p.date)).toEqual(CLAVES.map(esperado))
  })

  it("REGRESSION: el último punto (hoy) dice 'jue 1', no el día anterior 'mié 30', con el huso argentino", () => {
    process.env.TZ = "America/Argentina/Buenos_Aires"
    render(<SalesChart />)

    expect(capturedData[capturedData.length - 1].date).toBe("jue 1")
    expect(capturedData[0].date).toBe("vie 25")
  })
})
