"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useClients } from "@/hooks/data/use-clients"
import { toast } from "sonner"
import { MessageCircle, CheckCircle2, AlertCircle } from "lucide-react"
import { isValidWhatsAppPhone, normalizeWhatsAppPhone, PHONE_FORMAT_HINT } from "@/lib/phone-utils"

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import type { Client } from "@/lib/types"

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
  const [status,   setStatus]   = useState(initialData?.status   || "activo")

  // Real-time phone validation state
  const hasPhone      = phone.trim().length > 0
  const phoneValid    = hasPhone && isValidWhatsAppPhone(phone)
  const phoneInvalid  = hasPhone && !phoneValid
  const normalized    = phoneValid ? normalizeWhatsAppPhone(phone) : null

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name.trim()) {
      toast.error("El nombre es obligatorio")
      return
    }

    const clientData = {
      name:     name.trim(),
      email:    email.trim()    || null,
      phone:    phone.trim()    || null,
      status,
      category: category.trim() || null,
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
          <Label className="text-foreground">Nombre</Label>
          <Input
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

      {initialData && (
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Estado</Label>
          <Select value={status} onValueChange={(v: any) => setStatus(v)}>
            <SelectTrigger className="bg-background border-border text-foreground">
              <SelectValue />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border">
              <SelectItem value="activo">Activo</SelectItem>
              <SelectItem value="inactivo">Inactivo</SelectItem>
              <SelectItem value="perdido">Perdido</SelectItem>
            </SelectContent>
          </Select>
        </div>
      )}

      <Button type="submit" className="w-full">
        {initialData ? "Actualizar cliente" : "Crear cliente"}
      </Button>
    </form>
  )
}
