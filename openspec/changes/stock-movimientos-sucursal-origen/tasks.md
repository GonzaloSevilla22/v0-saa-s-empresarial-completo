> **Governance ALTA.** Se reescribe `rpc_reverse_stock_movement` (repone o descuenta stock en todo borrado de venta y de compra) y una migración de datos completa en masa `stock_movements.branch_id` en producción, como extensión de la única excepción auditada a RN-21.
>
> **Un solo PR**: las dos migraciones, el gate nuevo, el ajuste del gate de `ventas-sucursal-por-defecto`, la CI y RN-21. Lo **mergea el PO**, porque lleva una migración de datos.
>
> **TDD estricto**: cada grupo de producción abre con su RED (un gate que falla por la razón correcta) y deja evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR, nunca a `main`. Conventional commits en español.
> - `rpc_reverse_stock_movement` se reescribe desde su `pg_get_functiondef` **vivo de producción**, con la misma firma (`CREATE OR REPLACE`, sin `DROP`), conservando el `COMMENT` y re-emitiendo la ACL.
> - Nada contra producción salvo lo que ejecuta o autoriza el PO (grupos 0 y 9), y sólo `SELECT`. Nunca el MCP `apply_migration`: las migraciones van por el `supabase db push` del pipeline.
> - **Ninguna de las dos migraciones se escribe sin el OK textual del PO sobre OQ-A, OQ-B y OQ-D** (tarea 0.5).
> - La base local es compartida con otros applies: nada de `supabase db reset` sin coordinar; se emula la cola de la cadena de CI.

## 0. Checkpoint de producción y sign-off (sólo lectura)

- [ ] 0.1 **[PO ejecuta o autoriza]** Cuerpo vivo de producción, antes de escribir SQL:
  - `pg_get_functiondef`, `md5(replace(prosrc, E'\r', ''))`, `obj_description` y `proacl` de `rpc_reverse_stock_movement(uuid, text, text)`; sólo para leer, los mismos datos de `_stock_apply_delta(uuid, uuid, numeric, uuid, boolean)` y `c26_default_branch(uuid)`.
  - Referencia local (base con `MAX = 20261074000001`): `rpc_reverse_stock_movement` `3af74d58ee4bc40691d066d8d4860d7a`, `_stock_apply_delta` `b3f6edd5ea68b0904ff2b5e29bce9843`, `c26_default_branch` `4fb12c57c3417bb98212cddd2e5ac069`. ACL esperada de la reversa: `EXECUTE` sólo para `postgres` y `service_role`.
  - Comparar por líneas sin `\r` (gotcha CRLF). Si producción diverge de los archivos de migración, se decide con el PO como en `ventas-sucursal-por-defecto` (reconciliar antes o aceptar los dos `md5` en `v_expected`, documentado).
  - `MAX(version)` de producción y `gh pr list --state open`: confirmar que `20261077000001`/`000002` siguen libres y que el hermano `compras-gastos-sucursal-por-defecto` no tomó `20261077…`. Renumerar si hace falta.
- [ ] 0.2 **[PO ejecuta o autoriza]** Confirmar X (`2026-08-26 00:00:00-03`, design D3):
  - la corrida de `deploy.yml` del merge `043017a` (#465) terminó antes de X (`gh run list --commit 043017a`);
  - en producción: el primer evento `entity_type = 'branch'` de `audit_logs`; ninguna sucursal con `deactivated_at < X`; cuántas tienen `is_active = false AND deactivated_at IS NULL` (bajas sin fecha); cuántos eventos `branch.reactivated` hubo y de qué cuentas.
  - Si X no se puede confirmar, OQ-B pasa a (b) y la regla `reconstruida` no se escribe.
- [ ] 0.3 **[PO ejecuta o autoriza]** Clasificación de sólo lectura de los movimientos `'sale'` nulos: la regla de D2-D5 escrita como un `SELECT` (vive en el scratchpad, no en el repo). Informar, sin identificar cuentas:
  - por regla (`pre_sucursal`, `unica`, `reconstruida`) y por cuenta; nulos que quedarían por motivo (`no_fechable`, `contradiccion`, `sin_cuenta`, `sin_sucursal`);
  - `discrepancia_venta`; destinos hoy desactivados y hoy cerrados;
  - movimientos con `stock_movements.account_id` nulo (la reversa no los encuentra: si hay, candidato);
  - los 73 sin venta viva, desglosados: con contramovimiento `sale_reversal`, con `sale_update`, huérfanos sin cierre.
  - Contrastar con la medición del 2026-10-10 (47 / 207 / 63 / 126 / 73). Una diferencia se explica antes de seguir.
- [ ] 0.4 **[PO ejecuta o autoriza]** Movimientos `'sale'` y `'purchase'` de operaciones vivas cuya sucursal está hoy desactivada o cerrada (el alcance de D6, antes y después de la migración de datos).
- [ ] 0.5 **[PO]** Sign-off con los números de 0.2-0.4. Registrar la respuesta textual en «Sign-off del PO» del `design.md`.
  - **OQ-A, OQ-B y OQ-D bloquean los grupos 1 a 4.** OQ-C no bloquea (sin respuesta, (a)).
  - Si OQ-D es (b) o (c): se retiran del change el grupo 1 y 2, el MODIFIED de la reversa del delta, la migración `20261077000001` y la reaplicación de 5.2; con (b), además, la migración de datos sólo escribe destinos hoy operativos (OQ-A (b)).
  - Si OQ-A es (b): la migración de datos filtra destinos operativos y el delta lo dice. Si OQ-B es (b): se retira la regla `reconstruida` (los del caso 4 se cuentan como `no_fechable`) y sus casos del gate.
  - Cualquier otra opción: actualizar en el mismo PR la decisión, el delta y estas tareas.
- [ ] 0.6 SAFETY NET. Correr y registrar el baseline de los gates que alcanza el change: `test_stock_ledger_solo_rpc.sql`, `test_ventas_sucursal_por_defecto.sql`, `test_stock_movements_edicion.sql`, `test_remito_a_venta.sql`, `test_delete_guard_ledgers.sql`, `test_function_acl_gate.sql`; y en el backend `test_sales.py` y `test_purchases.py` (el borrado). Una falla previa se reporta como preexistente y no se corrige acá.

## 1. RED — gate de la reversa (parte A)

- [ ] 1.1 Crear `supabase/tests/test_stock_movimientos_sucursal_origen.sql` con la parte A (design D9). Patrón del proyecto: fallos acumulados en `text[]` y un solo `RAISE` por parte; anchors sintéticos vía `handle_new_user`; `created_at` explícito y asertado en las sucursales sintéticas (`c26_default_branch` no desempata); sesión simulada con `set_config` local; limpieza completa con residuo cero (cajas y `branch_stock` de las sucursales sintéticas, gotcha `session_replication_role`).
  - (A0) introspección: una sola firma, `SECURITY DEFINER`, sin `EXECUTE` para `anon`/`authenticated`/`PUBLIC`, `COMMENT` con la frase del fallback y `md5` vivo = `v_rewritten` de `20261077000001`;
  - (A1) venta con movimiento en sucursal desactivada (vaciada por transferencia y dada de baja): `rpc_delete_sale_operation` **ejecutada** repone en la principal operativa; el contramovimiento registra la principal y trae `reverses_movement_id`, `fallback_from_branch_id` y `fallback_reason = 'branch_inactive'`; la desactivada queda en 0;
  - (A2) lo mismo para una compra con `rpc_delete_purchase_operation`, con piso trazable cuando la principal no alcanza;
  - (A3) sucursal cerrada y activa: `P0422 branch_closed`, sin cambios en saldo ni ledger;
  - (A4) sucursal operativa y movimiento nulo: mismo resultado que hoy (contramovimiento en la sucursal original; nulo para el nulo);
  - (A5) una operación con dos líneas, una en sucursal desactivada y otra en una operativa: cada una se revierte según su caso.
- [ ] 1.2 Correr la parte A contra el cuerpo actual. (A0), (A1), (A2) y (A5) fallan por la razón correcta (el stock vuelve a la desactivada); (A3) y (A4) pasan (fijan lo que no debe cambiar). Registrar la salida.

## 2. GREEN — migración `20261077000001` (reversa)

- [ ] 2.1 Escribir `supabase/migrations/20261077000001_reversa_stock_sucursal_desactivada.sql` desde el cuerpo vivo de 0.1:
  - cabecera con el porqué (D6), lo que no cambia (cerradas, nulos, ACL) y el rollback;
  - preflight `DO` con `v_expected` (0.1) y `v_rewritten`; aborta si el vivo no es ninguno; `NOTICE '… ya es el cuerpo de esta migración (reaplicación)'` si ya es el reescrito;
  - `CREATE OR REPLACE` con la misma firma; diff contra el vivo limitado a: resolver la sucursal (desactivada → nula), el `branch_id` del contramovimiento (la efectiva cuando hubo respaldo) y la `metadata`;
  - `COMMENT` vivo completo más la frase del fallback; `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`.
- [ ] 2.2 Aplicarla en el stack local, medir el `md5(replace(prosrc, E'\r', ''))` resultante, fijarlo como `v_rewritten` en el preflight y en (A0), y reaplicarla: tiene que imprimir el `NOTICE` de reaplicación y dejar idénticos firmas, ACL y `COMMENT`.
- [ ] 2.3 Correr la parte A: verde. TRIANGULAR: una sucursal desactivada **y** cerrada (manda la baja: respaldo, no `P0422`); una cuenta sin ninguna sucursal operativa (cae donde ya cae hoy un movimiento nulo, sin error nuevo).
- [ ] 2.4 Ajustar **a propósito** el bloque (9b) de `supabase/tests/test_ventas_sucursal_por_defecto.sql`: de «el stock vuelve a G0 desactivada» a «vuelve a la principal operativa G1 y el contramovimiento la registra»; actualizar su encabezado y su `NOTICE` citando este change. Correr el gate completo.
- [ ] 2.5 Mutaciones sobre el cuerpo local (dentro de una transacción con `ROLLBACK`; cada una detectada por el gate con su propio mensaje): M1 sin respaldo; M2 respaldo también para cerradas; M3 contramovimiento con la sucursal original cuando hubo respaldo. Registrar la detección.
- [ ] 2.6 REFACTOR y gates del grupo 0.6 en verde.

## 3. RED — gate de los datos (parte B)

- [ ] 3.1 Sumar al gate la parte B (design D9), con `\i supabase/migrations/20261077000002_stock_movimientos_sucursal_origen.sql` **dos veces** dentro de una transacción. Fixtures con la historia de sucursales armada a mano:
  - sucursales con `created_at` explícitos (antes y después de X, y antes y después de cada movimiento);
  - eventos de `audit_logs` (`entity_type = 'branch'`) insertados con `created_at` explícito, y los cambios de estado hechos con `session_replication_role = replica` para que el disparador no escriba eventos con `now()` (todos compartirían el instante de la transacción);
  - bajas anteriores a X hechas sin evento y con `deactivated_at` nulo;
  - movimientos `'sale'` insertados con `created_at` explícito.
- [ ] 3.2 Casos y aserciones, acotados a las cuentas del fixture (la migración es global):
  - (B1) `pre_sucursal` con la más antigua desactivada → la más antigua;
  - (B2) `unica` con la única desactivada y la venta en otra sucursal posterior → la única; se cuenta `discrepancia_venta`;
  - (B3) `reconstruida`, T ≥ X, la más antigua dada de baja **después** de T (evento) → la más antigua;
  - (B4) `reconstruida`, T ≥ X, la más antigua dada de baja **antes** de T → la siguiente operativa;
  - (B4b) `reconstruida`, la más antigua dada de baja sin fecha y **reactivada** después de T (evento `branch.reactivated`): con T ≥ X no operaba → la siguiente; con T < X → nulo;
  - (B5) `reconstruida`, T < X, la más antigua inactiva en X sin fecha → nulo (`no_fechable`);
  - (B6) `reconstruida`, T < X, todas activas en X y sin `closed_at` → la más antigua;
  - (B7) `reconstruida`, T < X, una sucursal anterior a la elegida con `closed_at` no nulo → nulo;
  - (B8) `reconstruida` sin ninguna operativa en T (todas constan como no operativas) → la más antigua de las existentes en T;
  - (B9) veto por caja y (B10) veto por banco → nulo (`contradiccion`);
  - (B11) controles intactos: movimiento con sucursal; de otro tipo (`sale_return`, `purchase`); de una venta borrada y su contramovimiento; de una venta sin cuenta; de una cuenta sin sucursales; con `created_at` nulo;
  - (B12) ninguna otra columna cambia: hash de todas las columnas salvo `branch_id` de los movimientos del fixture, antes y después;
  - (B13) una fila de `audit_logs` por cuenta con movimientos completados (`action = 'stock_movements_branch_backfill'`), con `movement_ids`, `movement_ids_por_regla` y los contadores de D7;
  - (B14) la segunda corrida no cambia nada ni escribe auditoría;
  - (B15) sin efectos laterales: `branch_stock`, `sales`, `sales_orders`, caja, banco, cuentas corrientes, asientos, `events`, `notifications` y `analytics_events` de las cuentas del fixture sin cambios (conteos por cuenta: el relay de `pg_cron` corre cada minuto);
  - (B16) `rpc_delete_sale_operation` **ejecutada** sobre la venta de (B1): repone en la principal operativa por D6.
- [ ] 3.3 Correr: falla porque el archivo no existe o no completa nada. Registrar.

## 4. GREEN — migración `20261077000002` (datos)

- [ ] 4.1 Escribir `supabase/migrations/20261077000002_stock_movimientos_sucursal_origen.sql` (sólo datos, design D7), con cabecera completa: decisión y sign-off del PO, las tres reglas, X, el veto, la excepción a RN-21 y su cierre, locks, auditoría, reversión exacta e idempotencia.
  - Candidatos por `JOIN` sobre tablas temporales con clave, nunca subconsultas correlacionadas por fila.
  - Filas de `sales` referenciadas tomadas con `FOR UPDATE` en orden ascendente de `id` antes de escribir.
  - Estado de cada sucursal en X y en cada T según D3; eventos empatados en el mismo instante con estados distintos → desconocido.
  - Una sola escritura: `UPDATE stock_movements SET branch_id = …` sobre los resueltos, con `WHERE branch_id IS NULL`.
  - `NOTICE` con todos los contadores (incluidos los `'sale'` nulos sin venta viva); nunca aborta por datos.
- [ ] 4.2 Correr la parte B: verde, en las dos corridas.
- [ ] 4.3 Mutaciones (cada una detectada con su mensaje): M4 `pre_sucursal` con la más antigua **operativa**; M5 `unica` salteando la no operativa; M6 inactiva-en-X tratada como inactiva desde siempre; M7 estado actual en vez del rebobinado de `audit_logs`; M7b T < X tomando el rebobinado como exacto (sin la inferencia conservadora); M8 sin veto; M9 tocando movimientos sin venta viva; M10 escribiendo otra columna; M11 la sucursal de la venta en vez del origen (la regla vieja).
- [ ] 4.4 Volumen: 50.000 movimientos sintéticos en 5 cuentas con historia de sucursales; registrar el tiempo (referencia: 24 s del backfill de ventas). Si supera el minuto, revisar el plan antes de seguir.
- [ ] 4.5 REFACTOR y gates del grupo 0.6 en verde, más la parte B de `test_ventas_sucursal_por_defecto.sql` (su `\i` de `20261075000002` corre sobre una base donde ya corrió esta).

## 5. CI

- [ ] 5.1 `KPI_Validation.yml`: paso propio «Run stock movimientos sucursal origen gate» con `psql -v ON_ERROR_STOP=1`, desde la raíz del repo (el `\i` es relativo), después del de `test_ventas_sucursal_por_defecto.sql`.
- [ ] 5.2 Reaplicación al final de la cadena, después de `20261075000002`: `20261077000001` dos veces (la segunda exige el `NOTICE` de reaplicación y el `schema_snapshot` idéntico) y `20261077000002` una vez (exige ` 0 movimientos completados` y el `schema_snapshot` idéntico). Comentario con la regla: una migración posterior que redefina `rpc_reverse_stock_movement` retira ese bloque en el mismo PR.
- [ ] 5.3 Emular localmente la cola de la cadena (los dos reapply) y correr el gate nuevo después.

## 6. Base de conocimiento

- [ ] 6.1 Actualizar RN-21 en `knowledge-base/05_reglas_de_negocio.md`: la excepción se extiende con la segunda migración (reglas, veto, auditoría `stock_movements_branch_backfill`) y queda agotada; la reversa de un movimiento en una sucursal desactivada se aplica en la principal operativa. Reemplazar «No se reabre» por el cierre definitivo, sin perder la historia. Preservar CRLF (`git diff --ignore-space-at-eol` limpio fuera del párrafo).

## 7. Verificación local

- [ ] 7.1 Correr todos los gates de 0.6, el gate nuevo y la parte B de `test_ventas_sucursal_por_defecto.sql`; comparar contra el baseline.
- [ ] 7.2 `openspec validate "stock-movimientos-sucursal-origen" --strict` y `openspec validate --specs --strict`.
- [ ] 7.3 Line endings: `git ls-files --eol` de los archivos tocados y ningún `\r` textual en el diff.
- [ ] 7.4 Revisión adversarial del diff de las dos migraciones (un solo juez): el diff de la función contra el vivo, la regla de D3 contra los fixtures, y que ninguna escritura salga de `stock_movements.branch_id` y `audit_logs`.

## 8. PR y despliegue

- [ ] 8.1 Un solo PR con cuerpo en español: decisión del PO, números del checkpoint, reglas, efectos y rollback. **Lo mergea el PO.**
- [ ] 8.2 Tras el merge: la corrida de `deploy.yml` aplicó `20261077000001` y `20261077000002` (`MAX(version)` de producción = `20261077000002`, lo lee el PO).

## 9. Verificación posterior en producción (sólo lectura, la autoriza el PO)

- [ ] 9.1 `md5` vivo de `rpc_reverse_stock_movement` = `v_rewritten`; ACL y `COMMENT` como en el archivo; una sola firma.
- [ ] 9.2 Una fila `stock_movements_branch_backfill` por cuenta afectada; sus contadores coinciden con 0.3; los `'sale'` nulos restantes = sin venta viva + no fechables + contradicciones.
- [ ] 9.3 Re-medir 0.4: los movimientos que quedaron en sucursales desactivadas son los esperados, y ningún contramovimiento posterior al despliegue entró en una sucursal desactivada.
- [ ] 9.4 Informe al PO con los números finales.

## 10. Cierre

- [ ] 10.1 Al archivar: candidatos a `CHANGES.md` — «Facturar venta manual» sobre una venta cuya sucursal no opera (la otra mitad de OQ-8); movimientos con `account_id` nulo que la reversa no encuentra (si 0.3 los midió); contramovimientos nulos de movimientos nulos; y los nulos que quedaron por diseño.

## Evidencia TDD

| Tarea | Archivo | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|---|---|---|---|---|---|---|---|
| 1-2 | `supabase/tests/test_stock_movimientos_sucursal_origen.sql` (parte A) | SQL gate | | | | | |
| 2.4 | `supabase/tests/test_ventas_sucursal_por_defecto.sql` (9b) | SQL gate | | | | | |
| 3-4 | `supabase/tests/test_stock_movimientos_sucursal_origen.sql` (parte B) | SQL gate | | | | | |
