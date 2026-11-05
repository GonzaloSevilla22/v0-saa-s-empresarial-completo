"use client"

/**
 * Historial de compras del cliente — client-purchase-history §"Historial de
 * compras del cliente": una fila por operación de venta, fecha descendente.
 */

import Link from "next/link"
import { ChevronRight, PackageOpen } from "lucide-react"
import { formatBusinessDate } from "@/lib/sales-statistics"
import { PaginationBar } from "@/components/ui/pagination-bar"
import type { PaginationMeta, PageSizeOption } from "@/lib/pagination-utils"
import type { ClientPurchase } from "@/hooks/data/use-client-activity"

const currencyFormatter = new Intl.NumberFormat("es-AR", {
  style: "currency",
  currency: "ARS",
  maximumFractionDigits: 0,
})

interface ClientPurchaseHistoryProps {
  purchases:    ClientPurchase[]
  meta:         PaginationMeta
  isLoading:    boolean
  error:        string | null
  onPageChange: (page: number) => void
  onSizeChange: (size: PageSizeOption) => void
}

export function ClientPurchaseHistory({
  purchases, meta, isLoading, error, onPageChange, onSizeChange,
}: ClientPurchaseHistoryProps) {
  return (
    <div className="flex flex-col gap-4">
      <h2 className="text-sm font-semibold text-foreground">Historial de compras</h2>

      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error}
        </div>
      )}

      <div className="rounded-lg border border-border overflow-hidden overflow-x-auto">
        <div className="min-w-[420px] sm:min-w-0">
          <div className="grid grid-cols-[1fr_100px_120px_16px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
            <span>Fecha</span><span>Ítems</span><span>Total</span><span aria-hidden />
          </div>

          {isLoading && purchases.length === 0 && (
            <div data-testid="client-purchase-history-loading" className="flex flex-col">
              {Array.from({ length: 4 }).map((_, i) => (
                <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                  <div className="grid grid-cols-[1fr_100px_120px_16px] gap-3 items-center">
                    {Array.from({ length: 3 }).map((_, j) => (
                      <div key={j} className="h-3.5 rounded bg-accent animate-pulse" />
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )}

          {!isLoading && !error && purchases.length === 0 && (
            <div className="flex flex-col items-center gap-2 py-14 text-center text-muted-foreground">
              <PackageOpen className="h-8 w-8 opacity-30" />
              <p className="text-sm">Este cliente todavía no compró.</p>
            </div>
          )}

          {purchases.map((p) => {
            // `operationDate` es una fecha de negocio "YYYY-MM-DD": se muestra
            // tal cual, sin pasar por `Date` (que la correría un día en UTC-3).
            const date = formatBusinessDate(p.operationDate)
            return (
              <Link
                key={p.operationId}
                href={`/ventas?operation_id=${encodeURIComponent(p.operationId)}`}
                aria-label={`Ver venta del ${date}`}
                className="grid grid-cols-[1fr_100px_120px_16px] gap-3 px-4 py-3 items-center border-t border-border/50 first:border-t-0 transition-colors hover:bg-accent/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset"
              >
                <span className="text-sm text-foreground">{date}</span>
                <span className="text-sm text-muted-foreground tabular-nums">{p.itemCount}</span>
                <span className="text-sm font-medium text-foreground tabular-nums">
                  {currencyFormatter.format(p.total)}
                </span>
                <ChevronRight aria-hidden className="h-4 w-4 text-muted-foreground" />
              </Link>
            )
          })}
        </div>
      </div>

      <PaginationBar
        meta={meta}
        onPageChange={onPageChange}
        onSizeChange={onSizeChange}
        loading={isLoading}
        label="compras"
      />
    </div>
  )
}
