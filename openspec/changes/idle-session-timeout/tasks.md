> **Governance: CRITICAL (auth/session).** Do NOT begin implementation until a human has explicitly approved this change. Apply runs under **Strict TDD** (RED → GREEN → TRIANGULATE → REFACTOR). Each behavior gets a failing test first, then minimum code, then a second/edge case, then refactor. Build the pure core before anything that touches the DOM.

## 0. Pre-flight (approval + baseline)

- [x] 0.1 Obtain explicit human approval to write code (CRITICAL governance gate). Do not proceed without it.
- [x] 0.2 Confirm the test runner is available and runs green on a no-op (`pnpm test` or project equivalent); capture the baseline test count.
- [x] 0.3 Run existing tests for any file that will be modified (`auth-context.tsx`, dashboard `layout.tsx`, login `page.tsx`); record the baseline. Report any pre-existing failures — do NOT fix them here.

## 1. Pure core: config constants + `computeIdleState` (no DOM)

- [x] 1.1 RED: write a failing test for `IDLE_TIMEOUT_MS === 1_200_000` and `WARNING_BEFORE_MS === 60_000` and `WARNING_BEFORE_MS < IDLE_TIMEOUT_MS`, importing from `frontend/lib/auth/idle-config.ts` (does not exist yet).
- [x] 1.2 GREEN: create `frontend/lib/auth/idle-config.ts` with the two constants and an exported `IdleConfig` type and `IdleState = 'active' | 'warning' | 'expired'` type.
- [x] 1.3 RED: write a failing test for `computeIdleState(lastActivity, now, config)` returning `'active'` when elapsed `< IDLE_TIMEOUT_MS - WARNING_BEFORE_MS`.
- [x] 1.4 GREEN: implement `computeIdleState` (pure, no DOM/timer/network) to pass 1.3 (Fake It is allowed).
- [x] 1.5 TRIANGULATE: add tests for `'warning'` (within warning window), `'expired'` (>= threshold), and the exact boundaries (elapsed === `IDLE_TIMEOUT_MS - WARNING_BEFORE_MS` → `'warning'`; elapsed === `IDLE_TIMEOUT_MS` → `'expired'`). Generalize the implementation until all pass.
- [x] 1.6 REFACTOR: clean up naming/derived values (e.g. a `warningAt` helper), no `any`, keep all tests green.

## 2. Idle hook: timer scheduling, activity, visibility (`use-idle-timer`)

- [x] 2.1 RED: write a failing test (fake timers) that the hook schedules a single `setTimeout` derived from `lastActivity` and transitions `active → warning` at `IDLE_TIMEOUT_MS - WARNING_BEFORE_MS`.
- [x] 2.2 GREEN: create `frontend/hooks/use-idle-timer.ts` exposing the current `IdleState`, seconds-remaining, and a `reset()` callback; drive decisions through `computeIdleState(Date.now())`.
- [x] 2.3 RED: failing test that an activity event resets `lastActivity` and reschedules (no transition to warning while active).
- [x] 2.4 GREEN: attach throttled (~1/sec, leading edge) listeners for `mousemove`, `keydown`, `scroll`, `wheel`, `touchstart`, `click`; passive where applicable; remove all on unmount.
- [x] 2.5 TRIANGULATE: tests that high-frequency events update `lastActivity` at most once per ~1s window, and that listeners are detached on unmount (no leak).
- [x] 2.6 RED: failing test that on `visibilitychange`/focus when elapsed `>= IDLE_TIMEOUT_MS`, the hook reports `'expired'` immediately (no waiting for the timer).
- [x] 2.7 GREEN: implement `visibilitychange` + window `focus` recomputation (immediate expire, or re-enter warning with correct remaining seconds).
- [x] 2.8 REFACTOR: ensure single source of truth is the pure function; clear/reschedule timeout correctly; strict types, no `any`; all tests green.

## 3. Warning modal (`IdleWarningModal`)

- [x] 3.1 RED: failing render test that the modal shows the countdown copy ("Tu sesión se cerrará en {n}s") and a "Seguir conectado" button when state is `'warning'`.
- [x] 3.2 GREEN: create `frontend/components/auth/IdleWarningModal.tsx` on the existing shadcn/ui Dialog (Radix); presentational, props = remaining seconds + `onStayConnected`.
- [x] 3.3 RED: failing test that activating "Seguir conectado" (button click) calls `onStayConnected`.
- [x] 3.4 GREEN: wire the button; add the live countdown driven by a short interval mounted only while open (presentational only).
- [x] 3.5 TRIANGULATE: tests for Escape key treated as "Seguir conectado", focus moves into the modal on open (focus trap), and the countdown is in an `aria-live` region. Adjust until accessible.
- [x] 3.6 REFACTOR: extract the countdown into a small testable unit if helpful; verify no `any`, PascalCase filename; tests green.

## 4. Idle logout action (reuse existing logout)

- [x] 4.1 RED: failing test that the idle-logout action calls the existing sign-out path (`supabase.auth.signOut()`), clears the `tenant:active` cookie, and redirects to `/auth/login?reason=idle&next=<current-path>`.
- [x] 4.2 GREEN: implement the idle-logout action reusing `useAuth().logout` (or the identical sign-out + `deleteCookie(COOKIE_KEYS.TENANT)` sequence), appending `reason=idle` and the current path as `next`. Make logout idempotent / guard against double redirect.
- [x] 4.3 TRIANGULATE: test idempotency (calling twice does not double-redirect / error) and that `next` is the current pathname.
- [x] 4.4 REFACTOR: dedupe with the existing logout to avoid drift from the AuthContext contract; tests green.

## 5. Cross-tab synchronization

- [x] 5.1 RED: failing test that an `activity` broadcast carrying a newer `lastActivity` resets/reschedules the hook in a peer tab (and that an older value is ignored).
- [x] 5.2 GREEN: add a `BroadcastChannel`-based sync (messages: `activity` with absolute `lastActivity`, and `logout`); peers adopt only the newer `lastActivity`.
- [x] 5.3 RED: failing test that a `logout` broadcast signs out a peer tab.
- [x] 5.4 GREEN: handle the `logout` message → run the idle-logout action locally.
- [x] 5.5 TRIANGULATE: test the `localStorage` `storage`-event fallback path when `BroadcastChannel` is unavailable (both activity and logout), and that the channel is closed on unmount.
- [x] 5.6 REFACTOR: isolate the transport behind a small interface so it is testable and swappable; strict types; tests green.

## 6. Wiring into the app

- [x] 6.1 Create `frontend/components/auth/IdleTimeoutProvider.tsx` (Client Component) composing the hook + modal + logout action + cross-tab sync.
- [x] 6.2 Mount `IdleTimeoutProvider` inside `frontend/app/(dashboard)/layout.tsx` so it runs only for authenticated dashboard users (verify it does NOT mount on public/auth pages).
- [x] 6.3 RED: failing test that the login page shows the idle message when `?reason=idle` is present.
- [x] 6.4 GREEN: update `frontend/app/auth/login/page.tsx` to read `reason=idle` and surface a toast/message ("Tu sesión se cerró por inactividad."); preserve `next` for return-after-login.
- [x] 6.5 REFACTOR: confirm no regression in existing auth/login/layout tests (re-run the §0 baselines); strict types; everything green.

## 7. Verification & accessibility

- [x] 7.1 Run the full unit suite; confirm `computeIdleState` boundary cases and hook timer behavior are covered.
- [x] 7.2 Manual/automated check: warning appears ~1 min before, countdown ticks, "Seguir conectado" resets, no-response logs out, tab-hidden-past-threshold logs out immediately on return.
- [x] 7.3 Manual/automated check: cross-tab — activity in one tab keeps another alive; idle logout in one tab signs out all tabs (BroadcastChannel and the localStorage fallback).
- [x] 7.4 Accessibility pass on the modal: focus trap, Escape = stay connected, `aria-live` countdown announced, button is reachable and labeled.
- [x] 7.5 Fill in the Strict TDD Cycle Evidence table (per-task: test file, layer, safety net, RED/GREEN/TRIANGULATE/REFACTOR) in the apply summary.
