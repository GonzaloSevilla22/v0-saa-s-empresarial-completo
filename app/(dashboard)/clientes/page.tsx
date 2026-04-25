"use client"

import { useState, useEffect } from "react"
import { useData } from "@/contexts/data-context"
import { createClient } from "@/lib/supabase/client"
import { DataTable, type Column } from "@/components/data-table/data-table"
import { ClientForm } from "@/components/forms/client-form"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { useAuth } from "@/contexts/auth-context"
import { BarChart3 } from "lucide-react"
import Link from "next/link"
import { ModuleMetricsWrapper } from "@/components/admin/ModuleMetricsWrapper"
import { Badge } from "@/components/ui/badge"
import { formatMoney } from "@/lib/format"
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
    cell: (row) => (
      <div className="flex flex-col">
        <span className="font-medium">{row.name}</span>
        <span className="text-[10px] text-muted-foreground">{row.email}</span>
      </div>
    ),
  },
  {
    key: "category",
    header: "Categoría",
    cell: (row) => (
      <span className="text-xs text-muted-foreground italic">{row.category || "-"}</span>
    ),
  },
  {
    key: "email",
    header: "Email",
    cell: (row) => <span className="text-muted-foreground">{row.email}</span>,
  },
  {
    key: "phone",
    header: "Teléfono",
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
    cell: (row) => <span className="font-medium text-primary">{formatMoney(row.totalSpent)}</span>,
    sortable: true,
    sortValue: (row) => row.totalSpent,
  },
]

export default function ClientesPage() {
  const { clients, deleteClient, refreshData } = useData()
  const [open, setOpen] = useState(false)
  const [editingClient, setEditingClient] = useState<Client | undefined>()
  const { isAdmin } = useAuth()
  const supabase = createClient()

  useEffect(() => {
    const channel = supabase
      .channel('clientes-realtime')
      .on('postgres_changes', 
        { event: '*', schema: 'public', table: 'clients' }, 
        () => {
          refreshData()
        }
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [supabase, refreshData])

  const handleEdit = (client: Client) => {
    setEditingClient(client)
    setOpen(true)
  }

  const handleAdd = () => {
    setEditingClient(undefined)
    setOpen(true)
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Clientes</h1>
          <p className="text-sm text-muted-foreground mt-1">{clients.length} clientes registrados</p>
        </div>
      </div>

      {isAdmin && (
        <ModuleMetricsWrapper
          moduleType="clientes"
          title="Analíticas de Clientes"
          subtitle="Segmentación y retención"
        />
      )}

      <DataTable
        data={clients}
        columns={columns}
        searchPlaceholder="Buscar clientes..."
        searchKey={(row) => `${row.name} ${row.email}`}
        onAdd={handleAdd}
        addLabel="Nuevo cliente"
        onEdit={handleEdit}
        onDelete={deleteClient}
        getId={(row) => row.id}
        mobileCard={(row) => (
          <div className="flex flex-col gap-2">
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="font-medium text-sm text-foreground truncate">{row.name}</p>
                <p className="text-xs text-muted-foreground truncate">{row.email}</p>
              </div>
              <Badge variant="outline" className={`text-xs capitalize shrink-0 ${statusColors[row.status]}`}>
                {row.status}
              </Badge>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-xs text-muted-foreground italic">{row.category || "Sin categoría"}</span>
              <span className="text-sm font-semibold text-primary">{formatMoney(row.totalSpent)}</span>
            </div>
            <p className="text-xs text-muted-foreground">
              Última compra: {new Date(row.lastPurchase + "T12:00:00").toLocaleDateString("es-AR")}
            </p>
          </div>
        )}
        exportColumns={[
          { key: "name",        header: "Nombre"         },
          { key: "email",       header: "Email"          },
          { key: "phone",       header: "Teléfono"       },
          { key: "status",      header: "Estado"         },
          { key: "category",   header: "Categoría"      },
          { key: "totalSpent",  header: "Total gastado"  },
          { key: "lastPurchase",header: "Última compra"  },
        ]}
        exportFilename="clientes"
        importColumnMap={[
          { csvHeader: "Nombre",   key: "name"   },
          { csvHeader: "Email",    key: "email"  },
          { csvHeader: "Teléfono", key: "phone"  },
          { csvHeader: "Estado",   key: "status" },
        ]}
        onImport={(rows) => {
          console.log("Importando clientes:", rows)
        }}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              {editingClient ? "Editar cliente" : "Nuevo cliente"}
            </DialogTitle>
          </DialogHeader>
          <ClientForm
            initialData={editingClient}
            onSuccess={() => {
              setOpen(false)
              setEditingClient(undefined)
            }}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
