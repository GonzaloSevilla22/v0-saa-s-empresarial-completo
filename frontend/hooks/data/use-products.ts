"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Product } from "@/lib/types"

// ── Types for API responses ───────────────────────────────────────────────────

interface ProductApiRow {
  id: string
  account_id: string
  user_id?: string
  name: string
  category: string | null
  price: string | number | null
  cost: string | number | null
  stock: string | number
  min_stock: number | null
  barcode: string | null
  sku: string | null
  is_variant: boolean | null
  stock_control_type: string | null
  created_at: string
  parent_id?: string | null
}

function mapProduct(p: ProductApiRow): Product {
  const price = Number(p.price ?? 0)
  const cost  = Number(p.cost  ?? 0)
  return {
    id:               p.id,
    name:             p.name,
    category:         p.category || "Otros",
    cost,
    price,
    margin:           price > 0 ? Math.round(((price - cost) / price) * 100) : 0,
    stock:            Number(p.stock),
    minStock:         p.min_stock ?? 0,
    barcode:          p.barcode   ?? undefined,
    sku:              p.sku       ?? undefined,
    parentId:         p.parent_id ?? undefined,
    isVariant:        p.is_variant ?? false,
    stockControlType: (p.stock_control_type ?? "tracked") as Product["stockControlType"],
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Returns products list + mutations (add, update, delete) via Python API.
 */
export function useProducts() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.products.lists(),
    queryFn: async (): Promise<Product[]> => {
      const data = await pythonClient.get<ProductApiRow[]>("/products")
      return data.map(mapProduct)
    },
    staleTime: 60 * 1000, // 1 min
  })

  const addProductMutation = useMutation({
    mutationFn: async (product: Omit<Product, "id">) => {
      return pythonClient.post<ProductApiRow>("/products", {
        name:               product.name,
        category:           product.category   || null,
        price:              product.price,
        cost:               product.cost,
        stock:              product.stock,
        min_stock:          product.minStock,
        barcode:            product.barcode     ?? null,
        sku:                product.sku         ?? null,
        parent_id:          product.parentId    ?? null,
        is_variant:         product.isVariant,
        stock_control_type: product.stockControlType ?? "tracked",
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  const updateProductMutation = useMutation({
    mutationFn: async (product: Product) => {
      return pythonClient.put<ProductApiRow>(`/products/${product.id}`, {
        name:               product.name,
        category:           product.category   || null,
        price:              product.price,
        cost:               product.cost,
        stock:              product.stock,
        min_stock:          product.minStock,
        barcode:            product.barcode     ?? null,
        sku:                product.sku         ?? null,
        stock_control_type: product.stockControlType ?? "tracked",
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  const deleteProductMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/products/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
      // Also invalidate sales/purchases as product references change
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
    },
  })

  return {
    products:      query.data ?? [],
    isLoading:     query.isLoading,
    isError:       query.isError,
    error:         query.error,
    addProduct:    addProductMutation.mutateAsync,
    updateProduct: updateProductMutation.mutateAsync,
    deleteProduct: deleteProductMutation.mutateAsync,
    addProductMutation,
    updateProductMutation,
    deleteProductMutation,
  }
}
