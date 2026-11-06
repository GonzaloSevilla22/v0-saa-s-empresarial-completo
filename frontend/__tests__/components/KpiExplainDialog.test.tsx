/**
 * tablero-explicable (D4, task 2.3): diálogo «de dónde sale» de las tarjetas
 * KPI del Tablero. Cruz con nombre accesible, Esc, foco devuelto al disparador,
 * y las cinco secciones del catálogo más el enlace al detalle.
 */
import React, { useRef, useState } from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

vi.mock("next/link", () => ({
  default: ({ href, children, ...rest }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...rest}>
      {children}
    </a>
  ),
}))

import { KpiExplainDialog } from "@/components/dashboard/KpiExplainDialog"
import type { DashboardKpiId } from "@/lib/dashboard-kpi-explanations"

function Harness({ kpi, branchName = null }: { kpi: DashboardKpiId; branchName?: string | null }) {
  const [open, setOpen] = useState(false)
  const triggerRef = useRef<HTMLButtonElement>(null)
  return (
    <>
      <button type="button" ref={triggerRef} onClick={() => setOpen(true)}>
        abrir
      </button>
      <KpiExplainDialog
        kpi={kpi}
        context={{ periodDate: new Date("2026-10-01T03:00:00.000Z"), branchName }}
        open={open}
        onOpenChange={setOpen}
        returnFocusRef={triggerRef}
      />
    </>
  )
}

describe("KpiExplainDialog", () => {
  it("abre con el título como nombre y el «qué es» como descripción", async () => {
    const user = userEvent.setup()
    render(<Harness kpi="month_net_profit" />)
    await user.click(screen.getByRole("button", { name: "abrir" }))

    const dialog = await screen.findByRole("dialog", { name: "Ganancia neta del mes" })
    expect(dialog).toHaveAccessibleDescription(/Lo que te quedó en el mes/)
  })

  it("muestra las cinco secciones y el enlace al detalle", async () => {
    const user = userEvent.setup()
    render(<Harness kpi="month_net_profit" branchName="Centro" />)
    await user.click(screen.getByRole("button", { name: "abrir" }))

    const dialog = await screen.findByRole("dialog")
    for (const h of ["Cómo se calcula", "Período y filtros", "De dónde salen los datos", "No incluye"]) {
      expect(within(dialog).getByRole("heading", { name: h })).toBeInTheDocument()
    }
    expect(within(dialog).getByText(/Ventas del mes − Gastos del mes − Compras del mes/)).toBeInTheDocument()
    expect(within(dialog).getByText("Mes: octubre de 2026 (hora de Argentina)")).toBeInTheDocument()
    expect(within(dialog).getByText("Sucursal: Centro")).toBeInTheDocument()
    const link = within(dialog).getByRole("link", { name: /Ver el detalle en Reporte comparativo/ })
    expect(link).toHaveAttribute("href", "/reportes/comparativo")
  })

  it("la cruz tiene nombre accesible «Cerrar» y cierra el diálogo", async () => {
    const user = userEvent.setup()
    render(<Harness kpi="avg_ticket" />)
    await user.click(screen.getByRole("button", { name: "abrir" }))
    await screen.findByRole("dialog")

    await user.click(screen.getByRole("button", { name: "Cerrar" }))

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("Esc cierra y el foco vuelve al disparador", async () => {
    const user = userEvent.setup()
    render(<Harness kpi="critical_stock" />)
    const trigger = screen.getByRole("button", { name: "abrir" })
    await user.click(trigger)
    await screen.findByRole("dialog")

    await user.keyboard("{Escape}")

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })

  it("Productos en alerta dice que es una foto de ahora", async () => {
    const user = userEvent.setup()
    render(<Harness kpi="critical_stock" branchName="Centro" />)
    await user.click(screen.getByRole("button", { name: "abrir" }))

    const dialog = await screen.findByRole("dialog", { name: "Productos en alerta" })
    expect(within(dialog).getByText(/Es una foto de ahora/)).toBeInTheDocument()
    expect(within(dialog).queryByText(/^Mes:/)).not.toBeInTheDocument()
  })

  it("muestra las aclaraciones extra (notes) y la nota de sucursal cuando existen", async () => {
    const user = userEvent.setup()
    render(<Harness kpi="stagnant_stock" branchName="Centro" />)
    await user.click(screen.getByRole("button", { name: "abrir" }))

    const dialog = await screen.findByRole("dialog")
    expect(within(dialog).getByText(/Las existencias son las de hoy/)).toBeInTheDocument()
    expect(within(dialog).getByText(/una venta sin sucursal cuenta como que el producto rotó/)).toBeInTheDocument()
  })
})
