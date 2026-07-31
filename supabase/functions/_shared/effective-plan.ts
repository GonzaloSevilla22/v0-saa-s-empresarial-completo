// Shared effective-plan resolution for Edge Functions — billing-edge-effective-plan.
//
// Single source of truth for the plan an Edge Function should gate against.
// Delegates to the DB-normative `rpc_my_effective_plan()` (D1/D2 — wraps
// `public.get_effective_plan`, the definition introduced by billing-pro-trial)
// instead of re-deriving the trial/exemption rule locally from
// `public.profiles`, which is the divergence this change fixes.
//
// D6 (design.md): this module MUST stay pure and injectable — it receives the
// Supabase client as a parameter and has ZERO references to `Deno.*` at module
// scope. That single restriction is what makes it importable by vitest via a
// relative path (see frontend/__tests__/edge-effective-plan.test.ts): the test
// exercises this exact file, so a future reimplementation of the rule inside
// an Edge Function would show up as a divergence instead of passing silently.

export type EffectivePlan = "gratis" | "inicial" | "avanzado" | "pro"

const KNOWN_PLANS: readonly EffectivePlan[] = ["gratis", "inicial", "avanzado", "pro"]

function isKnownPlan(value: string): value is EffectivePlan {
  return (KNOWN_PLANS as readonly string[]).includes(value)
}

/**
 * Minimal structural shape of the Supabase client this module needs —
 * deliberately narrow (no `any`, D2 hard rule of the project) to the single
 * RPC call it makes.
 */
export interface EffectivePlanClient {
  rpc(
    fn: "rpc_my_effective_plan",
  ): Promise<{ data: string | null; error: { message: string } | null }>
}

/**
 * Resolves the effective plan of the CALLING user's account.
 *
 * There is no `account_id` parameter — by construction, a caller cannot ask
 * for the plan of a different account (spec: "Una Edge Function no puede
 * consultar el plan de otra cuenta"). The account is derived server-side by
 * `rpc_my_effective_plan()` from `auth.uid()`.
 *
 * Fail-closed (D5): any RPC error, a null/empty response, or an unrecognized
 * value degrades to `'gratis'` — never to a higher plan — and errors are
 * logged via `console.error` so the degradation is observable in the Edge
 * Function's logs instead of silent.
 */
export async function resolveEffectivePlan(
  supabase: EffectivePlanClient,
): Promise<EffectivePlan> {
  const { data, error } = await supabase.rpc("rpc_my_effective_plan")

  if (error) {
    console.error("[effective-plan] rpc_my_effective_plan failed:", error.message)
    return "gratis"
  }

  if (!data || !isKnownPlan(data)) {
    return "gratis"
  }

  return data
}
