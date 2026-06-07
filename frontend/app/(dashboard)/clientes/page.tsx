"use client"

import { useState, useCallback } from "react"
import { useData } from "@/contexts/data-context"
import { ClientForm } from "@/components/forms/client-form"
import { ClientImportDialog } from "@/components/clientes/client-import-dialog"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { usePaginatedQuery } from "@/hooks/use-paginated-query"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { exportToCSV } from "@/lib/excel"
import { MAX_CLIENTS_FREE } from "@/lib/constants"
import {
  Plus, Trash2, Pencil, Search, PackageOpen, Download, Upload, Loader2,
} from "lucide-react"
import { toast } from "sonner"
import type { Client } from "@/lib/types"

const statusColors: Record<string, string> = {
  activo:   "bg-emerald-500/20 text-emerald-400 border-emerald-500/30",
  inactivo: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  perdido:  "bg-red-500/20 text-red-400 border-red-500/30",
}

function mapRow(r: any): Client {
  return {
    id:           r.id,
    name:         r.name,
    email:        r.email || "",
    phone:        r.phone || "",
    status:       r.status || "activo",
    category:     r.category,
    lastPurchase: "-",   // computed separately; not needed in the list page
    totalSpent:   0,
  }
}

export default function ClientesPage() {
  const { deleteClient } = useData()
  const { isAdmin } = useAuth()
  const { limits } = usePlanLimits()
  const [importOpen,    setImportOpen]    = useState(false)
  const [open,          setOpen]          = useState(false)
  const [editingClient, setEditingClient] = useState<Client | undefined>()
  const [deletingId,    setDeletingId]    = useState<string | null>(null)

  // ── Paginated query — name/email search server-side ──────────────────────
  const pq = usePaginatedQuery<any>({
    table: "clients",
    applyFilters: (base, { search }) => {
      if (!search) return base
      // OR filter: name OR email
      return base.or(`name.ilike.%${search}%,email.ilike.%${search}%`)
    },
    defaultSortKey:  "name",
    defaultSortDir:  "asc",
    defaultPageSize: 25,
  })

  const clients = pq.data.map(mapRow)

  // ── Plan limit gate (C-02) ────────────────────────────────────────────────
  const maxClients = limits?.maxClients ?? MAX_CLIENTS_FREE
  const isAtClientLimit = pq.meta.totalCount >= maxClients

  // ── Actions ───────────────────────────────────────────────────────────────
  const handleDelete = useCallback(async (id: string) => {
    setDeletingId(id)
    try {
      await deleteClient(id)
      toast.success("Cliente eliminado")
      pq.refetch()
    } catch (err: any) {
      toast.error(err?.message || "Error al eliminar")
    } finally {
      setDeletingId(null)
    }
  }, [deleteClient, pq])

  function handleExport() {
    exportToCSV(clients as any[], [
      { key: "name",        header: "Nombre"         },
      { key: "email",       header: "Email"          },
      { key: "phone",       header: "Teléfono"       },
      { key: "status",      header: "Estado"         },
      { key: "category",    header: "Categoría"      },
    ], "clientes")
    toast.success(`Exportados ${clients.length} clientes`)
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Clientes</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {pq.meta.totalCount > 0 ? `${pq.meta.totalCount} clientes registrados` : ""}
        </p>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper moduleType="clientes" title="Analíticas de Clientes" subtitle="Segmentación y retención" />
      )}

      {/* Controls */}
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="relative w-full sm:w-72">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
          <Input
            value={pq.search}
            onChange={(e) => pq.setSearch(e.target.value)}
            placeholder="Buscar por nombre o email..."
            className="pl-9 bg-background border-border text-foreground"
          />
        </div>

        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">
            {pq.loading
              ? <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Cargando...</span>
              : `${pq.meta.totalCount} cliente${pq.meta.totalCount !== 1 ? "s" : ""}`
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
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/10 p-4">
          <p className="text-sm text-yellow-400">
            Llegaste al límite de {maxClients} clientes de tu plan. Actualizá tu plan para tener más capacidad.
          </p>
        </div>
      )}

      {pq.error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {pq.error}
        </div>
      )}

      {/* Table */}
      <div className="rounded-lg border border-border overflow-hidden">
        <div className="hidden sm:grid grid-cols-[1fr_140px_160px_100px_80px_72px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Nombre</span><span>Categoría</span><span>Email</span>
          <span>Teléfono</span><span>Estado</span><span />
        </div>

        {/* Skeleton */}
        {pq.loading && clients.length === 0 && (
          <div className="flex flex-col">
            {Array.from({ length: 6 }).map((_, i) => (
              <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                <div className="hidden sm:grid grid-cols-[1fr_140px_160px_100px_80px_72px] gap-3 items-center">
                  {Array.from({ length: 5 }).map((_, j) => (
                    <div key={j} className="h-3.5 rounded bg-accent animate-pulse" />
                  ))}
                  <div />
                </div>
                <div className="sm:hidden h-20 rounded bg-accent animate-pulse" />
              </div>
            ))}
          </div>
        )}

        {!pq.loading && clients.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {pq.search ? "Sin resultados para esa búsqueda" : "No hay clientes registrados"}
            </p>
            {!pq.search && (
              <Button variant="outline" size="sm" onClick={() => { setEditingClient(undefined); setOpen(true) }}>
                <Plus className="h-4 w-4 mr-1" />Agregar primer cliente
              </Button>
            )}
          </div>
        )}

        {clients.map((row) => (
          <div key={row.id} className="border-t border-border/50 first:border-t-0 hover:bg-accent/20 transition-colors">
            {/* Mobile */}
            <div className="sm:hidden flex flex-col gap-2 px-4 py-3">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="font-medium text-sm text-foreground truncate">{row.name}</p>
                  <p className="text-xs text-muted-foreground truncate">{row.email}</p>
                </div>
                <Badge variant="outline" className={`text-xs capitalize shrink-0 ${statusColors[row.status]}`}>
                  {row.status}
                </Badge>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-xs text-muted-foreground italic">{row.category || "Sin categoría"}</span>
                <div className="flex items-center gap-1">
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                    onClick={() => { setEditingClient(row); setOpen(true) }}>
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-destructive"
                    disabled={deletingId === row.id} onClick={() => handleDelete(row.id)}>
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              </div>
            </div>

            {/* Desktop */}
            <div className="hidden sm:grid grid-cols-[1fr_140px_160px_100px_80px_72px] gap-3 px-4 py-3 items-center">
              <div className="flex flex-col min-w-0">
                <span className="text-sm font-medium text-foreground truncate">{row.name}</span>
                <span className="text-[10px] text-muted-foreground truncate">{row.email}</span>
              </div>
              <span className="text-xs text-muted-foreground italic truncate">{row.category || "-"}</span>
              <span className="text-sm text-muted-foreground truncate">{row.email}</span>
              <span className="text-sm text-muted-foreground">{row.phone}</span>
              <Badge variant="outline" className={`text-xs capitalize w-fit ${statusColors[row.status]}`}>
                {row.status}
              </Badge>
              <div className="flex items-center gap-1 justify-end">
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                  onClick={() => { setEditingClient(row); setOpen(true) }}>
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-destructive"
                  disabled={deletingId === row.id} onClick={() => handleDelete(row.id)}>
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </div>
            </div>
          </div>
        ))}
      </div>

      <PaginationBar
        meta={pq.meta}
        onPageChange={pq.setPage}
        onSizeChange={pq.setPageSize}
        loading={pq.loading}
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
            initialData={editingClient}
            onSuccess={() => { setOpen(false); setEditingClient(undefined); pq.refetch() }}
          />
        </DialogContent>
      </Dialog>

      <ClientImportDialog
        open={importOpen}
        onOpenChange={setImportOpen}
        onSuccess={() => pq.refetch()}
      />
    </div>
  )
}
