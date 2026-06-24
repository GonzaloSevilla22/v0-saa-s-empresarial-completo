"use client"

/**
 * IdleTimeoutProvider — client component that wires together:
 *   - useIdleTimer() hook (timer + activity + cross-tab transport)
 *   - IdleWarningModal (shows warning at 'warning' state)
 *   - performIdleLogout (signs out at 'expired' state, and on cross-tab logout broadcast)
 *
 * Design decisions honored:
 *   - Decision 8: mounted inside the authenticated dashboard layout, runs ONLY for logged-in users.
 *   - Decision 3: the hook's countdown (secondsRemaining) is authoritative for the modal display.
 *   - Decision 6: cross-tab logout broadcast is handled by consuming the transport's logout message
 *     via an additional effect that watches for a "logout" broadcast from peers.
 *
 * Logout broadcast from peers:
 *   The hook handles "activity" messages. "logout" messages require a router + signOut —
 *   we handle them here via a separate transport listener so the hook stays pure.
 */

import { useEffect, useRef } from "react"
import { useRouter, usePathname } from "next/navigation"
import { useIdleTimer } from "@/hooks/use-idle-timer"
import { IdleWarningModal } from "@/components/auth/IdleWarningModal"
import { performIdleLogout } from "@/lib/auth/idle-logout"
import { createIdleTransport } from "@/lib/auth/idle-transport"

export function IdleTimeoutProvider() {
  const router = useRouter()
  const pathname = usePathname()
  const { idleState, secondsRemaining, reset } = useIdleTimer()
  const hasLoggedOutRef = useRef(false)

  // ── Handle expired state ────────────────────────────────────────────────────
  useEffect(() => {
    if (idleState === "expired" && !hasLoggedOutRef.current) {
      hasLoggedOutRef.current = true
      void performIdleLogout(router, pathname)
    }
  }, [idleState, router, pathname])

  // ── Listen for cross-tab logout broadcasts ─────────────────────────────────
  useEffect(() => {
    const transport = createIdleTransport()
    transport.onMessage((msg) => {
      if (msg.type === "logout" && !hasLoggedOutRef.current) {
        hasLoggedOutRef.current = true
        void performIdleLogout(router, pathname)
      }
    })
    return () => transport.close()
  }, [router, pathname])

  // ── Modal: shown during 'warning', dismissed by "Seguir conectado" ────────
  const handleStayConnected = () => {
    reset()
  }

  return (
    <IdleWarningModal
      isOpen={idleState === "warning"}
      secondsRemaining={secondsRemaining}
      onStayConnected={handleStayConnected}
    />
  )
}
