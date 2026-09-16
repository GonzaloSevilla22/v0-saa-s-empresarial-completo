## MODIFIED Requirements

### Requirement: Content Security Policy allows Turnstile

The application's Content Security Policy SHALL permit the Cloudflare Turnstile widget to load and render **without relying on `'unsafe-inline'` in `script-src`**. Specifically, `https://challenges.cloudflare.com` MUST be allowed in `script-src` and `connect-src`, `frame-src` MUST allow `https://challenges.cloudflare.com`, and any script that the widget injects at runtime MUST be permitted through `'strict-dynamic'` rather than through a blanket inline allowance.

In production, `script-src` SHALL be nonce-based: the captcha entry points SHALL keep working with a per-request nonce and `'strict-dynamic'` in place of `'unsafe-inline'` and `'unsafe-eval'`.

#### Scenario: Widget renders under production CSP

- **WHEN** an auth page is served with the production security headers
- **THEN** the Turnstile script loads and its challenge iframe renders without being blocked by the CSP

#### Scenario: Widget renders with a nonce-based script-src

- **GIVEN** production security headers whose `script-src` carries a per-request nonce and `'strict-dynamic'`, and neither `'unsafe-inline'` nor `'unsafe-eval'`
- **WHEN** an auth page with the captcha widget is loaded
- **THEN** the widget renders, solves, and submits its token without any CSP violation in the browser console

#### Scenario: The captcha submit path survives a token renewal under the nonce policy

- **WHEN** the widget renews its token after the tab regains visibility, under the nonce-based policy
- **THEN** the renewal completes and the auth submit proceeds, with no script blocked by the CSP
