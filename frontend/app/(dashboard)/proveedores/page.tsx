"use client"

// compras-proveedor-cuenta-corriente (D9): molde de /clientes, con menos
// columnas — sin read-model de actividad (OQ-6 fuera de alcance: no hay
// historial de compras por proveedor todavía). Listado plano (GET /suppliers
// no está paginado, D9/backend/routers/suppliers.py), búsqueda client-side,
// alta/edición en Dialog, baja con confirmación (AlertDialog, molde de
// product-catalog.tsx DeleteDialog), export CSV, banner + botón deshabilitado
// al alcanzar el límite de plan (usePlanLimits — afordancia, el enforcement
// real es el trigger + 403 del backend).

import { useState, useMemo, useCallback } from "react"
import { useRouter } from "next/navigation"
import { useSuppliers } from "@/hooks/data/use-suppliers"
import { SupplierForm } from "@/components/forms/supplier-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { exportToCSV } from "@/lib/excel"
import { MAX_SUPPLIERS_FREE } from "@/lib/constants"
import { Plus, Trash2, Pencil, Search, PackageOpen, Download, Landmark } from "lucide-react"
import { toast } from "sonner"
import type { Supplier } from "@/lib/types"

// ─── Delete confirmation (molde de components/products/product-catalog.tsx) ──

interface DeleteSupplierDialogProps {
  supplier: Supplier
  onConfirm: (id: string) => void
  isDeleting: boolean
}

function DeleteSupplierDialog({ supplier, onConfirm, isDeleting }: DeleteSupplierDialogProps) {
  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="h-7 w-7 text-muted-foreground hover:text-destructive"
          data-testid={`supplier-delete-${supplier.id}`}
          disabled={isDeleting}
        >
          <Trash2 className="h-3.5 w-3.5" />
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent className="bg-card border-border">
        <AlertDialogHeader>
          <AlertDialogTitle className="text-card-foreground">
            Confirmar eliminación
          </AlertDialogTitle>
          <AlertDialogDescription>
            ¿Eliminar &quot;{supplier.name}&quot;? Esta acción no se puede deshacer.
            Las compras que ya lo referencian siguen siendo legibles.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel className="border-border text-foreground">
            Cancelar
          </AlertDialogCancel>
          <AlertDialogAction
            onClick={() => onConfirm(supplier.id)}
            disabled={isDeleting}
            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
          >
            {isDeleting ? "Eliminando…" : "Eliminar"}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}

export default function ProveedoresPage() {
  const router = useRouter()
  const { suppliers, isLoading, error, deleteSupplier } = useSuppliers()
  const { limits } = usePlanLimits()
  const [search, setSearch] = useState("")
  const [open, setOpen] = useState(false)
  const [editingSupplier, setEditingSupplier] = useState<Supplier | undefined>()
  const [deletingId, setDeletingId] = useState<string | null>(null)

  // ── Plan limit gate (afordancia — el enforcement real es el trigger + 403) ──
  const maxSuppliers = limits?.maxSuppliers ?? MAX_SUPPLIERS_FREE
  const isAtSupplierLimit = suppliers.length >= maxSuppliers

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return suppliers
    return suppliers.filter(
      (s) =>
        s.name.toLowerCase().includes(q) ||
        (s.email ?? "").toLowerCase().includes(q),
    )
  }, [suppliers, search])

  // ── Actions ───────────────────────────────────────────────────────────────
  const handleDelete = useCallback(
    async (id: string) => {
      setDeletingId(id)
      try {
        await deleteSupplier(id)
        toast.success("Proveedor eliminado")
      } catch (err: any) {
        toast.error(err?.message || "Error al eliminar")
      } finally {
        setDeletingId(null)
      }
    },
    [deleteSupplier],
  )

  function handleEdit(supplier: Supplier) {
    setEditingSupplier(supplier)
    setOpen(true)
  }

  function goToAccount(id: string) {
    router.push(`/proveedores/${id}/cuenta`)
  }

  function handleExport() {
    exportToCSV(
      suppliers.map((s) => ({
        name: s.name,
        email: s.email ?? "",
        phone: s.phone ?? "",
        taxId: s.taxId ?? "",
        ivaCondition: s.ivaCondition ?? "",
        legalName: s.legalName ?? "",
      })),
      [
        { key: "name", header: "Nombre" },
        { key: "email", header: "Email" },
        { key: "phone", header: "Teléfono" },
        { key: "taxId", header: "CUIT/DNI" },
        { key: "ivaCondition", header: "Condición IVA" },
        { key: "legalName", header: "Razón social" },
      ],
      "proveedores",
    )
    toast.success(`Exportados ${suppliers.length} proveedores`)
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Proveedores</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {suppliers.length > 0 ? `${suppliers.length} proveedores registrados` : ""}
        </p>
      </div>

      {/* Controls */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="relative w-full sm:w-72">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Buscar por nombre o email..."
            className="pl-9 bg-background border-border text-foreground"
          />
        </div>

        <div className="flex items-center gap-2 flex-wrap">
          <Button variant="outline" size="sm" className="border-border text-foreground" onClick={handleExport}>
            <Download className="h-4 w-4 mr-1" />Exportar
          </Button>
          <Button
            onClick={() => { setEditingSupplier(undefined); setOpen(true) }}
            size="sm"
            disabled={isAtSupplierLimit}
            title={isAtSupplierLimit ? `Límite de ${maxSuppliers} proveedores alcanzado` : undefined}
          >
            <Plus className="h-4 w-4 mr-1" />Nuevo proveedor
          </Button>
        </div>
      </div>

      {isAtSupplierLimit && (
        <div className="rounded-lg border border-warning/30 bg-warning/10 p-4">
          <p className="text-sm text-warning">
            Llegaste al límite de {maxSuppliers} proveedores de tu plan. Actualizá tu plan para tener más capacidad.
          </p>
        </div>
      )}

      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {(error as Error).message || "Error al cargar proveedores"}
        </div>
      )}

      {/* Table */}
      <div className="rounded-lg border border-border overflow-hidden">
        <div className="hidden sm:grid grid-cols-[1fr_200px_160px_104px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Nombre</span><span>Contacto</span><span>CUIT/DNI</span><span />
        </div>

        {/* Skeleton */}
        {isLoading && suppliers.length === 0 && (
          <div className="flex flex-col">
            {Array.from({ length: 4 }).map((_, i) => (
              <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                <div className="hidden sm:grid grid-cols-[1fr_200px_160px_104px] gap-3 items-center">
                  {Array.from({ length: 3 }).map((_, j) => (
                    <div key={j} className="h-3.5 rounded bg-accent animate-pulse" />
                  ))}
                  <div />
                </div>
                <div className="sm:hidden h-14 rounded bg-accent animate-pulse" />
              </div>
            ))}
          </div>
        )}

        {!isLoading && filtered.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {search ? "Sin resultados para esa búsqueda" : "No hay proveedores registrados"}
            </p>
            {!search && (
              <Button variant="outline" size="sm" onClick={() => { setEditingSupplier(undefined); setOpen(true) }}>
                <Plus className="h-4 w-4 mr-1" />Agregar primer proveedor
              </Button>
            )}
          </div>
        )}

        {filtered.map((row) => (
          <div
            key={row.id}
            data-testid={`supplier-row-${row.id}`}
            className="border-t border-border/50 first:border-t-0 hover:bg-accent/20 transition-colors"
          >
            {/* Mobile */}
            <div className="sm:hidden flex flex-col gap-2 px-4 py-3">
              <div className="min-w-0">
                <p className="font-medium text-sm text-foreground truncate">{row.name}</p>
                <p className="text-xs text-muted-foreground truncate">
                  {row.email || row.phone || "Sin datos de contacto"}
                </p>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-xs text-muted-foreground tabular-nums">{row.taxId || "—"}</span>
                <div className="flex items-center gap-1">
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                    data-testid={`supplier-account-${row.id}`}
                    title="Cuenta corriente" onClick={() => goToAccount(row.id)}>
                    <Landmark className="h-3.5 w-3.5" />
                  </Button>
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                    data-testid={`supplier-edit-${row.id}`}
                    onClick={() => handleEdit(row)}>
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <DeleteSupplierDialog supplier={row} onConfirm={handleDelete} isDeleting={deletingId === row.id} />
                </div>
              </div>
            </div>

            {/* Desktop */}
            <div className="hidden sm:grid grid-cols-[1fr_200px_160px_104px] gap-3 px-4 py-3 items-center">
              <span className="text-sm font-medium text-foreground truncate">{row.name}</span>
              <span className="text-xs text-muted-foreground truncate">
                {row.email || row.phone || "Sin datos de contacto"}
              </span>
              <span className="text-xs text-muted-foreground tabular-nums">{row.taxId || "—"}</span>
              <div className="flex items-center gap-1 justify-end">
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                  data-testid={`supplier-account-${row.id}`}
                  title="Cuenta corriente" onClick={() => goToAccount(row.id)}>
                  <Landmark className="h-3.5 w-3.5" />
                </Button>
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                  data-testid={`supplier-edit-${row.id}`}
                  onClick={() => handleEdit(row)}>
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <DeleteSupplierDialog supplier={row} onConfirm={handleDelete} isDeleting={deletingId === row.id} />
              </div>
            </div>
          </div>
        ))}
      </div>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              {editingSupplier ? "Editar proveedor" : "Nuevo proveedor"}
            </DialogTitle>
          </DialogHeader>
          <SupplierForm
            initialData={editingSupplier}
            onSuccess={() => { setOpen(false); setEditingSupplier(undefined) }}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
