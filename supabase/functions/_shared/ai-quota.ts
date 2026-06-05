// Shared AI quota helper for Edge Functions — C-02 plan-gating-engine.
//
// Enforces the monthly AI-query quota per plan BEFORE calling OpenAI, and
// increments the counter AFTER a successful call. Uses the same effective-plan
// logic as the client (trial-aware).
//
// Usage in an Edge Function (after auth, before OpenAI):
//   const quota = await checkAiQuota(supabase, user.id, 'queries')
//   if (!quota.allowed) return jsonResponse(quota.body, 429)
//   ... call OpenAI ...
//   await incrementAiUsage(supabase, user.id, 'queries')

// deno-lint-ignore no-explicit-any
type SupabaseClient = any

type Plan = "gratis" | "inicial" | "avanzado" | "pro"
type Counter = "queries" | "advice"

interface QuotaResult {
  allowed: boolean
  body: {
    ok: false
    error: "quota_exceeded"
    resetAt: string | null
    used: number
    limit: number
  } | null
}

/** Trial-aware effective plan (mirrors lib/plan-utils.ts getEffectivePlan). */
function getEffectivePlan(profile: {
  billing_plan: string | null
  billing_status: string | null
  trial_plan: string | null
  trial_expires_at: string | null
}): Plan {
  const now = new Date()
  const trialActive =
    profile.billing_status === "trialing" &&
    profile.trial_plan != null &&
    profile.trial_expires_at != null &&
    new Date(profile.trial_expires_at) > now
  const plan = trialActive ? profile.trial_plan : profile.billing_plan
  return (plan ?? "gratis") as Plan
}

/**
 * Checks whether the user can make another AI call of the given kind.
 * Returns `{ allowed: true, body: null }` if within quota,
 * or `{ allowed: false, body: {...} }` (HTTP 429 payload) if exceeded.
 */
export async function checkAiQuota(
  supabase: SupabaseClient,
  userId: string,
  counter: Counter,
): Promise<QuotaResult> {
  const { data: profile, error: profErr } = await supabase
    .from("profiles")
    .select("billing_plan, billing_status, trial_plan, trial_expires_at, ai_queries_used, ai_advice_used, usage_reset_at")
    .eq("id", userId)
    .single()

  // Fail open: if we can't read the profile, don't block the user.
  if (profErr || !profile) return { allowed: true, body: null }

  const effectivePlan = getEffectivePlan(profile)

  const { data: limits, error: limErr } = await supabase
    .from("plan_limits")
    .select("max_ai_queries_per_month, max_ai_advice_per_month")
    .eq("plan", effectivePlan)
    .single()

  // Fail open if limits are unavailable.
  if (limErr || !limits) return { allowed: true, body: null }

  const used  = counter === "queries" ? (profile.ai_queries_used ?? 0) : (profile.ai_advice_used ?? 0)
  const limit = counter === "queries" ? limits.max_ai_queries_per_month : limits.max_ai_advice_per_month

  if (used >= limit) {
    return {
      allowed: false,
      body: {
        ok: false,
        error: "quota_exceeded",
        resetAt: profile.usage_reset_at ?? null,
        used,
        limit,
      },
    }
  }

  return { allowed: true, body: null }
}

/** Increments the user's AI usage counter after a successful call. */
export async function incrementAiUsage(
  supabase: SupabaseClient,
  userId: string,
  counter: Counter,
): Promise<void> {
  const column = counter === "queries" ? "ai_queries_used" : "ai_advice_used"
  // Read-modify-write. Acceptable for the MVP; a DB-side atomic increment RPC
  // can replace this in C-04 if concurrency becomes a concern.
  const { data } = await supabase
    .from("profiles")
    .select(column)
    .eq("id", userId)
    .single()
  const current = (data?.[column] as number | undefined) ?? 0
  await supabase
    .from("profiles")
    .update({ [column]: current + 1 })
    .eq("id", userId)
}
