/**
 * Capa canónica de acceso a `rpc_product_ranking` — el read-model de "más
 * vendidos" que ya usan la pantalla `/estadisticas` y su export CSV
 * (`supabase/functions/_shared/export-ranking.ts`).
 *
 * migrar-top-productos-canon: reemplaza las agregaciones locales de "top
 * productos" que `buildBusinessSnapshot.ts` (Copiloto) y
 * `supabase/functions/ai-insights/index.ts` reconstruían cada una por su
 * cuenta sobre `sales`/`v_sales_flat` — la 2ª y 3ª definición de la misma
 * agregación que esta RPC ya canoniza (regla de reutilización antes que
 * repetición). Gemelo Deno: `supabase/functions/_shared/reporting-canon.ts`.
 *
 * `rpc_product_ranking` exige `p_account_id` explícito (a diferencia de
 * `rpc_dashboard_kpi_summary`/`get_dashboard_critical_stock`, que lo derivan
 * de `auth.uid()` internamente) — `resolveActiveAccountId` lo resuelve con
 * el MISMO criterio determinístico que `backend/core/deps.py:get_account_id`
 * y `generate-export/index.ts`: la membresía más antigua (`created_at`),
 * desempatada por `id`.
 */

import type { SupabaseClient } from "@supabase/supabase-js"

// ─── Types ────────────────────────────────────────────────────────────────────

/** Fila de `rpc_product_ranking` mapeada a camelCase — sólo el subconjunto
 *  de columnas que estos consumidores de IA necesitan (nombre, unidades,
 *  importe, margen); la RPC devuelve además paginación/ventana que no hace
 *  falta acá. */
export interface TopProduct {
  productId: string
  name: string
  units: number
  revenue: number
  /** `null` cuando ninguna línea del grupo resolvió costo (cascada RN-D2) —
   *  nunca se informa un margen inventado. */
  marginPct: number | null
}

export interface RpcProductRankingRow {
  product_id: string
  product_name: string
  units: string | number
  revenue: string | number
  gross_margin_pct: string | number | null
}

export interface ProductRankingWindow {
  /** Fecha de negocio (YYYY-MM-DD) — igual criterio que `sales.date`. */
  start: string
  end: string
  branchId?: string | null
  /** Top N por importe. Default 5 (mismo tamaño que la agregación local que reemplaza). */
  limit?: number
}

const num = (v: string | number | null | undefined): number | null =>
  v == null ? null : Number(v)

const toNumber = (v: string | number | null | undefined): number => {
  if (v == null) return 0
  const n = Number(v)
  return Number.isNaN(n) ? 0 : n
}

// ─── Account resolution ────────────────────────────────────────────────────────

interface AccountMembershipRow {
  account_id: string
}

/**
 * Resuelve la cuenta activa del usuario con el mismo criterio determinístico
 * que `backend/core/deps.py:get_account_id` y `generate-export/index.ts`
 * (Regla de Tres: ya son 3 los consumidores de este criterio) — la
 * membresía con `created_at` más antiguo, desempatada por `id`. `null` si el
 * usuario no tiene ninguna cuenta activa; el caller decide si degrada.
 */
export async function resolveActiveAccountId(
  supabase: SupabaseClient,
  userId: string,
): Promise<string | null> {
  const { data, error } = await supabase
    .from("account_members")
    .select("account_id")
    .eq("user_id", userId)
    .order("created_at", { ascending: true })
    .order("id", { ascending: true })
    .limit(1)

  if (error || !data || data.length === 0) return null
  return (data[0] as AccountMembershipRow).account_id
}

// ─── Access ───────────────────────────────────────────────────────────────────

/**
 * Llama `rpc_product_ranking` (orden por importe, variantes agrupadas, top
 * `window.limit`) y devuelve las filas mapeadas. Propaga cualquier error del
 * RPC — la decisión de degradar (omitir el bloque, nunca reconstruir la
 * suma local) es del consumidor.
 */
export async function fetchTopProducts(
  supabase: SupabaseClient,
  accountId: string,
  window: ProductRankingWindow,
): Promise<TopProduct[]> {
  const { data, error } = await supabase.rpc("rpc_product_ranking", {
    p_account_id: accountId,
    p_start: window.start,
    p_end: window.end,
    p_order_by: "revenue",
    p_group_variants: true,
    p_branch_id: window.branchId ?? null,
    p_canal: null,
    p_limit: window.limit ?? 5,
    p_offset: 0,
  })
  if (error) throw error

  const rows = (data as RpcProductRankingRow[] | null) ?? []
  return rows.map((row) => ({
    productId: row.product_id,
    name: row.product_name,
    units: toNumber(row.units),
    revenue: toNumber(row.revenue),
    marginPct: num(row.gross_margin_pct),
  }))
}
