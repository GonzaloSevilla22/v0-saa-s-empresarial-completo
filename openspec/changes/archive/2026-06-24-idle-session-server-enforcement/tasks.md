## 0. Approval gate (CRITICAL — auth/middleware governance)

- [x] 0.1 Obtain explicit PO approval to write implementation code (this change touches auth + middleware = CRITICAL). No code in tasks 1+ until this is checked.
- [x] 0.2 Confirm the open questions with the PO: cookie name + maxAge bucket; whether the stale-logout also clears `tenant:active` (not just `sb-*` + `lastActivity`); Node vs Edge middleware runtime. Record answers in design.md before coding.

## 1. Pure server-side decision core (TDD: RED → GREEN → TRIANGULATE → REFACTOR)

- [x] 1.1 Safety net: run the existing `frontend/__tests__/idle-config.test.ts` and capture the baseline (all passing) before touching `idle-config.ts`.
- [x] 1.2 RED: write a failing unit test for `isServerSideIdle(lastActivity, now, timeoutMs)` (fresh ⇒ false) in `frontend/__tests__/` (e.g. extend `idle-config.test.ts` or a new `idle-server.test.ts`).
- [x] 1.3 GREEN: add the pure `isServerSideIdle` to `frontend/lib/auth/idle-config.ts` (`return now - lastActivity >= timeoutMs`); no second 20-min literal — callers pass `IDLE_TIMEOUT_MS`.
- [x] 1.4 TRIANGULATE: add tests for threshold-reached ⇒ true, exact-boundary (`elapsed === timeoutMs`) ⇒ true, and a value just under the threshold ⇒ false; generalize if needed.
- [x] 1.5 REFACTOR: ensure naming/JSDoc match the existing pure functions in the module; tests still green.

## 2. Cookie utility: add the lastActivity key

- [x] 2.1 RED (or assertion-level test): add a test that the cookie helper produces a `lastActivity` cookie with `SameSite=Lax`, `path=/`, not `httpOnly`, and `Secure` in production.
- [x] 2.2 GREEN: add `LAST_ACTIVITY` to `COOKIE_KEYS` and a matching `COOKIE_CONFIG` entry (sameSite `Lax`, maxAge ≥ idle window, per design Decision 2) in `frontend/lib/cookies.ts`.
- [x] 2.3 Verify `getServerCookie` reads the new key (it is generic over `CookieKey`); add a read assertion.

## 3. Client writes the activity cookie (extend the existing timer)

- [x] 3.1 Safety net: run `frontend/__tests__/hooks/use-idle-timer.test.ts` and capture the baseline before editing the hook.
- [x] 3.2 RED: write a failing test asserting the throttled activity path writes/refreshes the `lastActivity` cookie at most ~1/sec, and that `reset()` also refreshes it.
- [x] 3.3 GREEN: in `frontend/hooks/use-idle-timer.ts`, on the throttled `handleActivity` path and in `reset()`, call `setCookie(COOKIE_KEYS.LAST_ACTIVITY, String(now))` (never raw `document.cookie`). Do NOT write it from peer/transport messages or any non-interaction path.
- [x] 3.4 TRIANGULATE: add a test proving high-frequency events write the cookie at most once per throttle window, and that no cookie write happens absent user interaction.
- [x] 3.5 REFACTOR: confirm no existing `idle-session-timeout` behavior changed (warning, cross-tab, expiry); baseline tests still green.

## 4. Middleware integration (server-side enforcement)

- [x] 4.1 RED: write a failing test for the middleware idle decision — extract/exercise a small pure helper (e.g. `evaluateIdle(lastActivityCookie, now)`) so the stale/fresh/missing logic is testable without a full `NextRequest`. Cases: present+stale ⇒ logout; present+fresh ⇒ proceed.
- [x] 4.2 GREEN: in `frontend/lib/supabase/middleware.ts`, on the protected + authenticated + email-verified happy path, read `COOKIE_KEYS.LAST_ACTIVITY` via `getServerCookie`, parse with `Number` + `Number.isFinite`, and call `isServerSideIdle(parsed, Date.now(), IDLE_TIMEOUT_MS)`.
- [x] 4.3 GREEN: on stale ⇒ build the redirect to `/auth/login?reason=idle&next=<pathname>`, delete the `sb-*` cookies (mirror the existing "Refresh Token Not Found" branch) and the `lastActivity` cookie on the response, and wrap with `applySecurityHeaders(...)`.
- [x] 4.4 Import `IDLE_TIMEOUT_MS` and `isServerSideIdle` from `@/lib/auth/idle-config` (single source of truth; no duplicated literal). Keep `getUser()` — never downgrade to `getSession()`.

## 5. Loop-safety, missing-cookie, and scoping edge cases (TRIANGULATE)

- [x] 5.1 RED→GREEN: missing cookie on a protected route ⇒ NOT a logout; seed `lastActivity = now` on the response. Test the first-load-after-login no-loop case.
- [x] 5.2 RED→GREEN: unparseable cookie value ⇒ NOT a logout; re-seed. Add the test.
- [x] 5.3 Verify (test) the idle check never runs on `/auth/*` (not in `PROTECTED_PREFIXES`) and that the `/auth/login` redirect target is therefore never idle-gated (no loop).
- [x] 5.4 Confirm the existing `config.matcher` already excludes static assets; no matcher change needed (assert in a comment/test as appropriate).

## 6. Regression, docs, and wrap-up

- [x] 6.1 Run the full frontend vitest suite; confirm all `idle-*` tests (existing + new) pass and no `idle-session-timeout` behavior regressed.
- [ ] 6.2 Manual verification: log in, idle past 20 min with the tab backgrounded/crashed (no client timer), navigate → land on `/auth/login?reason=idle&next=...`; separately, confirm a fresh login does NOT loop.
- [x] 6.3 Update the change/spec notes if any open question resolved differently than assumed; ensure the defense-in-depth framing and the DB-backed future option remain documented.
- [ ] 6.4 Mark the change in CHANGES.md per project workflow (after archive).
