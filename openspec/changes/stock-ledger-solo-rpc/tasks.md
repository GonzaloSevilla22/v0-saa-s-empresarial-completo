> **Governance: ALTA.** Los grupos marcados 🛑 revocan privilegios o reescriben una RPC que mueve stock:
> se para, se muestra lo hecho y se sigue sólo con visto bueno. El resto es autónomo.
>
> **TDD estricto** en SQL, backend y frontend: test que falla **visto fallar** → mínimo código → triangular →
> refactor. Nunca aserciones triviales. Todo gate negativo exige **control positivo** del mismo camino.
>
> **Toda commit vía PR, jamás a `main`.** Ramas: `opsx/stock-ledger-solo-rpc-apply-a` (tanda A) y
> `opsx/stock-ledger-solo-rpc-apply-b` (tanda B, recién con la tanda A verificada en prod).
>
> **Sign-off del PO (2026-10-08, "firmo el candidato con las recomendaciones"):** roles `owner`/`admin`/`stock`;
> el alta deja "Stock inicial" sola y la edición deriva al modal (D9); tanda A = G1 sola, tanda B = el resto;
> backfill ya hecho por #617; importador → ledger fuera de alcance. OQ-1/OQ-2/OQ-3 del design: implementadas
> según su recomendación salvo que el PO objete antes del apply de la tanda B.
>
> **Hasta que la tanda B esté en prod, el ajuste sin rol por `rpc_apply_product_stock_delta` (incluido
> `p_log_movement = false`) sigue abierto.** La tanda A cierra la forja y la reversa pública, no eso.

# Tanda A — G1: cerrar la escritura directa (`20261073000001`)

## 1. Checkpoint de estado y controles por construcción (ANTES de escribir una línea de SQL)

- [ ] 1.1 `git fetch origin main` + rebase de la rama. Re-verificar `MAX(version)` en prod (`supabase_migrations.schema_migrations`, sólo lectura) y el último archivo de `supabase/migrations/` en `origin/main`; confirmar que `20261073000001` sigue libre (los changes de remitos en curso pueden haberlo tomado — si es así, renumerar y anotarlo).
- [ ] 1.2 Re-leer en prod `relacl` y `pg_policies` de `branch_stock`/`stock_movements`, `proacl` de `rpc_reverse_stock_movement` y el barrido de callers por `pg_get_functiondef` (query del Context del design). Cualquier diferencia con el design → parar y reportar.
- [ ] 1.3 Grep del repo (`frontend/`, `backend/`, `supabase/functions/`, `scripts/`, migraciones de ramas de remitos abiertas) por escrituras directas a las dos tablas (`.from("branch_stock"|"stock_movements").insert/update/upsert/delete`, `INSERT INTO/UPDATE/DELETE` fuera de funciones) y por llamadas a `rpc_reverse_stock_movement`. Esperado: 0 fuera de funciones `SECURITY DEFINER`.
- [ ] 1.4 Stack local (`supabase db reset` completo). Control (i): como `viewer`, forjar una fila `reference_type='sale'` y llamar a `rpc_reverse_stock_movement` ⇒ el stock **sube**. Log en `openspec/changes/stock-ledger-solo-rpc/evidence/logs/`.
- [ ] 1.5 Control (ii), que discrimine: como `seller`, `PATCH`/`UPDATE` de `branch_stock` a un valor **distinto** del actual ⇒ hoy pasa. Log.
- [ ] 1.6 Control (iii): como escritor de la cuenta A, insertar `branch_stock (A, producto de B, sucursal de B, 0)`; después una compra de B de ese producto en esa sucursal ⇒ verificar si `c21_apply_branch_stock_delta` acumula en la fila de A (invisible para B). Log con el resultado, sea cual sea.
- [ ] 1.7 Revisar cómo invocan `rpc_reverse_stock_movement` los gates existentes (`test_stock_movements_edicion.sql` L431/L454/L524): si lo hacen bajo `SET LOCAL ROLE authenticated`, se migran a borrar la operación por su RPC de borrado (el camino real); si corren como `postgres`, no cambian. Anotar el resultado.

## 2. Gate nuevo — RED

- [ ] 2.1 Crear `supabase/tests/test_stock_ledger_solo_rpc.sql` (molde `test_accounts_privilege_columns.sql`, `BEGIN … ROLLBACK`, usuarios `@test.local`, degrade-don't-fail sólo en la fixture) con los bloques **(a)** metadata de privilegios, **(b)** forma exacta de las policies, **(c)** ACL de la reversa, **(d)** matriz de evasión bajo `SET LOCAL ROLE authenticated` con owner, `seller` y `viewer` (`INSERT`, `UPDATE`, `UPDATE … RETURNING`, `INSERT … ON CONFLICT DO UPDATE`, `DELETE`, `TRUNCATE` sobre las dos tablas, ocupación cross-tenant, llamada a la reversa) exigiendo `42501` **y** texto `permission denied` (no el de RLS), con huella de las dos tablas idéntica antes/después, y **(e)** control positivo de los caminos legítimos (ajuste, alta y borrado de venta y de compra —incluida compra ya vendida—, transferencia, borrado de producto con historial, lectura propia sí / ajena no).
- [ ] 2.2 Correr el gate contra la base en HEAD (sin la migración): **RED visto** en (a), (b), (c) y en la forja/upsert/ocupación de (d); (e) verde. Pegar la salida en el log de evidencia.

## 3. 🛑 Migración de la tanda A — GREEN

- [ ] 3.1 Crear `supabase/migrations/20261073000001_stock_ledger_cierre_escritura_directa.sql` con cabecera (procedencia, medición, sign-off, residuo abierto hasta la tanda B): los tres `DROP POLICY IF EXISTS`, los dos `REVOKE INSERT, UPDATE, DELETE, TRUNCATE … FROM anon, authenticated` y el `REVOKE EXECUTE` de `rpc_reverse_stock_movement(uuid, text, text)` `FROM PUBLIC, anon, authenticated` (D2). Sin `CREATE OR REPLACE` de ninguna función. `COMMENT ON TABLE` de las dos tablas actualizado. LF, sin CR.
- [ ] 3.2 `supabase db reset` completo → gate **GREEN** en los cinco bloques.
- [ ] 3.3 Reaplicar el archivo dos veces sobre la base migrada: sin error, mismo estado (idempotencia).

## 4. Gates existentes y cableado

- [ ] 4.1 `supabase/tests/test_remitos_venta.sql` bloque (f) (~L744-762): invertir el control positivo — la fila forjada **debe** fallar con `42501` y **no** existir; conservar las aserciones posteriores del bloque (la edición devuelve exactamente lo retenido). Rebasar justo antes de editar (riesgo R3: el archivo es de `remitos-venta`).
- [ ] 4.2 `supabase/tests/test_remitos_compra.sql` bloque (f) (~L898-914): ídem.
- [ ] 4.3 `supabase/tests/test_is_account_writer_pivot.sql`: 45 policies / 18 tablas → **43 / 17**, con la línea de mantenimiento en la cabecera (este change retira `branch_stock_writer_insert`/`_update`). Re-contar en el stack local antes de fijar el número.
- [ ] 4.4 `supabase/tests/test_function_acl_gate.sql`: sumar `'public.rpc_reverse_stock_movement(uuid, text, text)'` a `v_internal_only_fns`, con su comentario de procedencia.
- [ ] 4.5 Cablear `test_stock_ledger_solo_rpc.sql` en `.github/workflows/KPI_Validation.yml` (`psql -v ON_ERROR_STOP=1`).
- [ ] 4.6 Batería completa en el stack local: los cinco gates de arriba + `test_stock_movements_edicion.sql`, `test_stock_adjustment_account_branch.sql`, `test_branch_stock.sql`, `test_ventas_unidades_conversion.sql`, `test_unidades_decisiones_8_9.sql`, `test_remito_a_venta.sql` y los `.sh` de carrera que tocan stock. Todo verde; `pytest` del backend como sanity.

## 5. PR de la tanda A, verificación post-merge y humo

- [ ] 5.1 Commit `fix(stock): …` + PR. La descripción declara qué queda abierto hasta la tanda B y enlaza la evidencia de 1.4-1.6 y 2.2.
- [ ] 5.2 Post-merge, sólo lectura en prod: `MAX(version) = 20261073000001`; `relacl` de las dos tablas sin `a`/`w`/`d`/`D` para `authenticated` ni `anon`; `pg_policies` = las cuatro esperadas; `proacl` de `rpc_reverse_stock_movement` sin `authenticated`; deploy de Render confirmado.
- [ ] 5.3 48 h de logs (PostgREST por MCP y Render por API): 0 `permission denied`/`42501` inesperados sobre las dos tablas o la reversa, con control positivo de que la consulta encuentra tráfico de `rpc_stock_adjustment`.
- [ ] 5.4 Humo del PO en prod: un ajuste en `/stock`, borrar una venta y una compra de prueba (el stock vuelve), una transferencia si la cuenta tiene dos sucursales.
- [ ] 5.5 Registrar la tanda A en `CHANGES.md` (ficha del change) con PR, migración y verificación.

# Tanda B — G2 + G4 + resto de G5 + specs (`20261074000001`)

## 6. Checkpoint de la tanda B (ANTES de escribir una línea de SQL)

- [ ] 6.1 Tanda A verificada en prod (5.2-5.4). Rebase; re-verificar `MAX(version)`; confirmar `20261074000001` libre (o renumerar).
- [ ] 6.2 Re-capturar `md5(pg_get_functiondef)` de las cinco funciones del Anexo A y comparar **por líneas sin CR**. Volcar los cuerpos vivos a `openspec/changes/stock-ledger-solo-rpc/evidence/live_functiondefs/`: la reescritura parte de esos archivos, no de la transcripción del design. Divergencia → parar.
- [ ] 6.3 Re-barrer en prod y en las migraciones del repo (incluidas ramas abiertas de remitos) los callers de `rpc_apply_product_stock_delta`, `rpc_reverse_stock_movement`, `rpc_stock_adjustment`, `rpc_adjust_branch_stock` y `rpc_transfer_stock`, y los escritores de tipos manuales en `stock_movements`. Esperado: lo del Context del design.
- [ ] 6.4 Re-medir: movimientos de tipo manual sin motivo (18 al 2026-10-08), saldos ≠ 0 de padres `variant_only` (5), cuentas multiusuario (0), movimientos `transfer_in`/`transfer_out` sin `reference_type = 'transfer'` (0).
- [ ] 6.5 Stack local: reproducir el **ajuste fantasma** de la edición (abrir el producto con stock 10, vender 2, guardar un cambio de precio con el `stock = 10` viejo ⇒ hoy el saldo vuelve a 10 con "Ajuste manual de stock"). Log.
- [ ] 6.6 Stack local: un `viewer` cambia el stock por `PUT /products/{id}` ⇒ hoy pasa. Log.

## 7. Gate de la tanda B — RED

- [ ] 7.1 Extender `test_stock_ledger_solo_rpc.sql` con **(f)** rol × envoltorio (owner/admin/stock OK; seller/cashier/purchases/accountant `P0403`; viewer `P0401`; rol vencido rechazado), **(g)** motivo nulo/vacío/espacios ⇒ `P0400` en los tres + `CHECK` rechaza una inserción directa como `postgres` (`23514`) + `convalidated = false`, **(h)** flags internos ⇒ `P0400`, **(i)** tenencia (producto ajeno `P0404` en los tres envoltorios y en `rpc_transfer_stock`; segundo miembro `admin` ajusta un producto que no creó), **(j)** sello e invariante (un movimiento por ajuste, cuenta/sucursal/autor/motivo, `after = before + delta` por sucursal, visible bajo RLS sólo para su cuenta), **(k)** semántica (conteo físico total en una cuenta de dos sucursales, objetivo por sucursal, `loss` positivo, `transfer_in`, padre `variant_only`, negativo `P0409`), **(l)** reversa tras la reescritura (venta y compra reponen; compra ya vendida ⇒ piso con ajuste trazable con motivo), **(m)** ACL (internas sin `EXECUTE` de la app; envoltorios y transferencia con `authenticated` y sin `anon`; un overload de cada una).
- [ ] 7.2 Correr contra la base con la tanda A: **RED visto** en (f)-(k) y (m); (l) verde (todavía usa el cuerpo viejo). Log.

## 8. 🛑 Migración de la tanda B — GREEN

- [ ] 8.1 Crear `supabase/migrations/20261074000001_stock_ledger_nucleo_ajuste_manual.sql` (una transacción; cabecera con md5 de partida, sign-off y decisiones). `_stock_assert_can_adjust(uuid)`: calco de `_quote_assert_can_write` con `ARRAY['owner','admin','stock']` (D5); `REVOKE ALL … FROM PUBLIC, anon, authenticated`.
- [ ] 8.2 🛑 `_stock_apply_delta(uuid, uuid, numeric, uuid, boolean)` INVOKER desde el cuerpo vivo de `rpc_apply_product_stock_delta` (6.2): cuenta por parámetro, lock filtrado por cuenta, sin `p_log_movement` (nunca escribe el movimiento principal), piso en cero trazable intacto. `REVOKE ALL`.
- [ ] 8.3 🛑 `_stock_manual_adjustment(...)` INVOKER (D4-D8): tenencia por `products.account_id` con lock filtrado, guard de rol, motivo, tipos, RN-20, cálculo bajo lock con alcance `'branch'`/`'total'`, `_stock_apply_delta`, un movimiento sellado, re-resolución de sucursal creada perezosamente. `REVOKE ALL`.
- [ ] 8.4 🛑 Envoltorios `CREATE OR REPLACE` con su firma y su forma de respuesta: `rpc_stock_adjustment`, `rpc_adjust_branch_stock`, `rpc_apply_product_stock_delta` (rechazo de flags `P0400 stock_internal_flags_not_allowed`). Re-afirmar `REVOKE ALL FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated, service_role`.
- [ ] 8.5 🛑 `rpc_reverse_stock_movement` `CREATE OR REPLACE` desde su cuerpo vivo, con `_stock_apply_delta(v_account_id, …, TRUE)` en lugar de la RPC pública; re-afirmar el `REVOKE` de la tanda A.
- [ ] 8.6 🛑 `rpc_transfer_stock` `CREATE OR REPLACE` desde su cuerpo vivo con el producto filtrado por cuenta (`P0404`); nada más cambia (D11).
- [ ] 8.7 `CHECK stock_movements_manual_needs_reason … NOT VALID` (sin `VALIDATE`) + `COMMENT` que explica las 18 filas históricas (D6). Idempotente (`DROP CONSTRAINT IF EXISTS` + `ADD`).
- [ ] 8.8 `COMMENT ON FUNCTION` de las ocho funciones tocadas (procedencia, contrato, interna/pública).
- [ ] 8.9 `supabase db reset` completo → gate **GREEN** (a)-(m); reaplicar el archivo dos veces sin error.

## 9. Gates de ACL y de fixture

- [ ] 9.1 `test_function_acl_gate.sql`: sumar las tres internas a `v_internal_only_fns` con su firma exacta.
- [ ] 9.2 `test_stock_adjustment_account_branch.sql` (#617): ajustar las expectativas de antes/después de la cuenta de dos sucursales a nivel sucursal (D8) y pasar motivo en toda llamada; el resto del gate (sello, visibilidad, ACL, overload único) no cambia.
- [ ] 9.3 Correr la batería completa de 4.6 + `test_function_acl_gate.sql`. Si una fixture rompe por rol, motivo, tipo o `variant_only`, se corrige **la fixture** (rol del usuario sintético, motivo, tipo de producto) — nunca el núcleo. Listar cada fixture corregida en el PR.
- [ ] 9.4 `backend/tests/test_table_refs_gate.py`: re-correr; si inspecciona cuerpos de función, actualizar las referencias de las funciones reescritas/nuevas.

## 10. Backend (TDD)

- [ ] 10.1 RED: `POST /products` con `stock > 0` y un actor sin `CAN_STOCK` ⇒ 403 y **ningún** `INSERT` ejecutado (ni conteo contra el límite del plan). Ver fallar.
- [ ] 10.2 GREEN: `services/products.py::create_product` llama `require_account_role(conn, auth, CAN_STOCK)` cuando `payload.stock != 0`, antes de todo; el router inyecta la conexión como en `product_categories`.
- [ ] 10.3 Triangular: owner y `stock` con stock inicial ⇒ 201 y la RPC llamada con `('Stock inicial', True, False)`; `seller` con `stock = 0` ⇒ 201 sin chequeo de rol de stock.
- [ ] 10.4 RED: `PUT /products/{id}` con `stock` distinto del saldo ⇒ 422 `stock_adjust_required` sin ningún `UPDATE`; con el mismo valor ⇒ 200 sin llamada a la RPC. Ver fallar.
- [ ] 10.5 GREEN: `update_product` compara contra `existing["stock"]` (lectura única ya existente, ampliada a cuando viene `stock`) y quita `stock` de `data`; `ProductRepository.update` deja de llamar a `rpc_apply_product_stock_delta`.
- [ ] 10.6 Retirar `StockRepository.adjust_with_event`; reemplazar `TestStockAdjustedProducer` (`backend/tests/outbox/test_producers.py`) por un candado estructural: ningún archivo de `backend/` invoca `rpc_apply_product_stock_delta` con flags distintos de `TRUE, FALSE`. Ver fallar el candado contra el código viejo.
- [ ] 10.7 Actualizar `backend/tests/test_c21_checkpoint2_single_write.py` y los tests de productos que asumían el ajuste por `PUT`.
- [ ] 10.8 `backend/core/rbac.py`: comentario de `CAN_STOCK` con su primer consumidor y el atado al `ARRAY` de la migración.
- [ ] 10.9 `pytest` completo + cobertura ≥ 87 %.

## 11. Frontend — librerías (TDD)

- [ ] 11.1 `lib/rbac-capabilities.ts`: `CAN_STOCK`. Test en `__tests__/lib/rbac-capabilities.test.ts` que lo ata a `CAN_STOCK` de `backend/core/rbac.py` **y** al `ARRAY[...]` de `_stock_assert_can_adjust` en `20261074000001` (RED primero).
- [ ] 11.2 `lib/operation-errors.ts`: tokens `stock_adjustment_reason_required`, `stock_adjustment_type_invalid` (deriva a "Transferir stock"), `stock_adjustment_product_not_adjustable`, `stock_internal_flags_not_allowed`, `stock_adjust_required` (deriva a "Ajustar stock"), y `insufficient_role` en el contexto "ajuste de stock" extendiendo `OperationErrorContext`. Tests por token, más el de "error no reconocido se muestra tal cual".
- [ ] 11.3 `hooks/data/use-branch-stock.ts::translateBranchStockError`: delega en el mapa canónico lo que no reconoce (rol, motivo). Test en `operation-errors-branch.test.ts`.
- [ ] 11.4 `lib/stock-import-parser.ts`: encabezado "Motivo" obligatorio (error de archivo), celda vacía ⇒ error bloqueante "Falta el motivo", alias de transferencia ⇒ error que deriva a "Transferir stock"; plantilla y lista de tipos actualizadas. Tests RED → GREEN.

## 12. Frontend — superficie (TDD)

- [ ] 12.1 `app/(dashboard)/stock/page.tsx`: "Ajustar stock", acción por fila e "Importar ajuste" con `hasCapability(roles, CAN_STOCK, rolesResolved)`; "Transferir" sin cambios. Test: `seller` no los ve, `stock` sí, roles sin resolver ⇒ visibles.
- [ ] 12.2 `components/stock/stock-adjustment-modal.tsx`: motivo obligatorio (rótulo, envío deshabilitado con motivo en blanco, mensaje en línea), sin las opciones de transferencia, errores por fila con `humanizeOperationError`. Tests: no llama al servidor con motivo vacío/espacios; envía `p_reason` recortado; error `insufficient_role` en castellano.
- [ ] 12.3 `components/stock/stock-import-adjustment-dialog.tsx`: filas sin motivo bloqueadas y explicadas; confirmación deshabilitada con errores bloqueantes. Test.
- [ ] 12.4 `components/branches/BranchStockTable.tsx` (ajuste con `CAN_STOCK`, transferencia con `isWriter`) y `AdjustStockModal.tsx` (motivo `.trim().min(1)`). Tests.
- [ ] 12.5 `components/forms/product-form.tsx`: alta con "Stock inicial" sólo con `CAN_STOCK` y producto con stock propio (nunca padre `variant_only`), línea explicativa sin rol; edición con "Stock actual" sólo lectura + "Ajustar stock" que abre `StockAdjustmentModal` con el producto preseleccionado (D9). Tests de las cuatro variantes.
- [ ] 12.6 `hooks/data/use-products.ts`: el `PUT` no manda `stock`. Test sobre el cuerpo enviado.
- [ ] 12.7 `pnpm vitest run` completo + `tsc --noEmit` sin errores nuevos; cero `any`.

## 13. Verificación visual y accesibilidad

- [ ] 13.1 Stack local con usuarios `@test.local` de rol `owner`, `stock` y `seller`. Capturas a 375 px y desktop, tema claro y oscuro, de: `/stock` (con y sin rol), el modal con motivo vacío y con error del servidor, el importador con filas sin motivo, `/sucursales/[id]/stock`, y el formulario de producto en alta (con y sin rol) y en edición con el modal abierto encima. Guardar en `evidence/screenshots/`.
- [ ] 13.2 Accesibilidad: el motivo tiene `label` y `aria-invalid`/mensaje asociado; el foco vuelve al formulario de producto al cerrar el modal anidado; contraste con los tokens existentes (sin colores literales nuevos).

## 14. PR de la tanda B, verificación post-merge y humo

- [ ] 14.1 Commit(s) convencionales + PR con la lista de fixtures corregidas (9.3), la evidencia de 6.5/6.6 y las capturas.
- [ ] 14.2 Post-merge, sólo lectura en prod: `MAX(version) = 20261074000001`; una sola definición viva de cada envoltorio, de `rpc_transfer_stock` y de `rpc_reverse_stock_movement`; las tres internas sin `EXECUTE` para `anon`/`authenticated`; `stock_movements_manual_needs_reason` presente y `NOT VALID`; deploy de Render y Vercel confirmados.
- [ ] 14.3 A las 48 h: 0 movimientos manuales nuevos sin motivo, sin cuenta o sin sucursal; 0 errores 5xx de `/products` en Render.
- [ ] 14.4 Humo del PO en prod: ajuste en `/stock` sin motivo (bloqueado) y con motivo (aparece en el historial con el motivo), importador con una fila sin motivo, edición de un producto que deriva al modal, alta con stock inicial, borrar una venta y una compra de prueba.
- [ ] 14.5 Actualizar la ficha del change en `CHANGES.md` con PRs, migraciones, verificación y los hallazgos laterales del design (cada uno como candidato con su medición).

## 15. Archive

- [ ] 15.1 KB, recién cuando ya es cierto en prod: RN-21 (grants revocados + sólo policies de lectura + las dos `qual = false`), RN-A5 (el ajuste de stock exige motivo en la base), `knowledge-base/03_actores_y_roles.md` (`stock_movements` y `branch_stock`: escritura "Solo via RPC"; ajuste manual `owner`/`admin`/`stock`).
- [ ] 15.2 `openspec archive stock-ledger-solo-rpc` + verificar en HEAD que los requirements de `branch-stock`, `inventory-single-ledger` y `stock-transfer` quedaron como en los deltas (CRLF → LF; gotchas conocidas de `openspec archive`).
