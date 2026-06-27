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

### Requirement: Widget reset on rejected token

When Supabase rejects a captcha token (expired or invalid) on any auth form, the system SHALL surface an error to the user and reset the Turnstile widget so a new challenge can be solved, without completing the auth action.

#### Scenario: Token rejected on submit

- **WHEN** Supabase Auth returns a captcha error for any auth form submission
- **THEN** the system shows an error message
- **AND** the Turnstile widget is reset so the user can retry
- **AND** the auth action (account creation / login / reset email) does not complete

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

