"use client"

import { useCallback } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import { bulkRecategorizeInChunks, runInChunks, type BulkCategoryResult, type ChunkRunFailure } from "@/lib/product-bulk-category"
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
  // ventas-unidades-conversion: `branch_stock.min_stock` es numeric(15,4) y
  // FastAPI serializa el Decimal como STRING ("0.5000"), igual que stock /
  // price / cost. Sin el Number() del mapeo, "5.0000".toFixed() tiraba /stock.
  min_stock: string | number | null
  barcode: string | null
  sku: string | null
  is_variant: boolean | null
  stock_control_type: string | null
  created_at: string
  parent_id?: string | null
  // ventas-unidades-conversion (D10): unidad en que se lleva el stock; ausente
  // en una base sin la migración → undefined.
  base_unit_id?: string | null
  // balanza-etiquetas-pos (D2): código de PLU de la balanza; ausente en una
  // base sin la migración → undefined (se degrada a `null`, igual que
  // `base_unit_id`).
  scale_plu?: number | null
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
    minStock:         p.min_stock == null ? 0 : Number(p.min_stock),
    barcode:          p.barcode   ?? undefined,
    sku:              p.sku       ?? undefined,
    parentId:         p.parent_id ?? undefined,
    isVariant:        p.is_variant ?? false,
    stockControlType: (p.stock_control_type ?? "tracked") as Product["stockControlType"],
    // ventas-unidades-conversion (D10): hasta este change el hook no mapeaba
    // la unidad base, así que el catálogo mostraba "uds" para todo y el
    // selector de unidad de los formularios nunca conocía la del producto.
    baseUnitId:       p.base_unit_id ?? undefined,
    // balanza-etiquetas-pos (D2): `null` = sin código de balanza asignado.
    scalePlu:         p.scale_plu ?? null,
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
  scale_plu?: number | null
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
        scale_plu: r.scalePlu ?? null,
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
 * Campos del payload de escritura que relajan a `Product` (lectura) a
 * tri-estado: en la lectura son valores resueltos; en la escritura
 * `undefined` = "no lo toqué, conservá" y `null` = "desasignalo"
 * (productos-costo-nullable D12 / ventas-unidades-conversion decisión 7).
 */
type ProductTriStateWrite = { cost?: number | null; baseUnitId?: string | null; scalePlu?: number | null }

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
    // ventas-unidades-conversion (decisión 7): `baseUnitId` también admite
    // `null` en la escritura — "Sin unidad" en el formulario. En el alta
    // `null` y la ausencia producen lo mismo (`base_unit_id: null`).
    mutationFn: async (product: Omit<Product, "id" | "cost" | "baseUnitId" | "scalePlu"> & ProductTriStateWrite) => {
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
        // ventas-unidades-conversion (D10): el formulario ya la mandaba y se
        // perdía acá. null = sin unidad base.
        base_unit_id:       product.baseUnitId ?? null,
        // balanza-etiquetas-pos (D2): en el alta, omitir la clave y mandar
        // `null` producen lo mismo (sin código de balanza asignado).
        scale_plu:          product.scalePlu ?? null,
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
    // ventas-unidades-conversion (decisión 7): `baseUnitId` es tri-estado
    // igual que `cost` — `undefined` conserva, uuid asigna, `null` desasigna
    // (opción "Sin unidad" del formulario; sujeta al guard D11/D-C del
    // backend: 409 base_unit_locked con stock o historia).
    //
    // stock-ledger-solo-rpc (D9, task 12.6): la EDICIÓN no manda `stock` —el tipo de
    // este payload ni siquiera lo admite—. El stock se cambia sólo con el ajuste
    // manual (rol owner/admin/stock + motivo); el backend responde 422
    // `stock_adjust_required` ante un `stock` distinto del saldo, y antes un
    // formulario abierto con el stock viejo re-sumaba en silencio lo vendido.
    mutationFn: async (product: Omit<Product, "cost" | "baseUnitId" | "scalePlu" | "stock"> & ProductTriStateWrite) => {
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
        min_stock:          product.minStock,
        barcode:            product.barcode     ?? null,
        sku:                product.sku         ?? null,
        stock_control_type: product.stockControlType ?? "tracked",
        // ventas-unidades-conversion (D10): el formulario manda siempre el
        // estado vigente del campo — null desasigna (misma semántica que sku).
        // ventas-unidades-conversion (auditoría post-apply): tri-estado por
        // ausencia de punta a punta — el campo se OMITE cuando el formulario no
        // lo determina (variante, padre variant_only, producto no rastreado) y
        // el backend conserva el valor; un uuid asigna. Antes `undefined` se
        // mandaba como `null` y desasignaba la unidad base al editar el nombre.
        ...(product.baseUnitId !== undefined ? { base_unit_id: product.baseUnitId } : {}),
        // balanza-etiquetas-pos (D2): tri-estado por ausencia — omitida
        // conserva el PLU vigente; un número lo asigna; `null` lo desasigna.
        ...(product.scalePlu !== undefined ? { scale_plu: product.scalePlu } : {}),
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

// ── productos-padre-variantes ─────────────────────────────────────────────────

/** Respuesta de `POST /products/{id}/relabel-unit` (igual en dry-run), en camelCase. */
export interface ProductUnitRelabelResult {
  changed: boolean
  rootId: string
  unitBefore: string | null
  unitAfter: string
  /** Variantes vivas de la familia. */
  variants: number
  /** Variantes que tenían unidad propia (pasan a heredar la de la raíz). */
  variantsWithOwnUnit: number
  /** Productos de la familia con stock distinto de 0. */
  productsWithStock: number
  /** Movimientos de stock de la familia. */
  movements: number
  /** Unidad de una línea que impide el relabel (sólo en dry-run); `null` si no hay conflicto. */
  conflictUnit: string | null
}

interface ProductUnitRelabelApiRow {
  changed: boolean
  root_id: string
  unit_before: string | null
  unit_after: string
  variants: number
  variants_with_own_unit: number
  products_with_stock: number
  movements: number
  conflict_unit: string | null
}

/**
 * Corregir la unidad de una familia (D5/D7). `dryRun: true` es la vista previa
 * (no escribe: no refresca nada); al aplicar se invalida el listado. Un
 * conflicto en dry-run llega en `conflictUnit`; al aplicar, el servidor
 * responde 409 `unit_relabel_conflict` y el error se propaga.
 */
export function useRelabelProductUnit() {
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: async (params: { productId: string; baseUnitId: string; dryRun: boolean }): Promise<ProductUnitRelabelResult> => {
      const r = await pythonClient.post<ProductUnitRelabelApiRow>(`/products/${params.productId}/relabel-unit`, {
        base_unit_id: params.baseUnitId,
        dry_run: params.dryRun,
      })
      return {
        changed: r.changed,
        rootId: r.root_id,
        unitBefore: r.unit_before ?? null,
        unitAfter: r.unit_after,
        variants: r.variants,
        variantsWithOwnUnit: r.variants_with_own_unit,
        productsWithStock: r.products_with_stock,
        movements: r.movements,
        conflictUnit: r.conflict_unit ?? null,
      }
    },
    onSuccess: (_result, params) => {
      if (!params.dryRun) queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })
  return { relabel: mutation.mutateAsync, mutation }
}

export type BulkPriceMode = "percent" | "amount"
export type BulkPriceDirection = "increase" | "decrease"

export interface ProductBulkPriceSample {
  id: string
  name: string
  priceBefore: number
  priceAfter: number
}

/** Contadores de `PATCH /products/bulk-price`, sumados sobre todos los bloques. */
export interface ProductBulkPriceResult {
  requested: number
  eligible: number
  changed: number
  unchanged: number
  skippedParents: number
  clamped: number
  /** Hasta 10 filas del PRIMER bloque. */
  sample: ProductBulkPriceSample[]
}

export interface ProductBulkPriceOutcome {
  /** Suma de los bloques que se aplicaron (o se previsualizaron). */
  result: ProductBulkPriceResult
  /** El bloque que cortó el lote (sólo al aplicar), o `null`. */
  failure: ChunkRunFailure | null
  appliedIds: number
  totalIds: number
}

interface ProductBulkPriceApiRow {
  requested: number
  eligible: number
  changed: number
  unchanged: number
  skipped_parents: number
  clamped: number
  sample: { id: string; name: string; price_before: string | number; price_after: string | number }[]
}

const EMPTY_BULK_PRICE_RESULT: ProductBulkPriceResult = {
  requested: 0, eligible: 0, changed: 0, unchanged: 0, skippedParents: 0, clamped: 0, sample: [],
}

/**
 * Modificar precios en lote (D8/D10). Trocea en requests de 500; cada bloque es
 * atómico en el servidor y el lote completo no. La vista previa (`dryRun`) suma
 * los bloques y falla entera si uno falla; al aplicar, un bloque que falla
 * CORTA el lote y el resultado informa el avance parcial en vez de lanzar. El
 * listado se refresca siempre que se haya intentado aplicar (puede haber
 * escritura parcial).
 */
export function useBulkAdjustPrices() {
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: async (params: {
      productIds: string[]
      mode: BulkPriceMode
      direction: BulkPriceDirection
      value: number
      dryRun: boolean
    }): Promise<ProductBulkPriceOutcome> => {
      const outcome = await runInChunks(params.productIds, (chunk) =>
        pythonClient.patch<ProductBulkPriceApiRow>("/products/bulk-price", {
          product_ids: chunk,
          mode: params.mode,
          direction: params.direction,
          value: params.value,
          dry_run: params.dryRun,
        }),
      )
      if (outcome.failure && params.dryRun) throw outcome.failure.error
      const result = outcome.results.reduce<ProductBulkPriceResult>((total, r, i) => ({
        requested: total.requested + r.requested,
        eligible: total.eligible + r.eligible,
        changed: total.changed + r.changed,
        unchanged: total.unchanged + r.unchanged,
        skippedParents: total.skippedParents + r.skipped_parents,
        clamped: total.clamped + r.clamped,
        sample: i === 0
          ? r.sample.map((s) => ({ id: s.id, name: s.name, priceBefore: Number(s.price_before), priceAfter: Number(s.price_after) }))
          : total.sample,
      }), EMPTY_BULK_PRICE_RESULT)
      return { result, failure: outcome.failure, appliedIds: outcome.appliedIds, totalIds: outcome.totalIds }
    },
    onSettled: (_data, _error, params) => {
      if (!params.dryRun) queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })
  return { adjust: mutation.mutateAsync, mutation }
}
