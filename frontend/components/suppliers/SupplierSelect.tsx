"use client"

/**
 * remitos-compra (D11, tarea 4.3) — selector de proveedor con alta inline, EXTRAÍDO
 * de `components/forms/purchase-form.tsx` sin cambiar lo que muestra: combobox
 * buscable (`SearchableSelect`) + "Nuevo proveedor" en el lugar, que queda
 * seleccionado. Lo consumen el formulario de compra y el del remito de compra.
 *
 * El componente es TONTO respecto de qué significa "seleccionado": `onChange` se
 * dispara al elegir, al limpiar (`null`) y al crear un proveedor inline (su id), y
 * cada caller decide qué hace con eso (`purchase-form` lo cuenta como "tocar" el
 * selector para el payload de edición). El aviso de proveedor no resoluble
 * (dado de baja) depende del contexto del caller, así que llega por
 * `unresolvedHint`.
 *
 * `askPhone` (default `false`, lo que `purchase-form` muestra hoy): suma un
 * teléfono OPCIONAL al alta inline. El remito de compra lo activa porque el
 * WhatsApp al proveedor depende de ese número.
 */
import { useId, useMemo, useState } from "react"
import { Plus, UserPlus } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { useSuppliers } from "@/hooks/data/use-suppliers"
import { getErrorMessage } from "@/lib/errors"

export interface SupplierSelectProps {
  /** Proveedor elegido; `null` si no hay. */
  value: string | null
  /** Elegir (id), limpiar (`null`) o crear inline (id del recién creado). */
  onChange: (supplierId: string | null) => void
  /** Suma un teléfono opcional al alta inline. Default `false`. */
  askPhone?: boolean
  /** `id` del rótulo, para `aria-labelledby` (default: uno propio por instancia). */
  labelId?: string
  /** Aviso bajo el selector (p. ej. "Proveedor actual no disponible (dado de baja)"); `null` no muestra nada. */
  unresolvedHint?: string | null
}

export function SupplierSelect({ value, onChange, askPhone = false, labelId, unresolvedHint = null }: SupplierSelectProps) {
  const generatedId = useId()
  const resolvedLabelId = labelId ?? `supplier-select-label-${generatedId}`
  const { suppliers, addSupplier } = useSuppliers()
  const [showNewSupplier, setShowNewSupplier] = useState(false)
  const [newSupplierName, setNewSupplierName] = useState("")
  const [newSupplierPhone, setNewSupplierPhone] = useState("")

  const supplierOptions = useMemo(() => suppliers.map((s) => ({ value: s.id, label: s.name })), [suppliers])

  // Crea el proveedor y lo preselecciona sin perder nada de lo que el caller ya cargó.
  async function handleCreateSupplier() {
    if (!newSupplierName.trim()) {
      toast.error("El nombre del proveedor es obligatorio")
      return
    }
    try {
      const created = await addSupplier({
        name: newSupplierName.trim(),
        email: "",
        phone: askPhone ? newSupplierPhone.trim() : "",
      })
      onChange(created.id)
      toast.success(`Proveedor "${newSupplierName}" creado`)
      setShowNewSupplier(false)
      setNewSupplierName("")
      setNewSupplierPhone("")
    } catch (err: unknown) {
      toast.error(getErrorMessage(err, "Error al crear el proveedor"))
    }
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between">
        {/* id explícito + aria-labelledby en el selector, en vez de aria-label a
            secas: el nombre accesible combina "Proveedor" con el valor visible
            (placeholder o proveedor elegido) en lugar de reemplazarlo. */}
        <Label id={resolvedLabelId} className="text-foreground">
          Proveedor
        </Label>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          className="h-6 text-xs text-primary"
          onClick={() => setShowNewSupplier(!showNewSupplier)}
        >
          <UserPlus className="h-3 w-3 mr-1" />
          {showNewSupplier ? "Cancelar" : "Nuevo proveedor"}
        </Button>
      </div>

      {showNewSupplier ? (
        <div className="rounded-lg border border-border bg-accent/30 p-3 flex flex-col gap-2">
          <Input
            selectOnFocus
            value={newSupplierName}
            onChange={(e) => setNewSupplierName(e.target.value)}
            placeholder="Nombre del proveedor"
            className="bg-background border-border text-foreground text-sm"
          />
          {askPhone && (
            <Input
              selectOnFocus
              type="tel"
              inputMode="tel"
              value={newSupplierPhone}
              onChange={(e) => setNewSupplierPhone(e.target.value)}
              placeholder="Teléfono (opcional)"
              aria-label="Teléfono del proveedor"
              className="bg-background border-border text-foreground text-sm"
            />
          )}
          <Button type="button" size="sm" variant="secondary" onClick={handleCreateSupplier} className="w-full">
            <Plus className="h-3 w-3 mr-1" />
            Crear y seleccionar
          </Button>
        </div>
      ) : (
        <>
          <SearchableSelect
            options={supplierOptions}
            value={value ?? ""}
            onValueChange={(v) => onChange(v || null)}
            placeholder="Seleccionar proveedor"
            searchPlaceholder="Buscar proveedor..."
            emptyMessage="No se encontraron proveedores."
            aria-labelledby={resolvedLabelId}
          />
          {/* El selector cae al placeholder en silencio cuando el valor no resuelve
              en la lista (proveedor dado de baja): el aviso explica por qué, en
              vez de dejarlo parecer "sin elegir". */}
          {unresolvedHint && <p className="text-xs text-muted-foreground">{unresolvedHint}</p>}
        </>
      )}
    </div>
  )
}
