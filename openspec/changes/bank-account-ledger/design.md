## Context

EmprendeSmart (V2.5 Finanzas) ya tiene dos ledgers de dinero: **efectivo** (`cash_movements`, C-28 — append-only, `amount` con signo, `balance_after`, helper intra-tx `c28_register_cash_movement`) y **cuentas corrientes** (`customer_account_movements`/`supplier_account_movements`, C-30). Falta el tercer ledger: el **banco**. Hoy:

- **No existe ninguna tabla `bank_*`** (greenfield — verificado en `supabase/migrations/`). Como son tablas NUEVAS, la regla dura "ninguna feature nueva sobre tablas en retirada" (RN-97, `knowledge-base/05`) **NO aplica**: C1 no toca ni una tabla legacy.
- El plan de cuentas de `journal-entry-outbox` reserva `1110 Banco` pero **nadie postea ahí** (`_journal_post_from_event` mapea TODO `PaymentReceived` → `1100 Caja` ignorando el método; las transferencias se cuentan mal como efectivo hoy). **C1 no arregla esto.**
- Las RPCs C-30 `rpc_register_payment_received/made` **no capturan `payment_method`** (firma: `idempotency_key, client_id/supplier_id, amount, reference_*`). **C1 no las modifica.**

Este es el **change C1 de 3** de BankReconciliation: C1 `bank-account-ledger` → C2 `bank-payment-routing` → C3 `bank-reconciliation`. C1 entrega un dominio bancario autónomo con **carga manual únicamente**, espejando fielmente el patrón de C-28.

**Principio arquitectónico central (dos ledgers sincronizados por el outbox):**
> `bank_movements` = ledger **OPERACIONAL** (espejo de `cash_movements`, fuente de verdad del saldo bancario y base de la conciliación futura C3). La cuenta contable `1110 Banco` = espejo **CONTABLE**, alimentado **asincrónicamente** por el Consumer 3 del outbox (`_journal_post_from_event`). La conciliación (C3) opera SIEMPRE sobre `bank_movements`, **NUNCA** sobre el journal. **C1 no postea al journal — ese cableado es de C2.**

## Goals / Non-Goals

**Goals:**
- Crear el agregado root `bank_accounts` (org-level, tenancy directa por `account_id`) con validación de CBU, `is_active` y saldo de apertura.
- Crear el ledger append-only `bank_movements` (espejo de `cash_movements`): `amount` con signo, `balance_after`, `value_date`, taxonomía `movement_type` **completa fijada ya** en el CHECK.
- Entregar el helper intra-tx `_register_bank_movement` como **contrato C1→C2** (análogo de `c28_register_cash_movement`).
- Entregar RPCs de carga **manual** (`rpc_create_bank_account`, `rpc_update_bank_account`, `rpc_register_bank_movement`) con guard `is_account_writer`.
- RLS correcta (sin subquery por fila en el ledger de alto volumen) + índices.
- Dejar **documentadas** (no construidas) las costuras para C2 y C3.

**Non-Goals (fuera de scope — C2/C3):**
- Conciliación: import de extracto (CSV/Excel), matching, `reconciliation_sessions`, `statement_lines` → **C3**.
- Ruteo automático de pagos por `payment_method`, captura de `payment_method`, posteo a `1110 Banco` en el journal, reinterpretar `payment_method = 'other'` en ventas → **C2**.
- Emitir movimientos de tipo `card_settlement`/`fee`/`tax_debit`/`interest` (el CHECK los acepta, pero la RPC manual de C1 los **rechaza**).
- Cualquier UI bancaria más allá de lo mínimo (queda para cuando C2/C3 definan los flujos).

## Decisions

### D1 — `bank_accounts` es ORG-LEVEL (tenancy directa), no branch-scoped
A diferencia de `cashboxes` (que cuelgan de `branches`, porque la caja es física de una sucursal), una cuenta bancaria pertenece a la **organización**, no a una sucursal: el mismo CBU sirve a todas las sucursales. Por eso `bank_accounts.account_id` es **FK directa a `accounts(id)`** (igual que `journal_entries.account_id` y `customer_accounts.account_id`).
- **RLS**: `account_id IN (SELECT current_account_ids())` — directa, sin cadena de FKs.
- `bank_movements.branch_id` es **nullable, solo analítica** (FK a `branches`): permite atribuir un movimiento a una sucursal sin acoplar el ledger a la sucursal.
- *Alternativa descartada*: colgar de `branches` como las cajas → forzaría una cuenta bancaria por sucursal, irreal para una PYME con un único CBU.

### D2 — `account_id` denormalizado en `bank_movements` (RLS sin subquery por fila)
`bank_movements` es un ledger de **alto volumen** (cada transferencia, acreditación, comisión). Resolver la RLS vía subquery `bank_account_id → bank_accounts.account_id` por fila degrada el SELECT a escala. Se **denormaliza `account_id NOT NULL` en `bank_movements`** y se indexa, exactamente como `journal_lines` (D7 de `journal-entry-outbox`) y `customer_account_movements`/`supplier_account_movements` (C-30).
- **RLS de `bank_movements`**: `account_id IN (SELECT current_account_ids())` — directa, sin JOIN.
- El helper copia `account_id` desde la cabecera `bank_accounts` al INSERT — valor **inmutable**.
- *Alternativa descartada*: RLS derivada `bank_account_id IN (SELECT id FROM bank_accounts WHERE account_id IN (...))` como `cash_movements`. Funciona, pero `cash_movements` está varios niveles abajo y el proyecto ya pagó esa deuda en C-30/journal denormalizando. Recomendado y elegido: denormalizar.
- *Trade-off*: el `account_id` se duplica; mitigado porque es inmutable y el helper es el único escritor (no hay UPDATE de cabecera que lo desincronice).

### D3 — Taxonomía `movement_type` completa fijada AHORA; la RPC manual acepta solo un subconjunto
El CHECK de `bank_movements.movement_type` fija ya **el enum completo** para no migrar el constraint después:
`'transfer_in'`, `'transfer_out'`, `'card_settlement'`, `'fee'`, `'tax_debit'`, `'interest'`, `'manual_adjustment'`.
- **C1 solo emite/acepta** el subconjunto manual/transferencia: `transfer_in`, `transfer_out`, `manual_adjustment`. La RPC `rpc_register_bank_movement` **rechaza** cualquier otro con `P0410` (incluso si el CHECK lo aceptaría a nivel tabla).
- **RESERVADOS para C2/C3** (documentado, no emitido en C1): `card_settlement`, `fee`, `tax_debit` (impuesto al cheque, Ley 25.413), `interest`.
- **`card_settlement` es espinoso**: el bruto vendido ≠ el neto acreditado (comisión del adquirente + retenciones de IVA/Ganancias/IIBB). Modelarlo (¿un movimiento neto? ¿bruto + `fee` + `tax_debit` separados?) es una decisión de **C2/C3**, no de C1. Se deja flagueado aquí.
- *Alternativa descartada*: fijar solo los 3 tipos manuales ahora y ampliar el CHECK en C2 → obliga a un `ALTER ... DROP/ADD CONSTRAINT` sobre una tabla ya con datos. Fijar el enum completo de una es más barato y no cuesta nada hoy.

### D4 — Helper intra-tx `_register_bank_movement` = contrato C1→C2 (espejo de `c28_register_cash_movement`)
`_register_bank_movement(p_bank_account_id, p_amount, p_type, p_source_doc_type, p_source_doc_ref, p_value_date, p_branch_id, p_description)`:
- `SECURITY DEFINER`, `SET search_path = public`, **NO abre transacción propia** (corre en la transacción del llamador).
- `FOR UPDATE` sobre la fila `bank_accounts` para serializar el cálculo de `balance_after` (igual que C-28 lockea la sesión).
- Calcula `balance_after = (último balance_after de la cuenta, o opening_balance) + p_amount`, copia `account_id` desde la cabecera (D2), inserta append-only.
- **REVOKE ALL FROM PUBLIC/anon/authenticated**: callable SOLO desde las RPCs SECURITY DEFINER de este módulo y desde **las futuras RPCs de pago de C2** (que rutearán al banco). Este es el mismo patrón por el que C-29 reutilizó `c28_register_cash_movement` en el hot path de la venta.
- *Por qué un helper separado de la RPC*: para que C2 pueda invocarlo **dentro** de la misma transacción de la RPC de pago (atomicidad pago+movimiento bancario), sin pasar por el guard/validación de la RPC pública manual.

### D5 — Escritura SOLO vía RPCs SECURITY DEFINER; sin policy de escritura directa
Ambas tablas tienen `ENABLE ROW LEVEL SECURITY` + **solo policy SELECT**. **Ausencia deliberada** de INSERT/UPDATE/DELETE policies (patrón C-28/C-30/journal): `authenticated` no escribe directo; toda escritura pasa por RPC SECURITY DEFINER que aplica `is_account_writer`. `bank_movements` es **append-only** (sin UPDATE/DELETE jamás).
- RPCs públicas con `REVOKE ALL FROM PUBLIC, anon; GRANT EXECUTE TO authenticated` (higiene del proyecto).
- Guard de escritor: `is_account_writer(account_id)` → `P0401` si no (mismo código y semántica que C-28/C-30).

### D6 — Idempotencia en `rpc_register_bank_movement` (sí, mirror de C-30)
La carga manual de un movimiento bancario es susceptible a doble-submit (doble click, retry de red). Se **adopta el patrón de idempotencia de C-30**: la RPC recibe `p_idempotency_key text` y reclama un slot en `operation_idempotency (user_id, operation_kind='bank_movement', idempotency_key)` con `ON CONFLICT DO NOTHING`; en replay devuelve el resultado original sin re-insertar.
- *Por qué*: un movimiento bancario es un hecho monetario; duplicarlo descuadra el saldo y la conciliación futura. Las RPCs `rpc_create_bank_account`/`rpc_update_bank_account` **no** necesitan idempotency_key (crear una cuenta dos veces es benigno/visible y editable; no hay efecto monetario acumulativo).
- *Alternativa descartada*: sin idempotencia, confiar en el cliente → C-30 ya estableció que los hechos monetarios la llevan.

### D7 — Validación de CBU (22 dígitos)
`cbu` es `text` nullable (una cuenta puede registrarse sin CBU y completarse luego). Cuando se provee, SHALL ser exactamente **22 dígitos numéricos** (`cbu ~ '^[0-9]{22}$'`). La validación va en la RPC (`P0411` si falla) **y** como `CHECK` a nivel tabla como red de seguridad (`cbu IS NULL OR cbu ~ '^[0-9]{22}$'`).
- No se valida el dígito verificador del CBU en C1 (algoritmo módulo 10 de los bloques) — se difiere; el formato de 22 dígitos cubre el 99% de los errores de tipeo. Flagueado como posible refinamiento C2/C3.

### D8 — ERRCODEs (espacio P04xx — verificados libres por grep de migraciones)
En uso hoy: `P0400, P0401, P0403, P0404, P0409, P0422, P0450, P0451`. C1 reclama:
| Código | Significado |
|---|---|
| **P0401** | escritor no autorizado (`is_account_writer` falla) — *reusa el estándar del proyecto* |
| **P0410** | `movement_type` inválido para la RPC manual (tipo reservado a C2/C3, p.ej. `card_settlement`) — **nuevo, libre** |
| **P0411** | CBU inválido (no 22 dígitos) — **nuevo, libre** |
| **P0412** | cuenta bancaria no encontrada / inactiva — **nuevo, libre** |

`P0410`–`P0412` y `P0402`/`P0405`–`P0408` están libres (grep sin match). Se usa el rango contiguo `P0410+` para el módulo bancario.

### D9 — Capability naming del spec: split `bank-account` + `bank-movement`
El proyecto ya divide el dominio de caja en dos specs: `cash-session` + `cash-movement`. Por consistencia, C1 crea **dos specs**: `bank-account` (el agregado root) y `bank-movement` (el ledger + helper + RPC manual). Mismo formato delta `## ADDED Requirements` con `#### Scenario:`.

### D10 — Migración: `20260804000002_bank_account_ledger.sql`
Timestamp libre verificado (última existente `20260803000003`). Estructura espejo de `20260701000001_c28_cash_session.sql`: header con CHANGE/ERRCODEs/GOVERNANCE/APPLY/ROLLBACK, tablas → índices → RLS → helper → RPCs → DO-block de gates. **APPLY solo vía `npx supabase db push`** (CI al mergear) — NUNCA MCP `apply_migration` (desincroniza el history). Sin pérdida de datos en rollback (feature nueva, 0 filas en prod).

## Forward-compat seams (DOCUMENTADAS — NO construidas en C1)

- **Seam C2 (`bank-payment-routing`)**: las RPCs de pago C-30 ganarán/usarán `payment_method`; cuando sea bancario, llamarán a **`_register_bank_movement`** (transferencia) en la misma transacción **y** postearán a `1110 Banco` en el journal (vía outbox/Consumer 3). C2 reinterpretará el `payment_method = 'other'` de ventas. El helper de C1 está diseñado para ser invocado intra-tx exactamente así (D4). C1 **no** modifica `rpc_register_payment_received/made` ni `_journal_post_from_event`.
- **Seam C3 (`bank-reconciliation`)**: agregará **columnas aditivas nullable** a `bank_movements` — `statement_line_id uuid`, `reconciliation_status text`, `reconciled_at timestamptz` — más tablas nuevas de extracto (`bank_statement_lines`) y sesión de conciliación (`reconciliation_sessions`). **`bank_movements` se diseña para que estas columnas sean puramente aditivas** (ningún rewrite): el ledger no asume nada sobre conciliación, el `id` es estable, y el matching de C3 operará sobre `bank_movements` (nunca sobre el journal).

## Risks / Trade-offs

- **[Saldo bancario operacional ≠ saldo contable `1110`]** → Es esperado y por diseño (dos ledgers, D-principio). En C1 `1110` está vacío, así que no hay divergencia observable. C2 los sincroniza vía outbox; C3 concilia el operacional contra el extracto. Mitigación: documentar el principio en el header de la migración y en los specs.
- **[Denormalización de `account_id` puede desincronizarse]** → Mitigado: `account_id` es inmutable, copiado por el único escritor (el helper), sin UPDATE de cabecera que lo cambie. Igual que journal_lines/C-30 (patrón probado).
- **[Fijar el enum completo "adivina" tipos futuros]** → Si C2/C3 necesitan un tipo no previsto, un `ALTER CONSTRAINT` puntual lo agrega; pero los 7 tipos cubren el vocabulario bancario PYME AR estándar. Riesgo bajo. `manual_adjustment` actúa de válvula de escape.
- **[`card_settlement` bruto≠neto no resuelto]** → Explícitamente diferido a C2/C3 (D3). C1 ni lo emite ni lo modela; solo reserva el nombre en el enum.
- **[CBU sin dígito verificador]** → 22-dígitos cubre errores de tipeo comunes; el DV se difiere (D7). Riesgo aceptado para C1.

## Migration Plan

1. **Apply**: la migración `20260804000002_bank_account_ledger.sql` se aplica por CI al mergear el PR (`npx supabase db push`). **No** se aplica manualmente ni vía MCP.
2. **Verificación post-push**: `SELECT` de `information_schema.tables` para `bank_accounts`/`bank_movements`; `information_schema.routines` para el helper + 3 RPCs; los gates DO-block del propio archivo validan RED→GREEN en el apply.
3. **Rollback** (header de la migración): `DROP FUNCTION` de las 3 RPCs + helper, `DROP TABLE bank_movements, bank_accounts` (orden inverso de FKs). Sin pérdida de datos (feature nueva, 0 filas en prod).

## Open Questions

- Ninguna bloqueante para C1. (Pendientes a resolver en C2/C3: modelado de `card_settlement` bruto/neto; validación del DV del CBU; columnas de conciliación de C3 — todas documentadas arriba como seams/risks, fuera de scope de C1.)
