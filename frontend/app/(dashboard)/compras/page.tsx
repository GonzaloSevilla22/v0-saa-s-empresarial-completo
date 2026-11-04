"use client"

import { useState, useCallback } from "react"
import { usePurchases } from "@/hooks/data/use-purchases"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import { InvoiceAIButton } from "@/components/invoice/InvoiceAIButton"
import { useAuth } from "@/contexts/auth-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { useOrgRole } from "@/hooks/useOrgRole"
import { CAN_PURCHASE, CAN_VOID_DELIVERY_NOTE, canModifyDocument, hasCapability } from "@/lib/rbac-capabilities"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { ExportButton } from "@/components/export/ExportButton"
import type { PurchaseOperation } from "@/lib/group-operations"

export default function ComprasPage() {
  const {
    purchases, meta, isLoading, error,
    dateFrom, setDateFrom, dateTo, setDateTo,
    costCenterId, setCostCenterId,
    paymentMethodId, setPaymentMethodId, clearFilters,
    setPage, setPageSize, refetch,
    deletePurchase, deletePurchasesByOperation,
  } = usePurchases()

  const { isAdmin, user } = useAuth()
  // ventas-unidades-conversion (cuarta revisión, D-F′): el listado muestra la
  // cantidad con el símbolo de su línea ("450 g") y lo exporta en el CSV.
  const { unitsById } = useUnitsOfMeasure()
  const { isWriter, roles, rolesResolved } = useOrgRole()
  // remitos-compra (D9): borrar la compra de un remito lo reabre y lo deja anulable, así que exige
  // el mismo rol que anularlo; el listado deshabilita «Eliminar» con su motivo si falta.
  const canVoidDeliveryNote = hasCapability(roles, CAN_VOID_DELIVERY_NOTE, rolesResolved)
  // multiusuario-operativo tanda B (D9, OQ-3 b): cargar una compra con factura exige CAN_PURCHASE (dueño,
  // administrador o compras), además de poder escribir: el depósito recibe mercadería por remito, no compra.
  // Sobre una compra de OTRO miembro sólo editan y eliminan el dueño y el administrador (OQ-4 b). Es sólo qué se
  // muestra: la barrera es la RPC (P0403) y `require_account_role` de FastAPI.
  const canPurchase = isWriter && hasCapability(roles, CAN_PURCHASE, rolesResolved)
  const canModifyPurchase = useCallback(
    (op: PurchaseOperation) =>
      canModifyDocument({
        roles, rolesResolved, capability: CAN_PURCHASE, authorId: op.createdBy, userId: user?.id,
      }),
    [roles, rolesResolved, user?.id],
  )

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
      {/* qa-integral-modulos G2 (H2/2.4): flex-wrap — el encabezado sin wrap
          medía 479 px de mínimo incluso con cero compras cargadas. */}
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Compras</h1>
          <p className="text-sm text-muted-foreground mt-1">Gestión de compras a proveedores</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <ExportButton exportType="purchases_csv" />
          {/* multiusuario-operativo tanda B (D9): la Factura IA termina en un alta de compra (POST /purchases),
              así que se ofrece sólo a quien puede comprar. */}
          {canPurchase && <InvoiceAIButton onPurchasesCreated={refetch} />}
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
        costCenterId={costCenterId}
        setCostCenterId={setCostCenterId}
        paymentMethodId={paymentMethodId}
        setPaymentMethodId={setPaymentMethodId}
        clearFilters={clearFilters}
        onPageChange={setPage}
        onPageSizeChange={setPageSize}
        onAdd={canPurchase ? handleAdd : undefined}
        onDeleteOperation={handleDeleteOperation}
        onEditOperation={handleEdit}
        canModifyOperation={canModifyPurchase}
        onRefetch={refetch}
        canVoidDeliveryNote={canVoidDeliveryNote}
        unitsById={unitsById}
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
