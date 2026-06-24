## ADDED Requirements

### Requirement: Client writes a lastActivity cookie as the server activity signal

The client idle timer SHALL persist the timestamp of the user's last real interaction into a non-httpOnly `lastActivity` cookie so that server-side code (middleware) can observe inactivity without depending on client JavaScript executing on the navigation request. The cookie SHALL be defined through the centralized cookie utility (`COOKIE_KEYS` / the cookie config in `frontend/lib/cookies.ts`) with `SameSite=Lax`, `Secure` in production, and `path=/`, and SHALL NOT be `httpOnly` (client JS must be able to update it). The cookie SHALL be updated on the SAME throttled cadence (at most ~once per second) as the in-memory `lastActivity` timer, and SHALL NOT be written by background/automated requests (token refresh, polling, prefetch).

#### Scenario: Activity updates the cookie on the throttled cadence

- **WHEN** the user interacts with the page (mouse move, key down, scroll, wheel, touch, or click) and the throttle window allows an update
- **THEN** the `lastActivity` cookie is set to the current timestamp via the centralized cookie utility
- **AND** the cookie carries `SameSite=Lax`, `path=/`, and `Secure` in production, and is not `httpOnly`

#### Scenario: High-frequency events do not over-write the cookie

- **WHEN** many activity events fire within the same one-second throttle window
- **THEN** the `lastActivity` cookie is written at most once for that window

#### Scenario: Staying connected from the warning modal refreshes the cookie

- **WHEN** the user activates "Seguir conectado" (or any explicit timer reset)
- **THEN** the `lastActivity` cookie is updated to the current timestamp

#### Scenario: Background requests do not count as activity

- **WHEN** a request occurs that was not driven by user interaction (silent token refresh, polling, or prefetch)
- **THEN** the `lastActivity` cookie is NOT updated by that request

### Requirement: Pure server-side idle decision function

The system SHALL expose a pure function `isServerSideIdle(lastActivity, now, timeoutMs)` that returns `true` when `now - lastActivity` is greater than or equal to `timeoutMs`, and `false` otherwise, with no request, cookie, DOM, or network access. The function SHALL reuse the existing `IDLE_TIMEOUT_MS` constant as its threshold (no second 20-minute literal is introduced) and SHALL live alongside the existing pure idle core in `frontend/lib/auth/idle-config.ts`.

#### Scenario: Fresh activity is not idle

- **WHEN** `now - lastActivity` is strictly less than `timeoutMs`
- **THEN** `isServerSideIdle` returns `false`

#### Scenario: Threshold reached is idle

- **WHEN** `now - lastActivity` is greater than or equal to `timeoutMs`
- **THEN** `isServerSideIdle` returns `true`

#### Scenario: Exact threshold boundary is idle

- **WHEN** `now - lastActivity` equals exactly `timeoutMs`
- **THEN** `isServerSideIdle` returns `true`

#### Scenario: Threshold reuses the single source of truth

- **WHEN** the middleware evaluates server-side idle
- **THEN** it passes `IDLE_TIMEOUT_MS` (imported from `frontend/lib/auth/idle-config.ts`) as the threshold, and no other 20-minute literal exists in the server path

### Requirement: Middleware enforces idle logout on protected routes

On a request to a protected (authenticated) route with a valid session, the middleware SHALL read the `lastActivity` cookie and, when `isServerSideIdle(lastActivity, now, IDLE_TIMEOUT_MS)` is `true`, force a server-side logout: it SHALL clear the Supabase auth cookies (the `sb-*` cookies) and the `lastActivity` cookie on the response, and SHALL redirect to `/auth/login?reason=idle&next=<current-path>`, reusing the existing `reason=idle` and `next` conventions.

#### Scenario: Stale session is logged out server-side

- **WHEN** an authenticated request hits a protected route
- **AND** the `lastActivity` cookie is present and `now - lastActivity` is greater than or equal to `IDLE_TIMEOUT_MS`
- **THEN** the middleware clears the `sb-*` auth cookies and the `lastActivity` cookie
- **AND** redirects to `/auth/login?reason=idle&next=<current-path>`

#### Scenario: Active session is allowed through

- **WHEN** an authenticated request hits a protected route
- **AND** the `lastActivity` cookie is present and `now - lastActivity` is strictly less than `IDLE_TIMEOUT_MS`
- **THEN** the middleware does NOT force a logout and the request proceeds normally with the existing session-refresh behavior

### Requirement: Missing or unparseable cookie does not cause a logout or redirect loop

When the session is valid but the `lastActivity` cookie is absent or cannot be parsed (first navigation after login, or JavaScript never ran), the middleware SHALL treat the session as just-active rather than idle: it SHALL NOT force a logout, and SHALL seed the `lastActivity` cookie to the current time so subsequent requests have a baseline. This prevents a redirect loop in which a freshly logged-in user with no cookie yet is immediately bounced back to login.

#### Scenario: First request after login has no cookie

- **WHEN** an authenticated request hits a protected route
- **AND** the `lastActivity` cookie is absent
- **THEN** the middleware does NOT force a logout
- **AND** it seeds the `lastActivity` cookie to the current time on the response

#### Scenario: Unparseable cookie value is treated as just-active

- **WHEN** the `lastActivity` cookie is present but its value is not a valid timestamp
- **THEN** the middleware does NOT force a logout
- **AND** it re-seeds the `lastActivity` cookie to the current time

### Requirement: Enforcement is scoped to protected routes only

The server-side idle check SHALL run only for authenticated/protected routes and SHALL NOT run on public or auth routes (`/auth/*`) or static assets. The forced-logout redirect target (`/auth/login`) SHALL itself never be gated by this check, so the redirect cannot loop.

#### Scenario: Auth routes are never idle-gated

- **WHEN** a request hits `/auth/login`, `/auth/register`, or another `/auth/*` route
- **THEN** the server-side idle check does not run and no idle redirect is issued

#### Scenario: Static assets are never idle-gated

- **WHEN** a request targets a static asset or an excluded path per the middleware matcher
- **THEN** the server-side idle check does not run

#### Scenario: Idle redirect lands on an ungated login page

- **WHEN** the middleware forces an idle logout and redirects to `/auth/login?reason=idle&next=<path>`
- **THEN** the resulting request to `/auth/login` is not idle-gated and renders the login page (no loop)

### Requirement: Server-side enforcement is defense-in-depth, not a hard boundary

The capability SHALL be documented and treated as a fail-safe / defense-in-depth control, not as a hard security boundary. Because the `lastActivity` cookie is client-writable (non-httpOnly), a determined client could forge it; the value of this control is that it enforces idle logout when the client timer does NOT fire (tab crash/restore, JS disabled or broken, SSR navigation) and removes sole reliance on client cooperation. True hard enforcement (server-tracked session activity keyed to the session in the database) is explicitly out of scope and recorded as a heavier future option.

#### Scenario: Enforcement holds when the client timer never runs

- **WHEN** the client-side idle timer does not fire (for example the tab was restored, JavaScript is disabled, or a server-rendered navigation occurs) and `now - lastActivity` is greater than or equal to `IDLE_TIMEOUT_MS`
- **THEN** the middleware still forces an idle logout on the next protected-route request

#### Scenario: Forged cookie is acknowledged as out of scope

- **WHEN** considering a client that forges a future `lastActivity` value to stay logged in
- **THEN** this is documented as a known limitation of the defense-in-depth model and is NOT addressed by this change
