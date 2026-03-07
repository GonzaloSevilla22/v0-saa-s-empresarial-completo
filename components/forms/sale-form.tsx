"use client"

import { useState, useMemo, useEffect } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { formatMoney, CURRENCIES, type Currency } from "@/lib/format"
import { Plus, UserPlus } from "lucide-react"
import { toast } from "sonner"

interface SaleFormProps {
  onSuccess: () => void
}

export function SaleForm({ onSuccess }: SaleFormProps) {
  const { products, clients, addSale, addClient } = useData()
  const [productId, setProductId] = useState("")
  const [clientId, setClientId] = useState("")
  const [quantity, setQuantity] = useState(1)
  const [currency, setCurrency] = useState<Currency>("ARS")
  const [discount, setDiscount] = useState(0) // Percentage
  const [manualTotal, setManualTotal] = useState<number | null>(null)

  // Inline new client
  const [showNewClient, setShowNewClient] = useState(false)
  const [newClientName, setNewClientName] = useState("")
  const [newClientEmail, setNewClientEmail] = useState("")
  const [newClientPhone, setNewClientPhone] = useState("")

  const selectedProduct = useMemo(() => products.find((p) => p.id === productId), [products, productId])
  const selectedClient = useMemo(() => clients.find((c) => c.id === clientId), [clients, clientId])

  // Reset manual values when product changes
  useEffect(() => {
    setManualTotal(null)
    setDiscount(0)
  }, [productId])

  const calculatedTotal = useMemo(() => {
    if (!selectedProduct) return 0
    const base = selectedProduct.price * quantity
    return base * (1 - discount / 100)
  }, [selectedProduct, quantity, discount])

  const currentTotal = manualTotal ?? calculatedTotal

  function handleCreateClient() {
    if (!newClientName.trim()) {
      toast.error("El nombre del cliente es obligatorio")
      return
    }
    addClient({
      name: newClientName,
      email: newClientEmail,
      phone: newClientPhone,
      status: "activo",
    })
    toast.success(`Cliente "${newClientName}" creado`)
    setShowNewClient(false)
    setNewClientName("")
    setNewClientEmail("")
    setNewClientPhone("")
    // Select the new client (it will be the first in the list after adding)
    setTimeout(() => {
      const newClient = clients.find((c) => c.name === newClientName)
      if (newClient) setClientId(newClient.id)
    }, 100)
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!selectedProduct || !selectedClient) {
      toast.error("Seleccioná producto y cliente")
      return
    }
    addSale({
      date: new Date().toISOString().split("T")[0],
      productId: selectedProduct.id,
      productName: selectedProduct.name,
      clientId: selectedClient.id,
      clientName: selectedClient.name,
      quantity,
      unitPrice: currentTotal / quantity,
      total: currentTotal,
      currency,
    })
    toast.success("Venta registrada")
    onSuccess()
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Producto</Label>
        <Select value={productId} onValueChange={setProductId}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar producto" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {products.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.name} - {formatMoney(p.price)} (Stock: {p.stock})
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <Label className="text-foreground">Cliente</Label>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-6 text-xs text-primary"
            onClick={() => setShowNewClient(!showNewClient)}
          >
            <UserPlus className="h-3 w-3 mr-1" />
            {showNewClient ? "Cancelar" : "Nuevo cliente"}
          </Button>
        </div>

        {showNewClient ? (
          <div className="rounded-lg border border-border bg-accent/30 p-3 flex flex-col gap-2">
            <Input
              value={newClientName}
              onChange={(e) => setNewClientName(e.target.value)}
              placeholder="Nombre del cliente"
              className="bg-background border-border text-foreground text-sm"
            />
            <div className="grid grid-cols-2 gap-2">
              <Input
                value={newClientEmail}
                onChange={(e) => setNewClientEmail(e.target.value)}
                placeholder="Email (opcional)"
                className="bg-background border-border text-foreground text-sm"
              />
              <Input
                value={newClientPhone}
                onChange={(e) => setNewClientPhone(e.target.value)}
                placeholder="Teléfono (opcional)"
                className="bg-background border-border text-foreground text-sm"
              />
            </div>
            <Button type="button" size="sm" variant="secondary" onClick={handleCreateClient} className="w-full">
              <Plus className="h-3 w-3 mr-1" />
              Crear y seleccionar
            </Button>
          </div>
        ) : (
          <Select value={clientId} onValueChange={setClientId}>
            <SelectTrigger className="bg-background border-border text-foreground">
              <SelectValue placeholder="Seleccionar cliente" />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border">
              {clients.map((c) => (
                <SelectItem key={c.id} value={c.id}>
                  {c.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        )}
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Cantidad</Label>
          <NumericInput
            min={1}
            max={selectedProduct?.stock || 999}
            value={quantity}
            onValueChange={(val) => {
              setQuantity(Math.max(1, val))
              setManualTotal(null)
            }}
            className="bg-background border-border text-foreground"
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Descuento (%)</Label>
          <NumericInput
            min={0}
            max={100}
            value={discount}
            onValueChange={(val) => {
              setDiscount(val)
              setManualTotal(null)
            }}
            placeholder="0"
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Moneda</Label>
          <Select value={currency} onValueChange={(v) => setCurrency(v as Currency)}>
            <SelectTrigger className="bg-background border-border text-foreground">
              <SelectValue />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border">
              {CURRENCIES.map((c) => (
                <SelectItem key={c.value} value={c.value}>
                  {c.symbol} ({c.value})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Total Final</Label>
          <NumericInput
            min={0}
            value={Math.round(currentTotal)}
            onValueChange={(val) => setManualTotal(val)}
            className="bg-background border-emerald-500/30 text-emerald-400 font-bold"
          />
        </div>
      </div>

      <div className="rounded-lg border border-border bg-accent/50 p-3">
        <div className="flex items-center justify-between text-sm">
          <span className="text-muted-foreground">Total a registrar</span>
          <span className="text-lg font-bold text-primary">{formatMoney(currentTotal, currency)}</span>
        </div>
      </div>

      <Button type="submit" className="w-full">
        Registrar venta
      </Button>
    </form>
  )
}
