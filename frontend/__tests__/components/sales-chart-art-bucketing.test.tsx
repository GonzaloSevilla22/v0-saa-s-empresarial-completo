import { describe, it, expect, vi, afterEach } from "vitest"
import { render } from "@testing-library/react"
import { SalesChart } from "@/components/dashboard/sales-chart"

// app-timezone-argentina, task 3.3: el bucketing por día del gráfico de
// "ventas últimos 7 días" debe anclarse al día argentino, no al día UTC del
// server (a las 22:00 ART el día UTC ya rolleó a mañana y el bucket de "hoy"
// quedaba vacío/corrido).
//
// recharts no renderiza SVG útil en jsdom (ResponsiveContainer mide 0x0) —
// se mockea `AreaChart` para capturar el `data` que el componente calcula,
// que es lo único bajo prueba acá.

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
  useSales: () => ({
    sales: [{ date: "2026-06-08", total: 5000 }],
  }),
}))

describe("SalesChart — bucketing por día argentino (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
    capturedData = []
  })

  it("REGRESSION: a las 22:00 ART, el último bucket (hoy) es el día D, no D+1, y contiene la venta de hoy", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun
    render(<SalesChart />)

    expect(capturedData).toHaveLength(7)
    const lastBucket = capturedData[capturedData.length - 1]
    // El bucket de "hoy" (ART) es el último de los 7 — la venta de hoy debe
    // caer ahí, no en el día UTC D+1 (que quedaría vacío/fuera de rango).
    expect(lastBucket.ventas).toBe(5000)
    expect(capturedData.reduce((sum, b) => sum + b.ventas, 0)).toBe(5000)
  })
})
