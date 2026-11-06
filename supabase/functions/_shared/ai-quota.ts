// Shared AI quota helper for Edge Functions — C-02 plan-gating-engine.
//
// Enforces the monthly AI-query quota per plan BEFORE calling OpenAI, and
// increments the counter AFTER a successful call.
//
// billing-edge-effective-plan: the effective plan is resolved via
// `_shared/effective-plan.ts` (the DB-normative `rpc_my_effective_plan()`),
// NOT re-derived locally from `public.profiles`. The counters themselves
// (`ai_queries_used`, `ai_advice_used`, `usage_reset_at`) stay in `profiles`
// — out of scope for this change (D3/OQ-2) — so the `profiles` SELECT below
// is narrowed to those counter columns only.
//
// Usage in an Edge Function (after auth, before OpenAI):
//   const quota = await checkAiQuota(supabase, user.id, 'queries')
//   if (!quota.allowed) return jsonResponse(quota.body, 429)
//   ... call OpenAI ...
//   await incrementAiUsage(supabase, user.id, 'queries')

import { resolveEffectivePlan, type EffectivePlanClient } from "./effective-plan.ts"

type Counter = "queries" | "advice"

/** Contadores que se consumen por RESERVA atómica: el OCR (v31-ia-ratelimit-budget) y las consultas del Copiloto (ia-copilot-v2). */
export const RESERVE_COUNTERS = ["ocr", "queries"] as const
export type ReserveCounter = (typeof RESERVE_COUNTERS)[number]

interface QueryResult<T> {
  data: T | null
  error: { message: string } | null
}

interface AiUsageCounters {
  ai_queries_used: number | null
  ai_advice_used: number | null
  usage_reset_at: string | null
}

interface AiPlanLimits {
  max_ai_queries_per_month: number
  max_ai_advice_per_month: number
}

interface SingleRowQuery<T> {
  eq(column: string, value: string): { single(): PromiseLike<QueryResult<T>> }
}

interface SelectableTable<T> {
  select(columns: string): SingleRowQuery<T>
}

/**
 * Minimal structural shape of the Supabase client this module needs — no
 * `any` (project hard rule). Extends the effective-plan client so the same
 * real client (or the same test double) satisfies both.
 *
 * `rpc` is declared as a proper TS overload set (both signatures repeated
 * here, including the one inherited from `EffectivePlanClient`) — a derived
 * interface cannot just ADD an incompatible overload for a method it
 * inherits, it has to restate the full overload set for `extends` to type-check.
 */
export interface AiQuotaClient extends EffectivePlanClient {
  from(table: "profiles"): SelectableTable<AiUsageCounters>
  from(table: "plan_limits"): SelectableTable<AiPlanLimits>
  rpc(fn: "rpc_my_effective_plan"): PromiseLike<{ data: string | null; error: { message: string } | null }>
  rpc(
    fn: "rpc_increment_ai_usage",
    args: { p_user_id: string; p_counter: Counter },
  ): PromiseLike<{ data: unknown; error: unknown }>
  rpc(
    fn: "rpc_reserve_ai_usage",
    args: { p_counter: ReserveCounter },
  ): PromiseLike<{ data: unknown; error: unknown }>
}

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

/**
 * Checks whether the user can make another AI call of the given kind.
 * Returns `{ allowed: true, body: null }` if within quota,
 * or `{ allowed: false, body: {...} }` (HTTP 429 payload) if exceeded.
 */
export async function checkAiQuota(
  supabase: AiQuotaClient,
  userId: string,
  counter: Counter,
): Promise<QuotaResult> {
  const effectivePlan = await resolveEffectivePlan(supabase)

  const { data: profile, error: profErr } = await supabase
    .from("profiles")
    .select("ai_queries_used, ai_advice_used, usage_reset_at")
    .eq("id", userId)
    .single()

  // Fail open: if we can't read the counters, don't block the user. Only the
  // PLAN resolution is fail-closed (D5) — without a counter there is nothing
  // to compare against, and blocking here would be an availability failure,
  // not an authorization one.
  if (profErr || !profile) return { allowed: true, body: null }

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

/** Increments the user's AI usage counter after a successful call via an atomic DB-side RPC. */
export async function incrementAiUsage(
  supabase: AiQuotaClient,
  userId: string,
  counter: Counter,
): Promise<void> {
  await supabase.rpc("rpc_increment_ai_usage", { p_user_id: userId, p_counter: counter })
}

// ─── Reserva atómica (v31-ia-ratelimit-budget, D6) ───────────────────────────
//
// `checkAiQuota` + `incrementAiUsage` son dos pasos separados por la llamada a
// OpenAI (10 s o más): una ráfaga concurrente pasa entera el chequeo. Para el
// OCR la cuota se RESERVA antes de llamar, con un UPDATE condicional único en la
// base (`rpc_reserve_ai_usage`). A diferencia de `checkAiQuota` (fail-open), la
// reserva es FAIL-CLOSED: si no se puede resolver, no se llama a OpenAI (OQ-3).
//
// Usage (after auth + cheap rejections, BEFORE OpenAI), con el cliente del
// USUARIO (la RPC resuelve auth.uid()), nunca el de service role:
//   const r = await reserveAiUsage(supabase, 'ocr')
//   if (r.kind !== 'allowed') return jsonResponse(r.body, r.status, retryHeaders(r))

export type AiReservationResult =
  | { kind: "allowed" }
  | {
      kind: "denied"
      status: 429
      body:
        | { ok: false; error: "quota_exceeded"; resetAt: string | null; used: number; limit: number }
        | { ok: false; error: "rate_limited"; retryAfterSeconds: number }
      /** Presente sólo en `rate_limited`: valor del header `Retry-After`. */
      retryAfterSeconds?: number
    }
  | { kind: "unavailable"; status: 503; body: { ok: false; error: "quota_unavailable" } }

const UNAVAILABLE: AiReservationResult = {
  kind: "unavailable",
  status: 503,
  body: { ok: false, error: "quota_unavailable" },
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

/**
 * Traduce el `jsonb` de `rpc_reserve_ai_usage` al resultado del handler. Pura y
 * exportada para testearla: cualquier forma que no se reconozca por completo es
 * `unavailable` (503), nunca una concesión por omisión.
 */
export function mapAiReservation(data: unknown, error: unknown): AiReservationResult {
  if (error || !isRecord(data) || typeof data.allowed !== "boolean") return UNAVAILABLE
  if (data.allowed) return { kind: "allowed" }

  if (data.reason === "quota_exceeded") {
    if (typeof data.used !== "number" || typeof data.limit !== "number") return UNAVAILABLE
    return {
      kind: "denied",
      status: 429,
      body: {
        ok: false,
        error: "quota_exceeded",
        resetAt: typeof data.reset_at === "string" ? data.reset_at : null,
        used: data.used,
        limit: data.limit,
      },
    }
  }

  if (data.reason === "rate_limited") {
    const retry = data.retry_after_seconds
    if (typeof retry !== "number" || !Number.isFinite(retry) || retry < 1) return UNAVAILABLE
    return {
      kind: "denied",
      status: 429,
      body: { ok: false, error: "rate_limited", retryAfterSeconds: retry },
      retryAfterSeconds: retry,
    }
  }

  return UNAVAILABLE
}

/**
 * Reserva una unidad del contador para el usuario autenticado. Una reserva
 * concedida NO se devuelve (OQ-2): OpenAI factura la llamada aunque falle.
 */
export async function reserveAiUsage(
  supabase: AiQuotaClient,
  counter: ReserveCounter,
): Promise<AiReservationResult> {
  try {
    const { data, error } = await supabase.rpc("rpc_reserve_ai_usage", { p_counter: counter })
    return mapAiReservation(data, error)
  } catch (_err) {
    return UNAVAILABLE
  }
}
