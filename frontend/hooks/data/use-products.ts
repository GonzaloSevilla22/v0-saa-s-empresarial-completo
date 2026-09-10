"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import { bulkRecategorizeInChunks, type BulkCategoryResult } from "@/lib/product-bulk-category"
import type { Product } from "@/lib/types"

// ── Types for API responses ───────────────────────────────────────────────────

interface ProductApiRow {
  id: string
  account_id: string
  user_id?: string
  name: string
  category: string | null
  // productos-categorias-sku (D1): fuente de verdad; ausente en una base sin
  // la migración → null.
  category_id?: string | null
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
  // productos-costo-nullable: el costo del catálogo es OPCIONAL — `null`/
  // `undefined` significan "no se cargó", nunca se imputan a 0 (eso produce
  // un margen del 100% indistinguible de uno medido). `0` es un costo cero
  // DECLARADO y se preserva tal cual.
  const cost = p.cost == null ? null : Number(p.cost)
  return {
    id:               p.id,
    name:             p.name,
    category:         p.category || "Otros",
    categoryId:       p.category_id ?? null,
    cost,
    price,
    margin:           cost == null ? null : (price > 0 ? Math.round(((price - cost) / price) * 100) : 0),
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
 * Returns products list + mutations (add, update, delete, bulkSetCategory) via Python API.
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
    // productos-costo-nullable: `cost` admite `undefined` además de
    // `number | null` — para un ALTA, omitir la clave y mandar `null`
    // producen el mismo resultado (sin costo cargado), así que el caller no
    // necesita distinguirlos.
    mutationFn: async (product: Omit<Product, "id" | "cost"> & { cost?: number | null }) => {
      return pythonClient.post<ProductApiRow>("/products", {
        name:               product.name,
        // productos-categoria-text-retiro: `category` (nombre libre) ya no se
        // envía — category_id es la única fuente de verdad (D1); el nombre
        // legible lo deriva el servidor. La clave viaja SÓLO si el formulario
        // la resolvió — una variante no la manda: el servidor hereda del padre (D11).
        ...(product.categoryId !== undefined ? { category_id: product.categoryId } : {}),
        price:              product.price,
        cost:               product.cost ?? null,
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
    // productos-costo-nullable (D12): `cost` es tri-estado igual que
    // `categoryId` — el caller (ProductForm) puede omitir la clave del todo
    // (`undefined`) para CONSERVAR el costo existente, distinto de mandarla
    // en `null` para DESASIGNARLO. `Product.cost` (lectura) es siempre
    // `number | null` definido; este payload de escritura relaja sólo ESE
    // campo a también admitir `undefined`.
    mutationFn: async (product: Omit<Product, "cost"> & { cost?: number | null }) => {
      return pythonClient.put<ProductApiRow>(`/products/${product.id}`, {
        name:               product.name,
        // productos-categoria-text-retiro: `category` ya no se envía (idem alta).
        // productos-categorias-sku (D12): tri-estado por AUSENCIA de la clave
        // (mismo contrato que bankAccountId en use-payment-methods): omitida
        // conserva; uuid asigna; null desasigna. `sku: null` más abajo BORRA
        // el SKU — el formulario manda siempre el estado vigente del campo.
        ...(product.categoryId !== undefined ? { category_id: product.categoryId } : {}),
        price:              product.price,
        ...(product.cost !== undefined ? { cost: product.cost } : {}),
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

  // productos-categorias-sku (D14): recategorización en lote, troceada en
  // requests de hasta 500 ids (lib/product-bulk-category) y agregada.
  const bulkSetCategoryMutation = useMutation({
    mutationFn: async (params: { productIds: string[]; categoryId: string }): Promise<BulkCategoryResult> =>
      bulkRecategorizeInChunks(params.productIds, params.categoryId, (chunk, categoryId) =>
        pythonClient.patch<BulkCategoryResult>("/products/bulk-category", {
          product_ids: chunk,
          category_id: categoryId,
        }),
      ),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
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
    bulkSetCategory: bulkSetCategoryMutation.mutateAsync,
    addProductMutation,
    updateProductMutation,
    deleteProductMutation,
    bulkSetCategoryMutation,
  }
}
