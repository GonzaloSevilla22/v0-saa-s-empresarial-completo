/**
 * estadisticas-ventas E1 (task 4.1, D13) — componentes de gráfico extraídos
 * a components/charts/ sobre REPORT_SERIES_COLORS. Los consume sólo la
 * superficie nueva; los 3 reportes existentes quedan como candidato.
 *
 * Bajo jsdom Recharts no mide el contenedor, así que se asserta el contrato
 * accesible (role="img" + aria-label) y el estado vacío — no los píxeles.
 */
import React from "react"
import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

import { ReportTimeSeriesChart } from "@/components/charts/ReportTimeSeriesChart"
import { ReportBarChart } from "@/components/charts/ReportBarChart"

describe("ReportTimeSeriesChart", () => {
  it("expone el gráfico como imagen accesible con su rótulo", () => {
    render(
      <ReportTimeSeriesChart
        ariaLabel="Evolución de la facturación neta por día"
        valueName="Neto"
        data={[
          { label: "01/08", value: 100 },
          { label: "02/08", value: 250 },
        ]}
      />,
    )
    expect(screen.getByRole("img", { name: "Evolución de la facturación neta por día" })).toBeInTheDocument()
  })

  it("sin datos muestra un estado vacío en vez de un gráfico en blanco", () => {
    render(<ReportTimeSeriesChart ariaLabel="Evolución" valueName="Neto" data={[]} />)
    expect(screen.getByText("Sin datos para graficar")).toBeInTheDocument()
    expect(screen.queryByRole("img")).not.toBeInTheDocument()
  })
})

describe("ReportBarChart", () => {
  it("expone el gráfico como imagen accesible con su rótulo", () => {
    render(
      <ReportBarChart
        ariaLabel="Top 10 productos por unidades"
        valueName="Unidades"
        data={[
          { name: "Remera", value: 40 },
          { name: "Gorra", value: 12 },
        ]}
      />,
    )
    expect(screen.getByRole("img", { name: "Top 10 productos por unidades" })).toBeInTheDocument()
  })

  it("sin datos muestra un estado vacío", () => {
    render(<ReportBarChart ariaLabel="Top" valueName="Unidades" data={[]} />)
    expect(screen.getByText("Sin datos para graficar")).toBeInTheDocument()
  })
})
