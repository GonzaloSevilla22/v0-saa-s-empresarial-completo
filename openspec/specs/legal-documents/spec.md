# legal-documents Specification

## Purpose
TBD - created by archiving change register-name-terms-captcha. Update Purpose after archive.
## Requirements
### Requirement: Public Terms and Conditions page

The system SHALL serve a public Terms and Conditions page at `/legal/terminos`, accessible without authentication. The content SHALL be tailored to Aliadata (microemprendedores de Mendoza, gestión financiera, datos fiscales/AFIP, asistencia con IA, comunicaciones por email) and SHALL be treated as a draft pending the PO's legal review.

#### Scenario: Unauthenticated visitor reads the terms

- **WHEN** an unauthenticated visitor navigates to `/legal/terminos`
- **THEN** the Terms and Conditions page renders without redirecting to login
- **AND** the page is reachable from the registration form's Terms checkbox link

#### Scenario: Page exposes a version identifier

- **WHEN** the Terms and Conditions page is rendered
- **THEN** it displays a version identifier and an effective date consistent with the `terms_version` value recorded at signup

### Requirement: Public Privacy Policy page

The system SHALL serve a public Privacy Policy page at `/legal/privacidad`, accessible without authentication. The content SHALL describe what personal and fiscal data Aliadata collects, how it is used (including email communications and AI processing), the legal basis under Argentine Law 25.326, and the user's rights. It SHALL be treated as a draft pending the PO's legal review.

#### Scenario: Unauthenticated visitor reads the privacy policy

- **WHEN** an unauthenticated visitor navigates to `/legal/privacidad`
- **THEN** the Privacy Policy page renders without redirecting to login

#### Scenario: Privacy policy is linked from the registration consent

- **WHEN** the registration form renders the Terms and Conditions checkbox label
- **THEN** the label also links to the Privacy Policy page (`/legal/privacidad`)

### Requirement: Versioned consent record

The system SHALL record, per user, the version of the Terms accepted and the timestamp of acceptance, so that consent is auditable when the legal documents are updated.

#### Scenario: Consent is auditable after a terms update

- **WHEN** the Terms version identifier is later bumped to a new value
- **THEN** users who registered under the previous version still have their original `terms_version` and `terms_accepted_at` preserved in `profiles`
- **AND** no existing consent record is silently overwritten by the version bump

