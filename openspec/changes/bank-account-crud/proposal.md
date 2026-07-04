## Why

La pantalla `/finanzas/conciliacion` muestra "No hay cuentas bancarias activas. Registrá una cuenta para poder conciliar", pero **no existe ningún camino en la aplicación para crear una cuenta bancaria**: la tabla `bank_accounts` y las RPCs `rpc_create_bank_account`/`rpc_update_bank_account` existen y están testeadas desde `bank-account-ledger` (C1, migración `20260804000002`), pero nunca se expusieron por backend ni por frontend. Sin alta de cuentas, toda la familia BankReconciliation (routing de pagos C2 + conciliación C3) queda inalcanzable para el usuario.

## What Changes

- **Sidebar**: el ítem de navegación "Conciliación bancaria" (`frontend/components/app-sidebar.tsx`) se renombra a **"Bancos"**. El `<h1>` interno de la página puede seguir diciendo "Conciliación bancaria". (Decisión PO 2026-07-04; "Caja" descartado por colisión con la caja de sucursal C-28.)
- **Backend**: se agrega `POST /bank-accounts` en las 3 capas (router → service → repository) invocando la RPC ya existente `rpc_create_bank_account`. Nuevo schema Pydantic v2 `BankAccountCreate` (name requerido; cbu opcional pero si viene = 22 dígitos; alias opcional; currency default `ARS`; opening_balance >= 0 opcional; opening_date opcional) y schema de respuesta con la fila creada.
- **Frontend**: mutación `createBankAccount` en `use-bank-accounts.ts` con invalidación de `queryKeys.bankAccounts`, y un formulario de alta (React Hook Form + Zod, dialog shadcn) accesible desde la pantalla de conciliación — botón "Nueva cuenta bancaria" en el empty state y botón secundario en el header de la card cuando ya hay cuentas.
- **Fuera de scope** (documentado, no se toca): edición/desactivación de cuentas desde la UI (la RPC `rpc_update_bank_account` existe; la pantalla de gestión queda para un change futuro si el PO la pide), import de extracto y todo lo de conciliación C3.

## Capabilities

### New Capabilities
<!-- Ninguna. La capability bank-account ya existe; este change extiende su superficie de acceso. -->

### Modified Capabilities
- `bank-account`: se agrega el requisito de **exponer el alta de cuentas bancarias por API y UI** — hoy la capability describe la existencia de las RPCs (`rpc_create_bank_account`/`rpc_update_bank_account`) pero no exige ningún endpoint HTTP ni pantalla de alta. El delta agrega el endpoint `POST /bank-accounts` (3 capas, JWT-passthrough, mapeo de ERRCODEs P0400/P0401/P0403/P0411) y el flujo de alta desde la pantalla de conciliación.

## Impact

- **Backend** (FastAPI): `backend/routers/bank_accounts.py` (agregar `POST`), `backend/services/bank_accounts.py` (nuevo — service layer con guard `require_role`, hoy inexistente para esta ruta), `backend/schemas/bank_accounts.py` (nuevo `BankAccountCreate` + respuesta), `backend/repositories/bank_account_repository.py` (agregar `create()` que llama `rpc_create_bank_account`). Errores mapeados vía `backend/core/errors.py`.
- **Frontend** (Next.js/React): `frontend/components/app-sidebar.tsx` (rename label), `frontend/hooks/data/use-bank-accounts.ts` (mutación create), nuevo `frontend/components/bank-accounts/BankAccountFormDialog.tsx` (form RHF+Zod), `frontend/app/(dashboard)/finanzas/conciliacion/page.tsx` (wiring del botón + dialog en empty state y header de card).
- **DB**: sin migraciones nuevas — la RPC `rpc_create_bank_account(text, text, text, text, text, numeric, date)` ya existe, es SECURITY DEFINER, está `GRANT`eada a `authenticated` y testeada. NO crea movimiento de apertura: solo inserta en `bank_accounts` (el `opening_balance` es la base de cálculo del primer `balance_after` de `bank_movements`, no un movimiento).
- **Tests**: pytest backend (mock asyncpg, AAA) para router/service/repository del POST; Vitest frontend para la mutación y validación Zod del form.
- **Governance**: BAJO-MEDIO — CRUD de catálogo sobre una RPC ya existente y testeada; no toca dinero, RLS, ni contabilidad.
