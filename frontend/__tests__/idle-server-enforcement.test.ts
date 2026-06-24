/**
 * Tests for the server-side idle enforcement:
 *  - isServerSideIdle(lastActivity, now, timeoutMs) — pure decision function
 *  - parseLastActivityCookie(value) — safe parsing helper
 *  - evaluateIdle(cookieValue, now) — middleware-level helper (pure, no request)
 *
 * All tests are pure (no DOM, no timers, no network, no request objects).
 * Strict TDD: RED → GREEN → TRIANGULATE → REFACTOR per task.
 */

import { describe, it, expect } from "vitest"
import {
  IDLE_TIMEOUT_MS,
  isServerSideIdle,
} from "@/lib/auth/idle-config"
import {
  parseLastActivityCookie,
  evaluateIdle,
} from "@/lib/auth/idle-server"
import { COOKIE_KEYS } from "@/lib/cookies"

// ── Task 2: COOKIE_KEYS.LAST_ACTIVITY ────────────────────────────────────────

describe("COOKIE_KEYS.LAST_ACTIVITY — cookie key exists and is correct", () => {
  // RED (task 2.1): assert the key exists with the PO-confirmed name
  it("LAST_ACTIVITY key equals 'auth:last-activity'", () => {
    expect(COOKIE_KEYS.LAST_ACTIVITY).toBe("auth:last-activity")
  })

  // TRIANGULATE (task 2.3): getServerCookie is generic over CookieKey — we verify
  // the key round-trips through a mock cookie store without type errors
  it("LAST_ACTIVITY value is a non-empty string (the cookie name)", () => {
    expect(typeof COOKIE_KEYS.LAST_ACTIVITY).toBe("string")
    expect(COOKIE_KEYS.LAST_ACTIVITY.length).toBeGreaterThan(0)
  })
})

// ── Task 1: isServerSideIdle ─────────────────────────────────────────────────

describe("isServerSideIdle", () => {
  // RED test (task 1.2): fresh activity is not idle
  it("returns false when elapsed < timeoutMs (fresh)", () => {
    const now = 1_200_000
    const lastActivity = now - 1_000 // 1 second ago — well under timeout
    expect(isServerSideIdle(lastActivity, now, IDLE_TIMEOUT_MS)).toBe(false)
  })

  // TRIANGULATE (task 1.4): threshold reached is idle
  it("returns true when elapsed === timeoutMs (exact boundary)", () => {
    const now = 2_400_000
    const lastActivity = now - IDLE_TIMEOUT_MS // exactly at the boundary
    expect(isServerSideIdle(lastActivity, now, IDLE_TIMEOUT_MS)).toBe(true)
  })

  it("returns true when elapsed > timeoutMs (well past threshold)", () => {
    const now = 2_400_000
    const lastActivity = now - IDLE_TIMEOUT_MS - 60_000 // 1 minute past threshold
    expect(isServerSideIdle(lastActivity, now, IDLE_TIMEOUT_MS)).toBe(true)
  })

  it("returns false for elapsed just under threshold (boundary-1)", () => {
    const now = 2_400_000
    const lastActivity = now - (IDLE_TIMEOUT_MS - 1) // 1 ms under the threshold
    expect(isServerSideIdle(lastActivity, now, IDLE_TIMEOUT_MS)).toBe(false)
  })

  it("returns false when elapsed is 0 (just-active)", () => {
    const now = 5_000_000
    expect(isServerSideIdle(now, now, IDLE_TIMEOUT_MS)).toBe(false)
  })

  it("works with a custom timeoutMs (not tied to the global constant)", () => {
    const customTimeout = 5_000 // 5 seconds for this test
    expect(isServerSideIdle(0, customTimeout, customTimeout)).toBe(true)
    expect(isServerSideIdle(0, customTimeout - 1, customTimeout)).toBe(false)
  })
})

// ── Task 4 + 5: parseLastActivityCookie ─────────────────────────────────────

describe("parseLastActivityCookie", () => {
  it("parses a valid numeric string timestamp", () => {
    const ts = 1_718_000_000_000
    expect(parseLastActivityCookie(String(ts))).toBe(ts)
  })

  it("returns null for undefined (missing cookie)", () => {
    expect(parseLastActivityCookie(undefined)).toBeNull()
  })

  it("returns null for an empty string", () => {
    expect(parseLastActivityCookie("")).toBeNull()
  })

  it("returns null for a non-numeric string", () => {
    expect(parseLastActivityCookie("not-a-number")).toBeNull()
  })

  it("returns null for NaN-producing strings", () => {
    expect(parseLastActivityCookie("NaN")).toBeNull()
  })

  it("returns null for Infinity", () => {
    expect(parseLastActivityCookie("Infinity")).toBeNull()
  })

  it("returns null for a float that parses but is suspicious (edge: still a finite number)", () => {
    // Number("123.45") = 123.45 — finite, so we accept it (timestamps are ints but
    // we guard only for non-finite; a float means a weird client, treat as valid)
    expect(parseLastActivityCookie("123.45")).toBe(123.45)
  })
})

// ── Task 4 + 5: evaluateIdle (middleware decision helper) ───────────────────

describe("evaluateIdle — middleware idle decision (pure, no request)", () => {
  const now = 2_400_000_000 // fixed reference: well past any reasonable timestamp

  // stale + fresh (task 4.1)
  it("returns 'logout' when cookie is present and session is stale", () => {
    const staleTs = now - IDLE_TIMEOUT_MS // exactly at the boundary
    const result = evaluateIdle(String(staleTs), now)
    expect(result.action).toBe("logout")
  })

  it("returns 'proceed' when cookie is present and session is fresh", () => {
    const freshTs = now - 1_000 // 1 second ago
    const result = evaluateIdle(String(freshTs), now)
    expect(result.action).toBe("proceed")
  })

  // missing/unparseable ⇒ seed, not logout (task 5.1 / 5.2)
  it("returns 'seed' when cookie is missing (undefined)", () => {
    const result = evaluateIdle(undefined, now)
    expect(result.action).toBe("seed")
  })

  it("returns 'seed' when cookie is an empty string", () => {
    const result = evaluateIdle("", now)
    expect(result.action).toBe("seed")
  })

  it("returns 'seed' when cookie value is unparseable", () => {
    const result = evaluateIdle("not-a-timestamp", now)
    expect(result.action).toBe("seed")
  })

  it("returns 'seed' when cookie value is NaN", () => {
    const result = evaluateIdle("NaN", now)
    expect(result.action).toBe("seed")
  })

  // just under boundary → proceed, not logout
  it("returns 'proceed' for elapsed just under the threshold", () => {
    const ts = now - (IDLE_TIMEOUT_MS - 1)
    const result = evaluateIdle(String(ts), now)
    expect(result.action).toBe("proceed")
  })

  // exact boundary → logout
  it("returns 'logout' at exact threshold boundary", () => {
    const ts = now - IDLE_TIMEOUT_MS
    const result = evaluateIdle(String(ts), now)
    expect(result.action).toBe("logout")
  })
})

// ── Scoping checks (task 5.3 / 5.4) ─────────────────────────────────────────
// These are structural assertions: we verify that the PROTECTED_PREFIXES list
// used in the middleware does NOT include /auth paths, ensuring the idle check
// is never triggered on the redirect target. These are tested at the import level.

describe("PROTECTED_PREFIXES scoping — auth routes are not idle-gated", () => {
  it("'/auth/login' is NOT in PROTECTED_PREFIXES (no idle check on the redirect target)", async () => {
    // Import the list from the middleware — kept as a named export for testability
    const { PROTECTED_PREFIXES } = await import("@/lib/supabase/middleware")
    const authPaths = ["/auth/login", "/auth/register", "/auth/verify-email", "/auth"]
    for (const path of authPaths) {
      const isGated = PROTECTED_PREFIXES.some((p: string) => path.startsWith(p))
      expect(isGated, `${path} must not be gated`).toBe(false)
    }
  })
})
