/**
 * idle-server.ts — server-side idle enforcement helpers.
 *
 * These are pure, request-free functions used by the middleware to decide
 * whether a session is idle. Keeping the decision logic here (not inline in
 * middleware.ts) lets us unit-test it without a full NextRequest.
 *
 * Design decisions honored:
 *  - Decision 3: single source of truth — callers pass IDLE_TIMEOUT_MS; no literal here.
 *  - Decision 6: missing/unparseable cookie ⇒ "seed" (treat as just-active), never logout.
 *  - Decision 8: Node runtime; no browser APIs at module scope.
 */

import { isServerSideIdle, IDLE_TIMEOUT_MS } from "@/lib/auth/idle-config"

/** Result returned by `evaluateIdle`. */
export type IdleEvalResult =
  | { action: "proceed" }
  | { action: "logout" }
  | { action: "seed" } // missing/unparseable cookie → seed lastActivity = now on response

/**
 * Safely parse the raw `lastActivity` cookie value into a numeric timestamp.
 *
 * Returns `null` for any value that is absent, non-numeric, NaN, or non-finite.
 * Parsing uses `Number(value)` + `Number.isFinite` guard (Decision 6).
 */
export function parseLastActivityCookie(value: string | undefined): number | null {
  if (value === undefined || value === "") return null
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return null
  return parsed
}

/**
 * Pure middleware idle decision: given the raw cookie string and `now`,
 * returns what the middleware should do:
 *   - "proceed"  — session is fresh, continue normally
 *   - "logout"   — session is stale, force idle logout
 *   - "seed"     — cookie missing/unparseable; treat as just-active and seed it
 *
 * This is the ONLY place that calls `isServerSideIdle`. Callers must NOT
 * inline the idle check — they should call `evaluateIdle` instead.
 *
 * @param cookieValue  Raw value of the `auth:last-activity` cookie (or undefined if absent).
 * @param now          Current timestamp in ms. Pass `Date.now()` from the caller.
 */
export function evaluateIdle(cookieValue: string | undefined, now: number): IdleEvalResult {
  const lastActivity = parseLastActivityCookie(cookieValue)

  // Decision 6: missing or unparseable ⇒ seed (loop safety)
  if (lastActivity === null) return { action: "seed" }

  // Decision 3: use the imported constant — no literal here
  if (isServerSideIdle(lastActivity, now, IDLE_TIMEOUT_MS)) return { action: "logout" }

  return { action: "proceed" }
}
