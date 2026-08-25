"use client"

import { useState, useMemo } from "react"
import { useSearchParams } from "next/navigation"
import { useProducts } from "@/hooks/data/use-products"
import { useAuth } from "@/contexts/auth-context"
import { useBranches } from "@/hooks/data/use-branches"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { LowStockAlert } from "@/components/stock/low-stock-alert"
import { StockAdjustmentModal } from "@/components/stock/stock-adjustment-modal"
import { StockImportAdjustmentDialog } from "@/components/stock/stock-import-adjustment-dialog"
import { StockMovementsPanel } from "@/components/stock/stock-movements-panel"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { ProductForm } from "@/components/forms/product-form"
import { Button } from "@/components/ui/button"
import { SlidersHorizontal, Upload } from "lucide-react"
import { ExportButton } from "@/components/export/ExportButton"
import { holdsOwnStock, getStockStatus, isBelowThreshold, type StockStatus } from "@/lib/product-stock"
import { TransferStockAction } from "@/components/branches/TransferStockAction"
import type { Product } from "@/lib/types"

/** Sort order for the "Estado" column — most urgent first, "sin mínimo" last. */
const STATUS_SORT_RANK: Record<StockStatus, number> = {
  critico: 0,
  bajo: 1,
  ok: 2,
  "sin-umbral": 3,
}

/**
 * sucursal-guard-vaciado-auditoria (G3, task 7.2): `columns` pasa de
 * constante estática a función de las sucursales activas — la acción
 * "Transferir stock" sólo tiene sentido con el módulo de sucursales
 * habilitado por el plan Y más de una sucursal activa (con una sola no hay
 * a dónde transferir, D7). `buildColumns` se memoiza en el componente con
 * `showTransfer` como dependencia.
 */
function buildColumns(showTransfer: boolean): Column<Product>[] {
  return [
  {
    key: "name",
    header: "Producto",
    cell: (row) => <span className="font-medium">{row.name}</span>,
  },
  {
    key: "category",
    header: "Categoría",
    cell: (row) => <span className="text-muted-foreground">{row.category}</span>,
  },
  {
    key: "stock",
    header: "Stock actual",
    cell: (row) => <span className="font-medium tabular-nums">{row.stock}</span>,
    sortable: true,
    sortValue: (row) => row.stock,
  },
  {
    key: "minStock",
    header: "Stock mínimo",
    cell: (row) => <span className="tabular-nums text-muted-foreground">{row.minStock}</span>,
  },
  {
    key: "status",
    header: "Estado",
    cell: (row) => <StockSemaphore stock={row.stock} minStock={row.minStock} />,
    sortable: true,
    sortValue: (row) => STATUS_SORT_RANK[getStockStatus(row.stock, row.minStock)],
  },
  {
    key: "reponer",
    header: "A reponer",
    cell: (row) => {
      const toOrder = isBelowThreshold(row.stock, row.minStock) ? row.minStock * 2 - row.stock : 0
      return toOrder > 0 ? (
        <span className="text-primary font-medium tabular-nums">{toOrder} unidades</span>
      ) : (
        <span className="text-muted-foreground">—</span>
      )
    },
  },
  {
    key: "adjust",
    header: "",
    cell: (row) => (
      <div className="flex items-center justify-end gap-1">
        {showTransfer && holdsOwnStock(row) && (
          <TransferStockAction productId={row.id} productName={row.name} />
        )}
        <AdjustButton product={row} />
      </div>
    ),
  },
  ]
}

/** Inline adjust button rendered per row — declared outside so columns is stable */
function AdjustButton({ product }: { product: Product }) {
  const [open, setOpen] = useState(false)
  // Variant parents and untracked services have no stock to adjust at this level.
  if (!holdsOwnStock(product)) {
    return null
  }
  return (
    <>
      <Button
        variant="ghost"
        size="sm"
        className="h-7 px-2 text-xs opacity-0 group-hover:opacity-100 transition-opacity"
        onClick={(e) => { e.stopPropagation(); setOpen(true) }}
        title="Ajustar stock"
      >
        <SlidersHorizontal className="h-3.5 w-3.5" />
      </Button>
      <StockAdjustmentModal
        open={open}
        onOpenChange={setOpen}
        product={product}
      />
    </>
  )
}

export default function StockPage() {
  const { products } = useProducts()
  // The stock/reposition views operate over real inventory items only —
  // variant_only parents (stock lives in their children) and untracked services
  // are catalogue constructs and would otherwise show bogus "Crítico" rows.
  const inventory = products.filter(holdsOwnStock)
  const lowStock = inventory.filter(p => isBelowThreshold(p.stock, p.minStock))
  const { isAdmin } = useAuth()

  // sucursal-guard-vaciado-auditoria (G3, D7): "Transferir stock" sólo tiene
  // sentido con el módulo de sucursales habilitado y más de una activa —
  // con una sola no hay a dónde transferir y el control sería ruido.
  const { branches } = useBranches()
  const { limits } = usePlanLimits()
  const showTransfer = !!limits?.hasBranchesModule && branches.length > 1
  const columns = useMemo(() => buildColumns(showTransfer), [showTransfer])

  // sucursal-guard-vaciado-auditoria (G3, task 7.5): camino directo desde el
  // aviso de error de venta — humanizeOperationError navega a
  // /stock?product=<id>. Se abre el mismo panel de existencias/transferencia
  // que la fila del producto ofrece, sin duplicar el diálogo.
  const searchParams = useSearchParams()
  const preselectedProductId = searchParams.get("product")

  // Quick-edit dialog triggered from the alert panel
  const [editingProduct,   setEditingProduct]   = useState<Product | undefined>()
  // Global adjustment modal (from header button — no pre-selected product)
  const [adjustModalOpen,  setAdjustModalOpen]  = useState(false)
  // Bulk CSV import dialog
  const [importOpen,       setImportOpen]       = useState(false)

  return (
    <div className="flex flex-col gap-6">
      {/* ── Page header ───────────────────────────────────────────────────── */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Stock</h1>
          <p className="text-sm text-muted-foreground mt-1">Control de inventario y reposición</p>
        </div>
        <div className="flex items-center gap-2">
          <ExportButton exportType="stock_csv" />
          <Button
            variant="outline"
            size="sm"
            onClick={() => setImportOpen(true)}
            className="gap-2"
          >
            <Upload className="h-4 w-4" />
            <span className="hidden sm:inline">Importar ajuste</span>
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => setAdjustModalOpen(true)}
            className="gap-2"
          >
            <SlidersHorizontal className="h-4 w-4" />
            <span className="hidden sm:inline">Ajustar stock</span>
            <span className="sm:hidden">Ajustar</span>
          </Button>
        </div>
      </div>

      {/* sucursal-guard-vaciado-auditoria (G3, task 7.5): camino directo
          desde el aviso de error de venta — se auto-abre sin trigger propio. */}
      {showTransfer && preselectedProductId && (() => {
        const preselected = inventory.find((p) => p.id === preselectedProductId)
        return preselected ? (
          <TransferStockAction
            productId={preselected.id}
            productName={preselected.name}
            defaultOpen
            hideTrigger
          />
        ) : null
      })()}

      {/* ── Admin analytics ───────────────────────────────────────────────── */}
      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="stock"
          title="Analíticas de Stock"
          subtitle="Control de inventario y valuación"
        />
      )}

      {/* ── Low-stock alert panel ─────────────────────────────────────────── */}
      <LowStockAlert
        products={lowStock}
        onEdit={setEditingProduct}
      />

      {/* ── Full inventory table ──────────────────────────────────────────── */}
      <DataTable
        data={inventory}
        columns={columns}
        searchPlaceholder="Buscar productos..."
        searchKey={(row) => `${row.name} ${row.category}`}
        getId={(row) => row.id}
        mobileCard={(row) => {
          const toOrder = isBelowThreshold(row.stock, row.minStock) ? row.minStock * 2 - row.stock : 0
          return (
            <div className="flex items-center justify-between gap-3">
              <div className="min-w-0 flex flex-col gap-0.5">
                <span className="font-medium text-sm text-foreground truncate">{row.name}</span>
                <span className="text-xs text-muted-foreground">{row.category}</span>
                {toOrder > 0 && (
                  <span className="text-xs text-primary font-medium">Reponer: {toOrder} uds</span>
                )}
              </div>
              <div className="flex flex-col items-end gap-1 shrink-0">
                <StockSemaphore stock={row.stock} minStock={row.minStock} size="sm" />
                <span className="text-xs text-muted-foreground tabular-nums">{row.stock} / {row.minStock} uds</span>
              </div>
            </div>
          )
        }}
        exportColumns={[
          { key: "name",     header: "Producto"      },
          { key: "category", header: "Categoría"     },
          { key: "stock",    header: "Stock actual"  },
          { key: "minStock", header: "Stock mínimo"  },
        ]}
        exportFilename="stock"
      />

      {/* ── Movements audit log ───────────────────────────────────────────── */}
      <StockMovementsPanel />

      {/* ── Global adjustment modal (no pre-selected product) ────────────── */}
      <StockAdjustmentModal
        open={adjustModalOpen}
        onOpenChange={setAdjustModalOpen}
      />

      {/* ── Bulk CSV import adjustment dialog ────────────────────────────── */}
      <StockImportAdjustmentDialog
        open={importOpen}
        onOpenChange={setImportOpen}
      />

      {/* ── Quick-edit dialog (opened from alert panel) ───────────────────── */}
      <Dialog
        open={!!editingProduct}
        onOpenChange={(v) => { if (!v) setEditingProduct(undefined) }}
      >
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Editar producto</DialogTitle>
          </DialogHeader>
          <ProductForm
            initialData={editingProduct}
            onSuccess={() => setEditingProduct(undefined)}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
