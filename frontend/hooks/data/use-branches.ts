"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { queryKeys } from "@/lib/query-keys"
import type { Branch } from "@/lib/types"

function mapRow(r: {
  id: string
  account_id: string
  name: string
  address: string | null
  is_active: boolean
  created_at: string
  status: string | null
  opened_at: string | null
  closed_at: string | null
  created_by: string | null
  deactivated_at: string | null
  deactivated_by: string | null
}): Branch {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    address:   r.address,
    isActive:  r.is_active,
    createdAt: r.created_at,
    status:    (r.status as Branch["status"]) ?? "active",
    openedAt:  r.opened_at,
    closedAt:  r.closed_at,
    createdBy:      r.created_by ?? null,
    deactivatedAt:  r.deactivated_at ?? null,
    deactivatedBy:  r.deactivated_by ?? null,
  }
}

/**
 * Traduce el mensaje crudo de una RPC de sucursales a texto para el usuario.
 * Exportada (no sólo usada internamente) para que
 * sucursal-guard-vaciado-auditoria pueda testearla directo, sin duplicar su
 * lógica en el test (como venía haciendo __tests__/branches.test.ts, que
 * quedó desactualizado frente a esta versión real).
 */
export function translateRpcError(message: string): string {
  if (message.includes("branch_limit_exceeded")) return "Límite de sucursales alcanzado para tu plan."
  if (message.includes("branch_name_duplicate")) return "Ya existe una sucursal con ese nombre."
  // sucursal-guard-vaciado-auditoria (G1, D3): P0428, un solo código con 3
  // motivos discriminados por token de texto — el orden de los `includes`
  // importa: branch_has_stock es el token MÁS específico y también aparece
  // como substring de ningún otro, así que no hay colisión, pero se lo deja
  // primero por ser el caso histórico (ya lo traducía el cierre con P0409).
  if (message.includes("branch_has_stock"))
    return "La sucursal tiene stock asignado. Transferilo a otra sucursal antes de darla de baja."
  if (message.includes("branch_has_open_cash_session"))
    return "La sucursal tiene una sesión de caja abierta. Cerrala antes de darla de baja."
  if (message.includes("branch_has_pending_transfers"))
    return "La sucursal tiene transferencias de stock sin completar. Esperá a que terminen antes de darla de baja."
  if (message.includes("branch_delete_forbidden"))
    return "No se puede borrar una sucursal — desactivala en su lugar."
  if (message.includes("last_active_branch"))    return "No podés cerrar la única sucursal operativa de tu cuenta."
  if (message.includes("branch_closed"))         return "La sucursal está cerrada."
  if (message.includes("unauthorized"))          return "No tenés permisos para realizar esta acción."
  if (message.includes("branch_not_found"))      return "La sucursal no existe."
  // C-28: cash session error codes
  if (message.includes("cashbox_session_open"))  return "Ya hay una sesión de caja abierta para esta caja."
  if (message.includes("no_open_session"))        return "No hay sesión de caja abierta. Abrí una sesión primero."
  if (message.includes("session_not_open"))       return "La sesión de caja no está abierta."
  return message || "Ocurrió un error inesperado."
}

/**
 * Returns the active branches for the current user's account.
 * Only populated for plan 'pro' (hasBranchesModule); returns [] otherwise.
 */
export function useBranches() {
  const { user } = useAuth()
  const supabase  = useMemo(() => createClient(), [])
  const accountId = user?.accountId ?? null

  const query = useQuery({
    queryKey: queryKeys.branches.active(),
    queryFn: async (): Promise<Branch[]> => {
      if (!accountId) return []
      const { data, error } = await supabase
        .from("branches")
        .select("id, account_id, name, address, is_active, created_at, status, opened_at, closed_at, created_by, deactivated_at, deactivated_by")
        .eq("account_id", accountId)
        .eq("is_active", true)
        .order("created_at", { ascending: true })

      if (error) throw error
      return (data ?? []).map(mapRow)
    },
    enabled: !!accountId,
    staleTime: 5 * 60 * 1000, // 5 min — branches rarely change
  })

  return {
    branches:  query.data ?? [],
    isLoading: query.isLoading,
    isError:   query.isError,
  }
}

/**
 * sucursal-guard-vaciado-auditoria (G2, OQ-4): sucursales INACTIVAS de la
 * cuenta, con su autoría de baja — para la línea secundaria de BranchList.tsx
 * ("desactivada por X el <fecha>"). Hook separado de useBranches() a
 * propósito: ese hook alimenta selectores de formularios (TransferStockModal,
 * sale-form, etc.) que sólo deben ofrecer sucursales ACTIVAS — ensanchar su
 * filtro habría filtrado sucursales inactivas en esos selectores.
 */
export function useInactiveBranches() {
  const { user } = useAuth()
  const supabase  = useMemo(() => createClient(), [])
  const accountId = user?.accountId ?? null

  const query = useQuery({
    queryKey: queryKeys.branches.inactive(),
    queryFn: async (): Promise<Branch[]> => {
      if (!accountId) return []
      const { data, error } = await supabase
        .from("branches")
        .select("id, account_id, name, address, is_active, created_at, status, opened_at, closed_at, created_by, deactivated_at, deactivated_by")
        .eq("account_id", accountId)
        .eq("is_active", false)
        .order("deactivated_at", { ascending: false })

      if (error) throw error
      return (data ?? []).map(mapRow)
    },
    enabled: !!accountId,
    staleTime: 5 * 60 * 1000,
  })

  return {
    branches:  query.data ?? [],
    isLoading: query.isLoading,
    isError:   query.isError,
  }
}

/**
 * Mutation to create a new branch via rpc_create_branch.
 */
export function useCreateBranch() {
  const queryClient = useQueryClient()
  const { user }    = useAuth()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async ({ name, address }: { name: string; address?: string }) => {
      const accountId = user?.accountId
      if (!accountId) throw new Error("No active account")

      const { data, error } = await supabase.rpc("rpc_create_branch", {
        p_account_id: accountId,
        p_name:       name,
        p_address:    address ?? null,
      })
      if (error) throw new Error(translateRpcError(error.message))
      return data as Branch
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.branches.all() })
    },
  })
}

/**
 * C-26: lifecycle operacional — abrir/cerrar sucursal.
 * El cierre falla con mensaje claro si la sucursal tiene stock
 * (branch_has_stock) o es la última operativa (last_active_branch).
 */
export function useOpenBranch() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (branchId: string) => {
      const { error } = await supabase.rpc("rpc_open_branch", { p_branch_id: branchId })
      if (error) throw new Error(translateRpcError(error.message))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.branches.all() })
    },
  })
}

export function useCloseBranch() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (branchId: string) => {
      const { error } = await supabase.rpc("rpc_close_branch", { p_branch_id: branchId })
      if (error) throw new Error(translateRpcError(error.message))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.branches.all() })
    },
  })
}

/**
 * Mutation to soft-delete a branch via rpc_deactivate_branch.
 */
export function useDeactivateBranch() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (branchId: string) => {
      const { error } = await supabase.rpc("rpc_deactivate_branch", {
        p_branch_id: branchId,
      })
      if (error) throw new Error(translateRpcError(error.message))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.branches.all() })
    },
  })
}
