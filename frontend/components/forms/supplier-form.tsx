"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useSuppliers } from "@/hooks/data/use-suppliers"
import { toast } from "sonner"
import { CheckCircle2, AlertCircle, Landmark } from "lucide-react"
import { isValidTaxId, CUIT_FORMAT_HINT } from "@/lib/cuit-utils"
import { IVA_CONDITION_OPTIONS } from "@/lib/constants"

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import type { Supplier, IvaCondition } from "@/lib/types"

// compras-proveedor-cuenta-corriente (D2/D10): molde exacto de client-form.tsx
// — reutiliza cuit-utils.ts para la validación de CUIT/DNI (RN-96: mismo VO
// FiscalIdentity compartido entre Customer y Supplier, sin reimplementarla) y
// IVA_CONDITION_OPTIONS (extraído de client-form.tsx a lib/constants.ts para
// que ambos formularios lo compartan). Sin la validación de teléfono WhatsApp
// del cliente — un proveedor no recibe comprobantes por WhatsApp.

const IVA_NONE = "none"

interface SupplierFormProps {
  onSuccess: () => void
  initialData?: Supplier
}

export function SupplierForm({ onSuccess, initialData }: SupplierFormProps) {
  const { addSupplier, updateSupplier } = useSuppliers()
  const [name,  setName]  = useState(initialData?.name  || "")
  const [email, setEmail] = useState(initialData?.email || "")
  const [phone, setPhone] = useState(initialData?.phone || "")

  // Datos fiscales (D2/OQ-3 opción A) — opcionales
  const [taxId,        setTaxId]        = useState(initialData?.taxId        || "")
  const [ivaCondition, setIvaCondition] = useState<IvaCondition | "">(initialData?.ivaCondition || "")
  const [legalName,    setLegalName]    = useState(initialData?.legalName    || "")

  // Real-time tax id validation state (espejo de client-form.tsx)
  const hasTaxId     = taxId.trim().length > 0
  const taxIdValid   = hasTaxId && isValidTaxId(taxId)
  const taxIdInvalid = hasTaxId && !taxIdValid

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name.trim()) {
      toast.error("El nombre es obligatorio")
      return
    }
    if (taxIdInvalid) {
      toast.error("El CUIT/DNI no es válido. " + CUIT_FORMAT_HINT)
      return
    }

    const supplierData = {
      name:  name.trim(),
      email: email.trim() || "",
      phone: phone.trim() || "",
      taxId:        taxId.trim()     || undefined,
      ivaCondition: ivaCondition     || undefined,
      legalName:    legalName.trim() || undefined,
    }

    try {
      if (initialData) {
        await updateSupplier({ ...supplierData, id: initialData.id })
        toast.success("Proveedor actualizado")
      } else {
        await addSupplier(supplierData)
        toast.success("Proveedor creado")
      }
      onSuccess()
    } catch (error) {
      console.error(error)
      toast.error("Error al guardar proveedor")
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label htmlFor="supplier-name" className="text-foreground">Nombre</Label>
        <Input
          id="supplier-name"
          selectOnFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Nombre del proveedor"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label htmlFor="supplier-email" className="text-foreground">Email</Label>
          <Input
            id="supplier-email"
            selectOnFocus
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="email@ejemplo.com"
            className="bg-background border-border text-foreground"
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="supplier-phone" className="text-foreground">Teléfono</Label>
          <Input
            id="supplier-phone"
            selectOnFocus
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            placeholder="0261 555-1234"
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      {/* ── Datos fiscales (D2/OQ-3 opción A — espejo de clients) ─────────── */}
      <div className="flex flex-col gap-3 rounded-lg border border-border p-3">
        <p className="text-sm font-medium text-foreground flex items-center gap-1.5">
          <Landmark className="h-3.5 w-3.5 text-muted-foreground" />
          Datos fiscales
          <span className="text-xs font-normal text-muted-foreground">(Opcional)</span>
        </p>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="flex flex-col gap-2">
            <Label htmlFor="supplier-tax-id" className="text-foreground">CUIT / DNI</Label>
            <div className="relative">
              <Input
                id="supplier-tax-id"
                selectOnFocus
                value={taxId}
                onChange={(e) => setTaxId(e.target.value)}
                placeholder="20-12345678-6 o DNI"
                className={[
                  "bg-background border-border text-foreground pr-9",
                  taxIdValid   ? "border-emerald-500/60 focus-visible:ring-emerald-500/30" : "",
                  taxIdInvalid ? "border-amber-500/60 focus-visible:ring-amber-500/30" : "",
                ].join(" ")}
              />
              {taxIdValid && (
                <CheckCircle2 className="absolute right-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-emerald-500 pointer-events-none" />
              )}
              {taxIdInvalid && (
                <AlertCircle className="absolute right-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-amber-500 pointer-events-none" />
              )}
            </div>
            {taxIdInvalid && (
              <p className="text-xs text-amber-500 flex items-center gap-1">
                <AlertCircle className="h-3 w-3" />
                {CUIT_FORMAT_HINT}
              </p>
            )}
          </div>

          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Condición IVA</Label>
            <Select
              value={ivaCondition || IVA_NONE}
              onValueChange={(v) => setIvaCondition(v === IVA_NONE ? "" : (v as IvaCondition))}
            >
              <SelectTrigger className="bg-background border-border text-foreground">
                <SelectValue placeholder="Sin especificar" />
              </SelectTrigger>
              <SelectContent className="bg-popover border-border">
                <SelectItem value={IVA_NONE}>Sin especificar</SelectItem>
                {IVA_CONDITION_OPTIONS.map((opt) => (
                  <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        <div className="flex flex-col gap-2">
          <Label htmlFor="supplier-legal-name" className="text-foreground">Razón social</Label>
          <Input
            id="supplier-legal-name"
            selectOnFocus
            value={legalName}
            onChange={(e) => setLegalName(e.target.value)}
            placeholder="Ej: ACME S.R.L."
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      <Button type="submit" className="w-full">
        {initialData ? "Actualizar proveedor" : "Crear proveedor"}
      </Button>
    </form>
  )
}
