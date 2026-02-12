"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { EXPENSE_CATEGORIES } from "@/lib/constants"
import { toast } from "sonner"

interface ExpenseFormProps {
  onSuccess: () => void
}

export function ExpenseForm({ onSuccess }: ExpenseFormProps) {
  const { addExpense } = useData()
  const [category, setCategory] = useState("")
  const [description, setDescription] = useState("")
  const [amount, setAmount] = useState(0)

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!category || !description) {
      toast.error("Completa todos los campos")
      return
    }
    addExpense({
      date: new Date().toISOString().split("T")[0],
      category,
      description,
      amount,
    })
    toast.success("Gasto registrado")
    onSuccess()
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Categoria</Label>
        <Select value={category} onValueChange={setCategory}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar categoria" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {EXPENSE_CATEGORIES.map((c) => (
              <SelectItem key={c} value={c}>{c}</SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Descripcion</Label>
        <Input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Detalle del gasto"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Monto</Label>
        <Input
          type="number"
          min={0}
          step={0.01}
          value={amount}
          onChange={(e) => setAmount(parseFloat(e.target.value) || 0)}
          className="bg-background border-border text-foreground"
        />
      </div>

      <Button type="submit" className="w-full">
        Registrar gasto
      </Button>
    </form>
  )
}
