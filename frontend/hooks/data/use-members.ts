"use client"

/**
 * v3-rbac-multirole Parte C (grupo 14/17) — administración de miembros y sus
 * roles, vía el backend FastAPI nuevo (/members). Reemplaza el consumo
 * directo de rpc_change_member_role/rpc_remove_member desde
 * /organizacion/roles por el listado con CONJUNTO de roles + asignar/
 * revocar/quitar en 3 capas (router -> service -> repository).
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { OrgRole } from "@/lib/types"

export interface MemberRoleAssignment {
  role: OrgRole
  expires_at: string | null
  is_active: boolean
}

export interface MemberRow {
  member_id: string
  user_id: string
  legacy_role: OrgRole
  created_at: string
  name: string | null
  email: string | null
  roles: MemberRoleAssignment[]
}

export function useMembers(accountId: string | null) {
  const queryClient = useQueryClient()
  const queryKey = queryKeys.members.list(accountId)

  const query = useQuery({
    queryKey,
    queryFn: async (): Promise<MemberRow[]> => {
      return pythonClient.get<MemberRow[]>("/members")
    },
    enabled: !!accountId,
    staleTime: 30_000,
  })

  function invalidateAll() {
    queryClient.invalidateQueries({ queryKey })
    // La pantalla de roles hoy ya invalida "orgRole" en las mutaciones
    // legacy — se conserva para que el rol singular propio (useOrgRole)
    // también se refresque cuando uno se asigna/revoca un rol a sí mismo.
    queryClient.invalidateQueries({ queryKey: ["orgRole", accountId] })
    // Ronda 2 adversarial (finding MINOR): "orgActiveRoles" es la clave de
    // la que useOrgRole.ts deriva isWriter DESDE la ronda 1 (el CONJUNTO
    // real vía rpc_my_active_account_roles(), no el singular "orgRole") --
    // sin invalidarla acá, un owner/admin que se asigna o revoca un rol a
    // SÍ MISMO desde /organizacion/roles seguía viendo el conjunto viejo
    // (y por lo tanto los gates de escritura de ~34 pantallas) hasta los 5
    // minutos de staleTime o hasta recargar la página.
    queryClient.invalidateQueries({ queryKey: ["orgActiveRoles", accountId] })
    queryClient.invalidateQueries({ queryKey: ["teamMembers", accountId] })
  }

  const assignRoleMutation = useMutation({
    mutationFn: async ({
      userId,
      role,
      expiresAt,
    }: {
      userId: string
      role: OrgRole
      expiresAt?: string | null
    }) => {
      return pythonClient.post(`/members/${userId}/roles`, {
        role,
        expires_at: expiresAt ?? null,
      })
    },
    onSuccess: invalidateAll,
  })

  const revokeRoleMutation = useMutation({
    mutationFn: async ({ userId, role }: { userId: string; role: OrgRole }) => {
      return pythonClient.delete(`/members/${userId}/roles/${role}`)
    },
    onSuccess: invalidateAll,
  })

  const removeMemberMutation = useMutation({
    mutationFn: async (userId: string) => {
      return pythonClient.delete(`/members/${userId}`)
    },
    onSuccess: invalidateAll,
  })

  return {
    members: query.data ?? [],
    isLoading: query.isLoading,
    isError: query.isError,
    assignRole: assignRoleMutation.mutateAsync,
    revokeRole: revokeRoleMutation.mutateAsync,
    removeMember: removeMemberMutation.mutateAsync,
    assignRoleMutation,
    revokeRoleMutation,
    removeMemberMutation,
  }
}
