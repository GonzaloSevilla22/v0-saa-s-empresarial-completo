"use client"

import { useMemo } from "react"
import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { useRoleCatalog } from "@/hooks/data/use-role-catalog"
import type { OrgRole } from "@/lib/types"

interface UseOrgRoleReturn {
  /** Derivado singular de mayor precedencia (owner > admin > resto) — la
   * misma forma que consumen las ~40 pantallas de hoy (v3-rbac-multirole
   * Parte C, D19). */
  role: OrgRole | null
  /** Conjunto COMPLETO de roles ACTIVOS del miembro (ronda 1 adversarial,
   * finding MAJOR — ver `isWriter` abajo). */
  roles: OrgRole[]
  isWriter: boolean
  isLoading: boolean
}

/**
 * Returns the current user's role(s) within their active account, and
 * whether they have write access.
 *
 * Uses React Query with a 5-minute stale time to stay fresh after role changes
 * made by other admins without requiring a full re-login.
 */
export function useOrgRole(): UseOrgRoleReturn {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const supabase  = useMemo(() => createClient(), [])

  const { data: role, isLoading: isRoleLoading } = useQuery<OrgRole | null>({
    queryKey: ["orgRole", accountId],
    queryFn:  async () => {
      if (!accountId) return null
      const { data, error } = await supabase.rpc("rpc_my_account_role", {
        p_account_id: accountId,
      })
      if (error) throw error
      return (data as OrgRole | null) ?? null
    },
    enabled:   !!accountId,
    staleTime: 5 * 60 * 1000,
    initialData: user?.accountRole ?? null,
  })

  // Ronda 1 adversarial (finding MAJOR): `rpc_my_account_role` (Parte A, sin
  // tocar) sólo puede devolver 'owner' | 'admin' | 'member' — su CASE
  // colapsa a 'member' cualquier conjunto que no contenga owner ni admin.
  // Un miembro cuyo único rol activo sea funcional (seller/cashier/stock/
  // purchases/accountant) quedaba con `role === "member"` y por lo tanto
  // `isWriter === false`, pese a que `is_account_writer` (la fuente real)
  // dice que SÍ puede escribir — el POS le bloqueaba la venta. Se resuelve
  // trayendo el CONJUNTO real vía `rpc_my_active_account_roles()` (Parte B,
  // SIN parámetro — resuelve auth.uid() del lado del servidor, GRANT a
  // authenticated, invocable por supabase-js como cualquier otro RPC pese a
  // lo que decía el comentario viejo de este archivo) y contrastándolo
  // contra `is_writer` del catálogo (useRoleCatalog, ya cacheado por
  // staleTime propio — no duplica el fetch en cada consumidor de este hook).
  const { data: activeRoles, isSuccess: isActiveRolesResolved } = useQuery<OrgRole[]>({
    queryKey: ["orgActiveRoles", accountId],
    queryFn:  async () => {
      const { data, error } = await supabase.rpc("rpc_my_active_account_roles")
      if (error) throw error
      return (data as OrgRole[] | null) ?? []
    },
    enabled:   !!accountId,
    staleTime: 5 * 60 * 1000,
  })

  const { data: catalog } = useRoleCatalog()

  // `roles`: el conjunto completo cuando ya resolvió (incluido el conjunto
  // VACÍO genuino -- ronda 2 adversarial, finding NIT, corregido); si el
  // conjunto todavía es INDETERMINADO (cargando o con error), el mismo array
  // de conveniencia de un elemento derivado del singular (compatibilidad).
  //
  // Antes de este fix, el `&& activeRoles.length > 0` de la condición hacía
  // que un conjunto RESUELTO pero vacío cayera igual al fallback `[role]` --
  // exactamente el mismo caso en el que `isWriter` (abajo) SÍ distingue
  // "resuelto vacío" de "indeterminado" y responde `false`. Un miembro sin
  // ningún rol activo quedaba con `roles === ["member"]` (el singular
  // legacy) e `isWriter === false` -- dos derivados del mismo hook
  // contradiciéndose entre sí. Nadie consume `roles` fuera de la pantalla de
  // gestión hoy, pero es una trampa para el primer consumidor que decida
  // algo mirándolo.
  const roles: OrgRole[] =
    isActiveRolesResolved && activeRoles
      ? activeRoles
      : role
        ? [role]
        : []

  // Fail-OPEN preservado (D19, ronda 1 adversarial: "conservando el
  // fail-open cuando el conjunto es indeterminado", literal del fix
  // pedido): un estado INDETERMINADO (el conjunto todavía no resolvió, o
  // resolvió con error) se trata SIEMPRE como escritor — nunca se vuelve a
  // mirar el singular `role` para esto, porque `role==="member"` es
  // PRECISAMENTE el valor ambiguo que colapsa tanto a un viewer real como a
  // un seller/cashier/stock/purchases/accountant, y bloquear en base a él
  // mientras el conjunto real todavía no llegó reintroduciría el mismo
  // bloqueo falso que este fix existe para eliminar (aunque fuera transitorio).
  // Una vez que el conjunto SÍ resolvió, la pregunta deja de ser "¿es
  // viewer/member?" y pasa a ser la real: ¿ALGUNO de los roles activos es
  // is_writer en el catálogo? (mismo predicado EXISTS que `is_account_writer`
  // en la base — fail-CLOSED sólo cuando el dato es cierto, nunca por
  // indeterminación). Si el catálogo todavía no cargó, sigue indeterminado
  // -> escritor. Este gate del frontend es sólo informativo (RLS
  // is_account_writer + require_account_role del backend son la barrera
  // real), así que un breve destello optimista mientras carga no compromete
  // nada — igual que el criterio ya documentado antes de esta ronda.
  const isWriter = (() => {
    if (!isActiveRolesResolved || !activeRoles) {
      return true
    }
    if (activeRoles.length === 0) {
      // Conjunto resuelto y genuinamente vacío (sin membresía activa, o
      // todos sus roles vencidos) -> ningún rol activo es writer, igual que
      // `is_account_writer` con 0 filas EXISTS.
      return false
    }
    if (!catalog) {
      // El conjunto de roles SÍ resolvió pero el catálogo (is_writer por
      // código) todavía no -- indeterminado, fail-open.
      return true
    }
    return activeRoles.some((r) => catalog.find((c) => c.code === r)?.is_writer ?? true)
  })()

  return { role: role ?? null, roles, isWriter, isLoading: isRoleLoading }
}
