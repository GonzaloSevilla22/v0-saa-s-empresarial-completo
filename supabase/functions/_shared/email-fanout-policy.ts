// Shared `all_users` fan-out allowlist for Edge Functions — send-email-webhook-hardening.
//
// GROUP 6 (ACTIVE per PO sign-off 2026-07-31, OQ3 = sí; design.md §Risks,
// §Open Questions OQ3, tasks.md §6). Any row inserted into `email_logs` with
// `recipient = 'all_users'` makes `send-email` call `auth.admin.listUsers()`
// and mail EVERY real user. Once the webhook is authenticated (D3), this is
// no longer reachable from outside, but it remains an internal-accident risk:
// a wrong `INSERT` into `email_logs` would still trigger an unconfirmed mass
// send. This allowlist restricts the fan-out to the `event_type`s that are
// actually meant to reach every user (community notices); any other
// `event_type` with `recipient = 'all_users'` is rejected without sending.
//
// D5/D6 pattern: this module is pure and injectable — ZERO references to
// `Deno.*` at module scope — so it is importable by vitest via a relative
// path (frontend/__tests__/send-email-fanout-policy.test.ts) without
// re-declaring the rule inside the test.

const ALL_USERS_EVENT_TYPE_ALLOWLIST = ["meeting_notice", "pool_notice"] as const

/**
 * Whether `event_type` is allowed to fan out to `recipient = 'all_users'`.
 * Comparison is case-sensitive and exact — `event_type` values are internal
 * enum-like strings controlled by this codebase's producers, not user input.
 */
export function isAllUsersFanoutAllowed(eventType: string): boolean {
  return (ALL_USERS_EVENT_TYPE_ALLOWLIST as readonly string[]).includes(eventType)
}
