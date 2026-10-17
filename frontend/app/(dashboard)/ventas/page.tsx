"use client"

import { useState, useCallback } from "react"
import { useSales } from "@/hooks/data/use-sales"
import { useClients } from "@/hooks/data/use-clients"
import { SaleForm } from "@/components/forms/sale-form"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { useAuth } from "@/contexts/auth-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { useOrgRole } from "@/hooks/useOrgRole"
import { CAN_SELL, canModifyDocument, hasCapability } from "@/lib/rbac-capabilities"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { ExportButton } from "@/components/export/ExportButton"
import type { SaleOperation } from "@/lib/group-operations"

export default function VentasPage() {
  const { clients } = useClients()
  const {
    sales, meta, isLoading, error,
    dateFrom, setDateFrom, dateTo, setDateTo,
    paymentMethodId, setPaymentMethodId, clearFilters,
    setPage, setPageSize, refetch,
    deleteSale, deleteSalesByOperation,
  } = useSales()

  const { isAdmin, user } = useAuth()
  // ventas-unidades-conversion (cuarta revisión, D-F′): el listado muestra la
  // cantidad con el símbolo de su línea ("450 g") y lo exporta en el CSV.
  const { unitsById } = useUnitsOfMeasure()
  const { isWriter, roles, rolesResolved } = useOrgRole()
  // multiusuario-operativo tanda B (D9, OQ-3 b): vender por el formulario exige CAN_SELL (dueño, administrador,
  // vendedor o cajero), además de poder escribir: un depósito o un contador son escritores pero no venden. Y sobre
  // una venta de OTRO miembro sólo editan y eliminan el dueño y el administrador (OQ-4 b). Es sólo qué se muestra:
  // la barrera es la RPC (P0403) y `require_account_role` de FastAPI.
  const canSell = isWriter && hasCapability(roles, CAN_SELL, rolesResolved)
  const canModifySale = useCallback(
    (op: SaleOperation) =>
      canModifyDocument({
        roles, rolesResolved, capability: CAN_SELL, authorId: op.createdBy, userId: user?.id,
      }),
    [roles, rolesResolved, user?.id],
  )

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
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Ventas</h1>
          <p className="text-sm text-muted-foreground mt-1">Gestión de todas tus ventas</p>
        </div>
        <ExportButton exportType="sales_csv" />
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
        meta={meta}
        loading={isLoading}
        error={error}
        dateFrom={dateFrom}
        setDateFrom={setDateFrom}
        dateTo={dateTo}
        setDateTo={setDateTo}
        paymentMethodId={paymentMethodId}
        setPaymentMethodId={setPaymentMethodId}
        clearFilters={clearFilters}
        onPageChange={setPage}
        onPageSizeChange={setPageSize}
        clients={clients}
        onAdd={canSell ? handleAdd : undefined}
        onDeleteOperation={handleDeleteOperation}
        onEditOperation={handleEdit}
        canModifyOperation={canModifySale}
        onRefetch={refetch}
        unitsById={unitsById}
      />

      <ResponsiveModal
        open={dialogOpen}
        onOpenChange={(open) => { if (!open) handleDialogClose() }}
        title={editingOperation ? "Editar venta" : "Nueva venta"}
      >
        <SaleForm
          key={editingOperation ? editingOperation.key : "new-sale"}
          editingOperation={editingOperation ?? undefined}
          onSuccess={() => { handleDialogClose(); refetch() }}
        />
      </ResponsiveModal>
    </div>
  )
}
