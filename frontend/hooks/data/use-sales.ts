"use client"

import { useState, useCallback, useMemo } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Sale } from "@/lib/types"
import type { SaleCartItem } from "@/lib/cart-utils"
import {
  buildPaginationMeta,
  type PaginationMeta,
  type PageSizeOption,
} from "@/lib/pagination-utils"

// ── Types for API responses ───────────────────────────────────────────────────

interface SaleApiRow {
  id: string
  date: string
  product_id: string
  product_name?: string | null
  product?: { name: string } | null
  client_id: string | null
  client_name?: string | null
  client?: { name: string } | null
  quantity: number
  amount: string | number
  total: string | number | null
  currency: string
  operation_id?: string | null
  // metodos-pago-operaciones: resueltos en el mismo query del backend (LEFT
  // JOIN payment_methods + derivación de lectura del POS por sales_orders — D7)
  payment_method_id?: string | null
  payment_method_name?: string | null
  payment_method_kind?: string | null
  // edicion-preserva-contexto: expuestos para prefillear el form de edición.
  branch_id?: string | null
  canal?: string | null
  unit_id?: string | null
  // edicion-preserva-contexto (F2): derivado de lectura — true si tiene
  // comprobante fiscal pending_cae/authorized.
  is_invoiced?: boolean
  // pagos-cableados-restantes (D6): derivado de lectura — true si tiene
  // cargo de cuenta corriente o movimiento de caja posteado.
  is_payment_locked?: boolean
  // delete-guard-ledgers (task 9.2): mismos tres EXISTS de is_payment_locked,
  // expuestos por separado para que el diálogo de borrado enumere
  // específicamente qué libro compensaría.
  has_account_charge?: boolean
  has_cash_movement?: boolean
  has_bank_movement?: boolean
}

interface SalesPageResponse {
  items: SaleApiRow[]
  // v3-api-standards §2/§6.1: envelope estándar {items,total,page,pages}
  // (reemplaza total_operations).
  total: number
  page?: number
  pages?: number
}

interface SaleOperationResult {
  operation_id: string
  operation_kind?: string | null
}

function mapSale(s: SaleApiRow): Sale {
  return {
    id:          s.id,
    date:        s.date.split("T")[0],
    productId:   s.product_id,
    productName: s.product_name || s.product?.name || "Eliminado",
    clientId:    s.client_id    || "",
    clientName:  s.client_name  || s.client?.name || "Consumidor Final",
    quantity:    Number(s.quantity),
    unitPrice:   Number(s.amount),
    total:       Number(s.total ?? s.amount),
    currency:    s.currency as Sale["currency"],
    operationId: s.operation_id ?? undefined,
    paymentMethodId:   s.payment_method_id ?? null,
    paymentMethodName: s.payment_method_name ?? null,
    paymentMethodKind: (s.payment_method_kind ?? null) as Sale["paymentMethodKind"],
    // edicion-preserva-contexto (D11): sin esto el form de edición no tiene
    // con qué prefillear sucursal/canal/unidad.
    branchId: s.branch_id ?? null,
    canal:    s.canal ?? null,
    unitId:   s.unit_id ?? undefined,
    isInvoiced: s.is_invoiced ?? false,
    isPaymentLocked: s.is_payment_locked ?? false,
    hasAccountCharge: s.has_account_charge ?? false,
    hasCashMovement:  s.has_cash_movement  ?? false,
    hasBankMovement:  s.has_bank_movement  ?? false,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

export function useSales() {
  const queryClient = useQueryClient()

  // ── Pagination & filter state ─────────────────────────────────────────────
  const [page,     setPageState]     = useState(0)
  const [pageSize, setPageSizeState] = useState<PageSizeOption>(25)
  const [dateFrom, setDateFromState] = useState("")
  const [dateTo,   setDateToState]   = useState("")
  // metodos-pago-operaciones: filtro por forma de pago de la OPERACIÓN.
  const [paymentMethodId, setPaymentMethodIdState] = useState<string | null>(null)

  const setPage = useCallback((p: number) => setPageState(p), [])
  const setPageSize = useCallback((s: PageSizeOption) => {
    setPageSizeState(s)
    setPageState(0)
  }, [])
  const setDateFrom = useCallback((v: string) => { setDateFromState(v); setPageState(0) }, [])
  const setDateTo   = useCallback((v: string) => { setDateToState(v);   setPageState(0) }, [])
  const setPaymentMethodId = useCallback((v: string | null) => {
    setPaymentMethodIdState(v)
    setPageState(0)
  }, [])
  const clearFilters = useCallback(() => {
    setDateFromState("")
    setDateToState("")
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
    if (paymentMethodId) p.payment_method_id = paymentMethodId
    return p
  }, [page, pageSize, dateFrom, dateTo, paymentMethodId])

  const query = useQuery({
    queryKey: [...queryKeys.sales.lists(), queryParams],
    queryFn: async (): Promise<SalesPageResponse> => {
      const qs = new URLSearchParams(queryParams).toString()
      return pythonClient.get<SalesPageResponse>(`/sales?${qs}`)
    },
    staleTime: 30 * 1000,
  })

  const sales = useMemo(
    () => (query.data?.items ?? []).map(mapSale),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total ?? 0),
    [page, pageSize, query.data?.total],
  )

  // ── Mutations ─────────────────────────────────────────────────────────────
  const addSaleOperationMutation = useMutation({
    mutationFn: async ({
      items,
      meta: opMeta,
    }: {
      items: SaleCartItem[]
      meta: {
        idempotencyKey: string
        clientId: string | null
        date: string
        currency: string
        branchId?: string | null
        canal?: string | null
        orgId: string
        /** metodos-pago-operaciones: optional, shared by all lines of the operation */
        paymentMethodId?: string | null
        /**
         * pagos-cableados-restantes (OQ-C): opt-in de caja del formulario de
         * venta — ausencia = no-op (D5). Las tres condiciones de servidor
         * (kind=cash, sesión abierta en la sucursal efectiva, fecha=hoy) se
         * validan en la RPC, nunca acá.
         */
        cashSessionId?: string | null
        /**
         * pos-banco-movimientos (D2): override explícito de la cuenta
         * bancaria destino. null/ausente = usar el default del método (o no
         * escribir nada si tampoco hay default) — la RPC resuelve y valida.
         */
        bankAccountId?: string | null
        /**
         * cobranzas-vencimientos (D3/D11): vencimiento explicito de la venta
         * a credito. null/ausente = la cascada de plazos (cliente → cuenta)
         * se resuelve en el helper del servidor, nunca aca.
         */
        dueDate?: string | null
      }
    }): Promise<SaleOperationResult> => {
      const payload = {
        org_id:          opMeta.orgId,
        date:            opMeta.date,
        client_id:       opMeta.clientId ?? null,
        currency:        opMeta.currency,
        canal:           opMeta.canal ?? null,
        payment_method_id: opMeta.paymentMethodId ?? null,
        cash_session_id: opMeta.cashSessionId ?? null,
        bank_account_id: opMeta.bankAccountId ?? null,
        due_date:        opMeta.dueDate ?? null,
        items: items.map(item => ({
          product_id: item.productId,
          amount:     item.unitPrice * (1 - item.discount / 100),
          quantity:   item.quantity,
          unit_id:    item.unitId ?? null,
        })),
      }
      // v3-api-standards §3/§6.2: la clave de idempotencia viaja por el header
      // Idempotency-Key (D4) — el body ya no la incluye.
      return pythonClient.post<SaleOperationResult>("/sales", payload, {
        "Idempotency-Key": opMeta.idempotencyKey,
      })
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
      // fix-supplier-account-ui-post-delete (bug 1, lado ventas): una venta a
      // crédito postea un cargo en customerAccounts — sin esto la cuenta
      // corriente del cliente queda stale (staleTime 30s en useCustomerAccount).
      queryClient.invalidateQueries({ queryKey: queryKeys.customerAccounts.all() })
      // cobranzas-panel (D8): el panel /cobranzas y el KPI del Tablero derivan
      // del mismo saldo — toda mutación que lo altera los invalida acá, en el
      // hook, nunca en la pantalla.
      queryClient.invalidateQueries({ queryKey: queryKeys.receivables.all() })
    },
  })

  const updateSaleMutation = useMutation({
    mutationFn: async (sale: Sale) => {
      return pythonClient.put<SaleApiRow>(`/sales/${sale.id}`, {
        amount:   sale.unitPrice,
        total:    sale.unitPrice * sale.quantity,
        quantity: sale.quantity,
        currency: sale.currency,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      // fix-supplier-account-ui-post-delete (bug 1, lado ventas): ver
      // comentario arriba.
      queryClient.invalidateQueries({ queryKey: queryKeys.customerAccounts.all() })
      // cobranzas-panel (D8): el panel /cobranzas y el KPI del Tablero derivan
      // del mismo saldo — toda mutación que lo altera los invalida acá, en el
      // hook, nunca en la pantalla.
      queryClient.invalidateQueries({ queryKey: queryKeys.receivables.all() })
    },
  })

  const deleteSaleMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/sales/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      // fix-supplier-account-ui-post-delete (bug 1, lado ventas): borrar una
      // venta a crédito revierte el cargo — sin esto la UI seguía mostrando
      // el saldo/movimiento ya reversado en DB.
      queryClient.invalidateQueries({ queryKey: queryKeys.customerAccounts.all() })
      // cobranzas-panel (D8): el panel /cobranzas y el KPI del Tablero derivan
      // del mismo saldo — toda mutación que lo altera los invalida acá, en el
      // hook, nunca en la pantalla.
      queryClient.invalidateQueries({ queryKey: queryKeys.receivables.all() })
    },
  })

  const deleteSalesByOperationMutation = useMutation({
    mutationFn: async (operationId: string) => {
      return pythonClient.delete<void>(`/sales?operation_id=${operationId}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      // fix-supplier-account-ui-post-delete (bug 1, lado ventas): ver
      // comentario arriba.
      queryClient.invalidateQueries({ queryKey: queryKeys.customerAccounts.all() })
      // cobranzas-panel (D8): el panel /cobranzas y el KPI del Tablero derivan
      // del mismo saldo — toda mutación que lo altera los invalida acá, en el
      // hook, nunca en la pantalla.
      queryClient.invalidateQueries({ queryKey: queryKeys.receivables.all() })
    },
  })

  const updateSaleOperationMutation = useMutation({
    mutationFn: async ({
      saleIds,
      newItems,
      meta: opMeta,
    }: {
      saleIds: string[]
      newItems: SaleCartItem[]
      meta: {
        clientId: string | null
        date: string
        currency: string
        orgId: string
        /**
         * metodos-pago-operaciones (D5): tri-estado por AUSENCIA de la clave
         * — ver el comentario espejo en use-purchases.ts.
         */
        paymentMethodId?: string | null
        /**
         * edicion-preserva-contexto (F1 §D3): branchId/canal usan el MISMO
         * contrato tri-estado por ausencia. Omitir la clave del objeto meta
         * preserva la sucursal/canal vigente; `null` explícito desimputa;
         * un valor reimputa.
         */
        branchId?: string | null
        canal?: string | null
      }
    }) => {
      const items = newItems.map(item => ({
        product_id: item.productId,
        amount:     item.unitPrice * (1 - item.discount / 100),
        quantity:   item.quantity,
        // edicion-preserva-contexto (F1 §D7): unit_id viaja pegado a la
        // línea — el form lo prefillea desde SaleItemOut.unit_id y lo
        // reenvía, igual que quantity/price.
        unit_id:    item.unitId ?? null,
      }))
      const payload: Record<string, unknown> = {
        sale_ids:  saleIds,
        client_id: opMeta.clientId ?? null,
        date:      opMeta.date,
        currency:  opMeta.currency,
        items,
      }
      if ("paymentMethodId" in opMeta) {
        payload.payment_method_id = opMeta.paymentMethodId ?? null
      }
      // edicion-preserva-contexto: mismo patrón de inclusión condicional —
      // JSON.stringify omite claves con valor `undefined`, así que "ausente"
      // viaja literalmente ausente y el backend (model_fields_set) distingue
      // "preservar" de "informado con null" (desimputar).
      if ("branchId" in opMeta) {
        payload.branch_id = opMeta.branchId ?? null
      }
      if ("canal" in opMeta) {
        payload.canal = opMeta.canal ?? null
      }
      return pythonClient.put<void>("/sales/operation", payload)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
      // fix-supplier-account-ui-post-delete (bug 1, lado ventas): editar una
      // operación de venta puede reimputar/desimputar el cliente o cambiar
      // montos que ya postearon cargo — ver comentario arriba.
      queryClient.invalidateQueries({ queryKey: queryKeys.customerAccounts.all() })
      // cobranzas-panel (D8): el panel /cobranzas y el KPI del Tablero derivan
      // del mismo saldo — toda mutación que lo altera los invalida acá, en el
      // hook, nunca en la pantalla.
      queryClient.invalidateQueries({ queryKey: queryKeys.receivables.all() })
    },
  })

  return {
    sales,
    meta,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error ? (query.error as Error).message : null,
    dateFrom,
    setDateFrom,
    dateTo,
    setDateTo,
    paymentMethodId,
    setPaymentMethodId,
    clearFilters,
    setPage,
    setPageSize,
    refetch: query.refetch,
    addSaleOperation:       addSaleOperationMutation.mutateAsync,
    updateSale:             updateSaleMutation.mutateAsync,
    deleteSale:             deleteSaleMutation.mutateAsync,
    deleteSalesByOperation: deleteSalesByOperationMutation.mutateAsync,
    updateSaleOperation:    updateSaleOperationMutation.mutateAsync,
    addSaleOperationMutation,
    updateSaleMutation,
    deleteSaleMutation,
    deleteSalesByOperationMutation,
    updateSaleOperationMutation,
  }
}
