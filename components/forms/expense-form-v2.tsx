"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { EXPENSE_CATEGORIES } from "@/lib/constants"
import { CalendarIcon } from "lucide-react"
import { toast } from "sonner"

interface ExpenseFormProps {
  onSuccess: () => void
}

export function ExpenseForm({ onSuccess }: ExpenseFormProps) {
  const { addExpense } = useData()
  const [category, setCategory] = useState("")
  const [description, setDescription] = useState("")
  const [amount, setAmount] = useState(0)
  const [date, setDate] = useState(() => new Date().toISOString().split("T")[0])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!category || !description) {
      toast.error("Completá todos los campos")
      return
    }
    try {
      await addExpense({
        date,
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
          selectOnFocus
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Detalle del gasto"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="grid grid-cols-2 gap-3">
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

        <div className="flex flex-col gap-2">
          <Label className="text-foreground flex items-center gap-1.5">
            <CalendarIcon className="h-3.5 w-3.5 text-muted-foreground" />
            Fecha
          </Label>
          <input
            type="date"
            value={date}
            max={new Date().toISOString().split("T")[0]}
            onChange={(e) => setDate(e.target.value)}
            className="flex h-10 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          />
        </div>
      </div>

      <Button type="submit" className="w-full">
        Registrar gasto
      </Button>
    </form>
  )
}
