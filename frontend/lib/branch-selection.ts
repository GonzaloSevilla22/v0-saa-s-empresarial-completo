/**
 * remitos-venta (D11) — qué sucursal precarga el formulario del remito.
 *
 * Mismo criterio que `c26_default_branch` en el servidor
 * (`20260625000001:143-144`): la sucursal ACTIVA y ABIERTA más antigua
 * (`created_at` ascendente). Sin su fallback a una sucursal cerrada: un remito
 * no puede salir de una sucursal cerrada (`branch_closed`).
 *
 * ventas-sucursal-por-defecto dejó `lib/default-branch.ts` (`resolveDefaultBranch`):
 * el mismo criterio PERO con el fallback de `c26_default_branch` a la más antigua
 * a secas cuando ninguna está operativa. Este módulo NO lo reutiliza a propósito:
 * un remito no puede salir de una sucursal cerrada, así que sin ninguna operativa
 * el formulario nace SIN sucursal en vez de con una que el servidor rechazaría.
 * La venta sí lo usa (el servidor resuelve ese fallback y es él quien rechaza con
 * `no_branch_found` / `branch_closed`).
 */
import type { Branch } from "@/lib/types"

type SelectableBranch = Pick<Branch, "id" | "createdAt" | "isActive" | "status">

/** Las sucursales de las que puede salir mercadería, de la más antigua a la más nueva. */
export function operativeBranches<T extends SelectableBranch>(branches: readonly T[]): T[] {
  return branches
    .filter((branch) => branch.isActive && branch.status !== "closed")
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
}

/** La sucursal con la que nace el formulario, o `null` si ninguna está operativa. */
export function pickOldestOperativeBranchId(branches: readonly SelectableBranch[]): string | null {
  return operativeBranches(branches)[0]?.id ?? null
}
