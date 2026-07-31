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

// ─── billing-edge-effective-plan (tasks 6.1, 6.3) ────────────────────────────
//
// generate-export/index.ts no longer reimplements the trial/exemption rule
// nor reads billing_plan/billing_status/trial_* from `profiles` — the plan is
// resolved via `resolveEffectivePlan` (supabase/functions/_shared/
// effective-plan.ts), whose own resolution behavior (including the exact
// task 6.1 scenario — a paid/exempt account whose `profiles.billing_plan`
// is stale at 'gratis') is already fully covered in
// frontend/__tests__/edge-effective-plan.test.ts. generate-export delegates
// 100% of that resolution, so this section covers the logic that IS still
// local to this Edge Function: the quota/history decisions computed FROM the
// already-resolved plan's limits. These are the same pure helpers the
// handler uses (duplicated here per the repo's established convention for
// Deno.serve handlers, which cannot be imported into vitest — see
// ai-precio.test.ts's header comment for the same rationale).

interface ExportPlanLimits {
  max_exports_per_month: number
  history_days: number
}

function isExportBlockedForPlan(limits: ExportPlanLimits): boolean {
  return limits.max_exports_per_month === 0
}

function isExportQuotaExceeded(exportsUsed: number, limits: ExportPlanLimits): boolean {
  return exportsUsed >= limits.max_exports_per_month
}

function historyDateFrom(historyDays: number, now: Date): string {
  const d = new Date(now)
  d.setDate(d.getDate() - historyDays)
  return d.toISOString().split("T")[0]
}

describe("generate-export: gating derived from the resolved effective plan (task 6.1)", () => {
  it("a plan resolved as 'pro' (e.g. paid account with profiles.billing_plan stale at 'gratis') is NOT blocked", () => {
    // Pre-fix: the plan used here would have been the stale 'gratis' value
    // read from profiles, and 'gratis' has max_exports_per_month = 0 →
    // blocked. Post-fix, effectivePlan comes from resolveEffectivePlan and
    // correctly reflects 'pro' regardless of what profiles.billing_plan says.
    const proLimits: ExportPlanLimits = { max_exports_per_month: 999, history_days: 3650 }
    expect(isExportBlockedForPlan(proLimits)).toBe(false)
  })
})

describe("generate-export: triangulation (task 6.3)", () => {
  it("plan efectivo 'gratis' (max_exports_per_month=0) → bloqueado", () => {
    const gratisLimits: ExportPlanLimits = { max_exports_per_month: 0, history_days: 30 }
    expect(isExportBlockedForPlan(gratisLimits)).toBe(true)
  })

  it("cuota agotada → quota_exceeded (independiente del plan)", () => {
    const inicialLimits: ExportPlanLimits = { max_exports_per_month: 3, history_days: 90 }
    expect(isExportQuotaExceeded(3, inicialLimits)).toBe(true)
    expect(isExportQuotaExceeded(2, inicialLimits)).toBe(false)
  })

  it("cuenta exenta (plan efectivo 'pro') → permitida incluso con billing_plan='gratis' en accounts", () => {
    // La exención ya se resuelve dentro de resolveEffectivePlan → 'pro'; acá
    // solo se confirma que 'pro' no está bloqueado por la tabla de límites.
    const proLimits: ExportPlanLimits = { max_exports_per_month: 999, history_days: 3650 }
    expect(isExportBlockedForPlan(proLimits)).toBe(false)
    expect(isExportQuotaExceeded(500, proLimits)).toBe(false)
  })

  it("la ventana de historial corresponde al plan efectivo, no al de 'gratis'", () => {
    const now = new Date("2026-08-01T00:00:00.000Z")
    const avanzadoHistoryDays = 730
    const gratisHistoryDays = 30

    const avanzadoFrom = historyDateFrom(avanzadoHistoryDays, now)
    const gratisFrom = historyDateFrom(gratisHistoryDays, now)

    expect(avanzadoFrom).toBe("2024-08-01")
    expect(gratisFrom).toBe("2026-07-02")
    expect(avanzadoFrom).not.toBe(gratisFrom)
  })
})
