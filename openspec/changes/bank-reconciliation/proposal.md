# Proposal: bank-reconciliation

## Why

C1 (`bank-account-ledger`) y C2 (`bank-payment-routing`) dejaron un ledger bancario operativo (`bank_movements`) que ya recibe los pagos/cobros bancarios del sistema — pero hoy nadie puede verificar que ese ledger coincida con lo que el banco realmente registró. Sin conciliación, un cobro que nunca se acreditó, una comisión no cargada o un movimiento duplicado pasan invisibles: el saldo del sistema y el saldo real divergen en silencio. C3 cierra la secuencia BankReconciliation (V2.5 Finanzas, decisión PO 2026-06-27): importar el extracto del banco, hacer matching contra `bank_movements` y cerrar períodos conciliados con diferencia explicada.

## What Changes

- **Import de extracto bancario**: carga del extracto (CSV nativo; Excel normalizado a filas en el cliente) contra una `bank_account`, con dedupe por hash de archivo e idempotencia. Las líneas quedan en `bank_statement_lines` como datos crudos inmutables del banco.
- **`ReconciliationSession`**: sesión de conciliación por cuenta bancaria + período, con FSM explícita `OPEN → CLOSED` (modelo V3 RN-A: transiciones válidas como datos, estado terminal, anti doble-apertura por cuenta). El cierre computa saldo del extracto vs. saldo de `bank_movements` a la fecha; una diferencia ≠ 0 exige motivo (RN-A5).
- **Matching 1:1 / 1:N / N:1**: vínculos línea(s)-de-extracto ↔ movimiento(s) vía `reconciliation_matches` (grupos de match). Sugerencias automáticas V1 solo 1:1 (monto exacto + ventana de fecha); 1:N y N:1 son resolución manual. Deshacer un match exige motivo y no borra — marca `undone` (append-only en espíritu, RN-A3).
- **V1 "solo anotar"** (decisión PO): comisiones, impuestos (Ley 25.413) e intereses que aparecen en el extracto y no existen en el sistema se cargan como `bank_movement` manual y se concilian. Para eso, `rpc_register_bank_movement` **amplía** los tipos manuales aceptados: `fee`, `tax_debit`, `interest` (hoy rechazados como reservados). La auto-generación de asientos de ajuste es fast-follow, NO entra en C3.
- **Estado de conciliación en el ledger**: `bank_movements` gana columnas aditivas `reconciliation_status` (`unreconciled` | `matched`) y `reconciled_at`, mantenidas por los RPCs de match/unmatch (denormalización para listar sin join).
- **La conciliación NUNCA toca el journal**: opera exclusivamente sobre el ledger operativo (`bank_movements` vs. extracto). El espejo contable `1110 Banco` sigue alimentándose solo por el Consumer 3 del outbox (C2). Cero cambios en `_journal_post_from_event` ni en el plan de cuentas.
- **RN-D5 (modelo V3)**: todos los filtros de período y el corte de sesión usan semántica de fecha local del tenant sobre `value_date` (tipo `date` en los bordes).
- Backend FastAPI 3 capas (routers → services → repositories) + UI de conciliación (import, matching de dos paneles, cierre con resumen).

## Capabilities

### New Capabilities

- `bank-reconciliation`: import de extracto (archivos + líneas inmutables), sesiones de conciliación con FSM y cierre con diferencia explicada, matching 1:1/1:N/N:1 con sugerencias automáticas 1:1 y resolución manual, deshacer con motivo.

### Modified Capabilities

- `bank-movement`: (1) la registración manual acepta además `fee`, `tax_debit` e `interest` (antes reservados — habilita el "solo anotar" de V1); (2) los movimientos exponen estado de conciliación (`reconciliation_status`, `reconciled_at`) mantenido exclusivamente por los RPCs de conciliación; sigue prohibido el UPDATE directo.

## Impact

- **DB (migración nueva, aditiva — sin DDL destructivo)**: tablas `bank_statement_imports`, `bank_statement_lines`, `reconciliation_sessions`, `reconciliation_matches`; `ALTER TABLE bank_movements ADD COLUMN` (status/fecha de conciliación); RPCs `SECURITY DEFINER` nuevos (import, open/close session, match, unmatch) + `CREATE OR REPLACE` de `rpc_register_bank_movement` (ampliar tipos manuales); extensión del CHECK de `operation_idempotency.operation_kind` con los kinds nuevos (regla C-30: mismo change, misma migración).
- **Backend**: router/service/repository `bank_reconciliation` nuevos; sin cambios en services de pagos ni journal.
- **Frontend**: página de conciliación por cuenta bancaria (import + matching + cierre); hook React Query nuevo.
- **Sin impacto en**: hot path de venta/pago (C2 intacto), journal/Consumer 3, cajas (`cash_movements`), RLS existente de `bank_accounts`/`bank_movements` (los patrones se replican: SELECT por `account_id`, escritura solo vía RPC).
- **Governance**: MEDIO (greenfield sobre ledger existente; no toca dinero en vuelo ni contabilidad). Checkpoints en apply; decisiones no obvias registradas en design.md.
