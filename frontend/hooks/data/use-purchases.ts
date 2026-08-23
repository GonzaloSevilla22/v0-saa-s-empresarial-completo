"use client"

import { useState, useCallback, useMemo } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Purchase } from "@/lib/types"
import type { PurchaseCartItem } from "@/lib/cart-utils"
import {
  buildPaginationMeta,
  type PaginationMeta,
  type PageSizeOption,
} from "@/lib/pagination-utils"

// ── Types for API responses ───────────────────────────────────────────────────

interface PurchaseApiRow {
  id: string
  date: string
  product_id: string
  product_name?: string | null
  product?: { name: string } | null
  quantity: number
  amount: string | number
  total: string | number | null
  operation_id?: string | null
  description?: string | null
  // cost-center-surface: resueltos en el mismo query del backend (LEFT JOIN)
  cost_center_id?: string | null
  cost_center_name?: string | null
  // metodos-pago-operaciones: resueltos en el mismo query del backend (LEFT JOIN)
  payment_method_id?: string | null
  payment_method_name?: string | null
  payment_method_kind?: string | null
  // edicion-preserva-contexto: expuestos para prefillear el form de edición.
  branch_id?: string | null
  unit_id?: string | null
  // pagos-cableados-restantes (D6): derivado de lectura — true si tiene
  // cargo de cuenta corriente posteado.
  is_payment_locked?: boolean
  // delete-guard-ledgers (task 9.2): mismos EXISTS de is_payment_locked,
  // expuestos por separado (sin pata de caja — las compras no la tienen).
  has_account_charge?: boolean
  has_bank_movement?: boolean
  // compras-proveedor-cuenta-corriente (task 9.2/10.4): supplier_id + nombre
  // resueltos en el mismo query del backend (LEFT JOIN suppliers).
  supplier_id?: string | null
  supplier_name?: string | null
}

interface PurchasesPageResponse {
  items: PurchaseApiRow[]
  // v3-api-standards §2/§6.1: envelope estándar {items,total,page,pages}
  // (reemplaza total_operations).
  total: number
  page?: number
  pages?: number
}

interface PurchaseOperationResult {
  operation_id: string
  operation_kind?: string | null
}

function mapPurchase(p: PurchaseApiRow): Purchase {
  return {
    id:          p.id,
    date:        p.date.split("T")[0],
    productId:   p.product_id,
    productName: p.product_name || p.product?.name || "Eliminado",
    quantity:    Number(p.quantity),
    unitCost:    Number(p.amount),
    total:       Number(p.total ?? p.amount),
    description: p.description ?? undefined,
    operationId: p.operation_id ?? undefined,
    costCenterId:   p.cost_center_id ?? null,
    costCenterName: p.cost_center_name ?? null,
    paymentMethodId:   p.payment_method_id ?? null,
    paymentMethodName: p.payment_method_name ?? null,
    paymentMethodKind: (p.payment_method_kind ?? null) as Purchase["paymentMethodKind"],
    // edicion-preserva-contexto (D11): sin esto el form de edición no tiene
    // con qué prefillear sucursal/unidad.
    branchId: p.branch_id ?? null,
    unitId:   p.unit_id ?? undefined,
    isPaymentLocked: p.is_payment_locked ?? false,
    hasAccountCharge: p.has_account_charge ?? false,
    hasBankMovement:  p.has_bank_movement  ?? false,
    supplierId:   p.supplier_id   ?? null,
    supplierName: p.supplier_name ?? null,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

export function usePurchases() {
  const queryClient = useQueryClient()

  // ── Pagination & filter state ─────────────────────────────────────────────
  const [page,     setPageState]     = useState(0)
  const [pageSize, setPageSizeState] = useState<PageSizeOption>(25)
  const [dateFrom, setDateFromState] = useState("")
  const [dateTo,   setDateToState]   = useState("")
  // cost-center-surface: filtro por centro de costo de la OPERACIÓN.
  const [costCenterId, setCostCenterIdState] = useState<string | null>(null)
  // metodos-pago-operaciones: filtro por forma de pago de la OPERACIÓN.
  const [paymentMethodId, setPaymentMethodIdState] = useState<string | null>(null)

  const setPage = useCallback((p: number) => setPageState(p), [])
  const setPageSize = useCallback((s: PageSizeOption) => {
    setPageSizeState(s)
    setPageState(0)
  }, [])
  const setDateFrom = useCallback((v: string) => { setDateFromState(v); setPageState(0) }, [])
  const setDateTo   = useCallback((v: string) => { setDateToState(v);   setPageState(0) }, [])
  const setCostCenterId = useCallback((v: string | null) => {
    setCostCenterIdState(v)
    setPageState(0)
  }, [])
  const setPaymentMethodId = useCallback((v: string | null) => {
    setPaymentMethodIdState(v)
    setPageState(0)
  }, [])
  const clearFilters = useCallback(() => {
    setDateFromState("")
    setDateToState("")
    setCostCenterIdState(null)
    setPaymentMethodIdState(null)
    setPageState(0)
  }, [])

  // ── List query ────────────────────────────────────────────────────────────
  const queryParams = useMemo(() => {
    const p: Record<string, string> = {
      page:      String(page),
      page_size: String(pageSize),
    }
    if (dateFrom) p.date_from = dateFrom
    if (dateTo)   p.date_to   = dateTo
    if (costCenterId) p.cost_center_id = costCenterId
    if (paymentMethodId) p.payment_method_id = paymentMethodId
    return p
  }, [page, pageSize, dateFrom, dateTo, costCenterId, paymentMethodId])

  const query = useQuery({
    queryKey: [...queryKeys.purchases.lists(), queryParams],
    queryFn: async (): Promise<PurchasesPageResponse> => {
      const qs = new URLSearchParams(queryParams).toString()
      return pythonClient.get<PurchasesPageResponse>(`/purchases?${qs}`)
    },
    staleTime: 30 * 1000,
  })

  const purchases = useMemo(
    () => (query.data?.items ?? []).map(mapPurchase),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total ?? 0),
    [page, pageSize, query.data?.total],
  )

  // ── Mutations ─────────────────────────────────────────────────────────────
  const addPurchaseOperationMutation = useMutation({
    mutationFn: async ({
      items,
      meta: opMeta,
    }: {
      items: PurchaseCartItem[]
      meta: {
        idempotencyKey: string
        date: string
        description: string
        branchId?: string | null
        orgId: string
        /** cost-center-dimension: optional analytic dimension for the whole operation */
        costCenterId?: string | null
        /** metodos-pago-operaciones: optional, shared by all lines of the operation */
        paymentMethodId?: string | null
        /**
         * pos-banco-movimientos (D2): override explícito de la cuenta
         * bancaria destino del egreso. null/ausente = default del método.
         */
        bankAccountId?: string | null
        /**
         * compras-proveedor-cuenta-corriente (D4): atributo DE LA OPERACIÓN
         * (no de línea), igual que costCenterId/paymentMethodId — se manda
         * SIEMPRE (null cuando no hay proveedor elegido), a diferencia del
         * tri-estado de la edición.
         */
        supplierId?: string | null
      }
    }): Promise<PurchaseOperationResult> => {
      const payload = {
        org_id:           opMeta.orgId,
        date:             opMeta.date,
        // cost-center-dimension: shared by all lines of the operation
        cost_center_id:   opMeta.costCenterId ?? null,
        // metodos-pago-operaciones: shared by all lines of the operation
        payment_method_id: opMeta.paymentMethodId ?? null,
        bank_account_id:  opMeta.bankAccountId ?? null,
        // compras-proveedor-cuenta-corriente (D4): shared by all lines of the operation
        supplier_id:      opMeta.supplierId ?? null,
        items: items.map(item => ({
          product_id:  item.productId,
          amount:      item.unitCost,
          quantity:    item.quantity,
          description: opMeta.description || null,
          unit_id:     item.unitId ?? null,
        })),
      }
      // v3-api-standards §3/§6.2: la clave de idempotencia viaja por el header
      // Idempotency-Key (D4) — el body ya no la incluye.
      return pythonClient.post<PurchaseOperationResult>("/purchases", payload, {
        "Idempotency-Key": opMeta.idempotencyKey,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  const updatePurchaseMutation = useMutation({
    mutationFn: async (purchase: Purchase) => {
      return pythonClient.put<PurchaseApiRow>(`/purchases/${purchase.id}`, {
        amount:   purchase.unitCost,
        total:    purchase.unitCost * purchase.quantity,
        quantity: purchase.quantity,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
    },
  })

  const deletePurchaseMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/purchases/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
    },
  })

  const deletePurchasesByOperationMutation = useMutation({
    mutationFn: async (operationId: string) => {
      return pythonClient.delete<void>(`/purchases?operation_id=${operationId}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
    },
  })

  const updatePurchaseOperationMutation = useMutation({
    mutationFn: async ({
      purchaseIds,
      newItems,
      meta: opMeta,
    }: {
      purchaseIds: string[]
      newItems: PurchaseCartItem[]
      meta: {
        date: string
        description: string
        orgId: string
        /**
         * metodos-pago-operaciones (D5): tri-estado por AUSENCIA de la clave,
         * no por valor. Omitir `paymentMethodId` del objeto meta preserva el
         * vigente (el backend traduce ausencia → JSON sin la clave →
         * p_payment_method_provided=false). Pasar `null` explícito desimputa
         * ("Sin especificar"); pasar un uuid reimputa.
         */
        paymentMethodId?: string | null
        /**
         * edicion-preserva-contexto (F1 §D3): branchId usa el mismo contrato
         * tri-estado por ausencia — ver el comentario espejo en use-sales.ts.
         */
        branchId?: string | null
        /**
         * compras-proveedor-cuenta-corriente (D7): supplierId usa el MISMO
         * contrato tri-estado por AUSENCIA de la clave — ausente preserva el
         * vigente, `null` desimputa, un uuid reimputa. Nunca por `is None`
         * en el backend (model_fields_set).
         */
        supplierId?: string | null
        /**
         * review B (FE-1/OQ-5 A): costCenterId usa el MISMO contrato
         * tri-estado por AUSENCIA que supplierId/branchId/paymentMethodId —
         * DB (rpc_atomic_update_purchase_operation, 12 args) y backend
         * (routers/purchases.py, "cost_center_id" in model_fields_set) ya lo
         * aceptaban desde OQ-5 opción A; le faltaba el passthrough acá.
         */
        costCenterId?: string | null
      }
    }) => {
      const items = newItems.map(item => ({
        product_id: item.productId,
        amount:     item.unitCost,
        quantity:   item.quantity,
        // edicion-preserva-contexto (F1 §D7): unit_id viaja pegado a la línea.
        unit_id:    item.unitId ?? null,
      }))
      const payload: Record<string, unknown> = {
        purchase_ids: purchaseIds,
        date:         opMeta.date,
        description:  opMeta.description || null,
        items,
      }
      // metodos-pago-operaciones (D5): la clave solo se incluye en el body si
      // el caller la mandó explícitamente en meta — JSON.stringify omite las
      // claves con valor `undefined`, así que "ausente" viaja literalmente
      // ausente y el backend (model_fields_set) lo distingue de `null`.
      if ("paymentMethodId" in opMeta) {
        payload.payment_method_id = opMeta.paymentMethodId ?? null
      }
      // edicion-preserva-contexto: mismo patrón de inclusión condicional.
      if ("branchId" in opMeta) {
        payload.branch_id = opMeta.branchId ?? null
      }
      // compras-proveedor-cuenta-corriente (D7): mismo patrón — ausente del
      // objeto meta = ausente del body = preservar el vigente.
      if ("supplierId" in opMeta) {
        payload.supplier_id = opMeta.supplierId ?? null
      }
      // review B (FE-1/OQ-5 A): mismo patrón de inclusión condicional.
      if ("costCenterId" in opMeta) {
        payload.cost_center_id = opMeta.costCenterId ?? null
      }
      return pythonClient.put<void>("/purchases/operation", payload)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  return {
    purchases,
    meta,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error ? (query.error as Error).message : null,
    dateFrom,
    setDateFrom,
    dateTo,
    setDateTo,
    costCenterId,
    setCostCenterId,
    paymentMethodId,
    setPaymentMethodId,
    clearFilters,
    setPage,
    setPageSize,
    refetch: query.refetch,
    addPurchaseOperation:       addPurchaseOperationMutation.mutateAsync,
    updatePurchase:             updatePurchaseMutation.mutateAsync,
    deletePurchase:             deletePurchaseMutation.mutateAsync,
    deletePurchasesByOperation: deletePurchasesByOperationMutation.mutateAsync,
    updatePurchaseOperation:    updatePurchaseOperationMutation.mutateAsync,
    addPurchaseOperationMutation,
    updatePurchaseMutation,
    deletePurchaseMutation,
    deletePurchasesByOperationMutation,
    updatePurchaseOperationMutation,
  }
}
