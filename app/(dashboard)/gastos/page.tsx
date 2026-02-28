"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { ExpenseForm } from "@/components/forms/expense-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Badge } from "@/components/ui/badge"
import { formatMoney, formatDate } from "@/lib/format"
import type { Expense } from "@/lib/types"

const categoryColors: Record<string, string> = {
  Alquiler: "bg-blue-500/20 text-blue-400 border-blue-500/30",
  Servicios: "bg-cyan-500/20 text-cyan-400 border-cyan-500/30",
  Marketing: "bg-primary/20 text-primary border-primary/30",
  Logistica: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  Personal: "bg-purple-500/20 text-purple-400 border-purple-500/30",
  Impuestos: "bg-red-500/20 text-red-400 border-red-500/30",
  Otros: "bg-muted text-muted-foreground border-border",
}

const columns: Column<Expense>[] = [
  {
    key: "date",
    header: "Fecha",
    cell: (row) => formatDate(row.date),
    sortable: true,
    sortValue: (row) => row.date,
  },
  {
    key: "category",
    header: "Categoría",
    cell: (row) => (
      <Badge variant="outline" className={`text-xs ${categoryColors[row.category] || categoryColors.Otros}`}>
        {row.category}
      </Badge>
    ),
  },
  {
    key: "description",
    header: "Descripción",
    cell: (row) => <span className="font-medium">{row.description}</span>,
  },
  {
    key: "amount",
    header: "Monto",
    cell: (row) => <span className="font-medium text-red-400">{formatMoney(row.amount)}</span>,
    sortable: true,
    sortValue: (row) => row.amount,
  },
]

export default function GastosPage() {
  const { expenses, deleteExpense } = useData()
  const [open, setOpen] = useState(false)

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Gastos</h1>
        <p className="text-sm text-muted-foreground mt-1">Control de gastos operativos</p>
      </div>

      <DataTable
        data={expenses}
        columns={columns}
        searchPlaceholder="Buscar por descripción..."
        searchKey={(row) => `${row.description} ${row.category}`}
        onAdd={() => setOpen(true)}
        addLabel="Nuevo gasto"
        onDelete={deleteExpense}
        getId={(row) => row.id}
        dateKey={(row) => row.date}
        exportColumns={[
          { key: "date", header: "Fecha" },
          { key: "category", header: "Categoría" },
          { key: "description", header: "Descripción" },
          { key: "amount", header: "Monto" },
        ]}
        exportFilename="gastos"
        importColumnMap={[
          { csvHeader: "Categoría", key: "category" },
          { csvHeader: "Descripción", key: "description" },
          { csvHeader: "Monto", key: "amount" },
          { csvHeader: "Fecha", key: "date" },
        ]}
        onImport={(rows) => {
          console.log("Importing expenses:", rows)
        }}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nuevo gasto</DialogTitle>
          </DialogHeader>
          <ExpenseForm onSuccess={() => setOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  )
}
