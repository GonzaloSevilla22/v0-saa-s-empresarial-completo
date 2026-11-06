"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { Bell, X } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { useNotifications } from "@/hooks/data/use-notifications"
import { notificationDestinationLabel, notificationHref } from "@/lib/notification-routes"
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
  // cobranzas-vencimientos (D8): resumen diario de deuda vencida, por lado.
  ReceivablesOverdueDigest: "Deuda vencida por cobrar",
  PayablesOverdueDigest: "Deuda vencida con proveedores",
}

function labelOf(notification: Notification): string {
  return TYPE_LABELS[notification.type] ?? notification.type
}

/**
 * v3-notifications-realtime (D7 design.md) + tablero-explicable (D6): campana
 * de notificaciones en el header. Badge de no leídas (total exacto) + panel con
 * las últimas N no leídas, cada una descartable o navegable a su alerta.
 * Alimentada por useNotifications (React Query + Supabase Realtime) — sin
 * polling. Descartar y navegar marcan leída de forma optimista.
 */
export function NotificationBell() {
  const { notifications, unreadCount, isLoading, markRead, markAllRead } = useNotifications()

  return (
    <NotificationBellView
      notifications={notifications}
      unreadCount={unreadCount}
      isLoading={isLoading}
      onMarkRead={(notification) => markRead(notification.id)}
      onMarkAllRead={markAllRead}
    />
  )
}

/**
 * qa-integral-modulos (G5/H5): panel presentacional separado del wireado de
 * datos para que el arnés de navegador (/dev-harness/bell) pueda fijar el
 * contrato de scroll con notificaciones sintéticas, sin sesión ni Realtime.
 */
export function NotificationBellView({
  notifications,
  unreadCount,
  isLoading,
  onMarkRead,
  onMarkAllRead,
}: {
  notifications: Notification[]
  unreadCount: number
  isLoading: boolean
  onMarkRead: (notification: Notification) => void
  onMarkAllRead: () => void
}) {
  const router = useRouter()
  const [open, setOpen] = useState(false)

  function openNotification(notification: Notification, href: string) {
    onMarkRead(notification)
    router.push(href)
    setOpen(false)
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
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
      </PopoverTrigger>
      <PopoverContent
        align="end"
        className="w-80 max-w-[calc(100vw-2rem)] bg-popover border-border p-0"
        aria-label="Notificaciones"
      >
        <div className="flex items-center justify-between gap-2 border-b border-border px-3 py-2">
          <div className="flex flex-col">
            <span className="text-sm font-medium text-foreground">Notificaciones</span>
            {unreadCount > 0 && (
              <span className="text-xs text-muted-foreground">{unreadCount} sin leer</span>
            )}
          </div>
          {notifications.length > 0 && (
            <Button
              variant="ghost"
              size="sm"
              className="h-7 px-2 text-xs"
              onClick={onMarkAllRead}
            >
              Marcar todas como leídas
            </Button>
          )}
        </div>

        {isLoading && (
          <p className="px-3 py-4 text-sm text-muted-foreground">Cargando notificaciones…</p>
        )}
        {!isLoading && notifications.length === 0 && (
          <p className="px-3 py-4 text-sm text-muted-foreground">Sin notificaciones</p>
        )}
        {!isLoading && notifications.length > 0 && (
          // qa-integral-modulos (G5/H5): el límite de alto va en el VIEWPORT
          // interno, no en el root — en el root (overflow-hidden) recortaba el
          // panel a 6 de 15 notificaciones sin habilitar ningún scroll.
          <ScrollArea viewportClassName="max-h-80">
            <ul className="flex flex-col">
              {notifications.map((notification) => {
                const label = labelOf(notification)
                const href = notificationHref(notification)
                const destination = notificationDestinationLabel(notification.type)
                const date = new Date(notification.createdAt).toLocaleString("es-AR")
                const content = (
                  <>
                    <span
                      className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${SEVERITY_DOT_CLASS[notification.severity]}`}
                    />
                    <span className="flex min-w-0 flex-col gap-0.5">
                      <span className="text-sm font-medium text-foreground">{label}</span>
                      <span className="text-xs text-muted-foreground">{date}</span>
                      {href && destination && (
                        <span className="text-xs font-medium text-primary">{destination}</span>
                      )}
                    </span>
                  </>
                )

                return (
                  <li
                    key={notification.id}
                    className="flex items-start gap-1 border-b border-border/60 last:border-b-0 px-1"
                  >
                    {href ? (
                      <button
                        type="button"
                        onClick={() => openNotification(notification, href)}
                        className="flex min-w-0 flex-1 items-start gap-2 rounded-sm px-2 py-2 text-left hover:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                      >
                        {content}
                      </button>
                    ) : (
                      <div className="flex min-w-0 flex-1 items-start gap-2 px-2 py-2">{content}</div>
                    )}
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      className="mt-1 h-7 w-7 shrink-0 text-muted-foreground hover:text-foreground"
                      aria-label={`Descartar: ${label}`}
                      onClick={() => onMarkRead(notification)}
                    >
                      <X className="h-3.5 w-3.5" />
                    </Button>
                  </li>
                )
              })}
            </ul>
          </ScrollArea>
        )}
      </PopoverContent>
    </Popover>
  )
}
