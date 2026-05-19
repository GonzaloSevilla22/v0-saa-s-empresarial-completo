"use client"

import { useState, useCallback } from "react"
import { useData } from "@/contexts/data-context"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import { InvoiceAIButton } from "@/components/invoice/InvoiceAIButton"
import { useAuth } from "@/contexts/auth-context"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import type { PurchaseOperation } from "@/lib/group-operations"

export default function ComprasPage() {
  // Realtime subscription for purchases is handled centrally in DataProvider.
  const { purchases, deletePurchase, deletePurchasesByOperation, refreshData } = useData()
  const { isAdmin } = useAuth()

  // ── Dialog state ────────────────────────────────────────────────────────────
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editingOperation, setEditingOperation] = useState<PurchaseOperation | null>(null)

  function handleAdd() {
    setEditingOperation(null)
    setDialogOpen(true)
  }

  function handleEdit(op: PurchaseOperation) {
    setEditingOperation(op)
    setDialogOpen(true)
  }

  function handleDialogClose() {
    setDialogOpen(false)
    // Clear editing state after animation completes (avoids flicker)
    setTimeout(() => setEditingOperation(null), 300)
  }

  // Delete handler — 1 DB call for grouped ops, 1 for historical
  const handleDeleteOperation = useCallback(
    async (op: PurchaseOperation) => {
      if (op.operationId) {
        await deletePurchasesByOperation(op.operationId)
      } else {
        // Historical record (no operationId) — always a single item
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
          <p className="text-sm text-muted-foreground mt-1">
            Gestión de compras a proveedores
          </p>
        </div>
        {/* Invoice AI scanner — floats in the page header so it's always visible */}
        <InvoiceAIButton onPurchasesCreated={refreshData} />
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
        onAdd={handleAdd}
        onDeleteOperation={handleDeleteOperation}
        onEditOperation={handleEdit}
      />

      <Dialog open={dialogOpen} onOpenChange={(open) => { if (!open) handleDialogClose() }}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              {editingOperation ? "Editar compra" : "Nueva compra"}
            </DialogTitle>
          </DialogHeader>
          {/* key forces a fresh form instance on each open — avoids stale state */}
          <PurchaseForm
            key={editingOperation ? editingOperation.key : "new-purchase"}
            editingOperation={editingOperation ?? undefined}
            onSuccess={handleDialogClose}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
