"use client"

import { useState, useCallback, useMemo } from "react"
import { ExpenseForm } from "@/components/forms/expense-form-v2"
import { CostCenterSelect } from "@/components/cost-centers/CostCenterSelect"
import { PaymentMethodSelect } from "@/components/payment-methods/PaymentMethodSelect"
import { PaymentMethodBadge } from "@/components/payment-methods/PaymentMethodBadge"
import { useCostCenters } from "@/hooks/data/use-cost-centers"
import { useExpenses } from "@/hooks/data/use-expenses-query"
import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"
import { DeleteOperationDialog } from "@/components/shared/delete-operation-dialog"
import { getDeleteCompensation } from "@/lib/delete-compensation"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { useAuth } from "@/contexts/auth-context"
import { useOrgRole } from "@/hooks/useOrgRole"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { formatMoney, formatDate } from "@/lib/format"
import { exportToCSV } from "@/lib/excel"
import {
  Plus, Pencil, Search, PackageOpen, Lock,
  Download, Upload, CalendarDays, X, Loader2,
} from "lucide-react"
import { toast } from "sonner"
import { ExportButton } from "@/components/export/ExportButton"
import type { Expense } from "@/lib/types"

/**
 * ⚠️ Deuda ajena declarada (D17): estos son literales de Tailwind, el patrón
 * que `tokens-contraste-aa` (#406-#408) desterró. `gastos-forma-pago` NO los
 * refactoriza — tocarlos ampliaría la superficie sin relación con el pedido —
 * pero tampoco los copia: el badge de forma de pago que agrega este change usa
 * tonos semánticos (`PaymentMethodBadge`). Queda anotado como candidato.
 */
const categoryColors: Record<string, string> = {
  Alquiler:  "bg-blue-500/20 text-blue-400 border-blue-500/30",
  Servicios: "bg-cyan-500/20 text-cyan-400 border-cyan-500/30",
  Marketing: "bg-primary/20 text-primary border-primary/30",
  Logistica: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  Personal:  "bg-purple-500/20 text-purple-400 border-purple-500/30",
  Impuestos: "bg-red-500/20 text-red-400 border-red-500/30",
  Otros:     "bg-muted text-muted-foreground border-border",
}

/** Razón visible del lock de edición (D11) — anticipa el `P0423` del servidor. */
function editBlockedReason(row: Expense): string | null {
  if (!row.isPaymentLocked) return null
  if (row.hasCashMovement && row.hasBankMovement) {
    return "No se puede editar: el gasto ya movió plata en la caja y en el banco. Para corregirlo, borralo y cargalo de nuevo."
  }
  if (row.hasCashMovement) {
    return "No se puede editar: el gasto ya descontó de la caja. Para corregirlo, borralo y cargalo de nuevo."
  }
  if (row.hasBankMovement) {
    return "No se puede editar: el gasto ya registró un movimiento bancario. Para corregirlo, borralo y cargalo de nuevo."
  }
  return "No se puede editar: el gasto ya movió plata."
}

export default function GastosPage() {
  const { isAdmin } = useAuth()
  const { isWriter } = useOrgRole()
  const [importOpen,     setImportOpen]     = useState(false)
  const [addOpen,        setAddOpen]        = useState(false)
  const [editingExpense, setEditingExpense] = useState<Expense | null>(null)
  const [deletingId,     setDeletingId]     = useState<string | null>(null)

  // ── D18: origen de datos = GET /expenses paginado del backend ─────────────
  // Antes: usePaginatedQuery({ table: "expenses" }) por PostgREST directo, con
  // su `mapRow` local. Por ese camino no hay forma de que llegue el lock
  // (`is_payment_locked` es un derivado de cash_movements/bank_movements, NO
  // una columna de `expenses`) ni el nombre de la forma de pago. Es la misma
  // plomería que /ventas ya usa con useSales(), no lógica nueva.
  const {
    expenses, meta, isLoading, error,
    search, setSearch,
    dateFrom, setDateFrom,
    dateTo, setDateTo,
    costCenterId, setCostCenterId,
    paymentMethodId, setPaymentMethodId,
    setPage, setPageSize, refetch,
    deleteExpense,
  } = useExpenses()

  // Nombres del catálogo para el badge de cada fila; incluye inactivos porque
  // los gastos históricos pueden apuntar a un centro dado de baja.
  const { costCenters } = useCostCenters(true)
  const costCenterNameById = useMemo(
    () => new Map(costCenters.map((cc) => [cc.id, cc.code ? `${cc.code} — ${cc.name}` : cc.name])),
    [costCenters],
  )

  const isDateFilterActive = !!(dateFrom || dateTo)
  const isAnyFilterActive  = isDateFilterActive || !!costCenterId || !!paymentMethodId || !!search

  // ── Actions ───────────────────────────────────────────────────────────────
  const handleDelete = useCallback(async (id: string) => {
    setDeletingId(id)
    try {
      await deleteExpense(id)
      toast.success("Gasto eliminado")
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al eliminar")
    } finally {
      setDeletingId(null)
    }
  }, [deleteExpense])

  function handleExport() {
    exportToCSV(expenses.map((e) => ({
      date: e.date,
      category: e.category,
      description: e.description,
      // gastos-forma-pago (11.5): misma columna que el export por Edge
      // Function — tocar uno solo los deja divergentes.
      paymentMethodName: e.paymentMethodName ?? "Sin especificar",
      amount: e.amount,
    })), [
      { key: "date",              header: "Fecha"         },
      { key: "category",          header: "Categoría"     },
      { key: "description",       header: "Descripción"   },
      { key: "paymentMethodName", header: "Forma de pago" },
      { key: "amount",            header: "Monto"         },
    ], "gastos")
    toast.success(`Exportados ${expenses.length} gastos`)
  }

  return (
    <div className="flex flex-col gap-6">
      {/* Las tres acciones de datos masivos (importar y los dos caminos de
          exportación) viven en la fila del título; abajo queda sólo el CTA.
          Medido a 1440px con el sidebar desplegado: el contenedor de controles
          reparte 1136px, de los que el grupo de filtros toma 875px rígidos
          (buscador w-64 + fechas + centro w-56 + formas w-56), y le deja 249px
          a una barra que necesitaba 456px. Ese déficit de 207px era lo que la
          quebraba en cuatro renglones escalonados, con el CTA primario último y
          aislado; mover un solo botón bajaba a tres y no alcanzaba. Con las tres
          acciones arriba, abajo quedan ~190px de contador + "Nuevo gasto" y la
          barra entra en una fila. El ExportButton arriba, además, es el mismo
          lugar que le da /ventas (ventas/page.tsx L60-66). */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Gastos</h1>
          <p className="text-sm text-muted-foreground mt-1">Control de gastos operativos</p>
        </div>
        <div className="flex flex-wrap items-center justify-end gap-2">
          <Button variant="outline" size="sm" className="border-border text-foreground"
            onClick={() => setImportOpen(true)}>
            <Upload className="h-4 w-4 mr-1" />Importar CSV
          </Button>
          {/* gastos-forma-pago (11.5): este botón NO existía — `handleExport`
              estaba escrito y sin montar en ninguna parte, mientras /clientes,
              /proveedores y /ventas sí lo exponen con este mismo markup. Se
              monta acá para que la columna nueva tenga por dónde salir. */}
          <Button variant="outline" size="sm" className="border-border text-foreground" onClick={handleExport}>
            <Download className="h-4 w-4 mr-1" />Exportar
          </Button>
          <ExportButton exportType="expenses_csv" />
        </div>
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
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              // El filtro server-side de D18 busca en categoría Y descripción
              // (`e.category ILIKE $4 OR e.description ILIKE $4`, documentado en el
              // Query del router): el copy tiene que decir lo mismo que el SQL.
              placeholder="Buscar descripción o categoría..."
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
                  <Label htmlFor="expense-date-from" className="text-xs text-muted-foreground">Desde</Label>
                  <Input id="expense-date-from" type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                <div className="flex flex-col gap-2">
                  <Label htmlFor="expense-date-to" className="text-xs text-muted-foreground">Hasta</Label>
                  <Input id="expense-date-to" type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                {isDateFilterActive && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="text-muted-foreground"
                    // G11 (H13): limpia SOLO el rango de fechas — antes llamaba
                    // al clearFilters() GLOBAL y borraba buscador, forma de
                    // pago y centro de costo en el mismo clic.
                    onClick={() => { setDateFrom(""); setDateTo("") }}
                  >
                    <X className="h-3 w-3 mr-1" />Limpiar filtro
                  </Button>
                )}
              </div>
            </PopoverContent>
          </Popover>

          {/* cost-center-surface: filtro por centro de costo */}
          <div className="w-full sm:w-56">
            <CostCenterSelect
              value={costCenterId}
              onChange={setCostCenterId}
              placeholder="Todos los centros"
              showLabel={false}
              includeInactive
              className={`bg-background border-border text-foreground ${costCenterId ? "border-primary text-primary" : ""}`}
            />
          </div>

          {/* gastos-forma-pago (11.2): filtro por forma de pago, server-side.
              `includeInactive` sostiene el escenario "desactivar una forma de
              pago usada por gastos": la forma dada de baja deja de ofrecerse
              para gastos NUEVOS, pero sigue siendo filtrable y nombrable. */}
          <div className="w-full sm:w-56">
            <PaymentMethodSelect
              value={paymentMethodId}
              onChange={setPaymentMethodId}
              placeholder="Todas las formas"
              showLabel={false}
              showSupportText={false}
              includeInactive
              context="expense"
              className={`bg-background border-border text-foreground ${paymentMethodId ? "border-primary text-primary" : ""}`}
            />
          </div>
        </div>

        {/* Sólo el contador y el CTA: ~190px, que entran en los 249px que deja
            el grupo de filtros a 1440px. `shrink-0` evita que el CTA se comprima
            si algún filtro crece. */}
        <div className="flex shrink-0 items-center gap-2">
          <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">
            {isLoading
              ? <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Cargando...</span>
              : `${meta.totalCount} gasto${meta.totalCount !== 1 ? "s" : ""}`
            }
          </span>
          {isWriter && (
            <Button onClick={() => setAddOpen(true)} size="sm" className="shrink-0">
              <Plus className="h-4 w-4 mr-1" />Nuevo gasto
            </Button>
          )}
        </div>
      </div>

      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error instanceof Error ? error.message : "Error al cargar los gastos"}
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
        {isLoading && expenses.length === 0 && (
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

        {!isLoading && expenses.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {isAnyFilterActive ? "Sin resultados" : "No hay gastos registrados"}
            </p>
            {!isAnyFilterActive && isWriter && (
              <Button variant="outline" size="sm" onClick={() => setAddOpen(true)}>
                <Plus className="h-4 w-4 mr-1" />Registrar primer gasto
              </Button>
            )}
          </div>
        )}

        {expenses.map((row) => {
          // D11/D8: los dos bloqueos vienen de los MISMOS predicados que evalúa
          // el servidor (derivados en el backend), no de una regla de cliente.
          const lockReason = editBlockedReason(row)
          const deleteInfo = getDeleteCompensation(
            {
              hasCashMovement: row.hasCashMovement,
              hasBankMovement: row.hasBankMovement,
              isDeleteBlocked: row.isDeleteBlocked,
            },
            "cliente",
            "gasto",
          )
          return (
          <div key={row.id} className="border-t border-border/50 first:border-t-0 hover:bg-accent/20 transition-colors">
            {/* Mobile */}
            <div className="sm:hidden flex flex-col gap-2 px-4 py-3">
              <div className="flex items-center justify-between gap-2">
                <Badge variant="outline" className={`text-xs shrink-0 ${categoryColors[row.category] || categoryColors.Otros}`}>
                  {row.category}
                </Badge>
                <span className="font-semibold text-sm text-destructive">{formatMoney(row.amount)}</span>
              </div>
              <p className="font-medium text-sm text-foreground">{row.description}</p>
              <div className="flex items-center gap-1.5 flex-wrap">
                {row.costCenterId && costCenterNameById.get(row.costCenterId) && (
                  <Badge variant="outline" className="text-[10px] w-fit text-muted-foreground">
                    {costCenterNameById.get(row.costCenterId)}
                  </Badge>
                )}
                <PaymentMethodBadge name={row.paymentMethodName} kind={row.paymentMethodKind} />
              </div>
              <div className="flex items-center justify-between">
                <p className="text-xs text-muted-foreground">{formatDate(row.date)}</p>
                <div className="flex items-center gap-1">
                  <Button
                    variant="ghost" size="icon" data-testid="expense-edit"
                    disabled={!!lockReason}
                    title={lockReason ?? undefined}
                    aria-label={lockReason ?? "Editar gasto"}
                    className="h-7 w-7 text-muted-foreground hover:text-primary"
                    onClick={() => setEditingExpense(row)}
                  >
                    {lockReason ? <Lock className="h-3.5 w-3.5" /> : <Pencil className="h-3.5 w-3.5" />}
                  </Button>
                  <DeleteOperationDialog
                    label="este gasto"
                    info={deleteInfo}
                    isDeleting={deletingId === row.id}
                    onConfirm={() => handleDelete(row.id)}
                  />
                </div>
              </div>
            </div>

            {/* Desktop */}
            <div className="hidden sm:grid grid-cols-[100px_140px_1fr_120px_80px] gap-3 px-4 py-3 items-center">
              <span className="text-sm text-muted-foreground tabular-nums">{formatDate(row.date)}</span>
              <Badge variant="outline" className={`text-xs w-fit ${categoryColors[row.category] || categoryColors.Otros}`}>
                {row.category}
              </Badge>
              <div className="flex items-center gap-2 min-w-0">
                <span className="text-sm font-medium text-foreground truncate">{row.description}</span>
                {row.costCenterId && costCenterNameById.get(row.costCenterId) && (
                  <Badge variant="outline" className="text-[10px] shrink-0 text-muted-foreground">
                    {costCenterNameById.get(row.costCenterId)}
                  </Badge>
                )}
                <PaymentMethodBadge name={row.paymentMethodName} kind={row.paymentMethodKind} layout="inline" />
              </div>
              <span className="text-right text-sm font-semibold text-destructive tabular-nums">{formatMoney(row.amount)}</span>
              <div className="flex items-center gap-1 justify-end">
                <Button
                  variant="ghost" size="icon" data-testid="expense-edit"
                  disabled={!!lockReason}
                  title={lockReason ?? undefined}
                  aria-label={lockReason ?? "Editar gasto"}
                  className="h-7 w-7 text-muted-foreground hover:text-primary"
                  onClick={() => setEditingExpense(row)}
                >
                  {lockReason ? <Lock className="h-3.5 w-3.5" /> : <Pencil className="h-3.5 w-3.5" />}
                </Button>
                <DeleteOperationDialog
                  label="este gasto"
                  info={deleteInfo}
                  isDeleting={deletingId === row.id}
                  onConfirm={() => handleDelete(row.id)}
                />
              </div>
            </div>
          </div>
          )
        })}
      </div>

      <PaginationBar
        meta={meta}
        onPageChange={setPage}
        onSizeChange={setPageSize}
        loading={isLoading}
        label="gastos"
      />

      {/* Add dialog */}
      <Dialog open={addOpen} onOpenChange={setAddOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nuevo gasto</DialogTitle>
          </DialogHeader>
          <ExpenseForm onSuccess={() => { setAddOpen(false) }} />
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
            onSuccess={() => { setEditingExpense(null) }}
          />
        </DialogContent>
      </Dialog>

      <ExpenseImportDialog
        open={importOpen}
        onOpenChange={setImportOpen}
        onSuccess={() => refetch()}
      />
    </div>
  )
}
