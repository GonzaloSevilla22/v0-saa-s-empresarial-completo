/**
 * Unit tests for C-10 subscription-ui-upgrade-flow — billing logic.
 *
 * Tests cover pure TypeScript functions extracted from the route handlers,
 * PLUS (v31-mp-upgrade-webhook-fix) route-handler-level tests for the
 * legacy webhook forwarder and the preference-creation notification_url —
 * those mock `@/lib/supabase/server` / `@/lib/mercadopago` and stub global
 * `fetch`, but still make no real Supabase/MercadoPago/HTTP calls.
 *
 * SQL/RLS tests (webhook idempotency, process_cancellations trigger) require
 * `npx supabase test db` with a real instance — those are integration tests
 * and live in supabase/tests/ when available.
 */

import { readFileSync } from "node:fs"
import path from "node:path"
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import type { Plan } from "@/lib/types"

// ─── Mocks for the preferences route (must be declared before the route  ───
// ─── import below — vi.mock calls are hoisted by Vitest's transform).    ───

const { mockGetUser, mockPlanLimitsSingle, mockPreferenceCreate } = vi.hoisted(() => ({
  mockGetUser: vi.fn(),
  mockPlanLimitsSingle: vi.fn(),
  mockPreferenceCreate: vi.fn(),
}))

vi.mock("@/lib/supabase/server", () => ({
  createClient: () => ({
    auth: { getUser: mockGetUser },
    from: () => ({
      select: () => ({
        eq: () => ({
          single: mockPlanLimitsSingle,
        }),
      }),
    }),
  }),
}))

vi.mock("@/lib/mercadopago", () => ({
  getMp: () => ({}),
  Preference: vi.fn().mockImplementation(function MockPreference() {
    return { create: mockPreferenceCreate }
  }),
}))

import { POST as webhookForwardPOST } from "@/app/api/billing/webhook/route"
import { POST as preferencesPOST } from "@/app/api/billing/preferences/route"

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

// ─── POST /api/billing/webhook — legacy route as stateless forwarder ─────────
// v31-mp-upgrade-webhook-fix D1/D2: MercadoPago bakes notification_url into
// every preference at creation time, so preferences issued before this
// change keep notifying this URL for their whole lifetime. It must relay
// raw bytes to the backend, never write to Supabase again.

describe("POST /api/billing/webhook — legacy route as stateless forwarder (D1, D2)", () => {
  const BACKEND_URL = "https://backend.example.com"
  let originalBackendUrl: string | undefined

  beforeEach(() => {
    originalBackendUrl = process.env.NEXT_PUBLIC_BACKEND_URL
    process.env.NEXT_PUBLIC_BACKEND_URL = BACKEND_URL
  })

  afterEach(() => {
    if (originalBackendUrl === undefined) {
      delete process.env.NEXT_PUBLIC_BACKEND_URL
    } else {
      process.env.NEXT_PUBLIC_BACKEND_URL = originalBackendUrl
    }
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it("relays the raw body bytes and both signature headers to the backend webhook (task 2.1)", async () => {
    const rawBody = JSON.stringify({ type: "payment", data: { id: "pay-123" } })
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }))
    vi.stubGlobal("fetch", fetchMock)

    const req = new Request("http://localhost/api/billing/webhook", {
      method: "POST",
      headers: { "x-signature": "ts=1,v1=abc", "x-request-id": "req-1" },
      body: rawBody,
    })

    await webhookForwardPOST(req)

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe(`${BACKEND_URL}/payments/webhook`)
    expect(init.body).toBe(rawBody)
    expect((init.headers as Record<string, string>)["x-signature"]).toBe("ts=1,v1=abc")
    expect((init.headers as Record<string, string>)["x-request-id"]).toBe("req-1")
    // Origin marker for the backend's traceability requirement (payment-webhook
    // spec) — not part of the HMAC-signed template, safe to add per D2.
    expect((init.headers as Record<string, string>)["x-relay-source"]).toBe("legacy-frontend")
  })

  it("relays a payload with non-alphabetical key order and unicode escapes byte-for-byte — no re-serialization (task 2.3, D2)", async () => {
    // If the route did JSON.parse -> JSON.stringify, key order and escape
    // style would normalize and this exact string would no longer match.
    const rawBody = '{"data":{"id":"pay-999"},"type":"payment","note":"caf\\u00e9 con leche"}'
    const fetchMock = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }))
    vi.stubGlobal("fetch", fetchMock)

    const req = new Request("http://localhost/api/billing/webhook", {
      method: "POST",
      headers: { "x-signature": "ts=2,v1=def", "x-request-id": "req-2" },
      body: rawBody,
    })

    await webhookForwardPOST(req)

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(init.body).toBe(rawBody)
  })

  it("does not import the Supabase client — the relay never touches the database (task 2.4, D1)", () => {
    const source = readFileSync(
      path.resolve(__dirname, "../app/api/billing/webhook/route.ts"),
      "utf-8"
    )
    expect(source).not.toMatch(/@\/lib\/supabase\/server/)
    expect(source).not.toMatch(/createClient/)
  })

  it("propagates an error status from the backend instead of masking it with 200 (task 2.5)", async () => {
    const rawBody = JSON.stringify({ type: "payment", data: { id: "pay-400" } })
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: false, error: "Firma inválida" }), { status: 400 })
    )
    vi.stubGlobal("fetch", fetchMock)

    const req = new Request("http://localhost/api/billing/webhook", {
      method: "POST",
      headers: { "x-signature": "ts=3,v1=bad", "x-request-id": "req-3" },
      body: rawBody,
    })

    const res = await webhookForwardPOST(req)
    expect(res.status).toBe(400)
  })

  it("fails closed without NEXT_PUBLIC_BACKEND_URL and never attempts a malformed-URL fetch (task 2.6)", async () => {
    delete process.env.NEXT_PUBLIC_BACKEND_URL
    const fetchMock = vi.fn()
    vi.stubGlobal("fetch", fetchMock)

    const req = new Request("http://localhost/api/billing/webhook", {
      method: "POST",
      headers: { "x-signature": "ts=4,v1=xyz", "x-request-id": "req-4" },
      body: JSON.stringify({ type: "payment", data: { id: "pay-nobackend" } }),
    })

    const res = await webhookForwardPOST(req)
    expect(res.status).toBe(500)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it("traces the relayed payment id and the backend status, without leaking secrets (task 2.7)", async () => {
    const rawBody = JSON.stringify({ type: "payment", data: { id: "pay-trace-1" } })
    const fetchMock = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }))
    vi.stubGlobal("fetch", fetchMock)
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {})

    const req = new Request("http://localhost/api/billing/webhook", {
      method: "POST",
      headers: { "x-signature": "ts=5,v1=trace", "x-request-id": "req-5" },
      body: rawBody,
    })
    await webhookForwardPOST(req)

    const logged = logSpy.mock.calls.map((c) => c.join(" ")).join("\n")
    expect(logged).toContain("pay-trace-1")
    expect(logged).toContain("200")
    expect(logged).not.toContain("MERCADOPAGO_WEBHOOK_SECRET")
  })
})

// ─── POST /api/billing/preferences — notification_url targets the backend ───
// v31-mp-upgrade-webhook-fix D3: notification_url is baked into the
// preference at creation time and can never be changed afterward, so new
// preferences must point straight at the backend that actually accredits.

describe("POST /api/billing/preferences — notification_url targets the backend (D3)", () => {
  const BACKEND_URL = "https://backend.example.com"
  let originalBackendUrl: string | undefined
  let originalAppUrl: string | undefined

  beforeEach(() => {
    originalBackendUrl = process.env.NEXT_PUBLIC_BACKEND_URL
    originalAppUrl = process.env.NEXT_PUBLIC_APP_URL
    process.env.NEXT_PUBLIC_BACKEND_URL = BACKEND_URL
    process.env.NEXT_PUBLIC_APP_URL = "https://app.example.com"

    mockGetUser.mockReset().mockResolvedValue({ data: { user: { id: "user-1" } }, error: null })
    mockPlanLimitsSingle.mockReset().mockResolvedValue({
      data: { plan: "avanzado", price_monthly: 1500, price_ars_annual: 15000 },
      error: null,
    })
    mockPreferenceCreate
      .mockReset()
      .mockResolvedValue({ id: "pref-1", init_point: "https://mp.example.com/init" })
  })

  afterEach(() => {
    if (originalBackendUrl === undefined) delete process.env.NEXT_PUBLIC_BACKEND_URL
    else process.env.NEXT_PUBLIC_BACKEND_URL = originalBackendUrl
    if (originalAppUrl === undefined) delete process.env.NEXT_PUBLIC_APP_URL
    else process.env.NEXT_PUBLIC_APP_URL = originalAppUrl
  })

  it("sends notification_url pointing at the backend webhook, not the legacy frontend route (task 3.1)", async () => {
    const req = new Request("http://localhost/api/billing/preferences", {
      method: "POST",
      body: JSON.stringify({ plan: "avanzado" }),
    })

    await preferencesPOST(req)

    expect(mockPreferenceCreate).toHaveBeenCalledTimes(1)
    const [{ body }] = mockPreferenceCreate.mock.calls[0]
    expect(body.notification_url).toBe(`${BACKEND_URL}/payments/webhook`)
    expect(body.notification_url).not.toMatch(/\/api\/billing\//)
  })

  it("fails closed without NEXT_PUBLIC_BACKEND_URL and never calls the MercadoPago API (task 3.3, D3)", async () => {
    delete process.env.NEXT_PUBLIC_BACKEND_URL
    const req = new Request("http://localhost/api/billing/preferences", {
      method: "POST",
      body: JSON.stringify({ plan: "avanzado" }),
    })

    const res = await preferencesPOST(req)
    expect(res.status).toBe(500)
    expect(mockPreferenceCreate).not.toHaveBeenCalled()
  })

  // qa-integral-modulos G10 (H21c): el catch tapaba el motivo real con
  // "Error interno del servidor" — el usuario del QA vio eso mientras la
  // consola tenía la explicación completa. El detalle se propaga.
  it("propaga el detalle del fallo en lugar del 500 genérico (G10/H21c)", async () => {
    mockPreferenceCreate.mockRejectedValue(new Error("invalid access token"))
    const req = new Request("http://localhost/api/billing/preferences", {
      method: "POST",
      body: JSON.stringify({ plan: "avanzado" }),
    })

    const res = await preferencesPOST(req)
    expect(res.status).toBe(500)
    const body = (await res.json()) as { ok: boolean; error?: string }
    expect(body.ok).toBe(false)
    expect(body.error).toContain("invalid access token")
    expect(body.error).not.toBe("Error interno del servidor")
  })

  it("keeps back_urls pointing at the frontend app URL — user navigation, not server notifications (task 3.4)", async () => {
    const req = new Request("http://localhost/api/billing/preferences", {
      method: "POST",
      body: JSON.stringify({ plan: "avanzado" }),
    })

    await preferencesPOST(req)

    const [{ body }] = mockPreferenceCreate.mock.calls[0]
    expect(body.back_urls.success).toBe("https://app.example.com/planes/success")
    expect(body.back_urls.failure).toBe("https://app.example.com/planes/failure")
  })
})
