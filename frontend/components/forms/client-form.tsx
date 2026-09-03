"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useClients } from "@/hooks/data/use-clients"
import { toast } from "sonner"
import { MessageCircle, CheckCircle2, AlertCircle, Landmark } from "lucide-react"
import { isValidWhatsAppPhone, normalizeWhatsAppPhone, PHONE_FORMAT_HINT } from "@/lib/phone-utils"
import { isValidTaxId, CUIT_FORMAT_HINT } from "@/lib/cuit-utils"
import { IVA_CONDITION_OPTIONS } from "@/lib/constants"

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import type { Client, IvaCondition } from "@/lib/types"

const IVA_NONE = "none"

interface ClientFormProps {
  onSuccess: () => void
  initialData?: Client
}

export function ClientForm({ onSuccess, initialData }: ClientFormProps) {
  const { addClient, updateClient } = useClients()
  const [name,     setName]     = useState(initialData?.name     || "")
  const [email,    setEmail]    = useState(initialData?.email    || "")
  const [phone,    setPhone]    = useState(initialData?.phone    || "")
  const [category, setCategory] = useState(initialData?.category || "")

  // cobranzas-vencimientos (D2/D14): plazo de pago propio, en dias. Vacio =
  // "usa el plazo de la cuenta" (null) — NUNCA cero.
  const [paymentTerms, setPaymentTerms] = useState(
    initialData?.paymentTermsDays != null ? String(initialData.paymentTermsDays) : "",
  )

  // Datos fiscales (C-22) — opcionales
  const [taxId,        setTaxId]        = useState(initialData?.taxId        || "")
  const [ivaCondition, setIvaCondition] = useState<IvaCondition | "">(initialData?.ivaCondition || "")
  const [legalName,    setLegalName]    = useState(initialData?.legalName    || "")

  // Real-time phone validation state
  const hasPhone      = phone.trim().length > 0
  const phoneValid    = hasPhone && isValidWhatsAppPhone(phone)
  const phoneInvalid  = hasPhone && !phoneValid
  const normalized    = phoneValid ? normalizeWhatsAppPhone(phone) : null

  // Real-time tax id validation state
  const hasTaxId      = taxId.trim().length > 0
  const taxIdValid    = hasTaxId && isValidTaxId(taxId)
  const taxIdInvalid  = hasTaxId && !taxIdValid

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

    const trimmedTerms = paymentTerms.trim()
    const parsedTerms = trimmedTerms === "" ? null : Number(trimmedTerms)
    if (parsedTerms !== null && (!Number.isInteger(parsedTerms) || parsedTerms < 0)) {
      toast.error("El plazo de pago debe ser un número de días (0 o más)")
      return
    }

    const clientData = {
      name:     name.trim(),
      email:    email.trim()    || null,
      phone:    phone.trim()    || null,
      category: category.trim() || null,
      taxId:        taxId.trim()     || undefined,
      ivaCondition: ivaCondition     || undefined,
      legalName:    legalName.trim() || undefined,
      // cobranzas-vencimientos (D14): el form SIEMPRE lo informa (conoce el
      // valor vigente) — vacio = null = "usa el plazo de la cuenta".
      paymentTermsDays: parsedTerms,
    }

    try {
      if (initialData) {
        await updateClient({ ...clientData, id: initialData.id } as any)
        toast.success("Cliente actualizado")
      } else {
        await addClient(clientData as any)
        toast.success("Cliente creado")
      }
      onSuccess()
    } catch (error) {
      console.error(error)
      toast.error("Error al guardar cliente")
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label htmlFor="client-name" className="text-foreground">Nombre</Label>
          <Input
            id="client-name"
            selectOnFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Nombre completo"
            className="bg-background border-border text-foreground"
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Categoría (Opcional)</Label>
          <Input
            selectOnFocus
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            placeholder="Ej: Mayorista"
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Email</Label>
        <Input
          selectOnFocus
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="email@ejemplo.com"
          className="bg-background border-border text-foreground"
        />
      </div>

      {/* ── Phone field with WhatsApp validation ──────────────────────────── */}
      <div className="flex flex-col gap-2">
        <Label className="text-foreground flex items-center gap-1.5">
          <MessageCircle className="h-3.5 w-3.5 text-[#25D366]" />
          Teléfono WhatsApp
        </Label>
        <div className="relative">
          <Input
            selectOnFocus
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            placeholder="0261 555-1234"
            className={[
              "bg-background border-border text-foreground pr-9",
              phoneValid   ? "border-[#25D366]/60 focus-visible:ring-[#25D366]/30" : "",
              phoneInvalid ? "border-amber-500/60 focus-visible:ring-amber-500/30" : "",
            ].join(" ")}
          />
          {/* Inline validation icon */}
          {phoneValid && (
            <CheckCircle2 className="absolute right-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-[#25D366] pointer-events-none" />
          )}
          {phoneInvalid && (
            <AlertCircle className="absolute right-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-amber-500 pointer-events-none" />
          )}
        </div>

        {/* Contextual feedback */}
        {phoneValid && normalized && (
          <p className="text-xs text-[#25D366] flex items-center gap-1">
            <CheckCircle2 className="h-3 w-3" />
            WhatsApp listo: <span className="font-mono ml-0.5">+{normalized}</span>
          </p>
        )}
        {phoneInvalid && (
          <p className="text-xs text-amber-500 flex items-center gap-1">
            <AlertCircle className="h-3 w-3" />
            {PHONE_FORMAT_HINT}
          </p>
        )}
        {!hasPhone && (
          <p className="text-xs text-muted-foreground">
            Necesario para enviar comprobantes por WhatsApp
          </p>
        )}
      </div>

      {/* ── Plazo de pago (cobranzas-vencimientos D2) ─────────────────────── */}
      <div className="flex flex-col gap-2">
        <Label htmlFor="client-payment-terms" className="text-foreground">
          Plazo de pago (días)
        </Label>
        <Input
          id="client-payment-terms"
          selectOnFocus
          type="number"
          min={0}
          step={1}
          value={paymentTerms}
          onChange={(e) => setPaymentTerms(e.target.value)}
          placeholder="Usa el plazo de la cuenta"
          className="bg-background border-border text-foreground"
        />
        <p className="text-xs text-muted-foreground">
          {paymentTerms.trim() === ""
            ? "Vacío: usa el plazo de la cuenta (Configuración → Cobranzas). Sin plazo en ningún lado, las ventas a crédito nacen sin vencimiento."
            : paymentTerms.trim() === "0"
            ? "0 = contado a la vista: el cargo vence el mismo día de la venta."
            : `Las ventas a crédito de este cliente vencen a los ${paymentTerms.trim()} días.`}
        </p>
      </div>

      {/* ── Datos fiscales (C-22) ─────────────────────────────────────────── */}
      <div className="flex flex-col gap-3 rounded-lg border border-border p-3">
        <p className="text-sm font-medium text-foreground flex items-center gap-1.5">
          <Landmark className="h-3.5 w-3.5 text-muted-foreground" />
          Datos fiscales
          <span className="text-xs font-normal text-muted-foreground">(Opcional)</span>
        </p>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="flex flex-col gap-2">
            <Label htmlFor="client-tax-id" className="text-foreground">CUIT / DNI</Label>
            <div className="relative">
              <Input
                id="client-tax-id"
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
          <Label htmlFor="client-legal-name" className="text-foreground">Razón social</Label>
          <Input
            id="client-legal-name"
            selectOnFocus
            value={legalName}
            onChange={(e) => setLegalName(e.target.value)}
            placeholder="Ej: ACME S.R.L."
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      <Button type="submit" className="w-full">
        {initialData ? "Actualizar cliente" : "Crear cliente"}
      </Button>
    </form>
  )
}
