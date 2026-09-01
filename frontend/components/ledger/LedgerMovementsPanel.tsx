"use client"

/**
 * LedgerMovementsPanel — historial de movimientos compartido por Caja y
 * Banco (ledger-movement-history, D1 del design).
 *
 * Calcado del molde de `components/stock/stock-movements-panel.tsx`:
 * Collapsible con resumen, píldoras de filtro por familia, badge por tipo
 * (label+ícono+tono), columna "saldo después", "Ver más" incremental y
 * export CSV. Un solo componente, parametrizado por un `LedgerBookConfig`
 * (lib/ledger/types.ts) — evita el `if (book === 'cash')` disperso.
 *
 * Dos correcciones sobre el molde (D1):
 *   1. El buscador va al SERVIDOR (`fetchPage({ q })`), no solo sobre las
 *      páginas ya cargadas — el propio molde de Stock documenta el bug que
 *      esto evita ("filtrar por Pérdidas no mostraba resultados").
 *   2. Tokens semánticos (`bg-{tone}/15 text-{tone} border-{tone}/25` vía
 *      `cva`) en vez de los colores literales del molde (`text-emerald-400`).
 */

import { useCallback, useEffect, useMemo, useRef, useState, memo } from "react"
import * as Collapsible from "@radix-ui/react-collapsible"
import { cva } from "class-variance-authority"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { ChevronDown, ChevronRight, History, Download, Loader2 } from "lucide-react"
import { cn } from "@/lib/utils"
import { format, parseISO } from "date-fns"
import { es } from "date-fns/locale"
import type { LedgerBookConfig, LedgerRowBase, LedgerTone } from "@/lib/ledger/types"
import { UNKNOWN_MOVEMENT_META } from "@/lib/ledger/types"

const PAGE_SIZE = 30
const SEARCH_DEBOUNCE_MS = 350

// ── Badge de tono semántico (tokens-contraste-aa) ──────────────────────────

const toneBadgeVariants = cva(
  "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[11px] font-medium border whitespace-nowrap",
  {
    variants: {
      tone: {
        success:     "border-transparent bg-success/15 text-success",
        destructive: "border-transparent bg-destructive/15 text-destructive",
        warning:     "border-transparent bg-warning/15 text-warning",
        primary:     "border-transparent bg-primary/15 text-primary",
        muted:       "border-border bg-transparent text-muted-foreground",
      } satisfies Record<LedgerTone, string>,
    },
    defaultVariants: { tone: "muted" },
  },
)

const amountToneVariants = cva("shrink-0 text-sm font-semibold tabular-nums pt-0.5 w-24 text-right", {
  variants: {
    positive: {
      true:  "text-success",
      false: "text-destructive",
    },
  },
})

// ── Fila memoizada ──────────────────────────────────────────────────────────

interface MovementRowProps<TRow extends LedgerRowBase> {
  row: TRow
  config: LedgerBookConfig<TRow>
}

function MovementRowInner<TRow extends LedgerRowBase>({ row, config }: MovementRowProps<TRow>) {
  const meta = config.meta[row.movementType] ?? UNKNOWN_MOVEMENT_META
  const Icon = meta.icon
  const isPositive = row.amount >= 0

  return (
    <div className="flex items-start gap-3 py-2.5 px-1 border-b border-border/50 last:border-0">
      <div className="w-[84px] shrink-0 pt-0.5">
        <p className="text-[11px] text-muted-foreground tabular-nums leading-tight">
          {format(parseISO(row.createdAt), "dd MMM yyyy", { locale: es })}
        </p>
        <p className="text-[10px] text-muted-foreground/60 tabular-nums">
          {format(parseISO(row.createdAt), "HH:mm")}
        </p>
      </div>

      <div className="w-[140px] shrink-0 pt-0.5">
        <span className={cn(toneBadgeVariants({ tone: meta.tone }))}>
          <Icon className="h-3.5 w-3.5" />
          {meta.label}
        </span>
      </div>

      <div className="flex-1 min-w-0 pt-0.5">
        {row.description && (
          <p className="text-sm text-foreground truncate">{row.description}</p>
        )}
      </div>

      <div className="hidden sm:block w-[140px] shrink-0 pt-0.5 text-xs text-muted-foreground">
        {config.extraColumn.render(row)}
      </div>

      <div className={cn(amountToneVariants({ positive: isPositive }))}>
        {isPositive ? "+" : ""}
        {row.amount.toLocaleString("es-AR", { minimumFractionDigits: 2 })}
      </div>

      <div className="hidden md:block w-24 shrink-0 text-right text-xs text-muted-foreground tabular-nums pt-1">
        {row.balanceAfter.toLocaleString("es-AR", { minimumFractionDigits: 2 })}
      </div>
    </div>
  )
}
const MovementRow = memo(MovementRowInner) as typeof MovementRowInner

// ── CSV export ────────────────────────────────────────────────────────────

function exportCsv<TRow extends LedgerRowBase>(rows: TRow[], config: LedgerBookConfig<TRow>) {
  const csvRows = rows.map(config.csvRow)
  const csv = [config.csvHeader, ...csvRows]
    .map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(","))
    .join("\n")
  const blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8;" })
  const url = URL.createObjectURL(blob)
  const a = Object.assign(document.createElement("a"), {
    href: url,
    download: `${config.csvName}_${format(new Date(), "yyyyMMdd")}.csv`,
  })
  a.click()
  URL.revokeObjectURL(url)
}

// ── Componente principal ─────────────────────────────────────────────────

interface LedgerMovementsPanelProps<TRow extends LedgerRowBase> {
  config: LedgerBookConfig<TRow>
  /** Se re-arma la key de fetch cuando cambia (p. ej. al cambiar de caja/cuenta). */
  scopeKey: string
  /** Incrementalo para forzar un refetch (p. ej. tras registrar un ajuste) —
   * el panel no usa TanStack Query, así que no hay queryClient que invalidar. */
  refreshToken?: number
}

export function LedgerMovementsPanel<TRow extends LedgerRowBase>({
  config,
  scopeKey,
  refreshToken,
}: LedgerMovementsPanelProps<TRow>) {
  const [open, setOpen] = useState(false)
  const [rows, setRows] = useState<TRow[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(false)
  const [hasMore, setHasMore] = useState(true)
  const [family, setFamily] = useState<string>("all")
  const [extraFilterValue, setExtraFilterValue] = useState<string>("")
  const [searchInput, setSearchInput] = useState("")
  const [search, setSearch] = useState("")

  // pageRef en vez de estado — fetchPage queda estable, evita el double-fetch
  // de Strict Mode (mismo patrón que el molde de Stock).
  const pageRef = useRef(0)

  const activeTypes = useMemo(() => {
    if (family === "all") return undefined
    return config.families.find((f) => f.key === family)?.types
  }, [family, config.families])

  const fetchPage = useCallback(
    async (reset: boolean) => {
      setLoading(true)
      const currentPage = reset ? 0 : pageRef.current

      const extra = config.extraFilter && extraFilterValue
        ? { [config.extraFilter.key]: extraFilterValue }
        : undefined

      try {
        const result = await config.fetchPage({
          page: currentPage,
          size: PAGE_SIZE,
          types: activeTypes,
          q: search || undefined,
          extra,
        })
        setRows((prev) => (reset ? result.items : [...prev, ...result.items]))
        setTotal(result.total)
        setHasMore(currentPage + 1 < result.pages)
        pageRef.current = reset ? 1 : currentPage + 1
      } finally {
        setLoading(false)
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [config.book, scopeKey, activeTypes, search, extraFilterValue],
  )

  // Debounce del buscador — server-side, no dispara un fetch por tecla.
  useEffect(() => {
    const t = setTimeout(() => setSearch(searchInput.trim()), SEARCH_DEBOUNCE_MS)
    return () => clearTimeout(t)
  }, [searchInput])

  useEffect(() => {
    if (open) fetchPage(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, scopeKey, activeTypes, search, extraFilterValue, refreshToken])

  return (
    <Collapsible.Root open={open} onOpenChange={setOpen}>
      <Collapsible.Trigger asChild>
        <button
          className={cn(
            "w-full flex items-center gap-3 px-4 py-3 rounded-xl border transition-colors",
            "bg-card border-border hover:bg-muted/40 text-left",
          )}
        >
          <History className="h-4 w-4 text-muted-foreground shrink-0" />
          <div className="flex-1 min-w-0">
            <span className="text-sm font-medium text-foreground">Historial de movimientos</span>
            {!open && total > 0 && (
              <span className="text-xs text-muted-foreground ml-2">{total} en total</span>
            )}
          </div>
          <span className="text-muted-foreground">
            {open ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
          </span>
        </button>
      </Collapsible.Trigger>

      <Collapsible.Content className="overflow-hidden data-[state=open]:animate-collapsible-down data-[state=closed]:animate-collapsible-up">
        <div className="mt-2 rounded-xl border border-border bg-card overflow-hidden">
          {/* Controles */}
          <div className="flex flex-wrap items-center gap-2 px-4 py-3 border-b border-border bg-muted/20">
            {config.families.map((f) => (
              <button
                key={f.key}
                onClick={() => setFamily(f.key)}
                className={cn(
                  "px-3 py-2 md:px-2.5 md:py-1 rounded-full text-xs font-medium border transition-colors",
                  family === f.key
                    ? "bg-primary text-primary-foreground border-primary"
                    : "bg-background border-border text-muted-foreground hover:text-foreground",
                )}
              >
                {f.label}
              </button>
            ))}

            {config.extraFilter && (
              <select
                value={extraFilterValue}
                onChange={(e) => setExtraFilterValue(e.target.value)}
                className="h-9 md:h-7 rounded-md border border-border bg-background px-2 text-xs text-foreground"
                aria-label={config.extraFilter.label}
              >
                <option value="">{config.extraFilter.label}: todos</option>
                {config.extraFilter.options.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            )}

            <div className="flex-1 min-w-[120px]">
              <Input
                placeholder="Buscar por motivo…"
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
                className="h-9 md:h-7 text-xs bg-background border-border"
              />
            </div>

            <Button
              variant="ghost"
              size="sm"
              className="h-11 min-w-11 md:h-7 md:min-w-0 px-2"
              onClick={() => fetchPage(true)}
              disabled={loading}
              title="Actualizar"
            >
              <Loader2 className={cn("h-3.5 w-3.5", loading && "animate-spin")} />
            </Button>

            {rows.length > 0 && (
              <Button
                variant="ghost"
                size="sm"
                className="h-11 min-w-11 md:h-7 md:min-w-0 px-2 hidden sm:inline-flex"
                onClick={() => exportCsv(rows, config)}
                title="Exportar CSV"
              >
                <Download className="h-3.5 w-3.5" />
              </Button>
            )}
          </div>

          {/* qa-integral-modulos G2 (H2/2.7): las columnas en px fijos (84 +
              140 + 96 + gaps) exceden el ancho móvil — el desborde ahora vive
              en este contenedor con scroll horizontal propio, no en la página
              (el hijo display:table del ScrollArea de Radix dimensionaba las
              filas a max-content y estiraba el documento entero). */}
          <div className="overflow-x-auto">
          <div className="min-w-[420px]">
          {/* Cabecera de tabla */}
          <div className="hidden sm:flex items-center gap-3 px-4 py-2 border-b border-border/50 bg-muted/10">
            <span className="w-[84px]  text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Fecha</span>
            <span className="w-[140px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Tipo</span>
            <span className="flex-1    text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Motivo</span>
            <span className="hidden sm:block w-[140px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">
              {config.extraColumn.header}
            </span>
            <span className="w-24 text-right text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Importe</span>
            <span className="hidden md:block w-24 text-right text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Saldo</span>
          </div>

          <ScrollArea className="h-[360px]">
            <div className="px-4">
              {loading && rows.length === 0 ? (
                <div className="flex items-center justify-center py-12 gap-2 text-muted-foreground">
                  <Loader2 className="h-4 w-4 animate-spin" />
                  <span className="text-sm">Cargando movimientos…</span>
                </div>
              ) : rows.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-12 text-center">
                  <History className="h-8 w-8 text-muted-foreground/30 mb-3" />
                  <p className="text-sm text-muted-foreground">
                    {search || family !== "all" || extraFilterValue
                      ? "Sin resultados para los filtros aplicados."
                      : "Aún no hay movimientos registrados."}
                  </p>
                </div>
              ) : (
                rows.map((row) => <MovementRow key={row.id} row={row} config={config} />)
              )}
            </div>
          </ScrollArea>
          </div>
          </div>

          {hasMore && (
            <div className="flex items-center justify-center px-4 py-3 border-t border-border">
              <Button
                variant="ghost"
                size="sm"
                onClick={() => fetchPage(false)}
                disabled={loading}
                className="text-xs text-muted-foreground hover:text-foreground"
              >
                {loading ? (
                  <>
                    <Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />
                    Cargando…
                  </>
                ) : (
                  "Ver más movimientos"
                )}
              </Button>
            </div>
          )}

          {rows.length > 0 && (
            <div className="px-4 py-2 border-t border-border bg-muted/10 text-center">
              <span className="text-xs text-muted-foreground">
                {rows.length} de {total} movimiento{total !== 1 ? "s" : ""}
              </span>
            </div>
          )}
        </div>
      </Collapsible.Content>
    </Collapsible.Root>
  )
}
