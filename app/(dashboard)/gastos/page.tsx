"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { ExpenseForm } from "@/components/forms/expense-form-v2"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { useAuth } from "@/contexts/auth-context"
import { BarChart3 } from "lucide-react"
import Link from "next/link"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { Badge } from "@/components/ui/badge"
import { formatMoney, formatDate } from "@/lib/format"
import { parseAmount, parseDate } from "@/lib/excel"
import { EXPENSE_CATEGORIES } from "@/lib/constants"
import { toast } from "sonner"
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
  // Realtime subscription for expenses is handled centrally in DataProvider.
  const { expenses, deleteExpense, addExpense } = useData()
  const [open, setOpen] = useState(false)
  const { isAdmin } = useAuth()

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Gastos</h1>
          <p className="text-sm text-muted-foreground mt-1">Control de gastos operativos</p>
        </div>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="gastos"
          title="Analíticas de Gastos"
          subtitle="Control de egresos operativos"
        />
      )}

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
        mobileCard={(row) => (
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between gap-2">
              <Badge variant="outline" className={`text-xs shrink-0 ${categoryColors[row.category] || categoryColors.Otros}`}>
                {row.category}
              </Badge>
              <span className="font-semibold text-sm text-red-400">{formatMoney(row.amount)}</span>
            </div>
            <p className="font-medium text-sm text-foreground">{row.description}</p>
            <p className="text-xs text-muted-foreground">{formatDate(row.date)}</p>
          </div>
        )}
        exportColumns={[
          { key: "date", header: "Fecha" },
          { key: "category", header: "Categoría" },
          { key: "description", header: "Descripción" },
          { key: "amount", header: "Monto" },
        ]}
        exportFilename="gastos"
        importColumnMap={[
          { csvHeader: "Categoría",   key: "category"     },
          { csvHeader: "Descripción", key: "description"  },
          { csvHeader: "Monto",       key: "amount"       },
          { csvHeader: "Fecha",       key: "date"         },
        ]}
        onImport={async (rows) => {
          const validCategories = new Set<string>(EXPENSE_CATEGORIES)
          let success = 0
          const errors: string[] = []

          for (let i = 0; i < rows.length; i++) {
            const row = rows[i]

            if (!row.description?.trim()) {
              errors.push(`Fila ${i + 2}: descripción requerida`)
              continue
            }

            const amount = parseAmount(row.amount)
            if (isNaN(amount) || amount <= 0) {
              errors.push(`Fila ${i + 2}: monto inválido ("${row.amount ?? ""}")`)
              continue
            }

            const category = validCategories.has(row.category?.trim())
              ? row.category!.trim()
              : "Otros"
            const date = parseDate(row.date)

            try {
              await addExpense({ date, category, description: row.description.trim(), amount })
              success++
            } catch (err: any) {
              errors.push(`Fila ${i + 2}: ${err?.message ?? "error desconocido"}`)
            }
          }

          if (success > 0)
            toast.success(`✅ ${success} gasto${success !== 1 ? "s" : ""} importado${success !== 1 ? "s" : ""} correctamente`)
          if (errors.length > 0) {
            toast.error(`❌ ${errors.length} fila${errors.length !== 1 ? "s" : ""} con error`)
            errors.slice(0, 3).forEach((e) => toast.error(e))
          }
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
