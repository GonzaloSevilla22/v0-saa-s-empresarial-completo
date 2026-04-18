"use client"

import { useEffect } from "react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { StockSemaphore } from "@/components/stock/stock-semaphore"
import { useAuth } from "@/contexts/auth-context"
import { BarChart3, AlertTriangle } from "lucide-react"
import Link from "next/link"
import { Button } from "@/components/ui/button"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { DataTable, type Column } from "@/components/data-table/data-table"
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
    cell: (row) => <span className="font-medium">{row.stock}</span>,
    sortable: true,
    sortValue: (row) => row.stock,
  },
  {
    key: "minStock",
    header: "Stock minimo",
    cell: (row) => row.minStock,
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
        <span className="text-primary font-medium">{toOrder} unidades</span>
      ) : (
        <span className="text-muted-foreground">-</span>
      )
    },
  },
]

export default function StockPage() {
  const { products, getLowStockProducts, refreshData } = useData()
  const lowStock = getLowStockProducts()
  const { isAdmin } = useAuth()
  const supabase = createClient()

  useEffect(() => {
    const channel = supabase
      .channel('stock-realtime')
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

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Stock</h1>
          <p className="text-sm text-muted-foreground mt-1">Control de inventario y reposicion</p>
        </div>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="stock"
          title="Analíticas de Stock"
          subtitle="Control de inventario y valuación"
        />
      )}

      {lowStock.length > 0 && (
        <Card className="border-red-500/30 bg-red-500/5">
          <CardHeader className="pb-2">
            <CardTitle className="flex items-center gap-2 text-sm text-red-400">
              <AlertTriangle className="h-4 w-4" />
              Productos en alerta ({lowStock.length})
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="flex flex-wrap gap-2">
              {lowStock.map((p) => (
                <div key={p.id} className="flex items-center gap-2 rounded-md border border-red-500/20 bg-red-500/10 px-3 py-1.5">
                  <div className="h-2 w-2 rounded-full bg-red-500" />
                  <span className="text-xs text-red-300">{p.name}</span>
                  <span className="text-xs text-red-400 font-medium">({p.stock}/{p.minStock})</span>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      )}

      <DataTable
        data={products}
        columns={columns}
        searchPlaceholder="Buscar productos..."
        searchKey={(row) => `${row.name} ${row.category}`}
        getId={(row) => row.id}
        exportColumns={[
          { key: "name",     header: "Producto"      },
          { key: "category", header: "Categoría"     },
          { key: "stock",    header: "Stock actual"  },
          { key: "minStock", header: "Stock mínimo"  },
        ]}
        exportFilename="stock"
        importColumnMap={[
          { csvHeader: "Producto",     key: "name"     },
          { csvHeader: "Categoría",    key: "category" },
          { csvHeader: "Stock actual", key: "stock"    },
          { csvHeader: "Stock mínimo", key: "minStock" },
        ]}
        onImport={(rows) => {
          console.log("Importando stock:", rows)
        }}
      />
    </div>
  )
}
