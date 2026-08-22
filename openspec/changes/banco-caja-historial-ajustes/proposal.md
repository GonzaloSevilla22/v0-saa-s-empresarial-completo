## Why

Hoy **Caja no es un módulo**: su única pantalla vive enterrada en `/sucursales/[id]/caja` — hay que entrar a Sucursales, elegir una de las 40 sucursales y recién ahí aparece la caja. No tiene entrada de sidebar propia. Banco sí tiene entrada ("Bancos") pero apunta a `/finanzas/conciliacion`, una pantalla que sólo sabe conciliar contra un extracto.

En ninguno de los dos libros el usuario puede hacer las dos cosas que pidió el PO textualmente (2026-08-22):

1. **Ver el historial de movimientos** como lo ve en Stock. En Caja la lista actual muestra sólo los movimientos de la **sesión abierta** — al cerrar la sesión el historial desaparece de la vista (65 movimientos en prod, ninguno consultable fuera de su sesión). En Banco los `bank_movements` **no tienen ninguna pantalla**: se escriben automáticamente desde los pagos (C2/`pos-banco-movimientos`) y sólo se ven de refilón dentro del tablero de conciliación, mezclados con las líneas del extracto.
2. **Registrar un ajuste manual** para consolidar el libro contra la realidad. En Caja **no existe**: `cash_movements.movement_type` es un vocabulario cerrado de 6 valores sin ninguno de ajuste, y la tabla **no tiene columna de motivo**. En Banco existe media pieza — `rpc_register_bank_movement` ya acepta `manual_adjustment` con `p_description`— pero el motivo es **opcional** y no hay superficie que la invoque (los 3 movimientos bancarios de prod son `transfer_in` y los 3 tienen `description` NULL).

El costo de no tenerlo ya se pagó: `delete-guard-ledgers` (2026-08-22) encontró **2 movimientos de caja huérfanos por $8.000 en una sesión abierta desde el 17-07** que nadie podía corregir porque el ledger es append-only y no había ajuste. La única salida era borrar la operación — el camino que produjo el cargo fantasma de $75.150.

## What Changes

### 1. Caja pasa a ser un módulo propio

- Nueva ruta `/caja` con entrada de sidebar propia (grupo **Operaciones**, título "Caja", ícono `Banknote`), a la par de Ventas / Compras / Gastos / Banco.
- La pantalla resuelve la sucursal y la caja **adentro** (selector), en vez de exigir navegar por Sucursales. Preselecciona la sucursal si hay una sola, y la caja si la sucursal tiene una sola (hoy el modelo es 1 caja por sucursal).
- `/sucursales/[id]/caja` se conserva como **acceso contextual** desde el detalle de sucursal y redirige a `/caja?branch=<id>` — cero links rotos, una sola pantalla que mantener.

### 2. Banco pasa a ser un módulo propio con la conciliación adentro

- Nueva ruta `/banco` como raíz del módulo, con tabs **Movimientos** y **Conciliación**. La tab de Conciliación monta los componentes existentes (`ReconciliationBoard`, importador de extracto, `BankAccountFormDialog`) **sin reescribirlos**.
- La entrada de sidebar "Bancos" → `/finanzas/conciliacion` pasa a "Banco" → `/banco`; `/finanzas/conciliacion` queda como redirect a `/banco?tab=conciliacion`.

### 3. Historial de movimientos en ambos módulos, al molde de Stock

- Un componente **compartido** `LedgerMovementsPanel` (capa canónica `components/ledger/`), calcado del molde de `components/stock/stock-movements-panel.tsx`: cabecera colapsable con resumen, píldoras de filtro por familia de tipo, buscador, badges de tipo con label+ícono+color, columna `saldo después`, "Ver más" incremental y export CSV. Un solo componente, dos configuraciones de libro (`cash` / `bank`) — **reutilización antes que repetición**.
- **Caja**: el historial cubre **todas las sesiones de la caja**, no sólo la abierta, con la sesión y su estado visibles en cada fila. Tipos: `sale`, `purchase_payment`, `expense`, `advance`, `withdrawal`, `sale_reversal` (de `delete-guard-ledgers`) y el nuevo `adjustment`.
- **Banco**: el historial cubre todos los `bank_movements` de la cuenta elegida. Tipos: `transfer_in`, `transfer_out`, `card_settlement`, `fee`, `tax_debit`, `interest`, `manual_adjustment`, más el **estado de conciliación** (`unreconciled` / `matched`) como badge y como filtro.
- Ambos listados por endpoint FastAPI con la **paginación estándar** `?page&size` → `{items, total, page, pages}` (`api-standards`), 3 capas y JWT-passthrough.

### 4. Movimiento de ajuste manual en ambos libros

- **Caja**: nuevo `movement_type = 'adjustment'` (amount signado: + sobrante, − faltante) y **nueva columna `cash_movements.description`** para el motivo. CHECK a nivel DB: un movimiento de tipo `adjustment` SHALL tener motivo no vacío. Append-only como todo el ledger — un ajuste equivocado se corrige con otro ajuste, nunca con UPDATE/DELETE.
- **Banco**: `rpc_register_bank_movement` pasa a **exigir motivo no vacío** cuando `p_type = 'manual_adjustment'` (hoy lo acepta NULL), con ERRCODE propio. Los ajustes bancarios entran al tablero de conciliación como cualquier otro movimiento del sistema (`unreconciled` al nacer, matcheables) — la pieza C3 no se toca.
- **BREAKING (contrato de RPC)**: `rpc_register_bank_movement` con `p_type='manual_adjustment'` y `p_description` vacío pasa de aceptar a rechazar. Ningún llamador en producción lo usa hoy (0 filas `manual_adjustment`).

### 5. El ajuste de caja NO tapa la señal antifraude del arqueo (RN-95)

Sin esto, el ajuste sería un agujero: `expected_balance = opening + Σ(cash_movements)`, así que un ajuste de +100 antes del cierre lleva la `difference` del arqueo a 0 y borra la señal. La solución:

- Nueva columna **`cash_sessions.adjustments_total`**, materializada en `rpc_close_cash_session` como Σ de los movimientos `adjustment` de la sesión (snapshot al cierre, patrón V3).
- `difference` conserva su definición actual (`counted − expected`), y el cierre expone además **`difference_before_adjustments = difference + adjustments_total`** — la diferencia que habría habido sin los ajustes.
- El historial de sesiones y la tarjeta de cierre muestran **ambas**: "Dif. $0 · 1 ajuste manual de +$100". La señal sobrevive al ajuste en vez de ser reemplazada por él.

### 6. Contabilidad: los ajustes NO postean asiento (decisión, no omisión)

El spec vigente `bank-movement` tiene una requirement explícita — *"C1 no postea al journal contable"* — y el consumidor `_journal_post_from_event` se alimenta de **eventos de negocio** (9 tipos: ventas, compras, cobros, pagos, borrados), nunca de filas de ledger. Su plan de cuentas real (`1100 Caja`, `1110 Banco`, `1300`, `2100`, `4100`, `4200`, `5100`, `5200`, `5300`) **no tiene cuenta de resultado para diferencias de caja/banco**, y el arqueo con `difference ≠ 0` tampoco postea nada hoy.

Postear el ajuste exigiría un `event_type` nuevo + cuentas nuevas + contradecir un requirement vigente. **Este change no lo hace**: el ajuste es una corrección de libro, y el drift libro↔contabilidad que ya existe (arqueo, movimientos bancarios manuales) no se agranda de forma nueva. Queda como **OQ-2** con la propuesta concreta lista (par `4300 Otros ingresos` / `5400 Diferencias de caja y banco`) para que el PO decida en un change aparte.

## Capabilities

### New Capabilities
- `cash-book-module`: Caja como módulo de primer nivel — ruta `/caja`, entrada de sidebar propia, selección de sucursal/caja adentro de la pantalla, y la ruta vieja de sucursal preservada como acceso contextual.
- `ledger-movement-history`: historial de movimientos de libro consultable en Caja y Banco, al molde del de Stock — un componente compartido, taxonomía de tipos con label/ícono/familia, filtros server-side, paginación estándar y export CSV. En Caja cubre **todas** las sesiones; en Banco expone el estado de conciliación.
- `ledger-adjustment`: movimiento de ajuste manual con **motivo obligatorio** y append-only en ambos libros, para consolidar el saldo del sistema contra la realidad, sin destruir la señal antifraude del arqueo ni postear al journal.

### Modified Capabilities
- `cash-movement`: el vocabulario cerrado de tipos suma `adjustment`; la tabla suma la columna `description` (motivo) con CHECK de obligatoriedad para `adjustment`.
- `cash-session`: el cierre materializa `adjustments_total` y expone `difference_before_adjustments`; la requirement "UI de caja por sucursal" se reemplaza por la del módulo propio `/caja`.
- `bank-movement`: la carga manual de `manual_adjustment` exige motivo no vacío; se agrega la requirement del historial legible de la cuenta.
- `bank-reconciliation`: se declara explícitamente que el ajuste manual nace `unreconciled` y es matcheable como cualquier movimiento del sistema (sin cambios de código en C3).

## Impact

**DB** (una migración idempotente, `supabase/migrations/20261006000001_banco_caja_historial_ajustes.sql` — MAX(version) en prod verificado = `20261005000001`):
- `cash_movements`: `+ description text`, CHECK de tipo ampliado con `adjustment`, CHECK de motivo obligatorio (`NOT VALID` sobre las 65 filas históricas, que no tienen ajustes), índice `(session_id, created_at DESC)`.
- `cash_sessions`: `+ adjustments_total numeric`.
- RPCs redefinidas (firma nueva ⇒ **REVOKE explícito de PUBLIC + anon + authenticated y GRANT selectivo en el mismo archivo**): `rpc_register_cash_movement`, `c28_register_cash_movement`, `rpc_close_cash_session`, `rpc_register_bank_movement`. Toda reescritura parte del `pg_get_functiondef` **vivo**.
- `.github/workflows/KPI_Validation.yml`: nuevo eslabón de la cadena de reapply después de `20261005000001`.

**Backend** (3 capas): `routers/cash.py` + `services/cash.py` + `repositories/cash_session_repository.py` (listado paginado por cashbox, ajuste de caja); `routers/bank_reconciliation.py` o router `bank_movements` nuevo + `repositories/bank_account_repository.py` (listado paginado de movimientos por cuenta). Errores RFC 7807 con `code`.

**Frontend**: nuevas rutas `app/(dashboard)/caja/page.tsx` y `app/(dashboard)/banco/page.tsx`; redirects desde `sucursales/[id]/caja` y `finanzas/conciliacion`; `components/app-sidebar.tsx` (entrada "Caja" nueva, "Bancos"→"Banco"); nuevo `components/ledger/LedgerMovementsPanel.tsx` + `LedgerAdjustmentDialog.tsx`; hooks `use-cash-movements.ts` (paginado, por cashbox) y `use-bank-movements.ts` (nuevo).

**Fuera de alcance**: el rediseño de "caja siempre abierta" (OQ-1), el asiento contable del ajuste (OQ-2), y cualquier cambio a la mecánica de matching de C3.

**No se tocan**: los gates transitivos y fiscales, `_journal_post_from_event`, el vocabulario de `bank_movements.movement_type` (ya tiene `manual_adjustment`), ni la lógica de conciliación.
