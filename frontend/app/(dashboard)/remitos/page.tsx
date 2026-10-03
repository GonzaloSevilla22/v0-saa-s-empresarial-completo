"use client"

/**
 * /remitos — listado de remitos de venta (remitos-venta D11, tarea 5.4).
 *
 * El filtro de estado, la búsqueda (nombre del cliente o número: "R-12", "12",
 * "00000012") y la paginación los resuelve el SERVIDOR; la pantalla sólo pide.
 * Siempre pide `direction=sale`: en este change el remito sólo tiene sentido de
 * venta y NO hay pestañas de sentido (OQ-RV6) — `remitos-compra` las suma sin
 * cambiar el contrato.
 *
 * **Contrato único de la URL** (D11), en castellano como el `?cliente=` de
 * /presupuestos/nuevo y combinable: `?estado=todos|pendientes|convertidos|anulados`
 * preselecciona la pestaña, y `?sucursal=<id>` y `?cliente=<id>` se aplican como
 * chips removibles. Los únicos enlaces que llegan filtrados lo usan: el de
 * `DeactivateBranchDialog` y el "Ver remitos" de la ficha del cliente. La pantalla
 * mantiene la URL en sintonía con lo que se ve (`router.replace`), así que un
 * listado filtrado se puede copiar y volver a abrir.
 *
 * Encabezado: el resumen "N remitos pendientes por $ X" que calcula el servidor
 * sobre el mismo recorte, sin importar la pestaña (no cambia al cambiar de
 * pestaña). Tabla en escritorio y tarjetas en móvil, con el mismo contenido.
 * "Nuevo remito" sólo con `CAN_DELIVER_SALE`, decidido sobre el CONJUNTO de roles.
 */
import { useEffect, useState } from "react"
import Link from "next/link"
import { usePathname, useRouter, useSearchParams } from "next/navigation"
import { ChevronLeft, ChevronRight, PackageCheck, Plus, Search, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { DeliveryNoteStatusBadge } from "@/components/delivery-notes/DeliveryNoteStatusBadge"
import { useBranches } from "@/hooks/data/use-branches"
import { useClients } from "@/hooks/data/use-clients"
import { useDeliveryNotes } from "@/hooks/data/use-delivery-notes"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useDebounce } from "@/hooks/ui/use-debounce"
import {
  DELIVERY_NOTE_ESTADO_TABS,
  parseDeliveryNoteEstadoParam,
  type DeliveryNoteEstado,
} from "@/lib/delivery-note-status"
import type { DeliveryNoteListItem } from "@/lib/delivery-note-types"
import { formatDate, formatMoney } from "@/lib/format"
import { CAN_DELIVER_SALE, hasCapability } from "@/lib/rbac-capabilities"

const PAGE_SIZE = 25
const SEARCH_DEBOUNCE_MS = 300

function numberLabel(note: DeliveryNoteListItem): string {
  return note.number_label ?? "—"
}

/** `/remitos?estado=…&sucursal=…&cliente=…`, sólo con lo que no es el valor por defecto. */
function buildListHref(pathname: string, estado: DeliveryNoteEstado, branchId?: string, clientId?: string): string {
  const params = new URLSearchParams()
  if (estado !== "todos") params.set("estado", estado)
  if (branchId) params.set("sucursal", branchId)
  if (clientId) params.set("cliente", clientId)
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

export default function DeliveryNotesPage() {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()
  const paramsKey = searchParams.toString()

  const [estado, setEstado] = useState<DeliveryNoteEstado>(() => parseDeliveryNoteEstadoParam(searchParams.get("estado")))
  const [branchFilter, setBranchFilter] = useState<string | undefined>(() => searchParams.get("sucursal") ?? undefined)
  const [clientFilter, setClientFilter] = useState<string | undefined>(() => searchParams.get("cliente") ?? undefined)
  const [searchInput, setSearchInput] = useState("")
  const [page, setPage] = useState(0)
  const search = useDebounce(searchInput.trim(), SEARCH_DEBOUNCE_MS)

  // Una navegación externa a /remitos?… (sin remontar la página) re-lee la URL.
  useEffect(() => {
    setEstado(parseDeliveryNoteEstadoParam(searchParams.get("estado")))
    setBranchFilter(searchParams.get("sucursal") ?? undefined)
    setClientFilter(searchParams.get("cliente") ?? undefined)
    setPage(0)
    // `paramsKey` resume los tres parámetros; `searchParams` cambia de identidad en cada render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paramsKey])

  const { roles, rolesResolved } = useOrgRole()
  const canDeliver = hasCapability(roles, CAN_DELIVER_SALE, rolesResolved)
  const { branches } = useBranches()
  const { clients } = useClients()

  const activeTab = DELIVERY_NOTE_ESTADO_TABS.find((t) => t.value === estado) ?? DELIVERY_NOTE_ESTADO_TABS[0]

  const { data, isLoading, isError } = useDeliveryNotes({
    direction: "sale",
    status: activeTab.status,
    branchId: branchFilter,
    clientId: clientFilter,
    q: search || undefined,
    page,
    pageSize: PAGE_SIZE,
  })

  const items = data?.items ?? []
  const pages = data?.pages ?? 0
  const summary = data?.summary

  function syncUrl(nextEstado: DeliveryNoteEstado, nextBranch?: string, nextClient?: string) {
    router.replace(buildListHref(pathname, nextEstado, nextBranch, nextClient), { scroll: false })
  }

  function selectTab(next: DeliveryNoteEstado) {
    setEstado(next)
    setPage(0)
    syncUrl(next, branchFilter, clientFilter)
  }

  function removeBranchFilter() {
    setBranchFilter(undefined)
    setPage(0)
    syncUrl(estado, undefined, clientFilter)
  }

  function removeClientFilter() {
    setClientFilter(undefined)
    setPage(0)
    syncUrl(estado, branchFilter, undefined)
  }

  function changeSearch(value: string) {
    setSearchInput(value)
    setPage(0)
  }

  const branchFilterName = branchFilter ? (branches.find((b) => b.id === branchFilter)?.name ?? null) : null
  const clientFilterName = clientFilter ? (clients.find((c) => c.id === clientFilter)?.name ?? null) : null

  const emptyText = (() => {
    if (search) {
      return {
        title: "Ningún remito coincide con la búsqueda",
        body: "Probá con el nombre del cliente o con el número (por ejemplo R-12).",
      }
    }
    if (estado !== "todos") {
      return {
        title: `No hay remitos ${activeTab.label.toLowerCase()}`,
        body: "Cuando algún remito llegue a este estado, va a aparecer acá.",
      }
    }
    if (clientFilter) {
      return { title: "Este cliente todavía no tiene remitos", body: "Cuando le entregues mercadería con un remito, va a aparecer acá." }
    }
    if (branchFilter) {
      return { title: "Esta sucursal no tiene remitos", body: "Cuando salga mercadería de esta sucursal con un remito, va a aparecer acá." }
    }
    return {
      title: "Todavía no hay remitos",
      body: "Un remito documenta la mercadería que entregás antes de cobrar. El remito descuenta stock al emitirse y se convierte en venta cuando cobrás.",
    }
  })()
  const showEmptyCta = canDeliver && estado === "todos" && !search && !clientFilter && !branchFilter

  const newHref = clientFilter ? `/remitos/nuevo?cliente=${encodeURIComponent(clientFilter)}` : "/remitos/nuevo"

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Cabecera ── */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Remitos</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Entregá mercadería con un remito: descuenta stock al emitirse y lo pasás a venta cuando cobrás.
          </p>
        </div>
        {canDeliver && (
          <Button asChild className="gap-2 shrink-0">
            <Link href={newHref}>
              <Plus className="h-4 w-4" aria-hidden="true" />
              Nuevo remito
            </Link>
          </Button>
        )}
      </div>

      {summary && (
        <p
          data-testid="delivery-notes-summary"
          className="rounded-md border border-border bg-accent/20 px-3 py-2 text-sm text-foreground"
        >
          {summary.pending_count > 0 ? (
            <>
              <span className="font-semibold tabular-nums">
                {summary.pending_count} {summary.pending_count === 1 ? "remito pendiente" : "remitos pendientes"}
              </span>{" "}
              por <span className="font-semibold tabular-nums">{formatMoney(Number(summary.pending_total))}</span>
            </>
          ) : (
            <span className="text-muted-foreground">No hay remitos pendientes de convertir en venta.</span>
          )}
        </p>
      )}

      {(branchFilter || clientFilter) && (
        <div className="flex flex-wrap items-center gap-2" aria-label="Filtros aplicados">
          {branchFilter && (
            <FilterChip
              testId="delivery-note-branch-filter"
              label={`Sucursal: ${branchFilterName ?? "seleccionada"}`}
              removeLabel="Quitar filtro de sucursal"
              onRemove={removeBranchFilter}
            />
          )}
          {clientFilter && (
            <FilterChip
              testId="delivery-note-client-filter"
              label={`Cliente: ${clientFilterName ?? "seleccionado"}`}
              removeLabel="Quitar filtro de cliente"
              onRemove={removeClientFilter}
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
            aria-label="Buscar por cliente o número"
            placeholder="Buscar por cliente o número (R-12)"
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
                <table className="w-full min-w-[820px] text-sm">
                  <thead>
                    <tr className="border-b border-border text-left">
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Número</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Cliente</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Fecha</th>
                      <th scope="col" className="px-4 py-3 font-medium text-muted-foreground">Sucursal</th>
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
                        <td className="px-4 py-3 max-w-[240px] truncate text-foreground">
                          {note.client_name ?? "Sin cliente"}
                        </td>
                        <td className="px-4 py-3 whitespace-nowrap tabular-nums text-muted-foreground">
                          {formatDate(note.issued_on)}
                        </td>
                        <td className="px-4 py-3 max-w-[180px] truncate text-muted-foreground">{note.branch_name ?? "—"}</td>
                        <td className="px-4 py-3 text-right tabular-nums text-muted-foreground">{note.item_count ?? 0}</td>
                        <td className="px-4 py-3 text-right font-semibold tabular-nums text-foreground whitespace-nowrap">
                          {formatMoney(Number(note.total))}
                        </td>
                        <td className="px-4 py-3">
                          <DeliveryNoteStatusBadge status={note.status} />
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
                      <p className="font-medium text-foreground truncate">{note.client_name ?? "Sin cliente"}</p>
                      <p className="text-xs text-muted-foreground">{numberLabel(note)}</p>
                    </div>
                    <DeliveryNoteStatusBadge status={note.status} />
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
