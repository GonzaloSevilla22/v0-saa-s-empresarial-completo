/**
 * ventas-sucursal-por-defecto (D10) — UNA sola definición de "la sucursal
 * principal" en el cliente, espejo exacto de `c26_default_branch` del servidor
 * (`supabase/migrations/20260625000001_c26_branch_as_root.sql`):
 *
 *   1. la sucursal ACTIVA y OPERATIVA (`status = 'active'`) más antigua;
 *   2. sin ninguna operativa, la más antigua a secas (aunque esté cerrada).
 *
 * Recibe las sucursales como las devuelve `useBranches` (activas, ordenadas por
 * `created_at` ascendente) y respeta ese orden: no reordena por su cuenta.
 *
 * Quienes antes tomaban `branches[0]` como "la principal" (el opt-in de caja, el
 * aviso de cambio de sucursal por defecto, el POS y el diálogo de conversión de
 * presupuestos) la leen de acá. `branches[0]` sólo coincide con el servidor
 * mientras la sucursal más antigua no esté CERRADA: con la más antigua cerrada,
 * el cliente la tomaba como principal y el servidor no.
 *
 * Distinto de `lib/branch-selection.ts` (remitos): un remito no puede salir de una
 * sucursal cerrada, así que ahí no hay fallback; la venta sí lo tiene, porque el
 * servidor lo resuelve igual y es él quien rechaza (`P0422 no_branch_found` /
 * `branch_closed`).
 */
import type { Branch } from "@/lib/types"

type DefaultBranchCandidate = Pick<Branch, "isActive" | "status">

export function resolveDefaultBranch<T extends DefaultBranchCandidate>(branches: readonly T[]): T | null {
  return branches.find((branch) => branch.isActive && branch.status === "active") ?? branches[0] ?? null
}
