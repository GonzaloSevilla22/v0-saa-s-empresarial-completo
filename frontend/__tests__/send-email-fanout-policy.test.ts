/**
 * Tests for the shared `all_users` fan-out allowlist used by the send-email
 * Edge Function (send-email-webhook-hardening, group 6 — ACTIVE per PO
 * sign-off 2026-07-31, OQ3 = sí).
 *
 * Same D5/D6 pattern as send-email-webhook-auth.test.ts and
 * edge-effective-plan.test.ts: imports the REAL file
 * `supabase/functions/_shared/email-fanout-policy.ts` by relative path
 * instead of re-declaring the allowlist rule inside the test.
 *
 * Run: pnpm vitest run __tests__/send-email-fanout-policy.test.ts
 */

import { describe, it, expect } from "vitest"
import { isAllUsersFanoutAllowed } from "../../supabase/functions/_shared/email-fanout-policy"

describe("isAllUsersFanoutAllowed (task 6.2 — RED/GREEN: allowlisted event types)", () => {
  it("allows 'meeting_notice'", () => {
    expect(isAllUsersFanoutAllowed("meeting_notice")).toBe(true)
  })

  it("allows 'pool_notice'", () => {
    expect(isAllUsersFanoutAllowed("pool_notice")).toBe(true)
  })
})

describe("isAllUsersFanoutAllowed (task 6.2 — triangulation: everything else is rejected)", () => {
  it("rejects 'welcome' (never intended for mass fan-out)", () => {
    expect(isAllUsersFanoutAllowed("welcome")).toBe(false)
  })

  it("rejects 'new_user_admin_notice'", () => {
    expect(isAllUsersFanoutAllowed("new_user_admin_notice")).toBe(false)
  })

  it("rejects an arbitrary/unknown event_type", () => {
    expect(isAllUsersFanoutAllowed("anything_else")).toBe(false)
  })

  it("rejects an empty string", () => {
    expect(isAllUsersFanoutAllowed("")).toBe(false)
  })

  it("is case-sensitive — rejects a differently-cased match", () => {
    expect(isAllUsersFanoutAllowed("Meeting_Notice")).toBe(false)
  })
})
