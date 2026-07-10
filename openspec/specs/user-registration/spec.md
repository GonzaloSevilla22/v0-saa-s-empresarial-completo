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

The `handle_new_user` trigger SHALL copy `last_name`, `terms_accepted_at`, `terms_version`, and `email_notifications_opt_in` from `raw_user_meta_data` into the new `profiles` row, while preserving all of its existing behavior (profile creation, tenant provisioning, welcome and admin-notice emails). As part of tenant provisioning, the trigger SHALL ALSO seed a default branch ("Casa Central") and a default cashbox for the new account (see "Tenant provisioning seed").

#### Scenario: Trigger copies new fields

- **WHEN** a new user signs up with `last_name`, `terms_version`, and `email_notifications_opt_in` in the signup metadata
- **THEN** the created `profiles` row reflects those values
- **AND** the user is still provisioned as the owner of a new account (tenant) exactly as before
- **AND** the welcome email and admin-notice email are still enqueued

#### Scenario: Trigger seeds the default branch and cashbox

- **WHEN** a new user signs up and the trigger provisions the new account
- **THEN** the new account has a default branch named "Casa Central" with `is_active = TRUE` and `status = 'active'`
- **AND** that branch has a default cashbox with `currency = 'ARS'`
- **AND** the profile, owner membership, welcome email and admin-notice email are still created exactly as before

### Requirement: Tenant provisioning seed

The `handle_new_user` trigger SHALL provision, at signup time and inside the same transaction, the minimal operational structures a new tenant needs to sell within minutes with zero manual setup: a default branch named "Casa Central" (`is_active = TRUE`, `status = 'active'`) and a default cashbox ("Caja Principal", `currency = 'ARS'`) hanging off that branch. The seed SHALL be idempotent (`ON CONFLICT (account_id, name) DO NOTHING` for the branch; a `NOT EXISTS` guard for the cashbox, since `cashboxes` has no unique constraint). The seed block SHALL NOT be able to abort the signup: it SHALL be wrapped so that any failure degrades to a warning (`RAISE WARNING`) rather than raising, relying on the existing lazy-create safety net downstream.

#### Scenario: New tenant can sell without manual setup

- **WHEN** a brand-new user completes signup
- **THEN** the trigger has created exactly one branch "Casa Central" for the account and exactly one default cashbox on that branch
- **AND** the tenant can open a cash session on that cashbox without any manual branch or cashbox creation

#### Scenario: Seed is idempotent and does not duplicate

- **GIVEN** an account that already has a branch named "Casa Central" (e.g. created lazily by a prior stock movement)
- **WHEN** the provisioning seed runs for that account
- **THEN** no second "Casa Central" branch is inserted (`ON CONFLICT (account_id, name) DO NOTHING`)
- **AND** a default cashbox is added only if the account has no cashbox yet

#### Scenario: A seed failure does not abort the signup

- **WHEN** the branch or cashbox seed raises an unexpected error during `handle_new_user`
- **THEN** the error is caught, a warning is logged, and the signup still succeeds (profile, account, owner membership and emails are committed)
- **AND** the missing branch is still created later by the lazy-create safety net on the first stock movement

### Requirement: Backfill of existing tenants

The provisioning migration SHALL backfill existing accounts idempotently so pre-existing tenants also have a default branch and cashbox, adding only what is missing. The backfill SHALL be conflict-safe: it SHALL insert "Casa Central" only for accounts that have no branch by that name, and SHALL insert a default cashbox only for accounts that have a branch but no cashbox.

#### Scenario: Existing account without any branch is backfilled

- **GIVEN** an existing account with zero branches (registered but never moved stock)
- **WHEN** the provisioning migration runs
- **THEN** a "Casa Central" branch (`is_active = TRUE`, `status = 'active'`) and a default cashbox are created for that account

#### Scenario: Existing account with a branch but no cashbox gets only the cashbox

- **GIVEN** an existing account that already has a "Casa Central" branch (created lazily) and no cashbox
- **WHEN** the provisioning migration runs
- **THEN** no duplicate branch is inserted
- **AND** a default cashbox is added to that account's default branch

#### Scenario: Backfill is a no-op for fully provisioned accounts

- **GIVEN** an existing account that already has a branch and a cashbox
- **WHEN** the provisioning migration runs
- **THEN** no new branch and no new cashbox are inserted for that account

