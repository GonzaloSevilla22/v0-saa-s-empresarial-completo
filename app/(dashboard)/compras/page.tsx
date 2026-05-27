"use client"

import { useState, useCallback, useMemo } from "react"
import { useData } from "@/contexts/data-context"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import { InvoiceAIButton } from "@/components/invoice/InvoiceAIButton"
import { useAuth } from "@/contexts/auth-context"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { usePaginatedQuery } from "@/hooks/use-paginated-query"
import type { Purchase } from "@/lib/types"
import type { PurchaseOperation } from "@/lib/group-operations"

function mapRow(r: any): Purchase {
  return {
    id:          r.id,
    date:        r.date?.split("T")[0] ?? r.date,
    productId:   r.product_id,
    productName: r.product?.name || "Eliminado",
    quantity:    r.quantity,
    unitCost:    Number(r.amount),
    total:       Number(r.total ?? r.amount),
    operationId: r.operation_id ?? undefined,
  }
}

export default function ComprasPage() {
  const { deletePurchase, deletePurchasesByOperation } = useData()
  const { isAdmin } = useAuth()

  const pq = usePaginatedQuery<any>({
    table:  "purchases",
    select: "*, product:products(name)",
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

  const purchases = useMemo(() => pq.data.map(mapRow), [pq.data])

  const [dialogOpen,       setDialogOpen]       = useState(false)
  const [editingOperation, setEditingOperation] = useState<PurchaseOperation | null>(null)

  function handleAdd() { setEditingOperation(null); setDialogOpen(true) }
  function handleEdit(op: PurchaseOperation) { setEditingOperation(op); setDialogOpen(true) }
  function handleDialogClose() {
    setDialogOpen(false)
    setTimeout(() => setEditingOperation(null), 300)
  }

  const handleDeleteOperation = useCallback(
    async (op: PurchaseOperation) => {
      if (op.operationId) {
        await deletePurchasesByOperation(op.operationId)
      } else {
        await deletePurchase(op.items[0].id)
      }
    },
    [deletePurchase, deletePurchasesByOperation],
  )

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Compras</h1>
          <p className="text-sm text-muted-foreground mt-1">Gestión de compras a proveedores</p>
        </div>
        <InvoiceAIButton onPurchasesCreated={pq.refetch} />
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="compras"
          title="Analíticas de Compras"
          subtitle="Seguimiento de abastecimiento y costos"
        />
      )}

      <PurchaseOperationsList
        purchases={purchases}
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
        onAdd={handleAdd}
        onDeleteOperation={handleDeleteOperation}
        onEditOperation={handleEdit}
        onRefetch={pq.refetch}
      />

      <ResponsiveModal
        open={dialogOpen}
        onOpenChange={(open) => { if (!open) handleDialogClose() }}
        title={editingOperation ? "Editar compra" : "Nueva compra"}
      >
        <PurchaseForm
          key={editingOperation ? editingOperation.key : "new-purchase"}
          editingOperation={editingOperation ?? undefined}
          onSuccess={() => { handleDialogClose(); pq.refetch() }}
        />
      </ResponsiveModal>
    </div>
  )
}
