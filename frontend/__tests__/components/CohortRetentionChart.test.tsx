/**
 * Tests for `CohortRetentionChart` (components/admin/charts/CohortRetentionChart.tsx).
 *
 * Hallazgo (revisión adversarial del PR #521): con `data` vacío el
 * componente hacía early-return dentro del `useEffect` (nunca dibujaba
 * nada) pero igual devolvía un `<svg>` de 1000x350 en blanco — un estado
 * vacío invisible para el usuario. Ahora, sin datos, el componente
 * renderiza un mensaje textual (`role="status"`) en vez del `<svg>`.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import CohortRetentionChart from "@/components/admin/charts/CohortRetentionChart"

describe("CohortRetentionChart", () => {
  it("con data vacío muestra el mensaje por defecto y NO renderiza el <svg> del gráfico", () => {
    render(<CohortRetentionChart data={[]} />)

    expect(screen.getByRole("status")).toHaveTextContent("Sin cohortes para el período")
    // El ícono del estado vacío también es un <svg> (lucide): se apunta al del gráfico.
    expect(screen.queryByTestId("cohort-retention-svg")).toBeNull()
  })

  it("con data vacío y emptyMessage custom muestra ese texto", () => {
    render(
      <CohortRetentionChart
        data={[]}
        emptyMessage="2 cohortes todavía no completaron el horizonte de 30 días"
      />
    )

    expect(
      screen.getByText("2 cohortes todavía no completaron el horizonte de 30 días")
    ).toBeInTheDocument()
  })

  it("con 1 cohorte renderiza el <svg> del gráfico y NO el mensaje vacío", () => {
    render(
      <CohortRetentionChart
        data={[
          {
            cohort_start: "2026-06-01T00:00:00.000Z",
            cohort_size: 10,
            retained_30d: 4,
            retention_rate: 40,
          },
        ]}
      />
    )

    expect(screen.getByTestId("cohort-retention-svg")).toBeInTheDocument()
    expect(screen.queryByRole("status")).toBeNull()
  })
})
