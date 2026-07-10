# Design: bank-reconciliation

## Context

C3 de la secuencia BankReconciliation (decisión PO 2026-06-27, explore engram `opsx/bank-reconciliation/explore`). El estado que hereda:

- **C1** (`bank-account-ledger`, migr `20260804000002`): `bank_accounts` (root org-level) + `bank_movements` (ledger append-only, `balance_after`, `account_id` denormalizado, enum completo de 7 tipos ya fijado) + helper intra-tx `_register_bank_movement` + RPC manual que solo acepta `transfer_in/transfer_out/manual_adjustment`.
- **C2** (`bank-payment-routing`, migr `20260804000007`): los pagos/cobros con método bancario escriben `bank_movement` automático intra-tx y el journal postea `1110 Banco` async vía Consumer 3.
- **Arquitectura de dos ledgers**: `bank_movements` = OPERATIVO (lo que se concilia contra el extracto); journal `1110` = espejo CONTABLE downstream. **La conciliación jamás opera sobre el journal.**
- Modelo V3 adoptado (2026-07-02): `reconciliation_sessions` nace con FSM explícita y motivo obligatorio en acciones destructivas (RN-A), y fechas con semántica local del tenant (RN-D5). El retrofit genérico `v3-document-status-history` aún no existe — ver D3.

Governance **MEDIO**: greenfield sobre el ledger existente; no toca dinero en vuelo, hot path de venta/pago ni contabilidad.

## Goals / Non-Goals

**Goals:**
- Importar extractos como datos crudos inmutables (`bank_statement_imports` + `bank_statement_lines`).
- Sesión de conciliación por cuenta + período con FSM `OPEN → CLOSED`, cierre con `difference` calculada y motivo obligatorio si ≠ 0.
- Matching 1:1/1:N/N:1 con validación de sumas, sugerencias automáticas solo 1:1, undo con motivo sin borrar historia.
- "Solo anotar" (PO): habilitar `fee`/`tax_debit`/`interest` en la carga manual para registrar cargos del extracto y conciliarlos.
- Estado de conciliación visible en el ledger (`reconciliation_status`/`reconciled_at` en `bank_movements`).

**Non-Goals (explícitos, decisión PO):**
- Auto-generación de asientos contables de ajuste (fast-follow; V1 el journal no se toca).
- Netting de `card_settlement` (bruto ≠ neto por comisión+retenciones) — sigue diferido.
- Sugerencias por IA, integración con APIs bancarias, import multi-moneda.
- Reapertura de sesiones cerradas (corrección = sesión nueva).
- Retrofit genérico `DocumentStatusHistory` (change `v3-document-status-history` separado).

## Decisions

**D1 — Match como grafo vía `reconciliation_matches` con `match_group`, NO FK en `bank_movements`.** C1 dejó anotada la idea de `statement_line_id` en `bank_movements`; se descarta: una FK singular no representa N:1 (varias líneas → un movimiento). El grupo de match es la unidad: todas las filas (línea o movimiento) de un grupo comparten `match_group UUID`; la RPC crea el grupo completo atómicamente (arrays de `statement_line_ids[]` + `bank_movement_ids[]`), valida Σ montos líneas = Σ montos movimientos (`P0433`) y que ningún participante tenga match `active` (`P0434`). Alternativa considerada (tabla de pares línea↔movimiento sin grupo): no valida sumas de conjuntos.

**D2 — El backend recibe filas normalizadas; el parseo vive en el cliente.** Contrato del import: `POST` con `{file_name, file_hash, lines: [{line_no, value_date, description, amount, balance?}]}` validado por Pydantic. El frontend parsea CSV (pipeline de import ya existente en el codebase — patrón del importador de productos) y normaliza Excel a filas del mismo shape. Ventaja: el backend no adquiere dependencias de parsing (ni pandas ni openpyxl en Render free) y el contrato es testeable puro. Dedupe primario por `file_hash` sobre la misma cuenta (replay idempotente). Cap V1: 5.000 líneas por import.

**D3 — FSM local a la sesión, alineada al modelo V3 sin esperar el retrofit.** `reconciliation_sessions.status` con CHECK `('open','closed')`, transiciones validadas en las RPCs (`P0432 session_closed` para toda acción sobre cerrada), índice UNIQUE parcial `ON (bank_account_id) WHERE status = 'open'` (anti doble-apertura, espejo de `cash_sessions`). El "historial" queda cubierto por los datos del propio dominio: la sesión registra `opened_by/at`, `closed_by/at`, `close_reason`; los matches registran `matched_by/at` y los undo `undone_by/at` + `undo_reason` sin borrar filas. Cuando llegue `v3-document-status-history`, la sesión se enchufa al patrón genérico sin migración de datos (las transiciones son reconstruibles).

**D4 — Sugerencias = query read-only, nunca persistidas ni auto-confirmadas.** Endpoint `GET .../suggestions`: pares 1:1 candidatos con monto exacto y `value_date` dentro de ±3 días (constante `SUGGESTION_DATE_WINDOW_DAYS = 3`), ambos sin match activo. Confirmar una sugerencia pasa por la misma RPC de match que un match manual (un solo camino de escritura). 1:N/N:1 son siempre manuales en V1.

**D5 — Denormalizar estado en `bank_movements`, derivar en `bank_statement_lines`.** El ledger es una tabla long-lived con UI propia → columnas `reconciliation_status`/`reconciled_at` mantenidas por las RPCs de match/unmatch en la misma transacción. Las líneas de extracto se consultan siempre en el scope de un import/sesión (volumen chico, cientos) → su estado se deriva con EXISTS sobre matches `active`, sin columna propia. Los campos económicos del movimiento siguen inmutables — el UPDATE controlado de columnas de estado no rompe el carácter append-only del ledger (mismo criterio que `processed_at` en `events`).

**D6 — Patrones heredados de C1/C2 (no reinventar):** RLS SELECT-only por `account_id IN (SELECT current_account_ids())` (nunca `= ANY(...)` — la fn devuelve SETOF, lección C-28); escritura solo vía RPCs `SECURITY DEFINER` con `SET search_path` y EXECUTE revocado donde corresponda; `is_account_writer` → `P0401`; cuenta inexistente/inactiva → `P0412`; ERRCODEs custom de 5 chars nuevos: `P0430` (import duplicado, si no se opta por replay), `P0431` (motivo requerido), `P0432` (sesión cerrada), `P0433` (sumas no coinciden), `P0434` (ya matcheado) — mapeados en `backend/core/errors.py`.

**D7 — Idempotencia:** import → slot en `operation_idempotency` con `operation_kind = 'bank_statement_import'` (clave = `idempotency_key` del cliente; el `file_hash` es el dedupe de dominio, ambos coexisten); cierre de sesión → naturalmente idempotente-por-estado (`P0432` en el segundo intento); match/unmatch → idempotencia por validación de estado. **El CHECK de `operation_idempotency.operation_kind` se extiende en la MISMA migración** (regla C-30 — 4º change consecutivo que la confirmó).

**D8 — Una sola migración SQL, aditiva.** Tablas nuevas + `ALTER TABLE bank_movements ADD COLUMN ... DEFAULT 'unreconciled'` + `CREATE OR REPLACE rpc_register_bank_movement` (ampliar tipos manuales; misma firma → sin riesgo de overload 42725, verificar igualmente con `DROP FUNCTION IF EXISTS` de firmas viejas si hiciera falta) + RPCs nuevas + gates TDD. Gotchas CI ya conocidos que la migración respeta: fecha > última migración existente (`ls supabase/migrations | sort | tail -1` antes de nombrar); gates comportamentales SOLO en DB vacía (`count(*) = 0 FROM accounts` → corre en CI, no-op en prod); sub-bloques `BEGIN/EXCEPTION` (jamás `SAVEPOINT/ROLLBACK TO` en plpgsql); `WHEN OTHERS` con discriminación de mensaje para errcodes custom (P04xx no son capturables por `WHEN raise_exception`); anchor sintético SIN insertar en `auth.users` (dispara `handle_new_user` — lección C2: resolver la cuenta auto-creada desde `account_members`); todo upsert sobre tabla con CHECK = UPDATE-then-INSERT.

**D9 — Backend y UI.** Router `bank_reconciliation.py` (prefijo `/bank-accounts/{id}/...` para import/sesiones + `/reconciliation-sessions/{id}/...` para match/close) → service con guards (`require_role` owner/admin vía `is_account_writer` en DB) → repository que llama RPCs. UI: página de conciliación dentro del detalle de cuenta bancaria — wizard de import, vista de dos paneles (extracto vs. movimientos, filtros por estado), botón "Sugerencias", cierre con resumen (saldos + diferencia + motivo). Hook React Query `use-bank-reconciliation`.

## Risks / Trade-offs

- **[Formatos de extracto heterogéneos por banco]** → el contrato de filas normalizadas mueve la variabilidad al cliente; presets de mapeo por banco = fast-follow. V1 documenta el shape esperado en la UI.
- **[Usuario matchea mal y cierra la sesión]** → undo con motivo preserva historia mientras la sesión está abierta; una sesión cerrada no se reabre (corrección = sesión nueva del mismo período — trade-off aceptado para mantener CLOSED terminal).
- **[Derivar estado de líneas por EXISTS podría ser lento en extractos enormes]** → cap de 5.000 líneas + índices sobre `reconciliation_matches (statement_line_id) WHERE status='active'`; si un banco excede, se pagina.
- **[`DEFAULT 'unreconciled'` sobre `bank_movements` con volumen]** → hoy el ledger es joven (C1/C2 recién live); el ALTER con DEFAULT constante en PG ≥ 11 no reescribe la tabla. Riesgo bajo.
- **[Doble fuente de dedupe en import (file_hash + idempotency_key)]** → complejidad marginal; el hash cubre "mismo archivo re-subido otro día", la key cubre el doble-click. Se documenta en la RPC.

## Migration Plan

1. PR único (rama `feat/bank-reconciliation`): migración SQL + backend + frontend + tests.
2. CI `validate-kpis` valida la migración con gates TDD en DB efímera (único validador — no hay Docker local).
3. Merge a main → GitHub Actions despliega (Vercel + `db push` + Render redeploy) — sin pasos manuales.
4. Rollback: revertir el PR. Seguro: tablas nuevas sin escritores previos, columnas aditivas con default, `rpc_register_bank_movement` se restaura con la migración siguiente (CREATE OR REPLACE del cuerpo anterior).

## Open Questions

Ninguna bloqueante — las decisiones estructurales las tomó el PO en el explore (2026-06-27: V1 solo-anotar, matching 1:1/1:N/N:1 manual, dos ledgers, org-level). Decisiones menores tomadas acá y sujetas a checkpoint del apply (governance MEDIO): ventana de sugerencia ±3 días (D4), cap 5.000 líneas (D2), derivación de estado en líneas (D5).
