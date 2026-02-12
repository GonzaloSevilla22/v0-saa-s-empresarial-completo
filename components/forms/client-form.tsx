"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useData } from "@/contexts/data-context"
import { toast } from "sonner"

interface ClientFormProps {
  onSuccess: () => void
}

export function ClientForm({ onSuccess }: ClientFormProps) {
  const { addClient } = useData()
  const [name, setName] = useState("")
  const [email, setEmail] = useState("")
  const [phone, setPhone] = useState("")

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name) {
      toast.error("El nombre es obligatorio")
      return
    }
    addClient({
      name,
      email,
      phone,
      status: "activo",
      lastPurchase: new Date().toISOString().split("T")[0],
      totalSpent: 0,
    })
    toast.success("Cliente creado")
    onSuccess()
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Nombre</Label>
        <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Nombre completo" className="bg-background border-border text-foreground" />
      </div>
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Email</Label>
        <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="email@ejemplo.com" className="bg-background border-border text-foreground" />
      </div>
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Telefono</Label>
        <Input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="+54 11 5555-1234" className="bg-background border-border text-foreground" />
      </div>
      <Button type="submit" className="w-full">
        Crear cliente
      </Button>
    </form>
  )
}
