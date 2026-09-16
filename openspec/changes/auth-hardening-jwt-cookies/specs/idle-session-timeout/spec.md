## MODIFIED Requirements

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
