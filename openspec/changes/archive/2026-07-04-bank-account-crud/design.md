## Context

La capability `bank-account` fue entregada en `bank-account-ledger` (C1, V2.5 BankReconciliation), que creó la tabla `bank_accounts`, el ledger `bank_movements`, y las RPCs `rpc_create_bank_account` / `rpc_update_bank_account` (migración `supabase/migrations/20260804000002_bank_account_ledger.sql`). C2 (`bank-payment-routing`) agregó un backend de **solo lectura** (`GET /bank-accounts`) para el picker de cobro/pago. Nunca se expuso el **alta**: no hay `POST` en el backend ni formulario en el frontend. Resultado: `/finanzas/conciliacion` es un callejón sin salida cuando la organización no tiene cuentas cargadas.

Firma real de la RPC (verificada en la migración, líneas 362-422):

```sql
rpc_create_bank_account(
  p_name            text,
  p_bank_name       text    DEFAULT NULL,
  p_cbu             text    DEFAULT NULL,
  p_alias           text    DEFAULT NULL,
  p_currency        text    DEFAULT 'ARS',
  p_opening_balance numeric DEFAULT 0,
  p_opening_date    date    DEFAULT NULL
) RETURNS jsonb   -- SECURITY DEFINER, GRANT EXECUTE TO authenticated
```

La RPC resuelve `account_id` de la sesión vía `current_account_ids()`, aplica el guard `is_account_writer` (→ `P0401`), valida CBU `^[0-9]{22}$` (→ `P0411`), exige `name` no vacío (→ `P0400`), y si no hay cuenta activa lanza `P0403`. Devuelve un `jsonb` con `bank_account_id`, `account_id`, `name`, `currency`, `opening_balance`, `is_active`. **NO crea un movimiento de apertura**: solo inserta la fila en `bank_accounts`; el `opening_balance` es la base de cálculo del primer `balance_after` de `bank_movements` (`_register_bank_movement`: `balance_after = opening_balance + SUM(amount previos) + amount`).

## Goals / Non-Goals

**Goals:**
- Exponer el alta de cuentas bancarias de punta a punta (backend `POST /bank-accounts` en 3 capas + formulario en la pantalla de conciliación).
- Renombrar el ítem de sidebar a "Bancos" sin tocar el título interno de la página.
- Reutilizar la RPC existente sin migraciones nuevas; que la RLS org-based siga como red de seguridad vía JWT-passthrough.
- Cobertura de tests (pytest AAA + Vitest) siguiendo el patrón del hot-path bank (`bank_reconciliation`) y del CRUD análogo (`cost_centers`).

**Non-Goals:**
- Edición/desactivación de cuentas desde la UI (la RPC `rpc_update_bank_account` existe; la pantalla de gestión queda para un change futuro si el PO la pide).
- Import de extracto bancario y todo el flujo de conciliación (C3, ya entregado; no se toca).
- Validación del dígito verificador del CBU (solo formato de 22 dígitos, como ya establece la spec).
- Nuevas RPCs, cambios de RLS o de schema.

## Decisions

**D1 — Service layer nuevo para el POST, siguiendo el patrón del hot-path bank.**
El router actual (`bank_accounts.py`) no tiene service layer porque el `GET` es lectura directa. El `POST` es una mutación → cumple la regla dura "NUNCA lógica en el router" creando `backend/services/bank_accounts.py` con `create_bank_account(repo, auth, payload)` que aplica `require_role(auth, ["user", "admin"])` (mismo guard superficial que `bank_reconciliation.py`; el guard autoritativo por rol de cuenta es `is_account_writer` dentro de la RPC). Alternativa descartada: llamar la RPC desde el router — viola la arquitectura de 3 capas.

**D2 — El repository llama `SELECT rpc_create_bank_account($1..$7)` con JWT-passthrough.**
`BankAccountRepository.create(...)` usa `self.fetchrow(...)` sobre la RPC (misma mecánica que `BankReconciliationRepository`). NUNCA `service_role`: la conexión inyecta los claims del JWT → la RPC resuelve `account_id` con `current_account_ids()` y la RLS queda activa. La RPC devuelve `jsonb`; el repository parsea a dict. Se hace un `SELECT` de la fila recién creada (por `bank_account_id`) para devolver el shape completo de `BankAccountOut` (incluye `bank_name`, `cbu`, `alias` que el `jsonb` de la RPC no trae), o se construye la respuesta desde el payload + el `jsonb`. Se elige **re-SELECT por id** para consistencia con lo que persistió y para reutilizar `BankAccountOut` tal cual.

**D3 — Mapeo de ERRCODEs en `backend/core/errors.py`.**
La RPC lanza `P0400` (name requerido), `P0401` (no autorizado), `P0403` (sin cuenta activa), `P0411` (CBU inválido). Se mapean a `HTTPException` con status explícito: `P0400`/`P0411` → 422 (validación), `P0401` → 403, `P0403` → 409/403. Se verifica el mapeo existente en `errors.py` y se agregan los códigos faltantes siguiendo el patrón de la familia bank (P0431-P0434 ya mapeados).

**D4 — Pydantic v2 `BankAccountCreate` valida en el borde antes de tocar la DB.**
Campos: `name: str` (min_length tras strip, requerido), `bank_name: str | None`, `cbu: str | None` (si presente, `pattern=r"^\d{22}$"`), `alias: str | None`, `currency: str = "ARS"`, `opening_balance: Decimal = 0` (`ge=0`), `opening_date: date | None`. La validación de CBU se duplica intencionalmente en Pydantic (feedback temprano 422) y en la RPC (autoridad final `P0411`) — misma defensa en capas que el resto del backend. Respuesta: `BankAccountOut` existente.

**D5 — Frontend: dialog shadcn con RHF+Zod, disparado desde dos entradas.**
Nuevo `frontend/components/bank-accounts/BankAccountFormDialog.tsx` (Client Component, único componente cliente del flujo). Schema Zod espejo del Pydantic (name requerido; cbu opcional con regex 22 dígitos; opening_balance ≥ 0). La mutación vive en `use-bank-accounts.ts` (`createBankAccount` con `pythonClient.post`), `onSuccess` invalida `queryKeys.bankAccounts.all()`. En `conciliacion/page.tsx`: el empty state gana un botón primario "Nueva cuenta bancaria"; con cuentas existentes, un botón secundario en el header de la card `CardHeader`. Patrón tomado de `cost-centers/CostCenterManager.tsx` (CRUD análogo ya en el repo).

**D6 — Sin optimistic update.**
El catálogo cambia con poca frecuencia (`staleTime` 5 min); tras crear, invalidar la query es suficiente y más simple que un optimistic con rollback. Se elige invalidación pura (como `cost_centers`).

## Risks / Trade-offs

- **[Divergencia de validación entre Zod/Pydantic y la RPC]** → Se documenta que la RPC es la autoridad final; Zod/Pydantic son feedback temprano. Los tests cubren el path de error de la RPC (P0411) para asegurar que un CBU inválido que se cuele igual retorne 422, no 500.
- **[`opening_balance` sin movimiento de apertura puede confundir]** → Es el comportamiento intencional de C1 (el saldo inicial es base de cálculo, no un movimiento). Se documenta en el design; el form deja claro que es el "saldo inicial" de la cuenta. Fuera de scope generar un `bank_movement` de apertura.
- **[El re-SELECT tras la RPC agrega un round-trip]** → Aceptable: alta es una operación puntual, no hot-path; garantiza el shape completo y consistente con lo persistido.
- **[Rename de sidebar podría romper tests de navegación]** → Se busca "Conciliación bancaria" en tests antes de renombrar; si hay un test que asierta ese texto en el sidebar, se actualiza a "Bancos".

## Migration Plan

Sin migración de DB. Deploy estándar: merge a main → GitHub Actions despliega Vercel (frontend) y redeploya el backend en Render. Rollback = revert del PR (no hay estado nuevo en DB que revertir). El backend Render tiene cold start ~50s; el `POST` nuevo no cambia eso.

## Open Questions

- Ninguna bloqueante. (La edición/desactivación desde UI y el movimiento de apertura quedan explícitamente fuera de scope por decisión de este change.)
