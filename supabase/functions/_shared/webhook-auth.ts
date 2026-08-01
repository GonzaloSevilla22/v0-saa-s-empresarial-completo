// Shared webhook-secret verification for Edge Functions — send-email-webhook-hardening.
//
// Closes the open relay on `send-email` (design.md §Context): the function
// must reject any request that does not carry the shared secret the
// production trigger authenticates with, BEFORE parsing the payload or
// calling the mail provider.
//
// D5 (design.md): this module MUST stay pure and injectable — ZERO
// references to `Deno.*` at module scope. That single restriction is what
// makes it importable by vitest via a relative path (see
// frontend/__tests__/send-email-webhook-auth.test.ts): the test exercises
// this exact file, so a future reimplementation of the rule inside the Edge
// Function handler would show up as a divergence instead of passing
// silently (the antipattern documented in ai-precio.test.ts).

export type WebhookAuthResult =
  | { ok: true }
  | { ok: false; status: 401 | 503; reason: "unauthorized" | "misconfigured" }

/**
 * Verifies the `x-webhook-secret` header value against the secret configured
 * in the Edge Function's environment.
 *
 * Three outcomes, deliberately distinguished (D3, design.md):
 * - `expected` missing/empty → 503 `misconfigured`. This is an operational
 *   error (incomplete deploy), not an attack — fail-closed, never fail-open:
 *   an unconfigured secret must never be treated as "anything goes".
 * - `provided` missing, or not matching `expected` → 401 `unauthorized`.
 * - Otherwise → `{ ok: true }`.
 *
 * The comparison against a correct-length secret runs in constant time
 * relative to the byte content, so response latency does not leak how many
 * leading bytes of the secret were guessed correctly.
 */
export function verifyWebhookSecret(
  provided: string | null,
  expected: string | undefined,
): WebhookAuthResult {
  if (!expected) {
    return { ok: false, status: 503, reason: "misconfigured" }
  }

  if (!provided || !constantTimeEquals(provided, expected)) {
    return { ok: false, status: 401, reason: "unauthorized" }
  }

  return { ok: true }
}

/**
 * Constant-time string comparison. Deliberately avoids `===`/`!==`, which
 * short-circuit on the first mismatching byte and can leak timing
 * information proportional to how much of the secret was guessed correctly.
 * Comparing lengths first is safe to short-circuit on: it reveals only the
 * secret's length, which is not sensitive (the secret is a fixed-length
 * random value, `openssl rand -hex 32`).
 */
function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false
  }

  let diff = 0
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  }

  return diff === 0
}
