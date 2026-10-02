"use client"

/**
 * /presupuestos — listado de presupuestos (presupuestos-modulo D10).
 *
 * El filtro de estado, la búsqueda (nombre del cliente o número: "P-12", "12",
 * "00000012") y la paginación los resuelve el SERVIDOR; la pantalla sólo pide.
 * "Vencido" es un estado derivado (`is_expired`): un enviado con la validez
 * pasada se muestra vencido aunque el barrido diario todavía no lo haya marcado.
 *
 * Tabla en escritorio y tarjetas en móvil, con el mismo contenido. El CTA
 * "Nuevo presupuesto" aparece sólo con `CAN_QUOTE`, evaluado sobre el CONJUNTO de
 * roles (el `role` singular colapsa a `member` a quien sólo es vendedor); el
 * backend es la barrera real.
 */
import { useState } from "react"
import Link from "next/link"
import { ChevronLeft, ChevronRight, FileText, Plus, Search, Settings2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { QuoteStatusBadge } from "@/components/quotes/QuoteStatusBadge"
import { useQuoteSettings, useQuotes } from "@/hooks/data/use-quotes"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useDebounce } from "@/hooks/ui/use-debounce"
import { formatDate, formatMoney } from "@/lib/format"
import { CAN_QUOTE, hasCapability } from "@/lib/rbac-capabilities"
import { QUOTE_LIST_TABS } from "@/lib/quote-status"
import type { QuoteListItem, QuoteStatus } from "@/lib/quote-types"

const PAGE_SIZE = 25
const SEARCH_DEBOUNCE_MS = 300

type TabValue = QuoteStatus | "all"

function quoteNumber(quote: QuoteListItem): string {
  return quote.number_label ?? "—"
}

function validityClass(quote: QuoteListItem): string {
  return quote.is_expired ? "text-destructive font-medium" : "text-muted-foreground"
}

export default function QuotesPage() {
  const [tab, setTab] = useState<TabValue>("all")
  const [searchInput, setSearchInput] = useState("")
  const [page, setPage] = useState(0)
  const search = useDebounce(searchInput.trim(), SEARCH_DEBOUNCE_MS)

  const { roles, rolesResolved } = useOrgRole()
  const canQuote = hasCapability(roles, CAN_QUOTE, rolesResolved)
  const { data: settings } = useQuoteSettings()

  const { data, isLoading, isError } = useQuotes({
    status: tab === "all" ? undefined : tab,
    q: search || undefined,
    page,
    pageSize: PAGE_SIZE,
  })

  const items = data?.items ?? []
  const pages = data?.pages ?? 0

  function selectTab(next: TabValue) {
    setTab(next)
    setPage(0)
  }

  function changeSearch(value: string) {
    setSearchInput(value)
    setPage(0)
  }

  const emptyText = (() => {
    if (search) return { title: "Ningún presupuesto coincide con la búsqueda", body: "Probá con el nombre del cliente o con el número (por ejemplo P-12)." }
    if (tab !== "all") {
      const noun = QUOTE_LIST_TABS.find((t) => t.value === tab)?.noun ?? ""
      return { title: `No hay presupuestos ${noun}`, body: "Cuando algún presupuesto llegue a este estado, va a aparecer acá." }
    }
    return {
      title: "Todavía no hay presupuestos",
      body: "Un presupuesto es la cotización que le mandás a un cliente antes de vender. Lo descargás en PDF o lo mandás por WhatsApp, y cuando lo acepta lo pasás a venta con un toque.",
    }
  })()
  const showEmptyCta = canQuote && tab === "all" && !search

  const validityDays = settings?.defaultQuoteValidityDays

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Cabecera ── */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Presupuestos</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Cotizá a tus clientes, mandales el PDF y convertí en venta los que aceptan.
          </p>
        </div>
        {canQuote && (
          <Button asChild className="gap-2 shrink-0">
            <Link href="/presupuestos/nuevo">
              <Plus className="h-4 w-4" aria-hidden="true" />
              Nuevo presupuesto
            </Link>
          </Button>
        )}
      </div>

      {validityDays !== undefined && (
        <p
          data-testid="quote-validity-notice"
          className="flex flex-wrap items-center gap-x-2 gap-y-1 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs text-muted-foreground"
        >
          <span>
            Validez por defecto: {validityDays} {validityDays === 1 ? "día" : "días"}
          </span>
          <span aria-hidden="true">·</span>
          <Link
            href="/configuracion?tab=cobranzas"
            className="inline-flex items-center gap-1 text-primary underline-offset-2 hover:underline"
          >
            <Settings2 className="h-3 w-3" aria-hidden="true" />
            Cambiar
          </Link>
        </p>
      )}

      {/* ── Filtros ── */}
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filtrar por estado">
          {QUOTE_LIST_TABS.map((t) => (
            <Button
              key={t.value}
              type="button"
              variant={tab === t.value ? "default" : "outline"}
              size="sm"
              className="h-8 text-xs"
              aria-pressed={tab === t.value}
              onClick={() => selectTab(t.value)}
            >
              {t.label}
            </Button>
          ))}
        </div>
        <div className="relative max-w-sm">
          <Search
            className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
            aria-hidden="true"
          />
          <Input
            type="search"
            aria-label="Buscar por cliente o número"
            placeholder="Buscar por cliente o número (P-12)"
            value={searchInput}
            onChange={(e) => changeSearch(e.target.value)}
            className="pl-9 bg-background border-border text-foreground"
          />
        </div>
      </div>

      {/* ── Listado ── */}
      {isLoading ? (
        <p className="px-4 py-10 text-center text-sm text-muted-foreground" role="status">
          Cargando presupuestos…
        </p>
      ) : isError ? (
        <p className="px-4 py-10 text-center text-sm text-destructive" role="alert">
          No se pudieron cargar los presupuestos. Probá de nuevo en un momento.
        </p>
      ) : items.length === 0 ? (
        <Card className="border-border bg-card">
          <CardContent
            data-testid="quotes-empty"
            className="flex flex-col items-center gap-3 px-4 py-14 text-center text-muted-foreground"
          >
            <FileText className="h-10 w-10 opacity-30" aria-hidden="true" />
            <p className="text-sm font-medium text-foreground">{emptyText.title}</p>
            <p className="max-w-md text-xs">{emptyText.body}</p>
            {showEmptyCta && (
              <Button asChild size="sm" className="gap-2">
                <Link href="/presupuestos/nuevo">
                  <Plus className="h-4 w-4" aria-hidden="true" />
                  Crear el primero
                </Link>
              </Button>
            )}
          </CardContent>
        </Card>
      ) : (
        <>
          {/* Escritorio: tabla */}
          <Card className="hidden border-border bg-card min-w-0 md:block">
            <CardContent className="p-0">
              <div className="overflow-x-auto">
                <table className="w-full min-w-[720px] text-sm">
                  <thead>
                    <tr className="border-b border-border text-left">
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Número</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Cliente</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Fecha</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Válido hasta</th>
                      <th scope="col" className="px-4 py-3 text-right font-medium text-muted-foreground">Total</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Estado</th>
                    </tr>
                  </thead>
                  <tbody>
                    {items.map((quote) => (
                      <tr
                        key={quote.id}
                        data-testid={`quote-row-${quote.id}`}
                        className="border-b border-border/50 last:border-b-0 transition-colors hover:bg-accent/20"
                      >
                        <td className="px-4 py-3 font-medium whitespace-nowrap">
                          <Link
                            href={`/presupuestos/${quote.id}`}
                            className="text-primary underline-offset-2 hover:underline"
                          >
                            {quoteNumber(quote)}
                          </Link>
                        </td>
                        <td className="px-4 py-3 max-w-[240px] truncate text-foreground">
                          {quote.client_name ?? "Sin cliente"}
                        </td>
                        <td className="px-4 py-3 whitespace-nowrap tabular-nums text-muted-foreground">
                          {formatDate(quote.created_at)}
                        </td>
                        <td
                          data-testid="quote-valid-until"
                          className={`px-4 py-3 whitespace-nowrap tabular-nums ${validityClass(quote)}`}
                        >
                          {quote.valid_until ? formatDate(quote.valid_until) : "—"}
                        </td>
                        <td className="px-4 py-3 text-right font-semibold tabular-nums text-foreground whitespace-nowrap">
                          {formatMoney(Number(quote.total))}
                        </td>
                        <td className="px-4 py-3">
                          <QuoteStatusBadge status={quote.status} isExpired={quote.is_expired} />
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>

          {/* Móvil: tarjetas */}
          <ul className="flex flex-col gap-2 md:hidden" aria-label="Presupuestos">
            {items.map((quote) => (
              <li key={quote.id}>
                <Link
                  href={`/presupuestos/${quote.id}`}
                  data-testid={`quote-card-${quote.id}`}
                  className="flex flex-col gap-2 rounded-lg border border-border bg-card p-4 transition-colors hover:bg-accent/20"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="font-medium text-foreground truncate">{quote.client_name ?? "Sin cliente"}</p>
                      <p className="text-xs text-muted-foreground">{quoteNumber(quote)}</p>
                    </div>
                    <QuoteStatusBadge status={quote.status} isExpired={quote.is_expired} />
                  </div>
                  <div className="flex items-end justify-between gap-2 text-xs">
                    <div className="flex flex-col text-muted-foreground tabular-nums">
                      <span>{formatDate(quote.created_at)}</span>
                      <span className={validityClass(quote)}>
                        Válido hasta {quote.valid_until ? formatDate(quote.valid_until) : "—"}
                      </span>
                    </div>
                    <span className="text-base font-semibold tabular-nums text-foreground">
                      {formatMoney(Number(quote.total))}
                    </span>
                  </div>
                </Link>
              </li>
            ))}
          </ul>

          {pages > 1 && (
            <div className="flex items-center justify-between gap-2">
              <span className="text-xs text-muted-foreground tabular-nums">
                Página {page + 1} de {pages} · {data?.total ?? 0} presupuestos
              </span>
              <div className="flex items-center gap-1">
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  disabled={page === 0}
                  onClick={() => setPage(page - 1)}
                  aria-label="Página anterior"
                >
                  <ChevronLeft className="h-4 w-4" aria-hidden="true" />
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  disabled={page + 1 >= pages}
                  onClick={() => setPage(page + 1)}
                  aria-label="Página siguiente"
                >
                  <ChevronRight className="h-4 w-4" aria-hidden="true" />
                </Button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}
