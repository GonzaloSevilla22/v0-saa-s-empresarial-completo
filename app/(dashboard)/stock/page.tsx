"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { LowStockAlert } from "@/components/stock/low-stock-alert"
import { StockAdjustmentModal } from "@/components/stock/stock-adjustment-modal"
import { StockMovementsPanel } from "@/components/stock/stock-movements-panel"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { ProductForm } from "@/components/forms/product-form"
import { Button } from "@/components/ui/button"
import { SlidersHorizontal } from "lucide-react"
import type { Product } from "@/lib/types"

const columns: Column<Product>[] = [
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
    sortValue: (row) => {
      if (row.stock <= row.minStock) return 0
      if (row.stock <= row.minStock * 1.5) return 1
      return 2
    },
  },
  {
    key: "reponer",
    header: "A reponer",
    cell: (row) => {
      const toOrder = row.stock <= row.minStock ? row.minStock * 2 - row.stock : 0
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
    cell: (row) => <AdjustButton product={row} />,
  },
]

/** Inline adjust button rendered per row — declared outside so columns is stable */
function AdjustButton({ product }: { product: Product }) {
  const [open, setOpen] = useState(false)
  if (
    product.stockControlType === "variant_only" ||
    product.stockControlType === "untracked"
  ) {
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
  const { products, getLowStockProducts } = useData()
  const lowStock = getLowStockProducts()
  const { isAdmin } = useAuth()

  // Quick-edit dialog triggered from the alert panel
  const [editingProduct,   setEditingProduct]   = useState<Product | undefined>()
  // Global adjustment modal (from header button — no pre-selected product)
  const [adjustModalOpen,  setAdjustModalOpen]  = useState(false)

  return (
    <div className="flex flex-col gap-6">
      {/* ── Page header ───────────────────────────────────────────────────── */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Stock</h1>
          <p className="text-sm text-muted-foreground mt-1">Control de inventario y reposición</p>
        </div>
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
        data={products}
        columns={columns}
        searchPlaceholder="Buscar productos..."
        searchKey={(row) => `${row.name} ${row.category}`}
        getId={(row) => row.id}
        mobileCard={(row) => {
          const toOrder = row.stock <= row.minStock ? row.minStock * 2 - row.stock : 0
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
