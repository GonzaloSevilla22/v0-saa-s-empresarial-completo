"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { ProductForm } from "@/components/forms/product-form"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Badge } from "@/components/ui/badge"
import { MAX_PRODUCTS_FREE } from "@/lib/constants"
import type { Product } from "@/lib/types"

const columns: Column<Product>[] = [
  {
    key: "name",
    header: "Nombre",
    cell: (row) => <span className="font-medium">{row.name}</span>,
  },
  {
    key: "category",
    header: "Categoria",
    cell: (row) => (
      <Badge variant="outline" className="text-xs border-border text-muted-foreground">{row.category}</Badge>
    ),
  },
  {
    key: "cost",
    header: "Costo",
    cell: (row) => `$${row.cost}`,
    sortable: true,
    sortValue: (row) => row.cost,
  },
  {
    key: "price",
    header: "Precio",
    cell: (row) => `$${row.price}`,
    sortable: true,
    sortValue: (row) => row.price,
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
  const { products, deleteProduct } = useData()
  const { user } = useAuth()
  const [open, setOpen] = useState(false)

  const isAtLimit = user?.plan === "free" && products.length >= MAX_PRODUCTS_FREE

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Productos</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {products.length} productos
          {user?.plan === "free" && ` / ${MAX_PRODUCTS_FREE} (plan gratis)`}
        </p>
      </div>

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
        searchKey={(row) => `${row.name} ${row.category}`}
        onAdd={isAtLimit ? undefined : () => setOpen(true)}
        addLabel="Nuevo producto"
        onDelete={deleteProduct}
        getId={(row) => row.id}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nuevo producto</DialogTitle>
          </DialogHeader>
          <ProductForm onSuccess={() => setOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  )
}
