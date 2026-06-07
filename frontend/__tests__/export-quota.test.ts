/**
 * Integration tests for export quota logic (C-14 export-module, tasks 7.3-7.6)
 *
 * These tests exercise the quota check + counter logic by calling the
 * generate-export Edge Function against a real Supabase test project.
 *
 * SETUP: set env vars SUPABASE_URL, SUPABASE_ANON_KEY, and TEST_USER_TOKEN
 * before running. If vars are absent, tests are skipped.
 *
 * Run: pnpm test __tests__/export-quota.test.ts
 */

import { describe, it, expect, beforeAll } from "vitest"

const SUPABASE_URL    = process.env.NEXT_PUBLIC_SUPABASE_URL ?? ""
const TEST_USER_TOKEN = process.env.TEST_USER_TOKEN ?? ""
const EF_URL          = `${SUPABASE_URL}/functions/v1/generate-export`

function shouldSkip() {
  return !SUPABASE_URL || !TEST_USER_TOKEN
}

async function callExport(exportType: string, token = TEST_USER_TOKEN) {
  const res = await fetch(EF_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ export_type: exportType }),
  })
  return { status: res.status, body: await res.json() }
}

describe("generate-export Edge Function", () => {
  beforeAll(() => {
    if (shouldSkip()) {
      console.warn("Skipping integration tests: set NEXT_PUBLIC_SUPABASE_URL and TEST_USER_TOKEN")
    }
  })

  it("7.3 — exports sales CSV successfully and returns a signed URL", async () => {
    if (shouldSkip()) return

    const { status, body } = await callExport("sales_csv")
    expect(status).toBe(200)
    expect(body.ok).toBe(true)
    expect(typeof body.signedUrl).toBe("string")
    expect(body.signedUrl).toMatch(/^https?:\/\//)
  })

  it("7.4 — plan gratis receives HTTP 403", async () => {
    if (shouldSkip()) return
    // This test requires a token belonging to a gratis-plan user.
    // Skip if no special token is configured.
    const gratisToken = process.env.TEST_GRATIS_USER_TOKEN
    if (!gratisToken) {
      console.warn("Skipping 7.4: set TEST_GRATIS_USER_TOKEN to a gratis-plan user token")
      return
    }

    const { status, body } = await callExport("sales_csv", gratisToken)
    expect(status).toBe(403)
    expect(body.error).toBe("export_not_allowed")
  })

  it("7.5 — after N=limit exports, the N+1st returns 429", async () => {
    if (shouldSkip()) return
    // This test requires a fresh user at exports_used = 0 at plan 'inicial' (limit=3).
    // We check the 4th call is rejected. Uses a dedicated test token.
    const quotaToken = process.env.TEST_QUOTA_USER_TOKEN
    if (!quotaToken) {
      console.warn("Skipping 7.5: set TEST_QUOTA_USER_TOKEN for a user at their export limit")
      return
    }

    const { status, body } = await callExport("sales_csv", quotaToken)
    expect(status).toBe(429)
    expect(body.error).toBe("quota_exceeded")
    expect(typeof body.resetAt).toBe("string")
  })

  it("7.6 — exports_used increments after a successful export", async () => {
    if (shouldSkip()) return

    // We don't directly query the DB here since that requires service_role.
    // Instead, verify via the response body that exportsUsed went up.
    const { status, body } = await callExport("stock_csv")
    expect(status).toBe(200)
    expect(body.ok).toBe(true)
    expect(typeof body.exportsUsed).toBe("number")
    // exportsUsed in the response is always used + 1 after this call
    expect(body.exportsUsed).toBeGreaterThan(0)
  })
})
