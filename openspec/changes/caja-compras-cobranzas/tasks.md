# Tasks — `caja-compras-cobranzas`

> ## 🛑 GATE DE GOVERNANCE — LEER ANTES DE TOCAR NADA
>
> **Governance: MEDIA, con un tramo de severidad ALTA** (los grupos 3, 4 y 5 escriben
> dinero real en el libro de caja desde RPCs `SECURITY DEFINER`). Implementación con
> **checkpoints 🛑 explícitos** en esos tramos: se implementa en pasos y se sube la
> decisión al PO donde está marcado. No hay autonomía plena.
>
> **Strict TDD activo.** Cada task de código sigue RED → GREEN → TRIANGULATE →
> REFACTOR, con safety net previo sobre lo que se toca. Los tests van **antes** de la
> implementación, nunca después. Prohibidas las aserciones triviales.
>
> **REGLA DE INTEGRIDAD DE FUNCIÓN (la más importante de este change).** Este change
> reescribe **cuatro** RPCs, una de ellas de 19.438 caracteres. Toda reescritura parte
> del `pg_get_functiondef` **VIVO de producción**, hasheado y guardado en `baseline/`,
> **nunca** del archivo de migración del repo — que ya divergió del cuerpo vivo al
> menos una vez (el G3 de `20261003000001`, reescrito in-place). Si el hash del apply
> no coincide con el registrado en `design.md`, **parar y reportar** antes de escribir
> una línea de SQL.
>
> **Reutilización antes que repetición.** Este change **no crea ni un helper SQL ni un
> hook nuevo**. `c28_register_cash_movement`, `_pay_register_operation_bank_movement`,
> `_pay_reverse_party_charge`, `useCashOptin` y `getDeleteCompensation` se usan tal
> cual. Si una task parece necesitar lógica financiera nueva, es señal de que se está
> resolviendo el problema equivocado: parar y reportar.
>
> Las tasks marcadas **[OQ-n]** dependen de la respuesta del PO a la Open Question
> correspondiente de `design.md`. **Sin respuesta, se implementa la recomendación** y
> se registra que salió así (precedente del proyecto).
>
> **Nunca commitear a main.** Todo por rama + PR, incluidos los fixes triviales
> posteriores al merge.

## 0. Sign-off y decisiones de producto

- [x] 0.1 🛑 Presentar al PO, **antes de escribir código**, los tres hechos que cambian su experiencia: (a) las **4 compras en efectivo, 6 cobros y 1 pago históricos** quedan **sin movimiento de caja para siempre** (D11, no hay backfill honesto — y de los cobros ni siquiera se sabe cuáles fueron en efectivo, porque el método de pago nunca se persistió); (b) una compra que ya impactó la caja pasa a ser **inmutable** — se corrige borrando y recargando (D8); (c) **borrar una compra en efectivo va a exigir la caja abierta** (`P0426`, D7). Registrar la respuesta acá. — ✅ **Firma del PO 2026-09-01** ("aplicalo con todas las recomendaciones"), tras presentarle los tres hechos: (a) sin backfill de los 11 históricos, imposible además por falta de datos — el PO puede cuadrar con un `adjustment` manual si quiere; (b) compra con caja posteada = inmutable, se corrige borrando y recargando; (c) borrado de compra con caja exige sesión abierta (`P0426`).
- [x] 0.2 🛑 **[OQ-1]** Confirmar si `payments_received` / `payments_made` empiezan a **persistir el método de pago** (recomendación: SÍ — dos columnas aditivas y nullable, sin backfill, escritas por las mismas RPCs que este change ya reescribe). Explicarle que es la razón #1 por la que hoy el backfill es imposible. — ✅ **[OQ-1] Firmada 2026-09-01**: SÍ, persistir `payment_method` de ahora en más (aditivo, sin backfill).
- [x] 0.3 🛑 **[OQ-2]** Confirmar el valor inicial del opt-in: **pre-marcado** en los tres caminos (recomendación), alineado con el gasto y no con la venta. Explicar la asimetría: la venta arranca desmarcada porque su formulario se usa para carga retroactiva de administración; compra en efectivo de hoy y cobro en efectivo describen plata que pasó por el cajón. — ✅ **[OQ-2] Firmada 2026-09-01**: opt-in de caja **pre-marcado** en los tres caminos (compra, cobro cliente, pago proveedor).
- [x] 0.4 **[OQ-3..OQ-5]** Registrar la respuesta del PO al relabel de `purchase_payment` → "Compra en efectivo" (OQ-3), al reverso de cobros fuera de alcance (OQ-4) y a la confirmación del "sin backfill" (OQ-5). Sin respuesta → recomendación, y se anota. — ✅ Registrado 2026-09-01, las tres por su opción recomendada: OQ-3 relabel de `purchase_payment` → "Compra en efectivo" SÍ, sin sign-off adicional (0 filas hoy); OQ-4 reverso de cobros/pagos de cuenta corriente queda **fuera de este change** (Non-Goal fundado; candidato `cobranzas-reverso` dado de alta en la task 16.3); OQ-5 sin backfill de los 11 históricos, confirmado.
- [x] 0.5 Registrar las decisiones de 0.1-0.4 en `CHANGES.md` y en engram (`topic_key: opsx/caja-compras-cobranzas/apply`) **antes** de escribir una línea de código. — ✅ 2026-09-01, ver entrada en `CHANGES.md` y `mem_save` con ese `topic_key`.

## 1. Reconocimiento y safety net

- [ ] 1.1 Re-verificar el **MAX de `supabase_migrations.schema_migrations` vivo en prod** (sólo `SELECT`) y compararlo con el último archivo de `origin/main`. Al escribirse el propose era `20261017000001` (266 migraciones) → el archivo nace como `20261018000001_caja_compras_cobranzas.sql`. ⚠️ **Se re-verifica acá, siempre**: en este proyecto la renumeración mordió tres veces. Un archivo con número **menor o igual** al MAX remoto no lo aplica nunca el push automático de Supabase.
- [ ] 1.2 **CHECKPOINT DE INTEGRIDAD DE FUNCIÓN.** Volcar a `baseline/` el `pg_get_functiondef` **vivo** de las cuatro RPCs a reescribir + los dos helpers de referencia, con su `md5` y su longitud. Comparar contra la tabla de `design.md`:
  - `rpc_create_purchase_operation` → `058f4d291d85bec0ae46589bde49e3a3` (19.438)
  - `rpc_delete_purchase_operation` → `e10a1505250d1d6d9301de38a719ee75` (4.165)
  - `rpc_register_payment_received` → `3af320ebaf30a94eaa7bbf8e3cd05404` (7.031)
  - `rpc_register_payment_made` → `f4b6bdfa06f4c35c487459c24a143b31` (6.148)
  - `rpc_atomic_update_purchase_operation` → `0dc8bcf0902710ecb126a9edb9bc3e5f` (23.205)
  - referencia (no se toca): `rpc_create_expense` `c8f2ef98…`, `rpc_delete_expense` `4d78ee3b…`
  🛑 **Cualquier divergencia detiene el apply.**
- [ ] 1.3 Volcar también a `baseline/` el `pg_get_functiondef` de `rpc_create_expense` y `rpc_delete_expense` **completos**: son el molde literal que las tasks 3.x y 5.x copian. Marcar en el volcado el bloque del opt-in de caja (las tres condiciones) y el de la compensación con `P0426`.
- [ ] 1.4 Correr la suite backend completa (`python -m pytest backend/tests -q -p no:cacheprovider`) y registrar el baseline `N/N`. Cualquier fallo preexistente se **reporta**, no se arregla acá.
- [ ] 1.5 **SAFETY NET DIRIGIDO (obligatorio).** Correr y registrar por separado, **antes** de tocar cada archivo:
  - `backend/tests/test_purchases*.py` y los que cubran `purchase_repository` → antes de tocar el repo/service/router de compras
  - `backend/tests/test_customer_accounts*.py` / `test_supplier_accounts*.py` → antes de tocar los de cuentas corrientes
  - `backend/tests/test_cash*.py` → antes de tocar `backend/schemas/cash.py`
  - `frontend/__tests__/hooks/use-purchases*.test.ts` (assertan el **payload actual** del alta — este change lo amplía a propósito)
  - `frontend/__tests__/components/purchase-form-*.test.tsx`
  - `frontend/__tests__/components/sale-form-cash-optin-baseline.test.tsx` (congela el comportamiento del hook compartido; **no debe cambiar**)
  > Todos verdes al final. Cada aserción que cambie va **justificada por escrito** en el PR.
- [ ] 1.6 Correr la suite frontend (`pnpm vitest run`, sin pipear a `tail` — enmascara el exit code) y registrar el baseline.
- [ ] 1.7 Levantar el stack local (`npx supabase db reset`) y correr los gates SQL en el orden exacto de CI, registrando el baseline. Prestar atención a `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_delete_guard_ledgers.sql`, `test_outbox_single_dispatcher.sql` y `token-contrast-aa.test.ts`.
- [ ] 1.8 Registrar en `baseline/` las mediciones de producto que el propose usa como argumento, re-medidas hoy (sólo `SELECT`): compras con `kind='cash'`, `payments_received`, `payments_made`, sesiones `open`, filas por `movement_type`, compras con `branch_id`, y **0 funciones vivas que escriban `purchase_payment`**. Si alguna cambió de orden de magnitud, revisar el diseño antes de seguir.

## 2. Migración — vocabulario de caja (grupo 6 del proposal)

- [ ] 2.1 **RED**: escribir el gate SQL `supabase/tests/test_cash_movement_types.sql` que afirme que el CHECK de `cash_movements.movement_type` contiene los **11** tipos, y que insertar `'tip'` falla. Debe **fallar** contra el esquema actual (8 tipos).
- [ ] 2.2 **GREEN**: crear `supabase/migrations/20261018000001_caja_compras_cobranzas.sql` (número re-verificado en 1.1) con la ampliación del CHECK a 11 tipos, **idempotente** (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`), sin `NOT VALID` y sin reescribir filas. Correr el gate → verde.
- [ ] 2.3 **TRIANGULATE**: agregar al gate el conteo de filas **antes y después** de la ampliación (debe ser idéntico) y una segunda aplicación de la migración sobre el mismo esquema (idempotencia real, no declarada).
- [ ] 2.4 **RED→GREEN** en `backend/schemas/cash.py`: test que afirme que `MovementType` tiene los 11 valores y que `_INCOME_TYPES` = `{sale, advance, expense_reversal, purchase_payment_reversal, payment_received}` y `_EXPENSE_TYPES` = `{purchase_payment, expense, withdrawal, sale_reversal, payment_made}`. Después implementar.
- [ ] 2.5 **TRIANGULATE** del validador de signo: un caso por tipo nuevo con el signo **incorrecto**, que debe ser rechazado por `RegisterMovementIn` (`purchase_payment_reversal` negativo, `payment_received` negativo, `payment_made` positivo).
- [ ] 2.6 **RED→GREEN** en `frontend/lib/types.ts` + `frontend/lib/ledger/cash-movement-meta.ts`: test que afirme que `CASH_MOVEMENT_META` tiene entrada para los 11 tipos, que `purchase_payment` dice "Compra en efectivo" (no "Pago a proveedor"), que `payment_made` dice "Pago a proveedor", y que `CASH_MOVEMENT_FAMILIES` ubica `purchase_payment_reversal` en **Reversas**, `payment_received` en **Ingresos** y `payment_made` en **Egresos**.
- [ ] 2.7 Verificar que los tonos usados en las entradas nuevas son **semánticos** (`success`/`destructive`/`warning`) y que `token-contrast-aa.test.ts` sigue verde.

## 3. Migración — la compra en efectivo descuenta de la caja 🛑 TRAMO ALTO

- [ ] 3.1 🛑 **CHECKPOINT**: antes de escribir SQL, releer el volcado de 1.3 y confirmar por escrito que el bloque del opt-in de `rpc_create_expense` se va a copiar **literal** (mismos tres tokens de error, mismo orden, misma comparación `p_date` contra `reporting_local_today()`). ⚠️ **PROHIBIDO** convertir la comparación de fecha a `timestamptz`: el `::date` implícito usa la timezone del servidor (UTC) mientras `reporting_local_today()` usa Mendoza, y una compra cargada entre las 21:00 y las 23:59 se rechazaría con `P0422` justo cuando el usuario sabe que es hoy.
- [ ] 3.2 **RED**: gate SQL `supabase/tests/test_purchase_cash_optin.sql` con los seis casos del requirement — las tres condiciones cumplidas (movimiento `purchase_payment` negativo con referencia a la operación), `kind` no efectivo con sesión informada (`P0422 cash_optin_requires_cash_kind`), sesión de otra sucursal (`P0422 cash_optin_requires_open_session`), fecha de ayer (`P0422 cash_optin_requires_today`), sin sesión informada (no-op, la compra se crea), sesión de otra cuenta (rechazo). Debe fallar entero.
- [ ] 3.3 **GREEN**: reescribir `rpc_create_purchase_operation` **desde el cuerpo vivo de 1.2**, agregando `p_cash_session_id uuid DEFAULT NULL` **trailing** y el bloque del opt-in que delega en `c28_register_cash_movement(p_cash_session_id, -total, 'purchase_payment', v_new_op_id)`. `DROP FUNCTION` de la firma anterior **antes** del `CREATE` (D6). Correr el gate → verde.
- [ ] 3.4 **GREEN (permisos)**: `REVOKE ALL ... FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE TO authenticated` en la misma migración. No basta con revocar `PUBLIC`.
- [ ] 3.5 **TRIANGULATE**: agregar al gate (a) que existe **exactamente una** definición viva de la función (`SELECT count(*) FROM pg_proc WHERE proname='rpc_create_purchase_operation'` = 1) — es el gotcha `42725` de sobrecargas; (b) que una compra `kind='cash'` **sin** sesión no crea ningún `cash_movement` ni `bank_movement`; (c) que el `balance_after` del movimiento es el saldo previo **menos** el total, y no el máximo histórico.
- [ ] 3.6 **TRIANGULATE (regresión)**: verificar en el mismo gate que los caminos preexistentes de la RPC no cambiaron — compra a crédito sigue posteando el cargo del proveedor, compra bancaria sigue escribiendo el `bank_movement`, compra sin forma de pago sigue emitiendo su evento con el default `credit`.
- [ ] 3.7 **REFACTOR**: revisar el diff de la función contra el cuerpo vivo original línea por línea; el único delta admisible es la firma, el bloque nuevo y sus comentarios.

## 4. Migración — cobro y pago de cuenta corriente en efectivo 🛑 TRAMO ALTO

- [ ] 4.1 🛑 **CHECKPOINT**: confirmar por escrito la decisión D5 —**dos** condiciones y no tres, porque `payments_received`/`payments_made` no tienen columna de fecha ni de sucursal (verificado contra `information_schema`)— y que el guard de tenencia lo aporta el backstop `P0401` de `c28_register_cash_movement`.
- [ ] 4.2 **RED**: gate SQL `supabase/tests/test_party_payment_cash.sql` con: cobro en efectivo + sesión abierta → `cash_movement` `payment_received` **positivo** y sin `bank_movement`; pago en efectivo + sesión abierta → `payment_made` **negativo**; método bancario + sesión informada → `P0422 cash_optin_requires_cash_kind`; sesión cerrada → `P0422 cash_optin_requires_open_session`; efectivo sin sesión → cobro registrado y **cero** movimientos de dinero (comportamiento previo intacto). Debe fallar entero.
- [ ] 4.3 **GREEN**: reescribir `rpc_register_payment_received` **desde el cuerpo vivo**, con `p_cash_session_id uuid DEFAULT NULL` trailing, `DROP` de la firma anterior, `REVOKE`/`GRANT` explícitos, y la escritura de caja **dentro** del bloque protegido por la clave de idempotencia (D12).
- [ ] 4.4 **GREEN**: espejo exacto en `rpc_register_payment_made`, con signo negativo y `movement_type = 'payment_made'`.
- [ ] 4.5 **TRIANGULATE (idempotencia, la aserción que más importa)**: llamar dos veces con la misma clave y afirmar que existe **un solo** `cash_movement`, un solo movimiento de cuenta corriente y una sola fila de cobro, y que la segunda llamada devuelve `replayed = true`. Repetir para el pago.
- [ ] 4.6 **TRIANGULATE**: una definición viva por función (`count(*) = 1` en `pg_proc`), y que los caminos bancarios preexistentes siguen escribiendo su `bank_movement` con el mismo `movement_type` y `source_doc_type`.
- [ ] 4.7 **[OQ-1]** Si el PO confirmó la recomendación: agregar en la misma migración las columnas `payment_method text NULL` a `payments_received` y `payments_made`, escritas por las dos RPCs, **sin backfill**, con su gate de que las filas históricas quedan en `NULL`.

## 5. Migración — el borrado de una compra compensa la caja 🛑 TRAMO ALTO

- [ ] 5.1 🛑 **CHECKPOINT**: confirmar por escrito que la pata de caja se inserta **antes** que la bancaria y la de stock (D7), y que el disparo es **por existencia del movimiento, jamás por su signo**. Citar el motivo: condicionarlo al signo esperado haría que un movimiento con el signo contrario se saltee la compensación entera, **no dispare `P0426`** y deje el `DELETE` proceder igual.
- [ ] 5.2 **RED**: gate SQL `supabase/tests/test_purchase_delete_cash_compensation.sql` con: compra con caja + sesión abierta → `purchase_payment_reversal` positivo por el importe opuesto y compra borrada; sesión original **cerrada** y otra abierta → el contra-movimiento va a la abierta y el arqueo cerrado no se toca; **sin** sesión abierta → `P0426`, la compra sigue existiendo, el stock **no** se revirtió y el banco tampoco; movimiento con signo invertido → se compensa igual; compra sin caja → borrado normal sin exigir sesión. Debe fallar entero.
- [ ] 5.3 **GREEN**: reescribir `rpc_delete_purchase_operation` **desde el cuerpo vivo** (`CREATE OR REPLACE`, la firma no cambia), insertando la pata de caja en la posición 2. Correr el gate → verde.
- [ ] 5.4 **TRIANGULATE (todo o nada)**: forzar un fallo en la compensación bancaria posterior y afirmar que el `purchase_payment_reversal` **tampoco** quedó, que la compra sigue existiendo y que ningún libro quedó parcial.
- [ ] 5.5 **TRIANGULATE**: afirmar que el saldo de la sesión abierta vuelve **exactamente** al valor previo a la compra, y que el movimiento original permanece en el ledger (append-only, no se borra ni se edita).
- [ ] 5.6 **REFACTOR**: verificar que el orden final de la RPC es cuenta corriente → caja → banco → stock → evento → `DELETE`, y que `P0425` (saldo negativo del proveedor) sigue evaluándose primero.

## 6. Migración — la compra con caja posteada es inmutable

- [ ] 6.1 **RED**: gate SQL que afirme que editar una compra con `cash_movement` posteado falla con `P0423`, y que una compra sin dinero posteado sigue siendo editable. Debe fallar (hoy el guard **no mira** `cash_movements` — verificado: el `pg_get_functiondef` vivo de `rpc_atomic_update_purchase_operation` no menciona la tabla).
- [ ] 6.2 **GREEN**: reescribir `rpc_atomic_update_purchase_operation` **desde el cuerpo vivo**, agregando el tercer término al `EXISTS` del guard `P0423` (`cash_movements.reference_id = p.operation_id`), con el mensaje nombrando la causa concreta.
- [ ] 6.3 **TRIANGULATE**: los dos términos preexistentes del guard (cargo de cuenta corriente y movimiento bancario) siguen bloqueando igual, y una compra imputada a efectivo **sin** opt-in sigue siendo plenamente editable.
- [ ] 6.4 Verificar que la migración completa es idempotente de punta a punta: `npx supabase db reset` limpio dos veces seguidas.

## 7. Backend Python — compras

- [ ] 7.1 **RED**: test que afirme que `PurchaseOperationIn` acepta `branch_id` y `cash_session_id`, y que `create_purchase_operation` los propaga al repositorio. Debe fallar (hoy el schema no tiene ninguno de los dos).
- [ ] 7.2 **GREEN**: agregar los dos campos a `backend/schemas/purchases.py` y el passthrough en `backend/services/purchases.py`.
- [ ] 7.3 **RED→GREEN (el bug de la sucursal, D3)**: test que afirme que `PurchaseRepository.create_operation` pasa el `branch_id` recibido como 5.º argumento de la RPC y **no `NULL` literal**. Corregir `create_operation` **y** `create_operation_with_event` — los dos tienen el mismo `NULL` hardcodeado; arreglar uno solo deja el camino con evento roto.
- [ ] 7.4 **TRIANGULATE**: caso con `branch_id = None` (sigue pasando `NULL`, sin error) y caso con `cash_session_id = None` (no-op).
- [ ] 7.5 **RED→GREEN**: `PurchaseItemOut` suma `has_cash_movement` e `is_delete_blocked`; `list_paginated_by_operation` los calcula con los dos `EXISTS` nuevos —el de `cash_movements.reference_id = p.operation_id` y el de "hay movimiento de caja **y** no hay sesión `open` en esa caja"— y suma el término de caja a `is_payment_locked`. ⚠️ Los campos **tienen que declararse en el modelo Pydantic** o se descartan al serializar (lección G10/H12 de `qa-integral-modulos`).
- [ ] 7.6 **TRIANGULATE**: una compra sin caja devuelve los dos flags en `false`; una con caja y sesión abierta devuelve `has_cash_movement=true`, `is_delete_blocked=false`; una con caja y sin sesión abierta devuelve los dos en `true`.
- [ ] 7.7 Borrar el comentario obsoleto de `purchase_repository.py` que dice *"no hay pata de caja para compras — las compras no tienen opt-in de caja, design.md Non-Goals"*: este change lo deroga y dejarlo induce al próximo lector al error.
- [ ] 7.8 Verificar que **no se agregó ningún ERRCODE** a `backend/core/errors.py` (D10): los siete que usa el change ya están mapeados.

## 8. Backend Python — cuentas corrientes

- [ ] 8.1 **RED→GREEN**: `PaymentReceivedIn` y `PaymentMadeIn` suman `cash_session_id: uuid.UUID | None = None`, con validador que rechace informar sesión junto a un método bancario **antes** de llegar a la DB (defensa en profundidad; la autoridad sigue siendo la RPC).
- [ ] 8.2 **RED→GREEN**: `customer_account_repository.register_payment_received` y su espejo de proveedor pasan el nuevo parámetro a la RPC, en posición trailing.
- [ ] 8.3 **RED→GREEN**: los dos services propagan el campo desde el payload.
- [ ] 8.4 **TRIANGULATE**: un pago sin `cash_session_id` produce exactamente la misma llamada que antes del change (contrato retrocompatible verificado por aserción sobre los argumentos del mock, no por inspección).
- [ ] 8.5 **[OQ-1]** Si se agregaron las columnas de método de pago: exponerlas en `AccountMovementOut` / `SupplierMovementOut` o en la lectura de cobros, según dónde las consuma la UI.

## 9. Frontend — piezas compartidas

- [ ] 9.1 **RED→GREEN**: `CashOptinDocument` suma `"compra"` y `"cobro"` con sus textos de motivo; `sale-form-cash-optin-baseline.test.tsx` **debe seguir verde sin cambios** (el hook no cambia de comportamiento para los consumidores existentes).
- [ ] 9.2 **TRIANGULATE**: test del hook para el documento `"compra"` (motivo de fecha nombra "una compra fechada hoy") y para `"cobro"` (el motivo de fecha **no** se usa, porque el cobro no tiene fecha — verificar que el consumidor de cobro no lo muestre).
- [ ] 9.3 Verificar que **no se creó** ningún hook, componente ni utilidad paralela: el bloque de opt-in es el mismo de `expense-form-v2.tsx`, extraído a un componente compartido **sólo si** el tercer consumidor lo justifica por duplicación real (Regla de Tres), nunca por anticipación.

## 10. Frontend — formulario de compra

- [ ] 10.1 **RED**: test de `purchase-form.tsx` que afirme que con `kind='cash'`, fecha de hoy y sesión abierta el checkbox aparece **marcado**, y que el payload lleva `cash_session_id`. Debe fallar.
- [ ] 10.2 **GREEN**: montar el bloque de opt-in con `useCashOptin({ kind: resolvedKind, branchId, date, document: "compra" })`, pre-marcado (D4), **sólo en el alta** (`!isEdit`), con el motivo visible cuando no es elegible.
- [ ] 10.3 **RED→GREEN (D3)**: `useCreatePurchase` incluye `branch_id: opMeta.branchId ?? null` en el payload del alta. Test que assertee el payload — hoy el `BranchSelect` del formulario es decorativo en el alta y el test lo congela.
- [ ] 10.4 **TRIANGULATE**: usuario desmarca → payload sin `cash_session_id`; `kind` no efectivo → bloque con el motivo "sólo un pago en efectivo…" y sin checkbox; edición → el bloque no se monta.
- [ ] 10.5 `useCreatePurchase` invalida además las query keys de **caja** (movimientos y sesión actual), con las claves que ya existen en `lib/query-keys.ts`. No bumpear el `refreshToken` de `LedgerMovementsPanel` (es estado local de `/caja` y `/banco`, que no están montados desde `/compras`).

## 11. Frontend — modales de cobro y pago

- [ ] 11.1 **RED→GREEN**: `RegisterPaymentForm.tsx` monta el bloque de opt-in cuando el método es `cash`, pre-marcado si hay sesión abierta, con el motivo visible si no la hay; el payload suma `cashSessionId`.
- [ ] 11.2 **RED→GREEN**: espejo exacto en `RegisterPaymentMadeForm.tsx`.
- [ ] 11.3 **TRIANGULATE**: con método bancario el bloque de caja **no** se muestra y el `refine` de zod que exige cuenta bancaria sigue funcionando igual; con efectivo y sin caja abierta el cobro se puede registrar igual, sin bloqueo.
- [ ] 11.4 `useRegisterPayment` y `useRegisterPaymentMade` invalidan además las query keys de caja.
- [ ] 11.5 Verificar que el `Select` de 4 métodos y la taxonomía `{cash,transfer,card,check}` **no cambian**: migrar estos modales al catálogo `payment_methods` es Non-Goal declarado.

## 12. Frontend — listado de compras y diálogo de borrado

- [ ] 12.1 **RED→GREEN**: el listado pasa `hasCashMovement` e `isDeleteBlocked` a `getDeleteCompensation(flags, "proveedor", …)`; el diálogo enumera las cuatro compensaciones y el control queda deshabilitado con motivo cuando falta la sesión abierta.
- [ ] 12.2 **RED→GREEN**: ajustar la redacción del bloqueo por caja cerrada en `delete-compensation.ts` para que sirva a compra y a gasto (hoy dice "el gasto descontó de una caja que ya está cerrada"), **sin duplicar la función**.
- [ ] 12.3 **TRIANGULATE**: compra con caja y sesión abierta → borrable y enumerada; compra con caja sin sesión → bloqueada con motivo; compra sin caja → comportamiento idéntico al de hoy.
- [ ] 12.4 **RED→GREEN**: la acción de editar aparece deshabilitada con motivo cuando `is_payment_locked` es true por caja.

## 13. Gates y verificación integral

- [ ] 13.1 Correr la suite backend completa y comparar contra el baseline de 1.4. Cero regresiones.
- [ ] 13.2 Correr `pnpm vitest run` completo y comparar contra 1.6. Cero regresiones. Justificar por escrito cada aserción que cambió.
- [ ] 13.3 Correr `pnpm tsc --noEmit` y confirmar cero errores nuevos (gotcha: `next-env.d.ts` puede quedar sucio tras un `next dev`).
- [ ] 13.4 `npx supabase db reset` limpio + los gates SQL en el orden exacto de CI, incluidos los cuatro gates nuevos de este change. Prestar atención especial a `test_function_acl_gate.sql` (chequeos 3, 4 y 5) tras el `DROP`+`CREATE` de las tres RPCs: **un `DROP FUNCTION` resetea las ACLs**, así que el re-`REVOKE`/`GRANT` tiene que estar en el mismo archivo.
- [ ] 13.5 Verificar el gate de referencias de tablas (`check_backend_table_refs` / `check_frontend_table_refs`) — lee también los comentarios SQL, así que una tabla nombrada en un comentario cuenta.
- [ ] 13.6 Verificar coverage backend ≥87% (umbral de CI) tras los archivos tocados.

## 14. Verificación visual (regla PO 2026-08-02)

- [ ] 14.1 Capturas del **formulario de compra** con el bloque de opt-in, en las 4 combinaciones (escritorio/móvil × claro/oscuro), en los dos estados (elegible con checkbox / no elegible con motivo).
- [ ] 14.2 Capturas del **modal de cobro** y del **modal de pago** en las 4 combinaciones, con efectivo y con método bancario.
- [ ] 14.3 Capturas del **historial de `/caja`** mostrando los cuatro tipos (compra en efectivo, reversa de compra, cobro, pago) con sus etiquetas, íconos y filtros de familia, en las 4 combinaciones.
- [ ] 14.4 Capturas del **diálogo de borrado de una compra** enumerando las cuatro compensaciones, y del listado con el control deshabilitado por caja cerrada.
- [ ] 14.5 Medir el contraste de los tonos usados (objetivo ≥4,5:1) y confirmar que `token-contrast-aa.test.ts` pasa.
- [ ] 14.6 Revisión de accesibilidad de los controles nuevos: el checkbox tiene etiqueta asociada, el motivo es texto y no sólo color, y el foco es visible.

## 15. Verificación en producción post-merge (obligatoria)

- [ ] 15.1 `SELECT max(version), count(*) FROM supabase_migrations.schema_migrations` → debe dar `20261018000001` y 267.
- [ ] 15.2 Verificar que existe **exactamente una** definición viva de cada una de las cuatro RPCs, con la firma nueva.
- [ ] 15.3 Verificar las ACLs de las cuatro funciones: sin `EXECUTE` para `PUBLIC` ni `anon`; `authenticated` con el otorgamiento explícito esperado.
- [ ] 15.4 Verificar que el cuerpo vivo de `rpc_create_purchase_operation`, `rpc_register_payment_received`, `rpc_register_payment_made` y `rpc_delete_purchase_operation` contiene `c28_register_cash_movement`.
- [ ] 15.5 Verificar el CHECK vivo de `cash_movements.movement_type` (11 tipos) y re-contar las filas por tipo: las 71 preexistentes intactas.
- [ ] 15.6 🛑 **Humo real con el PO en producción**: una compra en efectivo con opt-in, un cobro de cuenta corriente en efectivo, un pago a proveedor en efectivo, y el borrado de esa compra. Ver los cuatro movimientos en `/caja` con sus etiquetas correctas y el arqueo cuadrando.
- [ ] 15.7 Verificar que una compra registrada después del deploy tiene `branch_id` no nulo y aparece en el reporte por sucursal.
- [ ] 15.8 Auditoría de daño histórico: confirmar que **no** se creó ningún movimiento de caja retroactivo (D11) y que las 507 compras históricas siguen con `branch_id` nulo, no atribuidas a una sucursal inventada.

## 16. Documentación y cierre

- [ ] 16.1 Actualizar `CHANGES.md` con la entrada del change: decisiones, OQs y cómo se resolvieron, hallazgos, y los candidatos que deja abiertos.
- [ ] 16.2 Actualizar el puntero de "próximo change" en `CLAUDE.md` y correr `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** (gate `Docs Sync`).
- [ ] 16.3 Dar de alta el candidato **`cobranzas-reverso`** (OQ-4): hoy un cobro mal cargado no se puede deshacer por ningún camino, y este change le agrega una consecuencia más.
- [ ] 16.4 Dar de alta el candidato **`cobranzas-catalogo-pagos`** (Non-Goal 3): unificar los modales de cobro/pago al catálogo `payment_methods`, espejo de `pos-catalogo-pagos`.
- [ ] 16.5 Guardar en engram (`topic_key: opsx/caja-compras-cobranzas/apply`) las lecciones verificadas y los hallazgos, en particular el de la sucursal perdida en el alta de compra.
- [ ] 16.6 `/opsx:archive caja-compras-cobranzas` — sincronizar specs y archivar. ⚠️ Verificar que los requirements quedaron en **HEAD** y no sólo en el árbol de trabajo (gotcha registrado de `openspec archive`).
