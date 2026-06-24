/**
 * Tests for the useIdleTimer hook.
 *
 * Uses vitest fake timers to control time. BroadcastChannel and localStorage
 * are mocked to isolate transport from hook logic.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { IDLE_TIMEOUT_MS, WARNING_BEFORE_MS } from "@/lib/auth/idle-config"

// ── Mock transport so tests don't need a real BroadcastChannel ───────────────
const mockPostMessage = vi.fn()
const mockClose = vi.fn()
let storageEventHandlers: Array<(e: StorageEvent) => void> = []

vi.mock("@/lib/auth/idle-transport", () => ({
  createIdleTransport: vi.fn(() => ({
    postActivity: vi.fn(),
    postLogout: vi.fn(),
    onMessage: vi.fn(),
    close: mockClose,
  })),
}))

// ── Mock router (useIdleTimer itself doesn't navigate, the provider does) ─────
vi.mock("next/navigation", () => ({
  usePathname: vi.fn(() => "/dashboard"),
  useRouter: vi.fn(() => ({ push: vi.fn() })),
}))

import { useIdleTimer } from "@/hooks/use-idle-timer"

const warningAt = IDLE_TIMEOUT_MS - WARNING_BEFORE_MS // 1_140_000 ms

describe("useIdleTimer — timer scheduling and state transitions", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(0)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  // ── 2.1 RED / 2.2 GREEN: single setTimeout, active → warning ──────────────

  it("starts in 'active' state", () => {
    const { result } = renderHook(() => useIdleTimer())
    expect(result.current.idleState).toBe("active")
  })

  it("transitions to 'warning' after warningAt ms (single setTimeout)", () => {
    const { result } = renderHook(() => useIdleTimer())

    act(() => {
      // +2 to account for the +1 scheduling offset in the hook
      vi.advanceTimersByTime(warningAt + 2)
    })

    expect(result.current.idleState).toBe("warning")
  })

  it("transitions to 'expired' after IDLE_TIMEOUT_MS ms", () => {
    const { result } = renderHook(() => useIdleTimer())

    act(() => {
      // Must advance past both transition points (active→warning, then warning→expired)
      vi.advanceTimersByTime(IDLE_TIMEOUT_MS + 4)
    })

    expect(result.current.idleState).toBe("expired")
  })

  // ── 2.3 RED / 2.4 GREEN: activity resets the timer ───────────────────────

  it("stays 'active' after activity event while in active zone", () => {
    const { result } = renderHook(() => useIdleTimer())

    act(() => {
      vi.advanceTimersByTime(warningAt - 10_000) // 10s before warning
      result.current.reset() // simulate user activity
    })

    act(() => {
      vi.advanceTimersByTime(warningAt - 1) // would be in warning if not reset
    })

    expect(result.current.idleState).toBe("active")
  })

  it("reset() while in 'warning' brings the state back to 'active'", () => {
    const { result } = renderHook(() => useIdleTimer())

    act(() => {
      vi.advanceTimersByTime(warningAt + 1_000) // enter warning
    })
    expect(result.current.idleState).toBe("warning")

    act(() => {
      result.current.reset()
    })
    expect(result.current.idleState).toBe("active")
  })

  // ── 2.5 TRIANGULATE: throttle and listener cleanup ───────────────────────

  it("exposes secondsRemaining ≈ WARNING_BEFORE_MS/1000 when in warning state", () => {
    const { result } = renderHook(() => useIdleTimer())

    act(() => {
      vi.advanceTimersByTime(warningAt + 2)
    })

    expect(result.current.idleState).toBe("warning")
    // secondsRemaining should be at most WARNING_BEFORE_MS/1000
    expect(result.current.secondsRemaining).toBeGreaterThan(0)
    expect(result.current.secondsRemaining).toBeLessThanOrEqual(WARNING_BEFORE_MS / 1000)
  })

  it("exposes secondsRemaining = 0 when expired", () => {
    const { result } = renderHook(() => useIdleTimer())

    act(() => {
      vi.advanceTimersByTime(IDLE_TIMEOUT_MS + 5_000)
    })

    expect(result.current.secondsRemaining).toBe(0)
  })
})

// ── 2.6 / 2.7: visibilitychange / focus immediate expire ────────────────────

describe("useIdleTimer — visibility recompute", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(0)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("transitions to 'expired' immediately on visibilitychange if threshold already passed", () => {
    const { result } = renderHook(() => useIdleTimer())

    // Advance time past the threshold WITHOUT the timer firing (simulate sleeping device)
    act(() => {
      vi.setSystemTime(IDLE_TIMEOUT_MS + 10_000)
      // Simulate tab becoming visible
      Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true })
      document.dispatchEvent(new Event("visibilitychange"))
    })

    expect(result.current.idleState).toBe("expired")
  })

  it("shows 'warning' (not expired) if threshold not yet passed on focus", () => {
    const { result } = renderHook(() => useIdleTimer())

    act(() => {
      vi.setSystemTime(warningAt + 5_000) // in warning zone, not expired
      window.dispatchEvent(new Event("focus"))
    })

    expect(result.current.idleState).toBe("warning")
  })
})
