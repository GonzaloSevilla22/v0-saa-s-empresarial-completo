# idle-session-timeout — Spec

## Purpose

Client-side idle-session timeout: a fixed 20-minute inactivity threshold with a 1-minute warning modal, activity tracking, idle logout matching the existing sign-out flow, and cross-tab synchronization.

## Requirements

### Requirement: Fixed idle threshold and warning lead time

The system SHALL define the inactivity threshold and the warning lead time as fixed, hardcoded constants exposed from a single client configuration module (e.g. `lib/auth/idle-config.ts`). The idle threshold SHALL be 20 minutes (`IDLE_TIMEOUT_MS`) and the warning SHALL appear `WARNING_BEFORE_MS` (1 minute) before the threshold. These values SHALL NOT be configurable at runtime, per plan, or per role in this change.

#### Scenario: Constants define a 20-minute timeout with a 1-minute warning

- **WHEN** the idle configuration is read
- **THEN** `IDLE_TIMEOUT_MS` equals 20 minutes in milliseconds (1_200_000)
- **AND** `WARNING_BEFORE_MS` equals 1 minute in milliseconds (60_000)
- **AND** `WARNING_BEFORE_MS` is strictly less than `IDLE_TIMEOUT_MS`

### Requirement: Pure idle-state decision function

The system SHALL expose a pure function `computeIdleState(lastActivity, now, config)` that returns `'active'`, `'warning'`, or `'expired'` based only on its arguments, with no DOM, timer, or network access, so the core decision logic is deterministic and unit-testable.

#### Scenario: Active well before the warning window

- **WHEN** `now - lastActivity` is less than `IDLE_TIMEOUT_MS - WARNING_BEFORE_MS`
- **THEN** `computeIdleState` returns `'active'`

#### Scenario: Inside the warning window but not yet expired

- **WHEN** `now - lastActivity` is greater than or equal to `IDLE_TIMEOUT_MS - WARNING_BEFORE_MS` and strictly less than `IDLE_TIMEOUT_MS`
- **THEN** `computeIdleState` returns `'warning'`

#### Scenario: Threshold reached or exceeded

- **WHEN** `now - lastActivity` is greater than or equal to `IDLE_TIMEOUT_MS`
- **THEN** `computeIdleState` returns `'expired'`

#### Scenario: Exact boundary at the warning start is treated as warning

- **WHEN** `now - lastActivity` equals exactly `IDLE_TIMEOUT_MS - WARNING_BEFORE_MS`
- **THEN** `computeIdleState` returns `'warning'`

### Requirement: Activity resets the idle timer

The system SHALL treat user interaction in the tab — mouse move, key down, scroll, wheel, touch, and click — as activity that resets the inactivity timer by updating the `lastActivity` timestamp. Activity handling SHALL be throttled so the timestamp is updated at most approximately once per second to avoid performance cost on high-frequency events.

#### Scenario: User interacts before the warning

- **WHEN** the user moves the mouse, presses a key, scrolls, or touches the screen while in the `'active'` state
- **THEN** `lastActivity` is updated to the current time
- **AND** the scheduled logout is rescheduled relative to the new `lastActivity`

#### Scenario: High-frequency events are throttled

- **WHEN** many activity events fire within the same one-second window
- **THEN** `lastActivity` is updated at most once for that window

### Requirement: Warning modal with countdown before logout

The system SHALL display an accessible warning modal when the idle state becomes `'warning'`, showing a live countdown of the seconds remaining (e.g. "Tu sesión se cerrará en 60s") and a "Seguir conectado" button. Activating "Seguir conectado" SHALL reset the idle timer and dismiss the modal. The modal SHALL be focus-trapped, dismissible via the Escape key (treated as "Seguir conectado"), and announce the countdown to assistive technology via an `aria-live` region.

#### Scenario: Warning appears one minute before logout

- **WHEN** the user has been inactive for `IDLE_TIMEOUT_MS - WARNING_BEFORE_MS`
- **THEN** the warning modal is shown with a countdown starting at 60 seconds
- **AND** focus moves into the modal

#### Scenario: User chooses to stay connected

- **WHEN** the warning modal is shown and the user activates "Seguir conectado" (button click or Escape)
- **THEN** `lastActivity` is reset to the current time
- **AND** the modal is dismissed
- **AND** the session remains active

#### Scenario: User does not respond before the countdown ends

- **WHEN** the warning modal is shown and the countdown reaches zero without the user staying connected
- **THEN** the system performs an idle logout

### Requirement: Idle logout matches existing logout and is recoverable

When the idle state reaches `'expired'`, the system SHALL sign the user out using the **same shared sign-out mechanism** as the application's manual logout, and SHALL redirect to `/auth/login` with `reason=idle` and a `next` query parameter equal to the path the user was on, so the login page can explain why and return the user afterward.

That shared mechanism SHALL revoke the session server-side with **current-session scope** (never global: closing this session must not sign the user out on their other devices) and SHALL clear **every** session-related UX cookie — both the active-tenant cookie and the `lastActivity` cookie — through a single shared helper, so the three exit paths (manual logout, client idle logout, server idle logout) leave identical state behind.

Leaving the `lastActivity` cookie behind is NOT acceptable: it survives the logout and makes the middleware discard the freshly issued session cookies on the user's very next login attempt.

#### Scenario: Expired session signs out and redirects with context

- **WHEN** the idle state reaches `'expired'`
- **THEN** the Supabase session is revoked with current-session scope and the `tenant:active` and `lastActivity` cookies are cleared
- **AND** the browser is redirected to `/auth/login?reason=idle&next=<current-path>`

#### Scenario: Login page explains the idle logout

- **WHEN** the login page loads with `reason=idle`
- **THEN** the user is shown a message indicating the session was closed due to inactivity

#### Scenario: Re-login right after an idle logout succeeds on the first attempt

- **GIVEN** a session that was just closed for inactivity
- **WHEN** the user logs in again and navigates into the authenticated area
- **THEN** the navigation completes on the first attempt, because no stale activity cookie remains to trigger another forced logout

#### Scenario: The idle logout does not close sessions on other devices

- **GIVEN** the same user signed in on a second device
- **WHEN** the first device's session is closed for inactivity
- **THEN** the second device's session remains active

#### Scenario: The three exit paths leave the same state

- **WHEN** the session is closed by the manual logout, by the client idle timer, or by the server-side idle check
- **THEN** in all three cases the session is revoked server-side and the same set of session-related UX cookies is cleared

### Requirement: Idle detection is scoped to the authenticated area

The system SHALL run idle detection only for authenticated users within the dashboard area, by mounting the idle-timer provider inside the authenticated dashboard layout. Idle detection SHALL NOT run on public or auth pages (login, register).

#### Scenario: Provider active only when logged in

- **WHEN** an authenticated user is in the dashboard area
- **THEN** the idle-timer provider is mounted and tracking activity

#### Scenario: No idle tracking on public pages

- **WHEN** a visitor is on a public or auth page
- **THEN** the idle-timer provider is not mounted

### Requirement: Timer robust to background-tab throttling

The system SHALL drive the timeout from a single `setTimeout` recomputed from the `lastActivity` timestamp rather than a ticking `setInterval`, and SHALL recompute elapsed inactivity on `visibilitychange` and window focus. If the threshold was already crossed while the tab was hidden or the device was asleep, the system SHALL log out immediately upon return.

#### Scenario: Threshold passed while the tab was hidden

- **WHEN** the tab becomes visible or the window regains focus
- **AND** `now - lastActivity` is greater than or equal to `IDLE_TIMEOUT_MS`
- **THEN** the system performs an idle logout immediately without waiting for a timer callback

#### Scenario: Within the warning window on return

- **WHEN** the tab becomes visible or the window regains focus
- **AND** `now - lastActivity` is within the warning window but below the threshold
- **THEN** the warning modal is shown with the correct remaining countdown

### Requirement: Cross-tab synchronization of activity and logout

The system SHALL synchronize idle state across tabs of the same origin. Activity in one tab SHALL reset the idle timer in all other tabs, and an idle logout in one tab SHALL sign out all tabs. Synchronization SHALL use `BroadcastChannel`, with a `localStorage` `storage`-event fallback when `BroadcastChannel` is unavailable.

#### Scenario: Activity in one tab keeps other tabs alive

- **WHEN** the user is active in one tab
- **THEN** other open tabs receive the activity broadcast and reset their idle timers to the same `lastActivity`

#### Scenario: Logout in one tab logs out all tabs

- **WHEN** an idle logout occurs in one tab
- **THEN** all other open tabs sign out and redirect to the login page

#### Scenario: Fallback when BroadcastChannel is unavailable

- **WHEN** `BroadcastChannel` is not supported by the browser
- **THEN** cross-tab activity and logout are propagated via `localStorage` `storage` events

