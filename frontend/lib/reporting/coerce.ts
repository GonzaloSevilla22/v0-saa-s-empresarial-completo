/**
 * Coerción numérica canónica de la capa de reporting (frontend).
 *
 * F7 (revisión adversarial, tanda candidatos-seguridad-db 2026-09-09): antes
 * de este archivo, `toNumber` estaba redeclarado idéntico en
 * `revenue-canon.ts`, `product-ranking.ts` y `critical-stock.ts` — la
 * "Regla de Tres" del proyecto (openspec/specs, CLAUDE.md §"Reutilización
 * antes que repetición") se cumple exactamente en la tercera copia. El
 * gemelo Deno (`supabase/functions/_shared/reporting-canon.ts`) mantiene su
 * propia copia a propósito: los dos runtimes no comparten módulo.
 *
 * Postgres devuelve `numeric` como string vía el driver de Supabase — este
 * helper normaliza esa representación (string u number, null/undefined) a
 * un `number` de JS, con 0 como fallback seguro para valores ausentes o no
 * numéricos (nunca `NaN` propagado a un cálculo o a un render).
 */
export const toNumber = (v: string | number | null | undefined): number => {
  if (v == null) return 0
  const n = Number(v)
  return Number.isNaN(n) ? 0 : n
}
