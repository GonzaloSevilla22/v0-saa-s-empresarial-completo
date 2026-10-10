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

- [x] 0.1 **[PO]** Sign-off de las OQ (`design.md` §Open Questions). Registrar la respuesta textual en una sección "Sign-off del PO" del `design.md`.
  - **OQ-1, OQ-2, OQ-3, OQ-7 y OQ-8**: sin respuesta, el apply adopta la recomendación de cada una, (a) en las cinco.
  - **OQ-4, OQ-5 y OQ-6 bloquean el grupo 3**: el apply no escribe `20261075000002` sin el OK textual del PO sobre las reglas de D6, la excepción a RN-21 y la precedencia movimiento/orden. Los grupos 1, 2 y 4 a 9 pueden avanzar mientras tanto.
  - Si el PO elige (b) en OQ-5: se retiran del change el delta de `inventory-single-ledger`, la pata de `stock_movements` del backfill (3.2), las mutaciones M5 y M5b (3.4), la nota de RN-21 (10.2) y la verificación 12.4 de movimientos nulos, y se ajusta el requirement de históricos del delta de `branches`. Si elige (a): se quita el criterio de origen demostrable del delta de `inventory-single-ledger`, de `branches` y de 3.2, y se retira M5b.
  - Si el PO elige (b) o (c) en OQ-8: el arreglo entra en este change (reescritura de `rpc_apply_product_stock_delta` o `rpc_reverse_stock_movement`, y de `rpc_promote_legacy_sale_to_order`, con su propio checkpoint del cuerpo vivo, preflight y gates), y los bloques (8b) y (9b) asertan el comportamiento nuevo.
  - Si el PO elige otra opción en cualquier OQ, actualizar en el mismo PR la decisión, las specs y estas tareas.
- [x] 0.2 **[PO ejecuta o autoriza]** Checkpoint del cuerpo **vivo de producción**, antes de escribir una línea de SQL:
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

  - El `md5(prosrc)` vivo de producción de las tres funciones tiene que coincidir con el local (el que dejan los archivos). Entonces es el `v_expected` del preflight de `20261075000001` (2.1).
  - **Si producción diverge de los archivos**, el `v_expected` no puede ser sólo el md5 de producción: CI y todo stack local construyen la base desde los archivos, y el preflight abortaría en toda base nueva (design, Migration Plan). Se elige con el PO: reconciliar primero los archivos con una migración propia anterior a `20261075000001`, o que `v_expected` acepte los dos md5 con el desvío documentado.
  - `COMMENT` esperado: la edición tiene uno; la v2 y el wrapper, ninguno.
  - ACL esperada: `postgres`, `authenticated` y `service_role` con `EXECUTE`, y `anon` sin `EXECUTE`.
  - Si algo diverge, se reescribe sobre el **vivo** y se anota acá el desvío.
- [x] 0.3 Confirmar que `20261075000001` y `20261075000002` siguen libres: `ls supabase/migrations`, `gh pr list --state open` y `MAX(version)` de producción (lo lee el PO). `presupuestos-modulo` reserva `20261067000001`/`20261068000001` (la base local compartida ya tiene `20261067000001`, aplicada por su apply en curso). Si ya mergeó, nuestras dos van después en CI. Renumerar si hace falta.
- [x] 0.4 Re-verificar sobre `main` actualizado el inventario de escritores de `sales`: las funciones vivas con `INSERT INTO public.sales` (v2, wrapper, edición, `_c29_confirm_order_core` y los dos `rpc_atomic_create_sale` legacy, sólo `service_role`) y los `UPDATE` (`rpc_safe_delete_product`). Grep de escrituras directas en `backend/`, `frontend/` y `supabase/functions/`. Anotar cualquier escritor nuevo que no esté en el design.
- [x] 0.5 SAFETY NET. Correr y registrar el baseline:
  - **Backend**: `backend/tests/test_sales.py`, `test_sales_branch_id.py`, `test_sale_items.py`.
  - **Frontend**: `__tests__` de `sale-form*`, `use-sales*`, `use-cash-optin*`, `use-purchases-cash-optin*`, `use-party-payment-cash-optin*`, `use-default-branch-notice*`, `branches*`, `operation-errors*`, `pos-*` (incluido `pos-operation-errors`), `purchase-form*` (incluido `purchase-form-cash-optin`), `expense-form*`, `expense-import-dialog*` y `RegisterPaymentForms*` (incluido `RegisterPaymentForms-cash-optin`).
  - **Gates SQL**: `test_ventas_formulario_sucursal.sql` y los 23 de `supabase/tests/` que nombran `rpc_create_sale_operation`, `rpc_create_sale_operation_v2` o `rpc_atomic_update_sale_operation`. En particular:
    - `test_confirm_core_integrity.sql`, `test_cuenta_corriente_party_guard.sql`, `test_operacion_party_guard.sql`;
    - `test_pos_rpc_signatures.sql`, `test_cobranzas_vencimientos_schema.sql`;
    - `test_ventas_unidades_conversion.sql` y `test_ventas_unidades_conversion_race.sh`, `test_edicion_preserva_contexto.sql`, `test_facturar_venta_manual.sql`, `test_stock_movements_edicion.sql`, `test_operation_edit_lines.sql`;
    - `test_function_acl_gate.sql`.

  Una falla previa se reporta como preexistente y no se corrige acá.

## 1. RED — gate SQL de las funciones (antes de tocarlas)

- [x] 1.1 Escribir `supabase/tests/test_ventas_sucursal_por_defecto.sql` con los bloques (0)-(6) (incluido (3b)), (8b) y (9b) de `design.md` D13. Los bloques (7), (8) y (9) dependen del backfill y van en el grupo 3. Patrón del proyecto:
  - fallos acumulados en `text[]` y un solo `RAISE` al final;
  - anchors sintéticos vía `handle_new_user`;
  - `created_at` explícito y estrictamente posterior en las sucursales sintéticas, asertado (`c26_default_branch` no desempata);
  - limpieza de toda fila con el `account_id` de los anchors **y** de las dependencias sin `account_id` (las `cashboxes` de sus sucursales).
- [x] 1.2 Fixtures:
  - cuenta con A (principal) y B, productos con stock en las dos y producto de servicio (línea sin `product_id`);
  - flag `sale_items_rpc_v2 = false` para la cuenta del bloque (2);
  - A cerrada (`status = 'closed'`, `is_active` intacto) para el bloque (3);
  - para el bloque (3b), cuenta con una sucursal desactivada (`is_active = false`) y otra cerrada, ambas vacías: sin `session_replication_role`;
  - para el bloque (4), cuenta sin ninguna sucursal. Bajo `session_replication_role = replica` (para esquivar `trg_guard_branch_decommission`) no corren las acciones de FK, así que antes del `DELETE` de la sucursal se borran explícitamente sus `cashboxes` (que `handle_new_user` siembra y que no tienen `account_id`) y su `branch_stock`. Al final, asertar residuo cero de cajas y de stock de esas sucursales;
  - fila residual con `branch_id NULL`, insertada directo, para la edición sin informar del bloque (5);
  - forma de pago bancaria con cuenta destino para el bloque (6);
  - para el bloque (8b), una venta con B explícita y B cerrada después (sin stock, sin caja abierta, sin transferencias);
  - para el bloque (9b), una venta sin sucursal elegida en A, después A vaciada por transferencia y desactivada.
- [x] 1.3 Correr el gate contra los cuerpos **actuales** y registrar el RED. Esperado:
  - (0) falla porque los `INSERT` persisten `p_branch_id` y el md5 no es el reescrito;
  - (1), (2), (3) y (6) fallan con `branch_id NULL`;
  - (3b) falla porque la venta de servicio pasa con `NULL` y la de producto descuenta de la sucursal no operativa (o da `P0409`) en vez de `P0422 no_branch_found`;
  - (4) falla porque la venta de servicio pasa con `NULL` y la de producto da `P0409` en vez de `P0422 no_branch_found`;
  - (5) falla con la fila resultante en `NULL`;
  - (9b), con la recomendación (a) de OQ-8, falla porque con el cuerpo actual el movimiento queda `NULL` y el borrado repone en la principal operativa, no en A desactivada. Es el RED de la consecuencia declarada de D2, no de un comportamiento deseado: el mensaje del caso nombra el candidato;
  - (8b) pasa ya con los cuerpos actuales (el comportamiento es preexistente para toda venta con sucursal elegida): es un caso de caracterización y se registra como tal.
- [x] 1.4 Actualizar **a propósito** `supabase/tests/test_ventas_formulario_sucursal.sql`:
  - el bloque 2 pasa a «sin sucursal elegida: `sales.branch_id` y `stock_movements.branch_id` = principal, stock de la principal»;
  - el bloque 6c pasa a «venta, movimiento de stock y movimiento bancario en la **misma** principal»;
  - el encabezado cita `ventas-sucursal-por-defecto` en lugar de "decisión del PO pendiente".

  Correr contra los cuerpos actuales y registrar el RED.

## 2. GREEN — `supabase/migrations/20261075000001_ventas_sucursal_por_defecto.sql` (funciones)

- [x] 2.1 Escribir la migración partiendo de los cuerpos vivos de 0.2:
  - **Preflight** (bloque `DO` al principio, molde de `20261062000001` L107-170): `v_expected` con los `md5(replace(prosrc, E'\r', ''))` de partida confirmados en 0.2; `v_rewritten` con los que deja esta migración, medidos en el stack local después de aplicarla. Si el cuerpo vivo no es ninguno de los dos, `RAISE EXCEPTION` sin reescribir. Si ya es el reescrito, `NOTICE 'ventas-sucursal-por-defecto: % ya es el cuerpo de esta migración (reaplicación)'`.
  - Con **sólo** los cambios de `design.md` D2:
    - **v2**: `v_gate_branch` en los tres `INSERT` (sales con producto, sales de servicio, `stock_movements`) y el guard `P0422 no_branch_found` (sin sucursal elegida y principal `NULL` o no operativa), después de resolver `v_gate_branch` y antes del `INSERT` en `operation_idempotency`.
    - **Rama legacy del wrapper**: los mismos tres cambios y el mismo guard. La rama de delegación no se toca.
    - **Edición**: si `v_final_branch_id` quedó `NULL`, la principal y el mismo guard, después del tri-estado y **antes** del REVERSE.

  Cabecera de la migración con contexto, decisión del PO, reglas y referencias. Un comentario `-- ventas-sucursal-por-defecto (Dn):` en cada punto tocado.
- [x] 2.2 Re-declarar el `COMMENT` vivo de la edición, con su texto vivo completo más, al final, la excepción de D5 («ventas-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la principal»), porque «preserva branch_id … tri-estado para branch_id» deja de ser cierto para el nulo. Sin `COMMENT` nuevo en v2 ni wrapper si el vivo no lo tiene. Re-emitir las ACLs: `REVOKE ALL … FROM PUBLIC, anon` más `GRANT EXECUTE … TO authenticated, service_role`, idénticas a las vivas.
- [x] 2.3 Diff del cuerpo nuevo contra el vivo, por función y sin `\r`. Tiene que ser **exactamente** los cambios de D2 más los comentarios. Adjuntar el diff como evidencia en el PR.
- [x] 2.4 Aplicar en la base local y correr el gate. Tienen que quedar GREEN:
  - bloques (0)-(6), (3b), (8b) y (9b) de `test_ventas_sucursal_por_defecto.sql`;
  - `test_ventas_formulario_sucursal.sql` completo.
- [x] 2.5 Mutaciones sobre los cuerpos locales, dentro de una transacción con `ROLLBACK`. Cada una tiene que ser detectada por el gate con un mensaje propio:
  - M1: v2 con `p_branch_id` crudo en `sales`;
  - M2: la rama legacy con `p_branch_id` crudo;
  - M3: v2 con `p_branch_id` crudo en `stock_movements`;
  - M4: edición sin la resolución de la principal;
  - M9: guard que sólo mira `NULL` y deja pasar una principal no operativa.

  Registrar los mensajes.
- [x] 2.6 Idempotencia: reaplicar el archivo dos veces sobre la base local. La segunda pasada tiene que tomar la rama de reaplicación del preflight (3 `NOTICE`) y el fingerprint de esquema no cambia (el mismo `schema_snapshot` del paso "Verify … idempotent on reapply" de `KPI_Validation.yml`).
- [x] 2.7 Correr todos los gates de 0.5. En particular, `test_confirm_core_integrity.sql` (3) por las subcadenas de la v2, `test_cuenta_corriente_party_guard.sql` (3.8-v2) y `test_operacion_party_guard.sql` por el guard de cliente, `test_pos_rpc_signatures.sql` (1d) por una sola firma, y `test_function_acl_gate.sql`. Todos verdes.

## 3. Backfill — `supabase/migrations/20261075000002_ventas_sucursal_por_defecto_backfill.sql` (datos)

> **Bloqueado hasta el OK textual del PO sobre OQ-4, OQ-5 y OQ-6** (0.1).

- [x] 3.1 RED: agregar el bloque (7) al gate, con fixtures para cada caso de D6:
  - mono-sucursal;
  - multi-sucursal;
  - operación mixta (una fila en B, otra `NULL`), con una línea de servicio sin movimiento;
  - operación mixta con B **cerrada** (queda en B y se cuenta en `mixta_no_operativa`);
  - venta `NULL` con orden en B y comprobante `authorized`, y movimiento `'sale'` en X ≠ B (queda en B; `discrepancia_movimiento`); y lo mismo con `pending_cae` con marca de envío;
  - venta `NULL` con su movimiento `'sale'` en X operativa ≠ principal A, sin orden;
  - venta `NULL` con su movimiento `'sale'` en X operativa y orden sin comprobante en B (queda en X; `discrepancia_orden`);
  - venta `NULL` con su movimiento `'sale'` en X **cerrada** (debe quedar en la principal y contarse como discrepancia);
  - venta con `sales_orders` sin comprobante en B aunque la principal sea A, sin movimiento con sucursal;
  - venta con `sales_orders` sin comprobante en una sucursal **cerrada** (debe saltearse la regla);
  - cuenta con todas sus sucursales desactivadas o cerradas (residuo);
  - fila con `account_id NULL` (residuo);
  - venta borrada cuyo movimiento original y cuya reversa quedaron `NULL`;
  - movimientos `'sale'` `NULL` de las ventas vivas: en una cuenta cuya única sucursal existía al escribirse el movimiento (origen demostrable) y en una cuenta que ya tenía otra sucursal en ese momento (origen incierto). Los `created_at` de las sucursales y de los movimientos van explícitos y asertados.

  Registrar los conteos de `events`, `notifications`, `analytics_events`, `cash_movements`, `bank_movements`, `customer_account_movements` y `journal_entries` antes de la corrida, **acotados a los `account_id` de las cuentas del fixture**: `relay-process-outbox` y `relay-process-pending-cae` corren cada minuto por `pg_cron` en el stack local y en CI, y un conteo global puede cambiar sin defecto. Lo mismo para la aserción de la segunda corrida sobre `audit_logs`. El archivo de datos es global (también asigna ventas `NULL` que otros gates hayan dejado): ninguna aserción mira filas fuera del fixture. Ejecutar el archivo de datos con `\i` (todavía inexistente o vacío) y registrar el RED.
- [x] 3.2 GREEN: escribir la migración de datos (sin DDL, sin funciones, sin ACLs). Cabecera con:
  - la decisión textual del PO y su sign-off de OQ-4, OQ-5 y OQ-6;
  - las reglas de D6;
  - por qué no hace falta medir antes (D6, D7);
  - la excepción a RN-21 y sus límites, con el criterio de origen demostrable (si OQ-5 = (c); sin el criterio si es (a));
  - la idempotencia y la regla de que nunca aborta por datos.

  En un bloque `DO`:
  - tomar las candidatas (`branch_id IS NULL AND account_id IS NOT NULL`) con `FOR UPDATE` en **orden ascendente de `id`**, para respetar el orden global de locks del proyecto;
  - resolver la sucursal **por operación** (`COALESCE(operation_id, id)`) con las reglas de D6, en este orden: operación mixta → orden con comprobante vigente (`authorized`, o `pending_cae` con `cae_submit_started_at`/`cae_submit_unconfirmed_at`) → movimiento de stock propio → orden sin comprobante vigente → principal vigente. Las reglas 1 y 2 no pasan por el filtro de sucursal operativa (contar `mixta_no_operativa` y `orden_facturada_no_operativa`); las reglas 3 a 5 sí (contar las salteadas);
  - `UPDATE sales`;
  - si OQ-5 = (c): `UPDATE stock_movements SET branch_id = …` **sólo** de los movimientos `type = 'sale'`, `reference_type = 'sale'`, `branch_id IS NULL`, de las ventas asignadas en esta corrida y **de origen demostrable**: la sucursal asignada existía y era la única de la cuenta al `created_at` del movimiento (`NOT EXISTS` otra sucursal de la cuenta con `created_at <=` el del movimiento). Ninguna otra columna. Contar los no completados (`movimiento_origen_incierto`). Con (a), sin el criterio de origen;
  - una fila de `audit_logs` por cuenta afectada (`action = 'sales_branch_backfill'`, `entity_type = 'account'`, `user_id NULL`, `metadata` con `sale_ids`, `movement_ids`, conteo por regla, `mixta_no_operativa`, `orden_facturada_no_operativa`, `salteadas_no_operativa`, `discrepancia_movimiento`, `discrepancia_orden`, `movimiento_origen_incierto`, `branch_ids` y `evidencia_otra_sucursal`), sólo si la cuenta tuvo filas asignadas;
  - `NOTICE` con:
    - los conteos por regla, las asignaciones de las reglas 1 y 2 a sucursales no operativas y las reglas salteadas;
    - los movimientos actualizados y los de origen incierto;
    - el residuo (sin cuenta, cuenta sin sucursal, cuenta sin sucursal operativa);
    - las ventas asignadas cuyo movimiento `'sale'` ya registraba **otra** sucursal (`discrepancia_movimiento`);
    - las ventas asignadas que quedan en una sucursal distinta de la de su orden sin comprobante vigente (`discrepancia_orden`);
    - las ventas asignadas cuyo movimiento de caja (`cash_movements.reference_id` = operación → `cash_sessions` → `cashboxes.branch_id`) o de banco (`bank_movements.source_doc_type = 'sale'`, `source_doc_ref` = operación) registró **otra** sucursal (OQ-4).
- [x] 3.3 Correr el bloque (7) ejecutando el archivo **dos veces**. Verificar:
  - cada caso de D6;
  - la segunda corrida no cambia filas ni escribe auditoría;
  - los conteos de efectos laterales, acotados a las cuentas del fixture, quedan iguales.

  Después escribir y correr los bloques (8) (`rpc_promote_legacy_sale_to_order` **ejecutada** sobre la operación antes mixta) y (9) (`rpc_delete_sale_operation` **ejecutada** repone donde dice el movimiento: en la sucursal asignada si se completó, en X para la venta asignada por la regla del movimiento, y en la principal vigente si quedó `NULL` por origen incierto).
- [x] 3.4 Mutaciones, con `ROLLBACK`, detectadas por el gate:
  - M5: el backfill sin la pata de `stock_movements` (si OQ-5 = (a) o (c));
  - M5b: el backfill sin el criterio de origen demostrable (si OQ-5 = (c));
  - M6: el backfill sin la regla de la orden sin comprobante;
  - M6b: el backfill sin la regla de la orden con comprobante vigente;
  - M7: el backfill sin la regla del movimiento;
  - M8: el backfill sin el filtro de sucursal operativa en las reglas 3 a 5;
  - M8b: el backfill con el filtro de sucursal operativa también en la regla 1.
- [x] 3.5 Medir en la base local el tiempo del backfill sobre un volumen sintético (por ejemplo, 50.000 filas `NULL` en varias cuentas) para acotar la ventana de locks por fila. Anotar el resultado en el PR. No hace falta medir producción (D7).

## 4. CI

- [x] 4.1 `.github/workflows/KPI_Validation.yml`:
  - **retirar el bloque de reaplicación de `20261062000001`** (L982-1036, desde su comentario de cabecera hasta el `echo "20261062000001 idempotente…"`; L1038 ya es la cabecera del bloque de `20261063000001`, que se conserva). Citar en el commit la regla del propio workflow (L1004-1018): este change redefine tres de sus diez funciones y ese preflight abortaría. Mejor ubicar el bloque por su contenido que por número de línea;
  - actualizar todos los comentarios que se apoyan en el bloque retirado: los de `20261063000001` (L1039 y L1050), `20261064000001` (L1072), `20261065000001` (si lo nombra) y `20261066000001` (L1125-1133, que además explica la columna `base_unit_id` que dejaba la reaplicación retirada). La aserción de `scale_plu` sigue valiendo;
  - actualizar el comentario del paso «Run ventas formulario sucursal gate» (L2622-2638), que dice «(2) sin sucursal -> branch_id NULL … (contrato vigente, el fix NO lo cambia)» y «(6) … y la default si no se eligió ninguna»: pasa a citar este change y el contrato nuevo;
  - agregar la reaplicación de `20261075000001` y de `20261075000002` **después de la reconvergencia**, al final de los reapply posteriores (después de `20261066000001` y, si ya mergearon, de `20261067000001`/`20261068000001`), sin tolerancia: el de funciones exige 3 `NOTICE` «ya es el cuerpo de esta migración» (conteo como `UOM_REAPPLIED`), el de datos su `NOTICE` final con 0 filas asignadas, y los dos un `schema_snapshot` idéntico.
- [x] 4.2 Cablear `supabase/tests/test_ventas_sucursal_por_defecto.sql` como paso propio. `test_ventas_formulario_sucursal.sql` mantiene su paso.
- [ ] 4.3 **(abierta a propósito en el apply)** Antes del PR, correr en local el paso completo de CI con el preflight definitivo: `supabase db reset`, la cadena de reaplicación, la reconvergencia y los reapply posteriores. Así se prueba que el `v_expected` coincide con el cuerpo que dejan los archivos (0.2). Después, en la corrida de CI, confirmar que:
  - el bloque (0) del gate nuevo pasa **después** de los reapply (ninguna reaplicación puede dejar vivo un cuerpo viejo, lección de `candidatos-db-backend`);
  - `test_ventas_unidades_conversion.sql` y `test_ventas_unidades_conversion_race.sh` siguen verdes: cubren las otras siete funciones que dejó de reaplicar el bloque retirado.

  **Nota del apply**: `supabase db reset` **no** se corrió porque la base local es compartida con otras sesiones. En su lugar se emuló la cola de la cadena de reaplicación con `psql` (las dos migraciones aplicadas **dos veces** y el gate nuevo corrido entre medio), se comparó el `schema_snapshot` antes y después de cada pasada (idéntico) y se corrieron los 25 gates del orden de CI, todos en verde. Falta la corrida real de la cadena completa, que es la de CI de este PR: confirmar ahí el bloque (0) del gate nuevo **después** de los reapply y los dos gates de unidades.

## 5. Frontend — una sola "principal" en el cliente

- [x] 5.1 RED/GREEN de `frontend/lib/default-branch.ts`, `resolveDefaultBranch(branches: Branch[]): Branch | null`, con `__tests__/lib/default-branch.test.ts`. Casos:
  - lista vacía → `null`;
  - la primera con `status === "active"`;
  - la más antigua cerrada se saltea;
  - todas cerradas → la primera;
  - respeta el orden de entrada (el de `useBranches`, `created_at` ascendente).
- [x] 5.2 `hooks/use-cash-optin.ts`: `effectiveBranchId = branchId || resolveDefaultBranch(branches)?.id || null`. RED primero: con la más antigua cerrada, la sucursal efectiva tiene que ser la segunda. Regresión de sus cinco consumidores:
  - venta y gasto: los tests existentes siguen verdes;
  - compra: `__tests__/components/purchase-form-cash-optin.test.tsx` sigue verde. Su caso de `BranchSelect` mockeado a `null` fija un payload que el servidor rechaza (preexistente, OQ-3): no se corrige acá, se anota en el PR;
  - cobro y pago de cuenta corriente: caso nuevo en `__tests__/components/RegisterPaymentForms-cash-optin.test.tsx`: con la más antigua cerrada, el modal de cobro ofrece la sesión de la principal operativa.
- [x] 5.3 `hooks/use-default-branch-notice.ts`: `resolveDefaultBranch(branches)` en lugar de `branches[0]`. RED primero: con la más antigua cerrada, no se anuncia como principal.
- [x] 5.4 POS (`app/(dashboard)/ventas/pos/page.tsx:166`): `activeBranch = resolveDefaultBranch(branches)`. RED primero, en el test del POS que corresponda (por ejemplo `__tests__/pos-payment-methods.test.tsx`, o uno nuevo `pos-default-branch.test.tsx`): con la más antigua cerrada, el POS usa B para la caja y la sesión y manda `branch_id = B` en el payload. Los `pos-*` existentes siguen verdes.
- [x] 5.5 Grep de `branches[0]` en `frontend/` usado como "sucursal por defecto" que haya quedado fuera de 5.2-5.4. Migrar al helper o justificar cada uno en el PR (`caja/page.tsx:50` sólo lo usa con una única sucursal; `e2e/fixtures/fiscal-e2e.ts:105` es un fixture).

## 6. Frontend — selector de la venta

- [x] 6.1 RED/GREEN de `components/branches/BranchSelect.tsx`, con props nuevas cuyos valores por defecto no cambian nada:
  - `allowUnassigned?: boolean` (por defecto `true`): con `true`, opciones y comportamiento idénticos a hoy (test de regresión con la opción "Sin sucursal (general)"); con `false`, sin la opción `__none__`, valor mostrado `value ?? resolveDefaultBranch(branches)?.id`, la principal rotulada "Nombre (principal)" y `onChange` emite el id elegido;
  - `label?: string`: se renderiza **dentro** del componente, con `useId`, `<Label htmlFor>` e `id` en el `SelectTrigger` (patrón de `PaymentMethodSelect.tsx:95-108`);
  - `fallbackBranchId?: string | null`: valor mostrado con el estado en `null` cuando el servidor no va a usar la principal (documento de origen con sucursal). No se emite por `onChange`. Valor mostrado: `value ?? fallbackBranchId ?? resolveDefaultBranch(branches)?.id`;
  - con `allowUnassigned={false}`, placeholder «Cargando sucursales…» mientras `useBranches` carga.

  Tests nuevos:
  - (a) sin módulo de sucursales no se renderiza ni el rótulo ni el control;
  - (b) mientras cargan las sucursales, el disparador no dice «Sin sucursal»;
  - (c) `getByLabelText('Sucursal')` encuentra el combobox;
  - (d) con el componente real (sin mock), re-elegir la principal que ya se muestra no emite `onChange`;
  - (e) con `fallbackBranchId = B` y el valor en `null`, el disparador muestra B, no la principal.
- [x] 6.2 RED/GREEN de `components/forms/sale-form.tsx`:
  - `BranchSelect` con `allowUnassigned={false}` y `label="Sucursal"`; se retira el `placeholder="Sin sucursal (general)"` (L944);
  - **alta** sin tocar el selector: el payload lleva `branch_id: null` y el selector muestra la principal;
  - **alta** eligiendo B: viaja el id de B;
  - **edición** precarga la sucursal de la venta;
  - **edición** de una venta con `branchId` nulo: muestra la principal.

  Actualizar `frontend/__tests__/components/sale-form-branch-create.test.tsx`: el caso «elegir y volver a "Sin sucursal"» desaparece y lo reemplaza «elegir B y después volver a la principal manda el id de la principal». Ese test mockea `BranchSelect` con botones que llaman a `onChange` directo, así que el comportamiento real de Radix lo cubre 6.1 (d). Validar por mutación que los casos fallan sin el cambio.
- [x] 6.3 RED/GREEN de `lib/operation-errors.ts`: traducir `no_branch_found`. Hoy lo traducen cuatro lugares con textos distintos (Context). Reutilizar el texto de `hooks/data/use-promote-to-order.ts:50`, que ya manda a configurar una sucursal, ajustado sólo para nombrar la salida real (crear o reabrir una sucursal desde Sucursales); no crear un quinto texto. **RED documentado**: `__tests__/lib/operation-errors-branch.test.ts:44-49` hoy fija que `no_branch_found` pasa tal cual, y se modifica a propósito. No romper los casos `branch_closed`, `branch_not_found`, `branch_invalid` ni el stock insuficiente con su acción de transferir. El `friendlyError` del POS no se toca, y unificar los otros textos queda como candidato.
- [x] 6.4 Actualizar los comentarios y la prosa de tests del frontend que afirman que una venta sin sucursal queda `NULL` o que `null` significa "Sin sucursal (general)". Pasan a decir «sin sucursal elegida, viaja `null` y la RPC la registra en la principal», sin cambiar ninguna aserción:
  - `hooks/data/use-sales.ts` (cerca de L236-240);
  - `__tests__/hooks/use-sales-branch.test.ts:89`;
  - `__tests__/hooks/use-sales.test.ts:161`;
  - cualquier otro que aparezca en el grep.
- [x] 6.5 Regresión de compra, gasto e importador de gastos: sus tests verdes y su opción sin sucursal presente con su texto actual (compra y gasto: "Sin sucursal (general)"; importador de gastos: "Sin sucursal por defecto", `expense-import-dialog.tsx:691`).
- [x] 6.6 `pnpm vitest run` de los archivos afectados y vecinos, y `tsc --noEmit` sin errores nuevos respecto del baseline.
- [x] 6.7 Coordinación con `presupuestos-modulo`. Su núcleo `_quote_accept_core` resuelve la sucursal con la precedencia «la indicada por la conversión, la del presupuesto o la sucursal por defecto» (su spec `quote`, requirement «Quote.accept() crea un SalesOrder…»), no la principal sin más. Si mergeó antes que este change: pasar su `ConvertQuoteDialog` (que registra una venta) a `allowUnassigned={false}` con `label="Sucursal"` y `fallbackBranchId` = la sucursal del presupuesto (o precargar su estado con ella), con un test: con el presupuesto en B y la principal A, el diálogo muestra B y la venta queda en B. Resolver además el conflicto en `sale-form.tsx` (aquél migra el carrito a `lib/cart-utils.ts`). Si no mergeó: dejar la indicación en la descripción del PR y en el engram de los dos changes, para que lo haga quien aplique segundo. `QuoteForm` conserva el valor por defecto.

## 7. Backend (sin cambio de lógica)

- [x] 7.1 Corregir los comentarios y la prosa que afirman que `None` conserva `branch_id` NULL, sin cambiar ninguna aserción:
  - `backend/services/sales.py` cerca de L147 y `backend/schemas/sales.py` cerca de L50-56;
  - los docstrings de `backend/tests/test_sales_branch_id.py:75-77` y `:212`.

  Agregar a `SaleOperationIn.branch_id` y `SaleOperationUpdateIn.branch_id` la descripción de OpenAPI: «sin sucursal, la venta se registra en la sucursal principal de la cuenta».
- [x] 7.2 Confirmar con los tests existentes (`test_sales_branch_id.py`) que el alta y la edición transportan `None` y el tri-estado (`p_branch_provided`) sin cambios. No se agregan tests de comportamiento, porque no lo hay: la resolución es de la RPC y la cubre el gate.
- [x] 7.3 Correr la suite completa con el comando de CI (`pytest backend/tests -m "not integration" --cov=backend`). Cobertura ≥ 87 %.

## 8. Verificación visual (superficie frontend)

- [x] 8.1 Formulario de venta en alta y edición. Cuenta con módulo y dos sucursales, y cuenta sin módulo. Combinaciones:
  - escritorio (1280 px) y móvil (375 px);
  - tema claro y tema oscuro.

  Verificar:
  - rótulo "Sucursal", principal preseleccionada y marca "(principal)" con contraste AA (tokens semánticos, sin colores literales);
  - lista sin "Sin sucursal (general)";
  - en la cuenta sin módulo, ni selector ni rótulo;
  - sin desborde horizontal a 375 px.

  Adjuntar capturas.

  **Hecho (apply, 2026-10-10)**, con un arnés Playwright temporal contra el stack local (cuenta Pro con A «Casa Central» y B «Sucursal Norte QA»; cuenta sin módulo con su «Casa Central»). Capturas en las 4 combinaciones (1280 y 375 px, claro y oscuro) de: alta con módulo, alta sin módulo y alta con la más antigua cerrada; más la edición precargando la sucursal de cada venta (A y B) y la lista desplegada. Resultado: rótulo «Sucursal», principal preseleccionada con la marca «(principal)» y sus tokens semánticos; la lista **no** ofrece «Sin sucursal (general)»; en la cuenta sin módulo, ni selector ni la palabra «sucursal» en el modal; sin desborde horizontal a 375 px en ninguna combinación. Las capturas son artefactos del apply y no se versionan.
- [x] 8.2 Formularios de compra y de gasto, e importador de gastos, en las mismas combinaciones: la opción sin sucursal sigue igual.

  **Hecho (apply, 2026-10-10)**: compra y gasto muestran «Sin sucursal (general)» y el importador de gastos «Sin sucursal por defecto» en las 4 combinaciones (1280 y 375 px, claro y oscuro), sin desborde horizontal. Cierra la regresión de 6.5 con evidencia visual.

## 9. Humo en el stack local

- [x] 9.1 Levantar el stack local: Supabase con las migraciones de la rama, `uvicorn` desde el worktree y `pnpm dev`. Usar una cuenta Pro con A (principal) y B y una cuenta sin módulo de sucursales, y verificar cada caso con `psql`.
  - **H1**: venta sin tocar el selector → `sales` y `stock_movements` en A, stock de A. Anotar el aviso «Stock insuficiente (disponible: N)» con un producto que sólo tiene stock en B: muestra el agregado (candidato (c) de #606, Non-Goal).
  - **H2**: eligiendo B → B.
  - **H3**: cuenta sin módulo → su "Casa Central". Si se puede armar, una cuenta sin módulo que conserva dos sucursales → la más antigua operativa.
  - **H4**: `PUT /sales/{id}` con `branch_id: null` → A.
  - **H5**: `POST /sales` sin el campo → A.
  - **H6**: ventas `NULL` creadas con el código de `main`, una de ellas editada (movimiento con sucursal), y después la migración de datos → asignadas según D6, con fila en `audit_logs`.
  - **H7**: Tablero filtrado por A suma las ventas de H1 y H6.
  - **H8**: cerrar la sucursal más antigua (sin stock) → el selector de la venta preselecciona la siguiente, el opt-in de caja de la venta y el modal de cobro de cuenta corriente buscan su sesión, el aviso de sucursal por defecto la nombra, el POS usa su caja y la manda como sucursal, y una venta sin tocar el selector queda en ella.
  - **H9**: desactivar todas las sucursales de una cuenta de prueba vacía → una venta sin sucursal se rechaza con el mensaje traducido de `no_branch_found`.

  **Resultado del humo local (apply, 2026-10-10)**: stack = Supabase local con las dos migraciones de la rama aplicadas, `uvicorn` del worktree y `pnpm dev`, con el arnés Playwright temporal y `psql` por cada caso. Los nueve casos pasaron:
  - **H1** (UI, sin tocar el selector, principal preseleccionada): `sales.branch_id` = A en 1 fila, `stock_movements.branch_id` = A, stock de A 93 → 91 y de B 15 → 15. **H1b**, producto con stock sólo en B sin tocar el selector: la venta se rechaza con el mensaje por sucursal «No hay stock de «Humo solo B» en la sucursal Casa Central. Puede haber unidades en otra sucursal…» y la acción «Transferir stock»; ninguna venta del producto queda registrada (no aparece «Stock insuficiente (disponible: N)» agregado: el rechazo viene del servidor, ya contra la sucursal resuelta).
  - **H2** (eligiendo B): `sales` y movimiento en B, stock de B 15 → 14 y de A sin cambio (91).
  - **H3a**: cuenta sin módulo → `sales.branch_id` y movimiento = su «Casa Central». **H3b**: cuenta sin módulo que conserva dos sucursales → la más antigua operativa (Casa Central).
  - **H4** (`PUT /sales/operation` con `branch_id: null` sobre una venta de B, 200): la venta queda en A, stock de B 12 → 14 y de A 90 → 88.
  - **H5** (`POST /sales` sin el campo, 201): `sales` y movimiento en A.
  - **H6**: con los cuerpos de `main` se crearon 2 ventas `NULL` por la API real y una se editó (movimiento con A); después se aplicaron las dos migraciones. Resultado: las dos quedaron en A. `audit_logs` (`sales_branch_backfill`): 2 ventas, `por_regla` = `{principal: 1, movimiento: 1, operacion: 0, orden: 0, orden_facturada: 0}`, `movimiento_origen_incierto: 1` (OQ-5 (c): ese movimiento `NULL` no se completa), `movement_ids: []`, discrepancias 0.
  - **H7**: ingresos del Tablero filtrado por A = 3500 = suma de las ventas con `branch_id = A`; ventas sin sucursal = 0.
  - **H8** (cuenta Pro con la más antigua cerrada y vacía): el aviso de sucursal por defecto nombra a la nueva principal (Sucursal W2) y no a la cerrada; el selector de la venta preselecciona «Sucursal W2 (plan anterior) (principal)», ofrece **su** sesión de caja y la venta con el opt-in tildado deja `sales.branch_id` = W2 y el movimiento de caja en la sesión de W2; el modal de cobro de cuenta corriente ofrece la caja abierta; el POS manda W2 como sucursal: la orden, la venta y el movimiento de caja quedan en W2 y en su sesión.
  - **H9** (todas las sucursales desactivadas, sin sesión de caja abierta): el selector muestra «Sin sucursal disponible» y la venta se rechaza con «No encontramos una sucursal activa en la cuenta. Creá una o reabrí una cerrada desde Sucursales y volvé a intentar.»; ningún texto técnico `no_branch_found` llega al usuario y no se crea ninguna fila.

## 10. Specs, KB y documentación

- [x] 10.1 Correr `openspec validate "ventas-sucursal-por-defecto" --strict` y `openspec validate --specs --strict`.

  **Hecho (apply, 2026-10-10)**: el change es válido y las specs dan `109 passed, 0 failed`.
- [x] 10.2 `knowledge-base/05_reglas_de_negocio.md`:
  - RN-93: nota de que la venta la cumple desde este change (alta, edición e históricos) y de que compras queda pendiente (OQ-3);
  - RN-21 (si OQ-5 = (a) o (c)): nota de la única excepción auditada, con sus límites y el puntero al requirement nuevo de `inventory-single-ledger`.
- [ ] 10.3 Al archivar (no en el apply):
  - **`CHANGES.md`**: ficha con la verificación posterior y los candidatos que deja:
    - `NOT NULL` en `sales.branch_id` con retiro de los `rpc_atomic_create_sale` muertos y FK `RESTRICT` (D8);
    - `compras-gastos-sucursal-por-defecto`, con el opt-in de caja de la compra sin sucursal (OQ-3);
    - sucursal principal configurable (OQ-1);
    - disparador de defensa en profundidad (D1, alternativa A);
    - gate de stock de la edición contra la sucursal efectiva (candidato (d) de #606);
    - stock de la sucursal efectiva en el formulario (candidato (c) de #606);
    - guard de última sucursal operativa en `rpc_deactivate_branch` (D3);
    - reversa y "Facturar venta manual" con la sucursal guardada no operativa (OQ-8, si quedó en (a)): el stock que vuelve a una sucursal desactivada y la orden que nace en una cerrada o desactivada;
    - unificar las traducciones de `no_branch_found` (6.3).
  - **`CLAUDE.md`**: puntero y `python scripts/ci/check_docs_sync.py --fix` para `AGENTS.md`.
  - Diffear cada spec sincronizada contra su versión previa (`branches`, `branch-stock`, `operation-edit-context`, `inventory-single-ledger`, `dashboard-kpi-summary`, `sales-statistics`, `expense-operation`): si otro change archivó antes un delta sobre el mismo requirement, el segundo archive lo pisa sin que el conteo lo delate.

## 11. PR y merge

- [ ] 11.1 PR con commits convencionales y CI verde: `validate-kpis` con el gate nuevo, el bloque retirado y los reapply nuevos, Backend, Frontend, E2E y Docs Sync.
- [ ] 11.2 Revisión adversarial con un solo juez por ronda (tope de agentes del workflow) sobre: el diff de funciones contra el vivo, el preflight, el orden de locks del backfill, la resolución por operación y el filtro de operativa, la idempotencia, la paridad v2/legacy y la superficie frontend.
- [ ] 11.3 **[PO]** Merge. Los sub-agentes no mergean migraciones de datos.

## 12. Verificación posterior al merge (producción, sólo lectura; la ejecuta o autoriza el PO)

- [ ] 12.1 `deploy.yml` verde, con `MAX(version)` igual a `20261075000002` (o la última de la cadena). Vercel desplegado. Render: `GET /deploys` del commit del merge, y `POST /deploys` si falta (el auto-deploy no siempre dispara).
- [ ] 12.2 En los cuerpos vivos de las tres funciones, la persistencia resuelta y el guard están presentes, y su `md5(prosrc)` es el `v_rewritten` del preflight. La edición conserva su `COMMENT`. Las ACLs no cambiaron y hay una sola firma por función.
- [ ] 12.3 `SELECT count(*) FROM sales WHERE branch_id IS NULL` tiene que coincidir con el residuo que informó la migración. Ventas en vuelo: **no** buscarlas por `created_at` (es `DEFAULT now()`, el inicio de la transacción, así que una venta en vuelo tiene un `created_at` anterior al deploy). Listar las filas `NULL` con `account_id` no nulo cuya cuenta tiene una sucursal operativa (`is_active AND status = 'active'`): son las que el backfill habría asignado y tienen que ser 0. Si hay alguna, o si el conteo total supera al residuo informado, **[PO]** re-ejecutar el bloque idempotente del archivo de datos con `npx supabase db query --linked`.
- [ ] 12.4 Movimientos de stock:
  - movimientos `reference_type = 'sale'` con `branch_id NULL` cuya venta exista: con OQ-5 (c), iguales a la suma de `movimiento_origen_incierto` de la auditoría; con (a), cero;
  - discrepancias venta ≠ orden: ventas cuya `sales_orders` (por `sale_operation_id`) tiene otra sucursal. El número tiene que coincidir con `discrepancia_orden`, y ninguna de ellas puede tener comprobante vigente;
  - discrepancias: ventas asignadas cuyo movimiento `'sale'` tiene otra sucursal (`sales.branch_id IS DISTINCT FROM stock_movements.branch_id`, uniendo por `reference_id = sales.id`). El número tiene que coincidir con `discrepancia_movimiento` de la auditoría.
- [ ] 12.5 Filas `audit_logs` con `action = 'sales_branch_backfill'`: cantidad de cuentas, total de ventas y movimientos asignados, conteo por regla, asignaciones de las reglas 1 y 2 a sucursales no operativas, reglas salteadas, movimientos de origen incierto, discrepancias con movimientos y con órdenes, y el conteo de evidencia de otra sucursal (OQ-4). Informarlo al PO.
- [ ] 12.6 **[PO]** Humo real:
  - en una cuenta con dos sucursales, una venta sin tocar el selector queda en la principal;
  - el Tablero filtrado por la principal incluye las ventas históricas;
  - en una cuenta sin módulo, la venta queda en su "Casa Central".

## Evidencia TDD

| Tarea | Test / gate | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|-------------|------|------------|-----|-------|---------------|----------|
| 1.x/2.x | `supabase/tests/test_ventas_sucursal_por_defecto.sql` (0)-(6), (3b), (8b), (9b) | SQL | 24 gates SQL del orden de CI en verde (baseline) antes de tocar nada; `pytest -k sales` 85; vitest 54 archivos / 421 tests | gate parte A contra los cuerpos vivos: 38 líneas FAIL por la razón correcta ((0) md5/COMMENT, (1)-(3) persistencia, (3b)/(4) guard, (5a/5b) edición, (6a/6b) caja y banco, (9b)); exit 3 | gate parte A contra la migración 20261075000001: todos los bloques PASS (`GATE ... (parte A) PASSED`); aplicada dos veces, la segunda toma la rama de reaplicación (3 `NOTICE`) con `schema_snapshot` idéntico | alta v2 y wrapper, producto y servicio, rama legacy, más antigua cerrada, sin sucursal operativa, edición NULL informado y residual, caja y banco; 6 mutaciones M1-M4, M9, M9b detectadas con mensaje propio (BEGIN/ROLLBACK) | diff de cada cuerpo contra el vivo = sólo los cambios de D2 más comentarios; md5 antes (`ae7e818e…`/`577f86d2…`/`23f9f29a…`) y después (`52acb873…`/`e5185557…`/`9fde6d95…`) |
| 1.4 | `supabase/tests/test_ventas_formulario_sucursal.sql` bloques 2 y 6 | SQL | `test_ventas_formulario_sucursal.sql` verde antes de editarlo | bloques 2 y 6c afirman el comportamiento viejo (sin sucursal queda NULL), que este change invierte: se reescriben a propósito junto con el RED de 1.3 | gate actualizado: verde contra los cuerpos nuevos | caracterización explícita de la nueva semántica (sin sucursal = principal) en alta y edición | cabecera y comentarios del gate puestos al día |
| 3.x | `test_ventas_sucursal_por_defecto.sql` (7), (8), (9) | SQL | gate parte A verde | parte B sin la migración de datos: `No such file or directory` (exit 3), después con la migración y los asserts sobre cada regla de D6 | parte B verde (`GATE ... (parte B, primera corrida) PASSED`); la segunda corrida del archivo asigna 0 ventas (idempotente) | 5 reglas D6, filtro de operativa sólo en 3-5, residuo NULL, movimientos completados sólo con origen demostrable, auditoría por cuenta con sus contadores; 7 mutaciones M5, M5b, M6, M6b, M7, M8, M8b detectadas | backfill reescrito set-based con tablas temporales: 50.000 filas NULL en 24 s (antes 6 m 17 s por subconsultas correlacionadas) |
| 5.1 | `__tests__/lib/default-branch.test.ts` | Unit | — | `default-branch.test.ts`: falla al importar el helper inexistente (no tests) | 8 tests verdes | lista vacía, primera activa, una sola, saltea una o varias cerradas, todas cerradas (fallback de `c26_default_branch`), respeta el orden de entrada e inactiva | — |
| 5.2 | `use-cash-optin`, `RegisterPaymentForms-cash-optin`, `purchase-form-cash-optin` | Hook / Componente | tests de `use-cash-optin` y de los modales de cobro/compra verdes | `use-cash-optin-default-branch.test.ts`: 1 de 4 falla (con la más antigua cerrada la efectiva era ella) | 4 de 4; `RegisterPaymentForms-cash-optin` y `purchase-form-cash-optin` siguen verdes | sucursal explícita, principal viva, más antigua cerrada y sin sucursales | — |
| 5.3 | `use-default-branch-notice` | Hook | `use-default-branch-notice` verde | 1 de 7 falla: la más antigua CERRADA se anunciaba como principal (`branches[0]`) | nombra a la principal del servidor; el test del toast vigente sigue verde | sin valor previo, mismo id, id distinto, carga, la más antigua cerrada, cierre de una posterior sin cambio de principal y cuenta sin sucursales | — |
| 5.4 | POS (`pos-*`) | Componente | tests del POS verdes | `pos-default-branch.test.tsx`: 2 de 4 fallan (caja y enlace «Ir a caja de …» apuntaban a la cerrada) | 4 de 4 | con la más antigua cerrada se busca la caja en la siguiente operativa, el enlace y el `branch_id` enviado | — |
| 6.1 | `BranchSelect` | Componente | `BranchSelect` y `SaleCheckoutFields` verdes | `BranchSelect-sin-sucursal.test.tsx`: 9 de 13 fallan (props nuevas inexistentes) | 13 de 13 y los tests vecinos (29 tests en los dos archivos de la corrida) | `allowUnassigned={false}`, `fallbackBranchId` sin pisar un valor explícito, carga, sin sucursales, rótulo propio, principal cerrada | valores por defecto de las props sin cambio de comportamiento para compra, gasto e importador |
| 6.2 | `sale-form-branch-create` | Componente | `sale-form-branch-create` verde | 1 de 6 falla (el formulario ofrecía «Sin sucursal (general)») | 6 de 6, incluido «elegir B y después volver a la principal» | alta con la principal preseleccionada, elegir B, volver a la principal y cuenta sin módulo (sin selector); la edición con la sucursal de cada venta la cubren `sale-form-edit-context` y el humo | — |
| 6.3 | `operation-errors-branch` | Unit | `operation-errors-branch` verde | los casos nuevos de `no_branch_found` fallan: el token pasaba tal cual (el test viejo lo fijaba y se reescribe a propósito) | `no_branch_found` se traduce a «No encontramos una sucursal activa en la cuenta…» (texto reutilizado de `use-promote-to-order`) | token crudo, envuelto por el mapeo RFC 7807 y sin confundirlo con `branch_not_found` | — |
| 7.1/7.2 | `backend/tests/test_sales_branch_id.py` (+ `test_schema_branch_id_documents_that_no_branch_means_the_principal`) | Unit | pytest de ventas verde (85) | el test de la descripción del campo `branch_id` afirma el texto nuevo y falla contra el viejo | pasa con la descripción nueva (sin sucursal = principal) | el alta y la edición siguen transportando `None` y el tri-estado `p_branch_provided` sin cambio | suite completa: 3640 passed, 1 skipped, 93 deselected, cobertura 95,07 % |
