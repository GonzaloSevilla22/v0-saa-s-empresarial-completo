## Why

> **Governance: MEDIA, con un tramo de severidad ALTA.** El change escribe dinero real en **cuatro** libros (cuenta corriente, caja, banco y libro diario) desde RPCs `SECURITY DEFINER` nuevas. Mismo nivel que `caja-compras-cobranzas`, `gastos-forma-pago` y `compras-proveedor-cuenta-corriente`: implementación con checkpoints 🛑 explícitos en cada tramo que toca un libro, no autonomía plena. No es CRÍTICO: no cierra un hueco de auth ni de tenancy, y no toca billing.

**Origen:** OQ-4 de `caja-compras-cobranzas`, firmada por el PO el 2026-09-01 (*"FUERA de este change, por recomendación. Candidato `cobranzas-reverso` dado de alta"*), y su Non-Goal 1: *"Cuando se cree, la compensación de caja nace con él."*

**Hoy no existe ningún camino para deshacer un cobro de cuenta corriente ni un pago a proveedor.** Verificado contra producción el 2026-09-02:

| Camino de reverso | ¿Existe? |
|---|---|
| RPC `rpc_delete_payment_received` / `_made` | **NO** — ninguna función de reverso en `pg_proc` |
| Endpoint `DELETE` en `routers/customer_accounts.py` / `supplier_accounts.py` | **NO** — los dos routers sólo tienen `POST` de alta y `GET` de lectura |
| Acción de fila en `/clientes/[id]/cuenta` y `/proveedores/[id]/cuenta` | **NO** — `CustomerAccountHistory` / `SupplierAccountHistory` son listados de sólo lectura |

Un cobro mal cargado —importe equivocado, cliente equivocado, cargado dos veces— **no se puede corregir por ninguna vía de la aplicación**. Y desde que `caja-compras-cobranzas` se mergeó (PR #485, migración `20261018000001` viva en prod), el daño de un cobro equivocado dejó de ser un solo libro:

| Libro | ¿Lo escribe hoy el cobro/pago? | Medición en prod (2026-09-02) |
|---|---|---|
| Cuenta corriente (`customer/supplier_account_movements`) | **SÍ**, siempre | 7 movimientos de pago |
| Caja (`cash_movements`) | **SÍ**, con opt-in y forma de pago `cash` | 0 filas *todavía* — la funcionalidad tiene 1 día |
| Banco (`bank_movements`) | **SÍ**, con forma de pago bancaria | **6 filas** |
| **Libro diario (`journal_entries`)** | **SÍ, siempre, desde `journal-entry-outbox`** | **6/6 cobros y 1/1 pago tienen asiento `posted`** |

**El cuarto libro es el hallazgo que el chip original no contemplaba y que cambia el diseño.** `_journal_post_from_event` (32.940 chars, md5 `ef2d9459f125c200a28b757d266eb738`) tiene ramas `PaymentReceived` y `PaymentMade` **vivas desde hace meses**, y el 100% de los pagos históricos tiene su asiento de partida doble vigente. Un reverso que compense cuenta corriente, caja y banco pero deje el asiento en pie **rompe la partida doble del tenant en silencio**: el libro diario seguiría afirmando que ese cobro entró.

**Lo que ya está construido y no hace falta inventar** — este change es, otra vez, un cableado, no una invención:

- **`rpc_delete_expense`** (md5 `4d78ee3b241bea2f4df34ceb0afb7cce`) es el molde completo de compensación multi-libro: disparo **por existencia** del movimiento (`<> 0`, jamás por signo), contra-movimiento contra la **sesión abierta actual** de la misma caja, `P0426` cuando no la hay, espejo bancario con el escritor crudo `_register_bank_movement`, y el `DELETE` del documento **después** de las compensaciones.
- **La rama `PurchaseDeleted` de `_journal_post_from_event`** es el molde exacto del contra-asiento: localizar el asiento vigente por `(source_doc_type, source_doc_ref, status='posted')`, `P0451` si no está (el evento queda *pending* para retry), insertar la contra-entry con `reversal_of`, invertir el lado de cada línea, marcar el original `reversed`. El ASSERT de balance genérico la cubre sin código adicional.
- **`getDeleteCompensation`** (`frontend/lib/delete-compensation.ts`) ya enumera compensaciones y ya bloquea por falta de sesión abierta; sólo hay que sumarle el documento `"cobro"`/`"pago"`.
- **Los `ERRCODE` de la casa ya existen y ya están mapeados** en `backend/core/errors.py`: `P0401`, `P0404`, `P0409`, `P0423`, `P0425`, `P0426`, `P0451`.

## What Changes

### 1. Dos RPCs de reverso, con el molde de `rpc_delete_expense`

`rpc_reverse_payment_received(p_payment_id uuid, p_reason text DEFAULT NULL)` y `rpc_reverse_payment_made(...)`, `SECURITY DEFINER`, que en **una sola transacción**:

1. Validan `is_account_writer` (`P0401`) y que el pago exista **y pertenezca al tenant** (`P0404`) — guard de tenencia con el precedente de `cuenta-corriente-party-guard`.
2. **Cuenta corriente**: contra-movimiento por el importe **opuesto** vía `c30_register_customer/supplier_account_movement`, con **tipo propio nuevo** (`payment_received_reversal` / `payment_made_reversal`), nunca reutilizando `credit_note`/`debit_note` — ver §3.
3. **Caja**: si existe movimiento de caja del pago (disparo por **existencia**, `<> 0`), contra-movimiento en la **sesión abierta actual de la misma caja**; sin sesión abierta → `P0426` y el reverso entero se rechaza. La sesión original jamás se toca.
4. **Banco**: espejo con dirección invertida vía `_register_bank_movement`, siempre `unreconciled`, en loop sobre `(source_doc_type='payment_received'|'payment_made', source_doc_ref=p_payment_id)`.
5. **Evento** `PaymentReceivedReversed` / `PaymentMadeReversed` al outbox → contra-asiento contable async.
6. **`DELETE` de la fila** de `payments_received`/`payments_made`, **después** de las cuatro compensaciones.

### 2. El contra-asiento contable nace con el reverso (no se difiere)

`_journal_post_from_event` suma dos ramas calcadas de `PurchaseDeleted`, con **convención única** cada una (más simple que la venta, que tiene dos): `PaymentReceivedReversed` localiza por `('CustomerAccount', payment_id)` y `PaymentMadeReversed` por `('SupplierAccount', payment_id)`.

Los **dos filtros de `event_type`** —el de `_journal_post_from_event` y el de `rpc_process_outbox_dispatch`— pasan de 9 a 11 tipos. El invariante *"los dos listados deben listar el mismo conjunto"* está documentado desde `asiento-venta-formulario` y **se verifica con un gate**, no con la memoria del que edita.

### 3. Dos tipos nuevos por ledger de cuenta corriente, y dos por caja

- `customer_account_movements.movement_type`: 4 → **5** (`+ payment_received_reversal`).
- `supplier_account_movements.movement_type`: 4 → **5** (`+ payment_made_reversal`).
- `cash_movements.movement_type`: 11 → **13** (`+ payment_received_reversal`, `+ payment_made_reversal`).

**No se reutiliza `credit_note`/`debit_note`**: esos tipos ya están tomados por `_pay_reverse_party_charge` para revertir un **cargo**, y se postean **negativos** (reducen la deuda). Revertir un **cobro** hace lo contrario: **aumenta** la deuda, con importe **positivo**. Meter un `credit_note` positivo en el ledger invertiría el significado del tipo y corrompería cualquier lector que asuma su signo. Tampoco se reutiliza `adjustment`: la spec `cash-movement` ya lo fija como normativo — *cada contra-movimiento automático tiene su tipo propio*, y `adjustment` está reservado a la corrección manual con motivo obligatorio.

### 4. El KPI de "Cobrado" deja de mentir — gratis

`rpc_dashboard_kpi_summary` calcula `collected_revenue` sumando `payments_received.amount` del período, **sin ningún filtro de estado**. Borrar la fila del documento (§1.6) lo corrige por construcción: **no hay que tocar la RPC de KPIs**, que está bajo el gate `KPI_Validation` y fue objeto de un programa de remediación entero. Cualquier diseño que conservara la fila con una marca de anulación obligaría a modificarla — ver D2.

### 5. Superficie frontend (regla PO 2026-08-02) — dos pantallas que ya existen

Ninguna ruta ni entrada de menú nueva.

- **`/clientes/[id]/cuenta` y `/proveedores/[id]/cuenta`**: acción **"Anular"** por fila, visible **sólo** en los movimientos de tipo `payment_received`/`payment_made` que todavía tienen su documento vivo. Diálogo de confirmación que **enumera qué se va a compensar** (los cuatro libros, sólo los que apliquen) vía `getDeleteCompensation`, con los documentos nuevos `"cobro"`/`"pago"`.
- **Bloqueo visible antes de intentar**: cuando el pago tiene movimiento de caja y **no** hay sesión abierta en esa caja, la acción aparece deshabilitada con el motivo — el mismo derivado de servidor `is_reversal_blocked` que ya tienen gasto y compra, nunca una regla inventada en el cliente.
- **Errores legibles**: `P0426`, `P0404` y `P0451` se suman a `humanizeOperationError` (`frontend/lib/operation-errors.ts`).
- **`/caja` — historial**: los dos tipos nuevos con etiqueta, ícono, tono semántico y **familia "Reversas"** propios en `CASH_MOVEMENT_META`.
- Verificación en **desktop y móvil**, en **tema claro y oscuro**, con tokens semánticos del design system.

### 6. **BREAKING (dominio)**

- Anular un cobro/pago que posteó movimiento de caja **exige una sesión de caja abierta** (`P0426`). Mismo comportamiento que ya tienen la venta en efectivo, el gasto y la compra.
- La fila de `payments_received`/`payments_made` **desaparece** al anularse. El rastro queda en los ledgers append-only (los dos movimientos, original y reversa), en el outbox y en el contra-asiento — ver D2.

### Fuera de alcance, declarado

- **Reverso parcial** (anular $500 de un cobro de $2.000). Un cobro es un hecho atómico; el parcial se resuelve anulando y volviendo a cargar. Un reverso parcial exigiría estado en el documento y un modelo de saldo aplicado que hoy no existe.
- **Anular un cargo** (`sale`/`purchase` en cuenta corriente) por fuera del borrado de su operación. Ya está cubierto: `_pay_reverse_party_charge`, disparado por `rpc_delete_sale_operation`/`rpc_delete_purchase_operation`.
- **Reverso de un movimiento `adjustment`** de cuenta corriente. El ajuste manual se corrige con otro ajuste manual, por definición.
- **RBAC diferenciado** para anular vs. cobrar. `is_account_writer` para los dos, igual que hoy; la granularidad de roles es materia de `v3-rbac-multirole` (CRÍTICO, bloqueado a sign-off del PO).
- **Backfill de los 7 pagos históricos.** No hay nada que backfillear: el change no cambia cómo se registran los pagos, sólo agrega el camino de reverso.
- **Anular desde el listado de ventas/compras.** El reverso vive donde vive el cobro: la pantalla de cuenta corriente.

## Capabilities

### New Capabilities
- `payment-reversal`: contrato propio del reverso de un cobro de cliente y de un pago a proveedor — las dos RPCs, la compensación de los cuatro libros en una transacción, el disparo por existencia, el guard de tenencia, el bloqueo por caja cerrada y la superficie que lo expone. Espejo de `expense-operation`/`purchase-operation`, para los requirements que hoy no tienen capability donde vivir.

### Modified Capabilities
- `customer-account`: el ledger suma el tipo `payment_received_reversal`; se declara que un cobro es reversible y qué deja el reverso; se declara por qué el reverso **nunca** puede violar el invariante de saldo no negativo (a diferencia de la reversión de un cargo, que sí y por eso tiene `P0425`).
- `supplier-account`: espejo exacto del anterior para el pago a proveedor.
- `cash-movement`: el enum pasa de 11 a 13 tipos con su clasificación por signo y por familia; se agrega el contra-movimiento de caja por reverso de un cobro/pago, con su bloqueo `P0426` y su disparo por existencia.
- `journal-entry`: dos ramas de contra-asiento nuevas (`PaymentReceivedReversed`, `PaymentMadeReversed`) y el invariante de los dos filtros de `event_type` pasa de 9 a 11 tipos.
- `operation-delete-compensation`: el contrato transversal de compensación incorpora el reverso de un cobro/pago — el primer documento que compensa **cuatro** libros incluyendo el contable, y el primero donde el asiento se revierte en el mismo change que lo compensa.
- `transactional-outbox`: dos `event_type` nuevos en el conjunto en-scope del Consumer 3, con el invariante de los dos filtros verificado por gate.

## Impact

**DB — migración `20261019000001_cobranzas_reverso.sql`** (numeración verificada el 2026-09-02 contra `origin/main` —última `20261018000001`— y contra `supabase_migrations.schema_migrations` en prod: última `20261018000001`, **267 filas**; re-verificar al momento del apply, no asumir):
- 3 `CHECK` ampliados, idempotentes, sin reescribir ni invalidar filas existentes (`cash_movements` 11→13, `customer_account_movements` 4→5, `supplier_account_movements` 4→5).
- **2 RPCs nuevas**: `rpc_reverse_payment_received`, `rpc_reverse_payment_made`, con `REVOKE` explícito de `PUBLIC`, `anon` **y** `authenticated`, y `GRANT` selectivo en la misma migración.
- **2 funciones reescritas partiendo del `pg_get_functiondef` VIVO hasheado** (regla de la casa desde `metodos-pago-operaciones`): `_journal_post_from_event` (md5 `ef2d9459f125c200a28b757d266eb738`, 32.940 chars) y `rpc_process_outbox_dispatch` (md5 `28ef69cefc0fd0a5d112b656e7795ac6`, 5.933 chars). Ninguna cambia de firma → `CREATE OR REPLACE` sin `DROP` (no aplica el gotcha 42725).
- **Cero helpers nuevos.** `c30_register_customer/supplier_account_movement`, `c28_register_cash_movement` y `_register_bank_movement` se usan tal cual.

**Backend Python** (`backend/`):
- `routers/customer_accounts.py` / `supplier_accounts.py`: endpoint `DELETE /customer-accounts/payments/{payment_id}` y su espejo.
- `services/` + `repositories/` de las dos cuentas: método de reverso (3 capas, sin lógica en el router).
- `schemas/`: `PaymentReversalOut`; `AccountMovementOut` gana `is_reversal_blocked` y `is_reversible` (derivados del servidor, nunca columnas denormalizadas — regla D5 de `delete-guard-ledgers`).
- `schemas/cash.py`: `MovementType` + `_INCOME_TYPES`/`_EXPENSE_TYPES` con los dos tipos nuevos.
- `core/errors.py`: **cero ERRCODEs nuevos**; `P0451` se suma al mapa de status si todavía no está.

**Frontend** (`frontend/`):
- `components/customer-accounts/CustomerAccountHistory.tsx`, `components/supplier-accounts/SupplierAccountHistory.tsx`: acción de fila + diálogo.
- `hooks/data/use-customer-account.ts`, `use-supplier-account.ts`: mutación de reverso + invalidaciones de **cuenta corriente, caja, banco y KPIs del dashboard**.
- `lib/delete-compensation.ts`: `DeletableDocument` suma `"cobro"` y `"pago"`.
- `lib/operation-errors.ts`, `lib/types.ts` (`CashMovementType`), `lib/ledger/cash-movement-meta.ts`.

**Gates**:
- `supabase/tests/test_cobranzas_reverso.sql` (nuevo), con **control negativo obligatorio**: un test que sólo assertara "no hubo error" quedaría verde por omisión (lección literal de `gastos-forma-pago`).
- `test_function_acl_gate.sql`: las dos RPCs nuevas entran en el barrido.
- `test_cash_movement_types.sql`: los dos tipos nuevos.
- **Gate nuevo del invariante de los dos filtros** de `event_type` (hoy sólo lo sostiene un comentario).

**Sistemas que empiezan a ver datos que antes no veían**: el arqueo de caja, el historial de `/caja`, el libro diario (contra-asientos) y el KPI `collected_revenue` del dashboard.
