> **Governance MEDIA con tramo ALTO.** Se reescriben las tres funciones que mueven stock, caja y banco en el alta y la edición de ventas, y una migración de datos actualiza en masa `sales.branch_id` y `stock_movements.branch_id` en producción.
>
> **Un solo PR**: funciones, datos, frontend, gates y specs. Lo **mergea el PO**, porque lleva una migración de datos.
>
> **TDD estricto**: cada grupo de producción abre con su RED (un test o gate que falla por la razón correcta) y deja evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR, nunca a `main`. Conventional commits en español.
> - Toda RPC se reescribe desde su `pg_get_functiondef` **vivo de producción**, con la misma firma (`CREATE OR REPLACE`, sin `DROP`), conservando el `COMMENT` y re-emitiendo las ACLs.
> - Nada contra producción salvo lo que ejecuta o autoriza el PO (grupos 0 y 12). Nunca el MCP `apply_migration`: las migraciones van por el `supabase db push` del pipeline.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [ ] 0.1 **[PO]** Sign-off de OQ-1..OQ-4 (`design.md` §Open Questions). Registrar la respuesta textual en una sección "Sign-off del PO" del `design.md`. Sin respuesta, el apply adopta la recomendación de cada OQ: (a) en las cuatro. Si el PO elige otra opción, actualizar en el mismo PR la decisión, las specs y estas tareas.
- [ ] 0.2 **[PO ejecuta o autoriza]** Checkpoint del cuerpo **vivo de producción**, antes de escribir una línea de SQL:
  - `pg_get_functiondef`, `obj_description` y `proacl` de:
    - `rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)`;
    - `rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid, date)`;
    - `rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean, uuid, boolean, text, boolean)`.
  - Sólo para leer: `c26_default_branch(uuid)`, `op_stock_movement`, `rpc_reverse_stock_movement`, `rpc_promote_legacy_sale_to_order(uuid)` y `_sales_order_sync_from_operation(uuid, uuid, uuid)`.
  - Comparar por líneas, sin `\r` (gotcha CRLF), contra el local y contra `20261062000001_ventas_unidades_conversion.sql` (L330-699, L2629-3044 y L1594-2262).
  - Referencia local (`md5` del cuerpo sin `\r`, base local con 313 migraciones):

    | Función | `md5` |
    |---|---|
    | v2 | `6bbf5833592896ce493d3b933dd62b4e` |
    | wrapper | `92a2a3452c07dbbee3a99114f55ed469` |
    | edición | `954a5c8fb31202259c82485d0c6e05b9` |
    | `c26_default_branch` | `5fa1096b4c1481b36d6e04c8eaadbfdc` |

  - `COMMENT` esperado: la edición tiene uno; la v2 y el wrapper, ninguno.
  - ACL esperada: `postgres`, `authenticated` y `service_role` con `EXECUTE`, y `anon` sin `EXECUTE`.
  - Si algo diverge, se reescribe sobre el **vivo** y se anota acá el desvío.
- [ ] 0.3 Confirmar que `20261069000001` y `20261069000002` siguen libres: `ls supabase/migrations`, `gh pr list --state open` y `MAX(version)` de producción (lo lee el PO). `presupuestos-modulo` reserva `20261067000001`/`20261068000001`. Si ya mergeó, nuestras dos van después en la cadena de CI. Renumerar si hace falta.
- [ ] 0.4 Re-verificar sobre `main` actualizado el inventario de escritores de `sales`: las funciones vivas con `INSERT INTO public.sales` (v2, wrapper, edición, `_c29_confirm_order_core` y los dos `rpc_atomic_create_sale` legacy, sólo `service_role`) y los `UPDATE` (`rpc_safe_delete_product`). Grep de escrituras directas en `backend/`, `frontend/` y `supabase/functions/`. Anotar cualquier escritor nuevo que no esté en el design.
- [ ] 0.5 SAFETY NET. Correr y registrar el baseline:
  - **Backend**: `backend/tests/test_sales.py`, `test_sales_branch_id.py`, `test_sale_items.py`.
  - **Frontend**: `__tests__` de `sale-form*`, `use-sales*`, `use-cash-optin*`, `use-purchases-cash-optin*`, `use-default-branch-notice*`, `branches*`, `operation-errors*`, `pos-operation-errors*`, `purchase-form*`, `expense-form*`, `expense-import-dialog*`.
  - **Gates SQL**: `test_ventas_formulario_sucursal.sql` y los 23 de `supabase/tests/` que nombran `rpc_create_sale_operation`, `rpc_create_sale_operation_v2` o `rpc_atomic_update_sale_operation`. En particular:
    - `test_confirm_core_integrity.sql`, `test_cuenta_corriente_party_guard.sql`, `test_operacion_party_guard.sql`;
    - `test_pos_rpc_signatures.sql`, `test_cobranzas_vencimientos_schema.sql`;
    - `test_ventas_unidades_conversion.sql`, `test_edicion_preserva_contexto.sql`, `test_facturar_venta_manual.sql`, `test_stock_movements_edicion.sql`, `test_operation_edit_lines.sql`;
    - `test_function_acl_gate.sql`.

  Una falla previa se reporta como preexistente y no se corrige acá.

## 1. RED — gate SQL de las funciones (antes de tocarlas)

- [ ] 1.1 Escribir `supabase/tests/test_ventas_sucursal_por_defecto.sql` con los bloques (0)-(6), (8) y (9) de `design.md` D13 (el bloque (7), del backfill, va en el grupo 3). Patrón del proyecto:
  - fallos acumulados en `text[]` y un solo `RAISE` al final;
  - anchors sintéticos vía `handle_new_user`;
  - `created_at` explícito y estrictamente posterior en las sucursales sintéticas, asertado (`c26_default_branch` no desempata);
  - limpieza de toda fila con el `account_id` de los anchors.
- [ ] 1.2 Fixtures:
  - cuenta con A (principal) y B, productos con stock en las dos y producto de servicio (línea sin `product_id`);
  - flag `sale_items_rpc_v2 = false` para la cuenta del bloque (2);
  - A cerrada (`status = 'closed'`, `is_active` intacto) para el bloque (3);
  - cuenta sin ninguna sucursal para el bloque (4), borrando con `session_replication_role = replica` para esquivar `trg_guard_branch_decommission`;
  - fila residual con `branch_id NULL`, insertada directo, para la edición sin informar del bloque (5);
  - forma de pago bancaria con cuenta destino para el bloque (6).
- [ ] 1.3 Correr el gate contra los cuerpos **actuales** y registrar el RED. Esperado:
  - (0) falla porque los `INSERT` persisten `p_branch_id`;
  - (1), (2), (3) y (6) fallan con `branch_id NULL`;
  - (4) falla porque la venta de servicio pasa con `NULL` y la de producto da `P0409` en vez de `P0422 no_branch_found`;
  - (5) falla con la fila resultante en `NULL`.
- [ ] 1.4 Actualizar **a propósito** `supabase/tests/test_ventas_formulario_sucursal.sql`:
  - el bloque 2 pasa a «sin sucursal elegida: `sales.branch_id` y `stock_movements.branch_id` = principal, stock de la principal»;
  - el bloque 6c pasa a «venta, movimiento de stock y movimiento bancario en la **misma** principal»;
  - el encabezado cita `ventas-sucursal-por-defecto` en lugar de "decisión del PO pendiente".

  Correr contra los cuerpos actuales y registrar el RED.

## 2. GREEN — `supabase/migrations/20261069000001_ventas_sucursal_por_defecto.sql` (funciones)

- [ ] 2.1 Escribir la migración partiendo de los cuerpos vivos de 0.2, con **sólo** los cambios de `design.md` D2:
  - **v2**: `v_gate_branch` en los tres `INSERT` (sales con producto, sales de servicio, `stock_movements`) y guard `P0422 no_branch_found` después de resolver `v_gate_branch`, antes del `INSERT` en `operation_idempotency`.
  - **Rama legacy del wrapper**: los mismos tres cambios y el mismo guard. La rama de delegación no se toca.
  - **Edición**: `v_final_branch_id := COALESCE(v_final_branch_id, public.c26_default_branch(v_account_id))` y el guard, después del tri-estado y **antes** del REVERSE.

  Cabecera de la migración con contexto, decisión del PO, reglas y referencias. Un comentario `-- ventas-sucursal-por-defecto (Dn):` en cada punto tocado.
- [ ] 2.2 Re-declarar el `COMMENT` vivo de la edición (sin `COMMENT` nuevo en v2 ni wrapper si el vivo no lo tiene) y re-emitir las ACLs: `REVOKE ALL … FROM PUBLIC, anon` más `GRANT EXECUTE … TO authenticated, service_role`, idénticas a las vivas.
- [ ] 2.3 Diff del cuerpo nuevo contra el vivo, por función y sin `\r`. Tiene que ser **exactamente** los cambios de D2 más los comentarios. Adjuntar el diff como evidencia en el PR.
- [ ] 2.4 Aplicar en la base local y correr el gate. Tienen que quedar GREEN:
  - bloques (0)-(6), (8) y (9) de `test_ventas_sucursal_por_defecto.sql`;
  - `test_ventas_formulario_sucursal.sql` completo.
- [ ] 2.5 Mutaciones sobre los cuerpos locales, dentro de una transacción con `ROLLBACK`. Cada una tiene que ser detectada por el gate con un mensaje propio:
  - M1: v2 con `p_branch_id` crudo en `sales`;
  - M2: la rama legacy con `p_branch_id` crudo;
  - M3: v2 con `p_branch_id` crudo en `stock_movements`;
  - M4: edición sin el `COALESCE`.

  Registrar los mensajes.
- [ ] 2.6 Idempotencia: reaplicar el archivo dos veces sobre la base local y verificar que el fingerprint de esquema no cambia. Es el mismo `schema_snapshot` del paso "Verify … idempotent on reapply" de `KPI_Validation.yml`.
- [ ] 2.7 Correr todos los gates de 0.5. En particular, `test_confirm_core_integrity.sql` (3) por las subcadenas de la v2, `test_cuenta_corriente_party_guard.sql` (3.8-v2) y `test_operacion_party_guard.sql` por el guard de cliente, `test_pos_rpc_signatures.sql` (1d) por una sola firma, y `test_function_acl_gate.sql`. Todos verdes.

## 3. Backfill — `supabase/migrations/20261069000002_ventas_sucursal_por_defecto_backfill.sql` (datos)

- [ ] 3.1 RED: agregar el bloque (7) al gate, con fixtures para cada caso de D6:
  - mono-sucursal;
  - multi-sucursal;
  - venta con `sales_orders` en B aunque la principal sea A;
  - operación mixta (una fila en B, otra `NULL`);
  - fila con `account_id NULL`;
  - venta borrada cuyo movimiento original y cuya reversa quedaron `NULL`;
  - movimientos `'sale'` `NULL` de las ventas vivas.

  Registrar los conteos de `events`, `notifications`, `analytics_events`, `cash_movements`, `bank_movements`, `customer_account_movements` y `journal_entries` antes de la corrida. Ejecutar el archivo de datos con `\i` (todavía inexistente o vacío) y registrar el RED.
- [ ] 3.2 GREEN: escribir la migración de datos (sin DDL, sin funciones, sin ACLs). Cabecera con:
  - la decisión textual del PO;
  - las reglas de D6;
  - por qué no hace falta medir antes (D6, D7);
  - la idempotencia y la regla de que nunca aborta por datos.

  En un bloque `DO`:
  - tomar las candidatas (`branch_id IS NULL AND account_id IS NOT NULL`) con `FOR UPDATE` en **orden ascendente de `id`**, para respetar el orden global de locks del proyecto;
  - resolver la sucursal por regla: orden → operación → principal vigente;
  - `UPDATE sales`;
  - `UPDATE stock_movements` sólo de los movimientos `reference_type = 'sale'` de las ventas asignadas en esta corrida, con `branch_id NULL`;
  - una fila de `audit_logs` por cuenta afectada (`action = 'sales_branch_backfill'`, `entity_type = 'account'`, `user_id NULL`, `metadata` con `sale_ids`, `movement_ids`, conteo por regla, `branch_ids` y `evidencia_otra_sucursal`), sólo si la cuenta tuvo filas asignadas;
  - `NOTICE` con:
    - los conteos por regla;
    - los movimientos actualizados;
    - el residuo (sin cuenta, o cuenta sin sucursal);
    - las ventas asignadas cuyo movimiento de caja (`cash_movements.reference_id` = operación → `cash_sessions` → `cashboxes.branch_id`) o de banco (`bank_movements.source_doc_type = 'sale'`, `source_doc_ref` = operación) registró **otra** sucursal (OQ-4).
- [ ] 3.3 Correr el bloque (7) ejecutando el archivo **dos veces**. Verificar:
  - cada caso de D6;
  - la segunda corrida no cambia filas ni escribe auditoría;
  - los conteos de efectos laterales quedan iguales.

  Después correr los bloques (8) (`rpc_promote_legacy_sale_to_order` **ejecutada** sobre la operación antes mixta) y (9) (`rpc_delete_sale_operation` **ejecutada** repone en la sucursal asignada).
- [ ] 3.4 Mutaciones, con `ROLLBACK`, detectadas por el gate:
  - M5: el backfill sin la pata de `stock_movements`;
  - M6: el backfill sin la regla de la orden.
- [ ] 3.5 Medir en la base local el tiempo del backfill sobre un volumen sintético (por ejemplo, 50.000 filas `NULL` en varias cuentas) para acotar la ventana de locks por fila. Anotar el resultado en el PR. No hace falta medir producción (D7).

## 4. CI

- [ ] 4.1 `.github/workflows/KPI_Validation.yml`: sumar `20261069000001` y `20261069000002` **al final** de la cadena de reaplicación del paso "Verify … idempotent on reapply", después de `20261066000001` y, si ya mergearon, de `20261067000001`/`20261068000001`.
- [ ] 4.2 Cablear `supabase/tests/test_ventas_sucursal_por_defecto.sql` como paso propio. `test_ventas_formulario_sucursal.sql` mantiene su paso.
- [ ] 4.3 Confirmar en la corrida de CI que el bloque (0) del gate nuevo pasa **después** de la cadena de reaplicación. Ninguna reaplicación posterior puede dejar vivo un cuerpo viejo (lección de `candidatos-db-backend`).

## 5. Frontend — una sola "principal" en el cliente

- [ ] 5.1 RED/GREEN de `frontend/lib/default-branch.ts`, `resolveDefaultBranch(branches: Branch[]): Branch | null`, con `__tests__/lib/default-branch.test.ts`. Casos:
  - lista vacía → `null`;
  - la primera con `status === "active"`;
  - la más antigua cerrada se saltea;
  - todas cerradas → la primera;
  - respeta el orden de entrada (el de `useBranches`, `created_at` ascendente).
- [ ] 5.2 `hooks/use-cash-optin.ts`: `effectiveBranchId = branchId || resolveDefaultBranch(branches)?.id || null`. RED primero: con la más antigua cerrada, la sucursal efectiva tiene que ser la segunda. Los tests existentes siguen verdes, y también `use-purchases-cash-optin` y el gasto, que consumen el mismo hook.
- [ ] 5.3 `hooks/use-default-branch-notice.ts`: `resolveDefaultBranch(branches)` en lugar de `branches[0]`. RED primero: con la más antigua cerrada, no se anuncia como principal.
- [ ] 5.4 Grep de `branches[0]` en `frontend/` usado como "sucursal por defecto". Migrar al helper o justificar cada uno en el PR.

## 6. Frontend — selector de la venta

- [ ] 6.1 RED/GREEN de `components/branches/BranchSelect.tsx`, con la prop `allowUnassigned?: boolean` (por defecto `true`):
  - con `true`, opciones y comportamiento idénticos a hoy (test de regresión con la opción "Sin sucursal (general)");
  - con `false`: sin la opción `__none__`, valor mostrado `value ?? resolveDefaultBranch(branches)?.id`, la principal rotulada "Nombre (principal)", y `onChange` emite el id elegido;
  - sigue sin renderizarse sin módulo de sucursales.
- [ ] 6.2 RED/GREEN de `components/forms/sale-form.tsx`:
  - rótulo "Sucursal" asociado al control (`Label` con `htmlFor`/`id`) y `allowUnassigned={false}`;
  - **alta** sin tocar el selector: el payload lleva `branch_id: null` y el selector muestra la principal;
  - **alta** eligiendo B: viaja el id de B;
  - **edición** precarga la sucursal de la venta;
  - **edición** de una venta con `branchId` nulo: muestra la principal.

  Actualizar `frontend/__tests__/components/sale-form-branch-create.test.tsx`: el caso «elegir y volver a "Sin sucursal"» desaparece y lo reemplaza «elegir la principal en la lista», que manda su id. Validar por mutación que los casos fallan sin el cambio.
- [ ] 6.3 RED/GREEN de `lib/operation-errors.ts`: traducir `no_branch_found`, con un mensaje accionable del tipo «Tu cuenta no tiene ninguna sucursal operativa: creá o reabrí una desde Sucursales», sin romper los casos `branch_closed`, `branch_not_found`, `branch_invalid` ni el stock insuficiente con su acción de transferir. El `friendlyError` del POS no se toca.
- [ ] 6.4 Actualizar el comentario de `hooks/data/use-sales.ts` (cerca de L237: «null = "Sin sucursal (general)"») y los demás comentarios del frontend que afirmen que una venta sin sucursal queda `NULL`.
- [ ] 6.5 Regresión de compra, gasto e importador de gastos: sus tests verdes y la opción "Sin sucursal (general)" presente.
- [ ] 6.6 `pnpm vitest run` de los archivos afectados y vecinos, y `tsc --noEmit` sin errores nuevos respecto del baseline.

## 7. Backend (sin cambio de lógica)

- [ ] 7.1 Corregir los comentarios que afirman que `None` conserva `branch_id` NULL: `backend/services/sales.py` cerca de L147 y `backend/schemas/sales.py` cerca de L50-56. Agregar a `SaleOperationIn.branch_id` y `SaleOperationUpdateIn.branch_id` la descripción de OpenAPI: «sin sucursal, la venta se registra en la sucursal principal de la cuenta».
- [ ] 7.2 Confirmar con los tests existentes (`test_sales_branch_id.py`) que el alta y la edición transportan `None` y el tri-estado (`p_branch_provided`) sin cambios. No se agregan tests de comportamiento, porque no lo hay: la resolución es de la RPC y la cubre el gate.
- [ ] 7.3 Correr la suite completa con el comando de CI (`pytest backend/tests -m "not integration" --cov=backend`). Cobertura ≥ 87 %.

## 8. Verificación visual (superficie frontend)

- [ ] 8.1 Formulario de venta en alta y edición. Cuenta con módulo y dos sucursales, y cuenta sin módulo (selector oculto). Combinaciones:
  - escritorio (1280 px) y móvil (375 px);
  - tema claro y tema oscuro.

  Verificar:
  - rótulo "Sucursal", principal preseleccionada y marca "(principal)" con contraste AA (tokens semánticos, sin colores literales);
  - lista sin "Sin sucursal (general)";
  - sin desborde horizontal a 375 px.

  Adjuntar capturas.
- [ ] 8.2 Formularios de compra y de gasto en las mismas combinaciones: la opción "Sin sucursal (general)" sigue igual.

## 9. Humo en el stack local

- [ ] 9.1 Levantar el stack local: Supabase con las migraciones de la rama, `uvicorn` desde el worktree y `pnpm dev`. Usar una cuenta Pro con A (principal) y B y una cuenta sin módulo de sucursales, y verificar cada caso con `psql`.
  - **H1**: venta sin tocar el selector → `sales` y `stock_movements` en A, stock de A.
  - **H2**: eligiendo B → B.
  - **H3**: cuenta sin módulo → su "Casa Central".
  - **H4**: `PUT /sales/{id}` con `branch_id: null` → A.
  - **H5**: `POST /sales` sin el campo → A.
  - **H6**: ventas `NULL` creadas con el código de `main` y después la migración de datos → asignadas, con fila en `audit_logs`.
  - **H7**: Tablero filtrado por A suma las ventas de H1 y H6.
  - **H8**: cerrar la sucursal más antigua (sin stock) → el selector preselecciona la siguiente, el opt-in de caja busca su sesión, el aviso de sucursal por defecto la nombra y una venta sin tocar el selector queda en ella.

## 10. Specs, KB y documentación

- [ ] 10.1 Correr `openspec validate "ventas-sucursal-por-defecto" --strict` y `openspec validate --specs --strict`.
- [ ] 10.2 `knowledge-base/05_reglas_de_negocio.md` (RN-93): nota de que la venta la cumple desde este change (alta, edición e históricos) y de que compras queda pendiente (OQ-3).
- [ ] 10.3 Al archivar (no en el apply):
  - **`CHANGES.md`**: ficha con la verificación posterior y los candidatos que deja:
    - `NOT NULL` en `sales.branch_id` con retiro de los `rpc_atomic_create_sale` muertos y FK `RESTRICT` (D8);
    - `compras-gastos-sucursal-por-defecto` (OQ-3);
    - sucursal principal configurable (OQ-1);
    - disparador de defensa en profundidad (D1, alternativa A);
    - gate de stock de la edición contra la sucursal efectiva (candidato (d) de #606).
  - **`CLAUDE.md`**: puntero y `python scripts/ci/check_docs_sync.py --fix` para `AGENTS.md`.

## 11. PR y merge

- [ ] 11.1 PR con commits convencionales y CI verde: `validate-kpis` con el gate nuevo y la reaplicación, Backend, Frontend, E2E y Docs Sync.
- [ ] 11.2 Revisión adversarial con un solo juez por ronda (tope de agentes del workflow) sobre: el diff de funciones contra el vivo, el orden de locks del backfill, la idempotencia, la paridad v2/legacy y la superficie frontend.
- [ ] 11.3 **[PO]** Merge. Los sub-agentes no mergean migraciones de datos.

## 12. Verificación posterior al merge (producción, sólo lectura; la ejecuta o autoriza el PO)

- [ ] 12.1 `deploy.yml` verde, con `MAX(version)` igual a `20261069000002` (o la última de la cadena). Vercel desplegado. Render: `GET /deploys` del commit del merge, y `POST /deploys` si falta (el auto-deploy no siempre dispara).
- [ ] 12.2 En los cuerpos vivos de las tres funciones, la persistencia resuelta y el guard están presentes. La edición conserva su `COMMENT`. Las ACLs no cambiaron y hay una sola firma por función.
- [ ] 12.3 `SELECT count(*) FROM sales WHERE branch_id IS NULL` tiene que coincidir con el residuo que informó la migración. Además, las filas `NULL` con `created_at` posterior al deploy tienen que ser 0. Si hay alguna (ventana de ventas en vuelo), **[PO]** re-ejecutar el bloque idempotente del archivo de datos con `npx supabase db query --linked`.
- [ ] 12.4 Cero movimientos `reference_type = 'sale'` con `branch_id NULL` cuya venta exista.
- [ ] 12.5 Filas `audit_logs` con `action = 'sales_branch_backfill'`: cantidad de cuentas, total de ventas y movimientos asignados, y el conteo de evidencia de otra sucursal (OQ-4). Informarlo al PO.
- [ ] 12.6 **[PO]** Humo real:
  - en una cuenta con dos sucursales, una venta sin tocar el selector queda en la principal;
  - el Tablero filtrado por la principal incluye las ventas históricas;
  - en una cuenta sin módulo, la venta queda en su "Casa Central".

## Evidencia TDD

| Tarea | Test / gate | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|-------------|------|------------|-----|-------|---------------|----------|
| 1.x/2.x | `supabase/tests/test_ventas_sucursal_por_defecto.sql` (0)-(6), (8), (9) | SQL | | | | | |
| 1.4 | `supabase/tests/test_ventas_formulario_sucursal.sql` bloques 2 y 6 | SQL | | | | | |
| 3.x | `test_ventas_sucursal_por_defecto.sql` (7) | SQL | | | | | |
| 5.1 | `__tests__/lib/default-branch.test.ts` | Unit | | | | | |
| 5.2 | `use-cash-optin` | Hook | | | | | |
| 5.3 | `use-default-branch-notice` | Hook | | | | | |
| 6.1 | `BranchSelect` | Componente | | | | | |
| 6.2 | `sale-form-branch-create` | Componente | | | | | |
| 6.3 | `operation-errors-branch` | Unit | | | | | |
