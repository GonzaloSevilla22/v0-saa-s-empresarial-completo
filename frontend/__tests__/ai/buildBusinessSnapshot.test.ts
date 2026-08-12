/**
 * TDD tests for `buildBusinessSnapshot` (kpi-ia-canonical-revenue, grupo 4).
 *
 * Línea base = 0 (este archivo no existía antes de este change — el Copiloto
 * es el consumidor de IA con el bug más caro y no tenía ni un test). Doble de
 * `SupabaseClient` encadenable (`.from().select().gte()...` + `.rpc()`).
 */

import { describe, it, expect, vi } from "vitest"
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
  products: { name?: string; cost?: number; price?: number } | null
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
}): SupabaseClient {
  const rpcMock = vi.fn().mockResolvedValue(cfg.rpc ?? { data: [fullRpcRow({})], error: null })

  const fromMock = vi.fn((table: string) => ({
    select: (columns: string) => {
      if (table === "sales") {
        if (columns.includes("products(")) {
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
  }))

  return { rpc: rpcMock, from: fromMock } as unknown as SupabaseClient
}

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
          products: { name: "Producto A", cost: 500, price: 1000 },
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
      sales: [{ amount: 10000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, products: null, total: 10000 }],
      expenses: [{ amount: 2000, category: "Varios" }],
      // Canon: (10000 ventas - 1000 NC) - (2000 gastos + 3000 compras) = 4000; revenue neto = 9000
      rpc: { data: [fullRpcRow({ invoiced_revenue: 9000, net_profit: 4000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.gastos.margen_neto_pct).toBe(44)
  })

  it("expone ganancia_neta en pesos (hoy no existe en el snapshot)", async () => {
    const supabase = makeSupabaseDouble({
      sales: [{ amount: 10000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, products: null, total: 10000 }],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 9000, net_profit: 4000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.gastos.ganancia_neta).toBe(4000)
  })

  it("el ranking de productos usa el total de línea: B (4u x $2.000 = $8.000) supera a A (1u x $5.000)", async () => {
    const supabase = makeSupabaseDouble({
      sales: [
        { amount: 5000, quantity: 1, date: "2026-08-01", product_id: "A", client_id: null, products: { name: "A", cost: 2000, price: 5000 }, total: 5000 },
        { amount: 2000, quantity: 4, date: "2026-08-02", product_id: "B", client_id: null, products: { name: "B", cost: 1000, price: 2000 }, total: 8000 },
      ],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 13000, net_profit: 5000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.top_rentables[0].nombre).toBe("B")
    expect(snapshot.productos.top_rentables[0].revenue).toBe(8000)
  })
})

// ─── 4.6: camino degradado ──────────────────────────────────────────────────────

describe("buildBusinessSnapshot — camino degradado (D4)", () => {
  it("RPC en error → ingresos por sumLineRevenue local, margen/ganancia null, sin comparación falsa, sin throw", async () => {
    const supabase = makeSupabaseDouble({
      sales: [
        { amount: 1000, quantity: 3, date: "2026-08-01", product_id: "p1", client_id: null, products: null, total: 3000 },
        { amount: 500, quantity: 1, date: "2026-08-02", product_id: "p2", client_id: null, products: null, total: null },
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
      sales: [{ amount: 1000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, products: null, total: 1000 }],
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
      sales: [{ amount: 8000, quantity: 1, date: "2026-08-01", product_id: null, client_id: "c1", products: null, total: 8000 }],
      // El RPC ya restó una NC grande: el neto queda por debajo del bruto del único cliente.
      rpc: { data: [fullRpcRow({ invoiced_revenue: 5000, net_profit: 1000 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.clientes.top_cliente_revenue).toMatch(/100% del total/)
  })
})

// ─── 4.8: regresión — lo que NO cambia ──────────────────────────────────────────

describe("buildBusinessSnapshot — regresión de productos no tocados por el refactor", () => {
  it("stock_critico, sin_rotacion y margen_bajo conservan su comportamiento actual", async () => {
    const supabase = makeSupabaseDouble({
      products: [
        { id: "p1", name: "Bajo stock", price: 100, cost: 90, stock: 2, min_stock: 5 },
        { id: "p2", name: "Sin rotacion", price: 200, cost: 50, stock: 10, min_stock: 2 },
      ],
      sales: [],
      rotation: [],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 0, net_profit: 0 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.productos.stock_critico.map((p) => p.nombre)).toContain("Bajo stock")
    expect(snapshot.productos.margen_bajo.map((p) => p.nombre)).toContain("Bajo stock")
    expect(snapshot.productos.sin_rotacion.map((p) => p.nombre)).toContain("Sin rotacion")
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
      sales: [{ amount: 1000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, products: null, total: 1000 }],
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
      sales: [{ amount: 1000, quantity: 1, date: "2026-08-01", product_id: null, client_id: null, products: null, total: 1000 }],
      rpc: { data: [fullRpcRow({ invoiced_revenue: 1000, net_profit: -500 })], error: null },
    })

    const snapshot = await buildBusinessSnapshot(supabase)
    expect(snapshot.gastos.margen_neto_pct).toBe(-50)
    expect(snapshot.gastos.ganancia_neta).toBe(-500)
  })
})
