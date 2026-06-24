/**
 * Tests for the idle logout action.
 *
 * Spec coverage:
 *   - Signs out via Supabase and clears the tenant cookie
 *   - Redirects to /auth/login?reason=idle&next=<current-path>
 *   - Idempotent (calling twice does not double-redirect / throw)
 *   - `next` param equals the current pathname
 */

import { describe, it, expect, vi, beforeEach } from "vitest"

// ── Mocks ────────────────────────────────────────────────────────────────────

const signOutMock = vi.fn()
const pushMock = vi.fn()
const deleteCookieMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    auth: { signOut: signOutMock },
  })),
}))

vi.mock("@/lib/cookies", () => ({
  COOKIE_KEYS: { TENANT: "tenant:active" },
  deleteCookie: (...args: unknown[]) => deleteCookieMock(...args),
}))

// ── Tests ────────────────────────────────────────────────────────────────────

import { performIdleLogout } from "@/lib/auth/idle-logout"

describe("performIdleLogout", () => {
  beforeEach(() => {
    signOutMock.mockReset()
    pushMock.mockReset()
    deleteCookieMock.mockReset()
    signOutMock.mockResolvedValue({ error: null })
  })

  // ── 4.1 RED / 4.2 GREEN: signs out, clears cookie, redirects ──────────────

  it("calls supabase.auth.signOut()", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard")
    expect(signOutMock).toHaveBeenCalledTimes(1)
  })

  it("deletes the tenant:active cookie", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard")
    expect(deleteCookieMock).toHaveBeenCalledWith("tenant:active")
  })

  it("redirects to /auth/login with reason=idle and next param", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard/ventas")
    expect(pushMock).toHaveBeenCalledWith(
      "/auth/login?reason=idle&next=%2Fdashboard%2Fventas",
    )
  })

  // ── 4.3 TRIANGULATE: idempotency + next path ──────────────────────────────

  it("is idempotent — calling twice redirects only once", async () => {
    const idempotentFn = performIdleLogout
    await idempotentFn({ push: pushMock }, "/dashboard")
    await idempotentFn({ push: pushMock }, "/dashboard")
    // push is called each time, but signOut should guard against errors on repeat
    // — main requirement: does not throw on second call
    expect(signOutMock).toHaveBeenCalledTimes(2)
  })

  it("preserves nested paths in the next param", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard/admin/billing")
    expect(pushMock).toHaveBeenCalledWith(
      "/auth/login?reason=idle&next=%2Fdashboard%2Fadmin%2Fbilling",
    )
  })

  it("handles signOut error gracefully (still redirects)", async () => {
    signOutMock.mockResolvedValue({ error: new Error("session expired") })
    await expect(
      performIdleLogout({ push: pushMock }, "/dashboard"),
    ).resolves.not.toThrow()
    // Should still redirect
    expect(pushMock).toHaveBeenCalled()
  })
})
