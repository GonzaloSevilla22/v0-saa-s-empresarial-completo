"use client"

import { useState, useCallback, useMemo } from "react"
import { useData } from "@/contexts/data-context"
import { SaleForm } from "@/components/forms/sale-form"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { useAuth } from "@/contexts/auth-context"
import { useOrgRole } from "@/hooks/useOrgRole"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { usePaginatedQuery } from "@/hooks/use-paginated-query"
import type { Sale } from "@/lib/types"
import type { SaleOperation } from "@/lib/group-operations"

// ── Row mapper (mirrors DataContext.mapSale) ──────────────────────────────────
function mapRow(r: any): Sale {
  return {
    id:          r.id,
    date:        r.date?.split("T")[0] ?? r.date,
    productId:   r.product_id,
    productName: r.product?.name || "Eliminado",
    clientId:    r.client_id,
    clientName:  r.client?.name  || "Consumidor Final",
    quantity:    r.quantity,
    unitPrice:   Number(r.amount),
    total:       Number(r.total ?? r.amount),
    currency:    r.currency,
    operationId: r.operation_id ?? undefined,
  }
}

export default function VentasPage() {
  const { clients, deleteSale, deleteSalesByOperation } = useData()
  const { isAdmin } = useAuth()
  const { isWriter } = useOrgRole()

  // ── Paginated sales ───────────────────────────────────────────────────────
  const pq = usePaginatedQuery<any>({
    table:  "sales",
    select: "*, product:products(name), client:clients(name)",
    applyFilters: (base, { dateFrom, dateTo }) => {
      let q = base
      if (dateFrom) q = q.gte("date", dateFrom)
      if (dateTo)   q = q.lte("date", dateTo)
      return q
    },
    defaultSortKey:  "date",
    defaultSortDir:  "desc",
    defaultPageSize: 50,
  })

  const sales = useMemo(() => pq.data.map(mapRow), [pq.data])

  // ── Dialog state ──────────────────────────────────────────────────────────
  const [dialogOpen,       setDialogOpen]       = useState(false)
  const [editingOperation, setEditingOperation] = useState<SaleOperation | null>(null)

  function handleAdd() {
    setEditingOperation(null)
    setDialogOpen(true)
  }

  function handleEdit(op: SaleOperation) {
    setEditingOperation(op)
    setDialogOpen(true)
  }

  function handleDialogClose() {
    setDialogOpen(false)
    setTimeout(() => setEditingOperation(null), 300)
  }

  const handleDeleteOperation = useCallback(
    async (op: SaleOperation) => {
      if (op.operationId) {
        await deleteSalesByOperation(op.operationId)
      } else {
        await deleteSale(op.items[0].id)
      }
    },
    [deleteSale, deleteSalesByOperation],
  )

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Ventas</h1>
        <p className="text-sm text-muted-foreground mt-1">Gestión de todas tus ventas</p>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="ventas"
          title="Analíticas de Ventas"
          subtitle="Rendimiento comercial global"
        />
      )}

      {!isWriter && <NoWriteAccessBanner />}

      <SaleOperationsList
        sales={sales}
        meta={pq.meta}
        loading={pq.loading}
        error={pq.error}
        dateFrom={pq.dateFrom}
        setDateFrom={pq.setDateFrom}
        dateTo={pq.dateTo}
        setDateTo={pq.setDateTo}
        clearFilters={pq.clearFilters}
        onPageChange={pq.setPage}
        onPageSizeChange={pq.setPageSize}
        clients={clients}
        onAdd={isWriter ? handleAdd : undefined}
        onDeleteOperation={handleDeleteOperation}
        onEditOperation={handleEdit}
        onRefetch={pq.refetch}
      />

      <ResponsiveModal
        open={dialogOpen}
        onOpenChange={(open) => { if (!open) handleDialogClose() }}
        title={editingOperation ? "Editar venta" : "Nueva venta"}
      >
        <SaleForm
          key={editingOperation ? editingOperation.key : "new-sale"}
          editingOperation={editingOperation ?? undefined}
          onSuccess={() => { handleDialogClose(); pq.refetch() }}
        />
      </ResponsiveModal>
    </div>
  )
}
