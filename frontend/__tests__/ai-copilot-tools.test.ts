/**
 * ia-copilot-v2 (tanda A, grupo 3.3) — catálogo de herramientas de sólo lectura del Copiloto:
 * supabase/functions/_shared/ai-copilot-tools.ts (núcleo puro, sin Deno.*).
 *
 * Se prueba con dobles inyectados (patrón de ai-estadisticas.test.ts): la cuenta la fija el
 * servidor (el modelo NUNCA elige `p_account_id`), cada herramienta se traduce a UNA RPC canónica
 * con sus argumentos validados, los resultados se recortan a su tope y nada se re-agrega.
 *
 * Run: pnpm vitest run __tests__/ai-copilot-tools.test.ts
 */

import { describe, it, expect, vi } from "vitest"
import {
  COPILOT_TOOLS,
  COPILOT_TOOL_NAMES,
  executeCopilotTool,
  formatRangeEs,
  validateToolArgs,
  type ToolDeps,
  type ToolRpcResult,
} from "../../supabase/functions/_shared/ai-copilot-tools"

const ACCOUNT = "11111111-1111-4111-8111-111111111111"
const OTHER_ACCOUNT = "22222222-2222-4222-8222-222222222222"
const BRANCH = "33333333-3333-4333-8333-333333333333"
const PRODUCT = "44444444-4444-4444-8444-444444444444"
const NOW = new Date("2026-11-06T18:42:00.000Z") // 15:42 del viernes 6 de noviembre en Mendoza

function makeDeps(responses: Record<string, ToolRpcResult> = {}) {
  const rpc = vi.fn(async (fn: string, _args: Record<string, unknown>): Promise<ToolRpcResult> => {
    return responses[fn] ?? { data: [], error: null }
  })
  const searchProducts = vi.fn(async (_acc: string, _text: string, _limit: number): Promise<ToolRpcResult> => {
    return responses["products"] ?? { data: [], error: null }
  })
  const deps: ToolDeps = { accountId: ACCOUNT, now: NOW, rpc, searchProducts }
  return { deps, rpc, searchProducts }
}

describe("catálogo — schema estricto por herramienta", () => {
  it("las 12 herramientas del diseño D3, con additionalProperties:false, strict y todos los campos requeridos", () => {
    expect([...COPILOT_TOOL_NAMES].sort()).toEqual([
      "buscar_producto", "comparar_periodos", "cuentas_por_cobrar", "cuentas_por_pagar", "desglose_ventas",
      "detalle_producto", "evolucion_ventas", "mejores_clientes", "ranking_productos", "rentabilidad_productos",
      "resumen_periodo", "stock_critico",
    ])
    expect(COPILOT_TOOLS).toHaveLength(12)
    for (const tool of COPILOT_TOOLS) {
      expect(tool.type).toBe("function")
      expect(tool.function.strict).toBe(true)
      const params = tool.function.parameters
      expect(params.additionalProperties).toBe(false)
      expect(Object.keys(params.properties).sort()).toEqual([...params.required].sort())
      // el modelo no puede elegir la cuenta: ninguna herramienta declara account_id
      expect(Object.keys(params.properties)).not.toContain("account_id")
      expect(Object.keys(params.properties)).not.toContain("p_account_id")
    }
  })
})

describe("validateToolArgs — fechas, enumerados y límites", () => {
  it("acepta un rango válido y normaliza sucursal null", () => {
    const r = validateToolArgs("resumen_periodo", { desde: "2026-11-01", hasta: "2026-11-06", sucursal_id: null })
    expect(r).toEqual({ ok: true, value: { desde: "2026-11-01", hasta: "2026-11-06", sucursal_id: null } })
  })

  it("rechaza fecha mal formada, inexistente, rango invertido y de más de 366 días", () => {
    const bad = (a: Record<string, unknown>) => validateToolArgs("resumen_periodo", { sucursal_id: null, ...a })
    expect(bad({ desde: "01/11/2026", hasta: "2026-11-06" }).ok).toBe(false)
    expect(bad({ desde: "2026-02-30", hasta: "2026-03-01" }).ok).toBe(false)
    expect(bad({ desde: "2026-11-06", hasta: "2026-11-01" }).ok).toBe(false)
    expect(bad({ desde: "2025-11-05", hasta: "2026-11-06" }).ok).toBe(false) // 367 días con ambos extremos
    expect(bad({ desde: "2025-11-06", hasta: "2026-11-06" }).ok).toBe(true) // 366 días con ambos extremos
  })

  it("valida enumerados, límites y uuid de sucursal", () => {
    const base = { desde: "2026-11-01", hasta: "2026-11-06", sucursal_id: null }
    expect(validateToolArgs("ranking_productos", { ...base, orden: "units", limite: 500 }).ok).toBe(false)
    expect(validateToolArgs("ranking_productos", { ...base, orden: "units", limite: 0 }).ok).toBe(false)
    expect(validateToolArgs("ranking_productos", { ...base, orden: "profit", limite: 5 }).ok).toBe(false)
    expect(validateToolArgs("ranking_productos", { ...base, orden: "margin", limite: 5 }).ok).toBe(true)
    expect(validateToolArgs("ranking_productos", { ...base, orden: "units", limite: 5, sucursal_id: "no-uuid" }).ok).toBe(false)
    expect(validateToolArgs("desglose_ventas", { ...base, dimension: "color" }).ok).toBe(false)
    expect(validateToolArgs("desglose_ventas", { ...base, dimension: "hour" }).ok).toBe(true)
    expect(validateToolArgs("evolucion_ventas", { ...base, agrupar: "year" }).ok).toBe(false)
    expect(validateToolArgs("rentabilidad_productos", { dias: 3, limite: 5, orden: "mejor" }).ok).toBe(false)
    expect(validateToolArgs("rentabilidad_productos", { dias: 90, limite: 5, orden: "peor" }).ok).toBe(true)
    expect(validateToolArgs("stock_critico", { sucursal_id: null, limite: 51 }).ok).toBe(false)
    expect(validateToolArgs("buscar_producto", { texto: "a" }).ok).toBe(false)
    expect(validateToolArgs("buscar_producto", { texto: "x".repeat(81) }).ok).toBe(false)
    expect(validateToolArgs("buscar_producto", { texto: "remera" }).ok).toBe(true)
  })

  it("limite nulo toma el valor por defecto", () => {
    const r = validateToolArgs("mejores_clientes", { desde: "2026-11-01", hasta: "2026-11-06", limite: null, sucursal_id: null })
    expect(r.ok && r.value.limite).toBe(5)
  })
})

describe("executeCopilotTool — traducción exacta a la RPC canónica", () => {
  it("resumen_periodo llama a rpc_dashboard_kpi_summary con la ventana previa de previousWindow y devuelve 1 fila", async () => {
    const row = { net_profit: "5000", prev_net_profit: "3000", invoiced_revenue: "120000", prev_invoiced_revenue: "100000", sales_count: 12, stagnant_stock_count: 3 }
    const { deps, rpc } = makeDeps({ rpc_dashboard_kpi_summary: { data: [row], error: null } })
    const out = await executeCopilotTool(deps, "resumen_periodo", { desde: "2026-11-06", hasta: "2026-11-06", sucursal_id: null })
    expect(rpc).toHaveBeenCalledTimes(1)
    const [fn, args] = rpc.mock.calls[0]
    expect(fn).toBe("rpc_dashboard_kpi_summary")
    expect(args).toEqual({
      p_from: "2026-11-06T00:00:00.000Z", p_to: "2026-11-06T23:59:59.999Z",
      p_prev_from: "2026-11-05T00:00:00.000Z", p_prev_to: "2026-11-05T23:59:59.999Z",
      p_branch_id: null,
    })
    expect(out.ok).toBe(true)
    expect(out.rows).toBe(1)
    expect(out.result).toMatchObject({ invoiced_revenue: 120000, prev_invoiced_revenue: 100000, net_profit: 5000, sales_count: 12 })
    expect(out.consulted).toEqual({ tool: "resumen_periodo", label: "ventas del 6 de noviembre" })
    expect(out.focus.period).toEqual({ start: "2026-11-06", end: "2026-11-06" })
  })

  it("un argumento account_id del modelo se ignora: p_account_id sale siempre de la cuenta activa", async () => {
    const { deps, rpc } = makeDeps()
    await executeCopilotTool(deps, "ranking_productos", {
      desde: "2026-11-01", hasta: "2026-11-06", orden: "revenue", limite: 5, sucursal_id: BRANCH,
      account_id: OTHER_ACCOUNT, p_account_id: OTHER_ACCOUNT,
    })
    const [fn, args] = rpc.mock.calls[0]
    expect(fn).toBe("rpc_product_ranking")
    expect(args).toEqual({
      p_account_id: ACCOUNT, p_start: "2026-11-01", p_end: "2026-11-06", p_order_by: "revenue", p_group_variants: true,
      p_branch_id: BRANCH, p_canal: null, p_limit: 5, p_offset: 0,
    })
  })

  it("cada herramienta se traduce a SU RPC con p_account_id inyectado", async () => {
    const range = { desde: "2026-11-01", hasta: "2026-11-06" }
    const cases: Array<[string, Record<string, unknown>, string]> = [
      ["evolucion_ventas", { ...range, agrupar: "week", sucursal_id: null }, "rpc_sales_evolution"],
      ["desglose_ventas", { ...range, dimension: "canal", sucursal_id: null }, "rpc_sales_breakdown"],
      ["mejores_clientes", { ...range, limite: 3, sucursal_id: null }, "rpc_sales_top_clients"],
      ["detalle_producto", { ...range, producto_id: PRODUCT, agrupar: "day" }, "rpc_product_sales_evolution"],
      ["cuentas_por_cobrar", { limite: 5 }, "rpc_receivables_report"],
      ["cuentas_por_pagar", { limite: 5 }, "rpc_payables_report"],
    ]
    for (const [tool, args, fn] of cases) {
      const { deps, rpc } = makeDeps()
      await executeCopilotTool(deps, tool, args)
      expect(rpc.mock.calls[0][0]).toBe(fn)
      expect(rpc.mock.calls[0][1].p_account_id).toBe(ACCOUNT)
    }
    const { deps, rpc } = makeDeps()
    await executeCopilotTool(deps, "stock_critico", { sucursal_id: BRANCH, limite: 10 })
    expect(rpc.mock.calls[0]).toEqual(["get_dashboard_critical_stock_items", { p_branch_id: BRANCH, p_limit: 10 }])
    const c = makeDeps()
    await executeCopilotTool(c.deps, "comparar_periodos", { a_desde: "2026-11-01", a_hasta: "2026-11-06", b_desde: "2026-10-01", b_hasta: "2026-10-06" })
    expect(c.rpc.mock.calls[0]).toEqual(["rpc_period_comparison", { p_a_start: "2026-11-01", p_a_end: "2026-11-06", p_b_start: "2026-10-01", p_b_end: "2026-10-06" }])
    const r = makeDeps()
    await executeCopilotTool(r.deps, "rentabilidad_productos", { dias: 30, limite: 5, orden: "mejor" })
    expect(r.rpc.mock.calls[0]).toEqual(["rpc_product_profitability", { p_period_days: 30 }])
  })

  it("argumento fuera de dominio: {error:argumento_invalido} sin ejecutar la RPC", async () => {
    const { deps, rpc } = makeDeps()
    const out = await executeCopilotTool(deps, "ranking_productos", { desde: "2026-11-01", hasta: "2026-11-06", orden: "units", limite: 500, sucursal_id: null })
    expect(rpc).not.toHaveBeenCalled()
    expect(out.ok).toBe(false)
    expect(out.result.error).toBe("argumento_invalido")
    expect(typeof out.result.detalle).toBe("string")
    expect(out.consulted).toBeNull()
  })

  it("herramienta desconocida y argumentos que no son un objeto", async () => {
    const { deps, rpc } = makeDeps()
    const a = await executeCopilotTool(deps, "borrar_ventas", {})
    const b = await executeCopilotTool(deps, "resumen_periodo", "texto")
    expect(rpc).not.toHaveBeenCalled()
    expect(a.result.error).toBe("herramienta_desconocida")
    expect(b.result.error).toBe("argumento_invalido")
  })

  it("una RPC con error devuelve {error:no_disponible} y no filtra el mensaje", async () => {
    const { deps } = makeDeps({ rpc_sales_breakdown: { data: null, error: { message: "relation x does not exist", code: "42P01" } } })
    const out = await executeCopilotTool(deps, "desglose_ventas", { desde: "2026-11-01", hasta: "2026-11-06", dimension: "canal", sucursal_id: null })
    expect(out.ok).toBe(false)
    expect(out.result).toEqual({ error: "no_disponible" })
    expect(JSON.stringify(out.result)).not.toContain("relation")
  })

  it("una RPC que lanza también es no_disponible", async () => {
    const deps: ToolDeps = {
      accountId: ACCOUNT, now: NOW,
      rpc: async () => { throw new Error("timeout") },
      searchProducts: async () => ({ data: [], error: null }),
    }
    const out = await executeCopilotTool(deps, "stock_critico", { sucursal_id: null, limite: 5 })
    expect(out.result).toEqual({ error: "no_disponible" })
  })

  it("detalle_producto: P0404 se vuelve un resultado legible", async () => {
    const { deps } = makeDeps({ rpc_product_sales_evolution: { data: null, error: { message: "product not found", code: "P0404" } } })
    const out = await executeCopilotTool(deps, "detalle_producto", { desde: "2026-11-01", hasta: "2026-11-06", producto_id: PRODUCT, agrupar: "day" })
    expect(out.result).toEqual({ error: "producto_no_encontrado" })
    expect(out.ok).toBe(false)
  })
})

describe("topes de filas y compactación", () => {
  it("evolución: conserva current/previous y recorta los buckets a 31", async () => {
    const buckets = Array.from({ length: 45 }, (_, i) => ({ period: "bucket", bucket_start: `2026-10-${String((i % 28) + 1).padStart(2, "0")}`, bucket_end: "x", revenue: "10", credit_notes: "0", net_revenue: "10", units: "1", operations: 1, window_clamped: false }))
    const rows = [
      { period: "current", bucket_start: "2026-10-01", bucket_end: "2026-11-06", revenue: "450", credit_notes: "0", net_revenue: "450", units: "45", operations: 45, window_clamped: false },
      { period: "previous", bucket_start: "2026-08-01", bucket_end: "2026-09-30", revenue: "400", credit_notes: "0", net_revenue: "400", units: "40", operations: 40, window_clamped: false },
      ...buckets,
    ]
    const { deps } = makeDeps({ rpc_sales_evolution: { data: rows, error: null } })
    const out = await executeCopilotTool(deps, "evolucion_ventas", { desde: "2026-10-01", hasta: "2026-11-06", agrupar: "day", sucursal_id: null })
    const list = out.result.rows as Array<{ period: string }>
    expect(list.filter((r) => r.period === "bucket")).toHaveLength(31)
    expect(list.filter((r) => r.period === "current")).toHaveLength(1)
    expect(list.find((r) => r.period === "current")).toMatchObject({ revenue: 450 })
  })

  it("ranking recorta a 20 filas aunque la RPC devuelva más, y marca window_clamped", async () => {
    const rows = Array.from({ length: 30 }, (_, i) => ({ rank: i + 1, product_id: `p${i}`, product_name: `P${i}`, units: "1", revenue: "10", gross_margin_pct: null, window_clamped: i === 0 }))
    const { deps } = makeDeps({ rpc_product_ranking: { data: rows, error: null } })
    const out = await executeCopilotTool(deps, "ranking_productos", { desde: "2026-11-01", hasta: "2026-11-06", orden: "units", limite: 20, sucursal_id: null })
    expect((out.result.rows as unknown[]).length).toBe(20)
    expect(out.rows).toBe(20)
    expect(out.result.window_clamped).toBe(true)
  })

  it("desglose recorta a 24 filas", async () => {
    const rows = Array.from({ length: 40 }, (_, i) => ({ bucket_key: String(i), bucket_label: `H${i}`, sort_order: i, revenue: "1", units: "1", operations: 1, window_clamped: false }))
    const { deps } = makeDeps({ rpc_sales_breakdown: { data: rows, error: null } })
    const out = await executeCopilotTool(deps, "desglose_ventas", { desde: "2026-11-01", hasta: "2026-11-06", dimension: "hour", sucursal_id: null })
    expect((out.result.rows as unknown[]).length).toBe(24)
  })

  it("cuentas por cobrar: el total se suma sobre TODAS las filas antes de recortar la lista", async () => {
    const rows = Array.from({ length: 30 }, (_, i) => ({ client_id: `c${i}`, client_name: `C${i}`, balance: String(100 + i), overdue_total: "0", days_overdue_max: 0 }))
    const { deps } = makeDeps({ rpc_receivables_report: { data: rows, error: null } })
    const out = await executeCopilotTool(deps, "cuentas_por_cobrar", { limite: 3 })
    const expected = rows.reduce((s, r) => s + Number(r.balance), 0)
    expect(out.result.total_balance).toBe(expected)
    expect(out.result.debtors_count).toBe(30)
    const list = out.result.rows as Array<{ client_name: string; balance: number }>
    expect(list).toHaveLength(3)
    expect(list[0].balance).toBe(129) // ordenadas por saldo descendente
  })

  it("cuentas por pagar: mismo criterio", async () => {
    const rows = [
      { supplier_id: "s1", supplier_name: "A", balance: "50", overdue_total: "10" },
      { supplier_id: "s2", supplier_name: "B", balance: "200", overdue_total: "0" },
    ]
    const { deps } = makeDeps({ rpc_payables_report: { data: rows, error: null } })
    const out = await executeCopilotTool(deps, "cuentas_por_pagar", { limite: 1 })
    expect(out.result.total_balance).toBe(250)
    expect(out.result.total_overdue).toBe(10)
    expect((out.result.rows as Array<{ supplier_name: string }>)[0].supplier_name).toBe("B")
  })

  it("mejores clientes: 20 filas de clientes más la fila sin asignar", async () => {
    const rows = [
      ...Array.from({ length: 25 }, (_, i) => ({ row_kind: "client", rank: i + 1, client_id: `c${i}`, client_name: `C${i}`, revenue: "10", units: "1", operations: 1, total_clients: 25 })),
      { row_kind: "unassigned", rank: null, client_id: null, client_name: null, revenue: "999", units: "9", operations: 9, total_clients: 25 },
    ]
    const { deps } = makeDeps({ rpc_sales_top_clients: { data: rows, error: null } })
    const out = await executeCopilotTool(deps, "mejores_clientes", { desde: "2026-11-01", hasta: "2026-11-06", limite: 20, sucursal_id: null })
    const list = out.result.rows as Array<{ row_kind: string }>
    expect(list.filter((r) => r.row_kind === "client")).toHaveLength(20)
    expect(list.filter((r) => r.row_kind === "unassigned")).toHaveLength(1)
  })

  it("stock crítico recorta a 50 y rentabilidad ordena sin recalcular", async () => {
    const stock = Array.from({ length: 80 }, (_, i) => ({ product_id: `p${i}`, name: `P${i}`, sku: null, branch_id: "b", branch_name: "Central", quantity: "1", min_stock: "5" }))
    const a = makeDeps({ get_dashboard_critical_stock_items: { data: stock, error: null } })
    const out = await executeCopilotTool(a.deps, "stock_critico", { sucursal_id: null, limite: 50 })
    expect((out.result.rows as unknown[]).length).toBe(50)
    expect(out.consulted?.label).toBe("stock crítico de todas las sucursales")

    const prof = [
      { product_id: "a", product_name: "A", gross_margin: "100", gross_margin_pct: "50", total_revenue: "200", units_sold: "2", last_sale_date: "2026-11-01" },
      { product_id: "b", product_name: "B", gross_margin: "10", gross_margin_pct: "5", total_revenue: "200", units_sold: "2", last_sale_date: "2026-10-01" },
      { product_id: "c", product_name: "C", gross_margin: "60", gross_margin_pct: "30", total_revenue: "200", units_sold: "2", last_sale_date: "2026-10-15" },
    ]
    const peor = await executeCopilotTool(makeDeps({ rpc_product_profitability: { data: prof, error: null } }).deps, "rentabilidad_productos", { dias: 90, limite: 2, orden: "peor" })
    expect((peor.result.rows as Array<{ product_name: string }>).map((r) => r.product_name)).toEqual(["B", "C"])
    const mejor = await executeCopilotTool(makeDeps({ rpc_product_profitability: { data: prof, error: null } }).deps, "rentabilidad_productos", { dias: 90, limite: 2, orden: "mejor" })
    expect((mejor.result.rows as Array<{ product_name: string }>).map((r) => r.product_name)).toEqual(["A", "C"])
  })
})

describe("buscar_producto", () => {
  it("lee con la cuenta activa, limpia el patrón y devuelve hasta 10; con un solo candidato lo deja en foco", async () => {
    const { deps, searchProducts } = makeDeps({ products: { data: [{ id: PRODUCT, name: "Remera Roja", sku: "R1" }], error: null } })
    const out = await executeCopilotTool(deps, "buscar_producto", { texto: "rem,era%(x)" })
    expect(searchProducts).toHaveBeenCalledWith(ACCOUNT, "remerax", 10)
    expect(out.rows).toBe(1)
    expect(out.focus.product).toEqual({ id: PRODUCT, name: "Remera Roja" })
  })

  it("con varios candidatos no fija foco y recorta a 10", async () => {
    const rows = Array.from({ length: 15 }, (_, i) => ({ id: `id${i}`, name: `Remera ${i}`, sku: null }))
    const { deps } = makeDeps({ products: { data: rows, error: null } })
    const out = await executeCopilotTool(deps, "buscar_producto", { texto: "remera" })
    expect((out.result.rows as unknown[]).length).toBe(10)
    expect(out.focus.product).toBeUndefined()
  })

  it("texto que queda vacío tras limpiar es argumento inválido", async () => {
    const { deps, searchProducts } = makeDeps()
    const out = await executeCopilotTool(deps, "buscar_producto", { texto: "%%,,()" })
    expect(searchProducts).not.toHaveBeenCalled()
    expect(out.result.error).toBe("argumento_invalido")
  })
})

describe("rótulos «Miré: …» para la persona", () => {
  it("formatRangeEs: mismo día, mismo mes, distinto mes y distinto año", () => {
    expect(formatRangeEs("2026-11-06", "2026-11-06")).toBe("6 de noviembre")
    expect(formatRangeEs("2026-11-01", "2026-11-06")).toBe("1 al 6 de noviembre")
    expect(formatRangeEs("2026-10-28", "2026-11-06")).toBe("28 de octubre al 6 de noviembre")
    expect(formatRangeEs("2025-12-20", "2026-01-05")).toBe("20 de diciembre de 2025 al 5 de enero de 2026")
  })

  it("el rótulo lo arma el servidor desde los argumentos ya validados", async () => {
    const { deps } = makeDeps()
    const out = await executeCopilotTool(deps, "resumen_periodo", { desde: "2026-11-01", hasta: "2026-11-06", sucursal_id: null })
    expect(out.consulted).toEqual({ tool: "resumen_periodo", label: "ventas del 1 al 6 de noviembre" })
    const cc = await executeCopilotTool(makeDeps().deps, "cuentas_por_cobrar", { limite: 5 })
    expect(cc.consulted?.label).toBe("cuentas por cobrar")
  })
})

describe("foco para seguimientos", () => {
  it("detalle_producto fija producto y período; una sola fila de cliente fija cliente", async () => {
    const rows = [{ row_kind: "total", product_id: PRODUCT, product_name: "Gorra", units: "5", revenue: "100", window_clamped: false }]
    const a = await executeCopilotTool(makeDeps({ rpc_product_sales_evolution: { data: rows, error: null } }).deps, "detalle_producto", { desde: "2026-11-01", hasta: "2026-11-06", producto_id: PRODUCT, agrupar: "day" })
    expect(a.focus.product).toEqual({ id: PRODUCT, name: "Gorra" })
    expect(a.focus.period).toEqual({ start: "2026-11-01", end: "2026-11-06" })

    const clients = [{ client_id: "55555555-5555-4555-8555-555555555555", client_name: "Ana", balance: "100", overdue_total: "0" }]
    const b = await executeCopilotTool(makeDeps({ rpc_receivables_report: { data: clients, error: null } }).deps, "cuentas_por_cobrar", { limite: 5 })
    expect(b.focus.client).toEqual({ id: "55555555-5555-4555-8555-555555555555", name: "Ana" })
  })
})
