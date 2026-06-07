"use client"

import { useState, useCallback } from "react"
import { ExpenseForm } from "@/components/forms/expense-form-v2"
import { useDeleteExpense } from "@/hooks/data/use-expenses-query"
import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { usePaginatedQuery } from "@/hooks/use-paginated-query"
import { useAuth } from "@/contexts/auth-context"
import { useOrgRole } from "@/hooks/useOrgRole"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { formatMoney, formatDate } from "@/lib/format"
import { exportToCSV } from "@/lib/excel"
import {
  Plus, Trash2, Pencil, Search, PackageOpen,
  Download, Upload, CalendarDays, X, Loader2,
} from "lucide-react"
import { toast } from "sonner"
import { ExportButton } from "@/components/export/ExportButton"
import type { Expense } from "@/lib/types"

const categoryColors: Record<string, string> = {
  Alquiler:  "bg-blue-500/20 text-blue-400 border-blue-500/30",
  Servicios: "bg-cyan-500/20 text-cyan-400 border-cyan-500/30",
  Marketing: "bg-primary/20 text-primary border-primary/30",
  Logistica: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  Personal:  "bg-purple-500/20 text-purple-400 border-purple-500/30",
  Impuestos: "bg-red-500/20 text-red-400 border-red-500/30",
  Otros:     "bg-muted text-muted-foreground border-border",
}

function mapRow(r: any): Expense {
  return {
    id:          r.id,
    date:        r.date?.split("T")[0] ?? r.date,
    category:    r.category || "Otros",
    description: r.description || "",
    amount:      Number(r.amount),
  }
}

export default function GastosPage() {
  const deleteExpenseMutation = useDeleteExpense()
  const { isAdmin } = useAuth()
  const { isWriter } = useOrgRole()
  const [importOpen,     setImportOpen]     = useState(false)
  const [addOpen,        setAddOpen]        = useState(false)
  const [editingExpense, setEditingExpense] = useState<Expense | null>(null)
  const [deletingId,     setDeletingId]     = useState<string | null>(null)

  // ── Paginated query — search + date filter fully server-side ─────────────
  const pq = usePaginatedQuery<any>({
    table: "expenses",
    applyFilters: (base, { search, dateFrom, dateTo }) => {
      let q = base
      if (search)   q = q.ilike("description", `%${search}%`)
      if (dateFrom) q = q.gte("date", dateFrom)
      if (dateTo)   q = q.lte("date", dateTo)
      return q
    },
    defaultSortKey:  "date",
    defaultSortDir:  "desc",
    defaultPageSize: 25,
  })

  const expenses = pq.data.map(mapRow)
  const isDateFilterActive = !!(pq.dateFrom || pq.dateTo)

  // ── Actions ───────────────────────────────────────────────────────────────
  const handleDelete = useCallback(async (id: string) => {
    setDeletingId(id)
    try {
      await deleteExpenseMutation.mutateAsync(id)
      toast.success("Gasto eliminado")
      pq.refetch()
    } catch (err: any) {
      toast.error(err?.message || "Error al eliminar")
    } finally {
      setDeletingId(null)
    }
  }, [deleteExpenseMutation, pq])

  function handleExport() {
    exportToCSV(expenses as any[], [
      { key: "date",        header: "Fecha"       },
      { key: "category",    header: "Categoría"   },
      { key: "description", header: "Descripción" },
      { key: "amount",      header: "Monto"       },
    ], "gastos")
    toast.success(`Exportados ${expenses.length} gastos`)
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Gastos</h1>
        <p className="text-sm text-muted-foreground mt-1">Control de gastos operativos</p>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper moduleType="gastos" title="Analíticas de Gastos" subtitle="Control de egresos operativos" />
      )}

      {!isWriter && <NoWriteAccessBanner />}

      {/* Controls */}
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input
              value={pq.search}
              onChange={(e) => pq.setSearch(e.target.value)}
              placeholder="Buscar descripción..."
              className="pl-9 bg-background border-border text-foreground"
            />
          </div>

          <Popover>
            <PopoverTrigger asChild>
              <Button
                variant="outline" size="sm"
                className={`shrink-0 border-border text-foreground ${isDateFilterActive ? "border-primary text-primary" : ""}`}
              >
                <CalendarDays className="h-4 w-4 mr-1" />
                Filtrar fechas
                {isDateFilterActive && (
                  <span className="ml-1.5 flex h-4 w-4 items-center justify-center rounded-full bg-primary text-[10px] text-primary-foreground">1</span>
                )}
              </Button>
            </PopoverTrigger>
            <PopoverContent className="w-72 bg-popover border-border" align="start">
              <div className="flex flex-col gap-3">
                <p className="text-sm font-medium text-foreground">Rango de fechas</p>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Desde</Label>
                  <Input type="date" value={pq.dateFrom} onChange={(e) => pq.setDateFrom(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Hasta</Label>
                  <Input type="date" value={pq.dateTo} onChange={(e) => pq.setDateTo(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                {isDateFilterActive && (
                  <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={pq.clearFilters}>
                    <X className="h-3 w-3 mr-1" />Limpiar filtro
                  </Button>
                )}
              </div>
            </PopoverContent>
          </Popover>
        </div>

        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">
            {pq.loading
              ? <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Cargando...</span>
              : `${pq.meta.totalCount} gasto${pq.meta.totalCount !== 1 ? "s" : ""}`
            }
          </span>
          <Button variant="outline" size="sm" className="border-border text-foreground"
            onClick={() => setImportOpen(true)}>
            <Upload className="h-4 w-4 mr-1" />Importar CSV
          </Button>
          <ExportButton exportType="expenses_csv" />
          {isWriter && (
            <Button onClick={() => setAddOpen(true)} size="sm">
              <Plus className="h-4 w-4 mr-1" />Nuevo gasto
            </Button>
          )}
        </div>
      </div>

      {pq.error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {pq.error}
        </div>
      )}

      {/* Table */}
      <div className="rounded-lg border border-border overflow-hidden">
        {/* Header */}
        <div className="hidden sm:grid grid-cols-[100px_140px_1fr_120px_80px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Fecha</span><span>Categoría</span><span>Descripción</span>
          <span className="text-right">Monto</span><span />
        </div>

        {/* Skeleton */}
        {pq.loading && expenses.length === 0 && (
          <div className="flex flex-col">
            {Array.from({ length: 6 }).map((_, i) => (
              <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                <div className="hidden sm:grid grid-cols-[100px_140px_1fr_120px_80px] gap-3 items-center">
                  {Array.from({ length: 4 }).map((_, j) => (
                    <div key={j} className="h-3.5 rounded bg-accent animate-pulse" />
                  ))}
                  <div />
                </div>
                <div className="sm:hidden h-16 rounded bg-accent animate-pulse" />
              </div>
            ))}
          </div>
        )}

        {!pq.loading && expenses.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {pq.search || isDateFilterActive ? "Sin resultados" : "No hay gastos registrados"}
            </p>
            {!pq.search && !isDateFilterActive && isWriter && (
              <Button variant="outline" size="sm" onClick={() => setAddOpen(true)}>
                <Plus className="h-4 w-4 mr-1" />Registrar primer gasto
              </Button>
            )}
          </div>
        )}

        {expenses.map((row) => (
          <div key={row.id} className="border-t border-border/50 first:border-t-0 hover:bg-accent/20 transition-colors">
            {/* Mobile */}
            <div className="sm:hidden flex flex-col gap-2 px-4 py-3">
              <div className="flex items-center justify-between gap-2">
                <Badge variant="outline" className={`text-xs shrink-0 ${categoryColors[row.category] || categoryColors.Otros}`}>
                  {row.category}
                </Badge>
                <span className="font-semibold text-sm text-red-400">{formatMoney(row.amount)}</span>
              </div>
              <p className="font-medium text-sm text-foreground">{row.description}</p>
              <div className="flex items-center justify-between">
                <p className="text-xs text-muted-foreground">{formatDate(row.date)}</p>
                <div className="flex items-center gap-1">
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                    onClick={() => setEditingExpense(row)}>
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-destructive"
                    disabled={deletingId === row.id} onClick={() => handleDelete(row.id)}>
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              </div>
            </div>

            {/* Desktop */}
            <div className="hidden sm:grid grid-cols-[100px_140px_1fr_120px_80px] gap-3 px-4 py-3 items-center">
              <span className="text-sm text-muted-foreground tabular-nums">{formatDate(row.date)}</span>
              <Badge variant="outline" className={`text-xs w-fit ${categoryColors[row.category] || categoryColors.Otros}`}>
                {row.category}
              </Badge>
              <span className="text-sm font-medium text-foreground truncate">{row.description}</span>
              <span className="text-right text-sm font-semibold text-red-400 tabular-nums">{formatMoney(row.amount)}</span>
              <div className="flex items-center gap-1 justify-end">
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-primary"
                  onClick={() => setEditingExpense(row)}>
                  <Pencil className="h-3.5 w-3.5" />
                </Button>
                <Button variant="ghost" size="icon" className="h-7 w-7 text-muted-foreground hover:text-destructive"
                  disabled={deletingId === row.id} onClick={() => handleDelete(row.id)}>
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </div>
            </div>
          </div>
        ))}
      </div>

      <PaginationBar
        meta={pq.meta}
        onPageChange={pq.setPage}
        onSizeChange={pq.setPageSize}
        loading={pq.loading}
        label="gastos"
      />

      {/* Add dialog */}
      <Dialog open={addOpen} onOpenChange={setAddOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nuevo gasto</DialogTitle>
          </DialogHeader>
          <ExpenseForm onSuccess={() => { setAddOpen(false); pq.refetch() }} />
        </DialogContent>
      </Dialog>

      {/* Edit dialog */}
      <Dialog open={!!editingExpense} onOpenChange={(open) => { if (!open) setEditingExpense(null) }}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Editar gasto</DialogTitle>
          </DialogHeader>
          <ExpenseForm
            key={editingExpense?.id ?? "edit-expense"}
            initialData={editingExpense ?? undefined}
            onSuccess={() => { setEditingExpense(null); pq.refetch() }}
          />
        </DialogContent>
      </Dialog>

      <ExpenseImportDialog
        open={importOpen}
        onOpenChange={setImportOpen}
        onSuccess={() => pq.refetch()}
      />
    </div>
  )
}
