/**
 * Tests for the idle session timeout configuration constants and the pure
 * `computeIdleState` decision function.
 *
 * All tests are pure (no DOM, no timers, no network).
 */

import { describe, it, expect } from "vitest"
import {
  IDLE_TIMEOUT_MS,
  WARNING_BEFORE_MS,
  computeIdleState,
  type IdleConfig,
  type IdleState,
} from "@/lib/auth/idle-config"

// ── 1.1 / 1.2: Constants ────────────────────────────────────────────────────

describe("Idle configuration constants", () => {
  it("IDLE_TIMEOUT_MS equals 20 minutes (1_200_000 ms)", () => {
    expect(IDLE_TIMEOUT_MS).toBe(1_200_000)
  })

  it("WARNING_BEFORE_MS equals 1 minute (60_000 ms)", () => {
    expect(WARNING_BEFORE_MS).toBe(60_000)
  })

  it("WARNING_BEFORE_MS is strictly less than IDLE_TIMEOUT_MS", () => {
    expect(WARNING_BEFORE_MS).toBeLessThan(IDLE_TIMEOUT_MS)
  })
})

// ── 1.3 / 1.4: computeIdleState — active ────────────────────────────────────

describe("computeIdleState — active zone", () => {
  const cfg: IdleConfig = { idleTimeoutMs: IDLE_TIMEOUT_MS, warningBeforeMs: WARNING_BEFORE_MS }

  it("returns 'active' when elapsed is well below the warning window", () => {
    const now = 1_000_000
    const lastActivity = now - 1_000 // 1 second elapsed
    const state: IdleState = computeIdleState(lastActivity, now, cfg)
    expect(state).toBe("active")
  })

  it("returns 'active' when elapsed is zero (just joined)", () => {
    const now = 1_000_000
    const state: IdleState = computeIdleState(now, now, cfg)
    expect(state).toBe("active")
  })
})

// ── 1.5 TRIANGULATE: warning, expired, exact boundaries ─────────────────────

describe("computeIdleState — warning zone", () => {
  const cfg: IdleConfig = { idleTimeoutMs: IDLE_TIMEOUT_MS, warningBeforeMs: WARNING_BEFORE_MS }
  const warningAt = IDLE_TIMEOUT_MS - WARNING_BEFORE_MS // 1_140_000 ms

  it("returns 'warning' when elapsed equals the warning-start boundary (inclusive)", () => {
    const now = warningAt
    const state: IdleState = computeIdleState(0, now, cfg)
    expect(state).toBe("warning")
  })

  it("returns 'warning' when elapsed is within the warning window (not yet expired)", () => {
    const now = warningAt + 30_000 // 30 s into the warning window
    const state: IdleState = computeIdleState(0, now, cfg)
    expect(state).toBe("warning")
  })

  it("returns 'warning' one millisecond before the threshold", () => {
    const now = IDLE_TIMEOUT_MS - 1
    const state: IdleState = computeIdleState(0, now, cfg)
    expect(state).toBe("warning")
  })
})

describe("computeIdleState — expired zone", () => {
  const cfg: IdleConfig = { idleTimeoutMs: IDLE_TIMEOUT_MS, warningBeforeMs: WARNING_BEFORE_MS }

  it("returns 'expired' when elapsed equals the idle threshold exactly", () => {
    const now = IDLE_TIMEOUT_MS
    const state: IdleState = computeIdleState(0, now, cfg)
    expect(state).toBe("expired")
  })

  it("returns 'expired' when elapsed exceeds the idle threshold", () => {
    const now = IDLE_TIMEOUT_MS + 5_000
    const state: IdleState = computeIdleState(0, now, cfg)
    expect(state).toBe("expired")
  })
})

// ── 1.6 REFACTOR validation: helper values are consistent ───────────────────

describe("computeIdleState — boundary consistency", () => {
  const cfg: IdleConfig = { idleTimeoutMs: IDLE_TIMEOUT_MS, warningBeforeMs: WARNING_BEFORE_MS }
  const warningAt = IDLE_TIMEOUT_MS - WARNING_BEFORE_MS

  it("state transitions: active → warning → expired as elapsed grows", () => {
    const check = (elapsed: number) => computeIdleState(0, elapsed, cfg)
    expect(check(warningAt - 1)).toBe("active")
    expect(check(warningAt)).toBe("warning")
    expect(check(IDLE_TIMEOUT_MS - 1)).toBe("warning")
    expect(check(IDLE_TIMEOUT_MS)).toBe("expired")
  })
})
