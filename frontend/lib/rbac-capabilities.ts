/**
 * presupuestos-modulo (D11) — capacidades de rol de TENANT en el frontend.
 *
 * Espejo de `backend/core/rbac.py`: el backend es la fuente de verdad y el
 * frontend sólo decide qué mostrar (ocultar un CTA que igual rechazaría un 403).
 * Cada conjunto está atado por test (`__tests__/lib/rbac-capabilities.test.ts`)
 * al de Python y al catálogo de la máquina de estados
 * (`document_status_transitions.allowed_role`).
 *
 * Se decide sobre el CONJUNTO `roles` de `useOrgRole`, nunca sobre el `role`
 * singular: ese colapsa a `member` a un usuario que sólo es vendedor y le
 * ocultaría el módulo al usuario principal.
 */
import type { OrgRole } from "@/lib/types"

/** Crear, editar, enviar, rechazar, eliminar y convertir un presupuesto. */
export const CAN_QUOTE: readonly OrgRole[] = ["owner", "admin", "seller"]

/**
 * ¿Alguno de los roles activos del usuario habilita la capacidad?
 *
 * Mientras el conjunto no resolvió (`rolesResolved === false`) responde `true`:
 * fail-OPEN, igual que `isWriter`. Con el conjunto sin resolver `roles` vale
 * `[role]`, que para un vendedor es `["member"]`; decidir sobre eso ocultaría el
 * módulo durante la carga. Es sólo informativo — la barrera real es la RPC
 * (`P0403`) y `require_account_role` del backend.
 */
export function hasCapability(
  roles: readonly OrgRole[],
  capability: readonly OrgRole[],
  rolesResolved: boolean,
): boolean {
  if (!rolesResolved) return true
  return roles.some((role) => capability.includes(role))
}
