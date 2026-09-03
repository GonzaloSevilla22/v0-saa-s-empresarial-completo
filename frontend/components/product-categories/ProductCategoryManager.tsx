"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { useProductCategories } from "@/hooks/data/use-product-categories"
import { useOrgRole } from "@/hooks/useOrgRole"
import { normalizeCategoryName } from "@/components/product-categories/ProductCategorySelect"
import { ArrowDown, ArrowUp, Loader2, Pencil, Plus, Power, PowerOff, Trash2 } from "lucide-react"
import { toast } from "sonner"
import type { ProductCategory } from "@/lib/types"

/**
 * Gestor del catálogo de categorías de producto (productos-categorias-sku).
 * Molde de PaymentMethodManager, sin `kind`.
 *
 * Lectura para todo miembro; crear / renombrar / reordenar / desactivar /
 * reactivar / eliminar sólo para owner/admin (useOrgRole.isWriter — la
 * barrera real es el backend + RLS). Montado como décima pestaña de
 * /configuracion (D8, sign-off del PO en OQ-2): un solo lugar para los
 * catálogos de la cuenta, junto a Centros de costo y Formas de pago.
 */
export function ProductCategoryManager() {
  const { isWriter } = useOrgRole()
  const {
    productCategories,
    isLoading,
    createProductCategory,
    updateProductCategory,
    deactivateProductCategory,
    deleteProductCategory,
    createProductCategoryMutation,
    updateProductCategoryMutation,
    deactivateProductCategoryMutation,
    deleteProductCategoryMutation,
  } = useProductCategories(true)

  const sorted = [...productCategories].sort(
    (a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name),
  )

  const [addOpen, setAddOpen] = useState(false)
  const [editing, setEditing] = useState<ProductCategory | null>(null)
  const [deleting, setDeleting] = useState<ProductCategory | null>(null)
  const [formName, setFormName] = useState("")

  function openAdd() {
    setFormName("")
    setAddOpen(true)
  }

  function openEdit(c: ProductCategory) {
    setFormName(c.name)
    setEditing(c)
  }

  function closeDialog() {
    setAddOpen(false)
    setEditing(null)
    setFormName("")
  }

  async function handleSave() {
    const name = normalizeCategoryName(formName)
    if (!name) {
      toast.error("El nombre es requerido")
      return
    }
    try {
      if (editing) {
        await updateProductCategory({ id: editing.id, name })
        toast.success("Categoría actualizada")
      } else {
        await createProductCategory({ name })
        toast.success("Categoría creada")
      }
      closeDialog()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error: ${msg}`)
    }
  }

  async function handleDeactivate(c: ProductCategory) {
    try {
      await deactivateProductCategory(c.id)
      toast.success(`"${c.name}" desactivada — los productos que la usan la conservan`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error al desactivar: ${msg}`)
    }
  }

  async function handleReactivate(c: ProductCategory) {
    try {
      await updateProductCategory({ id: c.id, isActive: true })
      toast.success(`"${c.name}" reactivada`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error al reactivar: ${msg}`)
    }
  }

  async function handleDelete() {
    if (!deleting) return
    try {
      await deleteProductCategory(deleting.id)
      toast.success(`"${deleting.name}" eliminada`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error al eliminar: ${msg}`)
    } finally {
      setDeleting(null)
    }
  }

  /**
   * Reordenar = intercambiar sort_order con el vecino (dos PATCH). Si los dos
   * comparten el mismo valor (sólo posible vía API), el movido toma el valor
   * del vecino ±1 para que el intercambio tenga efecto.
   */
  async function move(index: number, direction: -1 | 1) {
    const a = sorted[index]
    const b = sorted[index + direction]
    if (!a || !b) return
    let aNew = b.sortOrder
    let bNew = a.sortOrder
    if (aNew === bNew) {
      aNew = b.sortOrder + direction
    }
    try {
      await Promise.all([
        updateProductCategory({ id: a.id, sortOrder: aNew }),
        updateProductCategory({ id: b.id, sortOrder: bNew }),
      ])
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error al reordenar: ${msg}`)
    }
  }

  const isSaving = createProductCategoryMutation.isPending || updateProductCategoryMutation.isPending
  const iconBtn = "h-11 w-11 md:h-7 md:w-7"

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-medium text-foreground">Categorías de producto</h3>
        {isWriter && (
          <Button size="sm" variant="outline" onClick={openAdd}>
            <Plus className="h-4 w-4 mr-1" />
            Nueva
          </Button>
        )}
      </div>

      {isLoading ? (
        <div className="flex justify-center py-4">
          <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
        </div>
      ) : sorted.length === 0 ? (
        <p className="text-sm text-muted-foreground py-2">
          No hay categorías definidas.
          {isWriter && " Creá la primera para empezar a clasificar tus productos."}
        </p>
      ) : (
        <ul className="flex flex-col gap-2">
          {sorted.map((c, index) => (
            <li
              key={c.id}
              className="flex items-center justify-between rounded-md border border-border bg-card px-3 py-2"
            >
              <div className="flex items-center gap-2 min-w-0">
                <span className={`text-sm font-medium truncate ${c.isActive ? "text-foreground" : "text-muted-foreground line-through"}`}>
                  {c.name}
                </span>
                {!c.isActive && (
                  <Badge variant="secondary" className="text-xs shrink-0">
                    Inactiva
                  </Badge>
                )}
              </div>

              {isWriter && c.isActive && (
                <div className="flex items-center gap-1 shrink-0 ml-2">
                  <Button
                    size="icon"
                    variant="ghost"
                    className={iconBtn}
                    onClick={() => void move(index, -1)}
                    disabled={index === 0 || updateProductCategoryMutation.isPending}
                    aria-label={`Subir ${c.name}`}
                    title="Subir"
                  >
                    <ArrowUp className="h-3.5 w-3.5" />
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    className={iconBtn}
                    onClick={() => void move(index, 1)}
                    disabled={index === sorted.length - 1 || updateProductCategoryMutation.isPending}
                    aria-label={`Bajar ${c.name}`}
                    title="Bajar"
                  >
                    <ArrowDown className="h-3.5 w-3.5" />
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    className={iconBtn}
                    onClick={() => openEdit(c)}
                    aria-label={`Editar ${c.name}`}
                    title="Editar"
                  >
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    className={`${iconBtn} text-destructive hover:text-destructive`}
                    onClick={() => void handleDeactivate(c)}
                    disabled={deactivateProductCategoryMutation.isPending}
                    aria-label={`Desactivar ${c.name}`}
                    title="Desactivar"
                  >
                    <PowerOff className="h-3.5 w-3.5" />
                  </Button>
                </div>
              )}

              {isWriter && !c.isActive && (
                <div className="flex items-center gap-1 shrink-0 ml-2">
                  <Button
                    size="icon"
                    variant="ghost"
                    className={iconBtn}
                    onClick={() => void handleReactivate(c)}
                    disabled={updateProductCategoryMutation.isPending}
                    aria-label={`Reactivar ${c.name}`}
                    title="Reactivar"
                  >
                    <Power className="h-3.5 w-3.5" />
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    className={`${iconBtn} text-destructive hover:text-destructive`}
                    onClick={() => setDeleting(c)}
                    disabled={deleteProductCategoryMutation.isPending}
                    aria-label={`Eliminar ${c.name}`}
                    title="Eliminar"
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      {/* ── Create / Edit dialog ─────────────────────────────────────────── */}
      <Dialog
        open={addOpen || editing !== null}
        onOpenChange={(open) => { if (!open) closeDialog() }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{editing ? "Editar categoría" : "Nueva categoría"}</DialogTitle>
            <DialogDescription>
              {editing
                ? "Renombrarla se refleja en todos los productos que la usan — no se parten en dos."
                : "Elegí un nombre que describa lo que vendés. Después la podés renombrar, reordenar o desactivar."}
            </DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-2 py-2">
            <Label htmlFor="pc-name">Nombre *</Label>
            <Input
              id="pc-name"
              value={formName}
              onChange={(e) => setFormName(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); void handleSave() } }}
              placeholder="Ej: Ferretería, Bebidas, Indumentaria"
              className="bg-background border-border"
            />
          </div>

          <div className="flex gap-2 justify-end pt-2">
            <Button variant="outline" onClick={closeDialog} disabled={isSaving}>
              Cancelar
            </Button>
            <Button onClick={() => void handleSave()} disabled={isSaving}>
              {isSaving && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
              {editing ? "Guardar cambios" : "Crear"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      {/* ── Delete (soft) confirm ────────────────────────────────────────── */}
      <AlertDialog open={deleting !== null} onOpenChange={(open) => { if (!open) setDeleting(null) }}>
        <AlertDialogContent className="bg-card border-border">
          <AlertDialogHeader>
            <AlertDialogTitle className="text-card-foreground">Eliminar categoría</AlertDialogTitle>
            <AlertDialogDescription>
              {deleting
                ? `"${deleting.name}" deja de existir en el catálogo. Los productos que ya la tienen conservan su categoría; no se puede deshacer desde acá.`
                : ""}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="border-border text-foreground">Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => void handleDelete()}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
