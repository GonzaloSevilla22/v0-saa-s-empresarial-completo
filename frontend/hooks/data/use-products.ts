"use client"

import { useCallback } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import { bulkRecategorizeInChunks, type BulkCategoryResult } from "@/lib/product-bulk-category"
import type { Product, ProductImportInput, ProductImportResult } from "@/lib/types"

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

// ── importador-productos-fastapi ────────────────────────────────────────────

interface ProductImportRowApi {
  row_no: number
  name: string
  category?: string | null
  price?: string | null
  cost?: string | null
  stock?: string | null
  min_stock?: number | null
  barcode?: string | null
  sku?: string | null
  sku_parent?: string | null
  parent_name?: string | null
  is_variant?: boolean | null
  stock_control_type?: string | null
  attributes: Array<{ key: string; value: string; sort_order: number }>
}

interface ProductImportPlanVerdictApi {
  plan: string
  limit: number | null
  before: number
  after: number
  added: number
  exceeded: boolean
}

interface ProductImportResultApi {
  committed: boolean
  import_id: string | null
  inserted: number
  updated: number
  errors: Array<{ row: number | null; sku?: string | null; name?: string | null; message: string }>
  new_categories: Array<{ name: string; rows: number }>
  // importador-gate-plan (OQ-1, sign-off PO 2026-09-11): presente en TODO
  // camino de la RPC vigente. Corrección de revisión (ronda 1 adversarial,
  // minor): sigue siendo opcional en el transporte — `backend/schemas/
  // products.py` lo declara `Optional[..., default=None]` a propósito,
  // para degradar sin romper el endpoint durante la ventana de deploy en
  // la que el backend ya se redesplegó pero la migración
  // `20261046000001` todavía no corrió (Render y `supabase db push`
  // avanzan por caminos independientes).
  plan: ProductImportPlanVerdictApi | null
  replayed: boolean
  dry_run: boolean
}

function mapProductImportResult(r: ProductImportResultApi): ProductImportResult {
  return {
    committed: r.committed,
    importId: r.import_id,
    inserted: r.inserted,
    updated: r.updated,
    errors: r.errors.map((e) => ({ row: e.row, sku: e.sku ?? null, name: e.name ?? null, message: e.message })),
    newCategories: r.new_categories,
    plan: r.plan
      ? {
          plan: r.plan.plan,
          limit: r.plan.limit,
          before: r.plan.before,
          after: r.plan.after,
          added: r.plan.added,
          exceeded: r.plan.exceeded,
        }
      : null,
    replayed: r.replayed,
    dryRun: r.dry_run,
  }
}

/**
 * Set de invalidaciones del importador: escribe productos, categorías
 * (D6/D7 pueden crear nuevas) y stock por sucursal (D1, branch_stock de la
 * sucursal por defecto) — los tres, UNA sola vez al confirmar (task 8.8),
 * nunca por fila.
 */
export function useInvalidateProductImport() {
  const queryClient = useQueryClient()
  return useCallback(() => {
    queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.productCategories.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.branchStock.all() })
  }, [queryClient])
}

/**
 * Lote transaccional de importación (D1 del design): UNA sola request a
 * `POST /products/import`, con `Idempotency-Key` por header. El `dryRun`
 * del input dispara el mismo camino en modo simulación (D7) — la vista
 * previa del paso 2 del diálogo usa la MISMA mutación, no un validador
 * aparte. Espejo exacto de `useImportExpenses`.
 */
export function useImportProducts() {
  const invalidateImportData = useInvalidateProductImport()
  const mutation = useMutation({
    mutationFn: async (input: ProductImportInput & { idempotencyKey: string }): Promise<ProductImportResult> => {
      const rows: ProductImportRowApi[] = input.rows.map((r) => ({
        row_no: r.rowNo,
        name: r.name,
        category: r.category ?? null,
        price: r.price != null ? String(r.price) : null,
        cost: r.cost != null ? String(r.cost) : null,
        stock: r.stock != null ? String(r.stock) : null,
        min_stock: r.minStock ?? null,
        barcode: r.barcode ?? null,
        sku: r.sku ?? null,
        sku_parent: r.skuParent ?? null,
        parent_name: r.parentName ?? null,
        is_variant: r.isVariant ?? null,
        stock_control_type: r.stockControlType ?? null,
        attributes: (r.attributes ?? []).map((a) => ({ key: a.key, value: a.value, sort_order: a.sortOrder })),
      }))
      const result = await pythonClient.post<ProductImportResultApi>(
        "/products/import",
        {
          file_name: input.fileName,
          file_hash: input.fileHash,
          dry_run: input.dryRun,
          rows,
        },
        { "Idempotency-Key": input.idempotencyKey }
      )
      return mapProductImportResult(result)
    },
    // Una sola invalidación por lote CONFIRMADO — el propio diálogo decide
    // cuándo llamar invalidateImportData() tras un resultado committed.
  })
  return { importMutation: mutation, invalidateImportData }
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
