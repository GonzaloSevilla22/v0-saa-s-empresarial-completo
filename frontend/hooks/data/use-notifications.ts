"use client"

import { useEffect, useMemo } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { queryKeys } from "@/lib/query-keys"
import type { Notification, NotificationType, NotificationSeverity } from "@/lib/types"

// ── Raw DB row shape (snake_case, tal como lo devuelve Supabase) ─────────────
interface NotificationRow {
  id: string
  account_id: string
  branch_id: string | null
  type: string
  severity: string
  payload: Record<string, unknown>
  audience: string[]
  read: boolean
  created_at: string
  read_at: string | null
}

function mapRow(r: NotificationRow): Notification {
  return {
    id: r.id,
    accountId: r.account_id,
    branchId: r.branch_id,
    type: r.type as NotificationType,
    severity: r.severity as NotificationSeverity,
    payload: r.payload ?? {},
    read: r.read,
    createdAt: r.created_at,
    readAt: r.read_at,
  }
}

const NOTIFICATIONS_LIMIT = 20

/**
 * v3-notifications-realtime (D7 design.md): fetch inicial (React Query) +
 * suscripción Realtime postgres_changes sobre notifications (INSERT). La
 * RLS de audiencia filtra el stream server-side — el filter del canal es
 * solo optimización de red, no la garantía de seguridad (D1).
 *
 * Sin polling: el badge se deriva del stream + la query inicial, nunca de
 * refetchInterval. En reconnect (`subscribe` con status !== 'SUBSCRIBED' la
 * primera vez, o cualquier resubscribe posterior) se invalida la query para
 * resincronizar (patrón de resiliencia FS §9.6).
 */
export function useNotifications() {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const supabase = useMemo(() => createClient(), [])
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: accountId ? queryKeys.notifications.byAccount(accountId) : queryKeys.notifications.all(),
    queryFn: async (): Promise<Notification[]> => {
      if (!accountId) return []

      const { data, error } = await supabase
        .from("notifications")
        .select("id, account_id, branch_id, type, severity, payload, audience, read, created_at, read_at")
        .eq("account_id", accountId)
        .order("created_at", { ascending: false })
        .limit(NOTIFICATIONS_LIMIT)

      if (error) throw error
      return (data ?? []).map((r) => mapRow(r as unknown as NotificationRow))
    },
    enabled: !!accountId,
    staleTime: 60 * 1000,
  })

  useEffect(() => {
    if (!accountId) return

    const queryKey = queryKeys.notifications.byAccount(accountId)

    const channel = supabase
      .channel(`notifications:${accountId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "notifications",
          filter: `account_id=eq.${accountId}`,
        },
        (payload: { new: Record<string, unknown> }) => {
          const incoming = mapRow(payload.new as unknown as NotificationRow)

          queryClient.setQueryData<Notification[]>(queryKey, (prev) => {
            const current = prev ?? []
            // Dedupe por id — evita duplicados si Realtime y un resync compiten (D7/Risks).
            if (current.some((n) => n.id === incoming.id)) return current
            return [incoming, ...current].slice(0, NOTIFICATIONS_LIMIT)
          })
        },
      )
      .subscribe((status: string) => {
        // Resync al (re)conectar: invalida la query para no perder eventos
        // ocurridos mientras el canal estaba caído (patrón FS §9.6).
        if (status === "SUBSCRIBED") {
          queryClient.invalidateQueries({ queryKey })
        }
      })

    return () => {
      supabase.removeChannel(channel)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accountId, supabase, queryClient])

  const notifications = query.data ?? []
  const unreadCount = notifications.filter((n) => !n.read).length

  return {
    notifications,
    unreadCount,
    isLoading: query.isLoading,
    isError: query.isError,
  }
}

/**
 * Marca una notificación como leída. UPDATE directo con RLS (USING + WITH
 * CHECK) — sin RPC (D5 design.md). Idempotente: re-marcar una ya leída no
 * rompe (el WHERE read=false evita un UPDATE innecesario, pero repetir la
 * llamada no falla — simplemente no afecta filas).
 */
export async function markNotificationRead(
  supabase: ReturnType<typeof createClient>,
  notificationId: string,
): Promise<void> {
  const { error } = await supabase
    .from("notifications")
    .update({ read: true, read_at: new Date().toISOString() })
    .eq("id", notificationId)
    .eq("read", false)

  if (error) throw error
}
