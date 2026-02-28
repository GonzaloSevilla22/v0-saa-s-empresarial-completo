"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { SaleForm } from "@/components/forms/sale-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { formatMoney, formatDate } from "@/lib/format"
import type { Sale } from "@/lib/types"

const columns: Column<Sale>[] = [
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
    cell: (row) => formatMoney(row.unitPrice),
  },
  {
    key: "total",
    header: "Total",
    cell: (row) => <span className="font-medium text-emerald-400">{formatMoney(row.total)}</span>,
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
        <p className="text-sm text-muted-foreground mt-1">Gestión de todas tus ventas</p>
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
        dateKey={(row) => row.date}
        exportColumns={[
          { key: "date", header: "Fecha" },
          { key: "productName", header: "Producto" },
          { key: "clientName", header: "Cliente" },
          { key: "quantity", header: "Cantidad" },
          { key: "unitPrice", header: "Precio Unitario" },
          { key: "total", header: "Total" },
        ]}
        exportFilename="ventas"
        importColumnMap={[
          { csvHeader: "Producto", key: "productName" },
          { csvHeader: "Cliente", key: "clientName" },
          { csvHeader: "Cantidad", key: "quantity" },
          { csvHeader: "Precio Unitario", key: "unitPrice" },
          { csvHeader: "Fecha", key: "date" },
        ]}
        onImport={(rows) => {
          console.log("Importing sales:", rows)
          // Here we would call a bulk create service
        }}
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
