"use client"

import { useState, useCallback, type KeyboardEvent, type MouseEvent } from "react"
import { useRouter } from "next/navigation"
import { useClients } from "@/hooks/data/use-clients"
import {
  useClientActivityList,
  type ClientActivity,
  type ClientActivityStatus,
  type ClientActivitySort,
} from "@/hooks/data/use-client-activity"
import { ClientActivityBadge } from "@/components/clientes/ClientActivityBadge"
import { ClientForm } from "@/components/forms/client-form"
import { ClientImportDialog } from "@/components/clientes/client-import-dialog"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { exportToCSV } from "@/lib/excel"
import { MAX_CLIENTS_FREE } from "@/lib/constants"
import {
  Plus, Trash2, Pencil, Search, PackageOpen, Download, Upload, Loader2,
  ArrowUpDown, Landmark,
} from "lucide-react"
import { toast } from "sonner"
import type { Client, IvaCondition } from "@/lib/types"

/** ClientForm sólo lee name/email/phone/taxId/ivaCondition/legalName/id de
 * `initialData` (más category, que no persiste el backend Python — queda
 * como default). Mapeo explícito en vez de `as any`.
 * deudas-menores-agosto (G2): `status` ya no se envía — el campo manual
 * dejó de tener superficie de lectura o edición (Client.status es legacy). */
function toFormInitialData(c: ClientActivity): Client {
  return {
    id:           c.id,
    name:         c.name,
    email:        c.email,
    phone:        c.phone,
    lastPurchase: "-",
    totalSpent:   c.totalSpent,
    taxId:        c.taxId,
    ivaCondition: c.ivaCondition as IvaCondition | undefined,
    legalName:    c.legalName,
  }
}

const ACTIVITY_STATUS_OPTIONS: { value: ClientActivityStatus | ""; label: string }[] = [
  { value: "",             label: "Todos los estados" },
  { value: "frecuente",    label: "Frecuente" },
  { value: "activo",       label: "Activo" },
  { value: "inactivo",     label: "Inactivo" },
  { value: "sin_compras",  label: "Sin compras" },
]

const SORT_OPTIONS: { value: ClientActivitySort; label: string }[] = [
  { value: "name",            label: "Nombre" },
  { value: "last_purchase",   label: "Última compra" },
  { value: "total_spent",     label: "Total comprado" },
  { value: "purchase_count",  label: "Cantidad de compras" },
]

const currencyFormatter = new Intl.NumberFormat("es-AR", {
  style: "currency",
  currency: "ARS",
  maximumFractionDigits: 0,
})

function formatLastPurchase(dateStr: string | null, days: number | null): string {
  if (!dateStr || days == null) return "Sin compras"
  if (days === 0) return "Hoy"
  if (days === 1) return "Hace 1 día"
  return `Hace ${days} días`
}

export default function ClientesPage() {
  const router = useRouter()
  const { deleteClient } = useClients()
  const { isAdmin } = useAuth()
  const { limits } = usePlanLimits()
  const [importOpen,    setImportOpen]    = useState(false)
  const [open,          setOpen]          = useState(false)
  const [editingClient, setEditingClient] = useState<ClientActivity | undefined>()
  const [deletingId,    setDeletingId]    = useState<string | null>(null)

  const act = useClientActivityList()
  const clients = act.clients

  // ── Plan limit gate (C-02) ────────────────────────────────────────────────
  const maxClients = limits?.maxClients ?? MAX_CLIENTS_FREE
  const isAtClientLimit = act.meta.totalCount >= maxClients

  // ── Navegación al detalle (client-purchase-history §"Navegación desde la lista") ──
  const goToDetail = useCallback((id: string) => {
    router.push(`/clientes/${id}`)
  }, [router])

  const handleRowKeyDown = useCallback((e: KeyboardEvent<HTMLDivElement>, id: string) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault()
      goToDetail(id)
    }
  }, [goToDetail])

  // cobranzas-panel (task 6.6): acceso directo a la cuenta corriente desde la
  // fila — patrón de /proveedores. stopPropagation: el acceso NO debe disparar
  // la activación de la fila que abre el detalle.
  const goToAccount = useCallback((e: MouseEvent, id: string) => {
    e.stopPropagation()
    router.push(`/clientes/${id}/cuenta`)
  }, [router])

  // Los controles dentro de la fila (editar/borrar) detienen la propagación
  // para no disparar la navegación (client-purchase-history §"Acciones de la
  // fila no navegan").
  const stopRowNavigation = (e: MouseEvent) => e.stopPropagation()

  // ── Actions ───────────────────────────────────────────────────────────────
  const handleDelete = useCallback(async (e: MouseEvent, id: string) => {
    stopRowNavigation(e)
    setDeletingId(id)
    try {
      await deleteClient(id)
      toast.success("Cliente eliminado")
      act.refetch()
    } catch (err: any) {
      toast.error(err?.message || "Error al eliminar")
    } finally {
      setDeletingId(null)
    }
  }, [deleteClient, act])

  const handleEdit = (e: MouseEvent, client: typeof clients[number]) => {
    stopRowNavigation(e)
    setEditingClient(client)
    setOpen(true)
  }

  function handleExport() {
    exportToCSV(clients.map((c) => ({
      name:          c.name,
      email:         c.email,
      phone:         c.phone,
      activityStatus: c.activityStatus,
      lastPurchaseDate: c.lastPurchaseDate ?? "",
      totalSpent:    c.totalSpent,
      purchaseCount: c.purchaseCount,
    })), [
      { key: "name",              header: "Nombre"              },
      { key: "email",             header: "Email"               },
      { key: "phone",             header: "Teléfono"            },
      { key: "activityStatus",    header: "Estado de actividad" },
      { key: "lastPurchaseDate",  header: "Última compra"       },
      { key: "totalSpent",        header: "Total comprado"      },
      { key: "purchaseCount",     header: "Cantidad de compras" },
    ], "clientes")
    toast.success(`Exportados ${clients.length} clientes`)
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Clientes</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {/* G10 (H25): unificado con el criterio del contador de la barra de
              filtros de esta misma pantalla ("1 cliente"). */}
          {act.meta.totalCount > 0
            ? act.meta.totalCount === 1
              ? "1 cliente registrado"
              : `${act.meta.totalCount} clientes registrados`
            : ""}
        </p>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper moduleType="clientes" title="Analíticas de Clientes" subtitle="Segmentación y retención" />
      )}

      {/* Controls */}
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center flex-1">
          <div className="relative w-full sm:w-72">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input
              value={act.search}
              onChange={(e) => act.setSearch(e.target.value)}
              placeholder="Buscar por nombre o email..."
              className="pl-9 bg-background border-border text-foreground"
            />
          </div>

          <label htmlFor="client-activity-status-filter" className="sr-only">
            Estado de actividad
          </label>
          <select
            id="client-activity-status-filter"
            aria-label="Estado de actividad"
            value={act.activityStatus ?? ""}
            onChange={(e) => act.setActivityStatus((e.target.value || null) as ClientActivityStatus | null)}
            className="h-9 rounded-md border border-border bg-background px-3 text-sm text-foreground"
          >
            {ACTIVITY_STATUS_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </select>

          <div className="flex items-center gap-1">
            <label htmlFor="client-activity-sort" className="sr-only">
              Ordenar por
            </label>
            <select
              id="client-activity-sort"
              aria-label="Ordenar por"
              value={act.sort}
              onChange={(e) => act.setSort(e.target.value as ClientActivitySort)}
              className="h-9 rounded-md border border-border bg-background px-3 text-sm text-foreground"
            >
              {SORT_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </select>
            <Button
              type="button"
              variant="outline"
              size="icon"
              className="h-9 w-9 border-border shrink-0"
              title={act.sortDir === "asc" ? "Ascendente" : "Descendente"}
              onClick={() => act.setSort(act.sort)}
            >
              <ArrowUpDown className="h-3.5 w-3.5" />
            </Button>
          </div>
        </div>

        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">
            {act.isLoading
              ? <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Cargando...</span>
              : `${act.meta.totalCount} cliente${act.meta.totalCount !== 1 ? "s" : ""}`
            }
          </span>
          <Button variant="outline" size="sm" className="border-border text-foreground"
            onClick={() => setImportOpen(true)}>
            <Upload className="h-4 w-4 mr-1" />Importar CSV
          </Button>
          <Button variant="outline" size="sm" className="border-border text-foreground" onClick={handleExport}>
            <Download className="h-4 w-4 mr-1" />Exportar
          </Button>
          <Button
            onClick={() => { setEditingClient(undefined); setOpen(true) }}
            size="sm"
            disabled={isAtClientLimit}
            title={isAtClientLimit ? `Límite de ${maxClients} clientes alcanzado` : undefined}
          >
            <Plus className="h-4 w-4 mr-1" />Nuevo cliente
          </Button>
        </div>
      </div>

      {isAtClientLimit && (
        <div className="rounded-lg border border-warning/30 bg-warning/10 p-4">
          <p className="text-sm text-warning">
            Llegaste al límite de {maxClients} clientes de tu plan. Actualizá tu plan para tener más capacidad.
          </p>
        </div>
      )}

      {act.error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {act.error}
        </div>
      )}

      {/* Table */}
      <div className="rounded-lg border border-border overflow-hidden">
        <div className="hidden sm:grid grid-cols-[1fr_120px_140px_130px_110px_80px_100px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Nombre</span><span>Estado</span><span>Última compra</span>
          <span>Total comprado</span><span>Saldo</span><span>Compras</span><span />
        </div>

        {/* Skeleton */}
        {act.isLoading && clients.length === 0 && (
          <div className="flex flex-col">
            {Array.from({ length: 6 }).map((_, i) => (
              <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                <div className="hidden sm:grid grid-cols-[1fr_120px_140px_130px_110px_80px_100px] gap-3 items-center">
                  {Array.from({ length: 6 }).map((_, j) => (
                    <div key={j} className="h-3.5 rounded bg-accent animate-pulse" />
                  ))}
                  <div />
                </div>
                <div className="sm:hidden h-20 rounded bg-accent animate-pulse" />
              </div>
            ))}
          </div>
        )}

        {!act.isLoading && clients.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {act.search ? "Sin resultados para esa búsqueda" : "No hay clientes registrados"}
            </p>
            {!act.search && (
              <Button variant="outline" size="sm" onClick={() => { setEditingClient(undefined); setOpen(true) }}>
                <Plus className="h-4 w-4 mr-1" />Agregar primer cliente
              </Button>
            )}
          </div>
        )}

        {clients.map((row) => (
          <div
            key={row.id}
            data-testid={`client-row-${row.id}`}
            role="button"
            tabIndex={0}
            onClick={() => goToDetail(row.id)}
            onKeyDown={(e) => handleRowKeyDown(e, row.id)}
            className="border-t border-border/50 first:border-t-0 hover:bg-accent/20 transition-colors cursor-pointer focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset"
          >
            {/* Mobile */}
            <div className="sm:hidden flex flex-col gap-2 px-4 py-3">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="font-medium text-sm text-foreground truncate">{row.name}</p>
                  <p className="text-xs text-muted-foreground truncate">{row.email}</p>
                </div>
                <ClientActivityBadge status={row.activityStatus} className="shrink-0" />
              </div>
              <div className="flex items-center justify-between gap-2">
                <span className="text-xs text-muted-foreground tabular-nums min-w-0 truncate">
                  {formatLastPurchase(row.lastPurchaseDate, row.daysSinceLastPurchase)} · {currencyFormatter.format(row.totalSpent)}
                  {/* cobranzas-panel (task 6.6): saldo visible también en móvil */}
                  {" · "}
                  <span className={row.currentBalance > 0 ? "text-warning font-medium" : undefined}>
                    Saldo {currencyFormatter.format(row.currentBalance)}
                  </span>
                </span>
                <div className="flex items-center gap-1 shrink-0">
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                    data-testid={`client-account-${row.id}`}
                    aria-label={`Cuenta corriente de ${row.name}`}
                    onClick={(e) => goToAccount(e, row.id)}>
                    <Landmark className="h-3.5 w-3.5" />
                  </Button>
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                    data-testid={`client-edit-${row.id}`}
                    onClick={(e) => handleEdit(e, row)}>
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-destructive"
                    data-testid={`client-delete-${row.id}`}
                    disabled={deletingId === row.id} onClick={(e) => handleDelete(e, row.id)}>
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              </div>
            </div>

            {/* Desktop */}
            <div className="hidden sm:grid grid-cols-[1fr_120px_140px_130px_110px_80px_100px] gap-3 px-4 py-3 items-center">
              <div className="flex flex-col min-w-0">
                <span className="text-sm font-medium text-foreground truncate">{row.name}</span>
                <span className="text-[10px] text-muted-foreground truncate">{row.email}</span>
              </div>
              <ClientActivityBadge status={row.activityStatus} className="w-fit" />
              <span className="text-xs text-muted-foreground truncate">
                {formatLastPurchase(row.lastPurchaseDate, row.daysSinceLastPurchase)}
              </span>
              <span className="text-sm text-foreground tabular-nums">
                {currencyFormatter.format(row.totalSpent)}
              </span>
              {/* cobranzas-panel (task 6.6): saldo de cuenta corriente — el
                  importe comunica por texto; el color solo refuerza. */}
              <span className={`text-sm tabular-nums ${row.currentBalance > 0 ? "text-warning font-medium" : "text-muted-foreground"}`}>
                {currencyFormatter.format(row.currentBalance)}
              </span>
              <span className="text-sm text-muted-foreground tabular-nums">{row.purchaseCount}</span>
              <div className="flex items-center gap-1 justify-end">
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                  data-testid={`client-account-${row.id}`}
                  aria-label={`Cuenta corriente de ${row.name}`}
                  onClick={(e) => goToAccount(e, row.id)}>
                  <Landmark className="h-3.5 w-3.5" />
                </Button>
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                  data-testid={`client-edit-${row.id}`}
                  onClick={(e) => handleEdit(e, row)}>
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-destructive"
                  data-testid={`client-delete-${row.id}`}
                  disabled={deletingId === row.id} onClick={(e) => handleDelete(e, row.id)}>
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </div>
            </div>
          </div>
        ))}
      </div>

      <PaginationBar
        meta={act.meta}
        onPageChange={act.setPage}
        onSizeChange={act.setPageSize}
        loading={act.isLoading}
        label="clientes"
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              {editingClient ? "Editar cliente" : "Nuevo cliente"}
            </DialogTitle>
          </DialogHeader>
          <ClientForm
            initialData={editingClient ? toFormInitialData(editingClient) : undefined}
            onSuccess={() => { setOpen(false); setEditingClient(undefined); act.refetch() }}
          />
        </DialogContent>
      </Dialog>

      <ClientImportDialog
        open={importOpen}
        onOpenChange={setImportOpen}
        onSuccess={() => act.refetch()}
      />
    </div>
  )
}
