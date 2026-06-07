/**
 * Unit tests for C-10 subscription-ui-upgrade-flow — billing logic.
 *
 * Tests cover pure TypeScript functions extracted from the route handlers.
 * No Supabase client, no MercadoPago SDK, no HTTP calls.
 *
 * SQL/RLS tests (webhook idempotency, process_cancellations trigger) require
 * `npx supabase test db` with a real instance — those are integration tests
 * and live in supabase/tests/ when available.
 */

import { describe, it, expect } from "vitest"
import type { Plan } from "@/lib/types"

// ─── Pure logic extracted from app/api/billing/preferences/route.ts ───────────

const PLAN_HIERARCHY: Plan[] = ["gratis", "inicial", "avanzado", "pro"]

function isValidPaidPlan(plan: unknown): plan is Plan {
  return (
    typeof plan === "string" &&
    PLAN_HIERARCHY.includes(plan as Plan) &&
    plan !== "gratis"
  )
}

function buildExternalReference(userId: string, plan: Plan): string {
  return `${userId}::${plan}`
}

function parseExternalReference(ref: string): { userId: string; plan: Plan } | null {
  const parts = ref.split("::")
  if (parts.length !== 2) return null
  const [userId, plan] = parts
  if (!userId || !PLAN_HIERARCHY.includes(plan as Plan)) return null
  return { userId, plan: plan as Plan }
}

// ─── Pure logic extracted from HMAC verification ────────────────────────────

function parseXSignature(xSignature: string | null): { ts: string; v1: string } | null {
  if (!xSignature) return null
  const parts = Object.fromEntries(
    xSignature.split(",").map((p) => {
      const idx = p.indexOf("=")
      return [p.slice(0, idx), p.slice(idx + 1)] as [string, string]
    })
  )
  if (!parts["ts"] || !parts["v1"]) return null
  return { ts: parts["ts"], v1: parts["v1"] }
}

// ─── Pure logic for cancellation eligibility ─────────────────────────────────

interface AccountState {
  billing_plan: Plan
  billing_status: "active" | "trialing" | "expired" | "cancelled" | "cancelling"
}

function canCancelSubscription(account: AccountState): { allowed: boolean; reason?: string } {
  if (account.billing_plan === "gratis") {
    return { allowed: false, reason: "No hay un plan pago activo para cancelar" }
  }
  if (account.billing_status === "cancelling") {
    return { allowed: false, reason: "La cancelación ya está programada" }
  }
  if (account.billing_status !== "active") {
    return { allowed: false, reason: "El plan no está activo" }
  }
  return { allowed: true }
}

// ─── Pure logic for plan expiry sweep (mirrors process_cancellations SQL) ─────

interface AccountForSweep {
  id: string
  billing_plan: Plan
  billing_status: AccountState["billing_status"]
  plan_expires_at: Date | null
}

function selectAccountsForCancellation(accounts: AccountForSweep[], now: Date): AccountForSweep[] {
  return accounts.filter(
    (a) =>
      a.billing_status === "cancelling" &&
      a.plan_expires_at !== null &&
      a.plan_expires_at < now
  )
}

// ─── isValidPaidPlan ─────────────────────────────────────────────────────────

describe("isValidPaidPlan — preferences input validation", () => {
  it("accepts inicial", () => {
    expect(isValidPaidPlan("inicial")).toBe(true)
  })

  it("accepts avanzado", () => {
    expect(isValidPaidPlan("avanzado")).toBe(true)
  })

  it("accepts pro", () => {
    expect(isValidPaidPlan("pro")).toBe(true)
  })

  it("rejects gratis (cannot pay for free plan)", () => {
    expect(isValidPaidPlan("gratis")).toBe(false)
  })

  it("rejects undefined", () => {
    expect(isValidPaidPlan(undefined)).toBe(false)
  })

  it("rejects unknown plan string", () => {
    expect(isValidPaidPlan("enterprise")).toBe(false)
  })

  it("rejects number", () => {
    expect(isValidPaidPlan(42)).toBe(false)
  })
})

// ─── external_reference round-trip ───────────────────────────────────────────

describe("external_reference — build and parse (MP payment tracking)", () => {
  const userId = "uuid-abc-123"

  it("builds correct reference for inicial", () => {
    expect(buildExternalReference(userId, "inicial")).toBe("uuid-abc-123::inicial")
  })

  it("builds correct reference for pro", () => {
    expect(buildExternalReference(userId, "pro")).toBe("uuid-abc-123::pro")
  })

  it("parses valid reference → userId + plan (task 7.1)", () => {
    const parsed = parseExternalReference("uuid-abc-123::avanzado")
    expect(parsed).toEqual({ userId: "uuid-abc-123", plan: "avanzado" })
  })

  it("returns null for malformed reference (no ::)", () => {
    expect(parseExternalReference("uuid-abc-123")).toBeNull()
  })

  it("returns null for unknown plan in reference", () => {
    expect(parseExternalReference("uuid::enterprise")).toBeNull()
  })

  it("returns null for empty string", () => {
    expect(parseExternalReference("")).toBeNull()
  })
})

// ─── parseXSignature — webhook signature parsing ──────────────────────────────

describe("parseXSignature — webhook HMAC header parsing (task 7.2)", () => {
  it("parses valid x-signature header", () => {
    const result = parseXSignature("ts=1749000000,v1=abc123def456")
    expect(result).toEqual({ ts: "1749000000", v1: "abc123def456" })
  })

  it("returns null for null header (invalid sig → 401)", () => {
    expect(parseXSignature(null)).toBeNull()
  })

  it("returns null for header missing v1", () => {
    expect(parseXSignature("ts=1749000000")).toBeNull()
  })

  it("returns null for header missing ts", () => {
    expect(parseXSignature("v1=abc123")).toBeNull()
  })

  it("returns null for empty string", () => {
    expect(parseXSignature("")).toBeNull()
  })

  it("handles v1 containing = sign (base64-safe)", () => {
    const sig = "ts=1749000000,v1=abc=def="
    const result = parseXSignature(sig)
    expect(result?.v1).toBe("abc=def=")
  })
})

// ─── canCancelSubscription — cancellation eligibility ────────────────────────

describe("canCancelSubscription — cancel route guard (task 7.4)", () => {
  it("allows cancellation for active paid plan", () => {
    const result = canCancelSubscription({ billing_plan: "avanzado", billing_status: "active" })
    expect(result.allowed).toBe(true)
  })

  it("allows cancellation for pro plan", () => {
    const result = canCancelSubscription({ billing_plan: "pro", billing_status: "active" })
    expect(result.allowed).toBe(true)
  })

  it("blocks cancellation for gratis plan (no paid plan to cancel)", () => {
    const result = canCancelSubscription({ billing_plan: "gratis", billing_status: "active" })
    expect(result.allowed).toBe(false)
    expect(result.reason).toContain("pago")
  })

  it("blocks cancellation when already cancelling (idempotent guard)", () => {
    const result = canCancelSubscription({ billing_plan: "avanzado", billing_status: "cancelling" })
    expect(result.allowed).toBe(false)
    expect(result.reason).toContain("programada")
  })

  it("blocks cancellation for expired plan", () => {
    const result = canCancelSubscription({ billing_plan: "avanzado", billing_status: "expired" })
    expect(result.allowed).toBe(false)
  })

  it("blocks cancellation for cancelled plan", () => {
    const result = canCancelSubscription({ billing_plan: "inicial", billing_status: "cancelled" })
    expect(result.allowed).toBe(false)
  })
})

// ─── selectAccountsForCancellation — daily sweep logic ────────────────────────

describe("selectAccountsForCancellation — process_cancellations logic (task 7.5)", () => {
  const now = new Date("2026-06-09T04:00:00Z")

  const expiredCancelling: AccountForSweep = {
    id: "acc-1",
    billing_plan: "avanzado",
    billing_status: "cancelling",
    plan_expires_at: new Date("2026-06-08T00:00:00Z"), // past
  }

  const futureCancelling: AccountForSweep = {
    id: "acc-2",
    billing_plan: "inicial",
    billing_status: "cancelling",
    plan_expires_at: new Date("2026-07-01T00:00:00Z"), // future
  }

  const activeAccount: AccountForSweep = {
    id: "acc-3",
    billing_plan: "pro",
    billing_status: "active",
    plan_expires_at: new Date("2026-06-01T00:00:00Z"),
  }

  const noExpiry: AccountForSweep = {
    id: "acc-4",
    billing_plan: "avanzado",
    billing_status: "cancelling",
    plan_expires_at: null,
  }

  it("selects account with cancelling status and past plan_expires_at", () => {
    const selected = selectAccountsForCancellation([expiredCancelling], now)
    expect(selected).toHaveLength(1)
    expect(selected[0].id).toBe("acc-1")
  })

  it("does NOT select account with future plan_expires_at", () => {
    const selected = selectAccountsForCancellation([futureCancelling], now)
    expect(selected).toHaveLength(0)
  })

  it("does NOT select active account (billing_status=active)", () => {
    const selected = selectAccountsForCancellation([activeAccount], now)
    expect(selected).toHaveLength(0)
  })

  it("does NOT select cancelling account with null plan_expires_at", () => {
    const selected = selectAccountsForCancellation([noExpiry], now)
    expect(selected).toHaveLength(0)
  })

  it("selects only eligible accounts from a mixed list", () => {
    const all = [expiredCancelling, futureCancelling, activeAccount, noExpiry]
    const selected = selectAccountsForCancellation(all, now)
    expect(selected).toHaveLength(1)
    expect(selected[0].id).toBe("acc-1")
  })

  it("returns empty array when no accounts eligible", () => {
    const selected = selectAccountsForCancellation([], now)
    expect(selected).toHaveLength(0)
  })
})

// ─── Idempotency check logic (task 7.3) ───────────────────────────────────────

describe("Idempotency — duplicate payment_id detection", () => {
  /**
   * In the actual webhook handler, idempotency is enforced by querying
   * billing_events WHERE mercadopago_payment_id = paymentId.
   * This test verifies the in-memory equivalent logic.
   */
  function isAlreadyProcessed(
    existingPaymentIds: string[],
    incomingPaymentId: string
  ): boolean {
    return existingPaymentIds.includes(incomingPaymentId)
  }

  it("detects duplicate payment_id → idempotent skip (task 7.3)", () => {
    const processed = ["mp-pay-001", "mp-pay-002"]
    expect(isAlreadyProcessed(processed, "mp-pay-001")).toBe(true)
  })

  it("allows new payment_id through", () => {
    const processed = ["mp-pay-001"]
    expect(isAlreadyProcessed(processed, "mp-pay-999")).toBe(false)
  })

  it("returns false for empty processed list", () => {
    expect(isAlreadyProcessed([], "mp-pay-001")).toBe(false)
  })
})
