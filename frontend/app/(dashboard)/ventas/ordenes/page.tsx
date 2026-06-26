"use client"

/**
 * facturar-venta-afip — Página de listado de SalesOrders (C-29).
 *
 * Muestra las órdenes de venta confirmadas con:
 *   - Estado de la venta (confirmed / draft / canceled)
 *   - FiscalDocumentBadge con Realtime si ya tiene comprobante
 *   - EmitInvoiceButton si está confirmada y SIN comprobante
 *
 * Design ref: D1 (endpoint dedicado), D4 (async), D6 (idempotencia).
 */

import { useSalesOrders } from "@/hooks/data/use-sales-orders"
import { useFiscalProfile } from "@/hooks/data/use-fiscal-profile"
import { usePointsOfSale } from "@/hooks/data/use-points-of-sale"
import { EmitInvoiceButton } from "@/components/fiscal/EmitInvoiceButton"
import { FiscalDocumentBadge } from "@/components/fiscal/FiscalDocumentBadge"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { formatMoney } from "@/lib/format"
import Link from "next/link"
import { ShoppingBag, Plus } from "lucide-react"
import type { FiscalDocumentStatus } from "@/components/fiscal/FiscalDocumentBadge"

// ── Types ──────────────────────────────────────────────────────────────────────

const STATUS_LABEL: Record<string, string> = {
  confirmed: "Confirmada",
  draft:     "Borrador",
  canceled:  "Cancelada",
}

const STATUS_CLASS: Record<string, string> = {
  confirmed: "bg-green-500/10 text-green-600 border-green-500/30",
  draft:     "bg-muted text-muted-foreground",
  canceled:  "bg-red-500/10 text-red-500 border-red-500/30",
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function SalesOrdersPage() {
  const { data: orders, isLoading, error } = useSalesOrders()
  const { profile: fiscalProfile } = useFiscalProfile()
  const { pointsOfSale } = usePointsOfSale()

  // Seleccionar el PV por defecto si solo hay uno activo
  const activePVs = (pointsOfSale ?? []).filter((pv) => pv.isActive)
  const defaultPvId = activePVs.length === 1 ? activePVs[0]?.id : undefined

  // ── Loading / error ──────────────────────────────────────────────────────

  if (isLoading) {
    return (
      <div className="flex flex-col gap-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-bold text-foreground tracking-tight">Órdenes de Venta</h1>
            <p className="text-sm text-muted-foreground mt-1">Confirmadas + en borrador</p>
          </div>
        </div>
        <div className="flex flex-col gap-2">
          {[1, 2, 3].map((i) => (
            <Skeleton key={i} className="h-16 w-full rounded-lg" />
          ))}
        </div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="flex flex-col gap-6">
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Órdenes de Venta</h1>
        <p className="text-sm text-red-500">Error al cargar las órdenes: {error.message}</p>
      </div>
    )
  }

  const sortedOrders = [...(orders ?? [])].sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
  )

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="flex flex-col gap-6">
      {/* Header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Órdenes de Venta</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Ventas confirmadas — facturá con un clic
          </p>
        </div>
        <Button asChild variant="outline" size="sm">
          <Link href="/ventas/pos">
            <Plus className="h-4 w-4 mr-1" />
            Nueva venta POS
          </Link>
        </Button>
      </div>

      {/* Empty state */}
      {sortedOrders.length === 0 && (
        <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border p-10 text-center">
          <ShoppingBag className="h-8 w-8 text-muted-foreground/40" />
          <div>
            <p className="text-sm font-medium text-foreground">Sin órdenes de venta aún</p>
            <p className="text-xs text-muted-foreground mt-1">
              Creá una venta rápida desde el POS para empezar.
            </p>
          </div>
          <Button asChild size="sm" variant="outline">
            <Link href="/ventas/pos">Ir al POS</Link>
          </Button>
        </div>
      )}

      {/* Orders list */}
      {sortedOrders.length > 0 && (
        <div className="flex flex-col gap-2">
          {sortedOrders.map((order) => {
            const createdAt = new Date(order.created_at)
            const dateLabel = createdAt.toLocaleDateString("es-AR", {
              day: "2-digit",
              month: "short",
              year: "numeric",
            })

            return (
              <div
                key={order.id}
                className="flex items-center gap-3 rounded-lg border border-border bg-card px-4 py-3"
              >
                {/* Status badge */}
                <Badge
                  variant="outline"
                  className={`shrink-0 text-xs ${STATUS_CLASS[order.status] ?? ""}`}
                >
                  {STATUS_LABEL[order.status] ?? order.status}
                </Badge>

                {/* Order info */}
                <div className="flex flex-col min-w-0 flex-1">
                  <span className="text-sm font-medium tabular-nums">
                    {formatMoney(Number(order.total), "ARS")}
                  </span>
                  <span className="text-xs text-muted-foreground font-mono">
                    {order.id.slice(0, 8)}… · {dateLabel}
                  </span>
                </div>

                {/* Fiscal section: badge OR emit button */}
                <div className="shrink-0 flex items-center">
                  {order.fiscal_document_id ? (
                    <FiscalDocumentBadge
                      documentId={order.fiscal_document_id}
                      initialStatus={"pending_cae" as FiscalDocumentStatus}
                      verbose
                    />
                  ) : (
                    <EmitInvoiceButton
                      salesOrderId={order.id}
                      salesOrderStatus={order.status}
                      fiscalDocumentId={order.fiscal_document_id}
                      ivaConditionEmisor={fiscalProfile?.ivaCondition ?? null}
                      pointOfSaleId={defaultPvId ?? null}
                    />
                  )}
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
