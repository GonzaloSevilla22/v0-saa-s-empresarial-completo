/**
 * TDD tests for `buildBusinessSnapshot` (kpi-ia-canonical-revenue, grupo 4).
 *
 * Línea base = 0 (este archivo no existía antes de este change — el Copiloto
 * es el consumidor de IA con el bug más caro y no tenía ni un test). Doble de
 * `SupabaseClient` encadenable (`.from().select().gte()...` + `.rpc()`).
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import type { SupabaseClient } from "@supabase/supabase-js"
import {
  buildBusinessSnapshot,
  snapshotToText,
  buildAdaptiveContext,
} from "@/lib/ai/buildBusinessSnapshot"

// ─── Fake query builder (chainable + thenable, sin `any`) ─────────────────────

interface FakeResult<T> {
  data: T[] | null
  error: { message: string } | null
}

interface FakeQueryBuilder<T> extends PromiseLike<FakeResult<T>> {
  select(columns: string): FakeQueryBuilder<T>
  gte(column: string, value: string): FakeQueryBuilder<T>
  lt(column: string, value: string): FakeQueryBuilder<T>
  order(column: string, opts?: { ascending: boolean }): FakeQueryBuilder<T>
  limit(n: number): FakeQueryBuilder<T>
}

function makeBuilder<T>(result: FakeResult<T>): FakeQueryBuilder<T> {
  const builder: FakeQueryBuilder<T> = {
    select: () => builder,
    gte: () => builder,
    lt: () => builder,
    order: () => builder,
    limit: () => builder,
    then: (onfulfilled, onrejected) => Promise.resolve(result).then(onfulfilled, onrejected),
  }
  return builder
}

// ─── Fixtures ──────────────────────────────────────────────────────────────────

interface SaleFixture {
  amount: number
  quantity: number
  date: string
  product_id: string | null
  client_id: string | null
  total?: number | null
}

interface ProductFixture {
  id: string
  name: string
  price: number
  cost: number
  stock: number
  min_stock: number
}

interface ExpenseFixture {
  amount: number
  category: string | null
}

interface ClientFixture {
  id: string
}

interface RotationFixture {
  product_id: string | null
  date: string
}

interface RankingRowFixture {
  product_id: string
  product_name: string
  units: number | string
  revenue: number | string
  gross_margin_pct: number | string | null
}

interface RpcSummaryRow {
  net_profit: number | string | null
  prev_net_profit: number | string | null
  invoiced_revenue: number | string | null
  prev_invoiced_revenue: number | string | null
  avg_ticket: number | string | null
  prev_avg_ticket: number | string | null
  cost_per_sale: number | string | null
  prev_cost_per_sale: number | string | null
  stagnant_stock_value: number | string | null
  stagnant_stock_count: number | null
  prev_stagnant_stock_value: number | string | null
  prev_stagnant_stock_count: number | null
  sales_count: number | null
  prev_sales_count: number | null
  collected_revenue: number | string | null
  prev_collected_revenue: number | string | null
}

function fullRpcRow(overrides: Partial<RpcSummaryRow>): RpcSummaryRow {
  return {
    net_profit: null,
    prev_net_profit: null,
    invoiced_revenue: null,
    prev_invoiced_revenue: null,
    avg_ticket: null,
    prev_avg_ticket: null,
    cost_per_sale: null,
    prev_cost_per_sale: null,
    stagnant_stock_value: null,
    stagnant_stock_count: null,
    prev_stagnant_stock_value: null,
    prev_stagnant_stock_count: null,
    sales_count: 0,
    prev_sales_count: 0,
    collected_revenue: null,
    prev_collected_revenue: null,
    ...overrides,
  }
}

function makeSupabaseDouble(cfg: {
  sales?: SaleFixture[]
  products?: ProductFixture[]
  expenses?: ExpenseFixture[]
  newClients?: ClientFixture[]
  rotation?: RotationFixture[]
  rpc?: FakeResult<RpcSummaryRow>
  criticalStock?: {
    data: number | string | null
    error: { message: string } | null
  }
  criticalStockItems?: {
    data: Array<{
      product_id: string
      name: string
      sku: string | null
      branch_id: string
      branch_name: string
      quantity: number | string
      min_stock: number | string
    }> | null
    error: { message: string } | null
  }
  // migrar-top-productos-canon: doble de rpc_product_ranking + resolución
  // de cuenta activa (auth.getUser + account_members). Defaults = camino
  // feliz (usuario autenticado, una membresía, ranking vacío) para no
  // romper los tests que no ejercitan top_rentables.
  ranking?: { data: RankingRowFixture[] | null; error: { message: string } | null }
  authUser?: { id: string } | null
  accountMembers?: Array<{ account_id: string }>
}): SupabaseClient {
  const rpcMock = vi.fn((fn: string) => {
    if (fn === "get_dashboard_critical_stock") {
      return Promise.resolve(cfg.criticalStock ?? { data: 0, error: null })
    }
    if (fn === "get_dashboard_critical_stock_items") {
      return Promise.resolve(cfg.criticalStockItems ?? { data: [], error: null })
    }
    if (fn === "rpc_product_ranking") {
      return Promise.resolve(cfg.ranking ?? { data: [], error: null })
    }
    return Promise.resolve(cfg.rpc ?? { data: [fullRpcRow({})], error: null })
  })

  const fromMock = vi.fn((table: string) => {
    if (table === "account_members") {
      const result = { data: cfg.accountMembers ?? [{ account_id: "acc-1" }], error: null }
      return {
        select: () => ({
          eq: () => ({
            order: () => ({
              order: () => ({
                limit: () => Promise.resolve(result),
              }),
            }),
          }),
        }),
      }
    }
    return {
      select: (columns: string) => {
        if (table === "sales") {
          // fix 7 (revisión adversarial): la consulta de ventas del período ya
          // no pide el join muerto `products(name, cost, price)` (nadie lo
          // leía) — el distingo entre esta consulta y la de rotación pasa a
          // ser `client_id` (sólo la primera lo selecciona).
          if (columns.includes("client_id")) {
            return makeBuilder<SaleFixture>({ data: cfg.sales ?? [], error: null })
          }
          return makeBuilder<RotationFixture>({ data: cfg.rotation ?? [], error: null })
        }
        if (table === "v_products_with_stock") {
          return makeBuilder<ProductFixture>({ data: cfg.products ?? [], error: null })
        }
        if (table === "expenses") {
          return makeBuilder<ExpenseFixture>({ data: cfg.expenses ?? [], error: null })
        }
        if (table === "clients") {
          return makeBuilder<ClientFixture>({ data: cfg.newClients ?? [], error: null })
        }
        return makeBuilder({ data: [], error: null })
      },
    }
  })

  const authUser = cfg.authUser === undefined ? { id: "u1" } : cfg.authUser
  const auth = { getUser: vi.fn().mockResolvedValue({ data: { user: authUser }, error: null }) }

  return { rpc: rpcMock, from: fromMock, auth } as unknown as SupabaseClient
}

// ─── app-timezone-argentina, task 3.2: ventanas ancladas al día argentino ──────

describe("buildBusinessSnapshot — ventana ART (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("REGRESSION: a las 22:00 ART el período no se corre al día UTC D+1", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun

    const supabase = makeSupabaseDouble({
      sales: [],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 0, net_profit: 0 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    // nowStr = argentinaToday() = 8/jun (no 9/jun); d30Str = 30 días ART antes = 9/may.
    expect(snapshot.periodo).toBe("2026-05-09 al 2026-06-08")
  })
})

// ─── Tests: 4.2 (RED contra el código actual) ──────────────────────────────────

describe("buildBusinessSnapshot — ventas (canon primero)", () => {
  it("venta de 3 unidades a $1.000 reporta ventas.total = 3000, no el precio unitario (hoy da 1000)", async () => {
    const supabase = makeSupabaseDouble({
      sales: [
        {
          amount: 1000,
          quantity: 3,
          date: "2026-08-01",
          product_id: "p1",
          client_id: null,
          total: 3000,
        },
      ],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 3000, net_profit: 1000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.ventas.total).toBe(3000)
  })

  it("el margen neto canónico viene del RPC (descuenta compras y NC), no de ventas-gastos local", async () => {
    const supabase = makeSupabaseDouble({
      sales: [{ amount: 10000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, total: 10000 }],
      expenses: [{ amount: 2000, category: "Varios" }],
      // Canon: (10000 ventas - 1000 NC) - (2000 gastos + 3000 compras) = 4000; revenue neto = 9000
      rpc: { data: [fullRpcRow({ invoiced_revenue: 9000, net_profit: 4000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.gastos.margen_neto_pct).toBe(44)
  })

  it("expone ganancia_neta en pesos (hoy no existe en el snapshot)", async () => {
    const supabase = makeSupabaseDouble({
      sales: [{ amount: 10000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, total: 10000 }],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 9000, net_profit: 4000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.gastos.ganancia_neta).toBe(4000)
  })

  it("el ranking de productos viene del read-model canónico rpc_product_ranking (B $8.000 por delante de A $5.000)", async () => {
    const supabase = makeSupabaseDouble({
      rpc: { data: [fullRpcRow({ invoiced_revenue: 13000, net_profit: 5000 })], error: null },
      ranking: {
        data: [
          { product_id: "B", product_name: "B", units: "4", revenue: "8000", gross_margin_pct: "50" },
          { product_id: "A", product_name: "A", units: "1", revenue: "5000", gross_margin_pct: "60" },
        ],
        error: null,
      },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.top_rentables[0].nombre).toBe("B")
    expect(snapshot.productos.top_rentables[0].revenue).toBe(8000)
    expect(snapshot.productos.top_rentables[0].margen_pct).toBe(50)
  })
})

// ─── migrar-top-productos-canon: read-model canónico, cuenta activa, degradado ──

describe("buildBusinessSnapshot — top productos (migrar-top-productos-canon)", () => {
  it("gross_margin_pct null (sin snapshot de costo) -> margen_pct null, nunca 0 inventado", async () => {
    const supabase = makeSupabaseDouble({
      ranking: {
        data: [{ product_id: "C", product_name: "C", units: "1", revenue: "100", gross_margin_pct: null }],
        error: null,
      },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.top_rentables[0].margen_pct).toBeNull()
    expect(snapshotToText(snapshot)).not.toMatch(/null% margen/)
  })

  it("rpc_product_ranking en error -> top_rentables omitido (vacío), sin throw, sin volver a agregar sales localmente", async () => {
    const supabase = makeSupabaseDouble({
      ranking: { data: null, error: { message: "ranking rpc down" } },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.top_rentables).toEqual([])
  })

  it("sin usuario autenticado -> top_rentables omitido, sin throw", async () => {
    const supabase = makeSupabaseDouble({ authUser: null })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.top_rentables).toEqual([])
  })

  it("sin cuenta activa (account_members vacío) -> top_rentables omitido, sin throw", async () => {
    const supabase = makeSupabaseDouble({ accountMembers: [] })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.top_rentables).toEqual([])
  })
})

// ─── 4.6: camino degradado ──────────────────────────────────────────────────────

describe("buildBusinessSnapshot — camino degradado (D4)", () => {
  it("RPC en error → ingresos por sumLineRevenue local, margen/ganancia null, sin comparación falsa, sin throw", async () => {
    const supabase = makeSupabaseDouble({
      sales: [
        { amount: 1000, quantity: 3, date: "2026-08-01", product_id: "p1", client_id: null, total: 3000 },
        { amount: 500, quantity: 1, date: "2026-08-02", product_id: "p2", client_id: null, total: null },
      ],
      rpc: { data: null, error: { message: "rpc down" } },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.ventas.total).toBe(3500)
    expect(snapshot.gastos.margen_neto_pct).toBeNull()
    expect(snapshot.gastos.ganancia_neta).toBeNull()
    expect(snapshot.ventas.vs_periodo_anterior).toBe("sin datos previos")
  })

  it("snapshotToText/buildAdaptiveContext no emiten líneas de margen ni ganancia en el camino degradado", async () => {
    const supabase = makeSupabaseDouble({
      sales: [{ amount: 1000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, total: 1000 }],
      rpc: { data: null, error: { message: "rpc down" } },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    const text = snapshotToText(snapshot)
    const adaptive = buildAdaptiveContext(snapshot, "¿cómo viene el margen este mes?")

    expect(text).not.toMatch(/null/i)
    expect(text).not.toMatch(/Margen neto:/)
    expect(text).not.toMatch(/Ganancia neta:/)
    expect(adaptive).not.toMatch(/null/i)
    expect(adaptive).not.toMatch(/Margen/i)
  })
})

// ─── 4.7: clamp del top cliente (D6) ────────────────────────────────────────────

describe("buildBusinessSnapshot — clamp del top cliente (D6)", () => {
  it("participación del mayor cliente nunca supera 100% cuando el bruto excede el neto (NC grande)", async () => {
    const supabase = makeSupabaseDouble({
      sales: [{ amount: 8000, quantity: 1, date: "2026-08-01", product_id: null, client_id: "c1", total: 8000 }],
      // El RPC ya restó una NC grande: el neto queda por debajo del bruto del único cliente.
      rpc: { data: [fullRpcRow({ invoiced_revenue: 5000, net_profit: 1000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.clientes.top_cliente_revenue).toMatch(/100% del total/)
  })
})

// ─── 4.8: regresión — lo que NO cambia ──────────────────────────────────────────

describe("buildBusinessSnapshot — KPIs de productos", () => {
  it("usa el conteo canónico de stock crítico y conserva sin_rotacion/margen_bajo", async () => {
    const supabase = makeSupabaseDouble({
      products: [
        { id: "p1", name: "Bajo stock", price: 100, cost: 90, stock: 2, min_stock: 5 },
        { id: "p2", name: "Sin rotacion", price: 200, cost: 50, stock: 10, min_stock: 2 },
      ],
      sales: [],
      rotation: [],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 0, net_profit: 0 })], error: null },
      criticalStock: { data: 1, error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.stock_critico_total).toBe(1)
    expect(snapshot.productos.margen_bajo.map((p) => p.nombre)).toContain("Bajo stock")
    expect(snapshot.productos.sin_rotacion.map((p) => p.nombre)).toContain("Sin rotacion")
  })

  it("no infiere criticidad desde el stock agregado del catálogo", async () => {
    const supabase = makeSupabaseDouble({
      products: [
        { id: "p1", name: "Agregado sano", price: 100, cost: 50, stock: 50, min_stock: 5 },
      ],
      criticalStock: { data: "2", error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.stock_critico_total).toBe(2)
    expect(snapshotToText(snapshot)).toContain("STOCK CRÍTICO: 2 productos")
  })
})

// ─── kpi-canonicalization (candidato S5): detalle de stock crítico ─────────────

describe("buildBusinessSnapshot — detalle de stock crítico (kpi-canonicalization S5)", () => {
  it("con ítems -> el texto nombra producto, sucursal y cantidad/mínimo (no sólo el conteo)", async () => {
    const supabase = makeSupabaseDouble({
      criticalStock: { data: 2, error: null },
      criticalStockItems: {
        data: [
          { product_id: "p1", name: "Remera", sku: "REM-01", branch_id: "b1", branch_name: "Showroom", quantity: "1", min_stock: "10" },
          { product_id: "p2", name: "Short", sku: null, branch_id: "b2", branch_name: "Depósito", quantity: 0, min_stock: 5 },
        ],
        error: null,
      },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.stock_critico_items).toEqual([
      { productId: "p1", name: "Remera", sku: "REM-01", branchId: "b1", branchName: "Showroom", quantity: 1, minStock: 10 },
      { productId: "p2", name: "Short", sku: null, branchId: "b2", branchName: "Depósito", quantity: 0, minStock: 5 },
    ])

    const text = snapshotToText(snapshot)
    expect(text).toContain("STOCK CRÍTICO: 2 productos")
    expect(text).toContain("Remera (REM-01) en Showroom: 1 de mínimo 10")
    expect(text).toContain("Short en Depósito: 0 de mínimo 5")

    const adaptive = buildAdaptiveContext(snapshot, "¿cómo viene el stock?")
    expect(adaptive).toContain("Remera en Showroom(1/10)")
  })

  it("sin ítems (RPC de detalle en error) -> el conteo se informa igual, sin líneas de detalle inventadas", async () => {
    const supabase = makeSupabaseDouble({
      criticalStock: { data: 3, error: null },
      criticalStockItems: { data: null, error: { message: "detalle rpc down" } },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.stock_critico_items).toBeNull()

    const text = snapshotToText(snapshot)
    expect(text).toContain("STOCK CRÍTICO: 3 productos")
    expect(text).not.toContain("de mínimo")
  })

  it("el conteo total NUNCA se deriva de items.length (detalle es sólo un top 5, puede haber más críticos)", async () => {
    const supabase = makeSupabaseDouble({
      criticalStock: { data: 9, error: null },
      criticalStockItems: {
        data: [
          { product_id: "p1", name: "Remera", sku: "REM-01", branch_id: "b1", branch_name: "Showroom", quantity: 1, min_stock: 10 },
        ],
        error: null,
      },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.stock_critico_total).toBe(9)
    expect(snapshot.productos.stock_critico_items).toHaveLength(1)
    expect(snapshotToText(snapshot)).toContain("STOCK CRÍTICO: 9 productos")
  })
})

// ─── 4.9: casos borde ────────────────────────────────────────────────────────────

describe("buildBusinessSnapshot — casos borde", () => {
  it("cuenta sin ventas: invoicedRevenue = 0 → margen null, sin división por cero", async () => {
    const supabase = makeSupabaseDouble({
      sales: [],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 0, net_profit: 0 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.ventas.total).toBe(0)
    expect(snapshot.gastos.margen_neto_pct).toBeNull()
    expect(snapshot.gastos.ganancia_neta).toBe(0)
  })

  it("cuenta sin gastos ni compras: RPC devuelve ganancia = ingresos íntegros", async () => {
    const supabase = makeSupabaseDouble({
      sales: [{ amount: 1000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, total: 1000 }],
      expenses: [],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 1000, net_profit: 1000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.gastos.total).toBe(0)
    expect(snapshot.gastos.ganancia_neta).toBe(1000)
    expect(snapshot.gastos.margen_neto_pct).toBe(100)
  })

  it("netProfit negativo → margen negativo se informa (no se omite)", async () => {
    const supabase = makeSupabaseDouble({
      sales: [{ amount: 1000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, total: 1000 }],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 1000, net_profit: -500 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.gastos.margen_neto_pct).toBe(-50)
    expect(snapshot.gastos.ganancia_neta).toBe(-500)
  })
})
