"use client"

import { useState, useEffect } from "react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { ProductForm } from "@/components/forms/product-form"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { BarChart3 } from "lucide-react"
import Link from "next/link"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { formatMoney } from "@/lib/format"
import { MAX_PRODUCTS_FREE } from "@/lib/constants"
import type { Product } from "@/lib/types"

const columns: Column<Product>[] = [
  {
    key: "name",
    header: "Producto",
    cell: (row) => (
      <div className="flex flex-col">
        <span className="font-medium">{row.name}</span>
        {row.parentId && (
          <span className="text-[10px] text-primary uppercase font-bold tracking-tighter">Variante</span>
        )}
      </div>
    ),
  },
  {
    key: "barcode",
    header: "Código",
    cell: (row) => <code className="text-[10px] bg-muted px-1 rounded">{row.barcode || "-"}</code>,
  },
  {
    key: "category",
    header: "Categoría",
    cell: (row) => (
      <Badge variant="outline" className="text-xs border-border text-muted-foreground">{row.category}</Badge>
    ),
  },
  {
    key: "price",
    header: "Precio",
    cell: (row) => <span className="font-medium text-emerald-400">{formatMoney(row.price)}</span>,
    sortable: true,
    sortValue: (row) => row.price,
  },
  {
    key: "cost",
    header: "Costo",
    cell: (row) => <span className="text-muted-foreground">{formatMoney(row.cost)}</span>,
    sortable: true,
    sortValue: (row) => row.cost,
  },
  {
    key: "margin",
    header: "Margen",
    cell: (row) => (
      <span className={`text-xs font-medium ${row.margin >= 50 ? "text-emerald-400" : row.margin >= 30 ? "text-yellow-400" : "text-red-400"}`}>
        {row.margin}%
      </span>
    ),
    sortable: true,
    sortValue: (row) => row.margin,
  },
  {
    key: "stock",
    header: "Stock",
    cell: (row) => (
      <div className="flex items-center gap-2">
        <span>{row.stock}</span>
        <StockSemaphore stock={row.stock} minStock={row.minStock} size="sm" />
      </div>
    ),
    sortable: true,
    sortValue: (row) => row.stock,
  },
]

export default function ProductosPage() {
  const { products, deleteProduct, refreshData } = useData()
  const { user } = useAuth()
  const [open, setOpen] = useState(false)
  const [editingProduct, setEditingProduct] = useState<Product | undefined>()
  const supabase = createClient()

  useEffect(() => {
    const channel = supabase
      .channel('productos-realtime')
      .on('postgres_changes', 
        { event: '*', schema: 'public', table: 'products' }, 
        () => {
          refreshData()
        }
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [supabase, refreshData])

  const isAtLimit = user?.plan === "free" && products.length >= MAX_PRODUCTS_FREE

  const handleEdit = (product: Product) => {
    setEditingProduct(product)
    setOpen(true)
  }

  const handleAdd = () => {
    setEditingProduct(undefined)
    setOpen(true)
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Productos</h1>
          <p className="text-sm text-muted-foreground mt-1">
            {products.length} productos
            {user?.plan === "free" && ` / ${MAX_PRODUCTS_FREE} (plan gratis)`}
          </p>
        </div>
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
            Llegaste al limite de {MAX_PRODUCTS_FREE} productos del plan gratuito. Actualiza a Pro para tener productos ilimitados.
          </p>
        </div>
      )}

      <DataTable
        data={products}
        columns={columns}
        searchPlaceholder="Buscar productos..."
        searchKey={(row) => `${row.name} ${row.category} ${row.barcode || ""}`}
        onAdd={isAtLimit ? undefined : handleAdd}
        addLabel="Nuevo producto"
        onEdit={handleEdit}
        onDelete={deleteProduct}
        getId={(row) => row.id}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              {editingProduct ? "Editar producto" : "Nuevo producto"}
            </DialogTitle>
            <DialogDescription className="sr-only">
              Formulario del producto
            </DialogDescription>
          </DialogHeader>
          <ProductForm
            initialData={editingProduct}
            onSuccess={() => {
              setOpen(false)
              setEditingProduct(undefined)
            }}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
