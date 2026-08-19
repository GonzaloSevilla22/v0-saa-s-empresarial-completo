"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Plus, Pencil, PowerOff, Loader2 } from "lucide-react"
import { toast } from "sonner"
import type { PaymentMethod, PaymentMethodKind } from "@/lib/types"

const KIND_LABELS: Record<PaymentMethodKind, string> = {
  cash: "Efectivo",
  transfer: "Transferencia",
  card: "Tarjeta",
  check: "Cheque",
  wallet: "Billetera virtual",
  credit: "Cuenta corriente",
  other: "Otro",
}

const KIND_OPTIONS: PaymentMethodKind[] = ["cash", "transfer", "card", "check", "wallet", "credit", "other"]

/**
 * Catalog management screen for payment methods (metodos-pago-operaciones).
 * Espejo de CostCenterManager.
 *
 * Visible to all members for reading, but the create/edit/deactivate actions
 * are gated to owner/admin via useOrgRole (isWriter). `kind` es inmutable
 * (D2: renombrar no cambia la semántica) — solo se elige al crear.
 *
 * Montado en /configuracion, junto a CostCenterManager (regla PO: superficie
 * frontend obligatoria en la misma pasada en que se escribe el componente).
 */
export function PaymentMethodManager() {
  const { isWriter } = useOrgRole()
  const {
    paymentMethods,
    isLoading,
    createPaymentMethod,
    updatePaymentMethod,
    deactivatePaymentMethod,
    createPaymentMethodMutation,
    updatePaymentMethodMutation,
    deactivatePaymentMethodMutation,
  } = usePaymentMethods(true) // includeInactive=true for management view

  const [addOpen, setAddOpen] = useState(false)
  const [editingMethod, setEditingMethod] = useState<PaymentMethod | null>(null)

  const [formName, setFormName] = useState("")
  const [formKind, setFormKind] = useState<PaymentMethodKind>("other")

  function openAdd() {
    setFormName("")
    setFormKind("other")
    setAddOpen(true)
  }

  function openEdit(pm: PaymentMethod) {
    setFormName(pm.name)
    setFormKind(pm.kind)
    setEditingMethod(pm)
  }

  function closeDialog() {
    setAddOpen(false)
    setEditingMethod(null)
    setFormName("")
    setFormKind("other")
  }

  async function handleSave() {
    const name = formName.trim()
    if (!name) {
      toast.error("El nombre es requerido")
      return
    }

    try {
      if (editingMethod) {
        await updatePaymentMethod({ id: editingMethod.id, name })
        toast.success("Forma de pago actualizada")
      } else {
        await createPaymentMethod({ name, kind: formKind })
        toast.success("Forma de pago creada")
      }
      closeDialog()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error: ${msg}`)
    }
  }

  async function handleDeactivate(pm: PaymentMethod) {
    try {
      await deactivatePaymentMethod(pm.id)
      toast.success(`"${pm.name}" desactivada`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error al desactivar: ${msg}`)
    }
  }

  const isSaving = createPaymentMethodMutation.isPending || updatePaymentMethodMutation.isPending

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-medium text-foreground">Formas de pago</h3>
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
      ) : paymentMethods.length === 0 ? (
        <p className="text-sm text-muted-foreground py-2">
          No hay formas de pago definidas.
          {isWriter && " Creá la primera para empezar a imputar ventas y compras."}
        </p>
      ) : (
        <ul className="flex flex-col gap-2">
          {paymentMethods
            .slice()
            .sort((a, b) => a.sortOrder - b.sortOrder)
            .map((pm) => (
              <li
                key={pm.id}
                className="flex items-center justify-between rounded-md border border-border bg-card px-3 py-2"
              >
                <div className="flex items-center gap-2 min-w-0">
                  <span className={`text-sm font-medium truncate ${pm.isActive ? "text-foreground" : "text-muted-foreground line-through"}`}>
                    {pm.name}
                  </span>
                  <Badge variant="outline" className="text-xs shrink-0">
                    {KIND_LABELS[pm.kind]}
                  </Badge>
                  {!pm.isActive && (
                    <Badge variant="secondary" className="text-xs shrink-0">
                      Inactiva
                    </Badge>
                  )}
                </div>

                {isWriter && pm.isActive && (
                  <div className="flex items-center gap-1 shrink-0 ml-2">
                    <Button
                      size="icon"
                      variant="ghost"
                      className="h-7 w-7"
                      onClick={() => openEdit(pm)}
                      title="Editar"
                    >
                      <Pencil className="h-3.5 w-3.5" />
                    </Button>
                    <Button
                      size="icon"
                      variant="ghost"
                      className="h-7 w-7 text-destructive hover:text-destructive"
                      onClick={() => handleDeactivate(pm)}
                      disabled={deactivatePaymentMethodMutation.isPending}
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
        open={addOpen || editingMethod !== null}
        onOpenChange={(open) => { if (!open) closeDialog() }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {editingMethod ? "Editar forma de pago" : "Nueva forma de pago"}
            </DialogTitle>
          </DialogHeader>

          <div className="flex flex-col gap-4 py-2">
            <div className="flex flex-col gap-2">
              <Label htmlFor="pm-name">Nombre *</Label>
              <Input
                id="pm-name"
                value={formName}
                onChange={(e) => setFormName(e.target.value)}
                placeholder="Ej: Mercado Pago, Banco Nación, Naranja X"
                className="bg-background border-border"
              />
            </div>

            <div className="flex flex-col gap-2">
              <Label htmlFor="pm-kind">Tipo</Label>
              <Select
                value={formKind}
                onValueChange={(v) => setFormKind(v as PaymentMethodKind)}
                disabled={editingMethod !== null}
              >
                <SelectTrigger id="pm-kind" className="bg-background border-border">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {KIND_OPTIONS.map((k) => (
                    <SelectItem key={k} value={k}>{KIND_LABELS[k]}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <p className="text-xs text-muted-foreground">
                {editingMethod
                  ? "El tipo no se puede cambiar una vez creada (renombrar no cambia la semántica)."
                  : "El tipo es lo que el sistema usa para razonar — el nombre es lo que vos ves y podés cambiar cuando quieras."}
              </p>
            </div>
          </div>

          <div className="flex gap-2 justify-end pt-2">
            <Button variant="outline" onClick={closeDialog} disabled={isSaving}>
              Cancelar
            </Button>
            <Button onClick={handleSave} disabled={isSaving}>
              {isSaving && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
              {editingMethod ? "Guardar cambios" : "Crear"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
