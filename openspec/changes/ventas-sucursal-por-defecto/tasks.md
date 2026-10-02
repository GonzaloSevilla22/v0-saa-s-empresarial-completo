> **Governance MEDIA con tramo ALTO.** Se reescriben las tres funciones que mueven stock, caja y banco en el alta y la edición de ventas, y una migración de datos actualiza en masa `sales.branch_id` (y, si el PO acepta la excepción a RN-21, `stock_movements.branch_id`) en producción.
>
> **Un solo PR**: funciones, datos, frontend, gates y specs. Lo **mergea el PO**, porque lleva una migración de datos.
>
> **TDD estricto**: cada grupo de producción abre con su RED (un test o gate que falla por la razón correcta) y deja evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR, nunca a `main`. Conventional commits en español.
> - Toda RPC se reescribe desde su `pg_get_functiondef` **vivo de producción**, con la misma firma (`CREATE OR REPLACE`, sin `DROP`), conservando el `COMMENT` y re-emitiendo las ACLs.
> - Nada contra producción salvo lo que ejecuta o autoriza el PO (grupos 0 y 12). Nunca el MCP `apply_migration`: las migraciones van por el `supabase db push` del pipeline.
> - **El grupo 3 (migración de datos) no se escribe sin el OK textual del PO sobre OQ-4, OQ-5 y OQ-6** (tarea 0.1).

## 0. Sign-off y checkpoints previos (sólo lectura)

- [ ] 0.1 **[PO]** Sign-off de las OQ (`design.md` §Open Questions). Registrar la respuesta textual en una sección "Sign-off del PO" del `design.md`.
  - **OQ-1, OQ-2, OQ-3 y OQ-7**: sin respuesta, el apply adopta la recomendación de cada una, (a) en las cuatro.
  - **OQ-4, OQ-5 y OQ-6 bloquean el grupo 3**: el apply no escribe `20261069000002` sin el OK textual del PO sobre las reglas de D6, la excepción a RN-21 y la precedencia movimiento/orden. Los grupos 1, 2 y 4 a 9 pueden avanzar mientras tanto.
  - Si el PO elige (b) en OQ-5: se retiran del change el delta de `inventory-single-ledger`, la pata de `stock_movements` del backfill (3.2), la mutación M5 (3.4), la nota de RN-21 (10.2) y la verificación 12.4 de movimientos nulos, y se ajusta el requirement de históricos del delta de `branches`.
  - Si el PO elige otra opción en cualquier OQ, actualizar en el mismo PR la decisión, las specs y estas tareas.
- [ ] 0.2 **[PO ejecuta o autoriza]** Checkpoint del cuerpo **vivo de producción**, antes de escribir una línea de SQL:
  - `pg_get_functiondef`, `obj_description` y `proacl` de:
    - `rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)`;
    - `rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)`;
    - `rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)`.
  - Sólo para leer: `c26_default_branch(uuid)`, `op_stock_movement`, `rpc_reverse_stock_movement`, `rpc_promote_legacy_sale_to_order(uuid)` y `_sales_order_sync_from_operation(uuid, uuid, uuid)`.
  - Comparar por líneas, sin `\r` (gotcha CRLF), contra el local y contra `20261062000001_ventas_unidades_conversion.sql`. Rangos de las funciones en ese archivo: v2 L330-697, edición L1594-2260, wrapper L2629-2957 (desde L2959 sigue DDL ajeno a la función). Mejor: extraer los dos lados con `pg_get_functiondef` en vez de cortar el archivo por líneas.
  - Referencia local (base local con las 313 migraciones de `main`). La medida del preflight es `md5(replace(prosrc, E'\r', ''))`, la misma que usa `20261062000001`; el `md5` del `pg_get_functiondef` sin `\r` queda como dato secundario:

    | Función | `md5(prosrc)` (= `v_rewritten` de `20261062000001`, L142-146) | `md5(pg_get_functiondef)` |
    |---|---|---|
    | v2 | `23f9f29a90d33aecf6b5add389488f68` | `6bbf5833592896ce493d3b933dd62b4e` |
    | wrapper | `577f86d234937234e6797e71120e349e` | `92a2a3452c07dbbee3a99114f55ed469` |
    | edición | `e8687db5ecdcc6056325550f37c8cbc0` | `954a5c8fb31202259c82485d0c6e05b9` |
    | `c26_default_branch` | `4fb12c57c3417bb98212cddd2e5ac069` | `5fa1096b4c1481b36d6e04c8eaadbfdc` |

  - El `md5(prosrc)` vivo de producción de las tres funciones es el `v_expected` del preflight de `20261069000001` (2.1).
  - `COMMENT` esperado: la edición tiene uno; la v2 y el wrapper, ninguno.
  - ACL esperada: `postgres`, `authenticated` y `service_role` con `EXECUTE`, y `anon` sin `EXECUTE`.
  - Si algo diverge, se reescribe sobre el **vivo** y se anota acá el desvío.
- [ ] 0.3 Confirmar que `20261069000001` y `20261069000002` siguen libres: `ls supabase/migrations`, `gh pr list --state open` y `MAX(version)` de producción (lo lee el PO). `presupuestos-modulo` reserva `20261067000001`/`20261068000001` (la base local compartida ya tiene `20261067000001`, aplicada por su apply en curso). Si ya mergeó, nuestras dos van después en CI. Renumerar si hace falta.
- [ ] 0.4 Re-verificar sobre `main` actualizado el inventario de escritores de `sales`: las funciones vivas con `INSERT INTO public.sales` (v2, wrapper, edición, `_c29_confirm_order_core` y los dos `rpc_atomic_create_sale` legacy, sólo `service_role`) y los `UPDATE` (`rpc_safe_delete_product`). Grep de escrituras directas en `backend/`, `frontend/` y `supabase/functions/`. Anotar cualquier escritor nuevo que no esté en el design.
- [ ] 0.5 SAFETY NET. Correr y registrar el baseline:
  - **Backend**: `backend/tests/test_sales.py`, `test_sales_branch_id.py`, `test_sale_items.py`.
  - **Frontend**: `__tests__` de `sale-form*`, `use-sales*`, `use-cash-optin*`, `use-purchases-cash-optin*`, `use-party-payment-cash-optin*`, `use-default-branch-notice*`, `branches*`, `operation-errors*`, `pos-*` (incluido `pos-operation-errors`), `purchase-form*` (incluido `purchase-form-cash-optin`), `expense-form*`, `expense-import-dialog*` y `RegisterPaymentForms*` (incluido `RegisterPaymentForms-cash-optin`).
  - **Gates SQL**: `test_ventas_formulario_sucursal.sql` y los 23 de `supabase/tests/` que nombran `rpc_create_sale_operation`, `rpc_create_sale_operation_v2` o `rpc_atomic_update_sale_operation`. En particular:
    - `test_confirm_core_integrity.sql`, `test_cuenta_corriente_party_guard.sql`, `test_operacion_party_guard.sql`;
    - `test_pos_rpc_signatures.sql`, `test_cobranzas_vencimientos_schema.sql`;
    - `test_ventas_unidades_conversion.sql` y `test_ventas_unidades_conversion_race.sh`, `test_edicion_preserva_contexto.sql`, `test_facturar_venta_manual.sql`, `test_stock_movements_edicion.sql`, `test_operation_edit_lines.sql`;
    - `test_function_acl_gate.sql`.

  Una falla previa se reporta como preexistente y no se corrige acá.

## 1. RED — gate SQL de las funciones (antes de tocarlas)

- [ ] 1.1 Escribir `supabase/tests/test_ventas_sucursal_por_defecto.sql` con los bloques (0)-(6) (incluido (3b)), (8) y (9) de `design.md` D13. El bloque (7), del backfill, va en el grupo 3. Patrón del proyecto:
  - fallos acumulados en `text[]` y un solo `RAISE` al final;
  - anchors sintéticos vía `handle_new_user`;
  - `created_at` explícito y estrictamente posterior en las sucursales sintéticas, asertado (`c26_default_branch` no desempata);
  - limpieza de toda fila con el `account_id` de los anchors **y** de las dependencias sin `account_id` (las `cashboxes` de sus sucursales).
- [ ] 1.2 Fixtures:
  - cuenta con A (principal) y B, productos con stock en las dos y producto de servicio (línea sin `product_id`);
  - flag `sale_items_rpc_v2 = false` para la cuenta del bloque (2);
  - A cerrada (`status = 'closed'`, `is_active` intacto) para el bloque (3);
  - para el bloque (3b), cuenta con una sucursal desactivada (`is_active = false`) y otra cerrada, ambas vacías: sin `session_replication_role`;
  - para el bloque (4), cuenta sin ninguna sucursal. Bajo `session_replication_role = replica` (para esquivar `trg_guard_branch_decommission`) no corren las acciones de FK, así que antes del `DELETE` de la sucursal se borran explícitamente sus `cashboxes` (que `handle_new_user` siembra y que no tienen `account_id`) y su `branch_stock`. Al final, asertar residuo cero de cajas y de stock de esas sucursales;
  - fila residual con `branch_id NULL`, insertada directo, para la edición sin informar del bloque (5);
  - forma de pago bancaria con cuenta destino para el bloque (6).
- [ ] 1.3 Correr el gate contra los cuerpos **actuales** y registrar el RED. Esperado:
  - (0) falla porque los `INSERT` persisten `p_branch_id` y el md5 no es el reescrito;
  - (1), (2), (3) y (6) fallan con `branch_id NULL`;
  - (3b) falla porque la venta de servicio pasa con `NULL` y la de producto descuenta de la sucursal no operativa (o da `P0409`) en vez de `P0422 no_branch_found`;
  - (4) falla porque la venta de servicio pasa con `NULL` y la de producto da `P0409` en vez de `P0422 no_branch_found`;
  - (5) falla con la fila resultante en `NULL`.
- [ ] 1.4 Actualizar **a propósito** `supabase/tests/test_ventas_formulario_sucursal.sql`:
  - el bloque 2 pasa a «sin sucursal elegida: `sales.branch_id` y `stock_movements.branch_id` = principal, stock de la principal»;
  - el bloque 6c pasa a «venta, movimiento de stock y movimiento bancario en la **misma** principal»;
  - el encabezado cita `ventas-sucursal-por-defecto` en lugar de "decisión del PO pendiente".

  Correr contra los cuerpos actuales y registrar el RED.

## 2. GREEN — `supabase/migrations/20261069000001_ventas_sucursal_por_defecto.sql` (funciones)

- [ ] 2.1 Escribir la migración partiendo de los cuerpos vivos de 0.2:
  - **Preflight** (bloque `DO` al principio, molde de `20261062000001` L107-170): `v_expected` con los `md5(replace(prosrc, E'\r', ''))` de partida confirmados en 0.2; `v_rewritten` con los que deja esta migración, medidos en el stack local después de aplicarla. Si el cuerpo vivo no es ninguno de los dos, `RAISE EXCEPTION` sin reescribir. Si ya es el reescrito, `NOTICE 'ventas-sucursal-por-defecto: % ya es el cuerpo de esta migración (reaplicación)'`.
  - Con **sólo** los cambios de `design.md` D2:
    - **v2**: `v_gate_branch` en los tres `INSERT` (sales con producto, sales de servicio, `stock_movements`) y el guard `P0422 no_branch_found` (sin sucursal elegida y principal `NULL` o no operativa), después de resolver `v_gate_branch` y antes del `INSERT` en `operation_idempotency`.
    - **Rama legacy del wrapper**: los mismos tres cambios y el mismo guard. La rama de delegación no se toca.
    - **Edición**: si `v_final_branch_id` quedó `NULL`, la principal y el mismo guard, después del tri-estado y **antes** del REVERSE.

  Cabecera de la migración con contexto, decisión del PO, reglas y referencias. Un comentario `-- ventas-sucursal-por-defecto (Dn):` en cada punto tocado.
- [ ] 2.2 Re-declarar el `COMMENT` vivo de la edición (sin `COMMENT` nuevo en v2 ni wrapper si el vivo no lo tiene) y re-emitir las ACLs: `REVOKE ALL … FROM PUBLIC, anon` más `GRANT EXECUTE … TO authenticated, service_role`, idénticas a las vivas.
- [ ] 2.3 Diff del cuerpo nuevo contra el vivo, por función y sin `\r`. Tiene que ser **exactamente** los cambios de D2 más los comentarios. Adjuntar el diff como evidencia en el PR.
- [ ] 2.4 Aplicar en la base local y correr el gate. Tienen que quedar GREEN:
  - bloques (0)-(6), (3b), (8) y (9) de `test_ventas_sucursal_por_defecto.sql`;
  - `test_ventas_formulario_sucursal.sql` completo.
- [ ] 2.5 Mutaciones sobre los cuerpos locales, dentro de una transacción con `ROLLBACK`. Cada una tiene que ser detectada por el gate con un mensaje propio:
  - M1: v2 con `p_branch_id` crudo en `sales`;
  - M2: la rama legacy con `p_branch_id` crudo;
  - M3: v2 con `p_branch_id` crudo en `stock_movements`;
  - M4: edición sin la resolución de la principal;
  - M9: guard que sólo mira `NULL` y deja pasar una principal no operativa.

  Registrar los mensajes.
- [ ] 2.6 Idempotencia: reaplicar el archivo dos veces sobre la base local. La segunda pasada tiene que tomar la rama de reaplicación del preflight (3 `NOTICE`) y el fingerprint de esquema no cambia (el mismo `schema_snapshot` del paso "Verify … idempotent on reapply" de `KPI_Validation.yml`).
- [ ] 2.7 Correr todos los gates de 0.5. En particular, `test_confirm_core_integrity.sql` (3) por las subcadenas de la v2, `test_cuenta_corriente_party_guard.sql` (3.8-v2) y `test_operacion_party_guard.sql` por el guard de cliente, `test_pos_rpc_signatures.sql` (1d) por una sola firma, y `test_function_acl_gate.sql`. Todos verdes.

## 3. Backfill — `supabase/migrations/20261069000002_ventas_sucursal_por_defecto_backfill.sql` (datos)

> **Bloqueado hasta el OK textual del PO sobre OQ-4, OQ-5 y OQ-6** (0.1).

- [ ] 3.1 RED: agregar el bloque (7) al gate, con fixtures para cada caso de D6:
  - mono-sucursal;
  - multi-sucursal;
  - operación mixta (una fila en B, otra `NULL`), con una línea de servicio sin movimiento;
  - venta `NULL` con su movimiento `'sale'` en X operativa ≠ principal A;
  - venta `NULL` con su movimiento `'sale'` en X **cerrada** (debe quedar en la principal y contarse como discrepancia);
  - venta con `sales_orders` en B aunque la principal sea A, sin movimiento con sucursal;
  - venta con `sales_orders` en una sucursal **cerrada** (debe saltearse la regla);
  - cuenta con todas sus sucursales desactivadas o cerradas (residuo);
  - fila con `account_id NULL` (residuo);
  - venta borrada cuyo movimiento original y cuya reversa quedaron `NULL`;
  - movimientos `'sale'` `NULL` de las ventas vivas.

  Registrar los conteos de `events`, `notifications`, `analytics_events`, `cash_movements`, `bank_movements`, `customer_account_movements` y `journal_entries` antes de la corrida. Ejecutar el archivo de datos con `\i` (todavía inexistente o vacío) y registrar el RED.
- [ ] 3.2 GREEN: escribir la migración de datos (sin DDL, sin funciones, sin ACLs). Cabecera con:
  - la decisión textual del PO y su sign-off de OQ-4, OQ-5 y OQ-6;
  - las reglas de D6;
  - por qué no hace falta medir antes (D6, D7);
  - la excepción a RN-21 y sus límites (si OQ-5 = (a));
  - la idempotencia y la regla de que nunca aborta por datos.

  En un bloque `DO`:
  - tomar las candidatas (`branch_id IS NULL AND account_id IS NOT NULL`) con `FOR UPDATE` en **orden ascendente de `id`**, para respetar el orden global de locks del proyecto;
  - resolver la sucursal **por operación** (`COALESCE(operation_id, id)`), con la primera regla que dé una sucursal **operativa**: operación mixta → movimiento de stock propio → orden → principal vigente. Contar las reglas salteadas por sucursal no operativa;
  - `UPDATE sales`;
  - si OQ-5 = (a): `UPDATE stock_movements SET branch_id = …` **sólo** de los movimientos `type = 'sale'`, `reference_type = 'sale'`, `branch_id IS NULL`, de las ventas asignadas en esta corrida. Ninguna otra columna;
  - una fila de `audit_logs` por cuenta afectada (`action = 'sales_branch_backfill'`, `entity_type = 'account'`, `user_id NULL`, `metadata` con `sale_ids`, `movement_ids`, conteo por regla, `salteadas_no_operativa`, `discrepancia_movimiento`, `branch_ids` y `evidencia_otra_sucursal`), sólo si la cuenta tuvo filas asignadas;
  - `NOTICE` con:
    - los conteos por regla y las reglas salteadas;
    - los movimientos actualizados;
    - el residuo (sin cuenta, cuenta sin sucursal, cuenta sin sucursal operativa);
    - las ventas asignadas cuyo movimiento `'sale'` ya registraba **otra** sucursal (`discrepancia_movimiento`);
    - las ventas asignadas cuyo movimiento de caja (`cash_movements.reference_id` = operación → `cash_sessions` → `cashboxes.branch_id`) o de banco (`bank_movements.source_doc_type = 'sale'`, `source_doc_ref` = operación) registró **otra** sucursal (OQ-4).
- [ ] 3.3 Correr el bloque (7) ejecutando el archivo **dos veces**. Verificar:
  - cada caso de D6;
  - la segunda corrida no cambia filas ni escribe auditoría;
  - los conteos de efectos laterales quedan iguales.

  Después correr los bloques (8) (`rpc_promote_legacy_sale_to_order` **ejecutada** sobre la operación antes mixta) y (9) (`rpc_delete_sale_operation` **ejecutada** repone en la sucursal asignada, también en la venta asignada por la regla del movimiento).
- [ ] 3.4 Mutaciones, con `ROLLBACK`, detectadas por el gate:
  - M5: el backfill sin la pata de `stock_movements` (si OQ-5 = (a));
  - M6: el backfill sin la regla de la orden;
  - M7: el backfill sin la regla del movimiento;
  - M8: el backfill sin el filtro de sucursal operativa.
- [ ] 3.5 Medir en la base local el tiempo del backfill sobre un volumen sintético (por ejemplo, 50.000 filas `NULL` en varias cuentas) para acotar la ventana de locks por fila. Anotar el resultado en el PR. No hace falta medir producción (D7).

## 4. CI

- [ ] 4.1 `.github/workflows/KPI_Validation.yml`:
  - **retirar el bloque de reaplicación de `20261062000001`** (L982-1041), citando en el commit la regla del propio workflow (L1004-1018): este change redefine tres de sus diez funciones y ese preflight abortaría;
  - actualizar el comentario del bloque de `20261066000001`, que justifica su posición «después del bloque de 20261062000001» (su aserción de `scale_plu` sigue valiendo);
  - agregar la reaplicación de `20261069000001` y de `20261069000002` **después de la reconvergencia**, al final de los reapply posteriores (después de `20261066000001` y, si ya mergearon, de `20261067000001`/`20261068000001`), sin tolerancia: el de funciones exige 3 `NOTICE` «ya es el cuerpo de esta migración» (conteo como `UOM_REAPPLIED`), el de datos su `NOTICE` final con 0 filas asignadas, y los dos un `schema_snapshot` idéntico.
- [ ] 4.2 Cablear `supabase/tests/test_ventas_sucursal_por_defecto.sql` como paso propio. `test_ventas_formulario_sucursal.sql` mantiene su paso.
- [ ] 4.3 Antes del PR, correr en local el paso completo de CI: `supabase db reset`, la cadena de reaplicación, la reconvergencia y los reapply posteriores. Después, en la corrida de CI, confirmar que:
  - el bloque (0) del gate nuevo pasa **después** de los reapply (ninguna reaplicación puede dejar vivo un cuerpo viejo, lección de `candidatos-db-backend`);
  - `test_ventas_unidades_conversion.sql` y `test_ventas_unidades_conversion_race.sh` siguen verdes: cubren las otras siete funciones que dejó de reaplicar el bloque retirado.

## 5. Frontend — una sola "principal" en el cliente

- [ ] 5.1 RED/GREEN de `frontend/lib/default-branch.ts`, `resolveDefaultBranch(branches: Branch[]): Branch | null`, con `__tests__/lib/default-branch.test.ts`. Casos:
  - lista vacía → `null`;
  - la primera con `status === "active"`;
  - la más antigua cerrada se saltea;
  - todas cerradas → la primera;
  - respeta el orden de entrada (el de `useBranches`, `created_at` ascendente).
- [ ] 5.2 `hooks/use-cash-optin.ts`: `effectiveBranchId = branchId || resolveDefaultBranch(branches)?.id || null`. RED primero: con la más antigua cerrada, la sucursal efectiva tiene que ser la segunda. Regresión de sus cinco consumidores:
  - venta y gasto: los tests existentes siguen verdes;
  - compra: `__tests__/components/purchase-form-cash-optin.test.tsx` sigue verde. Su caso de `BranchSelect` mockeado a `null` fija un payload que el servidor rechaza (preexistente, OQ-3): no se corrige acá, se anota en el PR;
  - cobro y pago de cuenta corriente: caso nuevo en `__tests__/components/RegisterPaymentForms-cash-optin.test.tsx`: con la más antigua cerrada, el modal de cobro ofrece la sesión de la principal operativa.
- [ ] 5.3 `hooks/use-default-branch-notice.ts`: `resolveDefaultBranch(branches)` en lugar de `branches[0]`. RED primero: con la más antigua cerrada, no se anuncia como principal.
- [ ] 5.4 POS (`app/(dashboard)/ventas/pos/page.tsx:166`): `activeBranch = resolveDefaultBranch(branches)`. RED primero, en el test del POS que corresponda (por ejemplo `__tests__/pos-payment-methods.test.tsx`, o uno nuevo `pos-default-branch.test.tsx`): con la más antigua cerrada, el POS usa B para la caja y la sesión y manda `branch_id = B` en el payload. Los `pos-*` existentes siguen verdes.
- [ ] 5.5 Grep de `branches[0]` en `frontend/` usado como "sucursal por defecto" que haya quedado fuera de 5.2-5.4. Migrar al helper o justificar cada uno en el PR (`caja/page.tsx:50` sólo lo usa con una única sucursal; `e2e/fixtures/fiscal-e2e.ts:105` es un fixture).

## 6. Frontend — selector de la venta

- [ ] 6.1 RED/GREEN de `components/branches/BranchSelect.tsx`, con props nuevas cuyos valores por defecto no cambian nada:
  - `allowUnassigned?: boolean` (por defecto `true`): con `true`, opciones y comportamiento idénticos a hoy (test de regresión con la opción "Sin sucursal (general)"); con `false`, sin la opción `__none__`, valor mostrado `value ?? resolveDefaultBranch(branches)?.id`, la principal rotulada "Nombre (principal)" y `onChange` emite el id elegido;
  - `label?: string`: se renderiza **dentro** del componente, con `useId`, `<Label htmlFor>` e `id` en el `SelectTrigger` (patrón de `PaymentMethodSelect.tsx:95-108`);
  - con `allowUnassigned={false}`, placeholder «Cargando sucursales…» mientras `useBranches` carga.

  Tests nuevos:
  - (a) sin módulo de sucursales no se renderiza ni el rótulo ni el control;
  - (b) mientras cargan las sucursales, el disparador no dice «Sin sucursal»;
  - (c) `getByLabelText('Sucursal')` encuentra el combobox;
  - (d) con el componente real (sin mock), re-elegir la principal que ya se muestra no emite `onChange`.
- [ ] 6.2 RED/GREEN de `components/forms/sale-form.tsx`:
  - `BranchSelect` con `allowUnassigned={false}` y `label="Sucursal"`; se retira el `placeholder="Sin sucursal (general)"` (L944);
  - **alta** sin tocar el selector: el payload lleva `branch_id: null` y el selector muestra la principal;
  - **alta** eligiendo B: viaja el id de B;
  - **edición** precarga la sucursal de la venta;
  - **edición** de una venta con `branchId` nulo: muestra la principal.

  Actualizar `frontend/__tests__/components/sale-form-branch-create.test.tsx`: el caso «elegir y volver a "Sin sucursal"» desaparece y lo reemplaza «elegir B y después volver a la principal manda el id de la principal». Ese test mockea `BranchSelect` con botones que llaman a `onChange` directo, así que el comportamiento real de Radix lo cubre 6.1 (d). Validar por mutación que los casos fallan sin el cambio.
- [ ] 6.3 RED/GREEN de `lib/operation-errors.ts`: traducir `no_branch_found`. Hoy lo traducen cuatro lugares con textos distintos (Context). Reutilizar el texto de `hooks/data/use-promote-to-order.ts:50`, que ya manda a configurar una sucursal, ajustado sólo para nombrar la salida real (crear o reabrir una sucursal desde Sucursales); no crear un quinto texto. **RED documentado**: `__tests__/lib/operation-errors-branch.test.ts:44-49` hoy fija que `no_branch_found` pasa tal cual, y se modifica a propósito. No romper los casos `branch_closed`, `branch_not_found`, `branch_invalid` ni el stock insuficiente con su acción de transferir. El `friendlyError` del POS no se toca, y unificar los otros textos queda como candidato.
- [ ] 6.4 Actualizar los comentarios y la prosa de tests del frontend que afirman que una venta sin sucursal queda `NULL` o que `null` significa "Sin sucursal (general)". Pasan a decir «sin sucursal elegida, viaja `null` y la RPC la registra en la principal», sin cambiar ninguna aserción:
  - `hooks/data/use-sales.ts` (cerca de L236-240);
  - `__tests__/hooks/use-sales-branch.test.ts:89`;
  - `__tests__/hooks/use-sales.test.ts:161`;
  - cualquier otro que aparezca en el grep.
- [ ] 6.5 Regresión de compra, gasto e importador de gastos: sus tests verdes y su opción sin sucursal presente con su texto actual (compra y gasto: "Sin sucursal (general)"; importador de gastos: "Sin sucursal por defecto", `expense-import-dialog.tsx:691`).
- [ ] 6.6 `pnpm vitest run` de los archivos afectados y vecinos, y `tsc --noEmit` sin errores nuevos respecto del baseline.
- [ ] 6.7 Coordinación con `presupuestos-modulo`. Si mergeó antes que este change: pasar su `ConvertQuoteDialog` (que registra una venta) a `allowUnassigned={false}` con `label="Sucursal"`, con su test, y resolver el conflicto en `sale-form.tsx` (aquél migra el carrito a `lib/cart-utils.ts`). Si no mergeó: dejar la indicación en la descripción del PR y en el engram de los dos changes, para que lo haga quien aplique segundo. `QuoteForm` conserva el valor por defecto.

## 7. Backend (sin cambio de lógica)

- [ ] 7.1 Corregir los comentarios y la prosa que afirman que `None` conserva `branch_id` NULL, sin cambiar ninguna aserción:
  - `backend/services/sales.py` cerca de L147 y `backend/schemas/sales.py` cerca de L50-56;
  - los docstrings de `backend/tests/test_sales_branch_id.py:75-77` y `:212`.

  Agregar a `SaleOperationIn.branch_id` y `SaleOperationUpdateIn.branch_id` la descripción de OpenAPI: «sin sucursal, la venta se registra en la sucursal principal de la cuenta».
- [ ] 7.2 Confirmar con los tests existentes (`test_sales_branch_id.py`) que el alta y la edición transportan `None` y el tri-estado (`p_branch_provided`) sin cambios. No se agregan tests de comportamiento, porque no lo hay: la resolución es de la RPC y la cubre el gate.
- [ ] 7.3 Correr la suite completa con el comando de CI (`pytest backend/tests -m "not integration" --cov=backend`). Cobertura ≥ 87 %.

## 8. Verificación visual (superficie frontend)

- [ ] 8.1 Formulario de venta en alta y edición. Cuenta con módulo y dos sucursales, y cuenta sin módulo. Combinaciones:
  - escritorio (1280 px) y móvil (375 px);
  - tema claro y tema oscuro.

  Verificar:
  - rótulo "Sucursal", principal preseleccionada y marca "(principal)" con contraste AA (tokens semánticos, sin colores literales);
  - lista sin "Sin sucursal (general)";
  - en la cuenta sin módulo, ni selector ni rótulo;
  - sin desborde horizontal a 375 px.

  Adjuntar capturas.
- [ ] 8.2 Formularios de compra y de gasto, e importador de gastos, en las mismas combinaciones: la opción sin sucursal sigue igual.

## 9. Humo en el stack local

- [ ] 9.1 Levantar el stack local: Supabase con las migraciones de la rama, `uvicorn` desde el worktree y `pnpm dev`. Usar una cuenta Pro con A (principal) y B y una cuenta sin módulo de sucursales, y verificar cada caso con `psql`.
  - **H1**: venta sin tocar el selector → `sales` y `stock_movements` en A, stock de A. Anotar el aviso «Stock insuficiente (disponible: N)» con un producto que sólo tiene stock en B: muestra el agregado (candidato (c) de #606, Non-Goal).
  - **H2**: eligiendo B → B.
  - **H3**: cuenta sin módulo → su "Casa Central". Si se puede armar, una cuenta sin módulo que conserva dos sucursales → la más antigua operativa.
  - **H4**: `PUT /sales/{id}` con `branch_id: null` → A.
  - **H5**: `POST /sales` sin el campo → A.
  - **H6**: ventas `NULL` creadas con el código de `main`, una de ellas editada (movimiento con sucursal), y después la migración de datos → asignadas según D6, con fila en `audit_logs`.
  - **H7**: Tablero filtrado por A suma las ventas de H1 y H6.
  - **H8**: cerrar la sucursal más antigua (sin stock) → el selector de la venta preselecciona la siguiente, el opt-in de caja de la venta y el modal de cobro de cuenta corriente buscan su sesión, el aviso de sucursal por defecto la nombra, el POS usa su caja y la manda como sucursal, y una venta sin tocar el selector queda en ella.
  - **H9**: desactivar todas las sucursales de una cuenta de prueba vacía → una venta sin sucursal se rechaza con el mensaje traducido de `no_branch_found`.

## 10. Specs, KB y documentación

- [ ] 10.1 Correr `openspec validate "ventas-sucursal-por-defecto" --strict` y `openspec validate --specs --strict`.
- [ ] 10.2 `knowledge-base/05_reglas_de_negocio.md`:
  - RN-93: nota de que la venta la cumple desde este change (alta, edición e históricos) y de que compras queda pendiente (OQ-3);
  - RN-21 (si OQ-5 = (a)): nota de la única excepción auditada, con sus límites y el puntero al requirement nuevo de `inventory-single-ledger`.
- [ ] 10.3 Al archivar (no en el apply):
  - **`CHANGES.md`**: ficha con la verificación posterior y los candidatos que deja:
    - `NOT NULL` en `sales.branch_id` con retiro de los `rpc_atomic_create_sale` muertos y FK `RESTRICT` (D8);
    - `compras-gastos-sucursal-por-defecto`, con el opt-in de caja de la compra sin sucursal (OQ-3);
    - sucursal principal configurable (OQ-1);
    - disparador de defensa en profundidad (D1, alternativa A);
    - gate de stock de la edición contra la sucursal efectiva (candidato (d) de #606);
    - stock de la sucursal efectiva en el formulario (candidato (c) de #606);
    - guard de última sucursal operativa en `rpc_deactivate_branch` (D3);
    - unificar las traducciones de `no_branch_found` (6.3).
  - **`CLAUDE.md`**: puntero y `python scripts/ci/check_docs_sync.py --fix` para `AGENTS.md`.
  - Diffear cada spec sincronizada contra su versión previa (`branches`, `branch-stock`, `operation-edit-context`, `inventory-single-ledger`, `dashboard-kpi-summary`, `sales-statistics`): si otro change archivó antes un delta sobre el mismo requirement, el segundo archive lo pisa sin que el conteo lo delate.

## 11. PR y merge

- [ ] 11.1 PR con commits convencionales y CI verde: `validate-kpis` con el gate nuevo, el bloque retirado y los reapply nuevos, Backend, Frontend, E2E y Docs Sync.
- [ ] 11.2 Revisión adversarial con un solo juez por ronda (tope de agentes del workflow) sobre: el diff de funciones contra el vivo, el preflight, el orden de locks del backfill, la resolución por operación y el filtro de operativa, la idempotencia, la paridad v2/legacy y la superficie frontend.
- [ ] 11.3 **[PO]** Merge. Los sub-agentes no mergean migraciones de datos.

## 12. Verificación posterior al merge (producción, sólo lectura; la ejecuta o autoriza el PO)

- [ ] 12.1 `deploy.yml` verde, con `MAX(version)` igual a `20261069000002` (o la última de la cadena). Vercel desplegado. Render: `GET /deploys` del commit del merge, y `POST /deploys` si falta (el auto-deploy no siempre dispara).
- [ ] 12.2 En los cuerpos vivos de las tres funciones, la persistencia resuelta y el guard están presentes, y su `md5(prosrc)` es el `v_rewritten` del preflight. La edición conserva su `COMMENT`. Las ACLs no cambiaron y hay una sola firma por función.
- [ ] 12.3 `SELECT count(*) FROM sales WHERE branch_id IS NULL` tiene que coincidir con el residuo que informó la migración. Además, las filas `NULL` con `created_at` posterior al deploy tienen que ser 0. Si hay alguna (ventana de ventas en vuelo), **[PO]** re-ejecutar el bloque idempotente del archivo de datos con `npx supabase db query --linked`.
- [ ] 12.4 Movimientos de stock:
  - si OQ-5 = (a), cero movimientos `reference_type = 'sale'` con `branch_id NULL` cuya venta exista;
  - discrepancias: ventas asignadas cuyo movimiento `'sale'` tiene otra sucursal (`sales.branch_id IS DISTINCT FROM stock_movements.branch_id`, uniendo por `reference_id = sales.id`). El número tiene que coincidir con `discrepancia_movimiento` de la auditoría.
- [ ] 12.5 Filas `audit_logs` con `action = 'sales_branch_backfill'`: cantidad de cuentas, total de ventas y movimientos asignados, reglas salteadas, discrepancias y el conteo de evidencia de otra sucursal (OQ-4). Informarlo al PO.
- [ ] 12.6 **[PO]** Humo real:
  - en una cuenta con dos sucursales, una venta sin tocar el selector queda en la principal;
  - el Tablero filtrado por la principal incluye las ventas históricas;
  - en una cuenta sin módulo, la venta queda en su "Casa Central".

## Evidencia TDD

| Tarea | Test / gate | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|-------------|------|------------|-----|-------|---------------|----------|
| 1.x/2.x | `supabase/tests/test_ventas_sucursal_por_defecto.sql` (0)-(6), (3b), (8), (9) | SQL | | | | | |
| 1.4 | `supabase/tests/test_ventas_formulario_sucursal.sql` bloques 2 y 6 | SQL | | | | | |
| 3.x | `test_ventas_sucursal_por_defecto.sql` (7) | SQL | | | | | |
| 5.1 | `__tests__/lib/default-branch.test.ts` | Unit | | | | | |
| 5.2 | `use-cash-optin`, `RegisterPaymentForms-cash-optin`, `purchase-form-cash-optin` | Hook / Componente | | | | | |
| 5.3 | `use-default-branch-notice` | Hook | | | | | |
| 5.4 | POS (`pos-*`) | Componente | | | | | |
| 6.1 | `BranchSelect` | Componente | | | | | |
| 6.2 | `sale-form-branch-create` | Componente | | | | | |
| 6.3 | `operation-errors-branch` | Unit | | | | | |
