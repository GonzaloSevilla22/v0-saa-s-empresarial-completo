"use client"

import { useState, useCallback, useMemo } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Expense, PaymentMethodKind } from "@/lib/types"
import {
  buildPaginationMeta,
  type PaginationMeta,
  type PageSizeOption,
} from "@/lib/pagination-utils"

// ── Types for API responses ───────────────────────────────────────────────────

interface ExpenseApiRow {
  id: string
  account_id?: string
  user_id?: string
  category: string
  amount: string | number
  description: string | null
  date: string
  created_at: string
  // cost-center-dimension: optional analytic dimension
  cost_center_id?: string | null
  // gastos-forma-pago: imputación + derivados de bloqueo, todos resueltos por
  // el backend con los MISMOS `EXISTS` que evalúan los guards del servidor
  // (P0423 en la edición, P0426 en el borrado). Nunca una regla reimplementada
  // en cliente: el listado se limita a mostrar lo que el servidor decidió.
  branch_id?: string | null
  payment_method_id?: string | null
  payment_method_name?: string | null
  payment_method_kind?: string | null
  is_payment_locked?: boolean
  has_cash_movement?: boolean
  has_bank_movement?: boolean
  is_delete_blocked?: boolean
}

/**
 * D18 — BREAKING de API interna sancionado: `GET /expenses` dejó de devolver
 * una lista plana y adoptó el envelope estándar de `v3-api-standards §2`,
 * igual que `GET /sales`. Es la única forma de que el estado de bloqueo llegue
 * a cada fila: `is_payment_locked` es un derivado de `cash_movements`/
 * `bank_movements`, no una columna de `expenses`, y por PostgREST directo no
 * hay camino de datos.
 */
interface ExpensesPageResponse {
  items: ExpenseApiRow[]
  total: number
  page?: number
  pages?: number
}

/** Alta: los cuatro campos nuevos son passthrough — la RPC decide, no el hook. */
export type ExpenseCreateInput = Omit<Expense, "id"> & {
  /** D1: opt-in de caja. Ausente/null = el gasto no toca caja (no-op). */
  cashSessionId?: string | null
  /** D5: override de la cuenta bancaria de la que sale el dinero. */
  bankAccountId?: string | null
}

/**
 * Edición: contrato TRI-ESTADO **por ausencia de la clave**, igual que
 * `useSales().updateSaleOperation` y `usePurchases()`:
 *   · clave ausente → preservar el valor vigente
 *   · `null`        → desimputar
 *   · uuid          → reimputar
 *
 * `JSON.stringify` omite las claves con valor `undefined`, así que "ausente"
 * viaja literalmente ausente y el backend lo distingue con `model_fields_set`.
 * La firma NO acepta `cashSessionId`/`bankAccountId`: la edición no postea
 * movimientos (D11/D13), y `rpc_update_expense` ni siquiera los recibe.
 */
export type ExpenseUpdateInput = Expense

function mapExpense(e: ExpenseApiRow): Expense {
  return {
    id:            e.id,
    date:          typeof e.date === "string" ? e.date.split("T")[0] : String(e.date),
    category:      e.category,
    description:   e.description || "",
    amount:        Number(e.amount),
    costCenterId:  e.cost_center_id ?? null,
    // gastos-forma-pago (D12): sin esto el selector de sucursal arranca vacío
    // al editar — el mapeo la descartaba y por eso el form la perdía.
    branchId:          e.branch_id ?? null,
    paymentMethodId:   e.payment_method_id ?? null,
    paymentMethodName: e.payment_method_name ?? null,
    paymentMethodKind: (e.payment_method_kind ?? null) as PaymentMethodKind | null,
    // Default false: una fila que llega sin el derivado se trata como NO
    // bloqueada y el servidor sigue siendo la autoridad (rechaza igual).
    isPaymentLocked: e.is_payment_locked ?? false,
    hasCashMovement: e.has_cash_movement ?? false,
    hasBankMovement: e.has_bank_movement ?? false,
    isDeleteBlocked: e.is_delete_blocked ?? false,
  }
}

/**
 * Alta contra `POST /expenses`. Vive en el módulo, no dentro del hook, para que
 * el alta suelta (`useExpenses`) y el alta masiva del importador
 * (`useBulkAddExpense`) compartan EXACTAMENTE el mismo payload: dos copias del
 * mapeo divergen y el bug aparece sólo por uno de los dos caminos.
 */
async function postExpense(expense: ExpenseCreateInput) {
  return pythonClient.post<ExpenseApiRow>("/expenses", {
    category:        expense.category,
    description:     expense.description ?? null,
    amount:          expense.amount,
    date:            expense.date,
    // cost-center-dimension: optional analytic dimension
    cost_center_id:  expense.costCenterId ?? null,
    // gastos-forma-pago (D6): el form lo mandaba y el payload lo tiraba —
    // 0 de 175 gastos de prod tienen sucursal por este bug.
    branch_id:         expense.branchId ?? null,
    payment_method_id: expense.paymentMethodId ?? null,
    cash_session_id:   expense.cashSessionId ?? null,
    bank_account_id:   expense.bankAccountId ?? null,
  })
}

/**
 * Set completo de invalidaciones de las mutaciones de gasto.
 *
 * Un gasto en efectivo escribe en `cash_movements` y uno por método bancario
 * en `bank_movements`; el borrado compensa las DOS patas. Invalidar sólo
 * `expenses` deja /caja, /banco, la conciliación y el reporte de formas de
 * pago mostrando un saldo que ya no existe — el precedente ya se pagó una vez
 * en ventas, donde faltaba `customerAccounts`.
 *
 * ⚠️ Lo que esto NO alcanza, a propósito: el `refreshToken` de
 * `LedgerMovementsPanel` es `useState` LOCAL de /banco y /caja — no hay query
 * key ni store que una mutación de /gastos pueda tocar, y esos paneles ni
 * siquiera están montados mientras el usuario está en /gastos (montan y hacen
 * fetch al navegar). El repo ya fijó esa división en
 * `use-cash-movements.ts:121-125`. Refresco cross-página = mover el token a un
 * store: alcance nuevo, no de este change.
 *
 * Se expone como hook propio para que el importador pueda invalidar UNA vez al
 * terminar el lote en vez de una vez por fila.
 */
export function useInvalidateExpenseLedgers() {
  const queryClient = useQueryClient()
  return useCallback(() => {
    queryClient.invalidateQueries({ queryKey: queryKeys.expenses.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.cashMovements.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.bankAccounts.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.bankReconciliation.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.paymentMethods.all() })
  }, [queryClient])
}

/**
 * Alta MASIVA para el importador CSV (D13): la misma alta, SIN invalidación por
 * fila y sin montar el listado.
 *
 * El importador llama al alta una vez por fila, en serie. Con `onSuccess:
 * invalidateLedgers` eso son seis invalidaciones por fila —y, en /gastos, dos
 * refetches reales por fila— todos descartados salvo el último. Y en este
 * camino son además inútiles por definición: por D13 las filas importadas
 * viajan sin forma de pago, sin sesión de caja y sin cuenta bancaria, así que
 * un alta por importación no puede tocar caja, banco ni el catálogo. El
 * diálogo invalida UNA vez al terminar el lote.
 */
export function useBulkAddExpense() {
  const invalidateLedgers = useInvalidateExpenseLedgers()
  const addExpenseMutation = useMutation({ mutationFn: postExpense })
  return { addExpenseMutation, invalidateLedgers }
}

// ── Unified hook ─────────────────────────────────────────────────────────────

/**
 * Origen de datos del listado de `/gastos` + mutaciones (alta, edición,
 * borrado) contra el backend FastAPI.
 *
 * Paginación y filtros server-side calcados de `useSales()` (D18): hasta este
 * change `/gastos` leía por PostgREST directo con `usePaginatedQuery` y este
 * hook sólo alimentaba `recent-activity.tsx`.
 */
export function useExpenses() {
  // ── Pagination & filter state ─────────────────────────────────────────────
  const [page,     setPageState]     = useState(0)
  const [pageSize, setPageSizeState] = useState<PageSizeOption>(25)
  const [search,   setSearchState]   = useState("")
  const [dateFrom, setDateFromState] = useState("")
  const [dateTo,   setDateToState]   = useState("")
  const [costCenterId,    setCostCenterIdState]    = useState<string | null>(null)
  const [paymentMethodId, setPaymentMethodIdState] = useState<string | null>(null)

  const setPage = useCallback((p: number) => setPageState(p), [])
  const setPageSize = useCallback((s: PageSizeOption) => {
    setPageSizeState(s)
    setPageState(0)
  }, [])
  // Todo cambio de filtro vuelve a la página 0: filtrar quedándose en la
  // página 3 muestra "sin resultados" sobre un filtro que sí tiene filas.
  const setSearch   = useCallback((v: string) => { setSearchState(v);   setPageState(0) }, [])
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
    setSearchState("")
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
    if (search)   p.search    = search
    if (dateFrom) p.date_from = dateFrom
    if (dateTo)   p.date_to   = dateTo
    if (costCenterId)    p.cost_center_id    = costCenterId
    if (paymentMethodId) p.payment_method_id = paymentMethodId
    return p
  }, [page, pageSize, search, dateFrom, dateTo, costCenterId, paymentMethodId])

  const query = useQuery({
    queryKey: [...queryKeys.expenses.lists(), queryParams],
    queryFn: async (): Promise<ExpensesPageResponse> => {
      const qs = new URLSearchParams(queryParams).toString()
      return pythonClient.get<ExpensesPageResponse>(`/expenses?${qs}`)
    },
    staleTime: 30 * 1000,
  })

  const expenses = useMemo(
    () => (query.data?.items ?? []).map(mapExpense),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total ?? 0),
    [page, pageSize, query.data?.total],
  )

  // Set completo de invalidaciones (definido arriba, compartido con el
  // importador masivo).
  const invalidateLedgers = useInvalidateExpenseLedgers()

  const addExpenseMutation = useMutation({
    mutationFn: postExpense,
    onSuccess: invalidateLedgers,
  })

  const updateExpenseMutation = useMutation({
    mutationFn: async (expense: ExpenseUpdateInput) => {
      const payload: Record<string, unknown> = {
        category:    expense.category,
        description: expense.description ?? null,
        amount:      expense.amount,
        date:        expense.date,
      }
      // Tri-estado por ausencia (D12). `cost_center_id` se perdía en cada
      // edición porque el payload directamente no lo incluía.
      if ("costCenterId" in expense)     payload.cost_center_id    = expense.costCenterId ?? null
      if ("branchId" in expense)         payload.branch_id         = expense.branchId ?? null
      if ("paymentMethodId" in expense)  payload.payment_method_id = expense.paymentMethodId ?? null
      return pythonClient.put<ExpenseApiRow>(`/expenses/${expense.id}`, payload)
    },
    onSuccess: invalidateLedgers,
  })

  const deleteExpenseMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/expenses/${id}`)
    },
    onSuccess: invalidateLedgers,
  })

  return {
    expenses,
    meta,
    isLoading:     query.isLoading,
    isError:       query.isError,
    error:         query.error,
    refetch:       query.refetch,
    // Filtros del listado (D18)
    search,          setSearch,
    dateFrom,        setDateFrom,
    dateTo,          setDateTo,
    costCenterId,    setCostCenterId,
    paymentMethodId, setPaymentMethodId,
    clearFilters,
    setPage,
    setPageSize,
    addExpense:    addExpenseMutation.mutateAsync,
    updateExpense: updateExpenseMutation.mutateAsync,
    deleteExpense: deleteExpenseMutation.mutateAsync,
    // Individual mutation states for UI feedback
    addExpenseMutation,
    updateExpenseMutation,
    deleteExpenseMutation,
  }
}

// ── Legacy individual exports (kept for backward compatibility) ───────────────

/** @deprecated Use `useExpenses()` instead */
export function useAddExpense() {
  const { addExpenseMutation } = useExpenses()
  return addExpenseMutation
}

/** @deprecated Use `useExpenses()` instead */
export function useUpdateExpense() {
  const { updateExpenseMutation } = useExpenses()
  return updateExpenseMutation
}

/** @deprecated Use `useExpenses()` instead */
export function useDeleteExpense() {
  const { deleteExpenseMutation } = useExpenses()
  return deleteExpenseMutation
}
