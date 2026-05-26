"use client"

/**
 * PurchaseOperationsList — paginated version.
 * Mirror of SaleOperationsList — see that file for the data-flow rationale.
 */

import { useState, useMemo, useCallback } from "react"
import { Button }   from "@/components/ui/button"
import { Input }    from "@/components/ui/input"
import { Label }    from "@/components/ui/label"
import { Badge }    from "@/components/ui/badge"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { groupPurchasesByOperation, type PurchaseOperation } from "@/lib/group-operations"
import { exportToCSV } from "@/lib/excel"
import { formatMoney, formatDate } from "@/lib/format"
import type { Purchase } from "@/lib/types"
import type { PaginationMeta, PageSizeOption } from "@/lib/pagination-utils"
import {
  Plus, Trash2, Pencil, ChevronDown, ChevronRight,
  ShoppingCart, Search, PackageOpen, Download, CalendarDays, X, Loader2,
} from "lucide-react"
import { toast } from "sonner"

interface PurchaseOperationsListProps {
  purchases:       Purchase[]
  meta:            PaginationMeta
  loading:         boolean
  error:           string | null
  dateFrom:        string
  setDateFrom:     (v: string) => void
  dateTo:          string
  setDateTo:       (v: string) => void
  clearFilters:    () => void
  onPageChange:    (page: number) => void
  onPageSizeChange:(size: PageSizeOption) => void
  onAdd:           () => void
  onDeleteOperation:(op: PurchaseOperation) => Promise<void>
  onEditOperation?: (op: PurchaseOperation) => void
  onRefetch:       () => void
}

export function PurchaseOperationsList({
  purchases, meta, loading, error,
  dateFrom, setDateFrom, dateTo, setDateTo, clearFilters,
  onPageChange, onPageSizeChange,
  onAdd, onDeleteOperation, onEditOperation, onRefetch,
}: PurchaseOperationsListProps) {
  const [search,      setSearch]      = useState("")
  const [expandedKey, setExpandedKey] = useState<string | null>(null)
  const [deletingKey, setDeletingKey] = useState<string | null>(null)

  const isDateFilterActive = !!(dateFrom || dateTo)

  const operations = useMemo(() => groupPurchasesByOperation(purchases), [purchases])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return operations
    return operations.filter((op) =>
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
        date: item.date, productName: item.productName,
        quantity: item.quantity, unitCost: item.unitCost,
        total: item.total, description: item.description ?? "",
        operationId: op.operationId ?? "",
      })),
    )
    exportToCSV(rows, [
      { key: "date",        header: "Fecha"        },
      { key: "productName", header: "Producto"     },
      { key: "quantity",    header: "Cantidad"     },
      { key: "unitCost",    header: "Costo unit."  },
      { key: "total",       header: "Total"        },
      { key: "description", header: "Descripción"  },
      { key: "operationId", header: "ID Operación" },
    ], "compras")
    toast.success(`Exportadas ${rows.length} filas`)
  }

  const handleDelete = useCallback(
    async (e: React.MouseEvent, op: PurchaseOperation) => {
      e.stopPropagation()
      const label = op.isGrouped ? `esta operación (${op.items.length} ítems)` : "esta compra"
      if (!confirm(`¿Eliminar ${label}? Esta acción no se puede deshacer.`)) return
      setDeletingKey(op.key)
      try {
        await onDeleteOperation(op)
        toast.success(op.isGrouped ? `${op.items.length} registros eliminados` : "Compra eliminada")
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
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Buscar en esta página..."
              className="pl-9 bg-background border-border text-foreground"
            />
          </div>

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
            <Plus className="h-4 w-4" />Nueva compra
          </Button>
        </div>
      </div>

      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error}
        </div>
      )}

      {/* Table */}
      <div className="rounded-xl border border-border overflow-hidden">
        <div className="hidden sm:grid grid-cols-[120px_1fr_80px_120px_48px_48px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Fecha</span><span>Productos</span>
          <span className="text-center">Ítems</span>
          <span className="text-right">Total</span>
          <span /><span />
        </div>

        {/* Skeleton */}
        {loading && purchases.length === 0 && (
          <div className="flex flex-col">
            {Array.from({ length: 5 }).map((_, i) => (
              <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                <div className="hidden sm:grid grid-cols-[120px_1fr_80px_120px_48px_48px] gap-3 items-center">
                  <div className="h-3.5 w-20 rounded bg-accent animate-pulse" />
                  <div className="h-3.5 w-40 rounded bg-accent animate-pulse" />
                  <div className="h-3.5 w-8 rounded bg-accent animate-pulse mx-auto" />
                  <div className="h-3.5 w-20 rounded bg-accent animate-pulse ml-auto" />
                </div>
                <div className="sm:hidden h-14 rounded bg-accent animate-pulse" />
              </div>
            ))}
          </div>
        )}

        {!loading && filtered.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {search || isDateFilterActive ? "Sin resultados para esa búsqueda" : "No hay compras registradas"}
            </p>
            {!search && !isDateFilterActive && (
              <Button variant="outline" size="sm" onClick={onAdd} className="gap-2">
                <Plus className="h-4 w-4" />Registrar primera compra
              </Button>
            )}
          </div>
        )}

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
                        <Badge variant="secondary" className="text-[10px] bg-cyan-500/15 text-cyan-400 border-cyan-500/25 border font-semibold">
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
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 min-w-0">
                      {isExpanded ? <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                        : <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0 group-hover:text-foreground" />}
                      <span className="text-sm font-medium text-foreground truncate">
                        {op.items.map((i) => i.productName).join(" · ")}
                      </span>
                    </div>
                    <span className="text-sm font-bold text-cyan-400 tabular-nums shrink-0">{formatMoney(op.total)}</span>
                  </div>
                </div>

                {/* Desktop */}
                <div className="hidden sm:grid grid-cols-[120px_1fr_80px_120px_48px_48px] gap-3 px-4 py-3 items-center">
                  <span className="text-sm text-muted-foreground tabular-nums">{formatDate(op.date)}</span>
                  <div className="flex items-center gap-2 min-w-0">
                    {isExpanded ? <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                      : <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0 group-hover:text-foreground" />}
                    <span className="text-sm font-medium text-foreground truncate">
                      {op.items.map((i) => i.productName).join(" · ")}
                    </span>
                  </div>
                  <div className="flex justify-center">
                    {op.isGrouped
                      ? <Badge variant="secondary" className="text-[10px] bg-cyan-500/15 text-cyan-400 border-cyan-500/25 border font-semibold">
                          <ShoppingCart className="h-2.5 w-2.5 mr-1" />{op.items.length}
                        </Badge>
                      : <span className="text-sm text-muted-foreground">1</span>
                    }
                  </div>
                  <span className="text-right text-sm font-bold text-cyan-400 tabular-nums">{formatMoney(op.total)}</span>
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

              {isExpanded && (
                <div className="px-4 pb-4 pt-1 bg-accent/10 border-t border-dashed border-border/50">
                  <div className="rounded-lg border border-border/60 overflow-x-auto mt-2">
                    <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2 bg-accent/30 text-[10px] uppercase tracking-wider text-muted-foreground font-semibold min-w-[320px]">
                      <span>Producto</span>
                      <span className="text-center">Cant.</span>
                      <span className="text-right">Costo unit.</span>
                      <span className="text-right">Subtotal</span>
                    </div>
                    {op.items.map((item) => (
                      <div key={item.id} className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border/30 text-sm items-center hover:bg-accent/10 min-w-[320px]">
                        <span className="font-medium text-foreground">{item.productName}</span>
                        <span className="text-center text-muted-foreground tabular-nums">{item.quantity}</span>
                        <span className="text-right text-muted-foreground tabular-nums">{formatMoney(item.unitCost)}</span>
                        <span className="text-right font-semibold text-cyan-400 tabular-nums">{formatMoney(item.total)}</span>
                      </div>
                    ))}
                    {op.description && (
                      <div className="px-3 py-2 border-t border-border/30 text-xs text-muted-foreground italic min-w-[320px]">
                        📝 {op.description}
                      </div>
                    )}
                    {op.isGrouped && (
                      <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border bg-accent/20 text-sm min-w-[320px]">
                        <span className="col-span-3 text-right font-medium text-muted-foreground pr-2">Total operación</span>
                        <span className="text-right font-bold text-base text-primary tabular-nums">{formatMoney(op.total)}</span>
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          )
        })}

        {!loading && filtered.length > 0 && (
          <div className="flex items-center justify-between px-4 py-3 border-t border-border bg-accent/40">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Total ({filtered.length} op. en esta página)
            </span>
            <span className="text-base font-bold text-primary tabular-nums">{formatMoney(grandTotal)}</span>
          </div>
        )}
      </div>

      <PaginationBar
        meta={meta}
        onPageChange={onPageChange}
        onSizeChange={onPageSizeChange}
        loading={loading}
        label="compras"
      />
    </div>
  )
}
