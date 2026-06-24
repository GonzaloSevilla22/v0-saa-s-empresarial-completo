/**
 * Tests that useIdleTimer writes the lastActivity cookie on the throttled
 * activity path and on reset(), and does NOT write it from non-interaction paths.
 *
 * Strategy: mock `@/lib/cookies` and assert `setCookie` is called with
 * `COOKIE_KEYS.LAST_ACTIVITY` on the correct paths.
 *
 * Strict TDD: RED → GREEN → TRIANGULATE → REFACTOR (task 3.2 → 3.5).
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook, act } from "@testing-library/react"

// ── Hoist mockSetCookie so it's available in vi.mock factories ────────────────
const { mockSetCookie } = vi.hoisted(() => ({
  mockSetCookie: vi.fn(),
}))

// ── Mock transport ────────────────────────────────────────────────────────────
vi.mock("@/lib/auth/idle-transport", () => ({
  createIdleTransport: vi.fn(() => ({
    postActivity: vi.fn(),
    postLogout: vi.fn(),
    onMessage: vi.fn(),
    close: vi.fn(),
  })),
}))

// ── Mock router ───────────────────────────────────────────────────────────────
vi.mock("next/navigation", () => ({
  usePathname: vi.fn(() => "/dashboard"),
  useRouter: vi.fn(() => ({ push: vi.fn() })),
}))

// ── Mock cookies so we can spy on setCookie ───────────────────────────────────
vi.mock("@/lib/cookies", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/cookies")>()
  return {
    ...original,
    setCookie: mockSetCookie,
  }
})

import { COOKIE_KEYS } from "@/lib/cookies"

import { useIdleTimer } from "@/hooks/use-idle-timer"

describe("useIdleTimer — lastActivity cookie writes (task 3)", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000_000)
    mockSetCookie.mockClear()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  // RED (task 3.2): throttled activity path writes the cookie
  it("writes the lastActivity cookie when a user activity event fires", () => {
    renderHook(() => useIdleTimer())
    mockSetCookie.mockClear() // clear any call from initialization

    act(() => {
      window.dispatchEvent(new Event("mousemove"))
    })

    expect(mockSetCookie).toHaveBeenCalledWith(
      COOKIE_KEYS.LAST_ACTIVITY,
      expect.any(String),
    )
  })

  // GREEN continuation: reset() also writes the cookie
  it("writes the lastActivity cookie when reset() is called", () => {
    const { result } = renderHook(() => useIdleTimer())
    mockSetCookie.mockClear()

    act(() => {
      result.current.reset()
    })

    expect(mockSetCookie).toHaveBeenCalledWith(
      COOKIE_KEYS.LAST_ACTIVITY,
      expect.any(String),
    )
  })

  // TRIANGULATE (task 3.4): high-frequency events write at most once per throttle window
  it("does NOT write the cookie more than once per throttle window (high-freq events)", () => {
    renderHook(() => useIdleTimer())
    mockSetCookie.mockClear()

    act(() => {
      // Fire 10 events within the same throttle window (no time advance)
      for (let i = 0; i < 10; i++) {
        window.dispatchEvent(new Event("mousemove"))
      }
    })

    // Only 1 write for the leading-edge throttle
    expect(mockSetCookie).toHaveBeenCalledTimes(1)
  })

  // TRIANGULATE (task 3.4): second event after the throttle window CAN write again
  it("writes the cookie again after the throttle window has elapsed", () => {
    renderHook(() => useIdleTimer())
    mockSetCookie.mockClear()

    act(() => {
      window.dispatchEvent(new Event("mousemove")) // first write
    })
    const firstCallCount = mockSetCookie.mock.calls.length

    act(() => {
      vi.advanceTimersByTime(1_100) // 1.1s — past the 1s throttle
      window.dispatchEvent(new Event("keydown")) // second write allowed
    })

    expect(mockSetCookie.mock.calls.length).toBeGreaterThan(firstCallCount)
  })

  // TRIANGULATE (task 3.4): non-interaction paths do NOT write the cookie
  it("does NOT write the cookie on visibility change alone (non-interaction recompute)", () => {
    renderHook(() => useIdleTimer())
    mockSetCookie.mockClear()

    act(() => {
      Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true })
      document.dispatchEvent(new Event("visibilitychange"))
    })

    // visibilitychange triggers recompute (not activity update), so no cookie write
    expect(mockSetCookie).not.toHaveBeenCalled()
  })
})
