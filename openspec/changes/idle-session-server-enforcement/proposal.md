## Why

The shipped `idle-session-timeout` capability (PR #217) logs an inactive user out after 20 minutes — but the enforcement lives **entirely in client-side JavaScript** (a React hook + `setTimeout`). If that timer never fires — a crashed/restored tab, a session resumed from disk, JS disabled or broken, an SSR navigation that bypasses the React lifecycle — an idle authenticated session keeps working indefinitely, because Supabase silently refreshes the token on every middleware request. For a SaaS that holds financial and fiscal data on shared/unattended devices, sole reliance on client cooperation is a gap. This change adds a **server-side (middleware) backstop** so the 20-minute idle policy is enforced even when the client timer does not run. It is the follow-up explicitly deferred in the original change's `design.md` §Decision 7.

## What Changes

- The existing client activity handler in `frontend/hooks/use-idle-timer.ts` ALSO writes a non-httpOnly `lastActivity` timestamp cookie (added to `COOKIE_KEYS` in `frontend/lib/cookies.ts`), updated on the same ~1/sec throttled cadence as the in-memory timer. The cookie is the server's view of "when did the user last actually interact".
- `frontend/lib/supabase/middleware.ts` reads that cookie on protected routes and, when `now - lastActivity >= IDLE_TIMEOUT_MS`, forces a server-side logout: clears the Supabase auth cookies (`sb-*`) and the `lastActivity` cookie, then redirects to `/auth/login?reason=idle&next=<path>` — reusing the existing `next`/`reason=idle` conventions.
- A new **pure** decision function `isServerSideIdle(lastActivity, now, timeoutMs) => boolean` (placed alongside the existing pure core in `frontend/lib/auth/idle-config.ts`) encapsulates the staleness comparison so it is unit-testable without a request.
- The 20-minute threshold is **reused** from the existing `IDLE_TIMEOUT_MS` constant — no second literal is introduced (single source of truth).
- Explicit handling for the **missing/unparseable cookie** case (first load after login, JS never ran) so it never produces a redirect loop with the login page: a valid session with no `lastActivity` cookie is treated as "just active" and the cookie is seeded.

This is purely additive and defense-in-depth. It does NOT change the client-side warning modal, cross-tab sync, the threshold value, or any existing `idle-session-timeout` requirement.

## Capabilities

### New Capabilities
- `idle-session-server-enforcement`: Middleware-level (server-side) enforcement of the existing fixed idle-timeout policy. Covers the client-written `lastActivity` activity cookie as the server's activity signal, the pure server-side staleness decision, the middleware forced-logout + redirect on protected routes, and the redirect-loop / missing-cookie safety rules. Explicitly framed as defense-in-depth (fail-safe when the client timer does not fire), NOT a hard security boundary against a client that forges the cookie.

### Modified Capabilities
<!-- None. The existing `idle-session-timeout` capability is unchanged; its client behavior continues to hold. This change adds a separate, complementary server-side capability and only EXTENDS the client timer with an additional cookie-write side effect (no requirement of the existing spec changes). -->

## Impact

- **Code (frontend, additive):**
  - `frontend/lib/auth/idle-config.ts` — add pure `isServerSideIdle(...)` (reuses `IDLE_TIMEOUT_MS`).
  - `frontend/lib/cookies.ts` — add a `LAST_ACTIVITY` entry to `COOKIE_KEYS` + its config (SameSite=Lax, Secure in prod, NOT httpOnly, path=/).
  - `frontend/hooks/use-idle-timer.ts` — write/refresh the `lastActivity` cookie on the throttled activity path and on `reset()`.
  - `frontend/lib/supabase/middleware.ts` — read the cookie on protected routes, force logout + redirect when stale, clear cookies; seed-on-missing to avoid loops.
  - Login page already handles `reason=idle` (`frontend/app/auth/login/page.tsx`) — no change needed.
- **Tests:** vitest in `frontend/__tests__/` — pure `isServerSideIdle` unit tests; cookie-write assertions on the timer; a middleware-decision test for stale / fresh / missing-cookie / auth-route-skip / redirect-loop cases.
- **Runtime:** middleware runs in the Node.js runtime (current Vercel default), so it can import the shared constant from `lib/auth/idle-config.ts`. No new dependency, no schema change, no data migration.
- **Governance:** Auth/middleware = **CRITICAL**. This propose produces analysis/design only; implementation requires explicit PO approval before any code is written.
- **Out of scope:** changing the threshold, per-plan/per-role config, and DB-backed server-tracked session activity (the true hard-enforcement option — noted as a heavier future change). Anything already shipped in `idle-session-timeout`.
