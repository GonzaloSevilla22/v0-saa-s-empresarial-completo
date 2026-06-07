/**
 * lib/format-unit.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * Visual formatters for unit-aware quantities and prices.
 *
 * Use these functions everywhere a quantity or price appears with a unit:
 *   - product catalog dropdowns
 *   - cart rows
 *   - sale / purchase tickets
 *   - stock semaphore labels
 *   - reports & dashboard cards
 *   - movement history tables
 *
 * Design principles
 * - Pure functions (no React, no hooks, no Supabase)
 * - Consistent decimal display: integers show no decimals, decimals → 3 places
 * - Graceful fallbacks: undefined unit → "uds" for stock, no suffix for prices
 */

import { formatMoney, type Currency } from "@/lib/format"

// ─── Public formatters ────────────────────────────────────────────────────────

/**
 * Formats a stock quantity with its unit symbol.
 * Always shows a symbol — falls back to "uds" when none is provided.
 *
 * @example
 * formatStock(10, "kg")      → "10 kg"
 * formatStock(1.25, "kg")    → "1.250 kg"
 * formatStock(3, "uds")      → "3 uds"
 * formatStock(3, undefined)  → "3 uds"
 */
export function formatStock(qty: number, unitSymbol?: string | null): string {
  const sym = unitSymbol ?? "uds"
  return `${_fmtQtyNum(qty)} ${sym}`
}

/**
 * Formats a unit price with a per-unit suffix when a symbol is known.
 *
 * @example
 * formatPricePerUnit(1500, "kg")      → "$1.500/kg"
 * formatPricePerUnit(500, "L")        → "$500/L"
 * formatPricePerUnit(500, undefined)  → "$500"   (no suffix for unitless)
 */
export function formatPricePerUnit(
  price: number,
  unitSymbol?: string | null,
  currency?: Currency,
): string {
  const money = formatMoney(price, currency)
  if (!unitSymbol) return money
  return `${money}/${unitSymbol}`
}

/**
 * Formats a quantity for display with its unit symbol.
 * Returns a bare number string when no symbol is provided.
 *
 * @example
 * formatQuantity(1.25, "kg")     → "1.250 kg"
 * formatQuantity(3, "uds")       → "3 uds"
 * formatQuantity(3, undefined)   → "3"
 */
export function formatQuantity(qty: number, unitSymbol?: string | null): string {
  const formatted = _fmtQtyNum(qty)
  if (!unitSymbol) return formatted
  return `${formatted} ${unitSymbol}`
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

/**
 * Core number formatter for quantities.
 *
 * - Integer values  → no decimals  ("3", "10", "1000")
 * - Decimal values  → exactly 3 dp ("1.250", "0.500", "12.375")
 *
 * Three decimal places match the precision typically used in commerce
 * (grams within kg, millilitres within L, etc.) and align with NUMERIC(15,4).
 */
function _fmtQtyNum(qty: number): string {
  if (Number.isInteger(qty)) return qty.toString()
  return qty.toFixed(3)
}
