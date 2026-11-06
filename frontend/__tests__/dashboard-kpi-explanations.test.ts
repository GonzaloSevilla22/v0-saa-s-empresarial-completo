/**
 * tablero-explicable (D4/D5, tasks 2.1/2.2): el catálogo único de textos de
 * «de dónde sale» de las tarjetas KPI del Tablero y el armado de su contexto
 * (período, comparación, sucursal). Gate de fidelidad: los textos no pueden
 * contradecir la definición vigente de la RPC que calcula cada tarjeta.
 */
import { describe, it, expect } from "vitest"
import { existsSync } from "node:fs"
import path from "node:path"
import {
  KPI_EXPLANATIONS,
  describeKpiContext,
  type DashboardKpiId,
} from "@/lib/dashboard-kpi-explanations"

const IDS: DashboardKpiId[] = [
  "net_profit",
  "channel_margin",
  "stagnant_stock",
  "cost_per_sale",
  "avg_ticket",
  "month_sales",
  "month_expenses",
  "month_net_profit",
  "critical_stock",
]

const RPCS = [
  "rpc_dashboard_kpi_summary",
  "rpc_dashboard_channel_margin",
  "get_dashboard_financials",
  "get_dashboard_critical_stock",
]

const APP_DIR = path.resolve(__dirname, "..", "app", "(dashboard)")

describe("KPI_EXPLANATIONS — catálogo", () => {
  it("tiene exactamente las 9 tarjetas pedidas (Por cobrar queda fuera)", () => {
    expect(Object.keys(KPI_EXPLANATIONS).sort()).toEqual([...IDS].sort())
    expect(Object.keys(KPI_EXPLANATIONS)).not.toContain("receivables")
  })

  it.each(IDS)("%s: todos los campos de texto están completos", (id) => {
    const e = KPI_EXPLANATIONS[id]
    expect(e.title.trim()).not.toBe("")
    expect(e.what.trim()).not.toBe("")
    expect(e.formula.trim()).not.toBe("")
    expect(e.sources.trim()).not.toBe("")
    expect(e.excludes.length).toBeGreaterThan(0)
    e.excludes.forEach((x) => expect(x.trim()).not.toBe(""))
    expect(e.link.label.trim()).not.toBe("")
  })

  it.each(IDS)("%s: technicalSource es una de las 4 RPC del diseño", (id) => {
    expect(RPCS).toContain(KPI_EXPLANATIONS[id].technicalSource)
  })

  it.each(IDS)("%s: el enlace de detalle resuelve a una pantalla real", (id) => {
    const href = KPI_EXPLANATIONS[id].link.href
    expect(href.startsWith("/")).toBe(true)
    const route = href.split("?")[0].replace(/^\//, "")
    expect(existsSync(path.join(APP_DIR, route, "page.tsx"))).toBe(true)
  })

  it("el texto de ninguna tarjeta nombra la RPC (OQ-4: lenguaje llano)", () => {
    for (const id of IDS) {
      const e = KPI_EXPLANATIONS[id]
      const all = [e.title, e.what, e.formula, e.sources, ...e.excludes, ...(e.notes ?? [])].join(" ")
      RPCS.forEach((r) => expect(all).not.toContain(r))
    }
  })
})

describe("KPI_EXPLANATIONS — fidelidad con la definición vigente de cada RPC", () => {
  it("Ticket Promedio y Margen por Canal dicen que NO restan notas de crédito", () => {
    for (const id of ["avg_ticket", "channel_margin"] as const) {
      const joined = KPI_EXPLANATIONS[id].excludes.join(" ").toLowerCase()
      expect(joined).toContain("notas de crédito")
    }
  })

  it("Gastos del mes aclara que no incluye compras", () => {
    expect(KPI_EXPLANATIONS.month_expenses.excludes.join(" ").toLowerCase()).toContain("compras")
  })

  it("Ganancia neta (ambas) resta las compras en su cuenta", () => {
    expect(KPI_EXPLANATIONS.month_net_profit.formula).toContain("Compras del mes")
    expect(KPI_EXPLANATIONS.net_profit.formula).toContain("Compras del mes")
  })

  it("Ganancia neta del mes explica por qué no da Ventas − Gastos", () => {
    expect(KPI_EXPLANATIONS.month_net_profit.formula.toLowerCase()).toContain("compras")
    expect(KPI_EXPLANATIONS.month_net_profit.formula).toMatch(/no da igual/i)
  })

  it("Productos en alerta es una foto de ahora y no depende del mes", () => {
    expect(KPI_EXPLANATIONS.critical_stock.period).toBe("now")
    for (const id of IDS.filter((i) => i !== "critical_stock")) {
      expect(KPI_EXPLANATIONS[id].period).not.toBe("now")
    }
  })

  it("las 5 tarjetas del bloque superior comparan contra el mes anterior; las 3 del mes, no", () => {
    for (const id of ["net_profit", "channel_margin", "stagnant_stock", "cost_per_sale", "avg_ticket"] as const) {
      expect(KPI_EXPLANATIONS[id].period).toBe("month-vs-prev")
    }
    for (const id of ["month_sales", "month_expenses", "month_net_profit"] as const) {
      expect(KPI_EXPLANATIONS[id].period).toBe("month")
    }
  })

  it("Stock sin Rotación advierte que un producto sin costo suma $0 y el costo por venta usa el del momento", () => {
    expect(KPI_EXPLANATIONS.stagnant_stock.formula.toLowerCase()).toContain("costo actual")
    expect(KPI_EXPLANATIONS.cost_per_sale.sources.toLowerCase()).toContain("momento de la venta")
  })

  it("Ganancia Neta (bloque superior) documenta el «Cobrado» y que no se calcula con sucursal", () => {
    const notes = (KPI_EXPLANATIONS.net_profit.notes ?? []).join(" ")
    expect(notes).toContain("Cobrado")
    expect(notes.toLowerCase()).toContain("sucursal")
  })
})

describe("describeKpiContext", () => {
  const NOV = new Date("2026-11-15T15:00:00.000Z")

  it("mes + comparado con + sucursal para una tarjeta mensual con badge", () => {
    expect(describeKpiContext({ periodDate: NOV, branchName: "Centro", kpi: "avg_ticket" })).toEqual([
      "Mes: noviembre de 2026 (hora de Argentina)",
      "Comparado con: octubre de 2026",
      "Sucursal: Centro",
    ])
  })

  it("sin sucursal elegida dice «Todas»", () => {
    const lines = describeKpiContext({ periodDate: NOV, branchName: null, kpi: "net_profit" })
    expect(lines).toContain("Sucursal: Todas")
  })

  it("una tarjeta mensual sin badge no compara", () => {
    const lines = describeKpiContext({ periodDate: NOV, branchName: null, kpi: "month_sales" })
    expect(lines).toEqual(["Mes: noviembre de 2026 (hora de Argentina)", "Sucursal: Todas"])
  })

  it("enero compara contra diciembre del año anterior", () => {
    const ENE = new Date("2027-01-10T15:00:00.000Z")
    const lines = describeKpiContext({ periodDate: ENE, branchName: null, kpi: "channel_margin" })
    expect(lines).toContain("Mes: enero de 2027 (hora de Argentina)")
    expect(lines).toContain("Comparado con: diciembre de 2026")
  })

  it("Productos en alerta no menciona mes ni comparación: es una foto de ahora", () => {
    const lines = describeKpiContext({ periodDate: NOV, branchName: "Centro", kpi: "critical_stock" })
    expect(lines).toEqual(["Es una foto de ahora: no depende del mes elegido", "Sucursal: Centro"])
  })

  it("usa el mes del selector (octubre) y no el actual", () => {
    const OCT = new Date("2026-10-01T03:00:00.000Z") // 00:00 ART del 1/oct
    const lines = describeKpiContext({ periodDate: OCT, branchName: null, kpi: "avg_ticket" })
    expect(lines[0]).toBe("Mes: octubre de 2026 (hora de Argentina)")
    expect(lines[1]).toBe("Comparado con: septiembre de 2026")
  })
})
