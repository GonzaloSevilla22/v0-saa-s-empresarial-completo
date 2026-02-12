"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { SaleForm } from "@/components/forms/sale-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import type { Sale } from "@/lib/types"

const columns: Column<Sale>[] = [
  {
    key: "date",
    header: "Fecha",
    cell: (row) => new Date(row.date + "T12:00:00").toLocaleDateString("es-AR"),
    sortable: true,
    sortValue: (row) => row.date,
  },
  {
    key: "product",
    header: "Producto",
    cell: (row) => <span className="font-medium">{row.productName}</span>,
  },
  {
    key: "client",
    header: "Cliente",
    cell: (row) => row.clientName,
  },
  {
    key: "quantity",
    header: "Cantidad",
    cell: (row) => row.quantity,
    sortable: true,
    sortValue: (row) => row.quantity,
  },
  {
    key: "unitPrice",
    header: "Precio unit.",
    cell: (row) => `$${row.unitPrice}`,
  },
  {
    key: "total",
    header: "Total",
    cell: (row) => <span className="font-medium text-emerald-400">${row.total}</span>,
    sortable: true,
    sortValue: (row) => row.total,
  },
]

export default function VentasPage() {
  const { sales, deleteSale } = useData()
  const [open, setOpen] = useState(false)

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Ventas</h1>
        <p className="text-sm text-muted-foreground mt-1">Gestion de todas tus ventas</p>
      </div>

      <DataTable
        data={sales}
        columns={columns}
        searchPlaceholder="Buscar por producto o cliente..."
        searchKey={(row) => `${row.productName} ${row.clientName}`}
        onAdd={() => setOpen(true)}
        addLabel="Nueva venta"
        onDelete={deleteSale}
        getId={(row) => row.id}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nueva venta</DialogTitle>
          </DialogHeader>
          <SaleForm onSuccess={() => setOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  )
}
