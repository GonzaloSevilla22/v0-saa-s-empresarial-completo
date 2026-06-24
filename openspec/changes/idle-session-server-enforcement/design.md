## Context

The shipped `idle-session-timeout` capability (PR #217, archived 2026-06-24) implements 20-minute AFK auto-logout **entirely client-side**: a React hook (`frontend/hooks/use-idle-timer.ts`) tracks a `lastActivity` timestamp, schedules a single recomputed `setTimeout`, shows a warning modal, syncs across tabs, and on expiry calls the existing `logout()` path. The pure decision core and the `IDLE_TIMEOUT_MS` (1_200_000) / `WARNING_BEFORE_MS` constants live in `frontend/lib/auth/idle-config.ts`.

The original `design.md` §Decision 7 deliberately deferred **server-side enforcement** as the recommended follow-up, noting it as defense-in-depth and naming the exact mechanism: "a `lastActivity` cookie ... refreshed on activity and validated in `frontend/lib/supabase/middleware.ts`, redirecting to login when stale." This change implements that.

Current relevant state:
- `frontend/middleware.ts` matches all paths except static assets/images, delegating to `updateSession()` in `frontend/lib/supabase/middleware.ts`.
- `updateSession()` already: calls `supabase.auth.getUser()` (validates the JWT — the rule is never to downgrade to `getSession()`), applies security headers, enforces `PROTECTED_PREFIXES`, redirects unauthenticated users to `/auth/login?next=<path>`, blocks unverified email, does an admin role check, and skips auth pages for logged-in users. It owns cookie I/O via the `@supabase/ssr` `getAll`/`setAll` adapter.
- `frontend/lib/cookies.ts` centralizes UX cookies via `COOKIE_KEYS` + a per-key `COOKIE_CONFIG` (maxAge, sameSite), with `setCookie`/`deleteCookie`/`getClientCookie` (client) and `getServerCookie` (duck-typed, for middleware/Server Components). `Secure` is added in production only.
- The login page (`frontend/app/auth/login/page.tsx`) already reads `reason=idle` and `next`.

Constraints: Next.js 16 App Router, React 19, TypeScript strict (never `any`), pnpm, vitest in `frontend/__tests__/`. Conventional commits scope `auth`. **Auth/middleware is a CRITICAL governance domain** — this change produces design/analysis only; writing code requires explicit PO approval, and apply runs under Strict TDD.

## Goals / Non-Goals

**Goals:**
- Enforce the existing 20-minute idle policy at the middleware (server) layer so it holds even when the client-side JS timer does not fire (tab crash/restore, JS disabled/broken, SSR navigation, token-refresh-only traffic).
- Drive the server check from a CLIENT-written `lastActivity` cookie (the user's real interaction), not from request traffic — so background/automated requests do not reset the AFK clock.
- Keep the server decision in a pure, request-free function for straightforward TDD.
- Reuse the existing threshold constant, the existing `reason=idle`/`next` conventions, and the centralized cookie utility. No new dependency, no schema change.
- Be honest in the artifacts that this is defense-in-depth, not a hard boundary.

**Non-Goals:**
- Changing the 20-minute threshold, or making it per-plan/per-role/runtime-configurable.
- DB-backed server-tracked session activity (the true hard-enforcement option) — noted as a future change.
- Any change to the client warning modal, countdown, cross-tab sync, or any existing `idle-session-timeout` requirement. The only client change is an added cookie-write side effect on the already-existing activity path.
- Changing `getUser()` to `getSession()`, or altering the existing route-protection / admin / email-verification logic.

## Decisions

### Decision 1 — Client-written `lastActivity` cookie is the server's activity signal (not request traffic)
The middleware must distinguish "user is interacting" from "the app made a request". Supabase auto-refreshes the token on every middleware pass, and the app polls/prefetches; if any request reset the clock, AFK detection would never trigger. Therefore the **client** owns the signal: the existing throttled activity handler in `use-idle-timer.ts` writes the `lastActivity` cookie (same ~1/sec cadence, same events) and the middleware only ever READS it. **Alternative considered:** have the middleware stamp activity on each request — rejected: it counts background traffic as activity and defeats the entire feature. **Alternative considered:** a server-stamped cookie updated only on "real" navigations — rejected: middleware cannot reliably tell a user navigation from a prefetch/refresh; the client already knows what real interaction is.

### Decision 2 — Cookie attributes via the centralized utility; non-httpOnly by necessity
Add `LAST_ACTIVITY: "auth:last-activity"` to `COOKIE_KEYS` and a `COOKIE_CONFIG` entry (`sameSite: "Lax"`, a maxAge ≥ the idle window — reusing the existing `WEEK` bucket is fine; `Secure` already comes from the prod flag; `path=/`). It MUST be readable/writable by client JS (the timer updates it), so it is **not** `httpOnly` — unlike the Supabase `sb-*` cookies which stay httpOnly and untouched except for clearing on logout. The client writes it via `setCookie(COOKIE_KEYS.LAST_ACTIVITY, String(now))`; never via raw `document.cookie` without attributes. **Alternative considered:** httpOnly cookie written by a server endpoint on each activity — rejected: needs a network round-trip per activity (defeats the ~1/sec throttle's purpose) and adds an endpoint to a CRITICAL surface.

### Decision 3 — Pure `isServerSideIdle(lastActivity, now, timeoutMs)` reusing `IDLE_TIMEOUT_MS`
Add a pure boolean function next to the existing `computeIdleState` in `idle-config.ts`: `return now - lastActivity >= timeoutMs`. The middleware calls `isServerSideIdle(parsed, Date.now(), IDLE_TIMEOUT_MS)`. This keeps the threshold as a single source of truth (no second 20-minute literal anywhere) and makes the decision unit-testable with no request object. Boundary (`elapsed === timeoutMs ⇒ true`) is an explicit test case, consistent with `computeIdleState`'s expired boundary. **Alternative considered:** inline `Date.now() - last >= IDLE_TIMEOUT_MS` in the middleware — rejected: harder to test in isolation and invites a drifting literal.

### Decision 4 — Middleware integration point: inside `updateSession`, after the protected-route auth check
The check is added in `frontend/lib/supabase/middleware.ts` only on the `isProtected && user && user.email_confirmed_at` happy path — i.e. after we already know the request is to a protected route with a valid, verified session. On stale: build the same kind of redirect the file already builds (`url.pathname = "/auth/login"`, `searchParams.set("reason", "idle")`, `searchParams.set("next", pathname)`), clear the `sb-*` cookies on the redirect response (mirroring the existing "Refresh Token Not Found" branch which already deletes `sb-` cookies), delete the `lastActivity` cookie, and `applySecurityHeaders(...)` it. Reusing the existing redirect/cookie-clear shapes keeps the change minimal and consistent. **Alternative considered:** a separate middleware function or matcher — rejected: `updateSession` already has `user`, `pathname`, `isProtected`, and the cookie adapter in scope; splitting it duplicates Supabase client setup.

### Decision 5 — Matcher / route scoping: rely on existing `PROTECTED_PREFIXES` + the existing matcher; auth routes are inherently safe
The existing `config.matcher` already excludes static/image assets. Within `updateSession`, the idle check is gated by `isProtected` (the `PROTECTED_PREFIXES` list), which does NOT include `/auth/*`. So the check never runs on `/auth/login` etc., and the idle redirect target is therefore never idle-gated — no loop is possible from scoping alone. No matcher change is required. **Alternative considered:** a dedicated matcher listing dashboard routes — rejected: redundant with `PROTECTED_PREFIXES`, two lists to keep in sync.

### Decision 6 — Missing/unparseable cookie ⇒ treat as just-active and seed it (loop safety)
A user who just logged in (or has JS disabled and never wrote the cookie) has a valid session but no `lastActivity` cookie. If "missing" were treated as idle, the user would be redirected to login, log in again, still have no cookie, and loop. So: missing or non-numeric cookie ⇒ NOT idle; the middleware seeds `lastActivity = now` on the response so the next request has a baseline. Parsing uses `Number(value)` with a `Number.isFinite` guard. This is the single most important loop-safety rule and gets dedicated tests. **Alternative considered:** treat missing as idle for strictness — rejected: guaranteed redirect loop; also wrong, since a missing cookie means "we have no evidence of inactivity", not "inactive".

### Decision 7 — Honest framing: defense-in-depth, not a hard boundary
Because the cookie is client-writable, a determined client can forge a future timestamp and stay logged in. The artifacts state this plainly. The real, defensible value: enforcement when the client timer DOESN'T run (the gap that motivated the change). The hard-boundary alternative — a server-side `session_activity` table keyed to the Supabase session/refresh token, updated by a trusted server path and validated in middleware — is materially heavier (schema, write path, RLS, GC) and is recorded as a future option, explicitly out of scope. **Alternative considered:** signing the cookie (HMAC) to prevent forgery — rejected for this change: it stops tampering with the value but the client still authors it (it can always replay a fresh signed value by interacting), so it does not convert this into a hard boundary; added complexity without closing the actual gap. Worth revisiting only alongside the DB-backed option.

### Decision 8 — Node runtime; safe to import the shared constant
Middleware runs in the Node.js runtime under the current Vercel defaults, and `IDLE_TIMEOUT_MS` / `isServerSideIdle` are plain TS with no browser APIs, so importing `@/lib/auth/idle-config` into `frontend/lib/supabase/middleware.ts` is safe (the pure module has no DOM/`document` access at module scope; the client cookie writes live in the hook, not the config module). If the project ever moves middleware to the Edge runtime, the pure module remains compatible (no Node-only APIs in it). **Alternative considered:** re-declare the constant in the middleware — rejected: violates single-source-of-truth.

## Risks / Trade-offs

- **[Client-writable cookie can be forged]** → Documented as defense-in-depth (Decision 7); the control's value is enforcing logout when the client timer doesn't fire, not stopping a determined attacker. Hard enforcement (DB-tracked session activity) recorded as a future change.
- **[Redirect loop if missing cookie were treated as idle]** → Decision 6: missing/unparseable ⇒ just-active + seed; auth routes are never idle-gated (Decision 5). Dedicated tests for first-load-after-login and the loop case.
- **[Background traffic resetting the AFK clock]** → Decision 1: only the client activity path writes the cookie; the middleware only reads. Spec scenario asserts background requests do not update it.
- **[Clock skew between client write and server read]** → Both use absolute epoch ms; the threshold is 20 minutes, so sub-second/second-level skew is immaterial. No relative timers cross the boundary.
- **[Cookie not sent on the relevant request (path/SameSite)]** → `path=/` and `SameSite=Lax` mean the cookie is sent on top-level navigations to protected routes (the requests we gate). Lax is sufficient because we only act on first-party navigations; we are not relying on cross-site sends.
- **[Stale-logout clears the wrong cookies]** → Mirror the existing `sb-`-prefix deletion already proven in the "Refresh Token Not Found" branch; also delete only `COOKIE_KEYS.LAST_ACTIVITY`. Do not touch unrelated UX cookies.
- **[Double enforcement vs. the client timer]** → Both can fire; both lead to the same `/auth/login?reason=idle` destination, and sign-out/cookie-clear is idempotent. No conflict.
- **[Governance: CRITICAL auth domain]** → No production code in this propose step; implementation requires explicit human approval (tasks §0). Apply under Strict TDD: pure core first, then cookie write, then middleware, then loop/edge cases.

## Migration Plan

1. **Approval gate (CRITICAL):** obtain explicit PO approval before any implementation code is written (tasks §0).
2. **Implement under Strict TDD**, in the order in `tasks.md`: (a) pure `isServerSideIdle` + tests; (b) add `LAST_ACTIVITY` to the cookie utility; (c) wire the cookie write into `use-idle-timer.ts` on the throttled path + `reset()`; (d) integrate the read/decision/forced-logout into `updateSession`; (e) loop-safety + missing-cookie + auth-route-skip cases.
3. **No data migration, no new dependency, no schema change.** Purely frontend, additive.
4. **Rollback:** remove the idle-check block from `updateSession` (one contiguous block) to fully disable server enforcement; the client cookie write and the pure function can remain dormant and harmless. No persisted server state to clean up.
5. **Verification:** unit tests for `isServerSideIdle` boundaries; cookie-write assertions on the timer; middleware-decision tests for stale / fresh / missing / unparseable / auth-route-skip / redirect-target-not-gated. Manual: log in, idle past 20 min with the tab backgrounded/crashed, navigate → land on `/auth/login?reason=idle&next=...`; and confirm a fresh login does not loop.

## Open Questions

- **Cookie name and maxAge bucket** — assumed `auth:last-activity` with the existing `WEEK` maxAge; confirm the exact name/lifetime during apply (must outlive the 20-min window; longer is harmless since the value, not the cookie lifetime, drives the decision).
- **Should the stale-logout also clear other auth-adjacent cookies (e.g. `tenant:active`)?** — the client `logout()` clears `tenant:active`; for parity the middleware could too. Assumed: clear `sb-*` + `lastActivity` only (minimal); confirm whether `tenant:active` should also be cleared server-side on idle.
- **Edge vs Node runtime** — assumed Node (current default) so the import is trivially fine; if middleware is later pinned to Edge, re-verify the pure module imports cleanly (expected yes). Confirm at apply.
- **Whether to sign the cookie now** — assumed NO (Decision 7); revisit only if/when the DB-backed hard-enforcement change is taken up.
