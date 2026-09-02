## Why

> **Governance: MEDIA, con un tramo de severidad ALTA.** El change escribe dinero real en el libro de caja desde RPCs `SECURITY DEFINER` que hoy no lo tocan. Mismo nivel que `gastos-forma-pago` y `compras-proveedor-cuenta-corriente`: implementación con checkpoints 🛑 explícitos en los tramos que tocan libros, no autonomía plena. No es CRÍTICO: no cierra un hueco de auth ni de tenancy, y no toca billing.

**Pedido textual del PO (2026-09-01):** *"No se registra la compra con Efectivo en el historial de caja y tampoco cuando cobrás una cuenta corriente; tiene que funcionar; también cuando se elimine una compra en efectivo se compense."*

El PO tiene razón en las tres puntas, y está verificado contra el `pg_get_functiondef` **vivo de producción** (2026-09-01), no contra los archivos de migración:

| RPC viva en prod | ¿Escribe en caja? | Hash del functiondef |
|---|---|---|
| `rpc_create_purchase_operation` | **NO** — sólo banco (`_pay_register_operation_bank_movement`) y, si `kind='credit'`, cargo en cuenta corriente | `058f4d29…` (19.438 chars) |
| `rpc_delete_purchase_operation` | **NO** — compensa cuenta corriente, banco y stock; no tiene rama de caja | `e10a1505…` (4.165 chars) |
| `rpc_register_payment_received` | **NO** — la única rama condicional es la bancaria; con `'cash'` no toca ningún libro de dinero | `3af320eb…` (7.031 chars) |
| `rpc_register_payment_made` | **NO** — espejo exacto del anterior | `f4b6bdfa…` (6.148 chars) |

El helper bancario compartido hace `RETURN NULL` sin error cuando el `kind` no es bancario (`v_is_bank_kind := p_kind IN ('transfer','card','check','wallet')`). O sea: **una compra en efectivo hoy no escribe absolutamente nada en ningún libro de dinero**, y tampoco un cobro o un pago de cuenta corriente en efectivo. La plata entra y sale del cajón y el arqueo no se entera.

**Lo que ya está construido y nunca se cableó**, en las dos puntas — el mismo patrón que en `gastos-forma-pago`:

- **DB**: el `CHECK` de `cash_movements.movement_type` **ya acepta `'purchase_payment'`** desde C-28. Medido en prod: **0 funciones lo escriben y 0 filas existen**. Es un tipo reservado y muerto desde hace un año.
- **Frontend**: `CASH_MOVEMENT_META` ya tiene la entrada `purchase_payment` (etiqueta "Pago a proveedor", ícono, tono `destructive`, familia "Egresos" del filtro). **La pantalla de `/caja` ya sabe mostrarlo**; nadie se lo mandó nunca.
- **`useCashOptin`** ya existe (`frontend/hooks/use-cash-optin.ts`), extraído en `gastos-forma-pago` D16 con las tres condiciones que valida el servidor, y **ya tiene dos consumidores** (venta y gasto). Este change es el tercero: no se escribe un bloque nuevo, se le pasa un documento más.
- **`delete-compensation.ts`** ya declara `hasCashMovement` e `isDeleteBlocked` en su contrato de flags. El listado de compras nunca se los pasa porque el backend no los deriva.

**Dimensión del problema en producción (medido 2026-09-01):** 4 compras imputadas a una forma de pago `kind='cash'` (0 movimientos de caja), 6 cobros y 1 pago de cuenta corriente (0 movimientos de caja), 3 sesiones de caja abiertas ahora mismo. El volumen es chico porque **la funcionalidad nunca funcionó**: el circuito de caja se alimenta hoy sólo desde el mostrador, el formulario de venta y el gasto.

**Hallazgo lateral que el change no puede esquivar (medido en prod):** **0 de 507 compras tienen `branch_id`.** No es que nadie elija sucursal — el formulario monta `BranchSelect` y manda `branchId` en el `meta`, pero `useCreatePurchase` lo descarta al componer el payload, `PurchaseOperationIn` no tiene el campo, y `PurchaseRepository.create_operation` pasa **`NULL` literal** como 5.º argumento de la RPC. Es el mismo bug que `gastos-forma-pago` encontró en gastos (0/175) y arregló. Acá es **load-bearing**: la condición 2 del opt-in de caja es *"existe una sesión abierta en la sucursal efectiva de la operación"*, y sin sucursal persistida la compra y el cajón que recibió la plata podrían quedar en sucursales distintas sin que nada lo note.

## What Changes

### 1. La compra en efectivo descuenta de la caja, por opt-in explícito

- `rpc_create_purchase_operation` suma `p_cash_session_id uuid DEFAULT NULL` **trailing** y, cuando viene informado, aplica las **tres condiciones verificadas en servidor** — copiadas literalmente de `rpc_create_expense`, que a su vez las copió de `rpc_create_sale_operation_v2`: `kind='cash'` (`P0422 cash_optin_requires_cash_kind`), sesión `open` cuya caja pertenece a la sucursal efectiva (`P0422 cash_optin_requires_open_session`), fecha de la compra = `reporting_local_today()` (`P0422 cash_optin_requires_today`).
- El efecto lo produce `c28_register_cash_movement(sesión, -total, 'purchase_payment', operation_id)`. **Revive el tipo reservado y muerto.** El helper aporta gratis: sesión abierta (`P0409`), tenencia de la sesión (`P0401`, agregada por `tenancy-guard-caja-outbox`), sucursal operativa (`P0422`), `balance_after` serializado bajo lock y `created_by`.
- **Ausencia de `p_cash_session_id` = NO-OP.** El alta no se bloquea porque no haya caja abierta: la compra se registra igual, sin tocar el arqueo. Mismo contrato que gasto y venta.
- **Cero lógica de caja nueva.** El change no crea ni un helper de caja: todo existe y está probado en tres caminos (mostrador, formulario de venta, gasto).

### 2. El cobro de cuenta corriente y el pago a proveedor en efectivo alimentan la caja

- `rpc_register_payment_received` y `rpc_register_payment_made` suman `p_cash_session_id uuid DEFAULT NULL` trailing. Con `p_payment_method='cash'` y sesión informada, postean `c28_register_cash_movement(sesión, +importe, 'payment_received', payment_id)` y `(sesión, −importe, 'payment_made', payment_id)` respectivamente, **en la misma transacción** que el movimiento de cuenta corriente y la fila de `payments_received`/`payments_made`.
- **Sólo dos condiciones, no tres**, y es una diferencia de datos, no de criterio (D5): `payments_received`/`payments_made` **no tienen columna `date` ni `branch_id`** (verificado contra `information_schema`) — se registran con `created_at = now()`, así que "la fecha es hoy" es verdadera por construcción y no hay una sucursal declarada que pueda discrepar de la del cajón. La sucursal la **aporta la sesión elegida** (sesión → caja → sucursal).
- **La cláusula ambigua se vuelve explícita.** Las specs `customer-account` L61(f) y `supplier-account` dicen hoy que con `cash` el cobro *"SHALL seguir el camino de caja existente sin tocar el ledger bancario"*. Ese camino **nunca existió**. El delta lo reemplaza por lo que el sistema va a hacer de verdad.
- **La idempotencia cubre el movimiento de caja**: un replay de la misma `Idempotency-Key` devuelve el resultado original y **no postea un segundo movimiento**.

### 3. El borrado de una compra en efectivo compensa la caja

- `rpc_delete_purchase_operation` suma la **cuarta pata** de compensación, con el molde exacto de `rpc_delete_expense`: contra-movimiento `purchase_payment_reversal` **positivo** por el importe opuesto, contra la **sesión abierta actual de la misma caja** (jamás dentro de una sesión cerrada — el ledger es append-only y el arqueo firmado es intocable). Sin sesión abierta → `P0426`, el borrado entero se rechaza.
- El disparo es por **existencia** del movimiento de caja, **nunca por su signo** (lección explícita ya normativa en `cash-movement` para el gasto: condicionar al signo esperado dejaría pasar el borrado sin compensar y sin error).
- Orden final de la RPC: cuenta corriente → **caja** → banco → stock → evento `PurchaseDeleted` → `DELETE`. Todo en una transacción (contrato `operation-delete-compensation`).
- **BREAKING (dominio)**: borrar una compra en efectivo con movimiento de caja posteado **exige una sesión de caja abierta**. Mismo comportamiento que ya tienen la venta en efectivo y el gasto.

### 4. La compra con caja posteada es inmutable

- **BREAKING (dominio)**: el predicado `P0423` que ya bloquea la edición de una compra con cargo en cuenta corriente o movimiento bancario suma la pata de caja. Se corrige borrando y recargando — camino que el punto 3 vuelve seguro. La compra sin dinero posteado sigue plenamente editable.
- El bloqueo se **expone en el listado antes de intentar la acción**: `PurchaseItemOut` suma `has_cash_movement` e `is_delete_blocked` (los dos derivados que `ExpenseItemOut` ya tiene y que `delete-compensation.ts` ya sabe consumir), para que "Editar" y "Eliminar" aparezcan deshabilitados con motivo visible y el diálogo de borrado enumere las cuatro compensaciones.

### 5. La compra empieza a persistir su sucursal (RN-93)

- **Bug preexistente medido: 0 de 507 compras tienen `branch_id`.** Se cablea la cadena entera que hoy lo descarta: `useCreatePurchase` incluye `branch_id` en el payload, `PurchaseOperationIn` gana el campo, el service lo propaga y `PurchaseRepository.create_operation` deja de pasar `NULL` literal. **La RPC ya lo acepta y ya lo valida** (`p_branch_id`, activa y de la cuenta) desde `20261009000001`: no hay SQL nuevo para esto.
- Efecto colateral deseado, igual que en gastos: `rpc_branch_report` empieza a ver las compras.

### 6. El vocabulario de caja se completa con tres tipos y un renombre

El `CHECK` de `cash_movements.movement_type` pasa de 8 a 11 tipos:

| Tipo | Estado | Signo | Familia UI | Etiqueta |
|---|---|---|---|---|
| `purchase_payment` | **ya existe, 0 filas** | egreso | Egresos | **"Compra en efectivo"** (relabel — ver abajo) |
| `purchase_payment_reversal` | **nuevo** | ingreso | Reversas | "Reversa de compra" |
| `payment_received` | **nuevo** | ingreso | Ingresos | "Cobro de cliente" |
| `payment_made` | **nuevo** | egreso | Egresos | "Pago a proveedor" |

El **relabel** de `purchase_payment` es seguro y necesario: hoy dice "Pago a proveedor", que es exactamente lo que va a significar el tipo **nuevo** `payment_made` (cancelar deuda de cuenta corriente). Como el tipo tiene **0 filas en producción**, el renombre no reescribe historia de nadie. Sin él, el arqueo no distinguiría "compré mercadería y pagué del cajón" de "le pagué al proveedor una deuda vieja" — dos hechos económicos distintos que además van a contrapartidas contables distintas cuando llegue el asiento de V2.6.

Las **dos taxonomías siguen siendo distintas** (D9 de `gastos-forma-pago`, ya normativa): el signo vive en `backend/schemas/cash.py` (`_INCOME_TYPES`/`_EXPENSE_TYPES`) y la familia del filtro en `frontend/lib/ledger/cash-movement-meta.ts`. `purchase_payment_reversal` es **ingreso por signo** y **Reversas por familia**, igual que `expense_reversal`.

### 7. Superficie frontend (regla PO 2026-08-02) — tres pantallas que ya existen

Ninguna ruta ni entrada de menú nueva.

- **`/compras` — formulario** (`purchase-form.tsx`): bloque de **opt-in de caja** con `useCashOptin({ document: "compra" })` (tercer consumidor del hook; se agrega un valor al union de documentos, no un bloque nuevo), **pre-marcado** (D4), con el motivo visible cuando alguna condición no se cumple — **nunca se oculta en silencio**. `BranchSelect` deja de ser decorativo en el alta.
- **`/compras` — listado**: "Editar"/"Eliminar" deshabilitados con motivo cuando hay caja posteada o cuando falta sesión abierta; diálogo de borrado enumerando cuenta corriente + caja + banco + stock.
- **`/clientes/[id]/cuenta` y `/proveedores/[id]/cuenta` — modales de cobro y pago** (`RegisterPaymentForm.tsx`, `RegisterPaymentMadeForm.tsx`): con "Efectivo" elegido aparece el mismo bloque de opt-in, pre-marcado, con el motivo visible cuando no aplica. El `Select` de 4 métodos y la cuenta bancaria obligatoria para métodos bancarios quedan como están.
- **`/caja` — historial**: los tres tipos nuevos con etiqueta, ícono, tono semántico y familia de filtro propios; `purchase_payment` con su etiqueta corregida.
- **Invalidaciones**: las mutaciones de compra y de cobro/pago pasan a invalidar además las query keys de caja, con las claves que **ya existen** en `lib/query-keys.ts`.

### Fuera de alcance, declarado

- **Reverso o anulación de un cobro/pago de cuenta corriente**: **no existe ese flujo hoy** — verificado en prod, no hay `rpc_delete_payment_*` ni endpoint `DELETE` en `routers/customer_accounts.py` / `routers/supplier_accounts.py`. No hay borrado que compensar. Si se agrega en el futuro, la compensación de caja tiene que nacer con él.
- **Asiento contable de los movimientos nuevos**: diferido a V2.6 junto con el resto del plan de cuentas, igual que el gasto (D10 de `gastos-forma-pago`). El evento de la compra no cambia su payload.
- **Migrar los modales de cobro/pago al catálogo `payment_methods`**: las dos RPCs usan la taxonomía `text` cerrada `{cash, transfer, card, check}`, ajena al catálogo. Unificarlas es el espejo de `pos-catalogo-pagos` y merece su propio change.
- **Opt-in de caja en la *edición* de una compra**: la edición no ofrece cuenta bancaria (D8 de `pos-banco-movimientos`) y una compra con caja posteada pasa a ser inmutable por el punto 4, así que el caso no existe.
- **Backfill de los 11 documentos históricos** (4 compras cash + 6 cobros + 1 pago): no se hace (D11).

## Capabilities

### New Capabilities
- `purchase-operation`: contrato propio de la operación de compra — persistencia de su sucursal (RN-93) y descuento de caja por opt-in con las tres condiciones verificadas en el servidor. Espejo de `expense-operation`, para los dos requirements que hoy no tienen capability donde vivir.

### Modified Capabilities
- `cash-movement`: el enum de tipos pasa de 8 a 11 (`purchase_payment_reversal`, `payment_received`, `payment_made`), con su clasificación por signo y por familia; la compra en efectivo, el cobro y el pago se declaran **productores reales**; se agrega el contra-movimiento de caja por borrado de una compra, con su bloqueo `P0426` y su disparo por existencia.
- `cash-session`: el requirement "Sólo el camino del mostrador alimenta el arqueo" deja de ser cierto — el arqueo lo alimentan también la compra en efectivo, el cobro y el pago de cuenta corriente, todos por opt-in explícito y verificado en servidor.
- `customer-account`: el cobro en efectivo deja de ser un no-op sobre los libros de dinero; la cláusula "SHALL seguir el camino de caja existente" se reemplaza por el opt-in real, con la idempotencia cubriendo el movimiento de caja.
- `supplier-account`: espejo exacto del anterior para el pago a proveedor.
- `payment-method`: "La forma de pago dispara los efectos según el camino, no según la etiqueta" suma la rama `cash` de la compra.
- `operation-delete-compensation`: el borrado de una compra suma la pata de caja al contrato transversal — de tres libros a cuatro.
- `operation-edit-context`: el predicado de inmutabilidad de la compra suma el movimiento de caja, y el listado expone el bloqueo de borrado por falta de sesión abierta.

## Impact

**DB — migración `20261018000001_caja_compras_cobranzas.sql`** (numeración verificada contra `origin/main` y contra `supabase_migrations.schema_migrations` en prod: última = `20261017000001`, 266 filas):
- `CHECK` de `cash_movements.movement_type` ampliado a 11 tipos, idempotente, sin invalidar ni reescribir las 71 filas existentes.
- 3 RPCs reescritas **partiendo del `pg_get_functiondef` vivo hasheado** (regla de la casa): `rpc_create_purchase_operation`, `rpc_register_payment_received`, `rpc_register_payment_made` — `DROP` de la firma anterior + `CREATE` de la nueva para no dejar dos overloads convivientes, con `REVOKE` explícito de `PUBLIC`, `anon` **y** `authenticated` y `GRANT` selectivo en la misma migración.
- 1 RPC reescrita sin cambio de firma: `rpc_delete_purchase_operation`.
- **Cero helpers nuevos.** `c28_register_cash_movement`, `_pay_register_operation_bank_movement`, `_pay_register_party_charge` y `_pay_reverse_party_charge` se usan tal cual.

**Backend Python** (`backend/`):
- `schemas/cash.py`: `MovementType` + `_INCOME_TYPES`/`_EXPENSE_TYPES` con los tres tipos nuevos.
- `schemas/purchases.py`: `PurchaseOperationIn` gana `branch_id` y `cash_session_id`; `PurchaseItemOut` gana `has_cash_movement` e `is_delete_blocked`.
- `schemas/customer_accounts.py` / `schemas/supplier_accounts.py`: `PaymentReceivedIn` / `PaymentMadeIn` ganan `cash_session_id`.
- `services/purchases.py`, `services/customer_accounts.py`, `services/supplier_accounts.py`: passthrough.
- `repositories/purchase_repository.py`: `create_operation` y `create_operation_with_event` dejan de pasar `NULL` literal en `p_branch_id` y suman `p_cash_session_id`; `list_paginated_by_operation` suma los dos `EXISTS` nuevos.
- `repositories/customer_account_repository.py`, `repositories/supplier_account_repository.py`: nuevo parámetro.
- `core/errors.py`: **cero ERRCODEs nuevos** — `P0400/P0401/P0409/P0412/P0422/P0423/P0426` ya existen y ya están mapeados.

**Frontend** (`frontend/`):
- `hooks/use-cash-optin.ts`: `CashOptinDocument` suma `"compra"` y `"cobro"` (sólo texto del motivo).
- `components/forms/purchase-form.tsx`, `components/customer-accounts/RegisterPaymentForm.tsx`, `components/supplier-accounts/RegisterPaymentMadeForm.tsx`: bloque de opt-in.
- `hooks/data/use-purchases.ts`, `hooks/data/use-customer-account.ts`, `hooks/data/use-supplier-account.ts`: payload + invalidaciones de caja.
- `lib/types.ts` (`CashMovementType`), `lib/ledger/cash-movement-meta.ts` (meta + familias).
- Listado de compras: flags nuevos hacia `getDeleteCompensation`.

**Sistemas que empiezan a ver datos que antes no veían**: el arqueo de caja (`expected_balance`), el historial de `/caja`, y `rpc_branch_report` (por la sucursal de la compra).
