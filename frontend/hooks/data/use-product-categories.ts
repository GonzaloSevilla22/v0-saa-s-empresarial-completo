"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { ProductCategory } from "@/lib/types"

// ── Types for API responses ───────────────────────────────────────────────────

interface ProductCategoryApiRow {
  id: string
  account_id: string
  name: string
  is_active: boolean
  sort_order: number
  created_at: string
}

export function mapProductCategory(r: ProductCategoryApiRow): ProductCategory {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    isActive:  r.is_active,
    sortOrder: r.sort_order,
    createdAt: r.created_at,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Catálogo de categorías de producto de la cuenta + mutaciones.
 * Espejo de usePaymentMethods (productos-categorias-sku, D7).
 *
 * @param includeInactive - true en la pantalla de gestión (y en el selector,
 *   que necesita mostrar como "(inactiva)" la categoría ya imputada a un
 *   producto que se edita). Default false.
 */
export function useProductCategories(includeInactive = false) {
  const queryClient = useQueryClient()

  const queryKey = includeInactive
    ? queryKeys.productCategories.lists()
    : queryKeys.productCategories.active()

  const query = useQuery({
    queryKey,
    queryFn: async (): Promise<ProductCategory[]> => {
      const url = includeInactive
        ? "/product-categories?include_inactive=true"
        : "/product-categories"
      const data = await pythonClient.get<ProductCategoryApiRow[]>(url)
      return data.map(mapProductCategory)
    },
    staleTime: 5 * 60 * 1000, // 5 min — el catálogo cambia poco
  })

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: queryKeys.productCategories.all() })

  const createProductCategoryMutation = useMutation({
    // Devuelve la categoría MAPEADA: el alta inline del selector necesita su id
    // para dejarla seleccionada (D9).
    mutationFn: async (payload: { name: string; sortOrder?: number | null }): Promise<ProductCategory> => {
      const row = await pythonClient.post<ProductCategoryApiRow>("/product-categories", {
        name: payload.name,
        sort_order: payload.sortOrder ?? null,
      })
      return mapProductCategory(row)
    },
    onSuccess: invalidate,
  })

  const updateProductCategoryMutation = useMutation({
    /**
     * Campo ausente = conservar (COALESCE del lado del backend). Sólo viajan
     * las claves informadas: renombrar no toca sort_order ni is_active.
     * `isActive: true` es la reactivación.
     */
    mutationFn: async (params: { id: string; name?: string; sortOrder?: number; isActive?: boolean }) => {
      const payload: Record<string, unknown> = {}
      if (params.name !== undefined) payload.name = params.name
      if (params.sortOrder !== undefined) payload.sort_order = params.sortOrder
      if (params.isActive !== undefined) payload.is_active = params.isActive
      const row = await pythonClient.patch<ProductCategoryApiRow>(`/product-categories/${params.id}`, payload)
      return mapProductCategory(row)
    },
    onSuccess: invalidate,
  })

  const deactivateProductCategoryMutation = useMutation({
    mutationFn: async (id: string) => {
      const row = await pythonClient.patch<ProductCategoryApiRow>(`/product-categories/${id}/deactivate`, {})
      return mapProductCategory(row)
    },
    onSuccess: invalidate,
  })

  const deleteProductCategoryMutation = useMutation({
    // Soft delete como maestro (deleted_at/deleted_by) — nunca borrado físico.
    mutationFn: async (id: string) => pythonClient.delete<void>(`/product-categories/${id}`),
    onSuccess: invalidate,
  })

  return {
    productCategories: query.data ?? [],
    isLoading:         query.isLoading,
    isError:           query.isError,
    error:             query.error,
    createProductCategory:     createProductCategoryMutation.mutateAsync,
    updateProductCategory:     updateProductCategoryMutation.mutateAsync,
    deactivateProductCategory: deactivateProductCategoryMutation.mutateAsync,
    deleteProductCategory:     deleteProductCategoryMutation.mutateAsync,
    createProductCategoryMutation,
    updateProductCategoryMutation,
    deactivateProductCategoryMutation,
    deleteProductCategoryMutation,
  }
}
