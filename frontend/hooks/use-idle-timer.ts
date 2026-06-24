"use client"

/**
 * useIdleTimer — tracks user inactivity and classifies the session as
 * 'active' | 'warning' | 'expired'.
 *
 * Design decisions honored:
 *  - Decision 2: computeIdleState is the single source of truth.
 *  - Decision 3: single recomputed setTimeout (not a ticking interval).
 *  - Decision 4: recompute on visibilitychange / focus; log out immediately if expired.
 *  - Decision 5: throttle activity handlers to ~1/sec (leading edge).
 *  - Decision 6: cross-tab transport injected via createIdleTransport().
 */

import { useState, useEffect, useRef, useCallback } from "react"
import {
  computeIdleState,
  msUntilWarning,
  msUntilExpiry,
  DEFAULT_IDLE_CONFIG,
  type IdleState,
  type IdleConfig,
} from "@/lib/auth/idle-config"
import { createIdleTransport, type IdleTransport } from "@/lib/auth/idle-transport"
import { setCookie, COOKIE_KEYS } from "@/lib/cookies"

export interface UseIdleTimerReturn {
  /** Current classification of the idle state. */
  idleState: IdleState
  /** Seconds remaining until logout (0 when expired). */
  secondsRemaining: number
  /** Call to record user activity and reset the timer. */
  reset: () => void
}

/** Throttle interval for activity events (~1 event per second max). */
const THROTTLE_MS = 1_000

export function useIdleTimer(config: IdleConfig = DEFAULT_IDLE_CONFIG): UseIdleTimerReturn {
  const [idleState, setIdleState] = useState<IdleState>("active")
  const [secondsRemaining, setSecondsRemaining] = useState(
    Math.ceil(config.idleTimeoutMs / 1000),
  )

  // lastActivity is stored in a ref so event handlers can read the latest value
  // without needing to be recreated on every state change.
  const lastActivityRef = useRef<number>(Date.now())
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const transportRef = useRef<IdleTransport | null>(null)
  // Throttle gate: timestamp of the last time we actually updated lastActivity.
  const lastThrottleRef = useRef<number>(0)

  // ── Recompute and schedule ─────────────────────────────────────────────────

  const recompute = useCallback(() => {
    const now = Date.now()
    const lastActivity = lastActivityRef.current
    const state = computeIdleState(lastActivity, now, config)

    setIdleState(state)

    // Compute remaining seconds (for the modal countdown)
    const remainingMs = msUntilExpiry(lastActivity, now, config)
    setSecondsRemaining(Math.ceil(remainingMs / 1000))

    // Clear any pending timer
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }

    if (state === "expired") {
      // Already expired; caller (provider) will trigger logout.
      return
    }

    if (state === "active") {
      // Schedule the next transition: to warning.
      const msToWarning = msUntilWarning(lastActivity, now, config)
      timerRef.current = setTimeout(() => recompute(), msToWarning + 1)
    } else {
      // In warning zone: schedule logout at the expiry point.
      const msToExpiry = msUntilExpiry(lastActivity, now, config)
      timerRef.current = setTimeout(() => recompute(), msToExpiry + 1)
    }
  }, [config])

  // ── Activity reset ─────────────────────────────────────────────────────────

  const reset = useCallback(() => {
    const now = Date.now()
    lastActivityRef.current = now
    lastThrottleRef.current = now
    // Persist activity timestamp for server-side idle enforcement (Decision 1,
    // idle-server-enforcement change). The middleware reads this cookie and never
    // writes it — only the client interaction path does (Design Decision 1).
    setCookie(COOKIE_KEYS.LAST_ACTIVITY, String(now))
    // Broadcast to other tabs
    transportRef.current?.postActivity(now)
    recompute()
  }, [recompute])

  // Throttled activity handler (leading edge, ~1/sec).
  const handleActivity = useCallback(() => {
    const now = Date.now()
    if (now - lastThrottleRef.current < THROTTLE_MS) return
    lastThrottleRef.current = now
    lastActivityRef.current = now
    // Persist activity timestamp for server-side idle enforcement.
    // Only written here (user interaction, throttled ~1/sec) — never from
    // peer/transport messages, visibility changes, or token-refresh paths.
    setCookie(COOKIE_KEYS.LAST_ACTIVITY, String(now))
    // Broadcast to other tabs (no re-broadcast from peer events)
    transportRef.current?.postActivity(now)
    recompute()
  }, [recompute])

  // ── Visibility / focus recompute (Decision 4) ─────────────────────────────

  const handleVisibilityOrFocus = useCallback(() => {
    if (document.visibilityState === "hidden") return
    recompute()
  }, [recompute])

  // ── Cross-tab message handler ─────────────────────────────────────────────

  const handleTransportMessage = useCallback(
    (msg: { type: string; lastActivity?: number }) => {
      if (msg.type === "activity" && typeof msg.lastActivity === "number") {
        // Adopt only if newer than our own last activity.
        if (msg.lastActivity > lastActivityRef.current) {
          lastActivityRef.current = msg.lastActivity
          recompute()
        }
      }
      // "logout" messages are handled in IdleTimeoutProvider (needs router + signOut).
    },
    [recompute],
  )

  // ── Effects ────────────────────────────────────────────────────────────────

  useEffect(() => {
    // Initial scheduling
    recompute()

    // Activity listeners — passive where supported to avoid blocking scroll.
    const activityEvents = ["mousemove", "keydown", "scroll", "wheel", "touchstart", "click"] as const
    const passiveEvents = new Set(["mousemove", "scroll", "wheel", "touchstart"])

    for (const ev of activityEvents) {
      window.addEventListener(ev, handleActivity, {
        passive: passiveEvents.has(ev),
        capture: false,
      })
    }

    // Visibility / focus
    document.addEventListener("visibilitychange", handleVisibilityOrFocus)
    window.addEventListener("focus", handleVisibilityOrFocus)

    // Cross-tab transport
    const transport = createIdleTransport()
    transportRef.current = transport
    transport.onMessage(handleTransportMessage)

    return () => {
      // Cleanup on unmount — no leaks.
      if (timerRef.current !== null) clearTimeout(timerRef.current)

      for (const ev of activityEvents) {
        window.removeEventListener(ev, handleActivity)
      }
      document.removeEventListener("visibilitychange", handleVisibilityOrFocus)
      window.removeEventListener("focus", handleVisibilityOrFocus)

      transport.close()
      transportRef.current = null
    }
  }, [handleActivity, handleVisibilityOrFocus, handleTransportMessage, recompute])

  return { idleState, secondsRemaining, reset }
}
