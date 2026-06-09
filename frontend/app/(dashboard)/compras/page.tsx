"use client"

import { useState, useCallback } from "react"
import { usePurchases } from "@/hooks/data/use-purchases"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import { InvoiceAIButton } from "@/components/invoice/InvoiceAIButton"
import { useAuth } from "@/contexts/auth-context"
import { useOrgRole } from "@/hooks/useOrgRole"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { ExportButton } from "@/components/export/ExportButton"
import type { PurchaseOperation } from "@/lib/group-operations"

export default function ComprasPage() {
  const {
    purchases, meta, isLoading, error,
    dateFrom, setDateFrom, dateTo, setDateTo, clearFilters,
    setPage, setPageSize, refetch,
    deletePurchase, deletePurchasesByOperation,
  } = usePurchases()

  const { isAdmin } = useAuth()
  const { isWriter } = useOrgRole()

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
        <div className="flex items-center gap-2">
          <ExportButton exportType="purchases_csv" />
          <InvoiceAIButton onPurchasesCreated={refetch} />
        </div>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="compras"
          title="Analíticas de Compras"
          subtitle="Seguimiento de abastecimiento y costos"
        />
      )}

      {!isWriter && <NoWriteAccessBanner />}

      <PurchaseOperationsList
        purchases={purchases}
        meta={meta}
        loading={isLoading}
        error={error}
        dateFrom={dateFrom}
        setDateFrom={setDateFrom}
        dateTo={dateTo}
        setDateTo={setDateTo}
        clearFilters={clearFilters}
        onPageChange={setPage}
        onPageSizeChange={setPageSize}
        onAdd={isWriter ? handleAdd : undefined}
        onDeleteOperation={handleDeleteOperation}
        onEditOperation={handleEdit}
        onRefetch={refetch}
      />

      <ResponsiveModal
        open={dialogOpen}
        onOpenChange={(open) => { if (!open) handleDialogClose() }}
        title={editingOperation ? "Editar compra" : "Nueva compra"}
      >
        <PurchaseForm
          key={editingOperation ? editingOperation.key : "new-purchase"}
          editingOperation={editingOperation ?? undefined}
          onSuccess={() => { handleDialogClose(); refetch() }}
        />
      </ResponsiveModal>
    </div>
  )
}
