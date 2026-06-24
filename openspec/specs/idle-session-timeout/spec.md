## ADDED Requirements

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

When the idle state reaches `'expired'`, the system SHALL sign the user out using the same mechanism as the application's existing logout (`supabase.auth.signOut()` plus clearing the `tenant:active` cookie) and SHALL redirect to `/auth/login` with `reason=idle` and a `next` query parameter equal to the path the user was on, so the login page can explain why and return the user afterward.

#### Scenario: Expired session signs out and redirects with context

- **WHEN** the idle state reaches `'expired'`
- **THEN** the Supabase session is signed out and the `tenant:active` cookie is cleared
- **AND** the browser is redirected to `/auth/login?reason=idle&next=<current-path>`

#### Scenario: Login page explains the idle logout

- **WHEN** the login page loads with `reason=idle`
- **THEN** the user is shown a message indicating the session was closed due to inactivity

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
