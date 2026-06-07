/**
 * lib/unit-utils.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * Core multi-unit intelligence. ALL unit-aware decisions in the app must flow
 * through these helpers — no inline `unit.type === 'unit'` checks anywhere.
 *
 * Design principles
 * - Pure functions (no side-effects, no React, no Supabase)
 * - Used by: forms, cart, catalog, reports, tickets, dashboard
 * - Behavior driven by the UnitOfMeasure object — never by the calling module
 */

import type { UnitOfMeasure } from "@/lib/types"

// ─── Semantic predicates ──────────────────────────────────────────────────────

/**
 * Returns true if the unit represents discrete/countable items (whole numbers).
 * Falls back to discrete when no unit is assigned (safe default).
 *
 * @example
 * isProductoPorUnidades({ type: 'unit', ... })   → true
 * isProductoPorUnidades({ type: 'weight', ... }) → false
 * isProductoPorUnidades(undefined)               → true  (assume discrete)
 */
export function isProductoPorUnidades(unit?: UnitOfMeasure | null): boolean {
  return !unit || unit.type === "unit"
}

/**
 * Returns true if the product is measured in continuous quantities
 * (weight, volume, length, custom). Allows — and expects — decimal quantities.
 */
export function isProductoMedible(unit?: UnitOfMeasure | null): boolean {
  return !isProductoPorUnidades(unit)
}

// ─── Input constraints ────────────────────────────────────────────────────────

/**
 * The recommended HTML input `step` for quantity fields of the given unit.
 *
 * - Discrete (unitarios)  → 1       (whole units only)
 * - Measurable (medibles) → 0.001   (three decimal places)
 */
export function unitInputStep(unit?: UnitOfMeasure | null): number {
  return isProductoPorUnidades(unit) ? 1 : 0.001
}

/**
 * The minimum allowed quantity for the given unit.
 * Mirrors unitInputStep so step and min are always consistent.
 */
export function unitInputMin(unit?: UnitOfMeasure | null): number {
  return isProductoPorUnidades(unit) ? 1 : 0.001
}

// ─── Quantity normalization ───────────────────────────────────────────────────

/**
 * Converts a display quantity (entered in the selected unit) to the normalized
 * base quantity that the DB stores in products.stock.
 *
 * The RPC does the same conversion server-side; this helper lets the frontend
 * validate stock locally before hitting the network.
 *
 * @example
 * // product.stock stored in grams, kg.factor = 1000
 * toBaseQuantity(2.5, kgUnit)      → 2500
 * // no unit → factor = 1
 * toBaseQuantity(3, undefined)     → 3
 */
export function toBaseQuantity(
  displayQty: number,
  unit?: UnitOfMeasure | null,
): number {
  return displayQty * (unit?.factor ?? 1)
}

// ─── Lookup helpers ───────────────────────────────────────────────────────────

/**
 * Resolves a UnitOfMeasure from a pre-built Map<id, unit> by its UUID.
 * Returns undefined when unitId is falsy or not found in the map.
 *
 * Prefer passing a memoized Map over calling Array.find() in hot paths.
 */
export function resolveUnit(
  unitId: string | undefined | null,
  unitsById: Map<string, UnitOfMeasure>,
): UnitOfMeasure | undefined {
  if (!unitId) return undefined
  return unitsById.get(unitId)
}
