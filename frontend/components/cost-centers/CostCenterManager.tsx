"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { useCostCenters } from "@/hooks/data/use-cost-centers"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Plus, Pencil, PowerOff, Loader2 } from "lucide-react"
import { toast } from "sonner"
import type { CostCenter } from "@/lib/types"

/**
 * Catalog management screen for cost centers (cost-center-dimension, V2.5).
 *
 * Visible to all members for reading, but the create/edit/deactivate actions
 * are gated to owner/admin via useOrgRole (isWriter).
 *
 * Note: management entry point is in /configuracion or similar settings area.
 * This component is a self-contained card that can be embedded anywhere.
 */
export function CostCenterManager() {
  const { isWriter } = useOrgRole()
  // Show all including inactive in the management screen (owner/admin screen)
  const {
    costCenters,
    isLoading,
    createCostCenter,
    updateCostCenter,
    deactivateCostCenter,
    createCostCenterMutation,
    updateCostCenterMutation,
    deactivateCostCenterMutation,
  } = useCostCenters(true) // includeInactive=true for management view

  const [addOpen, setAddOpen] = useState(false)
  const [editingCenter, setEditingCenter] = useState<CostCenter | null>(null)

  // Form state for create/edit dialog
  const [formName, setFormName] = useState("")
  const [formCode, setFormCode] = useState("")

  function openAdd() {
    setFormName("")
    setFormCode("")
    setAddOpen(true)
  }

  function openEdit(cc: CostCenter) {
    setFormName(cc.name)
    setFormCode(cc.code ?? "")
    setEditingCenter(cc)
  }

  function closeDialog() {
    setAddOpen(false)
    setEditingCenter(null)
    setFormName("")
    setFormCode("")
  }

  async function handleSave() {
    const name = formName.trim()
    if (!name) {
      toast.error("El nombre es requerido")
      return
    }
    const code = formCode.trim() || null

    try {
      if (editingCenter) {
        await updateCostCenter({ id: editingCenter.id, name, code })
        toast.success("Centro de costo actualizado")
      } else {
        await createCostCenter({ name, code })
        toast.success("Centro de costo creado")
      }
      closeDialog()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error: ${msg}`)
    }
  }

  async function handleDeactivate(cc: CostCenter) {
    try {
      await deactivateCostCenter(cc.id)
      toast.success(`"${cc.name}" desactivado`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error al desactivar: ${msg}`)
    }
  }

  const isSaving = createCostCenterMutation.isPending || updateCostCenterMutation.isPending

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-medium text-foreground">Centros de costo</h3>
        {isWriter && (
          <Button size="sm" variant="outline" onClick={openAdd}>
            <Plus className="h-4 w-4 mr-1" />
            Nuevo
          </Button>
        )}
      </div>

      {isLoading ? (
        <div className="flex justify-center py-4">
          <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
        </div>
      ) : costCenters.length === 0 ? (
        <p className="text-sm text-muted-foreground py-2">
          No hay centros de costo definidos.
          {isWriter && " Creá el primero para empezar a imputar gastos y compras."}
        </p>
      ) : (
        <ul className="flex flex-col gap-2">
          {costCenters.map((cc) => (
            <li
              key={cc.id}
              className="flex items-center justify-between rounded-md border border-border bg-card px-3 py-2"
            >
              <div className="flex items-center gap-2 min-w-0">
                <span className={`text-sm font-medium truncate ${cc.isActive ? "text-foreground" : "text-muted-foreground line-through"}`}>
                  {cc.name}
                </span>
                {cc.code && (
                  <Badge variant="outline" className="text-xs shrink-0">
                    {cc.code}
                  </Badge>
                )}
                {!cc.isActive && (
                  <Badge variant="secondary" className="text-xs shrink-0">
                    Inactivo
                  </Badge>
                )}
              </div>

              {isWriter && cc.isActive && (
                <div className="flex items-center gap-1 shrink-0 ml-2">
                  <Button
                    size="icon"
                    variant="ghost"
                    className="h-7 w-7"
                    onClick={() => openEdit(cc)}
                    title="Editar"
                  >
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <Button
                    size="icon"
                    variant="ghost"
                    className="h-7 w-7 text-destructive hover:text-destructive"
                    onClick={() => handleDeactivate(cc)}
                    disabled={deactivateCostCenterMutation.isPending}
                    title="Desactivar"
                  >
                    <PowerOff className="h-3.5 w-3.5" />
                  </Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      {/* ── Create / Edit dialog ─────────────────────────────────────────── */}
      <Dialog
        open={addOpen || editingCenter !== null}
        onOpenChange={(open) => { if (!open) closeDialog() }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {editingCenter ? "Editar centro de costo" : "Nuevo centro de costo"}
            </DialogTitle>
          </DialogHeader>

          <div className="flex flex-col gap-4 py-2">
            <div className="flex flex-col gap-2">
              <Label htmlFor="cc-name">Nombre *</Label>
              <Input
                id="cc-name"
                value={formName}
                onChange={(e) => setFormName(e.target.value)}
                placeholder="Ej: Logística, Marketing, Administración"
                className="bg-background border-border"
              />
            </div>

            <div className="flex flex-col gap-2">
              <Label htmlFor="cc-code">
                Código corto <span className="text-muted-foreground font-normal">(opcional)</span>
              </Label>
              <Input
                id="cc-code"
                value={formCode}
                onChange={(e) => setFormCode(e.target.value)}
                placeholder="Ej: LOG, MKT, ADM"
                className="bg-background border-border"
                maxLength={20}
              />
              <p className="text-xs text-muted-foreground">
                Código contable corto para referencia rápida.
              </p>
            </div>
          </div>

          <div className="flex gap-2 justify-end pt-2">
            <Button variant="outline" onClick={closeDialog} disabled={isSaving}>
              Cancelar
            </Button>
            <Button onClick={handleSave} disabled={isSaving}>
              {isSaving && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
              {editingCenter ? "Guardar cambios" : "Crear"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
