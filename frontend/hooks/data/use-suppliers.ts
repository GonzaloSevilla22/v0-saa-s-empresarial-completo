"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Supplier, IvaCondition } from "@/lib/types"

// compras-proveedor-cuenta-corriente (D10): calco exacto de use-clients.ts —
// mismo pythonClient, mismo patrón de mappers snake_case → camelCase, misma
// invalidación por queryKeys. GET /suppliers devuelve una lista plana (sin
// envelope), molde de GET /clients (backend/routers/suppliers.py).

// ── Types for API responses ───────────────────────────────────────────────────

interface SupplierApiRow {
  id: string
  account_id?: string
  name: string
  tax_id?: string | null
  iva_condition?: IvaCondition | null
  legal_name?: string | null
  email?: string | null
  phone?: string | null
  created_at: string
}

function mapSupplier(s: SupplierApiRow): Supplier {
  return {
    id:           s.id,
    name:         s.name,
    email:        s.email        || "",
    phone:        s.phone        || "",
    taxId:        s.tax_id       || undefined,
    ivaCondition: s.iva_condition || undefined,
    legalName:    s.legal_name   || undefined,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Returns suppliers list + mutations (add, update, delete) via Python API.
 */
export function useSuppliers() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.suppliers.lists(),
    queryFn: async (): Promise<Supplier[]> => {
      const data = await pythonClient.get<SupplierApiRow[]>("/suppliers")
      return data.map(mapSupplier)
    },
    staleTime: 2 * 60 * 1000, // 2 min
  })

  const addSupplierMutation = useMutation({
    mutationFn: async (supplier: Omit<Supplier, "id">) => {
      return pythonClient.post<SupplierApiRow>("/suppliers", {
        name:          supplier.name,
        email:         supplier.email        || null,
        phone:         supplier.phone        || null,
        tax_id:        supplier.taxId        || null,
        iva_condition: supplier.ivaCondition || null,
        legal_name:    supplier.legalName    || null,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.suppliers.all() })
    },
  })

  const updateSupplierMutation = useMutation({
    mutationFn: async (supplier: Supplier) => {
      return pythonClient.put<SupplierApiRow>(`/suppliers/${supplier.id}`, {
        name:          supplier.name,
        email:         supplier.email        || null,
        phone:         supplier.phone        || null,
        tax_id:        supplier.taxId        || null,
        iva_condition: supplier.ivaCondition || null,
        legal_name:    supplier.legalName    || null,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.suppliers.all() })
    },
  })

  const deleteSupplierMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/suppliers/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.suppliers.all() })
    },
  })

  return {
    suppliers:      query.data ?? [],
    isLoading:      query.isLoading,
    isError:        query.isError,
    error:          query.error,
    addSupplier:    addSupplierMutation.mutateAsync,
    updateSupplier: updateSupplierMutation.mutateAsync,
    deleteSupplier: deleteSupplierMutation.mutateAsync,
    addSupplierMutation,
    updateSupplierMutation,
    deleteSupplierMutation,
  }
}
