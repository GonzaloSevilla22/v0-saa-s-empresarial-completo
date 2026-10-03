/**
 * remitos-venta (D11) — qué sucursal precarga el formulario del remito.
 *
 * Mismo criterio que `c26_default_branch` en el servidor
 * (`20260625000001:143-144`): la sucursal ACTIVA y ABIERTA más antigua
 * (`created_at` ascendente). Sin su fallback a una sucursal cerrada: un remito
 * no puede salir de una sucursal cerrada (`branch_closed`).
 *
 * Es un recurso provisorio: cuando el PR #607 (`ventas-sucursal-por-defecto`)
 * deje `lib/default-branch.ts` en `main`, el remito lo reutiliza y este módulo
 * se reduce a `operativeBranches`.
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
