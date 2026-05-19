"use client"

import { useState, useCallback } from "react"
import { useData } from "@/contexts/data-context"
import { SaleForm } from "@/components/forms/sale-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { useAuth } from "@/contexts/auth-context"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import type { SaleOperation } from "@/lib/group-operations"

export default function VentasPage() {
  // Realtime subscription for sales is handled centrally in DataProvider.
  const { sales, clients, deleteSale, deleteSalesByOperation } = useData()
  const { isAdmin } = useAuth()

  // ── Dialog state ────────────────────────────────────────────────────────────
  const [dialogOpen, setDialogOpen] = useState(false)
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
    // Clear editing state after animation completes (avoids flicker)
    setTimeout(() => setEditingOperation(null), 300)
  }

  // Delete handler — 1 DB call for grouped ops, 1 for historical
  const handleDeleteOperation = useCallback(
    async (op: SaleOperation) => {
      if (op.operationId) {
        await deleteSalesByOperation(op.operationId)
      } else {
        // Historical record (no operationId) — always a single item
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

      <SaleOperationsList
        sales={sales}
        clients={clients}
        onAdd={handleAdd}
        onDeleteOperation={handleDeleteOperation}
        onEditOperation={handleEdit}
      />

      <Dialog open={dialogOpen} onOpenChange={(open) => { if (!open) handleDialogClose() }}>
        <DialogContent className="bg-card border-border overflow-hidden">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              {editingOperation ? "Editar venta" : "Nueva venta"}
            </DialogTitle>
          </DialogHeader>
          {/* key forces a fresh form instance on each open — avoids stale state */}
          <SaleForm
            key={editingOperation ? editingOperation.key : "new-sale"}
            editingOperation={editingOperation ?? undefined}
            onSuccess={handleDialogClose}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
