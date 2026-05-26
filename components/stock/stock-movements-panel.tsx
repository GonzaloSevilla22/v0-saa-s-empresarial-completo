"use client"

/**
 * StockMovementsPanel
 *
 * Collapsible audit-log panel showing inventory movements.
 * Fetches directly from the `stock_movements` table (with products join)
 * using paginated queries to handle large datasets efficiently.
 *
 * Features:
 *   - Collapsible header with summary stats (total movements, last 30 d)
 *   - Filter by movement type (all / inbound / outbound / adjustments)
 *   - Per-product filter (optional product selector)
 *   - Incremental rendering — "Ver más" loads 20 rows at a time
 *   - Export to CSV
 */

import { useState, useEffect, useCallback, useMemo, memo } from "react"
import { createClient } from "@/lib/supabase/client"
import * as Collapsible from "@radix-ui/react-collapsible"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import {
  ChevronDown, ChevronRight, History, ArrowUpCircle, ArrowDownCircle,
  ClipboardList, AlertTriangle, Wrench, Timer, ArrowRightLeft,
  ShoppingCart, Store, RefreshCw, Download, Loader2,
} from "lucide-react"
import type { StockMovement, MovementType } from "@/lib/types"
import { cn } from "@/lib/utils"
import { format, parseISO, subDays } from "date-fns"
import { es } from "date-fns/locale"

// ── Movement metadata ────────────────────────────────────────────────────────

interface MovementMeta {
  label:  string
  icon:   React.ReactNode
  color:  string  // text-* class
  bg:     string  // bg-*/border-* classes for badge
  inbound: boolean | null  // true = inbound, false = outbound, null = neutral
}

const MOVEMENT_META: Record<MovementType, MovementMeta> = {
  purchase:        { label: "Compra",               icon: <ShoppingCart className="h-3.5 w-3.5" />, color: "text-emerald-400", bg: "bg-emerald-500/15 border-emerald-500/25 text-emerald-400", inbound: true  },
  sale:            { label: "Venta",                icon: <Store         className="h-3.5 w-3.5" />, color: "text-blue-400",    bg: "bg-blue-500/15 border-blue-500/25 text-blue-400",           inbound: false },
  adjustment:      { label: "Ajuste",               icon: <ArrowUpCircle className="h-3.5 w-3.5" />, color: "text-yellow-400",  bg: "bg-yellow-500/15 border-yellow-500/25 text-yellow-400",     inbound: null  },
  return:          { label: "Devolución",           icon: <RefreshCw     className="h-3.5 w-3.5" />, color: "text-teal-400",    bg: "bg-teal-500/15 border-teal-500/25 text-teal-400",           inbound: true  },
  initial:         { label: "Stock inicial",        icon: <ArrowUpCircle className="h-3.5 w-3.5" />, color: "text-emerald-400", bg: "bg-emerald-500/15 border-emerald-500/25 text-emerald-400",  inbound: true  },
  sale_return:     { label: "Dev. venta",           icon: <RefreshCw     className="h-3.5 w-3.5" />, color: "text-blue-300",    bg: "bg-blue-500/10 border-blue-500/20 text-blue-300",           inbound: true  },
  purchase_return: { label: "Dev. compra",          icon: <RefreshCw     className="h-3.5 w-3.5" />, color: "text-emerald-300", bg: "bg-emerald-500/10 border-emerald-500/20 text-emerald-300",  inbound: false },
  physical_count:  { label: "Conteo físico",        icon: <ClipboardList className="h-3.5 w-3.5" />, color: "text-sky-400",     bg: "bg-sky-500/15 border-sky-500/25 text-sky-400",              inbound: null  },
  loss:            { label: "Pérdida / Robo",       icon: <AlertTriangle className="h-3.5 w-3.5" />, color: "text-red-400",     bg: "bg-red-500/15 border-red-500/25 text-red-400",              inbound: false },
  damage:          { label: "Daño / Merma",         icon: <Wrench        className="h-3.5 w-3.5" />, color: "text-orange-400",  bg: "bg-orange-500/15 border-orange-500/25 text-orange-400",     inbound: false },
  expiry:          { label: "Vencimiento",          icon: <Timer         className="h-3.5 w-3.5" />, color: "text-purple-400",  bg: "bg-purple-500/15 border-purple-500/25 text-purple-400",     inbound: false },
  transfer_in:     { label: "Transferencia ent.",   icon: <ArrowRightLeft className="h-3.5 w-3.5" />, color: "text-teal-400",   bg: "bg-teal-500/15 border-teal-500/25 text-teal-400",           inbound: true  },
  transfer_out:    { label: "Transferencia sal.",   icon: <ArrowRightLeft className="h-3.5 w-3.5 rotate-90" />, color: "text-slate-400", bg: "bg-slate-500/15 border-slate-500/25 text-slate-400", inbound: false },
}

// ── Filter tabs ──────────────────────────────────────────────────────────────

type FilterTab = "all" | "inbound" | "outbound" | "adjustments"

const INBOUND_TYPES:     MovementType[] = ["purchase", "return", "initial", "sale_return", "transfer_in"]
const OUTBOUND_TYPES:    MovementType[] = ["sale", "purchase_return", "loss", "damage", "expiry", "transfer_out"]
const ADJUSTMENT_TYPES:  MovementType[] = ["adjustment", "physical_count"]

// ── Row mapping ──────────────────────────────────────────────────────────────

function mapMovement(row: any): StockMovement {
  return {
    id:             row.id,
    userId:         row.user_id,
    productId:      row.product_id,
    productName:    row.products?.name ?? "Producto eliminado",
    type:           row.type as MovementType,
    quantityDelta:  Number(row.quantity_delta),
    quantityBefore: row.quantity_before != null ? Number(row.quantity_before) : undefined,
    quantityAfter:  row.quantity_after  != null ? Number(row.quantity_after)  : undefined,
    reason:         row.reason  ?? undefined,
    notes:          row.notes   ?? undefined,
    referenceId:    row.reference_id   ?? undefined,
    referenceType:  row.reference_type ?? undefined,
    performedBy:    row.performed_by   ?? undefined,
    metadata:       row.metadata       ?? undefined,
    createdAt:      row.created_at,
  }
}

// ── Single row ────────────────────────────────────────────────────────────────

const MovementRow = memo(function MovementRow({ m }: { m: StockMovement }) {
  const meta = MOVEMENT_META[m.type] ?? MOVEMENT_META.adjustment
  const delta = m.quantityDelta
  const isPos = delta > 0

  return (
    <div className="flex items-start gap-3 py-2.5 px-1 border-b border-border/50 last:border-0 group">
      {/* Date */}
      <div className="w-[84px] shrink-0 pt-0.5">
        <p className="text-[11px] text-muted-foreground tabular-nums leading-tight">
          {format(parseISO(m.createdAt), "dd MMM yyyy", { locale: es })}
        </p>
        <p className="text-[10px] text-muted-foreground/60 tabular-nums">
          {format(parseISO(m.createdAt), "HH:mm")}
        </p>
      </div>

      {/* Type badge */}
      <div className="w-[120px] shrink-0 pt-0.5">
        <span className={cn(
          "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[11px] font-medium border",
          meta.bg,
        )}>
          {meta.icon}
          {meta.label}
        </span>
      </div>

      {/* Product */}
      <div className="flex-1 min-w-0 pt-0.5">
        <p className="text-sm font-medium text-foreground truncate">{m.productName}</p>
        {(m.reason || m.notes) && (
          <p className="text-xs text-muted-foreground truncate mt-0.5">
            {m.reason ?? m.notes}
          </p>
        )}
      </div>

      {/* Before → After */}
      {m.quantityBefore != null && m.quantityAfter != null && (
        <div className="hidden sm:flex items-center gap-1 shrink-0 text-xs text-muted-foreground tabular-nums pt-0.5">
          <span>{m.quantityBefore}</span>
          <span className="text-muted-foreground/40">→</span>
          <span>{m.quantityAfter}</span>
        </div>
      )}

      {/* Delta */}
      <div className={cn(
        "shrink-0 text-sm font-semibold tabular-nums pt-0.5 w-16 text-right",
        isPos ? "text-emerald-400" : "text-red-400",
      )}>
        {isPos ? "+" : ""}{delta}
      </div>
    </div>
  )
})

// ── CSV export ────────────────────────────────────────────────────────────────

function exportCsv(movements: StockMovement[]) {
  const header = ["Fecha", "Hora", "Tipo", "Producto", "Delta", "Antes", "Después", "Motivo", "Notas"]
  const rows = movements.map((m) => [
    format(parseISO(m.createdAt), "dd/MM/yyyy"),
    format(parseISO(m.createdAt), "HH:mm"),
    MOVEMENT_META[m.type]?.label ?? m.type,
    m.productName ?? "",
    m.quantityDelta,
    m.quantityBefore ?? "",
    m.quantityAfter  ?? "",
    m.reason ?? "",
    m.notes  ?? "",
  ])
  const csv = [header, ...rows]
    .map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(","))
    .join("\n")
  const blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8;" })
  const url  = URL.createObjectURL(blob)
  const a    = Object.assign(document.createElement("a"), {
    href: url, download: `movimientos_stock_${format(new Date(), "yyyyMMdd")}.csv`,
  })
  a.click()
  URL.revokeObjectURL(url)
}

// ── Main component ────────────────────────────────────────────────────────────

const PAGE_SIZE = 30

interface StockMovementsPanelProps {
  /** Restrict display to movements for a specific product. */
  productId?: string
}

export function StockMovementsPanel({ productId }: StockMovementsPanelProps) {
  const supabase = createClient()

  const [open,       setOpen]       = useState(false)
  const [movements,  setMovements]  = useState<StockMovement[]>([])
  const [loading,    setLoading]    = useState(false)
  const [hasMore,    setHasMore]    = useState(true)
  const [page,       setPage]       = useState(0)
  const [filter,     setFilter]     = useState<FilterTab>("all")
  const [search,     setSearch]     = useState("")

  // ── Fetch page ────────────────────────────────────────────────────────────
  const fetchPage = useCallback(async (reset: boolean) => {
    setLoading(true)
    const from = reset ? 0 : page * PAGE_SIZE
    const to   = from + PAGE_SIZE - 1

    let query = supabase
      .from("stock_movements")
      .select("*, products(name)")
      .order("created_at", { ascending: false })
      .range(from, to)

    if (productId) {
      query = query.eq("product_id", productId)
    }

    const { data, error } = await query

    if (!error && data) {
      const mapped = data.map(mapMovement)
      setMovements((prev) => reset ? mapped : [...prev, ...mapped])
      setHasMore(data.length === PAGE_SIZE)
      if (!reset) setPage((p) => p + 1)
      else setPage(1)
    }
    setLoading(false)
  }, [supabase, page, productId])

  // ── Fetch on open ────────────────────────────────────────────────────────
  useEffect(() => {
    if (open && movements.length === 0) {
      fetchPage(true)
    }
  }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  // ── Client-side filter + search ──────────────────────────────────────────
  const filtered = useMemo(() => {
    let list = movements

    if (filter === "inbound")     list = list.filter((m) => INBOUND_TYPES.includes(m.type))
    if (filter === "outbound")    list = list.filter((m) => OUTBOUND_TYPES.includes(m.type))
    if (filter === "adjustments") list = list.filter((m) => ADJUSTMENT_TYPES.includes(m.type))

    if (search.trim()) {
      const q = search.trim().toLowerCase()
      list = list.filter(
        (m) =>
          (m.productName ?? "").toLowerCase().includes(q) ||
          (m.reason      ?? "").toLowerCase().includes(q) ||
          (m.notes       ?? "").toLowerCase().includes(q),
      )
    }

    return list
  }, [movements, filter, search])

  // ── Summary stats ─────────────────────────────────────────────────────────
  const since30d = useMemo(() => {
    const cutoff = subDays(new Date(), 30).toISOString()
    return movements.filter((m) => m.createdAt >= cutoff)
  }, [movements])

  const adjustmentCount = since30d.filter((m) =>
    ADJUSTMENT_TYPES.includes(m.type),
  ).length

  // ── Render ────────────────────────────────────────────────────────────────
  return (
    <Collapsible.Root open={open} onOpenChange={setOpen}>
      {/* ── Header / trigger ─────────────────────────────────────────────── */}
      <Collapsible.Trigger asChild>
        <button className={cn(
          "w-full flex items-center gap-3 px-4 py-3 rounded-xl border transition-colors",
          "bg-card border-border hover:bg-muted/40 text-left",
        )}>
          <History className="h-4 w-4 text-muted-foreground shrink-0" />
          <div className="flex-1 min-w-0">
            <span className="text-sm font-medium text-foreground">
              Historial de movimientos
            </span>
            {!open && movements.length > 0 && (
              <span className="text-xs text-muted-foreground ml-2">
                {since30d.length} en los últimos 30 días
                {adjustmentCount > 0 && ` · ${adjustmentCount} ajuste${adjustmentCount !== 1 ? "s" : ""}`}
              </span>
            )}
          </div>
          {/* Summary chips — desktop only */}
          {!open && since30d.length > 0 && (
            <div className="hidden sm:flex items-center gap-2 shrink-0">
              <Badge variant="outline" className="text-xs tabular-nums">
                {movements.filter((m) => INBOUND_TYPES.includes(m.type) && m.createdAt >= subDays(new Date(), 30).toISOString()).length} entradas
              </Badge>
              <Badge variant="outline" className="text-xs tabular-nums">
                {movements.filter((m) => OUTBOUND_TYPES.includes(m.type) && m.createdAt >= subDays(new Date(), 30).toISOString()).length} salidas
              </Badge>
            </div>
          )}
          <span className="text-muted-foreground">
            {open
              ? <ChevronDown className="h-4 w-4" />
              : <ChevronRight className="h-4 w-4" />
            }
          </span>
        </button>
      </Collapsible.Trigger>

      {/* ── Content ──────────────────────────────────────────────────────── */}
      <Collapsible.Content className="overflow-hidden data-[state=open]:animate-collapsible-down data-[state=closed]:animate-collapsible-up">
        <div className="mt-2 rounded-xl border border-border bg-card overflow-hidden">

          {/* Controls */}
          <div className="flex flex-wrap items-center gap-2 px-4 py-3 border-b border-border bg-muted/20">
            {/* Filter pills */}
            {(["all", "inbound", "outbound", "adjustments"] as FilterTab[]).map((f) => (
              <button
                key={f}
                onClick={() => setFilter(f)}
                className={cn(
                  "px-2.5 py-1 rounded-full text-xs font-medium border transition-colors",
                  filter === f
                    ? "bg-primary text-primary-foreground border-primary"
                    : "bg-background border-border text-muted-foreground hover:text-foreground",
                )}
              >
                {{
                  all:         "Todos",
                  inbound:     "Entradas",
                  outbound:    "Salidas",
                  adjustments: "Ajustes",
                }[f]}
              </button>
            ))}

            {/* Spacer */}
            <div className="flex-1 min-w-[120px]">
              <Input
                placeholder="Buscar…"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                className="h-7 text-xs bg-background border-border"
              />
            </div>

            {/* Refresh */}
            <Button
              variant="ghost"
              size="sm"
              className="h-7 px-2"
              onClick={() => fetchPage(true)}
              disabled={loading}
              title="Actualizar"
            >
              <RefreshCw className={cn("h-3.5 w-3.5", loading && "animate-spin")} />
            </Button>

            {/* Export */}
            {movements.length > 0 && (
              <Button
                variant="ghost"
                size="sm"
                className="h-7 px-2 hidden sm:inline-flex"
                onClick={() => exportCsv(filtered)}
                title="Exportar CSV"
              >
                <Download className="h-3.5 w-3.5" />
              </Button>
            )}
          </div>

          {/* Table header */}
          <div className="hidden sm:flex items-center gap-3 px-4 py-2 border-b border-border/50 bg-muted/10">
            <span className="w-[84px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Fecha</span>
            <span className="w-[120px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Tipo</span>
            <span className="flex-1 text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Producto</span>
            <span className="hidden sm:block w-[80px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Antes → Después</span>
            <span className="w-16 text-right text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Δ</span>
          </div>

          {/* Rows */}
          <ScrollArea className="h-[360px]">
            <div className="px-4">
              {loading && movements.length === 0 ? (
                <div className="flex items-center justify-center py-12 gap-2 text-muted-foreground">
                  <Loader2 className="h-4 w-4 animate-spin" />
                  <span className="text-sm">Cargando movimientos…</span>
                </div>
              ) : filtered.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-12 text-center">
                  <History className="h-8 w-8 text-muted-foreground/30 mb-3" />
                  <p className="text-sm text-muted-foreground">
                    {movements.length === 0
                      ? "Aún no hay movimientos registrados."
                      : "Sin resultados para los filtros aplicados."}
                  </p>
                </div>
              ) : (
                filtered.map((m) => <MovementRow key={m.id} m={m} />)
              )}
            </div>
          </ScrollArea>

          {/* Load more */}
          {hasMore && !search && filter === "all" && (
            <div className="flex items-center justify-center px-4 py-3 border-t border-border">
              <Button
                variant="ghost"
                size="sm"
                onClick={() => fetchPage(false)}
                disabled={loading}
                className="text-xs text-muted-foreground hover:text-foreground"
              >
                {loading ? (
                  <><Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />Cargando…</>
                ) : (
                  "Ver más movimientos"
                )}
              </Button>
            </div>
          )}

          {/* Footer count */}
          {filtered.length > 0 && (
            <div className="px-4 py-2 border-t border-border bg-muted/10 text-center">
              <span className="text-xs text-muted-foreground">
                {filtered.length} movimiento{filtered.length !== 1 ? "s" : ""}
                {filter !== "all" || search ? " (filtrados)" : ""}
              </span>
            </div>
          )}
        </div>
      </Collapsible.Content>
    </Collapsible.Root>
  )
}
