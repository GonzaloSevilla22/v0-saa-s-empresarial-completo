"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { LowStockAlert } from "@/components/stock/low-stock-alert"
import { useAuth } from "@/contexts/auth-context"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { ProductForm } from "@/components/forms/product-form"
import { toast } from "sonner"
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
]

export default function StockPage() {
  const { products, getLowStockProducts, updateProduct } = useData()
  const lowStock = getLowStockProducts()
  const { isAdmin } = useAuth()

  // Quick-edit dialog (opened from alert panel "edit" button)
  const [editingProduct, setEditingProduct] = useState<Product | undefined>()

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Stock</h1>
          <p className="text-sm text-muted-foreground mt-1">Control de inventario y reposición</p>
        </div>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="stock"
          title="Analíticas de Stock"
          subtitle="Control de inventario y valuación"
        />
      )}

      {/* Professional alert panel — replaces the broken flat badge map */}
      <LowStockAlert
        products={lowStock}
        onEdit={setEditingProduct}
      />

      {/* Full inventory table */}
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
        importColumnMap={[
          { csvHeader: "Producto",     key: "name"     },
          { csvHeader: "Stock actual", key: "stock"    },
        ]}
        onImport={() => {
          toast.info(
            "El stock se actualiza automáticamente al registrar compras y ventas. " +
            "Para ajustar el inventario usá el módulo de Compras.",
            { duration: 6000 },
          )
        }}
      />

      {/* Quick-edit dialog (from alert panel) */}
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
