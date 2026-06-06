import { format } from "date-fns"
import { es } from "date-fns/locale"
import { PLAN_DISPLAY_NAMES } from "@/lib/plan-utils"
import type { Plan } from "@/lib/types"

interface BillingEvent {
  id: string
  event_type: string
  from_plan: Plan | null
  to_plan: Plan | null
  amount: number | null
  created_at: string
}

interface BillingHistoryProps {
  events: BillingEvent[]
}

const EVENT_LABELS: Record<string, string> = {
  plan_upgraded: "Upgrade de plan",
  plan_cancelled: "Plan cancelado",
  cancellation_requested: "Cancelación solicitada",
  trial_expired: "Trial vencido",
  migration_backfill: "Migración inicial",
}

/**
 * Server Component — renders the billing history table.
 * Receives pre-fetched billing_events from the parent page.
 */
export function BillingHistory({ events }: BillingHistoryProps) {
  if (events.length === 0) {
    return (
      <div className="rounded-lg border border-border bg-muted/30 p-8 text-center">
        <p className="text-sm text-muted-foreground">No hay eventos de facturación todavía.</p>
      </div>
    )
  }

  return (
    <div className="overflow-x-auto rounded-lg border border-border">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-border bg-muted/50">
            <th className="px-4 py-3 text-left font-medium text-muted-foreground">Fecha</th>
            <th className="px-4 py-3 text-left font-medium text-muted-foreground">Evento</th>
            <th className="px-4 py-3 text-left font-medium text-muted-foreground">De</th>
            <th className="px-4 py-3 text-left font-medium text-muted-foreground">A</th>
            <th className="px-4 py-3 text-right font-medium text-muted-foreground">Monto</th>
          </tr>
        </thead>
        <tbody>
          {events.map((event) => (
            <tr key={event.id} className="border-b border-border last:border-0 hover:bg-muted/30 transition-colors">
              <td className="px-4 py-3 text-foreground whitespace-nowrap">
                {format(new Date(event.created_at), "dd/MM/yyyy HH:mm", { locale: es })}
              </td>
              <td className="px-4 py-3 text-foreground">
                {EVENT_LABELS[event.event_type] ?? event.event_type}
              </td>
              <td className="px-4 py-3 text-muted-foreground">
                {event.from_plan ? PLAN_DISPLAY_NAMES[event.from_plan] : "—"}
              </td>
              <td className="px-4 py-3 text-muted-foreground">
                {event.to_plan ? PLAN_DISPLAY_NAMES[event.to_plan] : "—"}
              </td>
              <td className="px-4 py-3 text-right text-foreground">
                {event.amount != null ? `$${Number(event.amount).toLocaleString("es-AR")}` : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
