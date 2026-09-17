## MODIFIED Requirements

### Requirement: Middleware enforces idle logout on protected routes

On a request to a protected (authenticated) route with a valid session, the middleware SHALL read the `lastActivity` cookie and, when `isServerSideIdle(lastActivity, now, IDLE_TIMEOUT_MS)` is `true`, force a server-side logout: it SHALL **revoke the session against the auth provider** (current-session scope) **before** clearing cookies, it SHALL clear the Supabase auth cookies (the `sb-*` cookies) and the `lastActivity` cookie on the response, and SHALL redirect to `/auth/login?reason=idle&next=<current-path>`, reusing the existing `reason=idle` and `next` conventions.

Clearing the cookies without revoking is NOT sufficient: the refresh token stays usable by any copy of it that was made while the cookies were still readable, which is precisely the exposure this system is closing.

#### Scenario: Stale session is logged out server-side

- **WHEN** an authenticated request hits a protected route
- **AND** the `lastActivity` cookie is present and `now - lastActivity` is greater than or equal to `IDLE_TIMEOUT_MS`
- **THEN** the middleware revokes the session against the auth provider with current-session scope
- **AND** clears the `sb-*` auth cookies and the `lastActivity` cookie
- **AND** redirects to `/auth/login?reason=idle&next=<current-path>`

#### Scenario: The revoked session cannot be resumed

- **GIVEN** a session that the middleware closed for inactivity
- **WHEN** the same refresh token is presented afterwards
- **THEN** the auth provider rejects it, because the session was revoked and not merely forgotten by the browser

#### Scenario: Active session is allowed through

- **WHEN** an authenticated request hits a protected route
- **AND** the `lastActivity` cookie is present and `now - lastActivity` is strictly less than `IDLE_TIMEOUT_MS`
- **THEN** the middleware does NOT force a logout and the request proceeds normally with the existing session-refresh behavior

### Requirement: Enforcement is scoped to protected routes only

The server-side idle check SHALL run only for authenticated/protected routes and SHALL NOT run on public or auth routes (`/auth/*`) or static assets. The forced-logout redirect target (`/auth/login`) SHALL itself never be gated by this check, so the redirect cannot loop.

The set of protected routes SHALL be the one derived by the session capability from the authenticated route tree (an explicit public allow-list plus protection by default), NOT a hand-maintained list of prefixes. A route tree added to the authenticated area therefore receives idle enforcement without any further action.

#### Scenario: Auth routes are never idle-gated

- **WHEN** a request hits `/auth/login`, `/auth/register`, or another `/auth/*` route
- **THEN** the server-side idle check does not run and no idle redirect is issued

#### Scenario: Static assets are never idle-gated

- **WHEN** a request targets a static asset or an excluded path per the middleware matcher
- **THEN** the server-side idle check does not run

#### Scenario: Idle redirect lands on an ungated login page

- **WHEN** the middleware forces an idle logout and redirects to `/auth/login?reason=idle&next=<path>`
- **THEN** the resulting request to `/auth/login` is not idle-gated and renders the login page (no loop)

#### Scenario: A newly added authenticated route is idle-gated without extra wiring

- **GIVEN** a route tree newly added to the authenticated area and absent from the public allow-list
- **WHEN** an idle session requests it
- **THEN** the idle check runs and forces the logout, with no prefix added by hand
