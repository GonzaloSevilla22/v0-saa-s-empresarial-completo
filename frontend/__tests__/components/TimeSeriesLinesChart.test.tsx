/**
 * fix/admin-seguros-timeseries: `TimeSeriesLinesChart` es compartido por 5
 * pantallas admin. `admin/metricas` y `admin/analytics` siempre pasan
 * `period` ISO real + `activations` + `umv_achieved` (viene de
 * `rpc_admin_kpi_overview`, que trunca a mes/día en SQL). `admin/seguros`
 * no tiene un segundo dato análogo a `umv_achieved` — este test fija que
 * `umv_achieved` es opcional (D3 no dibuja la serie verde cuando ningún
 * punto la trae) sin romper el modo de dos series que ya usan las otras
 * pantallas.
 *
 * Casos borde obligatorios (design del fix): n=0 (estado vacío) y n=1 (un
 * extent D3 de un solo punto no debe dar NaN/dominio roto).
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import TimeSeriesLinesChart from "@/components/admin/charts/TimeSeriesLinesChart"

function pathsWithoutNaN(container: HTMLElement): boolean {
  return Array.from(container.querySelectorAll("path")).every((p) => !(p.getAttribute("d") ?? "").includes("NaN"))
}

function circlesWithoutNaN(container: HTMLElement): boolean {
  return Array.from(container.querySelectorAll("circle")).every(
    (c) => c.getAttribute("cx") !== "NaN" && c.getAttribute("cy") !== "NaN"
  )
}

describe("TimeSeriesLinesChart", () => {
  it("n=0: muestra un estado vacío decente, no un canvas roto", () => {
    render(<TimeSeriesLinesChart data={[]} width={600} height={300} />)
    expect(screen.getByText(/sin datos para el gráfico/i)).toBeInTheDocument()
  })

  it("n=1: un único punto no rompe el eje temporal (extent D3 de dominio cero)", () => {
    const { container } = render(
      <TimeSeriesLinesChart data={[{ period: "2026-08-01T00:00:00.000Z", activations: 1 }]} width={600} height={300} />
    )

    expect(container.querySelectorAll("circle").length).toBeGreaterThan(0)
    expect(pathsWithoutNaN(container)).toBe(true)
    expect(circlesWithoutNaN(container)).toBe(true)
  })

  it("REGRESSION: acepta period ISO real (no 'Ene'..'Dic') sin producir Invalid Date en el path", () => {
    const { container } = render(
      <TimeSeriesLinesChart
        data={[
          { period: "2026-01-01T00:00:00.000Z", activations: 2, umv_achieved: 1 },
          { period: "2026-02-01T00:00:00.000Z", activations: 5, umv_achieved: 3 },
        ]}
        width={600}
        height={300}
      />
    )

    expect(pathsWithoutNaN(container)).toBe(true)
    expect(circlesWithoutNaN(container)).toBe(true)
  })

  it("serie secundaria opcional: sin umv_achieved en ningún punto, no dibuja la línea/puntos verdes", () => {
    const { container } = render(
      <TimeSeriesLinesChart
        data={[
          { period: "2026-01-01T00:00:00.000Z", activations: 2 },
          { period: "2026-02-01T00:00:00.000Z", activations: 5 },
        ]}
        width={600}
        height={300}
      />
    )

    expect(container.querySelectorAll('path[stroke="#10b981"]').length).toBe(0)
    expect(container.querySelectorAll('circle[fill="#10b981"]').length).toBe(0)
    expect(container.querySelectorAll('circle[fill="#3b82f6"]').length).toBe(2)
  })

  it("no rompe el modo de dos series existente: con umv_achieved en todos los puntos, dibuja ambas líneas", () => {
    const { container } = render(
      <TimeSeriesLinesChart
        data={[
          { period: "2026-01-01T00:00:00.000Z", activations: 2, umv_achieved: 1 },
          { period: "2026-02-01T00:00:00.000Z", activations: 5, umv_achieved: 3 },
        ]}
        width={600}
        height={300}
      />
    )

    expect(container.querySelectorAll('path[stroke="#3b82f6"]').length).toBe(1)
    expect(container.querySelectorAll('path[stroke="#10b981"]').length).toBe(1)
    expect(container.querySelectorAll('circle[fill="#3b82f6"]').length).toBe(2)
    expect(container.querySelectorAll('circle[fill="#10b981"]').length).toBe(2)
  })
})
