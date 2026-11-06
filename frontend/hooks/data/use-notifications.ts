"use client"

import { useEffect, useMemo } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { toast } from "sonner"
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
 * tablero-explicable (D6): la caché guarda las últimas N NO LEÍDAS más el
 * total exacto de no leídas visibles (para el badge), que puede ser mucho
 * mayor que las filas traídas.
 */
interface NotificationsData {
  items: Notification[]
  total: number
}

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

  const queryKey = accountId ? queryKeys.notifications.byAccount(accountId) : queryKeys.notifications.all()

  const query = useQuery({
    queryKey,
    queryFn: async (): Promise<NotificationsData> => {
      if (!accountId) return { items: [], total: 0 }

      // Sólo las no leídas (un aviso «cerrado» = leído, OQ-1) con el total
      // exacto: el badge deja de ser «no leídas entre las últimas 20».
      const { data, count, error } = await supabase
        .from("notifications")
        .select("id, account_id, branch_id, type, severity, payload, audience, read, created_at, read_at", {
          count: "exact",
        })
        .eq("account_id", accountId)
        .eq("read", false)
        .order("created_at", { ascending: false })
        .limit(NOTIFICATIONS_LIMIT)

      if (error) throw error
      const items = (data ?? []).map((r) => mapRow(r as unknown as NotificationRow))
      return { items, total: count ?? items.length }
    },
    enabled: !!accountId,
    staleTime: 60 * 1000,
  })

  useEffect(() => {
    if (!accountId) return

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

          // Sólo las no leídas entran al panel.
          if (incoming.read) return

          queryClient.setQueryData<NotificationsData>(queryKey, (prev) => {
            const current = prev ?? { items: [], total: 0 }
            // Dedupe por id — evita duplicados si Realtime y un resync compiten (D7/Risks).
            if (current.items.some((n) => n.id === incoming.id)) return current
            return {
              items: [incoming, ...current.items].slice(0, NOTIFICATIONS_LIMIT),
              total: current.total + 1,
            }
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

  // Actualización optimista (D6): la fila sale y el contador baja en el acto;
  // si la escritura falla, se restaura la caché y se avisa. Al terminar se
  // resincroniza para que el panel se complete con las siguientes no leídas.
  const markReadMutation = useMutation<void, Error, string, { previous?: NotificationsData }>({
    mutationFn: (id) => markNotificationRead(supabase, id),
    onMutate: async (id) => {
      await queryClient.cancelQueries({ queryKey })
      const previous = queryClient.getQueryData<NotificationsData>(queryKey)
      queryClient.setQueryData<NotificationsData>(queryKey, (prev) => {
        if (!prev) return prev
        const had = prev.items.some((n) => n.id === id)
        return {
          items: prev.items.filter((n) => n.id !== id),
          total: had ? Math.max(0, prev.total - 1) : prev.total,
        }
      })
      return { previous }
    },
    onError: (_err, _id, ctx) => {
      if (ctx?.previous) queryClient.setQueryData(queryKey, ctx.previous)
      toast.error("No pudimos marcar la notificación como leída. Probá de nuevo.")
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey })
    },
  })

  const markAllReadMutation = useMutation<void, Error, void, { previous?: NotificationsData }>({
    mutationFn: async () => {
      if (!accountId) return
      await markAllNotificationsRead(supabase, accountId)
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey })
      const previous = queryClient.getQueryData<NotificationsData>(queryKey)
      queryClient.setQueryData<NotificationsData>(queryKey, { items: [], total: 0 })
      return { previous }
    },
    onError: (_err, _vars, ctx) => {
      if (ctx?.previous) queryClient.setQueryData(queryKey, ctx.previous)
      toast.error("No pudimos marcar las notificaciones como leídas. Probá de nuevo.")
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey })
    },
  })

  const notifications = query.data?.items ?? []
  const unreadCount = query.data?.total ?? 0

  return {
    notifications,
    unreadCount,
    isLoading: query.isLoading,
    isError: query.isError,
    markRead: (id: string) => markReadMutation.mutate(id),
    markAllRead: () => markAllReadMutation.mutate(),
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

/**
 * tablero-explicable (D6): marca como leídas TODAS las no leídas de la cuenta
 * activa en un solo UPDATE. La RLS de audiencia acota lo que el usuario puede
 * tocar; el `account_id` explícito es defensa en profundidad y usa el índice
 * existente de `notifications`.
 */
export async function markAllNotificationsRead(
  supabase: ReturnType<typeof createClient>,
  accountId: string,
): Promise<void> {
  const { error } = await supabase
    .from("notifications")
    .update({ read: true, read_at: new Date().toISOString() })
    .eq("account_id", accountId)
    .eq("read", false)

  if (error) throw error
}
