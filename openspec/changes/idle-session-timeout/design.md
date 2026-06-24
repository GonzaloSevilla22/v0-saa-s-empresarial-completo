## Context

Aliadata (EIE) uses Supabase Auth via `@supabase/ssr`. The session token is short-lived but Supabase keeps it alive transparently: the client is configured with `autoRefreshToken`, and `frontend/middleware.ts` (via `frontend/lib/supabase/middleware.ts`) calls `getUser()` on every request, rotating the cookie. The practical consequence is that **a session never expires on its own while a tab stays open** — token expiry alone will never log an idle user out.

Today, logout is explicit and centralized in `frontend/contexts/auth-context.tsx`:

- `logout()` → `supabase.auth.signOut()`, clears the `tenant:active` cookie, then `router.push("/auth/login")`.
- `onAuthStateChange` reacts to `SIGNED_OUT` by setting `user` to `null`.
- `closeAllSessions()` uses `signOut({ scope: 'global' })`.

The authenticated UI lives under `frontend/app/(dashboard)/layout.tsx`, which is a **Server Component**. Protected routes are enforced server-side in the middleware (`PROTECTED_PREFIXES`), and the middleware already uses a `next` query param to preserve the intended destination after login.

Constraints from the project: Next.js 16 App Router, React 19, TypeScript strict (never `any`), Tailwind + shadcn/ui + Radix, pnpm. React component files in PascalCase. Auth is a **CRITICAL governance domain** — this change produces design/analysis only; writing the implementation requires explicit human approval.

## Goals / Non-Goals

**Goals:**
- Automatically sign out an authenticated user after a fixed 20 minutes of browser inactivity.
- Warn the user 1 minute before, via an accessible modal with a live countdown and a "Seguir conectado" action that resets the timer.
- Detect activity from mouse/keyboard/scroll/wheel/touch/click, throttled to ~once per second.
- Synchronize idle state across tabs: activity resets all tabs; logout signs out all tabs.
- Keep the core decision logic as a pure, DOM-free function for straightforward TDD.
- Reuse the existing logout mechanism exactly (sign-out + `tenant:active` cookie clear + redirect), adding `?reason=idle&next=` so the login page can explain and return the user.

**Non-Goals:**
- Server-side enforcement of inactivity in this change (see Decision 7 — recommended follow-up).
- Per-plan, per-role, or admin-configurable thresholds; "remember me"; or extended-session options.
- Changing any existing auth requirement, the middleware route-protection logic, or the AuthContext public contract. The idle feature is additive and reuses `logout()`.

## Decisions

### Decision 1 — Enforce idle logout explicitly client-side (not via token expiry)
Because `autoRefreshToken` keeps the session alive, idle logout MUST be driven by the client. The provider tracks a `lastActivity` timestamp and calls the existing sign-out path when the threshold is crossed. **Alternative considered:** shorten Supabase JWT/refresh lifetimes — rejected: it is global, affects active users, gives no warning UX, and is not "inactivity" (it logs out active users too).

### Decision 2 — Pure `computeIdleState(lastActivity, now, config)` core
All threshold logic lives in a pure function returning `'active' | 'warning' | 'expired'`, in `frontend/lib/auth/idle-config.ts` alongside the `IDLE_TIMEOUT_MS` / `WARNING_BEFORE_MS` constants and their types. The React hook becomes a thin shell that feeds `Date.now()` into this function. **Rationale:** deterministic, no DOM/timer/network, trivially unit-testable under Strict TDD (boundaries at warning-start and threshold are explicit test cases). **Alternative considered:** inline the comparisons in the hook — rejected: untestable without a DOM and entangles policy with effects.

### Decision 3 — Single recomputed `setTimeout`, not a ticking `setInterval`
The hook schedules one `setTimeout` computed from `lastActivity` (to the warning point, then to expiry). On any activity it clears and reschedules. **Rationale:** robust to background-tab timer throttling and cheaper than a per-second interval. The visible countdown inside the modal may use a short interval, but it is only mounted during the warning window and is presentational — the source of truth for the logout decision remains `computeIdleState(Date.now())`. **Alternative considered:** a 1s `setInterval` polling elapsed time — rejected: wasteful and unreliable when the tab is throttled/asleep.

### Decision 4 — Recompute on `visibilitychange` / focus, log out immediately if already expired
Background tabs throttle timers and sleeping devices freeze them, so a scheduled callback can fire late or not at all. On `visibilitychange` (visible) and window `focus`, the hook recomputes `computeIdleState(lastActivity, Date.now())`: if `'expired'`, log out immediately; if `'warning'`, show the modal with the correct remaining seconds; else reschedule. **Rationale:** correctness on tab-return without trusting the timer. **Alternative considered:** trust the timer only — rejected: it lets an idle-past-threshold session resume on return.

### Decision 5 — Throttle activity handlers to ~1/sec
`mousemove`/`scroll`/`wheel` fire at very high frequency. Handlers update `lastActivity` at most once per ~1000ms (leading-edge throttle). **Rationale:** sub-second precision is irrelevant against a 20-minute threshold and avoids perf cost. Listeners are attached `passive: true` where applicable and removed on unmount.

### Decision 6 — Cross-tab via `BroadcastChannel` with `localStorage` fallback
Two messages: `activity` (carries the new `lastActivity`) and `logout`. A tab that sees a peer's `activity` adopts the newer `lastActivity` and reschedules; a tab that sees `logout` signs out locally. `BroadcastChannel` is primary; when unavailable, write a timestamped key to `localStorage` and react to the `storage` event. **Note:** Supabase's own `onAuthStateChange` already propagates `SIGNED_OUT` across tabs via its storage adapter, which is a useful backstop — but we still need the **activity-reset** broadcast (Supabase does not know about UI activity), so we own a dedicated channel for both messages to keep behavior explicit and testable. **Alternative considered:** rely solely on Supabase's cross-tab sign-out — rejected: it covers logout but not activity reset, leaving tabs out of sync before expiry.

### Decision 7 — Client-side primary now; server enforcement is a documented follow-up (DEFENSE-IN-DEPTH)
Client-side idle control is bypassable (a user can disable JS, edit timers, or replay the cookie), so it is a UX/exposure-reduction control, not a hard security boundary. **In scope (this change):** client-side detection, warning, and logout. **Out of scope (recommended follow-up):** a server-enforced inactivity check — e.g. a `lastActivity` cookie (or a column on the session) refreshed on activity and validated in `frontend/lib/supabase/middleware.ts`, redirecting to login when stale. This is explicitly deferred to keep this change focused and low-risk; it is recorded here so it is not lost.

### Decision 8 — Mount the provider inside the dashboard layout
A new Client Component provider is rendered inside the Server Component `frontend/app/(dashboard)/layout.tsx`, so idle tracking runs only for authenticated dashboard users and never on public/auth pages. It reads the existing `logout` from `useAuth()` (or calls the same sign-out + cookie-clear sequence) to avoid duplicating the logout contract. **Rationale:** correct scoping with no change to middleware; Server Components can render Client Components as children.

### Decision 9 — Accessible modal on existing shadcn/ui Dialog
The warning modal reuses the project's shadcn/ui dialog (Radix) for built-in focus trap and Escape handling. The countdown text lives in an `aria-live="assertive"` (or `polite`) region; Escape is treated as "Seguir conectado". The primary action is "Seguir conectado". **Rationale:** consistency with existing UI and accessibility out of the box.

## Risks / Trade-offs

- **[Client-side control is bypassable]** → Documented as defense-in-depth (Decision 7); recommend a server-side `lastActivity` middleware check as a follow-up. This change reduces exposure but is not a hard boundary.
- **[Background-tab timer throttling / sleeping device fires the timeout late]** → `visibilitychange`/focus recomputation logs out immediately if already expired (Decision 4); the logout decision never trusts the timer alone.
- **[High-frequency activity events hurt performance]** → ~1/sec throttle + passive listeners (Decision 5).
- **[Cross-tab clock/skew or message races]** → All tabs use their own `Date.now()`; the broadcast carries an absolute `lastActivity` and tabs always adopt the **newer** value, so a late/duplicate message cannot shorten a fresh timer.
- **[`BroadcastChannel` unsupported (older browsers)]** → `localStorage` `storage`-event fallback (Decision 6).
- **[Modal could trap a user mid-form if mis-timed]** → 60s warning + one-click "Seguir conectado" that fully resets the timer; any in-tab activity already resets before the warning.
- **[Double logout / redirect loop across tabs]** → Logout is idempotent (signing out an already-signed-out session is a no-op) and guarded so only one redirect is issued per tab.
- **[Governance: CRITICAL auth domain]** → No production code is written in this propose step; implementation requires explicit human approval. Apply runs under Strict TDD.

## Migration Plan

1. **Approval gate (CRITICAL):** obtain explicit human approval before any implementation code is written.
2. **Implement under Strict TDD**, in the order encoded in `tasks.md`: pure core + config constants first (fully unit-tested), then the React hook, then the modal, then wiring into the dashboard layout and the login-page toast, then cross-tab sync.
3. **No data migration, no new dependency, no schema change.** Purely frontend, additive.
4. **Rollback:** unmount the provider from `frontend/app/(dashboard)/layout.tsx` (one-line revert) to fully disable the feature; the pure module and components can remain dormant. No persisted state to clean up beyond a transient `localStorage` key used only by the fallback.
5. **Verification:** unit tests for `computeIdleState` boundaries; manual/automated checks for the warning countdown, "Seguir conectado" reset, expiry logout, tab-hidden-then-return immediate logout, and cross-tab activity + logout sync.

## Open Questions

- **Toast vs. inline banner on the login page for `reason=idle`** — assumed a toast; confirm the exact copy ("Tu sesión se cerró por inactividad.") and channel during apply.
- **Exact `aria-live` politeness for the countdown** — `assertive` (interrupts) vs `polite`; lean `assertive` given it is a time-critical security prompt, confirm in design review.
- **Whether `closeAllSessions` (`scope: 'global'`) is ever desired for idle** — assumed NO: idle logout is local sign-out (the same as `logout()`), with cross-tab handled by our broadcast, not by revoking refresh tokens globally. Confirm with PO if a stricter posture is wanted later.
- **Server-enforcement follow-up** — confirmed out of scope here (Decision 7); should be filed as its own change if/when wanted.
