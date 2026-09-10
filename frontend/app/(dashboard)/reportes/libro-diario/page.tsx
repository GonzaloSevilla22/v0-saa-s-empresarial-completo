"use client"

/**
 * /reportes/libro-diario — asiento-contable-gastos (D9/D10).
 *
 * `GET /journal-entries` existe completo desde `journal-entry-outbox` (router,
 * service, repository, schemas Pydantic, tests) con CERO consumidores en el
 * frontend — el anti-patrón textual que la regla de superficie del PO existe
 * para prevenir (origen: `CostCenterManager` construido y jamás montado).
 *
 * Filtros por rango de fechas, tipo de documento y estado, más el modo
 * "asientos de un documento" (query params `source_doc_type`/`source_doc_ref`,
 * el enlace que sale de `ExpenseJournalStatusBadge` en /gastos). Sin gate de
 * plan — mismo criterio que Centros de costo y Formas de pago: es lectura de
 * datos que el propio usuario generó.
 *
 * D1/10.6: el posteo es asincrónico (el relay corre cada minuto, una
 * importación grande se asienta de a lotes) — la pantalla tolera el desfase
 * sin parecer rota.
 */
import { useMemo, useState } from "react"
import { useSearchParams } from "next/navigation"
import Link from "next/link"
import { format, parseISO } from "date-fns"
import { ChevronDown, ChevronRight, BookOpen, X, CalendarDays } from "lucide-react"
import { useJournalEntries } from "@/hooks/data/use-journal-entries"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { formatMoney } from "@/lib/format"
import { cn } from "@/lib/utils"
import type { JournalEntry } from "@/lib/types"

/** `posted_at` es `timestamptz` (no una fecha pura como `expenses.date`):
 * `formatDate` de `lib/format.ts` asume una fecha pura y le agrega
 * "T12:00:00" — aplicado acá correría el asiento de día. Molde de
 * `LedgerMovementsPanel` (fecha + hora en dos líneas). */
function formatEntryDate(iso: string): { date: string; time: string } {
  const d = parseISO(iso)
  return { date: format(d, "dd/MM/yyyy"), time: format(d, "HH:mm") }
}

const DOC_TYPE_LABELS: Record<string, string> = {
  SalesOrder: "Venta (POS)",
  SaleOperation: "Venta",
  Purchase: "Compra",
  CustomerAccount: "Cobro",
  SupplierAccount: "Pago a proveedor",
  CreditNote: "Nota de crédito",
  Expense: "Gasto",
}

function docTypeLabel(t: string | null): string {
  if (!t) return "Sin documento"
  return DOC_TYPE_LABELS[t] ?? t
}

export default function LibroDiarioPage() {
  const searchParams = useSearchParams()
  const initialDocType = searchParams.get("source_doc_type")
  const initialDocRef  = searchParams.get("source_doc_ref")

  const {
    entries, meta, isLoading, error,
    filters, setFilters,
    setPage, setPageSize,
  } = useJournalEntries({
    initialFilters: {
      sourceDocType: initialDocType,
      sourceDocRef:  initialDocRef,
    },
  })

  const [expandedId, setExpandedId] = useState<string | null>(null)

  const isDocumentMode = !!filters.sourceDocRef
  const isDateFilterActive = !!(filters.dateFrom || filters.dateTo)
  const isAnyFilterActive = isDateFilterActive || !!filters.sourceDocType || !!filters.status || isDocumentMode

  const docTypeOptions = useMemo(() => Object.keys(DOC_TYPE_LABELS), [])

  function clearAll() {
    setFilters({})
  }

  function clearDocumentMode() {
    setFilters({ ...filters, sourceDocRef: null, sourceDocType: filters.sourceDocType })
  }

  return (
    <div className="flex flex-col gap-6 min-w-0">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Libro diario</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Asientos de partida doble de venta, compra, gasto, cobros y pagos — de sólo lectura.
        </p>
      </div>

      {isDocumentMode && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg border border-primary/30 bg-primary/5 px-4 py-2.5 text-sm">
          <BookOpen className="h-4 w-4 text-primary shrink-0" />
          <span className="text-foreground">
            Mostrando los asientos de {docTypeLabel(filters.sourceDocType ?? null).toLowerCase()}
          </span>
          <Button variant="ghost" size="sm" className="ml-auto text-muted-foreground" onClick={clearDocumentMode}>
            <X className="h-3.5 w-3.5 mr-1" />Ver todos
          </Button>
        </div>
      )}

      {/* Filtros */}
      <div
        className="flex flex-col gap-3 lg:flex-row lg:flex-wrap lg:items-center lg:justify-between"
        data-testid="journal-filters-bar"
      >
        <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3">
          <Popover>
            <PopoverTrigger asChild>
              <Button
                variant="outline" size="sm"
                className={cn("shrink-0 border-border text-foreground", isDateFilterActive && "border-primary text-primary")}
              >
                <CalendarDays className="h-4 w-4 mr-1" />
                Filtrar fechas
              </Button>
            </PopoverTrigger>
            <PopoverContent className="w-72" align="start">
              <div className="flex flex-col gap-3">
                <p className="text-sm font-medium text-foreground">Rango de fechas</p>
                <div className="flex flex-col gap-2">
                  <Label htmlFor="je-date-from" className="text-xs text-muted-foreground">Desde</Label>
                  <Input
                    id="je-date-from" type="date" value={filters.dateFrom ?? ""}
                    onChange={(e) => setFilters({ ...filters, dateFrom: e.target.value || null })}
                  />
                </div>
                <div className="flex flex-col gap-2">
                  <Label htmlFor="je-date-to" className="text-xs text-muted-foreground">Hasta</Label>
                  <Input
                    id="je-date-to" type="date" value={filters.dateTo ?? ""}
                    onChange={(e) => setFilters({ ...filters, dateTo: e.target.value || null })}
                  />
                </div>
                {isDateFilterActive && (
                  <Button variant="ghost" size="sm" className="text-muted-foreground"
                    onClick={() => setFilters({ ...filters, dateFrom: null, dateTo: null })}>
                    <X className="h-3 w-3 mr-1" />Limpiar filtro
                  </Button>
                )}
              </div>
            </PopoverContent>
          </Popover>

          <div className="w-full sm:w-48">
            <Label htmlFor="je-doc-type" className="sr-only">Tipo de documento</Label>
            <Select
              value={filters.sourceDocType ?? "__all__"}
              onValueChange={(v) => setFilters({ ...filters, sourceDocType: v === "__all__" ? null : v })}
            >
              <SelectTrigger id="je-doc-type" aria-label="Tipo de documento">
                <SelectValue placeholder="Todos los documentos" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__all__">Todos los documentos</SelectItem>
                {docTypeOptions.map((t) => (
                  <SelectItem key={t} value={t}>{DOC_TYPE_LABELS[t]}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="w-full sm:w-40">
            <Label htmlFor="je-status" className="sr-only">Estado</Label>
            <Select
              value={filters.status ?? "__all__"}
              onValueChange={(v) => setFilters({ ...filters, status: v === "__all__" ? null : (v as "posted" | "reversed") })}
            >
              <SelectTrigger id="je-status" aria-label="Estado del asiento">
                <SelectValue placeholder="Todos los estados" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__all__">Todos los estados</SelectItem>
                <SelectItem value="posted">Vigente</SelectItem>
                <SelectItem value="reversed">Revertido</SelectItem>
              </SelectContent>
            </Select>
          </div>

          {isAnyFilterActive && (
            <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={clearAll}>
              <X className="h-3.5 w-3.5 mr-1" />Limpiar todo
            </Button>
          )}
        </div>

        <span className="text-sm text-muted-foreground tabular-nums">
          {isLoading ? "Cargando..." : `${meta.totalCount} asiento${meta.totalCount !== 1 ? "s" : ""}`}
        </span>
      </div>

      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error instanceof Error ? error.message : "Error al cargar el libro diario"}
        </div>
      )}

      <Card className="min-w-0">
        <CardHeader>
          <CardTitle className="text-sm font-medium">Asientos</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {isLoading && entries.length === 0 ? (
            <div className="flex flex-col">
              {Array.from({ length: 5 }).map((_, i) => (
                <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                  <div className="h-4 rounded bg-accent animate-pulse" />
                </div>
              ))}
            </div>
          ) : !isLoading && entries.length === 0 ? (
            <EmptyState isAnyFilterActive={isAnyFilterActive} />
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[640px] text-sm" data-testid="journal-entries-table">
                <caption className="sr-only">Libro diario — asientos de partida doble</caption>
                <thead>
                  <tr className="border-b border-border bg-muted/40">
                    <th scope="col" className="w-8 px-2 py-3"><span className="sr-only">Expandir</span></th>
                    <th scope="col" className="px-4 py-3 text-left font-medium text-muted-foreground">Fecha</th>
                    <th scope="col" className="px-4 py-3 text-left font-medium text-muted-foreground">Documento</th>
                    <th scope="col" className="px-4 py-3 text-left font-medium text-muted-foreground">Estado</th>
                    <th scope="col" className="px-4 py-3 text-right font-medium text-muted-foreground">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {entries.map((entry) => (
                    <JournalEntryRow
                      key={entry.id}
                      entry={entry}
                      expanded={expandedId === entry.id}
                      onToggle={() => setExpandedId(expandedId === entry.id ? null : entry.id)}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      <PaginationBar meta={meta} onPageChange={setPage} onSizeChange={setPageSize} loading={isLoading} label="asientos" />

      <p className="text-xs text-muted-foreground">
        Los asientos se postean de forma asincrónica: un gasto o una venta
        recién cargados pueden tardar hasta un minuto en aparecer acá, y un
        lote importado se asienta de a tandas. Un asiento revertido queda
        marcado como tal junto a su contra-asiento — ninguno de los dos se
        borra: el libro es de sólo agregado.
      </p>
    </div>
  )
}

function JournalEntryRow({
  entry, expanded, onToggle,
}: {
  entry: JournalEntry
  expanded: boolean
  onToggle: () => void
}) {
  const total = entry.lines
    .filter((l) => l.side === "debit")
    .reduce((sum, l) => sum + l.amount, 0)
  const isReversed = entry.status === "reversed"
  const panelId = `journal-lines-${entry.id}`

  return (
    <>
      <tr className={cn("border-t border-border/50 hover:bg-accent/20", isReversed && "text-muted-foreground")}>
        <td className="px-2 py-3">
          <Button
            variant="ghost" size="icon" className="h-6 w-6"
            aria-expanded={expanded}
            aria-controls={panelId}
            aria-label={expanded ? "Contraer líneas del asiento" : "Expandir líneas del asiento"}
            onClick={onToggle}
          >
            {expanded ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
          </Button>
        </td>
        <td className="px-4 py-3 tabular-nums text-muted-foreground">
          {(() => {
            const { date, time } = formatEntryDate(entry.postedAt)
            return (
              <div className="flex flex-col">
                <span>{date}</span>
                <span className="text-[10px] text-muted-foreground/60">{time}</span>
              </div>
            )
          })()}
        </td>
        <td className="px-4 py-3">
          <div className="flex items-center gap-2">
            <span className="font-medium text-foreground">{docTypeLabel(entry.sourceDocType)}</span>
            {entry.sourceDocType === "Expense" && entry.sourceDocRef && (
              <Link
                href={`/reportes/libro-diario?source_doc_type=Expense&source_doc_ref=${entry.sourceDocRef}`}
                className="text-xs text-primary hover:underline"
              >
                ver todos
              </Link>
            )}
          </div>
        </td>
        <td className="px-4 py-3">
          {/* D9: distinción visible sin necesidad de abrir el asiento. */}
          <Badge
            variant="outline"
            className={cn(
              "text-[10px]",
              isReversed ? "border-transparent bg-warning/15 text-warning" : "border-transparent bg-success/15 text-success",
            )}
          >
            {isReversed ? "Revertido" : "Vigente"}
          </Badge>
        </td>
        <td className="px-4 py-3 text-right tabular-nums font-semibold text-foreground">{formatMoney(total)}</td>
      </tr>
      {expanded && (
        <tr id={panelId}>
          <td colSpan={5} className="bg-muted/20 px-4 py-3">
            <table className="w-full text-xs">
              <caption className="sr-only">Líneas de débito y crédito del asiento</caption>
              <thead>
                <tr className="text-muted-foreground">
                  <th scope="col" className="text-left font-medium py-1">Cuenta</th>
                  <th scope="col" className="text-left font-medium py-1">Lado</th>
                  <th scope="col" className="text-right font-medium py-1">Importe</th>
                </tr>
              </thead>
              <tbody>
                {entry.lines.map((line) => (
                  <tr key={line.id}>
                    <td className="py-1 text-foreground">{line.accountCode}</td>
                    <td className="py-1 capitalize text-muted-foreground">
                      {line.side === "debit" ? "Débito" : "Crédito"}
                    </td>
                    <td className="py-1 text-right tabular-nums">{formatMoney(line.amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </td>
        </tr>
      )}
    </>
  )
}

function EmptyState({ isAnyFilterActive }: { isAnyFilterActive: boolean }) {
  return (
    <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
      <BookOpen className="h-10 w-10 opacity-30" />
      <p className="text-sm">
        {isAnyFilterActive
          ? "Sin asientos para este filtro"
          : "Todavía no hay asientos — se postean a medida que el relay procesa tus operaciones (hasta un minuto de desfase)."}
      </p>
    </div>
  )
}
