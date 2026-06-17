# Design — v21-cash-session (C-28)

## Context

Post-C-26 (`v21-branch-as-root`), `Branch` es Aggregate Root con `status ('active'|'closed')`, `opened_at`/`closed_at` y RPCs `rpc_open_branch`/`rpc_close_branch`; `branch_stock` es el único ledger de inventario con invariante `onHand >= 0`. No existe ninguna noción de caja/efectivo: el sistema registra ventas pero no el dinero físico en el cajón.

El modelo de dominio V2 (§3.7, §5.6, DEC-19) define la jerarquía `Cashbox (1+ por Branch) → CashSession (OPEN→CLOSED) → CashMovement[] (append-only)`. Invariantes (RN-95): una sola sesión abierta por caja; todo movimiento de efectivo exige sesión abierta; la diferencia de cierre (declarado vs esperado) se registra como señal antifraude. DEC-20 manda que venta+stock+caja+numeración fiscal vivan en la **misma transacción**; el resto (contabilidad, reporting, audit, IA, email) va por outbox.

**Estado de prod (feature nueva)**: 0 cajas, 0 sesiones, 0 movimientos. Las tablas, invariantes y RLS nacen limpios — sin backfill, sin riesgo sobre datos existentes. 26 cuentas × 1 branch activa (de C-26).

**Stakeholders**: C-29 (`v21-quote-salesorder`) es el consumidor crítico del punto de integración del hot path — su `SalesOrder.confirm()`/`quickSale()` llamará al helper de caja dentro de la transacción de venta. C-30 (cuentas corrientes) reusa el patrón ledger. Governance MEDIO: implementar con checkpoints; OQ-1..OQ-3 se resuelven con el PO antes del apply, pero el riesgo es bajo (sin datos en prod).

## Goals / Non-Goals

**Goals**
1. `Cashbox` por sucursal con RLS por `account_id` resuelto vía `branch_id → branches.account_id` (NO `company_id`/`user_id`, RN-97).
2. `CashSession` con lifecycle `open(opening_balance)` / `close(counted_balance)` + arqueo (`expected = opening + Σ movimientos`, `difference = counted - expected`).
3. `CashMovement` append-only con `balance_after` por fila, tipos enumerados, invariante de sesión abierta.
4. Invariante de doble apertura: una sola sesión `open` por caja (índice UNIQUE parcial + guard RPC).
5. **Punto de integración del hot path listo para C-29**: helper `c28_register_cash_movement(...)` invocable intra-transacción, testeado de forma autónoma en C-28.
6. Backend (3 capas) + UI `/sucursales/:id/caja` mínimos para operar el ciclo y ver el arqueo.

**Non-Goals**
- Implementar `SalesOrder.confirm()`/`quickSale()` (eso es C-29). C-28 deja el helper reutilizable y lo prueba con una RPC de prueba/wrapper, sin crear ventas.
- Cuentas corrientes / `CustomerAccount` (C-30): mismo patrón ledger, change aparte.
- Numeración fiscal / CAE en el cierre Z (el cierre Z formal AFIP es V2.5+; acá el "cierre" es operativo/arqueo, no fiscal).
- Multi-moneda real: `currency` se persiste (`DEFAULT 'ARS'`) pero no hay conversión; una sesión opera en la moneda de su caja.
- Conciliación bancaria / transferencias (V2.5, `BankReconciliation`).
- Reportes agregados de caja (proyecciones por outbox): los eventos `CashSessionOpened/Closed`, `CashMovementRegistered` se emiten al outbox para consumidores futuros, pero los read models de reporting no son parte de este change.

## Decisions

### D1 — RLS por `account_id` derivado de `branch_id`, sin columna `account_id` propia
`cashboxes` lleva `branch_id`; `cash_sessions` lleva `cashbox_id`; `cash_movements` lleva `session_id`. La pertenencia a la cuenta se deriva por joins hasta `branches.account_id`. Las políticas RLS usan `current_account_ids()` / `is_account_writer(account_id)` (las mismas helpers que el resto del sistema post-C-19) con un subselect que resuelve `account_id` por la cadena de FKs.
- Alternativa considerada: desnormalizar `account_id` en las tres tablas (como hacen las tablas legacy). **Rechazada**: viola la dirección V2 (una sola clave, derivada del aggregate root); duplica dato y abre la puerta a `account_id` incoherente con `branch_id`. El costo de los joins en RLS es aceptable con índices en las FKs (`cashboxes.branch_id`, `cash_sessions.cashbox_id`, `cash_movements.session_id`). Si el perfil de queries lo exige a escala, se materializa `account_id` después (migración aditiva).
- `cashboxes` SÍ podría llevar `account_id` redundante para acortar la RLS de la tabla raíz de la cadena; se evalúa en OQ-1.

### D2 — Helper intra-transacción `c28_register_cash_movement` separado de la RPC pública
La inserción de un movimiento, el cálculo de `balance_after` y las invariantes (sesión abierta, sucursal operativa) viven en una **función PL/pgSQL** `c28_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id) RETURNS uuid` que **no abre transacción propia** (corre en la transacción del llamador). La RPC pública `rpc_register_cash_movement` es un wrapper `SECURITY DEFINER` + guard `is_account_writer` que invoca el helper. Así:
- C-28 testea el helper de forma autónoma (movimiento manual: ingreso/egreso por la UI).
- C-29 invoca `c28_register_cash_movement` desde `rpc_*_sale_*` dentro del MISMO commit que el descuento de stock → atomicidad real (DEC-20). Si la venta falla, el ROLLBACK arrastra el movimiento.
- Alternativa rechazada: que la venta llame a la RPC pública `rpc_register_cash_movement`. Una RPC `SECURITY DEFINER` invocada desde otra RPC comparte transacción en Postgres, pero re-evalúa el guard de rol y no expresa el contrato "esto es un building block, no una operación de usuario". El helper deja el contrato explícito y evita doble chequeo de permisos.

### D3 — `balance_after` calculado con lock de la sesión (serialización del ledger)
El helper hace `SELECT ... FROM cash_sessions WHERE id = p_session_id AND status='open' FOR UPDATE` (lock de fila de la sesión) antes de calcular `balance_after = COALESCE(last balance_after, opening_balance) + p_amount` e insertar. El `FOR UPDATE` serializa los movimientos concurrentes de la misma sesión (una caja física tiene un cajero a la vez, pero el POS puede tener concurrencia) → `balance_after` siempre consistente, sin huecos. Patrón idéntico al lock corto de `DocumentSequence` (C-27) y al ledger de `stock_movements`.

### D4 — Doble apertura: índice UNIQUE parcial + guard, defensa en profundidad
`CREATE UNIQUE INDEX cash_sessions_one_open_per_cashbox ON cash_sessions (cashbox_id) WHERE status = 'open';` es la red de seguridad física (a nivel DB, imbatible por race condition). El guard en `rpc_open_cash_session` (`IF EXISTS (... status='open') THEN RAISE P0409 cashbox_session_open`) da el error de dominio limpio antes de que reviente el índice. Ambos: el guard para UX, el índice para correctness bajo concurrencia.
- Alternativa rechazada: solo el guard. Bajo dos aperturas concurrentes el guard tiene ventana de carrera (ambos leen "no hay abierta", ambos insertan). El índice cierra la ventana.
- Alternativa rechazada: solo el índice. Da error críptico de constraint en vez del ERRCODE de dominio.

### D5 — `cash_movements` estrictamente append-only; sin UPDATE/DELETE
RLS de `cash_movements`: `SELECT` para miembros de la cuenta; sin políticas de `UPDATE`/`DELETE`. La escritura ocurre únicamente vía el helper `SECURITY DEFINER`. Corregir un movimiento se hace con un movimiento compensatorio (signo opuesto), nunca editando — patrón contable (RN-98). Esto preserva la auditabilidad del arqueo (el faltante/sobrante no se puede "limpiar" borrando filas).

### D6 — RPCs SQL como única superficie de escritura (patrón vigente del proyecto)
`rpc_open_cash_session` / `rpc_close_cash_session` / `rpc_register_cash_movement` son `SECURITY DEFINER` con guard `is_account_writer` (owner/admin/escritura), ERRCODEs de 5 chars (`P0401`/`P0409`/`P0422` — convención post-20260624000001). El backend Python las invoca vía repositories con JWT-passthrough; cero lógica de negocio en routers (regla dura del proyecto). El cierre Z diario y los reportes salen de consultar el ledger, no de RPCs adicionales.

### D7 — `expected_balance` y `difference` se materializan al cerrar, no se derivan en cada lectura
El cierre persiste `expected_balance`, `counted_balance`, `difference`, `closing_balance` en `cash_sessions`. Una vez cerrada, la sesión es inmutable y su arqueo queda congelado (no se recalcula si alguien tocara movimientos — que además son append-only). Mientras está `open`, la UI muestra el saldo corriente derivado (`opening + Σ amount`) en vivo; al cerrar, ese valor se congela como `expected_balance`.

### D8 — Eventos al outbox (asíncrono), no en el hot path
`CashSessionOpened`, `CashMovementRegistered`, `CashSessionClosed` (con diferencia) se insertan en la tabla `events` (outbox, activada en C-25/v20-outbox) para consumidores de reporting/audit/IA. Esto NO está en el camino crítico de C-28 si el outbox aún no está activo: el INSERT en `events` es best-effort/condicional. Los read models de caja son trabajo futuro; acá solo se garantiza que el ledger (fuente de verdad) sea correcto.

## Risks / Trade-offs

- **[RLS con joins de 3 niveles puede degradar a escala]** → Mitigación: índices en todas las FKs (`cashboxes.branch_id`, `cash_sessions.cashbox_id`, `cash_movements.session_id`); el subselect de RLS resuelve `account_id` por PK lookups. Si el perfil real lo exige, materializar `account_id` en `cashboxes` (aditivo, OQ-1).
- **[El helper intra-transacción se prueba sin su consumidor real (C-29 no existe)]** → Mitigación: en C-28 se prueba con una RPC de prueba que abre una transacción, llama al helper y verifica atomicidad (commit → fila presente; rollback forzado → fila ausente). El contrato (firma + invariantes) queda fijado por los escenarios del spec `cash-movement`, de modo que C-29 enchufa sin sorpresas.
- **[Concurrencia de movimientos en la misma sesión]** → Mitigación: `SELECT ... FOR UPDATE` sobre la sesión serializa el cálculo de `balance_after` (D3). El lock es de fila y corto.
- **[Una venta en efectivo sin sesión abierta no podría registrar caja (C-29)]** → Decisión de contrato: el helper lanza `P0409 no_open_session`. C-29 deberá decidir su UX (forzar abrir caja, o permitir venta sin caja con `cash_movement` diferido). Se documenta como OQ-3 para que el PO lo resuelva antes de C-29; **no bloquea C-28**.
- **[`amount` con signo provisto por el llamador puede llegar incoherente con el tipo]** → Mitigación: el CHECK valida el enum; la coherencia signo↔tipo se valida en la capa de servicio (backend) y en el helper opcionalmente. Decisión: no imponer signo por CHECK en DB (un `withdrawal` podría representarse +/− según convención del consumidor); la convención (egresos negativos) se documenta y se valida en el service. Ver OQ-2.

## Migration Plan

1. **Migración A (única, no destructiva, aditiva)** — `npx supabase db push` (CLI; NUNCA el MCP `apply_migration`; proyecto prod `gxdhpxvdjjkmxhdkkwyb`):
   - `CREATE TABLE cashboxes (id, branch_id FK, name, currency DEFAULT 'ARS', created_at)` + RLS (SELECT miembros, escritura vía RPC) + índice `(branch_id)`.
   - `CREATE TABLE cash_sessions (id, cashbox_id FK, status CHECK in ('open','closed') DEFAULT 'open', opening_balance, closing_balance, counted_balance, expected_balance, difference, opened_by, closed_by, opened_at, closed_at)` + RLS + `UNIQUE INDEX ... (cashbox_id) WHERE status='open'`.
   - `CREATE TABLE cash_movements (id, session_id FK, amount, movement_type CHECK in (...), reference_id UUID NULL, balance_after, created_by, created_at)` + RLS (SELECT miembros; sin UPDATE/DELETE) + índice `(session_id, created_at)`.
   - `CREATE FUNCTION c28_register_cash_movement(...)` (helper intra-transacción, con `FOR UPDATE` y validación de sesión/branch).
   - `CREATE FUNCTION rpc_open_cash_session`, `rpc_close_cash_session`, `rpc_register_cash_movement` (SECURITY DEFINER + `is_account_writer` + ERRCODEs).
2. Backend (TDD: pytest baseline → RED → GREEN) + frontend → PR → merge → Render/Vercel deploy.
3. Smoke transaccional en prod (DO block + `set_config('request.jwt.claims', …)` + RAISE final para rollback): crear caja → abrir sesión → doble apertura falla `P0409` → registrar movimientos → cerrar con arqueo → diferencia correcta → cierre de sesión cerrada falla → registrar movimiento sin sesión abierta falla → atomicidad del helper (rollback no deja fila).
4. **Rollback**: `DROP FUNCTION rpc_*_cash_session, rpc_register_cash_movement, c28_register_cash_movement; DROP TABLE cash_movements, cash_sessions, cashboxes` (orden inverso de FKs). Sin pérdida de datos (feature nueva, 0 filas en prod).

## Resolved Decisions

> Resueltas por el PO (2026-06-17) antes del apply de C-28.

### OQ-1 → RLS DERIVADA (sin `account_id` en las nuevas tablas)
No se agrega `account_id` en `cashboxes`, `cash_sessions` ni `cash_movements`. La pertenencia a la cuenta se deriva 100% por la cadena de FKs:
`cash_movements.session_id → cash_sessions.cashbox_id → cashboxes.branch_id → branches.account_id`.
Las políticas RLS usan `current_account_ids()` / `is_account_writer()` con subselects JOIN.

### OQ-2 → SIGNED AMOUNT (signo en `amount`)
`amount` lleva signo: ingresos positivos (+), egresos negativos (−). El arqueo suma directamente `Σ amount`. La coherencia signo↔tipo (p. ej. `sale` > 0, `expense` < 0) se valida en la capa de servicio Python (no via CHECK en DB).

### OQ-3 → DEFERRED A C-29 (contrato fijado)
C-29 decide la UX de "venta sin caja abierta". El helper `c28_register_cash_movement` retorna `P0409 no_open_session` cuando no hay sesión `open` — ese es el contrato que C-29 consumirá. No bloquea C-28.

### Contrato del helper `c28_register_cash_movement` (para consumo de C-29)
```sql
c28_register_cash_movement(
  p_session_id   uuid,
  p_amount       numeric,   -- con signo: + ingreso, − egreso
  p_type         text,      -- 'sale'|'purchase_payment'|'expense'|'advance'|'withdrawal'
  p_reference_id uuid       -- nullable; sale_id u otra FK externa
) RETURNS uuid              -- id del cash_movement insertado
```
- Invariantes verificadas: `status='open'` (→ `P0409 no_open_session`), `branch.status='active'` (→ `P0422 branch_closed`).
- `balance_after = COALESCE(max(balance_after) FROM cash_movements WHERE session_id, opening_balance) + p_amount`.
- Lock de fila con `SELECT … FOR UPDATE` sobre `cash_sessions` (D3) — serializa movimientos concurrentes.
- **NO abre transacción propia** — corre en la transacción del llamador.

## Open Questions (resolver con el PO antes del apply)

- **OQ-1 — `account_id` redundante en `cashboxes`**: ¿dejamos la RLS 100% derivada por joins (recomendado, más limpio y coherente con V2) o desnormalizamos `account_id` en `cashboxes` para acortar la RLS de la tabla raíz? **Recomendación: derivada** — feature nueva, sin presión de escala; materializar después es aditivo.
- **OQ-2 — Convención de signo en `amount`**: ¿el `amount` lleva signo (ingresos +, egresos −) y el arqueo suma directo (recomendado, simple), o `amount` es siempre positivo y el `movement_type` determina el signo en el cálculo? **Recomendación: con signo** — la suma del arqueo es trivial y el ledger es legible. El service valida coherencia signo↔tipo.
- **OQ-3 — Venta en efectivo sin sesión de caja abierta (impacto en C-29, no bloquea C-28)**: cuando C-29 confirme una venta en efectivo y no haya sesión `open`, ¿la venta falla pidiendo abrir caja, o se permite y el `cash_movement` se difiere/omite? **Recomendación a confirmar en C-29**: para POS, exigir caja abierta (`P0409 no_open_session`) es lo coherente con RN-95; se documenta acá para fijar el contrato del helper.
