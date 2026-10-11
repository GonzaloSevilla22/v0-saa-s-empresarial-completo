> **Governance MEDIA con tramo ALTO.** Se reescriben las funciones que mueven stock, caja y banco en el alta y la edición de compras, y la edición de gastos. Si el PO elige el backfill (OQ-1 = (b)), además hay una migración de datos que mergea él.
>
> **Un solo PR**: funciones, frontend, backend (comentarios), gates y specs.
>
> **TDD estricto**: cada grupo de producción abre con su RED (un test o gate que falla por la razón correcta) y deja evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR, nunca a `main`. Conventional commits en español.
> - Toda RPC se reescribe desde su `pg_get_functiondef` **vivo de producción**, con la misma firma (`CREATE OR REPLACE`, sin `DROP`), conservando el `COMMENT` y re-emitiendo las ACLs.
> - Nada contra producción salvo lo que ejecuta o autoriza el PO (grupos 0 y 11). Nunca el MCP `apply_migration`.
> - La base local es compartida: con `remitos-compra` tanda B en curso, los applies corren **en serie**, nunca a la vez.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [x] 0.1 **[PO]** Sign-off de las OQ (`design.md` §Open Questions). Registrar la respuesta textual en una sección "Sign-off del PO" del `design.md`.
  - **Firmado el 2026-10-11, textual: «vamos con todo lo recomendado»** → OQ-1 (a), OQ-2 (a), OQ-3 (a). Registrado en `design.md` (§Open Questions → "Resueltas el 2026-10-11 por el PO: todas por la recomendación").
  - Consecuencias para el apply: **el grupo 3 (backfill) NO se ejecuta** y `20261076000002` no se usa; el alta de compra rechaza una sucursal elegida cerrada (`P0422 branch_closed`); no hay guard en el alta ni en la edición del gasto, ni reescritura de `rpc_create_expense`.
  - Sin respuesta, el apply adopta la recomendación de cada una: (a) en las tres.
  - **OQ-1 = (b)** suma el grupo 3, que no se escribe sin el OK textual del PO sobre las reglas de D8.
  - **OQ-2 = (b)** retira:
    - el chequeo `branch_closed` del alta (D2 (a)), el bloque (5) del gate y la mutación M8;
    - el escenario «Una sucursal elegida cerrada es rechazada» del delta de `purchase-operation`;
    - y el escenario «Compra en sucursal cerrada falla» del delta de `branches`. Además, «Operaciones solo contra sucursales operativas» pasa a excluir la compra.
  - **OQ-3 = (b)** suma:
    - la reescritura de `rpc_create_expense` (guard `no_branch_found` con `p_branch_id NULL`, antes del `INSERT`), con su preflight;
    - el bloque (9e) asertando el rechazo;
    - el error de fila del importador de gastos;
    - `humanizeOperationError` en `expense-form-v2.tsx` (tarea 5.2);
    - y los ajustes del delta de `expense-operation`.
- [x] 0.2 **[PO ejecuta o autoriza]** Checkpoint del cuerpo **vivo de producción**, antes de escribir SQL. **Ejecutado el 2026-10-11 por el orquestador** (el apply no tiene acceso a producción; usó sus datos y los verificó contra la base local):
  - **Caso A de D6**: `public._purchase_operation_core` **no existe** (ni en producción ni en local); `remitos-compra` sigue en 45/79, sin tanda B y sin PR. Este change reescribe `rpc_create_purchase_operation` entera.
  - Producción: `MAX(version) = 20261075000002`, 323 migraciones. Local: `MAX = 20261077000002`, 325 (le suma las dos de `stock-movimientos-sucursal-origen`, PR #631, que no tocan ninguna de las funciones de este change).
  - `md5(replace(prosrc, E'', ''))` local = producción en las tres funciones de partida (tabla de abajo); una sola firma, `anon` sin `EXECUTE`, `authenticated`/`service_role` con `EXECUTE`. `COMMENT`: el alta de compra no tiene; la edición de compra tiene el de `caja-compras-cobranzas` (D8); la edición de gasto, el de `gastos-forma-pago`. Los cuerpos locales volcados con `pg_get_functiondef` tienen 405 / 365 / 233 líneas, como dice el design.
  - Lo pedido a continuación quedó cubierto así:
  - `pg_get_functiondef`, `obj_description` y `proacl` de:
    - `rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)`;
    - `rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)`;
    - `rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean)`.
  - Sólo para leer: `rpc_create_expense`, `c26_default_branch(uuid)`, `c21_apply_branch_stock_delta`, `op_stock_movement`, `_pay_register_operation_bank_movement` y `rpc_delete_purchase_operation`.
  - **¿Existe `public._purchase_operation_core`?** Si existe, es el caso B de D6: la reescritura del alta va sobre el núcleo, y la edición parte del cuerpo de `remitos-compra` tanda B. Anotar el caso acá.
  - Comparar por líneas, sin `\r`, contra el local y contra el archivo que definió cada función (`20261062000001` para las dos de compra y `20261043000001` para la de gasto, salvo que la tanda B las haya redefinido). Extraer los dos lados con `pg_get_functiondef`, no cortando el archivo.
  - Referencia local (321 migraciones, `MAX = 20261074000001`), con la medida del preflight `md5(replace(prosrc, E'\r', ''))`:

    | Función | `md5(prosrc)` local |
    |---|---|
    | `rpc_create_purchase_operation` | `0366977251522a469d123c4d143f42f9` (= producción el 2026-10-03, `remitos-compra`) |
    | `rpc_atomic_update_purchase_operation` | `23558c073cf71d08ea4a0dfb15079555` (= producción el 2026-10-03) |
    | `rpc_update_expense` | `360d4dc4320208b56eb106d82c7b38c3` |
    | `rpc_create_expense` (sólo OQ-3 = (b)) | `4a5b5ae1eeb775c63a3ecfe2681401ba` |
    | `c26_default_branch` (lectura) | `4fb12c57c3417bb98212cddd2e5ac069` |

  - `COMMENT` esperado: el alta de compra no tiene; la edición de compra tiene el de `caja-compras-cobranzas` (D8); la edición de gasto, el de `gastos-forma-pago`.
  - ACL esperada: `postgres`, `authenticated` y `service_role` con `EXECUTE`, y `anon` sin `EXECUTE`.
  - Si producción diverge de los archivos, se elige con el PO entre reconciliar primero los archivos o aceptar los dos `md5` en `v_expected` (design D7). Se reescribe sobre el **vivo** y se anota el desvío.
- [x] 0.3 **[PO ejecuta o autoriza]** Conteos informativos en producción (sólo agregados, no bloquean). **No re-medidos por el apply** (sin acceso a producción); se conservan los del propose, informativos y que no cambian ninguna decisión (OQ-1 = (a): los históricos no se rellenan): 106 de 127 operaciones de compra sin sucursal al 2026-10-03 (12 de las 33 de los últimos 30 días) y 175 gastos sin sucursal. Quedan **pendientes para la verificación posterior (11.3)**, que los mide el PO o el orquestador:
  - operaciones de compra con `branch_id NULL` (total y últimos 30 días);
  - gastos con `branch_id NULL`;
  - movimientos `reference_type = 'purchase'` con `branch_id NULL`;
  - compras registradas en una sucursal que ya estaba cerrada (`branches.status = 'closed'` y `closed_at <= purchases.created_at`), para OQ-2;
  - cuentas sin ninguna sucursal operativa.

  Son la línea de base de la verificación 11.3.
- [x] 0.4 Confirmar que `20261076000001` (y `20261076000002` si OQ-1 = (b)) sigue libre: `ls supabase/migrations`, `gh pr list --state open` y `MAX(version)` de producción. Si `remitos-compra` tanda B lo tomó, renumerar al siguiente libre y anotarlo.
  - **Resultado (2026-10-11)**: `20261076000001` sigue libre. `gh pr list --state open` sólo muestra el #631 (`stock-movimientos-sucursal-origen`, `20261077000001`/`2`, que se ordena DESPUÉS de esta migración en la cadena y no comparte funciones con ella). `MAX` de producción `20261075000002` (dato del orquestador). `20261076000002` no se usa (OQ-1 = (a)).
- [x] 0.5 Re-verificar sobre `main` actualizado el inventario de escritores:
  - funciones vivas con `INSERT`/`UPDATE` en `purchases` y `expenses` (las del alcance, `rpc_atomic_create_purchase` ×2, `rpc_create_purchase_operation_v2`, `rpc_import_expenses`, `rpc_safe_delete_product`);
  - grep de escrituras directas en `backend/`, `frontend/` y `supabase/functions/` (hoy sólo `services.createExpense`, sin llamadores).

  Anotar cualquier escritor nuevo que no esté en el design (D13).
  - **Resultado**: las 11 funciones vivas de la base local con `INSERT`/`UPDATE` en `purchases` o `expenses` son exactamente las del design (`rpc_atomic_create_purchase` ×2, `rpc_atomic_update_purchase_operation`, `rpc_create_expense`, `rpc_create_purchase_operation`, `rpc_create_purchase_operation_v2`, `rpc_import_expenses`, `rpc_safe_delete_product` ×2, `rpc_update_expense`); ningún escritor nuevo. Escritura directa por PostgREST: sólo `services.createExpense` (`frontend/lib/supabase/services.ts:68`), sin llamadores salvo su test de identidad de sesión.
- [x] 0.6 Grep en `supabase/tests/`, `backend/tests/` y `frontend/__tests__/` de lo que fija el contrato viejo:
  - «compra sin sucursal → `NULL`»;
  - «la edición con `NULL` desimputa la sucursal de una compra o un gasto»;
  - la creación perezosa de "Casa Central" por una compra;
  - el `md5` o el texto de los `COMMENT` de `rpc_update_expense` y `rpc_atomic_update_purchase_operation`;
  - «Sin sucursal (general)» / «Sin sucursal por defecto» en compra, gasto o importador.

  Hoy aparece `test_gastos_forma_pago.sql` (4.3b, L1438-1440). Listar los que cambian a propósito en 1.4 y 5.x.
  - **Resultado**: cambia a propósito `test_gastos_forma_pago.sql` (4.3b, L1438-1440). Ningún gate fija el `md5` ni el texto de los `COMMENT` de las dos funciones de edición. «Sin sucursal (general)» / «Sin sucursal por defecto» sólo aparecen en los tres formularios del alcance (`purchase-form.tsx:780`, `expense-form-v2.tsx:234`, `expense-import-dialog.tsx:691`), en `QuoteForm.tsx:561` (queda), en el valor por defecto de `BranchSelect` y en los tests propios de `BranchSelect` (que siguen verdes: el default `true` no cambia). "Casa Central" aparece en gates ajenos que no la crean por una compra.
- [x] 0.7 **SAFETY NET**. Correr y registrar el baseline:
  - **Backend**: `test_purchases.py`, `test_caja_compras_cobranzas.py`, `test_expenses.py`, `test_gastos_forma_pago.py`, `test_expense_import.py` y `test_asiento_contable_gastos.py`.
  - **Frontend**: `__tests__` de `purchase-form*`, `use-purchases*`, `expense-form*`, `expense-import-dialog*`, `use-expenses*`, `BranchSelect*`, `use-cash-optin*`, `a11y/gastos*` y `QuoteForm*`.
  - **Gates SQL**: todos los que nombran las tres funciones (design D12), más `test_ventas_sucursal_por_defecto.sql` (comparte `c26_default_branch` y `BranchSelect`).

  Una falla previa se reporta como preexistente y no se corrige acá.
  - **Baseline (2026-10-11, antes de tocar nada)**: backend **180/180** en esos 6 archivos; frontend **28 archivos, 264/264**; gates SQL (los 27 de la lista de D12 + `test_ventas_sucursal_por_defecto`): **todos verdes salvo uno preexistente y ajeno** — `test_ventas_sucursal_por_defecto.sql` (parte A) falla en el caso 9b (la caracterización de OQ-8 de ventas) porque la base local compartida ya trae las migraciones `20261077000001`/`2` del apply en vuelo #631, cuyo cambio de reposición en la principal operativa invalida esa caracterización. No es de este change; lo actualiza el #631.
  - Aclaración de método: los gates con `\i` relativo (`test_unidades_decisiones_8_9.sql`) se corren copiando `supabase/` al contenedor y usando `-w`, como en CI desde la raíz del repo.

## 1. RED — gate SQL (antes de tocar las funciones)

- [ ] 1.1 Escribir `supabase/tests/test_compras_gastos_sucursal_por_defecto.sql` con los bloques (0)-(10) de `design.md` D12, más el (11) condicionado a que exista `rpc_convert_delivery_note_to_purchase`. Patrón del proyecto:
  - fallos acumulados en `text[]` y un solo `RAISE` al final;
  - anchors sintéticos vía `handle_new_user`;
  - `created_at` explícito y estrictamente posterior en las sucursales sintéticas, asertado;
  - limpieza de toda fila con el `account_id` de los anchors **y** de las dependencias sin `account_id` (`cashboxes` de sus sucursales).
- [ ] 1.2 Fixtures:
  - cuenta con A (principal) y B, un producto, forma de pago `cash` y forma de pago bancaria con cuenta destino;
  - una caja con sesión abierta hoy en A y otra en B;
  - A cerrada (`status = 'closed'`, vacía) para el bloque (2);
  - para el bloque (3), cuenta con una sucursal desactivada y otra cerrada, ambas vacías;
  - para el bloque (4), cuenta sin ninguna sucursal: borrado bajo `session_replication_role = replica`, con borrado explícito previo de sus `cashboxes` y su `branch_stock`, y aserción final de residuo cero;
  - compra y gasto residuales con `branch_id NULL`, insertados directo; la compra, con su stock en la principal y su movimiento `NULL`, como los deja hoy el alta;
  - un gasto en B sin dinero posteado.
- [ ] 1.3 Correr el gate contra los cuerpos **actuales** y registrar el RED. Esperado:
  - (0) falla por `md5`;
  - (1), (2), (6) y (7) fallan con `branch_id NULL` (en (6), además, con el rechazo `cash_optin_requires_open_session`);
  - (3) y (4) fallan porque la compra pasa (stock en el *fallback*, o "Casa Central" creada) en vez de dar `no_branch_found`;
  - (5) falla porque la compra en la sucursal cerrada pasa;
  - (8a), (8b), (8d), (9a), (9b) y (9c) fallan con la fila en `NULL` (o la operación modificada en (8d));
  - (10) caracteriza: hoy, con el movimiento `NULL`, la reversa cae en la principal vigente. Se registra como tal;
  - (9e) caracteriza el comportamiento de OQ-3 (a).
- [ ] 1.4 Actualizar **a propósito** `supabase/tests/test_gastos_forma_pago.sql` (4.3b): el nulo explícito de sucursal pasa a registrar la sucursal por defecto; forma de pago y centro de costo siguen desimputando. Lo mismo con todo lo que haya listado 0.6, citando este change en el comentario. Correr contra los cuerpos actuales y registrar el RED.

## 2. GREEN — `supabase/migrations/20261076000001_compras_gastos_sucursal_por_defecto.sql` (funciones)

- [ ] 2.1 Escribir la migración partiendo de los cuerpos vivos de 0.2:
  - **Preflight** (bloque `DO` inicial, molde de `20261075000001`): `v_expected` con los `md5` de partida, y `v_rewritten` con los que deja esta migración, medidos en el stack local. Si no es ninguno, `RAISE EXCEPTION` sin reescribir; si ya es el reescrito, `NOTICE 'compras-gastos-sucursal-por-defecto: % ya es el cuerpo de esta migración (reaplicación)'`.
  - Con **sólo** los cambios de `design.md` D2:
    - **alta de compra** (o núcleo, caso B):
      - `branch_closed` para una sucursal elegida cerrada (si OQ-2 = (a));
      - `v_gate_branch`;
      - el guard `P0422 no_branch_found` antes del `INSERT` en `operation_idempotency`;
      - `v_gate_branch` en los dos `INSERT` en `purchases`, en `c21_apply_branch_stock_delta`, en el `INSERT` en `stock_movements`, en la condición de sucursal del opt-in de caja y en `_pay_register_operation_bank_movement`;
    - **edición de compra**: `COALESCE` con la principal y el mismo guard, después del tri-estado y **antes** de la pata REVERSE;
    - **edición de gasto**: `COALESCE` con la principal después del tri-estado, sin guard (OQ-3 (a)).
  - Cabecera con contexto, decisión del PO, cuerpos de partida (con su `md5` y su archivo), caso de D6 y **regla para el PR siguiente**. Un comentario `-- compras-gastos-sucursal-por-defecto (Dn):` en cada punto tocado.
- [ ] 2.2 `COMMENT`:
  - la edición de compra re-declara el vivo **idéntico**;
  - la edición de gasto, el vivo completo más la excepción de D7;
  - el alta de compra, ninguno (si el vivo no tiene).

  Re-emitir las ACLs: `REVOKE ALL … FROM PUBLIC, anon` más `GRANT EXECUTE … TO authenticated, service_role`, idénticas a las vivas. En el caso B, el núcleo sin `authenticated`.
- [ ] 2.3 Diff de cada cuerpo nuevo contra el vivo, sin `\r`: tiene que ser **exactamente** D2 más los comentarios. Adjuntar los diffs como evidencia en el PR (`evidence/` del change).
- [ ] 2.4 Aplicar en la base local y correr el gate: bloques (0)-(10) (y (11) si aplica) en GREEN, más `test_gastos_forma_pago.sql` completo.
- [ ] 2.5 Mutaciones M1-M9 de D12 sobre los cuerpos locales, dentro de una transacción con `ROLLBACK`. Cada una detectada por el gate con su mensaje. Registrar los mensajes.
- [ ] 2.6 Idempotencia: reaplicar el archivo dos veces sobre la base local. La segunda pasada toma la rama de reaplicación del preflight (un `NOTICE` por función reescrita) y el `schema_snapshot` del paso "Verify … idempotent on reapply" de `KPI_Validation.yml` no cambia.
- [ ] 2.7 Correr todos los gates de 0.7, todos verdes. En particular:
  - `test_purchase_cash_optin.sql` (3.7: una sola definición);
  - `test_idempotency.sql` (8, 9, 11, 12);
  - `test_confirm_core_integrity.sql` (4, 5);
  - `test_ventas_unidades_conversion.sql` (E) y su prueba de carrera;
  - `test_edicion_preserva_contexto.sql` (2.2);
  - `test_stock_movements_edicion.sql`;
  - `test_compras_proveedor_cuenta_corriente.sql`;
  - `test_function_acl_gate.sql`;
  - `test_remitos_compra.sql`.

## 3. Backfill — `supabase/migrations/20261076000002_compras_gastos_sucursal_por_defecto_backfill.sql` (sólo si OQ-1 = (b))

> **No se escribe sin el OK textual del PO sobre las reglas de `design.md` D8.** Con OQ-1 = (a), este grupo se marca "no aplica" con la cita del sign-off.

- [ ] 3.1 RED: bloque (12) del gate, con fixtures para cada regla de D8:
  - compras: operación mixta (una fila en B, otra `NULL`, también con B cerrada), movimiento propio con sucursal operativa y no operativa, principal vigente, residuo (sin cuenta, cuenta sin sucursal operativa);
  - gastos: principal vigente y residuo.

  Conteos de efectos laterales (`events`, `notifications`, `analytics_events`, `cash_movements`, `bank_movements`, `supplier_account_movements`, `journal_entries`, `stock_movements`) **acotados a las cuentas del fixture**. Ejecutar con `\i` y registrar el RED.
- [ ] 3.2 GREEN: la migración de datos (sin DDL, sin funciones, sin ACLs). En un bloque `DO`:
  - `FOR UPDATE` por `id` ascendente;
  - resolución por operación (compras) y por fila (gastos);
  - `UPDATE`s;
  - una fila de `audit_logs` por cuenta y por documento (`purchases_branch_backfill` / `expenses_branch_backfill`), con ids y conteos;
  - `NOTICE` con conteos y residuo.

  Nunca aborta por datos. **Ningún `stock_movements` se toca.**
- [ ] 3.3 Correr el bloque (12) ejecutando el archivo **dos veces**: cada regla verificada, la segunda corrida sin cambios ni auditoría, y los efectos laterales en cero.
- [ ] 3.4 Mutaciones, con `ROLLBACK`:
  - M10: sin la regla de operación mixta;
  - M11: sin la regla del movimiento;
  - M12: sin el filtro de operativa en las reglas 2 y 3;
  - M13: un `UPDATE` que también toca `stock_movements`.

## 4. CI

- [ ] 4.1 `.github/workflows/KPI_Validation.yml`: reaplicación de `20261076000001` (y de `20261076000002` si existe) **al final de la cadena**, después del bloque de `20261075000001`/`2` (y, en el caso B, después del de `remitos-compra` tanda B), sin tolerancia:
  - dos pasadas;
  - la segunda con los `NOTICE` de reaplicación contados con `grep -cF` (uno por función reescrita);
  - el OK de la introspección;
  - y el `schema_snapshot` idéntico.

  El comentario del paso deja escrita la **regla para el PR siguiente** (D6/D12). Ubicar el bloque por contenido, no por número de línea.
- [ ] 4.2 Cablear `supabase/tests/test_compras_gastos_sucursal_por_defecto.sql` como paso propio. Actualizar el comentario del paso de `test_gastos_forma_pago.sql` si menciona el contrato viejo.
- [ ] 4.3 Antes del PR, emular en local la cola de la cadena: la migración aplicada **dos veces**, el gate nuevo entre medio, el `schema_snapshot` comparado y los gates del orden de CI. No hacer `supabase db reset` sobre la base compartida. En la corrida de CI, confirmar que el bloque (0) del gate nuevo pasa **después** de los reapply.

## 5. Frontend — selectores de compra, gasto e importador

- [ ] 5.1 RED/GREEN de `components/forms/purchase-form.tsx` (D9): `<BranchSelect allowUnassigned={false} label="Sucursal" …/>`, sin `placeholder`. Test nuevo `__tests__/components/purchase-form-branch-default.test.tsx`, con el `BranchSelect` **real** (mock de `useBranches`/`usePlanLimits`). Casos:
  - el alta muestra la principal con «(principal)» y la lista no ofrece «Sin sucursal (general)»;
  - sin tocar el selector, el payload lleva `branchId: null`;
  - elegir B manda B;
  - la edición precarga la sucursal de la compra;
  - la edición de una compra con `branchId` nulo muestra la principal;
  - la cuenta sin módulo no muestra selector ni rótulo;
  - `getByLabelText('Sucursal')` encuentra el combobox.

  Validar por mutación que los casos fallan sin el cambio.
- [ ] 5.2 RED/GREEN de `components/forms/expense-form-v2.tsx`, con los mismos casos en `__tests__/components/expense-form-branch-default.test.tsx`. Con OQ-3 = (b), además `humanizeOperationError` para el error del submit, con un caso de `no_branch_found` traducido.
- [ ] 5.3 RED/GREEN de `components/gastos/expense-import-dialog.tsx`: `allowUnassigned={false}` y `label="Sucursal por defecto"`, sin `placeholder`. Casos:
  - muestra la principal y la lista no ofrece «Sin sucursal por defecto»;
  - sin tocar el selector, el lote viaja con `default_branch_id: null`;
  - elegir B lo manda.

  Los tests existentes del importador siguen verdes.
- [ ] 5.4 `components/branches/BranchSelect.tsx`: actualizar sólo el JSDoc de `allowUnassigned` (el `true` por defecto queda para el presupuesto). Regresión: `BranchSelect.test.tsx` y `BranchSelect-sin-sucursal.test.tsx` verdes, y un caso de `QuoteForm` que sigue ofreciendo «Sin sucursal (general)».
- [ ] 5.5 Prosa: actualizar los comentarios que describan el opt-in de caja de una compra sin sucursal como rechazado por el servidor, o el contrato «sin sucursal → `NULL`» de compra o gasto, sin cambiar aserciones. Candidatos: el caso «elegible y tildado» de `__tests__/components/purchase-form-cash-optin.test.tsx` (L203-213), la cabecera de `hooks/use-cash-optin.ts` (que nombra a la venta y al gasto como fuentes de las tres condiciones; suma la compra), `backend/schemas/purchases.py` (6.1) y lo que encuentre el grep de 0.6.
- [ ] 5.6 Regresión del opt-in de caja: `purchase-form-cash-optin`, `use-purchases-cash-optin`, `expense-form-payment-effects` y `a11y/gastos.a11y` verdes.
- [ ] 5.7 Coordinación con `remitos-compra` tanda B (su 7.3 extrae `PurchaseCheckoutFields` de `purchase-form.tsx`). El selector de sucursal no está en lo que extrae, pero los dos tocan el archivo: quien aplique segundo resuelve el conflicto y mantiene `allowUnassigned={false}` en el selector del formulario. Dejarlo anotado en el PR y en el engram de los dos changes.
- [ ] 5.8 `pnpm vitest run` de los archivos afectados y vecinos, y `tsc --noEmit` sin errores nuevos respecto del baseline.

## 6. Backend (sin cambio de lógica)

- [ ] 6.1 RED/GREEN: test de la descripción de OpenAPI de `branch_id` en `PurchaseOperationIn`, `PurchaseOperationUpdateIn`, `ExpenseCreate` y `ExpenseUpdate` («sin sucursal, … se registra en la sucursal principal de la cuenta»), molde de `test_schema_branch_id_documents_that_no_branch_means_the_principal`. Agregar las descripciones y corregir los comentarios de `backend/schemas/purchases.py` (L26-31 y el docstring de la edición) y de `backend/services/purchases.py`.
- [ ] 6.2 Confirmar con los tests existentes que el alta y la edición transportan `None` y el tri-estado (`p_branch_provided`) sin cambios. No se agregan tests de comportamiento: la resolución es de la RPC y la cubre el gate.
- [ ] 6.3 Suite completa con el comando de CI (`pytest backend/tests -m "not integration" --cov=backend`), cobertura ≥ 87 %.

## 7. Verificación visual (superficie frontend)

- [ ] 7.1 Formulario de compra y formulario de gasto, en alta y edición, e importador de gastos. Con una cuenta con módulo y dos sucursales (y la más antigua cerrada, en un caso) y una cuenta sin módulo. Combinaciones: escritorio (1280 px) y móvil (375 px), tema claro y tema oscuro. Verificar:
  - el rótulo («Sucursal» / «Sucursal por defecto»), la principal preseleccionada y la marca «(principal)», con contraste AA (tokens semánticos, sin colores literales);
  - la lista sin la opción sin sucursal;
  - en la cuenta sin módulo, ni selector ni rótulo;
  - el bloque de caja de la compra en efectivo sin sucursal elegida, ofrecido y marcado;
  - sin desborde horizontal a 375 px.

  Adjuntar capturas al PR (no se versionan).
- [ ] 7.2 El presupuesto (`QuoteForm`) sigue mostrando «Sin sucursal (general)» en las mismas combinaciones.

## 8. Humo en el stack local

- [ ] 8.1 Levantar Supabase local con la migración de la rama, `uvicorn` desde el worktree y `pnpm dev`. Usar una cuenta Pro con A (principal) y B y una cuenta sin módulo, y verificar cada caso con `psql`:
  - **H1**: compra sin tocar el selector → `purchases`, `stock_movements` y `branch_stock` en A.
  - **H2**: eligiendo B → todo en B.
  - **H3**: cuenta sin módulo → su «Casa Central».
  - **H4**: compra en efectivo de hoy sin sucursal elegida, con la caja de A abierta y la casilla marcada (el defecto de hoy) → se registra, con su movimiento de caja en la sesión de A.
  - **H5**: compra por transferencia sin sucursal → `bank_movements.branch_id = A`.
  - **H6**: `PUT /purchases/operation` con `branch_id: null` sobre una compra en B → A, y el stock se traslada de B a A.
  - **H7**: compra y gasto `NULL` creados con el código de `main` y editados sólo en el importe → A.
  - **H8**: gasto sin tocar el selector → A; `PUT /expenses/{id}` con `branch_id: null` sobre un gasto en B → A.
  - **H9**: importador de gastos sin tocar la sucursal por defecto → las filas sin sucursal propia en A.
  - **H10** (OQ-2 (a)): compra eligiendo una sucursal cerrada → rechazo con el mensaje traducido de `branch_closed`, sin filas.
  - **H11**: cuenta de prueba con todas las sucursales desactivadas → la compra se rechaza con el mensaje traducido de `no_branch_found`, sin filas ni sucursal creada. El gasto se registra (OQ-3 (a)).
  - **H12**: el Tablero filtrado por A suma la compra de H1.
  - **H13** (caso B o tanda B ya mergeada): remito de compra → Compra, y la compra queda en la sucursal del remito.

## 9. Specs, KB y documentación

- [ ] 9.1 `openspec validate "compras-gastos-sucursal-por-defecto" --strict` y `openspec validate --specs --strict`.
- [ ] 9.2 `knowledge-base/05_reglas_de_negocio.md`: nota en RN-93 de que la compra y el gasto la cumplen desde este change (alta y edición), con los históricos según OQ-1.
- [ ] 9.3 Al archivar (no en el apply):
  - **`CHANGES.md`**: ficha con la verificación posterior y los candidatos que deja:
    - `NOT NULL` en `purchases`/`expenses.branch_id` junto con el de `sales` (D13);
    - `REVOKE` de la escritura directa de `authenticated` sobre `purchases` y `expenses`;
    - el retiro de `rpc_atomic_create_purchase`, `rpc_create_purchase_operation_v2` y `services.createExpense`;
    - la reversa y la edición con la sucursal guardada no operativa (OQ-8 de ventas, extendido a compras);
    - el guard de gasto sin sucursal operativa (si OQ-3 quedó en (a));
    - `humanizeOperationError` en el formulario de gasto.
  - **`CLAUDE.md`**: puntero y `python scripts/ci/check_docs_sync.py --fix` para `AGENTS.md`.
  - Diffear cada spec sincronizada contra su versión previa (`purchase-operation`, `expense-operation`, `operation-edit-context`, `branches` y `branch-stock`). `remitos-compra` agrega requirements a `purchase-operation` y `operation-edit-context`: si archiva antes, verificar en **HEAD** que sus requirements siguen ahí (gotchas de archive: CRLF, líneas en blanco, dos deltas sobre la misma capability).

## 10. PR y merge

- [ ] 10.1 PR con commits convencionales y CI verde: `validate-kpis` (gate nuevo y reapply nuevo), Backend, Frontend, E2E, Docs Sync y Vercel.
- [ ] 10.2 Revisión adversarial con **un solo juez** por ronda (tope de agentes del workflow) sobre:
  - el diff de cada función contra su cuerpo vivo;
  - el preflight y el caso de D6;
  - el guard y su posición antes de toda escritura;
  - la paridad entre caja, banco, stock y fila;
  - la idempotencia;
  - la superficie frontend.
- [ ] 10.3 Merge. Con OQ-1 = (b) lo mergea el **PO**: los sub-agentes no mergean migraciones de datos.

## 11. Verificación posterior al merge (producción, sólo lectura; la ejecuta o autoriza el PO)

- [ ] 11.1 `deploy.yml` verde, con `MAX(version)` igual a la migración de este change. Vercel desplegado. Render: `GET /deploys` del commit del merge, y `POST /deploys` si falta.
- [ ] 11.2 En los cuerpos vivos de las funciones reescritas, la persistencia resuelta y el guard están presentes, y su `md5(prosrc)` es el `v_rewritten` del preflight. Los `COMMENT` son los esperados, hay una sola firma por función y las ACLs no cambiaron (`anon` sin `EXECUTE`).
- [ ] 11.3 Conteos contra la línea de base de 0.3:
  - las operaciones de compra y los gastos con `branch_id NULL` no crecen. Se comparan por estado, nunca por `created_at`;
  - las compras registradas después del deploy tienen sucursal, y su movimiento de stock y su movimiento bancario también.
- [ ] 11.4 (Sólo si OQ-1 = (b)) Las filas de `audit_logs` del backfill: cuentas, documentos asignados por regla y residuo. Las compras y los gastos `NULL` de cuentas con sucursal operativa tienen que ser 0; si no, **[PO]** re-ejecutar el bloque idempotente. Informar al PO.
- [ ] 11.5 **[PO]** Humo real:
  - en una cuenta sin módulo, una compra en efectivo de hoy con la caja abierta se registra con su movimiento de caja (H4);
  - en una cuenta con dos sucursales, una compra y un gasto sin tocar el selector quedan en la principal;
  - el Tablero filtrado por la principal incluye la compra.

## Evidencia TDD

| Tarea | Test / gate | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|-------------|------|------------|-----|-------|---------------|----------|
| 1.x/2.x | `supabase/tests/test_compras_gastos_sucursal_por_defecto.sql` (0)-(11) | SQL | | | | | |
| 1.4 | `supabase/tests/test_gastos_forma_pago.sql` (4.3b) | SQL | | | | | |
| 3.x | `test_compras_gastos_sucursal_por_defecto.sql` (12), sólo OQ-1 = (b) | SQL | | | | | |
| 5.1 | `__tests__/components/purchase-form-branch-default.test.tsx` | Componente | | | | | |
| 5.2 | `__tests__/components/expense-form-branch-default.test.tsx` | Componente | | | | | |
| 5.3 | `__tests__/components/expense-import-dialog*` | Componente | | | | | |
| 5.4 | `BranchSelect*`, `QuoteForm` | Componente | | | | | |
| 6.1 | `backend/tests/test_purchases.py`, `test_expenses.py` (descripción de `branch_id`) | Unit | | | | | |
