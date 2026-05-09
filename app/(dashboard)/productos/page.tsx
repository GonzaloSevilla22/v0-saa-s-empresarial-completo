"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { ProductCatalog } from "@/components/products/product-catalog"
import { ProductForm } from "@/components/forms/product-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { MAX_PRODUCTS_FREE } from "@/lib/constants"
import { parseAmount } from "@/lib/excel"
import { toast } from "sonner"
import type { Product } from "@/lib/types"

export default function ProductosPage() {
  const { products, deleteProduct, addProduct } = useData()
  const { user } = useAuth()

  const [open, setOpen] = useState(false)
  const [editingProduct, setEditingProduct] = useState<Product | undefined>()
  /** When set, the form opens in "new variant" mode pre-filling this parent id */
  const [defaultParentId, setDefaultParentId] = useState<string | undefined>()

  // Realtime subscription for products is handled centrally in DataProvider.

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

  // ── CSV import handler ─────────────────────────────────────────────────────
  // Called by ProductCatalog after parsing + filtering the CSV rows.
  // `rows` keys match the csvHeader→key map defined in ProductCatalog:
  //   nombre, precio, costo, categoria, stock, stock_minimo, codigo

  async function handleImport(rows: Record<string, string>[]) {
    const VALID_CATEGORIES = new Set([
      "Electrónica", "Ropa", "Alimentos", "Hogar",
      "Salud", "Accesorios", "Otros",
    ])
    let success = 0
    const errors: string[] = []

    for (let i = 0; i < rows.length; i++) {
      const row = rows[i]

      if (!row.nombre?.trim()) {
        errors.push(`Fila ${i + 2}: nombre requerido`)
        continue
      }

      const price = parseAmount(row.precio)
      if (isNaN(price) || price < 0) {
        errors.push(`Fila ${i + 2}: precio inválido ("${row.precio ?? ""}")`)
        continue
      }

      const cost     = parseAmount(row.costo)      >= 0 ? parseAmount(row.costo)      : 0
      const stock    = parseInt(row.stock    ?? "0", 10)
      const minStock = parseInt(row.stock_minimo ?? "0", 10)
      const category = VALID_CATEGORIES.has(row.categoria?.trim())
        ? row.categoria!.trim()
        : "Otros"

      try {
        await addProduct({
          name:      row.nombre.trim(),
          category,
          price,
          cost:      isNaN(cost) ? 0 : cost,
          stock:     isNaN(stock)    ? 0 : stock,
          minStock:  isNaN(minStock) ? 0 : minStock,
          barcode:   row.codigo?.trim() || undefined,
          margin:    price > 0 ? Math.round(((price - cost) / price) * 100) : 0,
          isVariant: false,
        })
        success++
      } catch (err: any) {
        errors.push(`Fila ${i + 2}: ${err?.message ?? "error desconocido"}`)
      }
    }

    if (success > 0)
      toast.success(`✅ ${success} producto${success !== 1 ? "s" : ""} importado${success !== 1 ? "s" : ""} correctamente`)
    if (errors.length > 0) {
      toast.error(`❌ ${errors.length} fila${errors.length !== 1 ? "s" : ""} con error`)
      errors.slice(0, 3).forEach((e) => toast.error(e))
    }
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
        onImport={handleImport}
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
