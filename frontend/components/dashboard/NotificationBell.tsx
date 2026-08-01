"use client"

import { useMemo, useState } from "react"
import { Bell } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { createClient } from "@/lib/supabase/client"
import { useNotifications, markNotificationRead } from "@/hooks/data/use-notifications"
import type { Notification, NotificationSeverity } from "@/lib/types"

const SEVERITY_DOT_CLASS: Record<NotificationSeverity, string> = {
  info: "bg-blue-500",
  warning: "bg-warning",
  urgent: "bg-destructive",
}

const TYPE_LABELS: Record<Notification["type"], string> = {
  CashSessionClosed: "Cierre de caja con diferencia",
  StockBelowMinimum: "Stock por debajo del mínimo",
  FiscalDocumentRejected: "Comprobante fiscal rechazado",
  QuoteAccepted: "Presupuesto aceptado",
  TransferDispatched: "Transferencia despachada",
  // billing-pro-trial (D9): aviso de excedente de plan.
  PlanLimitExceeded: "Límite de plan excedido",
  // mp-real-subscriptions (D11): dunning de suscripción.
  SubscriptionPaymentFailed: "Cobro de suscripción rechazado",
  SubscriptionExpiringSoon: "Suscripción por vencer",
}

/**
 * v3-notifications-realtime (D7 design.md): campana de notificaciones en el
 * header. Badge de no-leídas + dropdown con las últimas N + marcar-como-leída.
 * Alimentada por useNotifications (React Query + Supabase Realtime
 * postgres_changes) — sin polling.
 */
export function NotificationBell() {
  const { notifications, unreadCount, isLoading } = useNotifications()
  const supabase = useMemo(() => createClient(), [])
  const [pendingIds, setPendingIds] = useState<Set<string>>(new Set())

  async function handleMarkRead(notification: Notification) {
    if (notification.read || pendingIds.has(notification.id)) return

    setPendingIds((prev) => new Set(prev).add(notification.id))
    try {
      await markNotificationRead(supabase, notification.id)
    } catch {
      // best-effort: si falla, el badge simplemente no baja hasta el próximo resync
    } finally {
      setPendingIds((prev) => {
        const next = new Set(prev)
        next.delete(notification.id)
        return next
      })
    }
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="relative h-9 w-9 text-muted-foreground hover:text-foreground"
        >
          <Bell className="h-[1.2rem] w-[1.2rem]" />
          {unreadCount > 0 && (
            <Badge
              variant="destructive"
              className="absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] leading-none"
            >
              {unreadCount > 9 ? "9+" : unreadCount}
            </Badge>
          )}
          <span className="sr-only">Notificaciones</span>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-80 bg-popover border-border">
        {isLoading && (
          <DropdownMenuItem disabled>Cargando notificaciones…</DropdownMenuItem>
        )}
        {!isLoading && notifications.length === 0 && (
          <DropdownMenuItem disabled>Sin notificaciones</DropdownMenuItem>
        )}
        {!isLoading && notifications.length > 0 && (
          <ScrollArea className="max-h-80">
            {notifications.map((notification) => (
              <DropdownMenuItem
                key={notification.id}
                onClick={() => handleMarkRead(notification)}
                className="flex items-start gap-2 py-2"
              >
                <span
                  className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${SEVERITY_DOT_CLASS[notification.severity]} ${notification.read ? "opacity-30" : ""}`}
                />
                <span className="flex flex-col gap-0.5">
                  <span className={notification.read ? "text-muted-foreground" : "font-medium"}>
                    {TYPE_LABELS[notification.type] ?? notification.type}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {new Date(notification.createdAt).toLocaleString("es-AR")}
                  </span>
                </span>
              </DropdownMenuItem>
            ))}
          </ScrollArea>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
