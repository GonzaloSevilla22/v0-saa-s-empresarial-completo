# user-registration Specification

## Purpose
TBD - created by archiving change register-name-terms-captcha. Update Purpose after archive.
## Requirements
### Requirement: Separate first name and last name

The registration form SHALL collect the user's first name (`nombre`) and last name (`apellido`) in two distinct, required fields. Both values SHALL be propagated through the `signUp` user metadata and persisted to `profiles.name` and `profiles.last_name` respectively.

#### Scenario: User submits both name fields

- **WHEN** a user fills in a non-empty `nombre` and a non-empty `apellido` and submits the registration form
- **THEN** the system calls `supabase.auth.signUp` with `options.data.name` and `options.data.last_name` set to the trimmed values
- **AND** after the trigger runs, the new `profiles` row has `name` and `last_name` populated with those values

#### Scenario: Apellido is missing

- **WHEN** a user submits the form with an empty or whitespace-only `apellido`
- **THEN** the system blocks submission and shows a validation error indicating the last name is required
- **AND** no `signUp` call is made

#### Scenario: Existing users without last name are unaffected

- **WHEN** the migration runs against a database with pre-existing profiles
- **THEN** those profiles keep `last_name` as NULL
- **AND** no error is raised and the registration of new users is unaffected

### Requirement: Mandatory acceptance of Terms and Conditions

The registration form SHALL require explicit acceptance of the Terms and Conditions before an account can be created. The system SHALL record which version of the terms was accepted and the timestamp of acceptance.

#### Scenario: Terms not accepted

- **WHEN** a user attempts to submit the registration form without checking the Terms and Conditions checkbox
- **THEN** the system blocks submission and shows a validation error
- **AND** the "Crear cuenta" action does not call `signUp`

#### Scenario: Terms accepted

- **WHEN** a user checks the Terms and Conditions checkbox and submits a valid form
- **THEN** the `signUp` metadata includes `terms_version` (the current terms version identifier)
- **AND** the trigger sets `profiles.terms_accepted_at` to the signup time and `profiles.terms_version` to the accepted version

#### Scenario: Terms checkbox links to the legal page

- **WHEN** the registration form renders the Terms and Conditions checkbox
- **THEN** the checkbox label contains a link to the public Terms and Conditions page (`/legal/terminos`)

### Requirement: Optional opt-in for email notifications

The registration form SHALL present an optional, unchecked-by-default checkbox for the user to opt in to email notifications about changes and news in Aliadata. The choice SHALL be persisted to `profiles.email_notifications_opt_in`.

#### Scenario: User opts in

- **WHEN** a user checks the email notifications checkbox and submits the form
- **THEN** the `signUp` metadata includes `email_notifications_opt_in = true`
- **AND** the trigger sets `profiles.email_notifications_opt_in = true`

#### Scenario: User does not opt in (default)

- **WHEN** a user submits the form without checking the email notifications checkbox
- **THEN** the `signUp` metadata includes `email_notifications_opt_in = false`
- **AND** the trigger sets `profiles.email_notifications_opt_in = false`

### Requirement: Signup metadata propagation via trigger

The `handle_new_user` trigger SHALL copy `last_name`, `terms_accepted_at`, `terms_version`, and `email_notifications_opt_in` from `raw_user_meta_data` into the new `profiles` row, while preserving all of its existing behavior (profile creation, tenant provisioning, welcome and admin-notice emails).

#### Scenario: Trigger copies new fields

- **WHEN** a new user signs up with `last_name`, `terms_version`, and `email_notifications_opt_in` in the signup metadata
- **THEN** the created `profiles` row reflects those values
- **AND** the user is still provisioned as the owner of a new account (tenant) exactly as before
- **AND** the welcome email and admin-notice email are still enqueued

