"use client"

import { useState, useEffect, useCallback } from "react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import { useAuth } from "@/contexts/auth-context"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import type { PurchaseOperation } from "@/lib/group-operations"

export default function ComprasPage() {
  const { purchases, deletePurchase, deletePurchasesByOperation, refreshData } = useData()
  const [open, setOpen] = useState(false)
  const { isAdmin } = useAuth()
  const supabase = createClient()

  // Realtime subscription
  useEffect(() => {
    const channel = supabase
      .channel("compras-realtime")
      .on("postgres_changes",
        { event: "*", schema: "public", table: "purchases" },
        () => { refreshData() },
      )
      .subscribe()
    return () => { supabase.removeChannel(channel) }
  }, [supabase, refreshData])

  // Delete handler — 1 DB call for grouped ops, 1 for historical
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
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Compras</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Gestión de compras a proveedores
        </p>
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
        onAdd={() => setOpen(true)}
        onDeleteOperation={handleDeleteOperation}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nueva compra</DialogTitle>
          </DialogHeader>
          <PurchaseForm onSuccess={() => setOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  )
}
