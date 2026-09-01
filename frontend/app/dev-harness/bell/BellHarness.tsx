"use client"

/**
 * qa-integral-modulos G5 (H5): arnés de la campana de notificaciones con datos
 * sintéticos — la campana real (NotificationBellView, el MISMO panel que monta
 * NotificationBell) con 15 notificaciones (el fixture del informe: badge "9+",
 * 6 visibles, 9 inalcanzables) y un control sano con 3.
 *
 * Los specs de e2e/harness/g5-bell-scroll.spec.ts fijan el contrato acá.
 */

import { NotificationBellView } from "@/components/dashboard/NotificationBell"
import type { Notification, NotificationType } from "@/lib/types"

const TYPES: NotificationType[] = [
  "CashSessionClosed",
  "StockBelowMinimum",
  "QuoteAccepted",
  "TransferDispatched",
  "PlanLimitExceeded",
]

function makeNotifications(count: number): Notification[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `notif-${i + 1}`,
    accountId: "acc-harness",
    branchId: null,
    type: TYPES[i % TYPES.length],
    severity: i % 3 === 0 ? "urgent" : i % 3 === 1 ? "warning" : "info",
    payload: {},
    read: i % 2 === 0,
    // Fecha distinta por ítem para que cada fila sea identificable.
    createdAt: new Date(2026, 7, 30, 10, i + 1).toISOString(),
    readAt: null,
  }))
}

const MANY = makeNotifications(15)
const FEW = makeNotifications(3)

export function BellHarness() {
  return (
    <div className="min-h-svh bg-background p-6 flex flex-col gap-6">
      <h1 className="text-lg font-semibold text-foreground">
        Arnés G5 — campana de notificaciones
      </h1>

      <section data-testid="campana-15" className="flex items-center gap-2">
        <span className="text-sm text-muted-foreground">15 notificaciones</span>
        <NotificationBellView
          notifications={MANY}
          unreadCount={MANY.filter((n) => !n.read).length}
          isLoading={false}
          onMarkRead={() => {}}
        />
      </section>

      <section data-testid="campana-3" className="flex items-center gap-2">
        <span className="text-sm text-muted-foreground">3 notificaciones</span>
        <NotificationBellView
          notifications={FEW}
          unreadCount={1}
          isLoading={false}
          onMarkRead={() => {}}
        />
      </section>
    </div>
  )
}
