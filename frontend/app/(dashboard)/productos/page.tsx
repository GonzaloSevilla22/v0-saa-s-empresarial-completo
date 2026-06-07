"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { ProductCatalog } from "@/components/products/product-catalog"
import { ProductForm } from "@/components/forms/product-form"
import { PriceSuggestionModal } from "@/components/ai/PriceSuggestionModal"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { usePlanGate } from "@/hooks/auth/use-plan-gate"
import { MAX_PRODUCTS_FREE } from "@/lib/constants"
import type { Product } from "@/lib/types"

export default function ProductosPage() {
  const { products, deleteProduct, refreshData } = useData()
  const { user } = useAuth()
  const { limits } = usePlanLimits()

  // Plan gate for AI price suggestion (task 3.2-3.3)
  const { hasAccess: hasPriceSuggestionAccess } = usePlanGate("avanzado")

  const [open, setOpen] = useState(false)
  const [editingProduct, setEditingProduct] = useState<Product | undefined>()
  /** When set, the form opens in "new variant" mode pre-filling this parent id */
  const [defaultParentId, setDefaultParentId] = useState<string | undefined>()

  // Price suggestion modal state (task 3.4)
  const [priceSuggestionProduct, setPriceSuggestionProduct] = useState<Product | null>(null)

  // Realtime subscription for products is handled centrally in DataProvider.

  const maxProducts = limits?.maxProducts ?? MAX_PRODUCTS_FREE
  const isAtLimit = products.length >= maxProducts

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

  const dialogTitle = editingProduct
    ? "Editar producto"
    : defaultParentId
      ? "Nueva variante"
      : "Nuevo producto"

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Productos</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {products.length} producto{products.length !== 1 ? "s" : ""}
          {Number.isFinite(maxProducts) && ` / ${maxProducts}`}
        </p>
      </div>

      {user?.role === "admin" && (
        <ModuleMetricsWrapper
          moduleType="stock"
          title="Analíticas de Productos & Stock"
          subtitle="Monitoreo de inventario"
        />
      )}

      {isAtLimit && (
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/10 p-4">
          <p className="text-sm text-yellow-400">
            Llegaste al límite de {maxProducts} productos de tu plan. Actualizá tu plan para tener más capacidad.
          </p>
        </div>
      )}

      {/* task 3.2-3.3: onSuggestPrice only passed when user has avanzado/pro plan */}
      <ProductCatalog
        products={products}
        onAdd={handleAdd}
        onEdit={handleEdit}
        onAddVariant={handleAddVariant}
        onDelete={deleteProduct}
        isAtLimit={isAtLimit}
        onImportComplete={refreshData}
        onSuggestPrice={hasPriceSuggestionAccess ? setPriceSuggestionProduct : undefined}
      />

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

      {/* Price Suggestion Modal (task 3.4) */}
      {priceSuggestionProduct && (
        <PriceSuggestionModal
          productId={priceSuggestionProduct.id}
          productName={priceSuggestionProduct.name}
          isOpen={priceSuggestionProduct !== null}
          onClose={() => setPriceSuggestionProduct(null)}
        />
      )}
    </div>
  )
}
