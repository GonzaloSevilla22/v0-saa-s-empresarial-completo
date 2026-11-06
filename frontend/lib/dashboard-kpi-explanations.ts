/**
 * tablero-explicable (D4/D5) — catálogo ÚNICO de los textos «de dónde sale
 * este número» de las tarjetas KPI del Tablero.
 *
 * Los textos están redactados contra los cuerpos VIVOS de las RPC que calculan
 * cada tarjeta, leídos con `pg_get_functiondef` en prod el 2026-11-06. Si una
 * de esas funciones cambia, hay un texto acá que revisar. md5 del cuerpo vivo
 * (sin CR) al momento de escribir el catálogo:
 *
 *   rpc_dashboard_kpi_summary     3947671c25c1706fb255cbfc66454eef
 *   rpc_dashboard_channel_margin  7ddc661b4e1fa3fb7fb31ade4eceb308
 *   get_dashboard_financials      b32ce1c01a224e4eb86cb21c29f42f78
 *   get_dashboard_critical_stock  055c8d84499cfc75a53520e2ada3f6c3
 *
 * El diálogo dice la definición TAL CUAL ES, aunque sea discutible (p. ej. el
 * Ticket Promedio no resta notas de crédito): corregir una definición es otro
 * change. `technicalSource` es sólo para mantenimiento y tests; no se muestra
 * al usuario (OQ-4).
 *
 * «Mes» = el mes del selector de período del Tablero (mes en curso por
 * defecto), calendario de Argentina.
 */

import { monthKey } from "@/lib/date-range"

export type DashboardKpiId =
  | "net_profit"
  | "channel_margin"
  | "stagnant_stock"
  | "cost_per_sale"
  | "avg_ticket"
  | "month_sales"
  | "month_expenses"
  | "month_net_profit"
  | "critical_stock"

/** `month` = sólo el mes elegido; `month-vs-prev` = el mes y el badge lo compara
 *  contra el anterior; `now` = foto de ahora, no depende del mes elegido. */
export type KpiPeriodKind = "month" | "month-vs-prev" | "now"

export interface KpiExplanation {
  title: string
  /** Qué mide, en una frase (DialogDescription). */
  what: string
  /** La cuenta con la que se obtiene el número. */
  formula: string
  period: KpiPeriodKind
  /** De dónde salen los datos, en lenguaje llano. */
  sources: string
  /** Qué NO incluye. */
  excludes: string[]
  /** Aclaraciones extra (opcionales). */
  notes?: string[]
  /** Aclaración propia del filtro de sucursal de esta tarjeta (opcional). */
  branchNote?: string
  /** Pantalla donde se ve el detalle. */
  link: { href: string; label: string }
  /** Nombre de la RPC que calcula el número — mantenimiento y tests. */
  technicalSource:
    | "rpc_dashboard_kpi_summary"
    | "rpc_dashboard_channel_margin"
    | "get_dashboard_financials"
    | "get_dashboard_critical_stock"
}

export const KPI_EXPLANATIONS: Record<DashboardKpiId, KpiExplanation> = {
  net_profit: {
    title: "Ganancia Neta",
    what: "Lo que le quedó al negocio en el mes después de restar lo que gastó y lo que compró.",
    formula: "Ventas del mes − Notas de crédito del mes − Gastos del mes − Compras del mes.",
    period: "month-vs-prev",
    sources: "Tus ventas, notas de crédito, gastos y compras registrados con fecha en el mes.",
    excludes: [
      "Lo cobrado o no cobrado: una venta a cuenta corriente cuenta el día que se vende.",
      "Presupuestos y remitos.",
      "El costo de la mercadería vendida: lo que se resta es lo que compraste en el mes, no el costo de lo que vendiste.",
    ],
    notes: [
      "Si aparece «Cobrado: $X», es lo que entró de verdad: ventas − ventas a cuenta corriente + cobros recibidos. No se calcula con una sucursal elegida, porque los cobros no tienen sucursal.",
    ],
    link: { href: "/reportes/comparativo", label: "Reporte comparativo" },
    technicalSource: "rpc_dashboard_kpi_summary",
  },

  channel_margin: {
    title: "Margen por Canal",
    what: "De cada $100 vendidos por cada canal (local, Instagram, Mercado Libre…), cuánto queda después de pagar la mercadería.",
    formula:
      "Por canal: (ventas − costo de lo vendido) ÷ ventas × 100. El costo de cada producto es el que tenía en el momento de la venta; si esa venta no lo guardó, se usa el costo actual del producto.",
    period: "month-vs-prev",
    sources: "Tus ventas del mes con su canal y las líneas de producto de cada venta.",
    excludes: [
      "Notas de crédito: el margen es sobre lo vendido bruto.",
      "Gastos y compras.",
      "Canales sin ventas en el mes. Las ventas sin canal aparecen como «Sin canal».",
      "Un producto sin costo cargado cuenta costo $0 y agranda el margen.",
    ],
    notes: [
      "«X lidera» es el canal de mayor margen. El color compara el margen total contra el mes anterior.",
    ],
    link: { href: "/estadisticas", label: "Estadísticas: por dónde se vende" },
    technicalSource: "rpc_dashboard_channel_margin",
  },

  stagnant_stock: {
    title: "Stock sin Rotación",
    what: "Cuánta plata tenés quieta en mercadería que no se vendió ni una vez en el mes.",
    formula:
      "Suma de existencias × costo actual de cada producto con stock que no tuvo ninguna venta en el mes. La etiqueta dice cuántos productos son; «N sin costo» son los que no tienen costo cargado y suman $0.",
    period: "month-vs-prev",
    sources: "Existencias por sucursal, costo actual de cada producto y tus ventas del mes.",
    excludes: [
      "Productos sin control de stock.",
      "Productos «padre» de variantes: cuentan sus variantes.",
      "Productos borrados.",
    ],
    notes: [
      "Las existencias son las de hoy; el mes elegido sólo sirve para saber si el producto se vendió. Que suba es malo, por eso el color se invierte.",
    ],
    branchNote:
      "Con una sucursal elegida se miran el stock y las ventas de esa sucursal; una venta sin sucursal cuenta como que el producto rotó.",
    link: { href: "/stock", label: "Stock" },
    technicalSource: "rpc_dashboard_kpi_summary",
  },

  cost_per_sale: {
    title: "Costo por Venta",
    what: "En promedio, cuánto te costó la mercadería de cada venta.",
    formula:
      "Costo de todo lo vendido en el mes ÷ cantidad de ventas del mes. Una venta con varios productos cuenta como una.",
    period: "month-vs-prev",
    sources:
      "Las líneas de producto de tus ventas, con el costo del momento de la venta (o el actual si no se guardó).",
    excludes: [
      "Gastos y compras.",
      "Servicios y productos sin costo cargado: cuentan $0.",
    ],
    notes: ["Que suba es malo, por eso el color se invierte."],
    link: { href: "/rentabilidad", label: "Rentabilidad por producto" },
    technicalSource: "rpc_dashboard_kpi_summary",
  },

  avg_ticket: {
    title: "Ticket Promedio",
    what: "Cuánto gasta en promedio un cliente en cada compra.",
    formula:
      "Total vendido en el mes ÷ cantidad de ventas del mes. Una venta con varios productos cuenta como una.",
    period: "month-vs-prev",
    sources: "Tus ventas del mes.",
    excludes: [
      "Notas de crédito: se calcula sobre lo vendido antes de devoluciones.",
      "Presupuestos y remitos.",
    ],
    link: { href: "/estadisticas", label: "Estadísticas de ventas" },
    technicalSource: "rpc_dashboard_kpi_summary",
  },

  month_sales: {
    title: "Ventas del mes",
    what: "Todo lo que vendiste en el mes, descontadas las devoluciones.",
    formula: "Total de las ventas con fecha en el mes − notas de crédito emitidas en el mes.",
    period: "month",
    sources: "Tus ventas (mostrador, formulario y órdenes) y notas de crédito.",
    excludes: [
      "Presupuestos y remitos sin facturar.",
      "Cobros de cuenta corriente: la venta a crédito cuenta el día que se vende, no cuando se cobra.",
    ],
    link: { href: "/ventas", label: "Ventas" },
    technicalSource: "get_dashboard_financials",
  },

  month_expenses: {
    title: "Gastos del mes",
    what: "Lo que pagaste en gastos del negocio en el mes (alquiler, servicios, sueldos…).",
    formula: "Suma de los gastos cargados con fecha en el mes.",
    period: "month",
    sources: "Tus gastos.",
    excludes: [
      "Compras de mercadería: se cargan en Compras y se restan aparte en la Ganancia neta.",
    ],
    branchNote:
      "Con una sucursal elegida entran sólo los gastos imputados a esa sucursal; los gastos cargados sin sucursal no entran.",
    link: { href: "/gastos", label: "Gastos" },
    technicalSource: "get_dashboard_financials",
  },

  month_net_profit: {
    title: "Ganancia neta del mes",
    what: "Lo que te quedó en el mes. Es el mismo número que «Ganancia Neta» de arriba.",
    formula:
      "Ventas del mes − Gastos del mes − Compras del mes. Por eso no da igual a Ventas − Gastos si compraste mercadería.",
    period: "month",
    sources: "Tus ventas, notas de crédito, gastos y compras.",
    excludes: [
      "Cobranzas pendientes.",
      "El costo de lo vendido: se resta lo comprado en el mes.",
    ],
    link: { href: "/reportes/comparativo", label: "Reporte comparativo" },
    technicalSource: "get_dashboard_financials",
  },

  critical_stock: {
    title: "Productos en alerta",
    what: "Cuántos productos están en su stock mínimo o por debajo.",
    formula:
      "Productos con un mínimo configurado (mayor que 0) cuyas existencias están en ese mínimo o menos, en alguna sucursal (o en la elegida). Un producto en alerta en dos sucursales cuenta una vez.",
    period: "now",
    sources: "Existencias y mínimos por sucursal.",
    excludes: [
      "Productos con mínimo 0: no tienen umbral.",
      "Productos sin control de stock.",
      "Productos «padre» de variantes.",
      "Productos borrados.",
    ],
    link: { href: "/stock", label: "Stock" },
    technicalSource: "get_dashboard_critical_stock",
  },
}

// ── Contexto dinámico (período, comparación, sucursal) ──────────────────────

const MONTH_NAMES_ES = [
  "enero", "febrero", "marzo", "abril", "mayo", "junio",
  "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
]

/** "2026-11" → "noviembre de 2026". Por partes: sin `Date`, sin huso. */
function monthLabel(year: number, monthIndex0: number): string {
  return `${MONTH_NAMES_ES[monthIndex0]} de ${year}`
}

export interface DescribeKpiContextInput {
  /** Cualquier fecha dentro del mes del selector de período del Tablero. */
  periodDate: Date
  /** Nombre de la sucursal activa; `null` = todas. */
  branchName: string | null
  kpi: DashboardKpiId
}

/**
 * Líneas de «Período y filtros» del diálogo, derivadas del contexto vigente
 * del Tablero. El mes se lee con `monthKey` (calendario de Argentina), no con
 * el huso del navegador.
 */
export function describeKpiContext({ periodDate, branchName, kpi }: DescribeKpiContextInput): string[] {
  const period = KPI_EXPLANATIONS[kpi].period
  const lines: string[] = []

  if (period === "now") {
    lines.push("Es una foto de ahora: no depende del mes elegido")
  } else {
    const [y, m] = monthKey(periodDate).split("-").map(Number)
    lines.push(`Mes: ${monthLabel(y, m - 1)} (hora de Argentina)`)
    if (period === "month-vs-prev") {
      const prevYear = m === 1 ? y - 1 : y
      const prevMonth0 = m === 1 ? 11 : m - 2
      lines.push(`Comparado con: ${monthLabel(prevYear, prevMonth0)}`)
    }
  }

  lines.push(`Sucursal: ${branchName ?? "Todas"}`)
  return lines
}
