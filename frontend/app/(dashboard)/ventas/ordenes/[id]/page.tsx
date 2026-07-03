/**
 * v3-document-status-history (task 6.3) — detalle de la orden de venta.
 *
 * Server Component: lee la orden (RLS sales_orders_select) y muestra la línea
 * de tiempo de estados de la venta y, si hay comprobante, la del documento
 * fiscal. La data del timeline se colocaliza server-side (D8).
 */
import Link from "next/link"
import { notFound, redirect } from "next/navigation"
import { ArrowLeft } from "lucide-react"

import { DocumentTimeline } from "@/components/documentos/DocumentTimeline"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { getStatusLabel } from "@/lib/document-timeline-utils"
import { formatMoney } from "@/lib/format"
import { createClient } from "@/lib/supabase/server"

export const metadata = {
  title: "Detalle de orden — Aliadata",
}

interface SalesOrderRow {
  id: string
  status: string
  payment_method: string | null
  total: number | string
  created_at: string
  fiscal_document_id: string | null
}

const STATUS_CLASS: Record<string, string> = {
  confirmed: "bg-green-500/10 text-green-600 border-green-500/30",
  draft: "bg-muted text-muted-foreground",
  canceled: "bg-red-500/10 text-red-500 border-red-500/30",
}

export default async function SalesOrderDetailPage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  const { id } = await params
  const supabase = createClient()

  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser()
  if (authError || !user) {
    redirect("/login")
  }

  const { data: order } = (await supabase
    .from("sales_orders")
    .select("id, status, payment_method, total, created_at, fiscal_document_id")
    .eq("id", id)
    .maybeSingle()) as { data: SalesOrderRow | null }

  if (!order) {
    notFound()
  }

  const createdAt = new Date(order.created_at)

  return (
    <div className="flex flex-col gap-6">
      {/* Header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            Orden de venta
          </h1>
          <p className="text-sm text-muted-foreground mt-1 font-mono">
            {order.id.slice(0, 8)}… ·{" "}
            {createdAt.toLocaleDateString("es-AR", {
              day: "2-digit",
              month: "short",
              year: "numeric",
            })}
          </p>
        </div>
        <Button asChild variant="outline" size="sm">
          <Link href="/ventas/ordenes">
            <ArrowLeft className="h-4 w-4 mr-1" />
            Volver
          </Link>
        </Button>
      </div>

      {/* Resumen */}
      <div className="flex items-center gap-3 rounded-lg border border-border bg-card px-4 py-3">
        <Badge
          variant="outline"
          className={`shrink-0 text-xs ${STATUS_CLASS[order.status] ?? ""}`}
        >
          {getStatusLabel("sales_order", order.status)}
        </Badge>
        <span className="text-sm font-medium tabular-nums">
          {formatMoney(Number(order.total), "ARS")}
        </span>
        {order.payment_method && (
          <span className="text-xs text-muted-foreground">
            {order.payment_method === "cash" ? "Efectivo" : "Otro medio"}
          </span>
        )}
      </div>

      {/* Línea de tiempo de la orden */}
      <DocumentTimeline
        documentType="sales_order"
        documentId={order.id}
        title="Historial de la orden"
      />

      {/* Línea de tiempo del comprobante fiscal, si existe */}
      {order.fiscal_document_id && (
        <DocumentTimeline
          documentType="fiscal_document"
          documentId={order.fiscal_document_id}
          title="Historial del comprobante"
        />
      )}
    </div>
  )
}
