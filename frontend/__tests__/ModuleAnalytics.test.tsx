import { describe, expect, it, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { ModuleAnalytics } from "@/components/admin/ModuleAnalytics"

vi.mock("@/components/admin/charts/ModuleSeriesChart", () => ({
  default: () => <div data-testid="module-series" />,
}))

describe("ModuleAnalytics — unidades canónicas", () => {
  it("presenta conteos de ventas como operaciones, no como dinero", () => {
    render(
      <ModuleAnalytics
        title="Ventas"
        subtitle="Detalle"
        moduleType="ventas"
        stats={{
          summary: { users_count: 4, count: 12, avg_per_user: 3 },
          time_series: [],
        }}
      />,
    )

    expect(screen.getByText("Operaciones Totales")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.queryByText(/ARS|\$/)).not.toBeInTheDocument()
  })

  it("rotula el conteo de stock como productos", () => {
    render(
      <ModuleAnalytics
        title="Stock"
        subtitle="Detalle"
        moduleType="stock"
        stats={{
          summary: { users_count: 2, count: 8, avg_per_user: 4 },
          time_series: [],
        }}
      />,
    )

    expect(screen.getByText("Productos")).toBeInTheDocument()
    expect(screen.getByText("Productos x Usuario")).toBeInTheDocument()
    expect(screen.queryByText("Operaciones Totales")).not.toBeInTheDocument()
  })
})
