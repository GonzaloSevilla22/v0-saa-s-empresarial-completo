/**
 * productos-padre-variantes (D9, D11) — reglas de precio del catálogo que viven
 * del lado del cliente: el redondeo compartido con la base y la sugerencia de
 * precio a partir del costo.
 *
 * Todo es PURO (sin React ni red) para que la regla de "nunca pisar un precio
 * escrito" tenga test propio y los formularios sólo la conecten.
 */

/**
 * Factor de la sugerencia de precio (costo × 1,5). Es SÓLO una sugerencia: el
 * markup real de las cuentas es muy disperso (propose, medición del 2026-11-05).
 * Candidato posterior: `markup-por-cuenta`.
 */
export const SUGGESTED_MARKUP_FACTOR = 1.5

/**
 * Redondeo a pesos enteros, mitad hacia afuera del cero.
 *
 * Contraparte TS de `public.product_round_price(numeric)` (`round(x, 0)` de
 * Postgres sobre `numeric`). `Math.round` solo redondea la mitad hacia +∞
 * (-2.5 → -2), por eso se redondea el valor absoluto y se restituye el signo.
 * La paridad la sostiene la tabla `supabase/tests/fixtures/product_round_price_cases.json`.
 */
export function roundToPesos(n: number): number {
  const rounded = Math.sign(n) * Math.round(Math.abs(n))
  return rounded === 0 ? 0 : rounded // normaliza -0
}

/** `costo × factor` redondeado a pesos, o `null` si el costo no sirve de base. */
export function suggestPriceFromCost(
  cost: number | null | undefined,
  factor: number = SUGGESTED_MARKUP_FACTOR,
): number | null {
  if (cost == null || !Number.isFinite(cost) || cost <= 0) return null
  return roundToPesos(cost * factor)
}

export interface PriceSuggestionState {
  /** Costo recién escrito (null = vacío). */
  cost: number | null
  /** Precio actual del formulario (0 = vacío). */
  price: number
  /** Última sugerencia que el formulario aplicó; null si nunca aplicó una o el usuario escribió el precio. */
  lastSuggested: number | null
}

/**
 * Regla de pisado (D11): al cambiar el costo, el precio se reemplaza por la
 * sugerencia SÓLO si está vacío o es igual a la última sugerencia aplicada.
 * Un precio que el usuario escribió (distinto de la sugerencia) nunca se pisa,
 * ni en el alta ni en la edición de un producto que ya trae precio.
 */
export function nextPriceOnCostChange(state: PriceSuggestionState): { price: number; lastSuggested: number | null } {
  const suggestion = suggestPriceFromCost(state.cost)
  if (suggestion == null) return { price: state.price, lastSuggested: state.lastSuggested }
  const priceIsEmpty = !(state.price > 0)
  const priceIsOurSuggestion = state.lastSuggested != null && state.price === state.lastSuggested
  if (priceIsEmpty || priceIsOurSuggestion) return { price: suggestion, lastSuggested: suggestion }
  return { price: state.price, lastSuggested: state.lastSuggested }
}
