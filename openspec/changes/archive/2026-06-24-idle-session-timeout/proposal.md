## Why

Supabase Auth auto-refreshes the JWT (`autoRefreshToken`), so an authenticated session stays alive indefinitely while a browser tab is open — even if the user walks away. On shared or unattended devices (a common reality for the micro-entrepreneurs and their staff who use Aliadata at a counter, feria stall, or shared back-office PC) this leaves financial data, billing, and AFIP fiscal tooling exposed. We need to automatically end a session after a fixed period of inactivity, with a clear warning so active users are never logged out mid-task.

## What Changes

- Auto-logout the user after **20 minutes of inactivity (AFK)** in the authenticated dashboard area. The 20-minute threshold is a fixed hardcoded constant for this change (not configurable, not plan-based).
- Show a **warning modal with a countdown** at ~19 minutes (1 minute before the limit): "Tu sesión se cerrará en 60s" with a **"Seguir conectado"** button that resets the idle timer. If the user does not respond within the countdown, log them out.
- Detect activity from **browser interaction** in the tab (mouse move, keydown, scroll, touch, wheel, click), throttled to update at most ~once per second.
- **Synchronize idle state across tabs**: activity in one tab resets the timer in all tabs, and an idle logout in one tab signs out every tab. Use `BroadcastChannel` with a `localStorage` `storage`-event fallback.
- On idle logout, **match the existing logout behavior** (`supabase.auth.signOut()` + clear the `tenant:active` cookie) and redirect to `/auth/login` with `?reason=idle&next=<current-path>` so the login page can show an explanatory toast and return the user to where they were.
- Add a small client-only configuration module (e.g. `lib/auth/idle-config.ts`) exposing `IDLE_TIMEOUT_MS` and `WARNING_BEFORE_MS` constants, and a **pure decision function** `computeIdleState(lastActivity, now, config)` returning `'active' | 'warning' | 'expired'` so the core logic is unit-testable without a DOM.
- Mount a client idle-timer provider inside the authenticated dashboard layout so it only runs for logged-in users.

Out of scope (future, not this change):
- Server-side enforcement of inactivity (e.g. a `lastActivity` cookie validated in middleware). Documented as a recommended follow-up in `design.md`; this change is client-side primary only.
- Per-plan or per-role configurable timeouts, an admin settings UI for the threshold, and "remember me" / extended-session options.

## Capabilities

### New Capabilities
- `idle-session-timeout`: Client-side inactivity detection that warns the user before, and then performs, an automatic sign-out after a fixed idle threshold, synchronized across browser tabs and consistent with the application's existing logout flow.

### Modified Capabilities
<!-- No existing spec's requirements change. The existing `backend-auth` and tenancy/auth specs are untouched; this adds a new, additive client-side capability. -->

## Impact

- **New code (frontend):**
  - `frontend/lib/auth/idle-config.ts` — `IDLE_TIMEOUT_MS`, `WARNING_BEFORE_MS`, and the pure `computeIdleState()` decision function (+ its types).
  - A React hook + client provider (e.g. `frontend/hooks/use-idle-timer.ts` and `frontend/components/auth/IdleTimeoutProvider.tsx`) wiring activity listeners, the single recomputed `setTimeout`, `visibilitychange`/focus recomputation, and cross-tab sync.
  - An accessible warning modal component (e.g. `frontend/components/auth/IdleWarningModal.tsx`) built on the existing shadcn/ui dialog primitives.
- **Modified code (frontend):**
  - `frontend/app/(dashboard)/layout.tsx` — mount the client idle provider so it covers only the authenticated area.
  - `frontend/app/auth/login/page.tsx` — read `?reason=idle` and surface a toast ("Tu sesión se cerró por inactividad").
  - Reuses (does not change the contract of) `frontend/contexts/auth-context.tsx` `logout()` / `signOut()` and the `tenant:active` cookie handling in `frontend/lib/cookies.ts`.
- **Auth/security (governance: CRITICAL):** touches the auth/session domain. This change emits analysis/design artifacts only; production implementation requires explicit human approval before code is written.
- **Dependencies:** none new. Uses browser `BroadcastChannel`, `localStorage`, the existing `@supabase/ssr` client, and existing shadcn/ui + Radix dialog components.
- **Gotcha:** because Supabase keeps refreshing the token, expiry alone never logs the user out — idle logout MUST be enforced explicitly client-side.
