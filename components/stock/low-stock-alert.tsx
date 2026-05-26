"use client"

/**
 * LowStockAlert — collapsible alert panel for products below minimum stock.
 *
 * Performance strategy:
 *   Incremental rendering — only the first INITIAL_PAGE_SIZE rows are mounted;
 *   each "Ver más" click appends PAGE_INCREMENT more. Combined with a
 *   fixed-height ScrollArea, the browser never paints more than ~20–40 rows
 *   at once, handling tens of thousands of products without freezing.
 *
 *   No external library needed (no react-window): for typical ERP datasets
 *   (< 10 000 alerts) incremental slice rendering is faster to ship and
 *   equally smooth in practice.
 *
 * Severity inside the low-stock set (all have stock ≤ minStock):
 *   crítico  — stock = 0       (out of stock)
 *   bajo     — 0 < stock < minStock
 *   moderado — stock = minStock (exactly at the limit)
 */

import { memo, useState, useMemo, useCallback } from "react"
import * as Collapsible from "@radix-ui/react-collapsible"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Input }      from "@/components/ui/input"
import { Button }     from "@/components/ui/button"
import {
  AlertTriangle, ChevronDown, Search,
  Package, ArrowUp, ArrowDown, Pencil, X,
} from "lucide-react"
import { cn } from "@/lib/utils"
import type { Product } from "@/lib/types"

// ─── Constants ────────────────────────────────────────────────────────────────

const INITIAL_PAGE_SIZE = 20
const PAGE_INCREMENT    = 20

// ─── Severity ─────────────────────────────────────────────────────────────────

type Severity    = "critico" | "bajo" | "moderado"
type FilterLevel = "all" | Severity
type SortDir     = "asc" | "desc"

function getSeverity(stock: number, minStock: number): Severity {
  if (stock === 0)        return "critico"
  if (stock < minStock)   return "bajo"
  return "moderado"
}

const SEV = {
  critico: {
    label:      "Crítico",
    dot:        "bg-red-500",
    glow:       "shadow-[0_0_5px_rgba(239,68,68,0.55)]",
    badge:      "bg-red-500/15 text-red-400 border-red-500/25",
    headerText: "text-red-400",
    headerDot:  "bg-red-500",
  },
  bajo: {
    label:      "Bajo",
    dot:        "bg-yellow-500",
    glow:       "shadow-[0_0_5px_rgba(234,179,8,0.55)]",
    badge:      "bg-yellow-500/15 text-yellow-400 border-yellow-500/25",
    headerText: "text-yellow-400",
    headerDot:  "bg-yellow-500",
  },
  moderado: {
    label:      "Moderado",
    dot:        "bg-orange-400",
    glow:       "shadow-[0_0_5px_rgba(251,146,60,0.55)]",
    badge:      "bg-orange-500/15 text-orange-400 border-orange-500/25",
    headerText: "text-orange-400",
    headerDot:  "bg-orange-400",
  },
} as const

// ─── SeverityBadge ────────────────────────────────────────────────────────────

function SeverityBadge({ severity }: { severity: Severity }) {
  const s = SEV[severity]
  return (
    <span className={cn(
      "inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px] font-medium whitespace-nowrap",
      s.badge,
    )}>
      <span className={cn("h-1.5 w-1.5 rounded-full shrink-0", s.dot, s.glow)} />
      {s.label}
    </span>
  )
}

// ─── StockBar ─────────────────────────────────────────────────────────────────

function StockBar({ stock, minStock }: { stock: number; minStock: number }) {
  const pct      = minStock > 0 ? Math.min(100, Math.round((stock / minStock) * 100)) : 0
  const severity = getSeverity(stock, minStock)
  const fill     =
    severity === "critico" ? "bg-red-500"
    : severity === "bajo"  ? "bg-yellow-500"
    : "bg-orange-400"

  return (
    <div className="flex items-center gap-2 min-w-[90px]">
      <div className="h-1.5 flex-1 rounded-full bg-muted overflow-hidden">
        <div
          className={cn("h-full rounded-full transition-all duration-500", fill)}
          style={{ width: `${pct}%` }}
        />
      </div>
      <span className="text-[11px] tabular-nums text-muted-foreground shrink-0 font-mono">
        {stock}/{minStock}
      </span>
    </div>
  )
}

// ─── ProductRow ───────────────────────────────────────────────────────────────

interface ProductRowProps {
  product: Product
  onEdit?: (p: Product) => void
}

const ProductRow = memo(function ProductRow({ product, onEdit }: ProductRowProps) {
  const severity = getSeverity(product.stock, product.minStock)
  const s        = SEV[severity]

  return (
    <div className="flex items-center gap-3 px-3 py-2.5 rounded-md hover:bg-accent/40 transition-colors group">
      {/* Severity dot */}
      <span className={cn("h-2 w-2 rounded-full shrink-0", s.dot, s.glow)} />

      {/* Name + SKU */}
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium text-foreground truncate leading-tight">
          {product.name}
        </p>
        {product.sku && (
          <p className="text-[11px] text-muted-foreground leading-tight mt-0.5">
            SKU: <span className="font-mono">{product.sku}</span>
          </p>
        )}
      </div>

      {/* Stock bar — hidden on mobile */}
      <div className="hidden sm:block w-28 shrink-0">
        <StockBar stock={product.stock} minStock={product.minStock} />
      </div>

      {/* Severity badge */}
      <div className="shrink-0">
        <SeverityBadge severity={severity} />
      </div>

      {/* Edit action */}
      {onEdit && (
        <Button
          variant="ghost"
          size="icon"
          className="h-7 w-7 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity text-muted-foreground hover:text-foreground"
          onClick={() => onEdit(product)}
          aria-label={`Editar ${product.name}`}
        >
          <Pencil className="h-3.5 w-3.5" />
        </Button>
      )}
    </div>
  )
})

// ─── FilterPill ───────────────────────────────────────────────────────────────

interface FilterPillProps {
  level:   FilterLevel
  active:  boolean
  count?:  number
  onClick: () => void
}

function FilterPill({ level, active, count, onClick }: FilterPillProps) {
  const labelMap: Record<FilterLevel, string> = {
    all:      "Todos",
    critico:  "Crítico",
    bajo:     "Bajo",
    moderado: "Moderado",
  }
  const activeStyle =
    level === "all"
      ? "bg-foreground/10 border-foreground/20 text-foreground"
      : cn(SEV[level as Severity].badge, "border")

  return (
    <button
      onClick={onClick}
      className={cn(
        "h-7 px-2.5 rounded text-[11px] font-medium border transition-colors",
        active
          ? activeStyle
          : "border-transparent text-muted-foreground hover:text-foreground hover:border-border",
      )}
    >
      {labelMap[level]}
      {count !== undefined && (
        <span className="ml-1 text-[10px] opacity-60">{count}</span>
      )}
    </button>
  )
}

// ─── LowStockAlert (main) ────────────────────────────────────────────────────

export interface LowStockAlertProps {
  products:     Product[]
  onEdit?:      (p: Product) => void
  defaultOpen?: boolean
}

export function LowStockAlert({
  products,
  onEdit,
  defaultOpen = false,
}: LowStockAlertProps) {
  const [open,         setOpen]         = useState(defaultOpen)
  const [search,       setSearch]       = useState("")
  const [filterLevel,  setFilterLevel]  = useState<FilterLevel>("all")
  const [sortDir,      setSortDir]      = useState<SortDir>("asc")
  const [visibleCount, setVisibleCount] = useState(INITIAL_PAGE_SIZE)

  // ── Severity counts (summary bar) ────────────────────────────────────────
  const counts = useMemo(() => {
    const c = { critico: 0, bajo: 0, moderado: 0 }
    for (const p of products) c[getSeverity(p.stock, p.minStock)]++
    return c
  }, [products])

  // ── Filter + sort ─────────────────────────────────────────────────────────
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    let list = q
      ? products.filter(
          p =>
            p.name.toLowerCase().includes(q) ||
            (p.sku ?? "").toLowerCase().includes(q),
        )
      : products

    if (filterLevel !== "all") {
      list = list.filter(p => getSeverity(p.stock, p.minStock) === filterLevel)
    }

    return [...list].sort((a, b) =>
      sortDir === "asc" ? a.stock - b.stock : b.stock - a.stock,
    )
  }, [products, search, filterLevel, sortDir])

  const visible = filtered.slice(0, visibleCount)
  const hasMore = visibleCount < filtered.length

  // ── Handlers ─────────────────────────────────────────────────────────────
  const loadMore = useCallback(() => {
    setVisibleCount(prev => prev + PAGE_INCREMENT)
  }, [])

  const handleOpenChange = useCallback((v: boolean) => {
    setOpen(v)
    if (!v) {
      setSearch("")
      setFilterLevel("all")
      setVisibleCount(INITIAL_PAGE_SIZE)
    }
  }, [])

  const handleSearchChange = useCallback((v: string) => {
    setSearch(v)
    setVisibleCount(INITIAL_PAGE_SIZE)
  }, [])

  const handleFilterChange = useCallback((level: FilterLevel) => {
    setFilterLevel(level)
    setVisibleCount(INITIAL_PAGE_SIZE)
  }, [])

  const toggleSort = useCallback(() => {
    setSortDir(prev => (prev === "asc" ? "desc" : "asc"))
  }, [])

  // ── Nothing to show ───────────────────────────────────────────────────────
  if (products.length === 0) return null

  return (
    <Collapsible.Root
      open={open}
      onOpenChange={handleOpenChange}
      className="rounded-lg border border-yellow-500/25 bg-yellow-500/5 overflow-hidden"
    >
      {/* ── Summary trigger ─────────────────────────────────────────────── */}
      <Collapsible.Trigger asChild>
        <button className="w-full flex items-center justify-between px-4 py-3 text-left hover:bg-yellow-500/5 transition-colors">
          <div className="flex items-center gap-3 min-w-0">
            <AlertTriangle className="h-4 w-4 text-yellow-400 shrink-0" />
            <span className="text-sm font-semibold text-yellow-300 shrink-0">
              {products.length.toLocaleString()} producto{products.length !== 1 ? "s" : ""} con stock bajo
            </span>

            {/* Severity pills — desktop only */}
            <div className="hidden md:flex items-center gap-3">
              {counts.critico > 0 && (
                <span className={cn("inline-flex items-center gap-1.5 text-[11px]", SEV.critico.headerText)}>
                  <span className={cn("h-1.5 w-1.5 rounded-full", SEV.critico.headerDot)} />
                  {counts.critico.toLocaleString()} crítico{counts.critico !== 1 ? "s" : ""}
                </span>
              )}
              {counts.bajo > 0 && (
                <span className={cn("inline-flex items-center gap-1.5 text-[11px]", SEV.bajo.headerText)}>
                  <span className={cn("h-1.5 w-1.5 rounded-full", SEV.bajo.headerDot)} />
                  {counts.bajo.toLocaleString()} bajo{counts.bajo !== 1 ? "s" : ""}
                </span>
              )}
              {counts.moderado > 0 && (
                <span className={cn("inline-flex items-center gap-1.5 text-[11px]", SEV.moderado.headerText)}>
                  <span className={cn("h-1.5 w-1.5 rounded-full", SEV.moderado.headerDot)} />
                  {counts.moderado.toLocaleString()} moderado{counts.moderado !== 1 ? "s" : ""}
                </span>
              )}
            </div>
          </div>

          <div className="flex items-center gap-2 shrink-0 ml-2">
            <span className="text-xs text-muted-foreground hidden sm:block">
              {open ? "Ocultar" : "Ver detalles"}
            </span>
            <ChevronDown
              className={cn(
                "h-4 w-4 text-muted-foreground transition-transform duration-200",
                open && "rotate-180",
              )}
            />
          </div>
        </button>
      </Collapsible.Trigger>

      {/* ── Expandable content ──────────────────────────────────────────── */}
      <Collapsible.Content className="overflow-hidden data-[state=open]:animate-collapsible-down data-[state=closed]:animate-collapsible-up">
        <div className="border-t border-yellow-500/15">

          {/* Controls bar */}
          <div className="flex flex-col sm:flex-row gap-2 px-3 py-2.5 bg-background/40">
            {/* Search */}
            <div className="relative flex-1">
              <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground pointer-events-none" />
              <Input
                value={search}
                onChange={e => handleSearchChange(e.target.value)}
                placeholder="Buscar por nombre o SKU…"
                className="pl-8 h-8 text-xs bg-background border-border"
              />
              {search && (
                <button
                  onClick={() => handleSearchChange("")}
                  className="absolute right-2.5 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground transition-colors"
                  aria-label="Limpiar búsqueda"
                >
                  <X className="h-3.5 w-3.5" />
                </button>
              )}
            </div>

            {/* Filter pills */}
            <div className="flex items-center gap-1 flex-wrap">
              {(["all", "critico", "bajo", "moderado"] as const).map(level => (
                <FilterPill
                  key={level}
                  level={level}
                  active={filterLevel === level}
                  count={level !== "all" ? counts[level] : undefined}
                  onClick={() => handleFilterChange(level)}
                />
              ))}
            </div>

            {/* Sort toggle */}
            <Button
              variant="ghost"
              size="sm"
              className="h-8 px-2.5 text-xs gap-1.5 text-muted-foreground hover:text-foreground shrink-0"
              onClick={toggleSort}
              title={sortDir === "asc" ? "Ordenar: menor stock primero" : "Ordenar: mayor stock primero"}
            >
              {sortDir === "asc"
                ? <ArrowUp className="h-3.5 w-3.5" />
                : <ArrowDown className="h-3.5 w-3.5" />
              }
              <span className="hidden sm:inline">Stock</span>
            </Button>
          </div>

          {/* Result count */}
          <div className="px-4 py-1 text-[11px] text-muted-foreground border-t border-border/40 flex items-center justify-between">
            <span>
              {filtered.length !== products.length
                ? `${filtered.length.toLocaleString()} de ${products.length.toLocaleString()} productos`
                : `${products.length.toLocaleString()} producto${products.length !== 1 ? "s" : ""}`}
            </span>
            {hasMore && (
              <span className="text-[10px] opacity-60">
                mostrando {visibleCount} de {filtered.length.toLocaleString()}
              </span>
            )}
          </div>

          {/* Scrollable product list */}
          <ScrollArea className="h-[320px]">
            <div className="px-2 py-1 pb-2">
              {visible.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-14 text-muted-foreground gap-2">
                  <Package className="h-8 w-8 opacity-25" />
                  <p className="text-sm">Sin resultados para esa búsqueda</p>
                </div>
              ) : (
                <>
                  {visible.map(p => (
                    <ProductRow key={p.id} product={p} onEdit={onEdit} />
                  ))}

                  {/* Load more */}
                  {hasMore && (
                    <button
                      onClick={loadMore}
                      className="w-full mt-1 py-2.5 text-xs text-muted-foreground hover:text-foreground transition-colors border-t border-border/40 text-center"
                    >
                      Ver {Math.min(PAGE_INCREMENT, filtered.length - visibleCount).toLocaleString()} más
                      <span className="ml-1.5 text-[10px] opacity-50">
                        ({visibleCount} / {filtered.length.toLocaleString()})
                      </span>
                    </button>
                  )}
                </>
              )}
            </div>
          </ScrollArea>
        </div>
      </Collapsible.Content>
    </Collapsible.Root>
  )
}
