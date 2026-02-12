"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { ClientForm } from "@/components/forms/client-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Badge } from "@/components/ui/badge"
import type { Client } from "@/lib/types"

const statusColors: Record<string, string> = {
  activo: "bg-emerald-500/20 text-emerald-400 border-emerald-500/30",
  inactivo: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  perdido: "bg-red-500/20 text-red-400 border-red-500/30",
}

const columns: Column<Client>[] = [
  {
    key: "name",
    header: "Nombre",
    cell: (row) => <span className="font-medium">{row.name}</span>,
  },
  {
    key: "email",
    header: "Email",
    cell: (row) => <span className="text-muted-foreground">{row.email}</span>,
  },
  {
    key: "phone",
    header: "Telefono",
    cell: (row) => <span className="text-muted-foreground">{row.phone}</span>,
  },
  {
    key: "status",
    header: "Estado",
    cell: (row) => (
      <Badge variant="outline" className={`text-xs capitalize ${statusColors[row.status]}`}>
        {row.status}
      </Badge>
    ),
  },
  {
    key: "lastPurchase",
    header: "Ultima compra",
    cell: (row) => new Date(row.lastPurchase + "T12:00:00").toLocaleDateString("es-AR"),
    sortable: true,
    sortValue: (row) => row.lastPurchase,
  },
  {
    key: "totalSpent",
    header: "Total gastado",
    cell: (row) => <span className="font-medium text-primary">${row.totalSpent.toLocaleString()}</span>,
    sortable: true,
    sortValue: (row) => row.totalSpent,
  },
]

export default function ClientesPage() {
  const { clients, deleteClient } = useData()
  const [open, setOpen] = useState(false)

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Clientes</h1>
        <p className="text-sm text-muted-foreground mt-1">{clients.length} clientes registrados</p>
      </div>

      <DataTable
        data={clients}
        columns={columns}
        searchPlaceholder="Buscar clientes..."
        searchKey={(row) => `${row.name} ${row.email}`}
        onAdd={() => setOpen(true)}
        addLabel="Nuevo cliente"
        onDelete={deleteClient}
        getId={(row) => row.id}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nuevo cliente</DialogTitle>
          </DialogHeader>
          <ClientForm onSuccess={() => setOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  )
}
