/**
 * Aritmética canónica de reporting para el frontend (Next.js) —
 * kpi-ia-canonical-revenue, D3.
 *
 * Gemelo Deno: `supabase/functions/_shared/reporting-canon.ts`.
 * Test de paridad entre ambos: `__tests__/reporting/reporting-canon-parity.test.ts`.
 *
 * Estas funciones son la ÚNICA fórmula de revenue de línea del frontend
 * (openspec/specs/reporting-invariants/spec.md — "Enforcement de consumo").
 * En filas modernas de `sales`/`v_sales_flat`, `amount` es el precio UNITARIO
 * y `total` es el subtotal de línea (`amount * quantity`); sumar `amount` a
 * secas subcuenta cualquier venta con `quantity > 1`. Filas legacy no tienen
 * `total` (columna agregada después) y caen al precio unitario como total de
 * línea — es lo mejor que se puede hacer sin la cantidad.
 */

// ─── Types ────────────────────────────────────────────────────────────────────

/** Fila mínima de venta con la que se puede calcular su revenue de línea.
 *  Los numerics de Postgres llegan como `string` vía supabase-js. */
export interface SaleRevenueRow {
  amount: number | string | null
  total?: number | string | null
}

export interface Window {
  from: string
  to: string
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const toNumber = (v: number | string | null | undefined): number => {
  if (v == null) return 0
  const n = Number(v)
  return Number.isNaN(n) ? 0 : n
}

/**
 * Revenue de una línea de venta: `COALESCE(total, amount)`.
 *
 * Usa `??` (no `||`) a propósito: `total = 0` es un subtotal legítimo (p. ej.
 * una venta bonificada al 100%) y debe aportar 0, no caer al fallback de
 * `amount`. Solo `null`/`undefined` disparan el fallback.
 */
export function lineRevenue(row: SaleRevenueRow): number {
  const raw = row.total ?? row.amount
  return toNumber(raw)
}

/** Suma el revenue de línea de un conjunto de filas de venta. */
export function sumLineRevenue(rows: SaleRevenueRow[]): number {
  return rows.reduce((sum, row) => sum + lineRevenue(row), 0)
}

/**
 * Margen neto porcentual = `netProfit / revenue * 100`, redondeado.
 *
 * Devuelve `null` cuando no hay base de cálculo (`revenue` nulo, 0 o
 * negativo) o cuando `netProfit` no está disponible — "sin base de cálculo"
 * no es lo mismo que "margen cero". Una ganancia negativa SÍ se informa
 * (margen negativo).
 */
export function netMarginPct(
  netProfit: number | null,
  revenue: number | null,
): number | null {
  if (netProfit == null || revenue == null || revenue <= 0) return null
  return Math.round((netProfit / revenue) * 100)
}

/**
 * Ventana comparativa sintética (D2): el intervalo inmediatamente anterior,
 * de igual duración que `[from, to]`, sin invertirse ni solaparse con la
 * ventana original. `from`/`to` son ISO 8601 parseables por `Date.parse`.
 */
export function previousWindow(from: string, to: string): Window {
  const fromMs = Date.parse(from)
  const toMs = Date.parse(to)
  const durationMs = toMs - fromMs

  const prevToMs = fromMs - 1
  const prevFromMs = prevToMs - durationMs

  return {
    from: new Date(prevFromMs).toISOString(),
    to: new Date(prevToMs).toISOString(),
  }
}
