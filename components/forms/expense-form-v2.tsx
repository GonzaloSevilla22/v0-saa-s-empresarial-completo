"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
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

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!category || !description) {
      toast.error("Completá todos los campos")
      return
    }
    try {
      await addExpense({
        date: new Date().toISOString().split("T")[0],
        category,
        description,
        amount,
      })
      toast.success("Gasto registrado")
      onSuccess()
    } catch (error: any) {
      console.error("Expense creation error:", error)
      const errorMsg = error.message || (typeof error === 'string' ? error : "Error desconocido")
      toast.error(`Error al registrar gasto: ${errorMsg}`)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Categoría</Label>
        <Select value={category} onValueChange={setCategory}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar categoría" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {EXPENSE_CATEGORIES.map((c) => (
              <SelectItem key={c} value={c}>{c}</SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Descripción</Label>
        <Input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Detalle del gasto"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Monto</Label>
        <NumericInput
          min={0}
          step={0.01}
          value={amount}
          onValueChange={setAmount}
          className="bg-background border-border text-foreground"
        />
      </div>

      <Button type="submit" className="w-full">
        Registrar gasto
      </Button>
    </form>
  )
}
