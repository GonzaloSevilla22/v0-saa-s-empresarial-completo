/**
 * TDD tests para la capa canónica de acceso a `get_dashboard_financials`
 * (fix ad-hoc tablero-kpis-mes-vigente, D1).
 *
 * El mapeo de la fila del RPC vivía embebido (y duplicado como interfaz local
 * con nombres snake_case) en `app/(dashboard)/dashboard/page.tsx`. Nace acá,
 * en `lib/reporting/`, para que las tarjetas del Tablero (mes vigente) y el
 * Resumen IA (día) consuman UN solo mapeo vía `useDashboardFinancials`.
 */

import { describe, it, expect, vi } from "vitest"
import type { SupabaseClient } from "@supabase/supabase-js"
import { fetchDashboardFinancials } from "@/lib/reporting/dashboard-financials"

// Fila tal como la devuelve get_dashboard_financials (numerics como string).
const mockRpcRow = {
  total_income: "125000.50",
  total_expenses: "30000",
  total_purchases: "45000.25",
  net_profit: "49999.75",
}

function makeSupabase(result: { data: unknown; error: unknown }) {
  const rpc = vi.fn().mockResolvedValue(result)
  return { supabase: { rpc } as unknown as SupabaseClient, rpc }
}

const RANGE = {
  from: "2026-09-01T00:00:00.000Z",
  to: "2026-09-30T23:59:59.999Z",
}

describe("fetchDashboardFinancials — llamada al RPC", () => {
  it("pasa p_date_from/p_date_to de la ventana y NO manda p_branch_id sin sucursal", async () => {
    const { supabase, rpc } = makeSupabase({ data: [mockRpcRow], error: null })

    await fetchDashboardFinancials(supabase, { ...RANGE, branchId: null })

    expect(rpc).toHaveBeenCalledTimes(1)
    expect(rpc).toHaveBeenCalledWith("get_dashboard_financials", {
      p_date_from: "2026-09-01T00:00:00.000Z",
      p_date_to: "2026-09-30T23:59:59.999Z",
    })
  })

  it("incluye p_branch_id cuando hay sucursal filtrada", async () => {
    const { supabase, rpc } = makeSupabase({ data: [mockRpcRow], error: null })

    await fetchDashboardFinancials(supabase, { ...RANGE, branchId: "branch-9" })

    expect(rpc).toHaveBeenCalledWith("get_dashboard_financials", {
      p_date_from: "2026-09-01T00:00:00.000Z",
      p_date_to: "2026-09-30T23:59:59.999Z",
      p_branch_id: "branch-9",
    })
  })

  it("branchId ausente (undefined) se comporta como sin sucursal", async () => {
    const { supabase, rpc } = makeSupabase({ data: [mockRpcRow], error: null })

    await fetchDashboardFinancials(supabase, RANGE)

    expect(rpc.mock.calls[0][1]).not.toHaveProperty("p_branch_id")
  })
})

describe("fetchDashboardFinancials — mapeo de la fila", () => {
  it("mapea snake_case a camelCase y numerics-como-string a number", async () => {
    const { supabase } = makeSupabase({ data: [mockRpcRow], error: null })

    const result = await fetchDashboardFinancials(supabase, RANGE)

    expect(result).toEqual({
      totalIncome: 125000.5,
      totalExpenses: 30000,
      totalPurchases: 45000.25,
      netProfit: 49999.75,
    })
  })

  it("acepta números nativos y trata null como 0 (Number(x ?? 0))", async () => {
    const { supabase } = makeSupabase({
      data: [
        {
          total_income: 800,
          total_expenses: null,
          total_purchases: null,
          net_profit: 800,
        },
      ],
      error: null,
    })

    const result = await fetchDashboardFinancials(supabase, RANGE)

    expect(result).toEqual({
      totalIncome: 800,
      totalExpenses: 0,
      totalPurchases: 0,
      netProfit: 800,
    })
  })

  it("preserva una ganancia neta negativa (gastos > ventas)", async () => {
    const { supabase } = makeSupabase({
      data: [{ ...mockRpcRow, net_profit: "-1500.5" }],
      error: null,
    })

    const result = await fetchDashboardFinancials(supabase, RANGE)

    expect(result.netProfit).toBe(-1500.5)
  })
})

describe("fetchDashboardFinancials — respuestas vacías y errores", () => {
  it("respuesta vacía (período sin datos) → ceros, nunca null", async () => {
    const { supabase } = makeSupabase({ data: [], error: null })

    await expect(fetchDashboardFinancials(supabase, RANGE)).resolves.toEqual({
      totalIncome: 0,
      totalExpenses: 0,
      totalPurchases: 0,
      netProfit: 0,
    })
  })

  it("data null (sin cuerpo) → ceros", async () => {
    const { supabase } = makeSupabase({ data: null, error: null })

    await expect(fetchDashboardFinancials(supabase, RANGE)).resolves.toEqual({
      totalIncome: 0,
      totalExpenses: 0,
      totalPurchases: 0,
      netProfit: 0,
    })
  })

  it("propaga el error del RPC (la decisión de degradar es del consumidor)", async () => {
    const rpcError = { message: "permission denied for function get_dashboard_financials" }
    const { supabase } = makeSupabase({ data: null, error: rpcError })

    await expect(fetchDashboardFinancials(supabase, RANGE)).rejects.toBe(rpcError)
  })
})
