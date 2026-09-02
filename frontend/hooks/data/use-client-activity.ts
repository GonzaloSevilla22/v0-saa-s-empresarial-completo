"use client"

/**
 * clientes-frecuentes-historial — hooks de datos para el listado de clientes
 * con actividad comercial y el historial de compras por cliente.
 *
 * `activity_status` viaja YA CALCULADO desde el backend
 * (backend/core/client_activity.py, client-activity §"Umbrales canónicos en
 * una única fuente de verdad") — este hook sólo mapea el envelope, nunca
 * compara cantidades ni fechas contra umbrales propios.
 */

import { useState, useCallback, useMemo } from "react"
import { useQuery } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import {
  buildPaginationMeta,
  type PaginationMeta,
  type PageSizeOption,
} from "@/lib/pagination-utils"

// ── Types ──────────────────────────────────────────────────────────────────

export type ClientActivityStatus = "frecuente" | "activo" | "inactivo" | "sin_compras"
export type ClientActivitySort = "name" | "last_purchase" | "total_spent" | "purchase_count"
export type SortDir = "asc" | "desc"

interface ClientActivityApiRow {
  id: string
  name: string
  email: string | null
  phone: string | null
  tax_id?: string | null
  iva_condition?: string | null
  legal_name?: string | null
  created_at: string
  purchase_count: number | string
  purchase_count_90d: number | string
  total_spent: number | string
  last_purchase_date: string | null
  days_since_last_purchase: number | string | null
  activity_status: ClientActivityStatus
  // cobranzas-panel (D9): saldo materializado de la cuenta corriente —
  // Decimal de Pydantic viaja como string; ausente en backends viejos.
  current_balance?: number | string
}

interface ClientActivityPageResponse {
  items: ClientActivityApiRow[]
  total: number
  page: number
  pages: number
}

export interface ClientActivity {
  id: string
  name: string
  email: string
  phone: string
  taxId?: string
  ivaCondition?: string
  legalName?: string
  purchaseCount: number
  purchaseCount90d: number
  totalSpent: number
  lastPurchaseDate: string | null
  daysSinceLastPurchase: number | null
  activityStatus: ClientActivityStatus
  /** cobranzas-panel (D9): saldo de cuenta corriente — 0 = al día o sin cuenta. */
  currentBalance: number
}

interface ClientPurchaseApiRow {
  operation_id: string
  operation_date: string
  item_count: number | string
  total: number | string
}

interface ClientPurchaseSummaryApi {
  purchase_count: number | string
  total_spent: number | string
  last_purchase_date: string | null
  days_since_last_purchase: number | string | null
}

interface ClientPurchasesPageResponse {
  items: ClientPurchaseApiRow[]
  total: number
  page: number
  pages: number
  summary: ClientPurchaseSummaryApi
}

export interface ClientPurchase {
  operationId: string
  operationDate: string
  itemCount: number
  total: number
}

export interface ClientPurchaseSummary {
  purchaseCount: number
  totalSpent: number
  lastPurchaseDate: string | null
  daysSinceLastPurchase: number | null
}

// ── Mappers — numerics de Postgres pueden llegar como string ────────────────

const toNumber = (v: number | string | null | undefined): number => {
  if (v == null) return 0
  const n = Number(v)
  return Number.isNaN(n) ? 0 : n
}

const toNullableNumber = (v: number | string | null | undefined): number | null =>
  v == null ? null : toNumber(v)

function mapClientActivity(r: ClientActivityApiRow): ClientActivity {
  return {
    id:                     r.id,
    name:                   r.name,
    email:                  r.email || "",
    phone:                  r.phone || "",
    taxId:                  r.tax_id        || undefined,
    ivaCondition:           r.iva_condition || undefined,
    legalName:              r.legal_name    || undefined,
    purchaseCount:          toNumber(r.purchase_count),
    purchaseCount90d:       toNumber(r.purchase_count_90d),
    totalSpent:             toNumber(r.total_spent),
    lastPurchaseDate:       r.last_purchase_date,
    daysSinceLastPurchase:  toNullableNumber(r.days_since_last_purchase),
    activityStatus:         r.activity_status,
    // Una respuesta sin la columna (backend viejo) degrada a 0, no a NaN.
    currentBalance:         toNumber(r.current_balance),
  }
}

function mapPurchase(r: ClientPurchaseApiRow): ClientPurchase {
  return {
    operationId:    r.operation_id,
    operationDate:  r.operation_date,
    itemCount:      toNumber(r.item_count),
    total:          toNumber(r.total),
  }
}

function mapSummary(r: ClientPurchaseSummaryApi): ClientPurchaseSummary {
  return {
    purchaseCount:          toNumber(r.purchase_count),
    totalSpent:             toNumber(r.total_spent),
    lastPurchaseDate:       r.last_purchase_date,
    daysSinceLastPurchase:  toNullableNumber(r.days_since_last_purchase),
  }
}

// ── useClientActivityList — GET /clients/activity ───────────────────────────

export function useClientActivityList() {
  const [page,           setPageState]           = useState(0)
  const [pageSize,       setPageSizeState]       = useState<PageSizeOption>(25)
  const [search,         setSearchState]         = useState("")
  const [activityStatus, setActivityStatusState] = useState<ClientActivityStatus | null>(null)
  // deudas-menores-agosto (G3): default pasa de name/asc a last_purchase/desc
  // — el control de orden inicializa reflejando lo que el servidor ya
  // devuelve por defecto (design.md §D7); el orden lo sigue resolviendo SQL.
  const [sort,           setSortState]           = useState<ClientActivitySort>("last_purchase")
  const [sortDir,        setSortDirState]        = useState<SortDir>("desc")

  const setPage = useCallback((p: number) => setPageState(p), [])
  const setPageSize = useCallback((s: PageSizeOption) => {
    setPageSizeState(s)
    setPageState(0)
  }, [])
  const setSearch = useCallback((v: string) => {
    setSearchState(v)
    setPageState(0)
  }, [])
  const setActivityStatus = useCallback((s: ClientActivityStatus | null) => {
    setActivityStatusState(s)
    setPageState(0)
  }, [])
  const setSort = useCallback((key: ClientActivitySort) => {
    setSortState((prev) => {
      if (prev === key) {
        setSortDirState((d) => (d === "asc" ? "desc" : "asc"))
        return prev
      }
      setSortDirState("asc")
      return key
    })
    setPageState(0)
  }, [])

  const queryParams = useMemo(() => {
    const p: Record<string, string> = {
      page:     String(page),
      size:     String(pageSize),
      sort,
      sort_dir: sortDir,
    }
    if (search)         p.search          = search
    if (activityStatus) p.activity_status = activityStatus
    return p
  }, [page, pageSize, search, activityStatus, sort, sortDir])

  const query = useQuery({
    queryKey: [...queryKeys.clients.activity(), queryParams],
    queryFn: async (): Promise<ClientActivityPageResponse> => {
      const qs = new URLSearchParams(queryParams).toString()
      return pythonClient.get<ClientActivityPageResponse>(`/clients/activity?${qs}`)
    },
    staleTime: 30 * 1000,
  })

  const clients = useMemo(
    () => (query.data?.items ?? []).map(mapClientActivity),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total ?? 0),
    [page, pageSize, query.data?.total],
  )

  return {
    clients,
    meta,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error ? (query.error as Error).message : null,
    search,         setSearch,
    activityStatus, setActivityStatus,
    sort,           sortDir, setSort,
    setPage,        setPageSize,
    refetch: query.refetch,
  }
}

// ── useClientPurchases — GET /clients/{id}/purchases ─────────────────────────

export function useClientPurchases(clientId: string | null) {
  const [page,     setPageState]     = useState(0)
  const [pageSize, setPageSizeState] = useState<PageSizeOption>(25)

  const setPage = useCallback((p: number) => setPageState(p), [])
  const setPageSize = useCallback((s: PageSizeOption) => {
    setPageSizeState(s)
    setPageState(0)
  }, [])

  const query = useQuery({
    queryKey: [...queryKeys.clients.purchases(clientId ?? ""), page, pageSize],
    queryFn: async (): Promise<ClientPurchasesPageResponse> => {
      const qs = new URLSearchParams({ page: String(page), size: String(pageSize) }).toString()
      return pythonClient.get<ClientPurchasesPageResponse>(`/clients/${clientId}/purchases?${qs}`)
    },
    enabled: !!clientId,
    staleTime: 30 * 1000,
  })

  const purchases = useMemo(
    () => (query.data?.items ?? []).map(mapPurchase),
    [query.data],
  )

  // El resumen se calcula sobre TODAS las operaciones del cliente — no
  // depende de la página visible (client-purchase-history §"Resumen
  // acumulado"), pero SÍ requiere que haya datos cargados.
  const summary: ClientPurchaseSummary | null = useMemo(
    () => (query.data ? mapSummary(query.data.summary) : null),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total ?? 0),
    [page, pageSize, query.data?.total],
  )

  return {
    purchases,
    summary,
    meta,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error ? (query.error as Error).message : null,
    setPage,
    setPageSize,
    refetch: query.refetch,
  }
}
