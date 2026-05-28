"use client"

/**
 * SaleOperationsList — paginated version.
 *
 * Data flow:
 *   VentasPage calls usePaginatedQuery (date filter server-side, ordered by date DESC)
 *     → passes the page's raw Sale rows + pagination controls as props
 *   This component groups those rows by operation_id in memory (cheap: ≤ 100 rows)
 *     → applies client-side text search on the already-fetched page
 *     → renders grouped operations + PaginationBar
 *
 * Why client-side search on a paginated component?
 *   Searching by product/client name requires joining related tables. Supabase
 *   does not support .ilike() on joined columns. Filtering on the current page
 *   (≤ 100 rows) is instant and avoids a complex multi-step server query.
 *   Date range filter IS server-side and accurate across all pages.
 */

import { useState, useMemo, useCallback } from "react"
import { Button }   from "@/components/ui/button"
import { Input }    from "@/components/ui/input"
import { Label }    from "@/components/ui/label"
import { Badge }    from "@/components/ui/badge"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { groupSalesByOperation, type SaleOperation } from "@/lib/group-operations"
import { exportToCSV } from "@/lib/excel"
import { formatMoney, formatDate, type Currency } from "@/lib/format"
import { SaleReceiptButton } from "@/components/ventas/sale-receipt-button"
import type { Sale, Client } from "@/lib/types"
import { ProductDisplay } from "@/components/shared/product-display"
import type { PaginationMeta, PageSizeOption } from "@/lib/pagination-utils"
import {
  Plus, Trash2, Pencil, ChevronDown, ChevronRight,
  ShoppingCart, Search, PackageOpen, Download, CalendarDays, X, Loader2,
} from "lucide-react"
import { toast } from "sonner"

interface SaleOperationsListProps {
  // Paginated data from parent (usePaginatedQuery)
  sales:           Sale[]
  meta:            PaginationMeta
  loading:         boolean
  error:           string | null
  // Date filter — server-side, passed from parent hook
  dateFrom:        string
  setDateFrom:     (v: string) => void
  dateTo:          string
  setDateTo:       (v: string) => void
  clearFilters:    () => void
  onPageChange:    (page: number) => void
  onPageSizeChange:(size: PageSizeOption) => void
  // Misc
  clients:         Client[]
  onAdd:           () => void
  onDeleteOperation:(op: SaleOperation) => Promise<void>
  onEditOperation?: (op: SaleOperation) => void
  onRefetch:       () => void
}

export function SaleOperationsList({
  sales, meta, loading, error,
  dateFrom, setDateFrom, dateTo, setDateTo, clearFilters,
  onPageChange, onPageSizeChange,
  clients, onAdd, onDeleteOperation, onEditOperation, onRefetch,
}: SaleOperationsListProps) {
  const clientMap    = useMemo(() => new Map(clients.map((c) => [c.id, c])), [clients])
  const [search,     setSearch]     = useState("")
  const [expandedKey, setExpandedKey] = useState<string | null>(null)
  const [deletingKey, setDeletingKey] = useState<string | null>(null)

  const isDateFilterActive = !!(dateFrom || dateTo)

  // Group the current page's rows → operations (in-memory, ≤ 100 rows)
  const operations = useMemo(() => groupSalesByOperation(sales), [sales])

  // Client-side text filter on the current page
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return operations
    return operations.filter(
      (op) =>
        op.clientName.toLowerCase().includes(q) ||
        op.items.some((i) => i.productName.toLowerCase().includes(q)),
    )
  }, [operations, search])

  const grandTotal = useMemo(
    () => filtered.reduce((sum, op) => sum + op.total, 0),
    [filtered],
  )

  function handleExport() {
    const rows = filtered.flatMap((op) =>
      op.items.map((item) => ({
        date: item.date, clientName: op.clientName,
        productName: item.productName, quantity: item.quantity,
        unitPrice: item.unitPrice, total: item.total,
        currency: op.currency, operationId: op.operationId ?? "",
      })),
    )
    exportToCSV(rows, [
      { key: "date",        header: "Fecha"        },
      { key: "clientName",  header: "Cliente"      },
      { key: "productName", header: "Producto"     },
      { key: "quantity",    header: "Cantidad"     },
      { key: "unitPrice",   header: "Precio unit." },
      { key: "total",       header: "Total"        },
      { key: "currency",    header: "Moneda"       },
      { key: "operationId", header: "ID Operación" },
    ], "ventas")
    toast.success(`Exportadas ${rows.length} filas`)
  }

  const handleDelete = useCallback(
    async (e: React.MouseEvent, op: SaleOperation) => {
      e.stopPropagation()
      const label = op.isGrouped ? `esta operación (${op.items.length} ítems)` : "esta venta"
      if (!confirm(`¿Eliminar ${label}? Esta acción no se puede deshacer.`)) return
      setDeletingKey(op.key)
      try {
        await onDeleteOperation(op)
        toast.success(op.isGrouped ? `${op.items.length} registros eliminados` : "Venta eliminada")
        onRefetch()
      } catch (err: any) {
        toast.error(err.message || "Error al eliminar")
      } finally {
        setDeletingKey(null)
      }
    },
    [onDeleteOperation, onRefetch],
  )

  const toggleExpand = useCallback((key: string) => {
    setExpandedKey((prev) => (prev === key ? null : key))
  }, [])

  return (
    <div className="flex flex-col gap-4">
      {/* Controls Bar */}
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
          {/* Client-side text search */}
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Buscar en esta página..."
              className="pl-9 bg-background border-border text-foreground"
            />
          </div>

          {/* Server-side date filter */}
          <Popover>
            <PopoverTrigger asChild>
              <Button
                variant="outline" size="sm"
                className={`shrink-0 border-border text-foreground ${isDateFilterActive ? "border-primary text-primary" : ""}`}
              >
                <CalendarDays className="h-4 w-4 mr-1" />
                Filtrar fechas
                {isDateFilterActive && (
                  <span className="ml-1.5 flex h-4 w-4 items-center justify-center rounded-full bg-primary text-[10px] text-primary-foreground">1</span>
                )}
              </Button>
            </PopoverTrigger>
            <PopoverContent className="w-72 bg-popover border-border" align="start">
              <div className="flex flex-col gap-3">
                <p className="text-sm font-medium text-foreground">Rango de fechas</p>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Desde</Label>
                  <Input type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Hasta</Label>
                  <Input type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                {isDateFilterActive && (
                  <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={clearFilters}>
                    <X className="h-3 w-3 mr-1" />Limpiar filtro
                  </Button>
                )}
              </div>
            </PopoverContent>
          </Popover>
        </div>

        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">
            {loading
              ? <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Cargando...</span>
              : `${filtered.length} operación${filtered.length !== 1 ? "es" : ""}`
            }
          </span>
          <Button variant="outline" size="sm" className="border-border text-foreground" onClick={handleExport}>
            <Download className="h-4 w-4 mr-1" />Exportar
          </Button>
          <Button onClick={onAdd} size="sm" className="gap-2">
            <Plus className="h-4 w-4" />Nueva venta
          </Button>
        </div>
      </div>

      {/* Error state */}
      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error}
        </div>
      )}

      {/* Table */}
      <div className="rounded-xl border border-border overflow-hidden">
        <div className="hidden sm:grid grid-cols-[120px_1fr_180px_80px_120px_48px_48px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Fecha</span>
          <span>Productos</span>
          <span>Cliente</span>
          <span className="text-center">Ítems</span>
          <span className="text-right">Total</span>
          <span /><span />
        </div>

        {/* Skeleton loader */}
        {loading && sales.length === 0 && (
          <div className="flex flex-col">
            {Array.from({ length: 5 }).map((_, i) => (
              <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                <div className="hidden sm:grid grid-cols-[120px_1fr_180px_80px_120px_48px_48px] gap-3 items-center">
                  <div className="h-3.5 w-20 rounded bg-accent animate-pulse" />
                  <div className="h-3.5 w-40 rounded bg-accent animate-pulse" />
                  <div className="h-3.5 w-28 rounded bg-accent animate-pulse" />
                  <div className="h-3.5 w-8 rounded bg-accent animate-pulse mx-auto" />
                  <div className="h-3.5 w-20 rounded bg-accent animate-pulse ml-auto" />
                </div>
                <div className="sm:hidden h-14 rounded bg-accent animate-pulse" />
              </div>
            ))}
          </div>
        )}

        {/* Empty state */}
        {!loading && filtered.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {search || isDateFilterActive ? "Sin resultados para esa búsqueda" : "No hay ventas registradas"}
            </p>
            {!search && !isDateFilterActive && (
              <Button variant="outline" size="sm" onClick={onAdd} className="gap-2">
                <Plus className="h-4 w-4" />Registrar primera venta
              </Button>
            )}
          </div>
        )}

        {/* Operation rows */}
        {filtered.map((op) => {
          const isExpanded = expandedKey === op.key
          return (
            <div key={op.key} className="border-t border-border/50 first:border-t-0">
              <div
                role="button" tabIndex={0}
                onClick={() => toggleExpand(op.key)}
                onKeyDown={(e) => e.key === "Enter" && toggleExpand(op.key)}
                className="cursor-pointer hover:bg-accent/20 transition-colors group"
                aria-expanded={isExpanded}
              >
                {/* Mobile */}
                <div className="sm:hidden flex flex-col gap-1.5 px-4 py-3">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs text-muted-foreground tabular-nums">{formatDate(op.date)}</span>
                    <div className="flex items-center gap-1.5">
                      {op.isGrouped && (
                        <Badge variant="secondary" className="text-[10px] bg-emerald-500/15 text-emerald-400 border-emerald-500/25 border font-semibold">
                          <ShoppingCart className="h-2.5 w-2.5 mr-1" />{op.items.length}
                        </Badge>
                      )}
                      {onEditOperation && (
                        <Button type="button" variant="ghost" size="icon"
                          onClick={(e) => { e.stopPropagation(); onEditOperation(op) }}
                          className="h-8 w-8 text-muted-foreground hover:text-primary hover:bg-primary/10">
                          <Pencil className="h-3.5 w-3.5" />
                        </Button>
                      )}
                      <Button type="button" variant="ghost" size="icon"
                        onClick={(e) => handleDelete(e, op)} disabled={deletingKey === op.key}
                        className="h-8 w-8 text-muted-foreground hover:text-destructive hover:bg-destructive/10">
                        <Trash2 className="h-3.5 w-3.5" />
                      </Button>
                    </div>
                  </div>
                  <div className="flex items-center gap-2 min-w-0">
                    {isExpanded ? <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                      : <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0 group-hover:text-foreground" />}
                    <span className="text-sm font-medium text-foreground truncate">
                      {op.items[0].productName}
                      {op.items.length > 1 && (
                        <span className="text-muted-foreground font-normal"> · +{op.items.length - 1} más</span>
                      )}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-sm text-muted-foreground truncate">{op.clientName}</span>
                    <span className="text-sm font-bold text-emerald-400 tabular-nums">{formatMoney(op.total, op.currency)}</span>
                  </div>
                </div>

                {/* Desktop */}
                <div className="hidden sm:grid grid-cols-[120px_1fr_180px_80px_120px_48px_48px] gap-3 px-4 py-3 items-center">
                  <span className="text-sm text-muted-foreground tabular-nums">{formatDate(op.date)}</span>
                  <div className="flex items-center gap-2 min-w-0">
                    {isExpanded ? <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                      : <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0 group-hover:text-foreground" />}
                    <span className="text-sm font-medium text-foreground truncate">
                      {op.items[0].productName}
                      {op.items.length > 1 && (
                        <span className="text-muted-foreground font-normal"> · +{op.items.length - 1} más</span>
                      )}
                    </span>
                  </div>
                  <span className="text-sm text-muted-foreground truncate">{op.clientName}</span>
                  <div className="flex justify-center">
                    {op.isGrouped
                      ? <Badge variant="secondary" className="text-[10px] bg-emerald-500/15 text-emerald-400 border-emerald-500/25 border font-semibold">
                          <ShoppingCart className="h-2.5 w-2.5 mr-1" />{op.items.length}
                        </Badge>
                      : <span className="text-sm text-muted-foreground">1</span>
                    }
                  </div>
                  <span className="text-right text-sm font-bold text-emerald-400 tabular-nums">
                    {formatMoney(op.total, op.currency)}
                  </span>
                  {onEditOperation
                    ? <Button type="button" variant="ghost" size="icon"
                        onClick={(e) => { e.stopPropagation(); onEditOperation(op) }}
                        className="h-8 w-8 text-muted-foreground hover:text-primary hover:bg-primary/10">
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                    : <span />
                  }
                  <Button type="button" variant="ghost" size="icon"
                    onClick={(e) => handleDelete(e, op)} disabled={deletingKey === op.key}
                    className="h-8 w-8 text-muted-foreground hover:text-destructive hover:bg-destructive/10">
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              </div>

              {/* Expanded detail */}
              {isExpanded && (
                <div className="px-4 pb-4 pt-1 bg-accent/10 border-t border-dashed border-border/50">
                  <div className="rounded-lg border border-border/60 overflow-x-auto mt-2">
                    <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2 bg-accent/30 text-[10px] uppercase tracking-wider text-muted-foreground font-semibold min-w-[320px]">
                      <span>Producto</span>
                      <span className="text-center">Cant.</span>
                      <span className="text-right">Precio unit.</span>
                      <span className="text-right">Subtotal</span>
                    </div>
                    {op.items.map((item) => (
                      <div key={item.id} className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border/30 text-sm items-center hover:bg-accent/10 min-w-[320px]">
                        <ProductDisplay mode="table" name={item.productName} />
                        <span className="text-center text-muted-foreground tabular-nums">{item.quantity}</span>
                        <span className="text-right text-muted-foreground tabular-nums">{formatMoney(item.unitPrice, op.currency)}</span>
                        <span className="text-right font-semibold text-emerald-400 tabular-nums">{formatMoney(item.total, op.currency)}</span>
                      </div>
                    ))}
                    {op.isGrouped && (
                      <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border bg-accent/20 text-sm min-w-[320px]">
                        <span className="col-span-3 text-right font-medium text-muted-foreground pr-2">Total operación</span>
                        <span className="text-right font-bold text-base text-primary tabular-nums">{formatMoney(op.total, op.currency)}</span>
                      </div>
                    )}
                  </div>
                  <div className="flex justify-end mt-3" onClick={(e) => e.stopPropagation()}>
                    <SaleReceiptButton
                      op={op}
                      clientPhone={clientMap.get(op.clientId ?? "")?.phone}
                      clientFirstName={clientMap.get(op.clientId ?? "")?.name}
                    />
                  </div>
                </div>
              )}
            </div>
          )
        })}

        {/* Grand total footer */}
        {!loading && filtered.length > 0 && (
          <div className="flex items-center justify-between px-4 py-3 border-t border-border bg-accent/40">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Total ({filtered.length} op. en esta página)
            </span>
            <span className="text-base font-bold text-primary tabular-nums">
              {formatMoney(grandTotal)}
            </span>
          </div>
        )}
      </div>

      {/* Pagination bar */}
      <PaginationBar
        meta={meta}
        onPageChange={onPageChange}
        onSizeChange={onPageSizeChange}
        loading={loading}
        label="ventas"
      />
    </div>
  )
}
