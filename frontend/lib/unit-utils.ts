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
 * Converts a display quantity (entered in the selected unit) to the quantity
 * in which the product's stock is kept: the product's BASE unit (ventas-unidades-
 * conversion D1). Mirror of the single SQL definition `_uom_normalize_quantity`
 * that every stock-writing path uses server-side — this helper only lets the
 * frontend validate stock locally before hitting the network; the server
 * decides.
 *
 *   normalized = displayQty × factor(unit) ÷ factor(product base unit)
 *
 * Rounded to 4 decimals (NUMERIC(15,4)) so `450 × 0.001` compares cleanly.
 *
 * @example
 * // product kept in kg (factor 1), line entered in g (factor 0.001)
 * toBaseQuantity(450, gUnit, kgUnit)   → 0.45
 * // product kept in g, line entered in kg
 * toBaseQuantity(0.5, kgUnit, gUnit)   → 500
 * // no unit → factor = 1 (quantity already in the product's base unit)
 * toBaseQuantity(3, undefined)         → 3
 */
export function toBaseQuantity(
  displayQty: number,
  unit?: UnitOfMeasure | null,
  productBaseUnit?: UnitOfMeasure | null,
): number {
  const factor = (unit?.factor ?? 1) / (productBaseUnit?.factor ?? 1)
  return Math.round(displayQty * factor * 10_000) / 10_000
}

// ─── Unit compatibility (selector) ─────────────────────────────────────────

/**
 * Returns true when a unit is a BASE unit of its type (factor 1, no parent).
 * Kilogramo, Litro, Metro and Unidad are base units; Gramo, Docena, mL are not.
 */
export function isBaseUnit(unit: Pick<UnitOfMeasure, "factor" | "baseUnitId">): boolean {
  return unit.factor === 1 && !unit.baseUnitId
}

/**
 * The units a line may use for a product — the ONLY definition, shared by the
 * POS, the sale form and the purchase form (ventas-unidades-conversion D3/D5),
 * and the exact mirror of what `_uom_normalize_quantity` accepts server-side:
 *
 * - product WITH a base unit  → every unit of the same `type` (the base included);
 *   converting across types (kg ↔ L) is never defined, so those are not offered.
 * - product WITHOUT base unit → only base units (factor 1): there is no
 *   reference against which to convert a derived unit (this is how 0,381 "mL"
 *   became a -0.0004 stock movement on 2026-09-22).
 *
 * @example
 * compatibleUnits(units, kgUnit)    → [kg, g, tn]
 * compatibleUnits(units, undefined) → [u, kg, L, m]
 */
export function compatibleUnits(
  units: UnitOfMeasure[],
  productBaseUnit?: UnitOfMeasure | null,
): UnitOfMeasure[] {
  // Auditoría post-apply: un solo predicado (isUnitCompatible); antes había
  // una segunda copia acá.
  return units.filter((u) => isUnitCompatible(u, productBaseUnit))
}

/**
 * Whether a previously chosen unit is still valid for a product — used to
 * fall back to the product's base unit (or "no unit") when the product changes.
 */
export function isUnitCompatible(
  unit: UnitOfMeasure | null | undefined,
  productBaseUnit?: UnitOfMeasure | null,
): boolean {
  if (!unit) return true
  if (productBaseUnit) return unit.type === productBaseUnit.type
  return isBaseUnit(unit)
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
