"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useData } from "@/contexts/data-context"
import { toast } from "sonner"

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import type { Client } from "@/lib/types"

interface ClientFormProps {
  onSuccess: () => void
  initialData?: Client
}

export function ClientForm({ onSuccess, initialData }: ClientFormProps) {
  const { addClient, updateClient } = useData()
  const [name, setName] = useState(initialData?.name || "")
  const [email, setEmail] = useState(initialData?.email || "")
  const [phone, setPhone] = useState(initialData?.phone || "")
  const [category, setCategory] = useState(initialData?.category || "")
  const [status, setStatus] = useState(initialData?.status || "activo")

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name) {
      toast.error("El nombre es obligatorio")
      return
    }

    const clientData = {
      name,
      email,
      phone,
      status,
      category,
      lastPurchase: initialData?.lastPurchase || new Date().toISOString().split("T")[0],
      totalSpent: initialData?.totalSpent || 0,
    }

    try {
      if (initialData) {
        await updateClient({ ...clientData, id: initialData.id })
        toast.success("Cliente actualizado")
      } else {
        await addClient(clientData)
        toast.success("Cliente creado")
      }
      onSuccess()
    } catch (error) {
      toast.error("Error al guardar cliente")
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Nombre</Label>
          <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Nombre completo" className="bg-background border-border text-foreground" />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Categoría (Opcional)</Label>
          <Input value={category} onChange={(e) => setCategory(e.target.value)} placeholder="Ej: Mayorista" className="bg-background border-border text-foreground" />
        </div>
      </div>
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Email</Label>
        <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="email@ejemplo.com" className="bg-background border-border text-foreground" />
      </div>
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Teléfono</Label>
        <Input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="+54 11 5555-1234" className="bg-background border-border text-foreground" />
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
