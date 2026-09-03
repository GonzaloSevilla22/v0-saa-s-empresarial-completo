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
  payment_terms_days?: number | null
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
    // cobranzas-vencimientos: null = "usa el plazo de la cuenta" — se
    // preserva, nunca degrada a 0 ni a undefined (D14).
    paymentTermsDays: s.payment_terms_days ?? null,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * qa-integral-modulos (G9/H14): detalle de un proveedor por id — espejo de
 * useClient (use-clients.ts), nace acá (capa canónica) para que la cabecera
 * de /proveedores/[id]/cuenta pueda nombrar al proveedor.
 * GET /suppliers/{id} ya existe en backend/routers/suppliers.py.
 */
export function useSupplier(supplierId: string | null) {
  return useQuery({
    queryKey: [...queryKeys.suppliers.all(), "detail", supplierId ?? ""],
    queryFn: async (): Promise<Supplier> => {
      const data = await pythonClient.get<SupplierApiRow>(`/suppliers/${supplierId}`)
      return mapSupplier(data)
    },
    enabled: !!supplierId,
    staleTime: 60 * 1000,
  })
}

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
        ...(supplier.paymentTermsDays !== undefined
          ? { payment_terms_days: supplier.paymentTermsDays }
          : {}),
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
        ...(supplier.paymentTermsDays !== undefined
          ? { payment_terms_days: supplier.paymentTermsDays }
          : {}),
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
