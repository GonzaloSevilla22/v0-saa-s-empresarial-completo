# auth-captcha Specification

## Purpose
TBD - created by archiving change register-name-terms-captcha. Update Purpose after archive.
## Requirements
### Requirement: Captcha gate on every auth entry point

Every authentication entry point that Supabase Auth gates with captcha SHALL require a successful Cloudflare Turnstile challenge before calling Supabase. This covers account creation (`signUp`), password login (`signInWithPassword`), password recovery (`resetPasswordForEmail`), and magic-link/OTP login (`signInWithOtp`) if used. The Turnstile token SHALL be passed via `options.captchaToken` so Supabase validates it server-side; no custom backend validation is added.

#### Scenario: Registration requires captcha

- **WHEN** a user completes a valid registration form but the Turnstile challenge has not produced a token
- **THEN** the "Crear cuenta" submit is disabled and `signUp` is not called
- **AND** once the challenge produces a token, `signUp` is called with `options.captchaToken` set to it

#### Scenario: Login requires captcha

- **WHEN** a user submits the login form
- **THEN** `signInWithPassword` is called with `options.captchaToken` set to a valid Turnstile token
- **AND** the submit is blocked until the challenge is solved

#### Scenario: Password recovery requires captcha

- **WHEN** a user submits the forgot-password form
- **THEN** `resetPasswordForEmail` is called with `options.captchaToken` set to a valid Turnstile token

### Requirement: Captcha token freshness on tab visibility

The captcha widget SHALL track the instant each token was issued and, when the page returns to a visible state, SHALL discard and re-challenge any token whose age exceeds the maximum token age, notifying the consuming form so the stale token is cleared from its state. The maximum token age is a single shared constant, set well below the Turnstile token lifetime. This closes the idle-logout gap: a background tab solves the challenge on mount, its timers do not run reliably, and the token is already dead by the time the user returns.

#### Scenario: Stale token is renewed when the user comes back to the tab

- **WHEN** a token was issued, the page has been hidden, and it becomes visible again after the token exceeded the maximum token age
- **THEN** the widget resets the challenge and notifies the form that the current token is no longer usable
- **AND** the form clears its token, keeping the submit disabled until a fresh token arrives
- **AND** once the challenge re-solves, the form holds a freshly issued token with no user action

#### Scenario: Fresh token survives a short tab switch

- **WHEN** the page becomes visible again and the issued token is still within the maximum token age
- **THEN** the widget does not reset the challenge
- **AND** the form keeps its token and the submit stays enabled

#### Scenario: Visibility change with no issued token is inert

- **WHEN** the page becomes visible and no token has been issued yet (or the last one was already cleared)
- **THEN** the widget performs no reset and emits no notification

### Requirement: Captcha token age guard before submit

Every auth form SHALL verify the age of its captcha token before calling Supabase and SHALL obtain a fresh token when the current one exceeds the maximum token age. The check is independent of visibility events, so it also covers a token that aged while the tab stayed open. If a fresh token cannot be obtained within the refresh timeout, the submission fails with a normal error instead of sending a stale token.

#### Scenario: Stale token is replaced before calling Supabase

- **WHEN** a user submits an auth form whose captcha token exceeds the maximum token age
- **THEN** a fresh token is requested from the widget before the Supabase call
- **AND** Supabase is called with the fresh token, never with the stale one

#### Scenario: Fresh token is used as is

- **WHEN** a user submits an auth form whose captcha token is within the maximum token age
- **THEN** the Supabase call is made immediately with that token and no extra challenge is requested

#### Scenario: Refresh timeout surfaces a normal error

- **WHEN** a fresh token is required but none is issued within the refresh timeout
- **THEN** the auth action does not complete
- **AND** an error is surfaced to the user with the widget left ready for a new challenge

### Requirement: Widget reset on rejected token

When Supabase rejects a captcha token (expired or invalid) on any auth form, the system SHALL surface an error to the user and reset the Turnstile widget so a new challenge can be solved, without completing the auth action. Before surfacing that error, the system SHALL retry the submission automatically **at most once**, with a freshly issued token, and only when the rejection is identified as a captcha error. Any other failure, and the failure of the single retry, is surfaced immediately with no further retry.

#### Scenario: Token rejected on submit

- **WHEN** Supabase Auth returns a captcha error for any auth form submission
- **THEN** the system shows an error message
- **AND** the Turnstile widget is reset so the user can retry
- **AND** the auth action (account creation / login / reset email) does not complete

#### Scenario: Captcha rejection recovers on the automatic retry

- **WHEN** Supabase Auth returns a captcha error on the first attempt and the retry with a fresh token succeeds
- **THEN** the auth action completes normally
- **AND** no captcha error is shown to the user

#### Scenario: Retry happens at most once

- **WHEN** Supabase Auth returns a captcha error on both the first attempt and the automatic retry
- **THEN** no third attempt is made
- **AND** the error is surfaced and the widget is reset for the user to retry manually

#### Scenario: Non-captcha errors are not retried

- **WHEN** Supabase Auth returns an error that is not a captcha rejection (invalid credentials, network, rate limit)
- **THEN** the submission is not retried
- **AND** the error is surfaced to the user on the first attempt

### Requirement: Shared freshness policy across auth entry points

The token freshness policy SHALL be implemented once and reused by every auth entry point that renders the captcha widget, rather than duplicated per screen. The entry points covered are login, registration, password recovery and magic-link login.

#### Scenario: All four entry points share one implementation

- **WHEN** the freshness policy (age guard, refresh, single retry) is exercised on login, registration, password recovery or magic-link login
- **THEN** all four delegate to the same shared implementation
- **AND** changing the maximum token age in one place changes the behavior of all four

### Requirement: Local QA captcha stub is exempt from freshness handling

When the local Playwright QA stub is active, the widget SHALL report its stub token as never stale, SHALL resolve any refresh request immediately with that token, and SHALL NOT register visibility handling. The stub emits its token without a real Turnstile widget, so a reset would never produce a replacement token and any wait for one would hang the automated suite.

#### Scenario: Stub token is never treated as stale

- **WHEN** the local QA stub is active and the page becomes visible after any amount of elapsed time
- **THEN** no reset occurs and the form keeps the stub token
- **AND** a request for a fresh token resolves immediately with the stub token

### Requirement: Content Security Policy allows Turnstile

The application's Content Security Policy SHALL permit the Cloudflare Turnstile widget to load and render. Specifically, `https://challenges.cloudflare.com` MUST be allowed in `script-src` and `connect-src`, and `frame-src` MUST allow `https://challenges.cloudflare.com`.

#### Scenario: Widget renders under production CSP

- **WHEN** an auth page is served with the production security headers
- **THEN** the Turnstile script loads and its challenge iframe renders without being blocked by the CSP

### Requirement: Project-wide enablement sequencing

Because enabling captcha in Supabase applies project-wide to sign-up, login, and password reset simultaneously, captcha enforcement in Supabase SHALL be enabled only once all gated auth entry points submit a captcha token.

#### Scenario: Enablement does not break existing flows

- **WHEN** captcha protection is enabled in the Supabase dashboard
- **THEN** registration, login, and password recovery all submit a valid `captchaToken`
- **AND** no gated auth flow fails due to a missing captcha token

