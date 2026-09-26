"use client"

/**
 * C-27 v21-fiscal-profile — Hook `usePointsOfSale`.
 *
 * List + create + deactivate de puntos de venta vía Python backend.
 * TanStack Query; invalida al mutar.
 *
 * Design ref: OQ-2 (multi-PV), D10 (account_id desnorm en PV para RLS)
 *
 * punto-venta-seleccion (D2/D9): `isDefault` + mutaciones para marcar / quitar
 * el PV predeterminado de la cuenta (uno como mucho, sólo activo).
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── Types ────────────────────────────────────────────────────────────────────

export interface PointOfSale {
  id: string
  fiscalProfileId: string
  accountId: string
  branchId: string | null
  numero: number
  isActive: boolean
  /** Predeterminado de la cuenta (punto-venta-seleccion). */
  isDefault: boolean
  createdAt: string
}

interface PointOfSaleApiRow {
  id: string
  fiscal_profile_id: string
  account_id: string
  branch_id: string | null
  numero: number
  is_active: boolean
  /** Ausente en un backend anterior a la migración 20261063000001. */
  is_default?: boolean
  created_at: string
}

interface PointOfSaleCreateInput {
  numero: number
  branch_id?: string | null
}

function mapRow(r: PointOfSaleApiRow): PointOfSale {
  return {
    id:              r.id,
    fiscalProfileId: r.fiscal_profile_id,
    accountId:       r.account_id,
    branchId:        r.branch_id,
    numero:          r.numero,
    isActive:        r.is_active,
    isDefault:       r.is_default ?? false,
    createdAt:       r.created_at,
  }
}

// ── Hooks ────────────────────────────────────────────────────────────────────

/** Lista todos los puntos de venta de la cuenta activa. */
export function usePointsOfSale() {
  const query = useQuery({
    queryKey: queryKeys.pointsOfSale.lists(),
    queryFn: async (): Promise<PointOfSale[]> => {
      const rows = await pythonClient.get<PointOfSaleApiRow[]>("/fiscal/points-of-sale")
      return rows.map(mapRow)
    },
    staleTime: 5 * 60 * 1000, // 5 min
  })

  return {
    pointsOfSale: query.data ?? [],
    isLoading:    query.isLoading,
    isError:      query.isError,
    error:        query.error,
  }
}

/** Crea un nuevo punto de venta para la cuenta activa. */
export function useCreatePointOfSale() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (input: PointOfSaleCreateInput): Promise<PointOfSale> => {
      const row = await pythonClient.post<PointOfSaleApiRow>("/fiscal/points-of-sale", input)
      return mapRow(row)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.pointsOfSale.all() })
    },
  })
}

/** Desactiva un punto de venta (soft-delete: is_active = false). */
export function useDeactivatePointOfSale() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (pvId: string): Promise<PointOfSale> => {
      const row = await pythonClient.patch<PointOfSaleApiRow>(
        `/fiscal/points-of-sale/${pvId}`,
        {},
      )
      return mapRow(row)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.pointsOfSale.all() })
    },
  })
}

/**
 * Marca un PV como predeterminado de la cuenta (punto-venta-seleccion, D9).
 * El backend quita la marca del anterior en la misma transacción; 404 si el PV
 * es ajeno o está inactivo, 403 si el rol no es owner/admin.
 */
export function useSetDefaultPointOfSale() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (pvId: string): Promise<PointOfSale> => {
      const row = await pythonClient.post<PointOfSaleApiRow>(
        `/fiscal/points-of-sale/${pvId}/default`,
        {},
      )
      return mapRow(row)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.pointsOfSale.all() })
    },
  })
}

/** Deja la cuenta sin punto de venta predeterminado. */
export function useClearDefaultPointOfSale() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (): Promise<void> => {
      await pythonClient.delete<void>("/fiscal/points-of-sale/default")
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.pointsOfSale.all() })
    },
  })
}
