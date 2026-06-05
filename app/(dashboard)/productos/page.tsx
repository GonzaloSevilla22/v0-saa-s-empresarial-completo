"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { ProductCatalog } from "@/components/products/product-catalog"
import { ProductForm } from "@/components/forms/product-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { MAX_PRODUCTS_FREE } from "@/lib/constants"
import type { Product } from "@/lib/types"

export default function ProductosPage() {
  const { products, deleteProduct, refreshData } = useData()
  const { user } = useAuth()
  const { limits } = usePlanLimits()

  const [open, setOpen] = useState(false)
  const [editingProduct, setEditingProduct] = useState<Product | undefined>()
  /** When set, the form opens in "new variant" mode pre-filling this parent id */
  const [defaultParentId, setDefaultParentId] = useState<string | undefined>()

  // Realtime subscription for products is handled centrally in DataProvider.

  const maxProducts = limits?.maxProducts ?? MAX_PRODUCTS_FREE
  const isAtLimit = products.length >= maxProducts

  // â”€â”€ Dialog handlers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  function handleAdd() {
    setEditingProduct(undefined)
    setDefaultParentId(undefined)
    setOpen(true)
  }

  function handleEdit(product: Product) {
    setEditingProduct(product)
    setDefaultParentId(undefined)
    setOpen(true)
  }

  function handleAddVariant(parent: Product) {
    setEditingProduct(undefined)
    setDefaultParentId(parent.id)
    setOpen(true)
  }

  function handleClose() {
    setOpen(false)
    setEditingProduct(undefined)
    setDefaultParentId(undefined)
  }

  // Derive dialog title
  const dialogTitle = editingProduct
    ? "Editar producto"
    : defaultParentId
      ? "Nueva variante"
      : "Nuevo producto"

  return (
    <div className="flex flex-col gap-6">
      {/* â”€â”€ Header â”€â”€ */}
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Productos</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {products.length} producto{products.length !== 1 ? "s" : ""}
          {Number.isFinite(maxProducts) && ` / ${maxProducts}`}
        </p>
      </div>

      {/* â”€â”€ Admin analytics â”€â”€ */}
      {user?.role === "admin" && (
        <ModuleMetricsWrapper
          moduleType="stock"
          title="AnalÃ­ticas de Productos & Stock"
          subtitle="Monitoreo de inventario"
        />
      )}

      {/* â”€â”€ Plan limit warning â”€â”€ */}
      {isAtLimit && (
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/10 p-4">
          <p className="text-sm text-yellow-400">
            Llegaste al límite de {maxProducts} productos de tu plan. Actualizá tu plan para tener más capacidad.
          </p>
        </div>
      )}

      {/* â”€â”€ Catalog (hierarchical) â”€â”€ */}
      <ProductCatalog
        products={products}
        onAdd={handleAdd}
        onEdit={handleEdit}
        onAddVariant={handleAddVariant}
        onDelete={deleteProduct}
        isAtLimit={isAtLimit}
        onImportComplete={refreshData}
      />

      {/* â”€â”€ Create / Edit dialog â”€â”€ */}
      <Dialog open={open} onOpenChange={(v) => { if (!v) handleClose() }}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">{dialogTitle}</DialogTitle>
          </DialogHeader>
          <ProductForm
            initialData={editingProduct}
            defaultParentId={defaultParentId}
            onSuccess={handleClose}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
