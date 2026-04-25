"use client"

import { useState, useEffect } from "react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { ProductCatalog } from "@/components/products/product-catalog"
import { ProductForm } from "@/components/forms/product-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { MAX_PRODUCTS_FREE } from "@/lib/constants"
import type { Product } from "@/lib/types"

export default function ProductosPage() {
  const { products, deleteProduct, refreshData } = useData()
  const { user } = useAuth()

  const [open, setOpen] = useState(false)
  const [editingProduct, setEditingProduct] = useState<Product | undefined>()
  /** When set, the form opens in "new variant" mode pre-filling this parent id */
  const [defaultParentId, setDefaultParentId] = useState<string | undefined>()

  const supabase = createClient()

  // Real-time subscription: refresh when products table changes
  useEffect(() => {
    const channel = supabase
      .channel("productos-realtime")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "products" },
        () => refreshData(),
      )
      .subscribe()

    return () => { supabase.removeChannel(channel) }
  }, [supabase, refreshData])

  const isAtLimit = user?.plan === "free" && products.length >= MAX_PRODUCTS_FREE

  // ── Dialog handlers ────────────────────────────────────────────────────────

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
      {/* ── Header ── */}
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Productos</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {products.length} producto{products.length !== 1 ? "s" : ""}
          {user?.plan === "free" && ` / ${MAX_PRODUCTS_FREE} (plan gratis)`}
        </p>
      </div>

      {/* ── Admin analytics ── */}
      {user?.role === "admin" && (
        <ModuleMetricsWrapper
          moduleType="stock"
          title="Analíticas de Productos & Stock"
          subtitle="Monitoreo de inventario"
        />
      )}

      {/* ── Plan limit warning ── */}
      {isAtLimit && (
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/10 p-4">
          <p className="text-sm text-yellow-400">
            Llegaste al límite de {MAX_PRODUCTS_FREE} productos del plan gratuito. Actualizá a Pro para tener productos ilimitados.
          </p>
        </div>
      )}

      {/* ── Catalog (hierarchical) ── */}
      <ProductCatalog
        products={products}
        onAdd={handleAdd}
        onEdit={handleEdit}
        onAddVariant={handleAddVariant}
        onDelete={deleteProduct}
        isAtLimit={isAtLimit}
      />

      {/* ── Create / Edit dialog ── */}
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
