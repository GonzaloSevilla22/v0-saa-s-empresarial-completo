"use client"

/**
 * PurchaseOperationsList
 *
 * Renders purchases grouped by operation_id — identical UX to SaleOperationsList.
 * Includes: date filter, CSV export, CSV import (same utilities as DataTable / Gastos).
 */

import { useState, useMemo, useCallback, useRef } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { groupPurchasesByOperation, type PurchaseOperation } from "@/lib/group-operations"
import { exportToCSV, parseCSV, readFileAsText } from "@/lib/excel"
import { formatMoney, formatDate } from "@/lib/format"
import type { Purchase } from "@/lib/types"
import {
  Plus,
  Trash2,
  ChevronDown,
  ChevronRight,
  ShoppingCart,
  Search,
  PackageOpen,
  Download,
  Upload,
  CalendarDays,
  X,
} from "lucide-react"
import { toast } from "sonner"

interface PurchaseOperationsListProps {
  purchases: Purchase[]
  onAdd: () => void
  onDeleteOperation: (op: PurchaseOperation) => Promise<void>
}

export function PurchaseOperationsList({
  purchases,
  onAdd,
  onDeleteOperation,
}: PurchaseOperationsListProps) {
  const [search, setSearch] = useState("")
  const [dateFrom, setDateFrom] = useState("")
  const [dateTo, setDateTo] = useState("")
  const [expandedKey, setExpandedKey] = useState<string | null>(null)
  const [deletingKey, setDeletingKey] = useState<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const isDateFilterActive = dateFrom || dateTo

  // ── Group, search and date filter ───────────────────────────────────────────
  const operations = useMemo(() => groupPurchasesByOperation(purchases), [purchases])

  const filtered = useMemo(() => {
    let list = operations
    const q = search.trim().toLowerCase()
    if (q) {
      list = list.filter((op) =>
        op.items.some((item) => item.productName.toLowerCase().includes(q)),
      )
    }
    if (dateFrom) list = list.filter((op) => op.date >= dateFrom)
    if (dateTo)   list = list.filter((op) => op.date <= dateTo)
    return list
  }, [operations, search, dateFrom, dateTo])

  // ── Totals ──────────────────────────────────────────────────────────────────
  const grandTotal = useMemo(
    () => filtered.reduce((sum, op) => sum + op.total, 0),
    [filtered],
  )

  // ── Export — one row per item (consistent with raw DB rows) ─────────────────
  function handleExport() {
    const rows = filtered.flatMap((op) =>
      op.items.map((item) => ({
        date:        item.date,
        productName: item.productName,
        quantity:    item.quantity,
        unitCost:    item.unitCost,
        total:       item.total,
        description: item.description ?? "",
        operationId: op.operationId ?? "",
      })),
    )
    exportToCSV(
      rows,
      [
        { key: "date",        header: "Fecha"        },
        { key: "productName", header: "Producto"     },
        { key: "quantity",    header: "Cantidad"     },
        { key: "unitCost",    header: "Costo unit."  },
        { key: "total",       header: "Total"        },
        { key: "description", header: "Descripción"  },
        { key: "operationId", header: "ID Operación" },
      ],
      "compras",
    )
    toast.success(`Exportadas ${rows.length} filas`)
  }

  // ── Import — same pattern as DataTable / Gastos ─────────────────────────────
  async function handleImport(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    try {
      const text = await readFileAsText(file)
      const rows = parseCSV(text, [
        { csvHeader: "Fecha",       key: "date"        },
        { csvHeader: "Producto",    key: "productName" },
        { csvHeader: "Cantidad",    key: "quantity"    },
        { csvHeader: "Costo unit.", key: "unitCost"    },
        { csvHeader: "Descripción", key: "description" },
      ])
      if (rows.length === 0) {
        toast.error("No se encontraron datos en el archivo")
        return
      }
      toast.success(`Importadas ${rows.length} filas — revisá y confirmá antes de guardar`)
      console.log("Importando compras:", rows)
    } catch {
      toast.error("Error al leer el archivo")
    }
    if (fileInputRef.current) fileInputRef.current.value = ""
  }

  // ── Handlers ────────────────────────────────────────────────────────────────
  const handleDelete = useCallback(
    async (e: React.MouseEvent, op: PurchaseOperation) => {
      e.stopPropagation()
      const label = op.isGrouped ? `esta operación (${op.items.length} ítems)` : "esta compra"
      if (!confirm(`¿Eliminar ${label}? Esta acción no se puede deshacer.`)) return
      setDeletingKey(op.key)
      try {
        await onDeleteOperation(op)
        toast.success(op.isGrouped ? `${op.items.length} registros eliminados` : "Compra eliminada")
      } catch (err: any) {
        toast.error(err.message || "Error al eliminar")
      } finally {
        setDeletingKey(null)
      }
    },
    [onDeleteOperation],
  )

  const toggleExpand = useCallback((key: string) => {
    setExpandedKey((prev) => (prev === key ? null : key))
  }, [])

  // ── Render ──────────────────────────────────────────────────────────────────
  return (
    <div className="flex flex-col gap-4">
      {/* Controls Bar */}
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        {/* Left: search + date filter */}
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Buscar por producto..."
              className="pl-9 bg-background border-border text-foreground"
            />
          </div>

          {/* Date filter — identical to DataTable / Gastos */}
          <Popover>
            <PopoverTrigger asChild>
              <Button
                variant="outline"
                size="sm"
                className={`shrink-0 border-border text-foreground ${isDateFilterActive ? "border-primary text-primary" : ""}`}
              >
                <CalendarDays className="h-4 w-4 mr-1" />
                Filtrar fechas
                {isDateFilterActive && (
                  <span className="ml-1.5 flex h-4 w-4 items-center justify-center rounded-full bg-primary text-[10px] text-primary-foreground">
                    1
                  </span>
                )}
              </Button>
            </PopoverTrigger>
            <PopoverContent className="w-72 bg-popover border-border" align="start">
              <div className="flex flex-col gap-3">
                <p className="text-sm font-medium text-foreground">Rango de fechas</p>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Desde</Label>
                  <Input
                    type="date"
                    value={dateFrom}
                    onChange={(e) => setDateFrom(e.target.value)}
                    className="bg-background border-border text-foreground"
                  />
                </div>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Hasta</Label>
                  <Input
                    type="date"
                    value={dateTo}
                    onChange={(e) => setDateTo(e.target.value)}
                    className="bg-background border-border text-foreground"
                  />
                </div>
                {isDateFilterActive && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="text-muted-foreground"
                    onClick={() => { setDateFrom(""); setDateTo("") }}
                  >
                    <X className="h-3 w-3 mr-1" />
                    Limpiar filtro
                  </Button>
                )}
              </div>
            </PopoverContent>
          </Popover>
        </div>

        {/* Right: import / export / add */}
        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">
            {filtered.length} operación{filtered.length !== 1 ? "es" : ""}
          </span>

          {/* Import */}
          <input
            type="file"
            ref={fileInputRef}
            accept=".csv,.txt"
            className="hidden"
            onChange={handleImport}
          />
          <Button
            variant="outline"
            size="sm"
            className="border-border text-foreground"
            onClick={() => fileInputRef.current?.click()}
          >
            <Upload className="h-4 w-4 mr-1" />
            Importar
          </Button>

          {/* Export */}
          <Button
            variant="outline"
            size="sm"
            className="border-border text-foreground"
            onClick={handleExport}
          >
            <Download className="h-4 w-4 mr-1" />
            Exportar
          </Button>

          {/* Add */}
          <Button onClick={onAdd} size="sm" className="gap-2">
            <Plus className="h-4 w-4" />
            Nueva compra
          </Button>
        </div>
      </div>

      {/* Table */}
      <div className="rounded-xl border border-border overflow-hidden">
        {/* Header row */}
        <div className="hidden sm:grid grid-cols-[120px_1fr_80px_120px_48px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Fecha</span>
          <span>Productos</span>
          <span className="text-center">Ítems</span>
          <span className="text-right">Total</span>
          <span />
        </div>

        {/* Empty state */}
        {filtered.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {search || isDateFilterActive
                ? "Sin resultados para esa búsqueda"
                : "No hay compras registradas"}
            </p>
            {!search && !isDateFilterActive && (
              <Button variant="outline" size="sm" onClick={onAdd} className="gap-2">
                <Plus className="h-4 w-4" />
                Registrar primera compra
              </Button>
            )}
          </div>
        )}

        {/* Operation rows */}
        {filtered.map((op) => {
          const isExpanded = expandedKey === op.key
          return (
            <div key={op.key} className="border-t border-border/50 first:border-t-0">
              {/* Main row */}
              <div
                role="button"
                tabIndex={0}
                onClick={() => toggleExpand(op.key)}
                onKeyDown={(e) => e.key === "Enter" && toggleExpand(op.key)}
                className="grid grid-cols-[120px_1fr_80px_120px_48px] gap-3 px-4 py-3 items-center cursor-pointer hover:bg-accent/20 transition-colors group"
                aria-expanded={isExpanded}
              >
                <span className="text-sm text-muted-foreground tabular-nums">
                  {formatDate(op.date)}
                </span>
                <div className="flex items-center gap-2 min-w-0">
                  {isExpanded
                    ? <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                    : <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0 group-hover:text-foreground transition-colors" />}
                  <span className="text-sm font-medium text-foreground truncate">
                    {op.items.map((i) => i.productName).join(" · ")}
                  </span>
                </div>
                <div className="flex justify-center">
                  {op.isGrouped ? (
                    <Badge variant="secondary" className="text-[10px] bg-cyan-500/15 text-cyan-400 border-cyan-500/25 border font-semibold">
                      <ShoppingCart className="h-2.5 w-2.5 mr-1" />
                      {op.items.length}
                    </Badge>
                  ) : (
                    <span className="text-sm text-muted-foreground">1</span>
                  )}
                </div>
                <span className="text-right text-sm font-bold text-cyan-400 tabular-nums">
                  {formatMoney(op.total)}
                </span>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  onClick={(e) => handleDelete(e, op)}
                  disabled={deletingKey === op.key}
                  className="h-8 w-8 text-muted-foreground hover:text-destructive hover:bg-destructive/10 transition-colors"
                  aria-label="Eliminar operación"
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </div>

              {/* Expanded detail */}
              {isExpanded && (
                <div className="px-4 pb-4 pt-1 bg-accent/10 border-t border-dashed border-border/50">
                  <div className="rounded-lg border border-border/60 overflow-hidden mt-2">
                    <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2 bg-accent/30 text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
                      <span>Producto</span>
                      <span className="text-center">Cant.</span>
                      <span className="text-right">Costo unit.</span>
                      <span className="text-right">Subtotal</span>
                    </div>
                    {op.items.map((item) => (
                      <div key={item.id} className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border/30 text-sm items-center hover:bg-accent/10 transition-colors">
                        <span className="font-medium text-foreground">{item.productName}</span>
                        <span className="text-center text-muted-foreground tabular-nums">{item.quantity}</span>
                        <span className="text-right text-muted-foreground tabular-nums">{formatMoney(item.unitCost)}</span>
                        <span className="text-right font-semibold text-cyan-400 tabular-nums">{formatMoney(item.total)}</span>
                      </div>
                    ))}
                    {op.description && (
                      <div className="px-3 py-2 border-t border-border/30 text-xs text-muted-foreground italic">
                        📝 {op.description}
                      </div>
                    )}
                    {op.isGrouped && (
                      <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border bg-accent/20 text-sm">
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

        {/* Grand total footer */}
        {filtered.length > 0 && (
          <div className="flex items-center justify-between px-4 py-3 border-t border-border bg-accent/40">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Total ({filtered.length} op.)
            </span>
            <span className="text-base font-bold text-primary tabular-nums">
              {formatMoney(grandTotal)}
            </span>
          </div>
        )}
      </div>
    </div>
  )
}
