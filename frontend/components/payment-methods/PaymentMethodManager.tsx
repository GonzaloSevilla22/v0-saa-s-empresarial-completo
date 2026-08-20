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
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Plus, Pencil, PowerOff, Loader2, Landmark } from "lucide-react"
import { toast } from "sonner"
import { isBankPaymentKind, type PaymentMethod, type PaymentMethodKind } from "@/lib/types"

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
  // pos-banco-movimientos (D7, task 9.3): cuentas para resolver el nombre
  // (columna) y poblar el selector (dialog de edición) — reusa el hook ya
  // existente desde C2, sin duplicar fetch.
  const { data: bankAccounts } = useBankAccounts()
  const bankAccountName = (id: string | null) =>
    id ? (bankAccounts ?? []).find((b) => b.id === id)?.name ?? null : null

  const [addOpen, setAddOpen] = useState(false)
  const [editingMethod, setEditingMethod] = useState<PaymentMethod | null>(null)

  const [formName, setFormName] = useState("")
  const [formKind, setFormKind] = useState<PaymentMethodKind>("other")
  // pos-banco-movimientos (D7): destino bancario editado en el dialog — sólo
  // relevante cuando formKind es bancario.
  const [formBankAccountId, setFormBankAccountId] = useState<string | null>(null)

  function openAdd() {
    setFormName("")
    setFormKind("other")
    setFormBankAccountId(null)
    setAddOpen(true)
  }

  function openEdit(pm: PaymentMethod) {
    setFormName(pm.name)
    setFormKind(pm.kind)
    setFormBankAccountId(pm.bankAccountId)
    setEditingMethod(pm)
  }

  function closeDialog() {
    setAddOpen(false)
    setEditingMethod(null)
    setFormName("")
    setFormKind("other")
    setFormBankAccountId(null)
  }

  async function handleSave() {
    const name = formName.trim()
    if (!name) {
      toast.error("El nombre es requerido")
      return
    }

    try {
      if (editingMethod) {
        // pos-banco-movimientos (D7): el destino sólo se envía cuando el
        // kind del método es bancario — el dialog no lo muestra para los
        // demás kinds, así que no hay nada que informar (tri-estado por
        // AUSENCIA de la clave, ver use-payment-methods.ts).
        await updatePaymentMethod(
          isBankPaymentKind(editingMethod.kind)
            ? { id: editingMethod.id, name, bankAccountId: formBankAccountId }
            : { id: editingMethod.id, name },
        )
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
                  {/* pos-banco-movimientos (D7): columna "Cuenta bancaria" —
                      sólo para kinds bancarios, rótulo explícito cuando no
                      tiene destino ("no registra movimiento bancario"). */}
                  {isBankPaymentKind(pm.kind) && (
                    <Badge
                      variant="outline"
                      className="text-xs shrink-0 gap-1 text-muted-foreground"
                    >
                      <Landmark className="h-3 w-3" />
                      {bankAccountName(pm.bankAccountId) ?? "Sin cuenta (no registra movimiento)"}
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

            {/* pos-banco-movimientos (D7, task 9.3): destino bancario por
                defecto — sólo editable, sólo para kinds bancarios (el kind
                es inmutable y se elige al crear; el destino se configura
                después, acá). */}
            {editingMethod && isBankPaymentKind(editingMethod.kind) && (
              <div className="flex flex-col gap-2">
                <Label htmlFor="pm-bank-account">Cuenta bancaria (opcional)</Label>
                <Select
                  value={formBankAccountId ?? "__none__"}
                  onValueChange={(v) => setFormBankAccountId(v === "__none__" ? null : v)}
                >
                  <SelectTrigger id="pm-bank-account" className="bg-background border-border">
                    <SelectValue placeholder="Sin cuenta" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__none__">Sin cuenta (no registra movimiento)</SelectItem>
                    {(bankAccounts ?? [])
                      .filter((b) => b.isActive)
                      .map((b) => (
                        <SelectItem key={b.id} value={b.id}>{b.name}</SelectItem>
                      ))}
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">
                  Las ventas y compras imputadas a esta forma de pago registrarán su movimiento en
                  esta cuenta — configurala una vez, el mostrador no vuelve a preguntar.
                </p>
              </div>
            )}
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
