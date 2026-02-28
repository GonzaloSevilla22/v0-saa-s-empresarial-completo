"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { formatMoney, formatDate } from "@/lib/format"
import type { Purchase } from "@/lib/types"

const columns: Column<Purchase>[] = [
  {
    key: "date",
    header: "Fecha",
    cell: (row) => formatDate(row.date),
    sortable: true,
    sortValue: (row) => row.date,
  },
  {
    key: "product",
    header: "Producto",
    cell: (row) => <span className="font-medium">{row.productName}</span>,
  },
  {
    key: "quantity",
    header: "Cantidad",
    cell: (row) => row.quantity,
    sortable: true,
    sortValue: (row) => row.quantity,
  },
  {
    key: "unitCost",
    header: "Costo unit.",
    cell: (row) => formatMoney(row.unitCost),
  },
  {
    key: "total",
    header: "Total",
    cell: (row) => <span className="font-medium text-cyan-400">{formatMoney(row.total)}</span>,
    sortable: true,
    sortValue: (row) => row.total,
  },
]

export default function ComprasPage() {
  const { purchases, deletePurchase } = useData()
  const [open, setOpen] = useState(false)

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Compras</h1>
        <p className="text-sm text-muted-foreground mt-1">Gestión de compras a proveedores</p>
      </div>

      <DataTable
        data={purchases}
        columns={columns}
        searchPlaceholder="Buscar por producto..."
        searchKey={(row) => row.productName}
        onAdd={() => setOpen(true)}
        addLabel="Nueva compra"
        onDelete={deletePurchase}
        getId={(row) => row.id}
        dateKey={(row) => row.date}
        exportColumns={[
          { key: "date", header: "Fecha" },
          { key: "productName", header: "Producto" },
          { key: "quantity", header: "Cantidad" },
          { key: "unitCost", header: "Costo Unitario" },
          { key: "total", header: "Total" },
        ]}
        exportFilename="compras"
        importColumnMap={[
          { csvHeader: "Producto", key: "productName" },
          { csvHeader: "Cantidad", key: "quantity" },
          { csvHeader: "Costo Unitario", key: "unitCost" },
          { csvHeader: "Fecha", key: "date" },
        ]}
        onImport={(rows) => {
          console.log("Importing purchases:", rows)
        }}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nueva compra</DialogTitle>
          </DialogHeader>
          <PurchaseForm onSuccess={() => setOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  )
}
