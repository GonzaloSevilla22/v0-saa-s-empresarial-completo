/**
 * Tests for the shared webhook-secret verification module used by the
 * send-email Edge Function (send-email-webhook-hardening, D5).
 *
 * Follows the D6 pattern established by edge-effective-plan.test.ts: this
 * file imports the REAL file `supabase/functions/_shared/webhook-auth.ts` by
 * relative path instead of re-declaring the verification rule locally (the
 * antipattern documented in ai-precio.test.ts). D5 requires that module to be
 * pure and injectable (no `Deno.*` at module scope) so a future divergence
 * between the function and this test would show up as a failure instead of
 * passing silently.
 *
 * Run: pnpm vitest run __tests__/send-email-webhook-auth.test.ts
 */

import { describe, it, expect } from "vitest"
import { verifyWebhookSecret, type WebhookAuthResult } from "../../supabase/functions/_shared/webhook-auth"

describe("verifyWebhookSecret (task 2.1 — RED: correct secret)", () => {
  it("returns { ok: true } when the provided secret matches the expected one", () => {
    const result: WebhookAuthResult = verifyWebhookSecret("correct-secret", "correct-secret")
    expect(result).toEqual({ ok: true })
  })
})

describe("verifyWebhookSecret (task 2.3 — triangulation: breaks any convenience fake)", () => {
  it("returns 401 unauthorized when the provided secret is incorrect", () => {
    expect(verifyWebhookSecret("wrong-secret", "correct-secret")).toEqual({
      ok: false,
      status: 401,
      reason: "unauthorized",
    })
  })

  it("returns 401 unauthorized when the header is absent (null)", () => {
    expect(verifyWebhookSecret(null, "correct-secret")).toEqual({
      ok: false,
      status: 401,
      reason: "unauthorized",
    })
  })

  it("returns 503 misconfigured when the expected secret is absent (undefined) — never fail-open", () => {
    expect(verifyWebhookSecret("anything", undefined)).toEqual({
      ok: false,
      status: 503,
      reason: "misconfigured",
    })
  })

  it("returns 503 misconfigured when the expected secret is an empty string — empty is not a valid secret", () => {
    expect(verifyWebhookSecret("anything", "")).toEqual({
      ok: false,
      status: 503,
      reason: "misconfigured",
    })
  })

  it("returns 401 unauthorized when the provided secret is empty against a non-empty expected value", () => {
    expect(verifyWebhookSecret("", "correct-secret")).toEqual({
      ok: false,
      status: 401,
      reason: "unauthorized",
    })
  })
})

describe("verifyWebhookSecret (task 2.4 — triangulation: constant-time comparison does not change the functional result)", () => {
  it("rejects a value of the SAME length as expected but different content", () => {
    // Same length as "correct-secret" (14 chars), differs only in the last char.
    expect(verifyWebhookSecret("correct-secreX", "correct-secret")).toEqual({
      ok: false,
      status: 401,
      reason: "unauthorized",
    })
  })

  it("rejects a value SHORTER than expected", () => {
    expect(verifyWebhookSecret("short", "correct-secret")).toEqual({
      ok: false,
      status: 401,
      reason: "unauthorized",
    })
  })

  it("rejects a value LONGER than expected", () => {
    expect(verifyWebhookSecret("correct-secret-plus-extra", "correct-secret")).toEqual({
      ok: false,
      status: 401,
      reason: "unauthorized",
    })
  })
})
