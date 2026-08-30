## Why

> **Governance: MEDIUM, con un tramo de severidad ALTA.** El change escribe dinero en dos libros (caja y banco) desde RPCs `SECURITY DEFINER` nuevas. Mismo nivel que `compras-proveedor-cuenta-corriente`, que también postea cargos reales: implementación con checkpoints 🛑 explícitos en los tramos que tocan libros, no autonomía plena. No es CRÍTICO: no cierra un hueco de auth ni de tenancy, y no toca billing.

**Pedido textual del PO (2026-08-28):** *"Modificar Módulo Gastos para incluir identificación del gasto, ejemplo efectivo, transferencia y que estos movimientos concilien caja y banco"*.

El gasto es hoy **el único documento operativo del sistema que no dice con qué se pagó**. `public.expenses` tiene `category`, `amount`, `date`, `cost_center_id` — y ninguna columna de forma de pago. La consecuencia es que la plata que sale por gastos no existe para ningún libro: **175 gastos en producción** (9 cuentas, 2026-03-07 → 2026-08-29, **$8.723.710,63**) no produjeron **ni un solo** movimiento de caja ni bancario. El arqueo de caja nunca vio un egreso por gasto (`cash_movements` con `movement_type = 'expense'`: **0** filas sobre 67 movimientos vivos) y la conciliación bancaria nunca vio una transferencia de gasto.

Esto **no es un pedido nuevo**: es la deuda `gastos-forma-pago` que dejó anotada la OQ-4 de `pos-banco-movimientos` (`CHANGES.md` L1097) — *"extender el catálogo `payment_methods` a `expenses` para que los gastos por transferencia también escriban `bank_movement`; diferido hasta que `expenses` tenga imputación de forma de pago"*. La precondición que la difería ya está cumplida: el catálogo `payment_methods` está **sembrado en las 37 cuentas** con los 7 `kind`, y ventas y compras ya despachan por `kind` con predicados probados en producción.

**El modelo ya anticipó este change y nunca se cableó**, en las dos puntas:

- **DB**: el `CHECK` de `cash_movements.movement_type` **ya acepta `'expense'`** desde C-28. No hay que ampliar nada; hay que producirlo.
- **Frontend**: `CASH_MOVEMENT_META` ya tiene la entrada `expense` (etiqueta "Gasto", ícono de egreso, tono `destructive`, familia "Egresos" del filtro) y `BANK_MOVEMENT_META` ya tiene `transfer_out`. **Las pantallas de /caja y /banco ya saben mostrar un gasto**; nadie se lo mandó nunca.

**Por qué el change es estructural y no una columna.** El gasto se crea con un `INSERT` plano desde `ExpenseRepository.create()` (L22) — **no existe ninguna RPC de gasto**, y `update()` (L39) y `delete()` (L52) son `UPDATE`/`DELETE` crudos sin un solo guard. Un `INSERT` desde Python no puede tocar dos libros atómicamente: por DEC-24 la unidad de trabajo del proyecto es la RPC `SECURITY DEFINER`. Y el `DELETE` crudo es **exactamente** el agujero que produjo un cargo fantasma real en producción y motivó `delete-guard-ledgers`: si el alta postea dinero, el borrado sin compensación deja el libro apuntando a un gasto que ya no existe.

## What Changes

### 1. El gasto imputa forma de pago (catálogo, no texto)

- `public.expenses` suma `payment_method_id uuid NULL REFERENCES payment_methods(id)` — **espejo exacto** de `sales.payment_method_id` y `purchases.payment_method_id`. Nullable: los **175 gastos históricos** quedan como "Sin imputar", sin backfill (D7).
- El `kind` **se deriva en el servidor** desde el catálogo, nunca se acepta como texto del cliente; forma de pago inexistente, inactiva, borrada o de otra cuenta → `P0404`. Predicado copiado literal de `rpc_create_sale_operation_v2`.
- `public.expenses` empieza además a **persistir `branch_id`** (la columna existe y `create()` nunca la escribió: **0 de 175** gastos tienen sucursal). Lo exige **RN-93** y lo necesita el guard de sucursal del opt-in de caja. Efecto colateral: `rpc_branch_report`, que hoy nunca ve un gasto, empieza a verlos.

### 2. El gasto impacta los libros según el `kind`, reutilizando los helpers que ya existen

- **Efectivo** → `c28_register_cash_movement(p_cash_session_id, -importe, 'expense', id_del_gasto)`. Signo negativo (egreso). El helper aporta gratis: sesión abierta (`P0409`), tenencia de la sesión (`P0401`, agregada por `tenancy-guard-caja-outbox`), sucursal activa (`P0422`), `balance_after` serializado y `created_by`. **El gasto es exactamente el "caller futuro" que ese guard fue escrito para cubrir.**
- **Transferencia / tarjeta / cheque / billetera** → `_pay_register_operation_bank_movement(..., 'out', 'expense', id_del_gasto, fecha, sucursal, NULL)`. Llamada **incondicional**, igual que venta y compra: el helper decide. Aporta gratis el predicado `kind IN ('transfer','card','check','wallet')`, la resolución y validación de la cuenta bancaria (`P0412`), el rechazo de cuenta bancaria sobre `kind` no bancario (`P0400`), el mapa `kind`→`movement_type`, el signo y el **guard de período conciliado** (`P0424`).
- **Cero lógica bancaria o de caja nueva.** El change no crea ni un helper: todo lo que necesita ya existe y está probado en dos caminos.
- El movimiento bancario nace `reconciliation_status = 'unreconciled'` y **aparece solo** en la pantalla de conciliación — no hay tabla ni RPC intermedia. Con la fecha valor tomada de la fecha del gasto, la sugerencia automática (monto exacto, ±3 días) lo engancha contra el extracto.

### 3. La cuenta bancaria deja de fallar en silencio en el camino de gasto

**Bloqueante de producto medido:** `payment_methods` con `bank_account_id` configurado = **0** en las 37 cuentas. Con la cuenta sin resolver, `_pay_register_operation_bank_movement` retorna `NULL` **sin error** — o sea que, tal cual está, el pedido literal del PO fallaría en silencio para el 100% de los tenants.

- El **formulario de gasto** monta `BankAccountDestinationSelect` (el mismo componente de venta y compra) y allí es **obligatorio**, no opcional.
- La **RPC de gasto** lo respalda: si el `kind` es bancario, la cuenta no resuelve (ni override ni default) **y la organización tiene al menos una cuenta bancaria activa** → `P0412`. Si la organización **no tiene ninguna** cuenta bancaria (**33 de 37** hoy), el gasto se guarda como etiqueta sin efecto bancario, con el motivo visible en la UI.
- **El helper compartido NO se toca**: la spec `bank-movement` exige que "sin cuenta resuelta la venta sigue funcionando igual que antes". El endurecimiento vive en el caller de gasto, no en el punto de paso común.

### 4. El CRUD de gastos pasa a tres RPCs atómicas — alta, edición y borrado, en una sola etapa

- `rpc_create_expense`, `rpc_update_expense`, `rpc_delete_expense`, `SECURITY DEFINER`, `search_path` fijado. El tenant **se resuelve desde la sesión**, nunca por parámetro (lección de `_pay_register_party_charge` y del hotfix #454); el rol de escritura se verifica explícitamente, porque un `DEFINER` deja la RLS fuera de juego.
- **La edición y el borrado no son opcionales.** Un alta que postea dinero con un `DELETE` crudo al lado reproduce el cargo fantasma de `delete-guard-ledgers`.
- **BREAKING (dominio)**: un gasto con movimiento de caja o bancario posteado pasa a ser **inmutable** (`P0423`, ya mapeado a HTTP 409). Se corrige borrando y recargando, camino que este change vuelve seguro. El gasto sin dinero posteado —la enorme mayoría— sigue plenamente editable.
- **BREAKING (dominio)**: borrar un gasto en efectivo **exige una sesión de caja abierta** (`P0426`), porque la compensación se postea contra la sesión abierta de hoy y jamás toca la sesión original (append-only). Mismo comportamiento que ya tiene el borrado de una venta en efectivo.
- El borrado compensa **las dos patas** en la misma transacción: caja (contra-movimiento) y banco (espejo invertido `transfer_out`→`transfer_in`).

### 5. `expense_reversal` completa el vocabulario de caja

El `CHECK` de `cash_movements.movement_type` acepta `expense` pero **no tiene el tipo de su contra-partida**. Se agrega `expense_reversal`, con el mismo patrón de contra-movimiento automático con tipo propio que `sale_reversal`. **Dos clasificaciones distintas, que no hay que mezclar** (D9): por **signo** entra en los tipos de **ingreso** (`backend/schemas/cash.py`), porque revertir un egreso repone plata — al revés que `sale_reversal`, que es egreso; por **familia** del filtro del historial de caja entra en **"Reversas"** junto a `sale_reversal` (`frontend/lib/ledger/cash-movement-meta.ts`), **no** en "Ingresos". Conjuntos finales del validador de signo: ingresos `{sale, advance, expense_reversal}` · egresos `{purchase_payment, expense, withdrawal, sale_reversal}` · signo libre `{adjustment}`.

### 6. Superficie frontend (regla PO 2026-08-02) — toda sobre `/gastos`, que ya existe

La ruta y la entrada de sidebar ya existen (`app-sidebar.tsx:44`, `breadcrumb-nav.tsx:24`): no hace falta ruta ni menú nuevos.

- **Formulario** (`expense-form-v2.tsx`): `PaymentMethodSelect` con contexto de gasto (reuso; el componente suma el contexto y su texto de apoyo, no se crea uno nuevo) + `BankAccountDestinationSelect` condicional + bloque de **opt-in de caja** con las tres condiciones verificadas en servidor y el motivo visible cuando no aplica — **nunca se oculta en silencio**.
- **Listado** (`gastos/page.tsx`): **migra su lectura a `GET /expenses` paginado del backend**, espejo exacto de lo que ya hace `/ventas` con `useSales()` (D18). Hoy lee por PostgREST directo (`usePaginatedQuery({ table: "expenses" })`), y por ese camino **no hay forma** de que llegue el lock, que es un derivado de `cash_movements`/`bank_movements` y no una columna de `expenses`. Sobre esa base: badge de forma de pago con tonos **semánticos** (no los `categoryColors` literales que el gate `token-contrast-aa` proscribió) con el nombre resuelto por el backend (`payment_method_name`, como en `SaleOut`), y filtro por forma de pago como query param server-side. `usePaymentMethods(true)` queda sólo para poblar el selector del filtro, con `includeInactive` para que una forma dada de baja siga ofreciéndose y nombrándose.
- **Lock visible**: `ExpenseOut` suma `is_payment_locked`, `has_cash_movement`, `has_bank_movement` (espejo literal de `SaleOut`) y `is_delete_blocked` (hay movimiento de caja del gasto y **no** hay sesión abierta en ese `cashbox` — el mismo `EXISTS` que precede al `P0426`), para deshabilitar "Editar"/"Eliminar" con motivo **antes** de llegar al 409 y para que el diálogo de borrado enumere qué libro compensa.
- **Invalidaciones**: las tres mutaciones pasan a invalidar además caja, banco, conciliación y el reporte de formas de pago, con las query keys que **ya existen** en `lib/query-keys.ts`. **No** se bumpea el `refreshToken` de `LedgerMovementsPanel`: es `useState` local de `/banco` y `/caja`, esos paneles no están montados mientras el usuario está en `/gastos`, y refrescan solos al montar (el repo ya fijó esa división en `use-cash-movements.ts:121-125`).
- **Canonización pendiente de la Regla de Tres**: el badge de forma de pago está hoy duplicado literal en 4 lugares (ventas ×2, compras ×2); con gastos serían 6 → se canoniza un `PaymentMethodBadge` y se sube `KIND_LABELS` desde el interior de `PaymentMethodManager` a la capa canónica.
- Verificación obligatoria en **desktop y mobile** y en **tema claro y oscuro**.

### 7. Dos bugs pre-existentes de gastos que este change no puede dejar vivos

`use-expenses-query.ts` descarta `branch_id` en el alta (el form lo manda, el `mutationFn` no lo pone en el payload) y **pierde `cost_center_id` en cada edición**. Es el mismo patrón que `edicion-preserva-contexto` (#423/#424) ya corrigió para ventas y compras. Se arreglan acá porque un `payment_method_id` que se borra solo al editar un gasto **ya imputado a caja** no es una molestia cosmética: es un descuadre de libros.

### Fuera de alcance (declarado explícitamente)

- **Asiento contable del gasto.** `_journal_post_from_event` filtra por una whitelist literal de 9 `event_type` y **ninguno es de gasto**; `public.events` no tiene ningún evento de gasto entre sus 13 tipos con datos. `CHANGES.md` lo tiene diferido a V2.6. Incluirlo duplicaría el tamaño del change.
- **Emisión de eventos al outbox.** La RPC de gasto **no** inserta en `public.events` (evita el chequeo (5) del gate de ACLs y no hay consumer de gasto). El trigger `trg_analytics_operation_created` está en la tabla, no en el camino de código: sigue disparando gratis.
- **`kind = 'credit'` en gastos.** Un gasto no tiene contraparte (`expenses` no tiene `supplier_id`): no hay cuenta corriente que cargar. El camino correcto para "lo pago después" es la compra a proveedor, que ya existe.
- **Backfill de los 175 gastos históricos.** Ver D7.
- **Sembrar `bank_account_id` por defecto en el catálogo.** Es configuración del PO, no de este change (OQ-2).
- **Importador CSV con forma de pago.** Ver D13.
- **Soft delete de gastos.** `expenses` no tiene `deleted_at` (`v3-soft-delete-policy` no la cubrió). Fuera de alcance: el borrado sigue siendo físico, ahora con compensación.

## Capabilities

### New Capabilities

- `expense-operation`: el gasto como **operación transaccional** — alta, edición y borrado atómicos vía RPC `SECURITY DEFINER`, con forma de pago imputable, sucursal persistida, impacto en libros despachado por `kind`, inmutabilidad del gasto con dinero posteado, compensación al borrar y las superficies que lo hacen operable.

### Modified Capabilities

- `payment-method`: la imputación opcional de la forma de pago se extiende a **gastos** (hoy la spec sólo la define para ventas y compras); `kind = 'credit'` no es aplicable a un gasto y se rechaza en las dos puntas; el selector suma el contexto de gasto con su texto de apoyo propio; el read-model de distribución por forma de pago suma los gastos; y el requirement **"Superficies de la forma de pago"**, que hoy enumera de forma cerrada ventas y compras en sus puntos (b) y (c), suma gastos — sin eso, tras el archive la spec principal describiría un sistema que ya no es el real.
- `cash-movement`: el gasto pasa a ser **productor real** de `movement_type = 'expense'` (tipo aceptado desde C-28 y jamás emitido) y el vocabulario suma `expense_reversal` para su contra-partida, espejo de `sale_reversal`.
- `bank-movement`: los gastos por método bancario registran un `bank_movement` automático con `source_doc_type = 'expense'`, y en el camino de gasto la cuenta bancaria **deja de degradar en silencio** cuando la organización tiene cuentas activas.
- `operation-delete-compensation`: el borrado de un gasto compensa caja y banco dentro de la misma RPC atómica, con los mismos guards y el mismo criterio de destino del contra-movimiento que el borrado de una venta.
- `operation-edit-context`: el gasto con dinero posteado es inmutable (`P0423`) con su espejo de lectura en el listado, y la edición de un gasto **preserva** su contexto (sucursal, centro de costo, forma de pago) mediante el contrato tri-estado, cerrando dos pérdidas silenciosas pre-existentes.

## Impact

**DB — una migración: `20261015000001_gastos_forma_pago.sql`**

`MAX(version)` vivo en prod verificado hoy (2026-08-28, sólo `SELECT`): **`20261014000001`** (263 migraciones), idéntico al último archivo de `origin/main`. El próximo libre es **`20261015000001`**, y **se re-verifica en el apply** justo antes de escribir el archivo: en este proyecto la renumeración ya mordió tres veces.

- `public.expenses`: `ADD COLUMN payment_method_id uuid NULL REFERENCES payment_methods(id) ON DELETE SET NULL`; índice `(account_id, payment_method_id)`. `branch_id` ya existe (se empieza a escribir, no se agrega).
- `public.cash_movements`: `CHECK` de `movement_type` ampliado con `expense_reversal` (drop + add idempotente).
- Funciones nuevas: `rpc_create_expense`, `rpc_update_expense`, `rpc_delete_expense` (`SECURITY DEFINER`, `REVOKE` de `anon` + `GRANT` a `authenticated`, patrón uniforme del proyecto). **Sin helpers internos nuevos** → no dispara el chequeo (4) del gate de ACLs.
- `rpc_payment_method_report`: reescritura completa desde el `pg_get_functiondef` **vivo** para sumar los gastos (checkpoint 🛑 de gate de integridad de función). Sumar `total_spent` cambia el `RETURNS TABLE`, así que **no** se puede con `CREATE OR REPLACE` pelado (42P13): va `DROP FUNCTION IF EXISTS public.rpc_payment_method_report(uuid, date, date)` + `CREATE` + **re-emisión completa de sus ACLs** (el `DROP` las resetea) + gate ANTI-OVERLOAD propio. Ver D14.
- Funciones **reutilizadas sin tocar**: `c28_register_cash_movement`, `_pay_register_operation_bank_movement`, `_pay_resolve_bank_account`, `_register_bank_movement`, `c26_default_branch`, `reporting_local_today`, `is_account_writer`, `current_account_ids`.
- **Ningún ERRCODE nuevo.** `P0400`/`P0401`/`P0404`/`P0409`/`P0412`/`P0422`/`P0423`/`P0424`/`P0426` ya existen y ya están mapeados en `backend/core/errors.py`. `P0001` queda prohibido (un gate viejo de `20260804000003` lo re-lanza y abortaría `supabase db reset`).

**CI**

- `supabase/tests/test_gastos_forma_pago.sql`: gate propio del change (despacho por `kind`, opt-in de caja, inmutabilidad, compensación al borrar, aislamiento por cuenta, cleanup sin residuos).
- Gates que deben seguir verdes sin cambios: `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_delete_guard_ledgers.sql`, `test_payment_method_operations.sql`, `test_payment_method_report.sql`, `test_banco_caja_historial_ajustes.sql`, `test_pos_banco_movimientos.sql`, `test_tenancy_guard_caja_outbox.sql`, `token-contrast-aa.test.ts`.
- `.github/workflows/KPI_Validation.yml`: la migración nueva se suma como último eslabón de la cadena de reapply idempotente, más un step propio para el gate SQL nuevo. Se **verifica** (no se supone) que el reapply tolerado de `20260928000001` sigue abortando en su gate ANTI-OVERLOAD de la sección 9, **antes** del `CREATE` de `rpc_payment_method_report` de la sección 10 — que es lo que evita que la firma vieja de 7 columnas choque con la nueva de 8 (42P13). Ver D14 y task 1.5.

**Backend Python**

- `backend/schemas/expenses.py` — `ExpenseCreate`/`ExpenseUpdate` suman `payment_method_id`, `branch_id`, `cash_session_id`, `bank_account_id` (`uuid | None`, **passthrough opt-in**: el service no los interpreta); `ExpenseOut` suma `payment_method_id`, `branch_id` y el derivado `is_payment_locked`. `ExpenseUpdate` adopta el contrato **tri-estado** (`model_fields_set`).
- `backend/repositories/expense_repository.py` — `create`/`update`/`delete` pasan de SQL crudo a **una** llamada a su RPC; `get_by_id`/`list_by_org` suman los derivados de lock y `list_by_org` adopta paginación y filtros server-side (D18), con la plomería que ya tiene `/sales`.
- `backend/routers/expenses.py` — `GET /expenses` adopta el contrato paginado estándar `{items,total,page,pages}` (`v3-api-standards`) con `page`, `page_size`, `date_from`, `date_to`, `search`, `cost_center_id` y `payment_method_id`. **BREAKING de API interna**: el endpoint deja de devolver una lista plana; el único consumidor es el frontend propio.
- `backend/schemas/cash.py` — `MovementType` suma `expense_reversal`, que entra en los tipos de ingreso.
- `backend/services/expenses.py`, `backend/routers/expenses.py` — sin lógica de negocio nueva (DEC-24): validación Pydantic + delegación.
- `backend/core/errors.py` — `EXPENSE_ERRCODE_STATUS` (override por endpoint, molde de `BANK_ACCOUNT_CREATE_ERRCODE_STATUS`): `P0412` → **422** con `field = "bank_account_id"` **sólo** en el camino de gasto; su 404 global queda intacto (D19).
- `backend/tests/test_expenses.py` — **ya existe** (7 `def test_`): safety net previo obligatorio (task 1.2b) y después ampliación con los caminos nuevos.

**Frontend**

- `frontend/components/forms/expense-form-v2.tsx` — selectores + opt-in de caja.
- `frontend/components/payment-methods/PaymentMethodSelect.tsx` — el contexto suma `"expense"`; el texto de apoyo suma su rama; `credit` no se ofrece en contexto de gasto (extensión aditiva).
- `frontend/hooks/data/use-expenses-query.ts` — pasa a ser el hook del listado con paginación y filtros (calcado de `useSales()`), payload completo, contrato tri-estado, invalidaciones de caja/banco/conciliación; **corrige los dos bugs pre-existentes**. Tiene 5 casos vivos en `__tests__/hooks/use-expenses.test.ts` que fijan los payloads actuales: safety net previo obligatorio.
- `frontend/app/(dashboard)/gastos/page.tsx` — origen de datos (D18), badge + filtro + lock visible + columna nueva en el export local.
- `supabase/functions/generate-export/index.ts` — **Edge Function Deno, no frontend**: el `ExportButton` con `exportType="expenses_csv"` se resuelve acá (`fetchExpensesRows` + los headers `['fecha','categoria','descripcion','monto','moneda','sucursal']`, líneas 91-103 y 255-257), y la hoja "Gastos" del XLSX consolidado usa el mismo `fetchExpensesRows`. Sumar la columna requiere resolver el nombre del método (join a `payment_methods`) y **tiene deploy propio**: no viaja con la migración del merge.
- `frontend/lib/types.ts` — `Expense` suma `paymentMethodId`, `paymentMethodName`, `branchId`, `isPaymentLocked`.
- `frontend/lib/ledger/cash-movement-meta.ts` — entrada `expense_reversal`.
- `frontend/components/payment-methods/PaymentMethodBadge.tsx` (nuevo, canonización) + `frontend/lib/payment-method-meta.ts` con `KIND_LABELS` subido desde `PaymentMethodManager`.
- `frontend/lib/payment-method-report.ts` + `/reportes/formas-pago` — columna de gastos.
- `frontend/components/gastos/expense-import-dialog.tsx` — sólo el texto de ayuda del paso 1 (el template **no** cambia).
- `frontend/lib/database.types.ts` — regenerado.
- `frontend/__tests__/` — el módulo **sí tiene tests hoy** (`hooks/use-expenses.test.ts`, `components/expense-form-date-default.test.tsx`, `components/expense-import-dialog-parse-and-validate.test.ts`, más `components/RecentActivity.test.tsx` que mockea `useExpenses`): safety net previo (D15) y después cobertura nueva de listado, lock y a11y.

**Documentación**

- `knowledge-base/04_modelo_de_datos.md` (columnas nuevas de `expenses`, vocabulario de `cash_movements`), `knowledge-base/05_reglas_de_negocio.md` (RN-93 pasa de aspiracional a cumplida para gastos), `CHANGES.md` (la entrada L1097 deja de ser candidato diferido).

**Relación con otros changes**

- Consume directo lo entregado por `metodos-pago-operaciones`, `pos-banco-movimientos`, `pagos-cableados-restantes`, `delete-guard-ledgers`, `edicion-preserva-contexto` y `tenancy-guard-caja-outbox` (cuyo guard de tenencia de caja cubre a este change **sin ninguna línea nueva**).
- **No** depende de `v3-rbac-multirole` (CRÍTICO, bloqueado a sign-off del PO): usa el gating de rol vigente.
- Sin conflicto de archivos con los changes activos (`asiento-venta-formulario`, `mp-real-subscriptions`, `v31-*`): ninguno toca `expenses`, `expense_repository.py` ni el formulario de gastos. El único punto de contacto es `rpc_payment_method_report`, que ningún change activo modifica.
- Deja como candidato natural el **asiento contable del gasto** (V2.6), que este change habilita al dejar la forma de pago imputada.
