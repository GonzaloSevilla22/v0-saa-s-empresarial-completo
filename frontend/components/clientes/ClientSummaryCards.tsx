"use client"

/**
 * Resumen acumulado del cliente — client-purchase-history §"Resumen
 * acumulado" + §"El total comprado es bruto y no descuenta notas de
 * crédito". Se calcula sobre TODAS las operaciones, independiente de la
 * página del historial visible — el caller (page.tsx) lo pide una sola vez.
 */

import Link from "next/link"
import { CreditCard } from "lucide-react"
import type { ClientPurchaseSummary } from "@/hooks/data/use-client-activity"

const currencyFormatter = new Intl.NumberFormat("es-AR", {
  style: "currency",
  currency: "ARS",
  maximumFractionDigits: 0,
})

function formatLastPurchase(dateStr: string | null, days: number | null): string {
  if (!dateStr || days == null) return "—"
  if (days === 0) return "Hoy"
  if (days === 1) return "Hace 1 día"
  return `Hace ${days} días`
}

interface ClientSummaryCardsProps {
  clientId:  string
  summary:   ClientPurchaseSummary | null
  isLoading: boolean
}

export function ClientSummaryCards({ clientId, summary, isLoading }: ClientSummaryCardsProps) {
  if (isLoading) {
    return (
      <div
        data-testid="client-summary-loading"
        className="grid grid-cols-1 sm:grid-cols-3 gap-3"
      >
        {Array.from({ length: 3 }).map((_, i) => (
          <div key={i} className="h-20 rounded-lg border border-border bg-accent/30 animate-pulse" />
        ))}
      </div>
    )
  }

  // Sin datos y sin estar cargando (p. ej. la carga falló): el error ya se
  // comunica en ClientPurchaseHistory — acá no hay nada honesto que mostrar.
  if (!summary) {
    return null
  }

  if (summary.purchaseCount === 0) {
    return (
      <div className="rounded-lg border border-border bg-accent/20 px-4 py-6 text-center text-sm text-muted-foreground">
        Este cliente todavía no compró.
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div className="rounded-lg border border-border bg-card px-4 py-3">
          <p className="text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
            Cantidad de compras
          </p>
          <p className="text-2xl font-bold text-foreground tabular-nums mt-1">{summary.purchaseCount}</p>
        </div>

        <div className="rounded-lg border border-border bg-card px-4 py-3">
          <p className="text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
            Total comprado
          </p>
          <p className="text-2xl font-bold text-foreground tabular-nums mt-1">
            {currencyFormatter.format(summary.totalSpent)}
          </p>
          <p className="text-[11px] text-muted-foreground mt-0.5">
            No descuenta notas de crédito.
          </p>
        </div>

        <div className="rounded-lg border border-border bg-card px-4 py-3">
          <p className="text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
            Última compra
          </p>
          <p className="text-2xl font-bold text-foreground tabular-nums mt-1">
            {formatLastPurchase(summary.lastPurchaseDate, summary.daysSinceLastPurchase)}
          </p>
        </div>
      </div>

      {/* client-purchase-history §"Acceso a la posición financiera" */}
      <Link
        href={`/clientes/${clientId}/cuenta`}
        className="inline-flex items-center gap-1.5 self-start text-xs text-primary hover:underline"
      >
        <CreditCard className="h-3.5 w-3.5" />
        Ver cuenta corriente (saldo y notas de crédito)
      </Link>
    </div>
  )
}
