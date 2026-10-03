"use client"

/**
 * /remitos — listado de remitos (remitos-venta D11, tarea 5.4; remitos-compra D11,
 * tarea 5.4).
 *
 * Dos pestañas de SENTIDO, **De venta** (la que abre por defecto) y **De compra**,
 * con `?sentido=venta|compra`: cada una pide `GET /delivery-notes?direction=…`. Las
 * dos se muestran a todo miembro de la cuenta (la lectura es libre); lo que se
 * habilita por rol es el alta de cada sentido (`CAN_DELIVER_SALE` /
 * `CAN_RECEIVE_PURCHASE`). El estado, la búsqueda, el resumen y la paginación los
 * resuelve el SERVIDOR; la pantalla sólo pide.
 *
 * **Contrato único de la URL** (D11), en castellano como el `?cliente=` de
 * /presupuestos/nuevo y combinable: `?sentido=` elige la pestaña de sentido,
 * `?estado=todos|pendientes|convertidos|anulados` la de estado, y `?sucursal=<id>`,
 * `?cliente=<id>` (venta) y `?proveedor=<id>` (compra) se aplican como chips
 * removibles. Los enlaces que llegan filtrados lo usan: el de
 * `DeactivateBranchDialog`, el "Ver remitos" de la ficha del cliente y los de
 * /proveedores. La pantalla mantiene la URL en sintonía con lo que se ve
 * (`router.replace`), así que un listado filtrado se puede copiar y volver a abrir.
 *
 * Encabezado: el resumen "N remitos pendientes por $ X" (en compra, "N remitos de
 * compra pendientes por $ X (M sin precio)": el importe está incompleto mientras
 * alguna línea esté en precio 0) que calcula el servidor sobre el mismo recorte, sin
 * importar la pestaña de estado. Tabla en escritorio y tarjetas en móvil, con el
 * mismo contenido. Todos los textos que dependen del sentido salen de
 * `DELIVERY_NOTE_SCREEN_TEXTS`.
 */
import { useEffect, useState } from "react"
import Link from "next/link"
import { usePathname, useRouter, useSearchParams } from "next/navigation"
import { ChevronLeft, ChevronRight, PackageCheck, Plus, Search, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { DeliveryNoteStatusBadge } from "@/components/delivery-notes/DeliveryNoteStatusBadge"
import { DELIVERY_NOTE_SCREEN_TEXTS } from "@/components/delivery-notes/delivery-note-page-texts"
import { useBranches } from "@/hooks/data/use-branches"
import { useClients } from "@/hooks/data/use-clients"
import { useDeliveryNotes } from "@/hooks/data/use-delivery-notes"
import { useSuppliers } from "@/hooks/data/use-suppliers"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useDebounce } from "@/hooks/ui/use-debounce"
import {
  DELIVERY_NOTE_ESTADO_TABS,
  DELIVERY_NOTE_SENTIDO_TABS,
  directionFromSentido,
  parseDeliveryNoteEstadoParam,
  parseDeliveryNoteSentidoParam,
  type DeliveryNoteEstado,
  type DeliveryNoteSentido,
} from "@/lib/delivery-note-status"
import type { DeliveryNoteListItem } from "@/lib/delivery-note-types"
import { formatDate, formatMoney } from "@/lib/format"
import { CAN_DELIVER_SALE, CAN_RECEIVE_PURCHASE, hasCapability } from "@/lib/rbac-capabilities"

const PAGE_SIZE = 25
const SEARCH_DEBOUNCE_MS = 300

function numberLabel(note: DeliveryNoteListItem): string {
  return note.number_label ?? "—"
}

/** Un pendiente con líneas en precio 0 todavía no se puede convertir: su total subestima lo recibido. */
function hasMissingPrice(note: DeliveryNoteListItem): boolean {
  return note.direction === "purchase" && note.status === "issued" && (note.missing_price_count ?? 0) > 0
}

interface ListFilters {
  sentido: DeliveryNoteSentido
  estado: DeliveryNoteEstado
  branchId?: string
  clientId?: string
  supplierId?: string
}

/** `/remitos?sentido=…&estado=…&sucursal=…&cliente=…&proveedor=…`, sólo con lo que no es el valor por defecto. */
function buildListHref(pathname: string, filters: ListFilters): string {
  const params = new URLSearchParams()
  if (filters.sentido !== "venta") params.set("sentido", filters.sentido)
  if (filters.estado !== "todos") params.set("estado", filters.estado)
  if (filters.branchId) params.set("sucursal", filters.branchId)
  if (filters.clientId) params.set("cliente", filters.clientId)
  if (filters.supplierId) params.set("proveedor", filters.supplierId)
  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

function FilterChip({
  testId,
  label,
  removeLabel,
  onRemove,
}: {
  testId: string
  label: string
  removeLabel: string
  onRemove: () => void
}) {
  return (
    <span
      data-testid={testId}
      className="inline-flex items-center gap-1 rounded-full border border-border bg-accent/30 py-1 pl-3 pr-1 text-xs text-foreground"
    >
      {label}
      <button
        type="button"
        onClick={onRemove}
        aria-label={removeLabel}
        className="inline-flex h-5 w-5 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        <X className="h-3 w-3" aria-hidden="true" />
      </button>
    </span>
  )
}

function NoPriceBadge({ noteId }: { noteId: string }) {
  return (
    <Badge
      variant="outline"
      data-testid={`delivery-note-no-price-${noteId}`}
      className="whitespace-nowrap border-warning/40 bg-warning/10 text-warning"
    >
      Sin precio
    </Badge>
  )
}

export default function DeliveryNotesPage() {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()
  const paramsKey = searchParams.toString()

  const [sentido, setSentido] = useState<DeliveryNoteSentido>(() => parseDeliveryNoteSentidoParam(searchParams.get("sentido")))
  const [estado, setEstado] = useState<DeliveryNoteEstado>(() => parseDeliveryNoteEstadoParam(searchParams.get("estado")))
  const [branchFilter, setBranchFilter] = useState<string | undefined>(() => searchParams.get("sucursal") ?? undefined)
  const [clientFilter, setClientFilter] = useState<string | undefined>(() => searchParams.get("cliente") ?? undefined)
  const [supplierFilter, setSupplierFilter] = useState<string | undefined>(() => searchParams.get("proveedor") ?? undefined)
  const [searchInput, setSearchInput] = useState("")
  const [page, setPage] = useState(0)
  const search = useDebounce(searchInput.trim(), SEARCH_DEBOUNCE_MS)

  // Una navegación externa a /remitos?… (sin remontar la página) re-lee la URL.
  useEffect(() => {
    setSentido(parseDeliveryNoteSentidoParam(searchParams.get("sentido")))
    setEstado(parseDeliveryNoteEstadoParam(searchParams.get("estado")))
    setBranchFilter(searchParams.get("sucursal") ?? undefined)
    setClientFilter(searchParams.get("cliente") ?? undefined)
    setSupplierFilter(searchParams.get("proveedor") ?? undefined)
    setPage(0)
    // `paramsKey` resume los parámetros; `searchParams` cambia de identidad en cada render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paramsKey])

  const direction = directionFromSentido(sentido)
  const isPurchase = direction === "purchase"
  const texts = DELIVERY_NOTE_SCREEN_TEXTS[direction].list

  const { roles, rolesResolved } = useOrgRole()
  const canCreate = hasCapability(roles, isPurchase ? CAN_RECEIVE_PURCHASE : CAN_DELIVER_SALE, rolesResolved)
  const { branches } = useBranches()
  const { clients } = useClients()
  const { suppliers } = useSuppliers()

  const activeTab = DELIVERY_NOTE_ESTADO_TABS.find((t) => t.value === estado) ?? DELIVERY_NOTE_ESTADO_TABS[0]

  // La contraparte del otro sentido no aplica: un cliente no filtra remitos de compra.
  const activeClient = isPurchase ? undefined : clientFilter
  const activeSupplier = isPurchase ? supplierFilter : undefined

  const { data, isLoading, isError } = useDeliveryNotes({
    direction,
    status: activeTab.status,
    branchId: branchFilter,
    clientId: activeClient,
    supplierId: activeSupplier,
    q: search || undefined,
    page,
    pageSize: PAGE_SIZE,
  })

  const items = data?.items ?? []
  const pages = data?.pages ?? 0
  const summary = data?.summary

  function syncUrl(next: ListFilters) {
    router.replace(buildListHref(pathname, next), { scroll: false })
  }

  function current(overrides: Partial<ListFilters> = {}): ListFilters {
    return {
      sentido,
      estado,
      branchId: branchFilter,
      clientId: activeClient,
      supplierId: activeSupplier,
      ...overrides,
    }
  }

  function selectSentido(next: DeliveryNoteSentido) {
    if (next === sentido) return
    setSentido(next)
    // Cliente y proveedor son contrapartes de sentidos distintos, y la búsqueda
    // (cliente / proveedor / R- / RC-) significa otra cosa en cada pestaña.
    setClientFilter(undefined)
    setSupplierFilter(undefined)
    setSearchInput("")
    setPage(0)
    syncUrl({ sentido: next, estado, branchId: branchFilter })
  }

  function selectTab(next: DeliveryNoteEstado) {
    setEstado(next)
    setPage(0)
    syncUrl(current({ estado: next }))
  }

  function removeBranchFilter() {
    setBranchFilter(undefined)
    setPage(0)
    syncUrl(current({ branchId: undefined }))
  }

  function removeClientFilter() {
    setClientFilter(undefined)
    setPage(0)
    syncUrl(current({ clientId: undefined }))
  }

  function removeSupplierFilter() {
    setSupplierFilter(undefined)
    setPage(0)
    syncUrl(current({ supplierId: undefined }))
  }

  function changeSearch(value: string) {
    setSearchInput(value)
    setPage(0)
  }

  const branchFilterName = branchFilter ? (branches.find((b) => b.id === branchFilter)?.name ?? null) : null
  const clientFilterName = activeClient ? (clients.find((c) => c.id === activeClient)?.name ?? null) : null
  const supplierFilterName = activeSupplier ? (suppliers.find((s) => s.id === activeSupplier)?.name ?? null) : null

  const emptyText = (() => {
    if (search) return texts.emptySearch
    if (estado !== "todos") {
      return {
        title: `No hay remitos ${activeTab.label.toLowerCase()}`,
        body: "Cuando algún remito llegue a este estado, va a aparecer acá.",
      }
    }
    if (activeClient || activeSupplier) return texts.emptyCounterpart
    if (branchFilter) return texts.emptyBranch
    return texts.emptyDefault
  })()
  const showEmptyCta = canCreate && estado === "todos" && !search && !activeClient && !activeSupplier && !branchFilter

  const newParams = new URLSearchParams()
  if (isPurchase) newParams.set("tipo", "compra")
  if (activeClient) newParams.set("cliente", activeClient)
  if (activeSupplier) newParams.set("proveedor", activeSupplier)
  const newQuery = newParams.toString()
  const newHref = newQuery ? `/remitos/nuevo?${newQuery}` : "/remitos/nuevo"

  const counterpartName = (note: DeliveryNoteListItem): string =>
    (isPurchase ? note.supplier_name : note.client_name) ?? texts.counterpartMissing

  const missingPriceCount = summary?.pending_missing_price_count ?? 0

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Cabecera ── */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Remitos</h1>
          <p className="text-sm text-muted-foreground mt-1">{texts.subtitle}</p>
        </div>
        {canCreate && (
          <Button asChild className="gap-2 shrink-0">
            <Link href={newHref}>
              <Plus className="h-4 w-4" aria-hidden="true" />
              {texts.newCta}
            </Link>
          </Button>
        )}
      </div>

      {/* ── Sentido ── */}
      <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filtrar por sentido">
        {DELIVERY_NOTE_SENTIDO_TABS.map((t) => (
          <Button
            key={t.value}
            type="button"
            variant={sentido === t.value ? "default" : "outline"}
            size="sm"
            className="h-8 text-xs"
            aria-pressed={sentido === t.value}
            onClick={() => selectSentido(t.value)}
          >
            {t.label}
          </Button>
        ))}
      </div>

      {summary && (
        <p
          data-testid="delivery-notes-summary"
          className="rounded-md border border-border bg-accent/20 px-3 py-2 text-sm text-foreground"
        >
          {summary.pending_count > 0 ? (
            <>
              <span className="font-semibold tabular-nums">
                {summary.pending_count} {texts.pendingNoun(summary.pending_count)}
              </span>{" "}
              por <span className="font-semibold tabular-nums">{formatMoney(Number(summary.pending_total))}</span>
              {isPurchase && missingPriceCount > 0 ? (
                <span className="text-warning tabular-nums"> ({missingPriceCount} sin precio)</span>
              ) : null}
            </>
          ) : (
            <span className="text-muted-foreground">{texts.summaryNoPending}</span>
          )}
        </p>
      )}

      {(branchFilter || activeClient || activeSupplier) && (
        <div className="flex flex-wrap items-center gap-2" aria-label="Filtros aplicados">
          {branchFilter && (
            <FilterChip
              testId="delivery-note-branch-filter"
              label={`Sucursal: ${branchFilterName ?? "seleccionada"}`}
              removeLabel="Quitar filtro de sucursal"
              onRemove={removeBranchFilter}
            />
          )}
          {activeClient && (
            <FilterChip
              testId="delivery-note-client-filter"
              label={`Cliente: ${clientFilterName ?? "seleccionado"}`}
              removeLabel="Quitar filtro de cliente"
              onRemove={removeClientFilter}
            />
          )}
          {activeSupplier && (
            <FilterChip
              testId="delivery-note-supplier-filter"
              label={`Proveedor: ${supplierFilterName ?? "seleccionado"}`}
              removeLabel="Quitar filtro de proveedor"
              onRemove={removeSupplierFilter}
            />
          )}
        </div>
      )}

      {/* ── Filtros ── */}
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filtrar por estado">
          {DELIVERY_NOTE_ESTADO_TABS.map((t) => (
            <Button
              key={t.value}
              type="button"
              variant={estado === t.value ? "default" : "outline"}
              size="sm"
              className="h-8 text-xs"
              aria-pressed={estado === t.value}
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
            aria-label={texts.searchLabel}
            placeholder={texts.searchPlaceholder}
            value={searchInput}
            onChange={(e) => changeSearch(e.target.value)}
            className="pl-9 bg-background border-border text-foreground"
          />
        </div>
      </div>

      {/* ── Listado ── */}
      {isLoading ? (
        <p className="px-4 py-10 text-center text-sm text-muted-foreground" role="status">
          Cargando remitos…
        </p>
      ) : isError ? (
        <p className="px-4 py-10 text-center text-sm text-destructive" role="alert">
          No se pudieron cargar los remitos. Probá de nuevo en un momento.
        </p>
      ) : items.length === 0 ? (
        <Card className="border-border bg-card">
          <CardContent
            data-testid="delivery-notes-empty"
            className="flex flex-col items-center gap-3 px-4 py-14 text-center text-muted-foreground"
          >
            <PackageCheck className="h-10 w-10 opacity-30" aria-hidden="true" />
            <p className="text-sm font-medium text-foreground">{emptyText.title}</p>
            <p className="max-w-md text-xs">{emptyText.body}</p>
            {showEmptyCta && (
              <Button asChild size="sm" className="gap-2">
                <Link href={newHref}>
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
                <table className={isPurchase ? "w-full min-w-[900px] text-sm" : "w-full min-w-[820px] text-sm"}>
                  <thead>
                    <tr className="border-b border-border text-left">
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Número</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">{texts.counterpartHeader}</th>
                      {isPurchase && (
                        <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Remito del proveedor</th>
                      )}
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Fecha</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">{texts.branchHeader}</th>
                      <th scope="col" className="px-4 py-3 text-right font-medium text-muted-foreground">Ítems</th>
                      <th scope="col" className="px-4 py-3 text-right font-medium text-muted-foreground">Total</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Estado</th>
                    </tr>
                  </thead>
                  <tbody>
                    {items.map((note) => (
                      <tr
                        key={note.id}
                        data-testid={`delivery-note-row-${note.id}`}
                        className="border-b border-border/50 last:border-b-0 transition-colors hover:bg-accent/20"
                      >
                        <td className="px-4 py-3 font-medium whitespace-nowrap">
                          <Link href={`/remitos/${note.id}`} className="text-primary underline-offset-2 hover:underline">
                            {numberLabel(note)}
                          </Link>
                        </td>
                        <td className="px-4 py-3 max-w-[240px] truncate text-foreground">{counterpartName(note)}</td>
                        {isPurchase && (
                          <td className="px-4 py-3 max-w-[180px] truncate tabular-nums text-muted-foreground">
                            {note.supplier_reference || "—"}
                          </td>
                        )}
                        <td className="px-4 py-3 whitespace-nowrap tabular-nums text-muted-foreground">
                          {formatDate(note.issued_on)}
                        </td>
                        <td className="px-4 py-3 max-w-[180px] truncate text-muted-foreground">{note.branch_name ?? "—"}</td>
                        <td className="px-4 py-3 text-right tabular-nums text-muted-foreground">{note.item_count ?? 0}</td>
                        <td className="px-4 py-3 text-right font-semibold tabular-nums text-foreground whitespace-nowrap">
                          {formatMoney(Number(note.total))}
                        </td>
                        <td className="px-4 py-3">
                          <div className="flex flex-wrap items-center gap-1">
                            <DeliveryNoteStatusBadge status={note.status} direction={note.direction} />
                            {hasMissingPrice(note) && <NoPriceBadge noteId={note.id} />}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>

          {/* Móvil: tarjetas */}
          <ul className="flex flex-col gap-2 md:hidden" aria-label="Remitos">
            {items.map((note) => (
              <li key={note.id}>
                <Link
                  href={`/remitos/${note.id}`}
                  data-testid={`delivery-note-card-${note.id}`}
                  className="flex flex-col gap-2 rounded-lg border border-border bg-card p-4 transition-colors hover:bg-accent/20"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="font-medium text-foreground truncate">{counterpartName(note)}</p>
                      <p className="text-xs text-muted-foreground">
                        {numberLabel(note)}
                        {isPurchase && note.supplier_reference ? ` · Remito ${note.supplier_reference}` : ""}
                      </p>
                    </div>
                    <div className="flex shrink-0 flex-col items-end gap-1">
                      <DeliveryNoteStatusBadge status={note.status} direction={note.direction} />
                      {hasMissingPrice(note) && <NoPriceBadge noteId={`${note.id}-card`} />}
                    </div>
                  </div>
                  <div className="flex items-end justify-between gap-2 text-xs">
                    <div className="flex min-w-0 flex-col text-muted-foreground">
                      <span className="tabular-nums">{formatDate(note.issued_on)}</span>
                      <span className="truncate">
                        {note.branch_name ?? "—"} · {note.item_count ?? 0} {(note.item_count ?? 0) === 1 ? "ítem" : "ítems"}
                      </span>
                    </div>
                    <span className="text-base font-semibold tabular-nums text-foreground">
                      {formatMoney(Number(note.total))}
                    </span>
                  </div>
                </Link>
              </li>
            ))}
          </ul>

          {pages > 1 && (
            <div className="flex items-center justify-between gap-2">
              <span className="text-xs text-muted-foreground tabular-nums">
                Página {page + 1} de {pages} · {data?.total ?? 0} remitos
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
