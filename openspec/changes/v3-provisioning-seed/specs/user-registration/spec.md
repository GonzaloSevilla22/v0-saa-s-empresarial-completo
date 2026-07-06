## MODIFIED Requirements

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

## ADDED Requirements

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
