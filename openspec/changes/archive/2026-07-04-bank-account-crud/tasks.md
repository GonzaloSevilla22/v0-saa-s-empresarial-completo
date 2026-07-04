# Tasks — bank-account-crud

> Governance: BAJO-MEDIO (CRUD de catálogo sobre RPC existente y testeada). TDD estricto: RED → GREEN → TRIANGULATE → REFACTOR por comportamiento.
> Sin migraciones nuevas — `rpc_create_bank_account` ya existe (`20260804000002_bank_account_ledger.sql`).

## 1. Backend — schema Pydantic v2

- [x] 1.1 RED: test de `BankAccountCreate` en `backend/tests/` — rechaza `name` vacío/blank y `cbu` no-22-dígitos; acepta payload mínimo (`name` solo) y payload completo. (AAA, sin DB.)
- [x] 1.2 GREEN: agregar `BankAccountCreate` a `backend/schemas/bank_accounts.py` (name requerido con strip+min_length; bank_name/alias/opening_date opcionales; `cbu: str | None` con `pattern=r"^\d{22}$"`; `currency: str = "ARS"`; `opening_balance: Decimal = 0` con `ge=0`).
- [x] 1.3 TRIANGULATE: casos borde — `currency` default `ARS` cuando se omite; `opening_balance` negativo rechazado; `cbu` de 22 dígitos válido aceptado; `cbu` con letras rechazado.

## 2. Backend — repository (llama la RPC)

- [x] 2.1 RED: test de `BankAccountRepository.create(...)` con asyncpg mockeado — asierta que se invoca `rpc_create_bank_account` con los 7 params en orden y que devuelve la fila creada (re-SELECT por id) mapeada a dict.
- [x] 2.2 GREEN: agregar `create(...)` a `backend/repositories/bank_account_repository.py` — `SELECT rpc_create_bank_account($1..$7)` (JWT-passthrough vía `base.py`), luego re-SELECT de la fila por `bank_account_id` para el shape completo de `BankAccountOut`.
- [x] 2.3 TRIANGULATE: test con `cbu = NULL` (omitido) y con `bank_name`/`alias`/`opening_date` provistos — verifica que los NULLs se pasan correctamente.

## 3. Backend — service layer (guard)

- [x] 3.1 RED: test de `create_bank_account(repo, auth, payload)` — con `auth` sin rol de escritura levanta el guard antes de llamar al repo (repo mock NO invocado); con rol válido delega al repo.
- [x] 3.2 GREEN: crear `backend/services/bank_accounts.py` con `create_bank_account(...)` aplicando `require_role(auth, ["user", "admin"])` (patrón `bank_reconciliation.py`) y delegando a `repo.create(...)`.
- [x] 3.3 TRIANGULATE: mapeo de ERRCODEs — test de que la excepción `P0401` de la RPC se traduce a HTTP 403 y `P0400`/`P0411` a 422 (vía `backend/core/errors.py`); agregar los códigos faltantes a `errors.py` si no están.

## 4. Backend — router (POST)

- [x] 4.1 RED: test de integración del endpoint `POST /bank-accounts` (TestClient + deps mockeadas) — 200/201 con payload válido; 403 sin permiso; 422 con `name` vacío y con `cbu` inválido.
- [x] 4.2 GREEN: agregar `POST /bank-accounts` a `backend/routers/bank_accounts.py` — solo validación (`BankAccountCreate`) + DI (`Depends`), delega a `create_bank_account` del service; `response_model=BankAccountOut`. Actualizar el docstring del módulo (ya no es "solo lectura").
- [x] 4.3 REFACTOR: correr la suite pytest del módulo bank + coverage; asegurar verde y limpiar duplicación. **Nota**: 88/88 tests del módulo bank verdes. Suite completa: 4 tests preexistentes de `test_payments.py` fallan por flake de conteo/timing (NO causado por este change — ver hallazgo en engram `bugs/test-payments-count-flake`, verificado por bisección en worktree aislado: se reproduce duplicando CUALQUIER archivo de test existente, incluso sin ejecutar ninguna de sus aserciones).

## 5. Frontend — mutación en el hook

- [x] 5.1 RED: test Vitest de `useBankAccounts().createBankAccount` — mockea `pythonClient.post` y asierta que hace `POST /bank-accounts` con el payload (snake_case) y que invalida `queryKeys.bankAccounts.all()` en `onSuccess`.
- [x] 5.2 GREEN: agregar `useQueryClient` + `useMutation` `createBankAccountMutation` a `frontend/hooks/data/use-bank-accounts.ts` (`pythonClient.post`, mapea la respuesta con `mapBankAccount`, invalida `queryKeys.bankAccounts.all()`); exponer `createBankAccount` y su mutation state. Mantener `useBankAccounts()` retrocompatible para los consumidores del picker.

## 6. Frontend — formulario (dialog RHF + Zod)

- [x] 6.1 RED: test Vitest del schema Zod del form — name requerido; cbu opcional con regex 22 dígitos; opening_balance ≥ 0; currency default `ARS`.
- [x] 6.2 GREEN: crear `frontend/components/bank-accounts/BankAccountFormDialog.tsx` (Client Component; RHF + zodResolver; dialog shadcn; campos name/bank_name/cbu/alias/currency/opening_balance/opening_date; onSubmit → `createBankAccount`; toast de éxito/error; cierra el dialog al confirmar). Sin `any`; PascalCase.
- [x] 6.3 TRIANGULATE: test de comportamiento del form — submit con name vacío no dispara la mutación; submit válido la dispara una vez.

## 7. Frontend — wiring en la pantalla + rename sidebar

- [x] 7.1 GREEN: en `frontend/app/(dashboard)/finanzas/conciliacion/page.tsx`, agregar el botón primario "Nueva cuenta bancaria" en el empty state (reemplaza/complementa el texto "No hay cuentas bancarias activas…") y un botón secundario en el `CardHeader` de la tarjeta de cuenta cuando `(bankAccounts ?? []).length > 0`; ambos abren `BankAccountFormDialog`.
- [x] 7.2 GREEN: renombrar el label del ítem de sidebar en `frontend/components/app-sidebar.tsx` (línea ~41) de "Conciliación bancaria" a "Bancos". Buscar tests que asierten ese texto y actualizarlos. **Nota**: no se encontró ningún test que asertara ese texto (grep verificado) — no hubo que actualizar tests existentes.
- [x] 7.3 REFACTOR: correr Vitest de los archivos tocados + typecheck; verificar que el flujo empty-state → crear → aparece en el selector funciona (sin `any`, sin `useEffect` para estado derivado). `tsc --noEmit` limpio; Vitest completo 49/49 archivos, 436/436 tests verdes.

## 8. Cierre

- [x] 8.1 Verificar suite completa (pytest backend módulo bank + Vitest frontend) en verde. Backend módulo bank: 88/88 verdes. Frontend: 49/49 archivos, 436/436 tests verdes. Suite completa backend: 876/880 verdes — 4 fallas preexistentes en `test_payments.py` NO causadas por este change (bisección en worktree aislado confirma que se reproduce agregando CUALQUIER archivo de test nuevo/duplicado al repo, incluso sin ejecutar sus aserciones — flake de conteo/timing de la suite, ver engram `bugs/test-payments-count-flake`).
- [x] 8.2 `openspec validate bank-account-crud --strict` en verde.
- [x] 8.3 Documentar fuera-de-scope en el PR: edición/desactivación desde UI (RPC `rpc_update_bank_account` existe, sin UI), import de extracto, movimiento de apertura (la RPC no lo crea — comportamiento intencional de C1).
