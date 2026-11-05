> **Governance ALTA**: escribe dinero real en cuatro libros (cuenta corriente, caja, banco y libro diario) desde RPCs `SECURITY DEFINER`.
>
> **Tres tandas, cada una un PR y aplicadas por un solo agente en serie** (`design.md` §Migration Plan):
> - **A**: cimientos, sin cambio de comportamiento visible. Grupos 1–5.
> - **B**: la edición con dinero y el backend. Grupos 6–11.
> - **C**: superficie. Grupos 12–17.
>
> Cada tanda lleva checkpoint de cuerpo vivo, gates que **ejecutan** las RPCs, revisión adversarial antes del merge y verificación post-merge en prod.
>
> **TDD estricto**: cada grupo abre con su RED (un test que falla por la razón correcta) antes de escribir producción. La evidencia va en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR, nunca a `main`. Nunca `--no-verify`.
> - Toda función se reescribe desde su `pg_get_functiondef` **vivo de prod**, comparado por líneas y sin `\r`, conservando su `COMMENT` (o su ausencia) y re-asertando la ACL.
> - Una firma que cambia va con `DROP` + `CREATE` + `REVOKE` explícito a `PUBLIC`, `anon` y `authenticated` + `GRANT` selectivo. Nunca `CREATE OR REPLACE` con un `DEFAULT` nuevo (`42725`).
> - Todo repositorio filtra por `account_id` de forma explícita.
> - Número de migración: el siguiente libre al momento de cada tanda.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [x] 0.1 **[PO]** Sign-off de OQ-1..OQ-6 (`design.md` §Open Questions).
  - Registrar la respuesta textual en `design.md` antes de escribir producción.
  - Si el PO elige una alternativa a la recomendada, actualizar en el mismo PR la decisión, las specs y estas tareas.
  - **OQ-4 (rol) se cierra junto con `multiusuario`.** Sin sign-off no hay apply: es governance ALTA.
- [x] 0.2 Confirmar que ya están mergeados y en prod: `fix/stock-edicion-sucursal-y-piso`, la tanda B de `remitos-compra` y, antes de la tanda B de este change, `multiusuario`. Anotar los números de migración que ocuparon (`gh pr list --state all`, `MAX(version)` de prod). Si alguno no mergeó, la tanda que depende de él no empieza (la tanda A sólo depende de los dos primeros).
- [x] 0.3 **Checkpoint de cuerpo vivo de la tanda en curso.**
  - Leer de prod `pg_get_functiondef`, `obj_description` y ACL de cada función que la tanda redefine.
  - Comparar el `md5` (sin `\r`) contra el de `design.md` §Context, tomado el 2026-10-14. Los hermanos cambian varias de estas funciones, así que **se espera divergencia**: partir siempre del vivo y anotar el desvío.
  - Guardar los cuerpos previos en `evidence/<tanda>/` para el rollback.
- [x] 0.4 Re-medir en prod (sólo `SELECT`) las cifras de `proposal.md` (bloqueadas por motivo, cajas cerradas, cargos con saldo menor, movimientos en período conciliado, 0 eventos pendientes) y las 6 `credit_note` históricas con su referencia. Si algo cambió, actualizar `design.md` en el mismo PR.
- [x] 0.5 **Inventario de CI.** En `.github/workflows/KPI_Validation.yml`, listar los bloques de reaplicación que fijan cuerpos de las funciones que la tanda redefine, y aplicar su "REGLA PARA EL PR SIGUIENTE" en el mismo PR (retirarlos o actualizarlos), igual que `remitos-compra` 1.9.
- [x] 0.6 **Safety net**: baseline en verde, registrado.
  - backend `-m "not integration"` + integración;
  - vitest completo y `tsc`;
  - los gates SQL del workflow sobre `db reset` limpio, en especial los 17 que ejecutan las RPCs de edición, `test_delete_guard_ledgers.sql`, `test_gastos_forma_pago.sql`, `test_cobranzas_vencimientos*.sql`, el gate del conjunto canónico del outbox y `test_function_acl_gate.sql`.

  Un pre-existente en rojo se reporta y no se corrige acá.

## 1. Tanda A — Huella neta y borrado sobre la huella

- [x] 1.1 **RED**: gate `supabase/tests/test_op_money_footprint.sql`, con dos cuentas, fixtures propios y cleanup asertado.
  - Una venta del POS con caja, editada a mano como `postgres` (movimiento original + reversión + nuevo con la misma referencia), se borra.
  - Hoy `rpc_delete_sale_operation` compensa la suma del tipo `sale`, no el neto: ver el doble conteo.
  - Lo mismo para un gasto y para la caja repartida en dos sesiones de la misma caja.
- [x] 1.2 Función de huella neta (D3), por `(libro, cuenta del libro, referencia)` — **desvío**: una única `op_money_footprint` `SECURITY INVOKER` legible por la aplicación (más `op_money_footprint_flags` para los indicadores), en vez de una interna `_op_money_footprint` + una variante: un INVOKER público no puede llamar a una interna sin EXECUTE, y una sola definición es más fiel a D3:
  - cuenta corriente: `sale`/`credit_note` y `purchase`/`debit_note`;
  - caja: agrupada por caja;
  - banco: agrupado por cuenta y por familia de tipo.

  Más su variante legible por la aplicación (`SECURITY INVOKER`, sin `_` inicial). Nombre y ACL compatibles con los chequeos (3) y (4) de `test_function_acl_gate.sql`.
- [x] 1.3 Reescribir `rpc_delete_sale_operation`, `rpc_delete_purchase_operation` y `rpc_delete_expense` desde el vivo para que compensen la huella neta, con una compensación por fila de huella y la **misma referencia**. Se conservan el orden de guards, `P0425`, `P0426`, el espejo `unreconciled`, el remito y los eventos.
- [x] 1.4 GREEN → **TRIANGULATE**:
  - venta del formulario y del POS, compra, gasto;
  - neto cero sin movimientos;
  - signo invertido plantado (se compensa igual);
  - caja en dos sesiones (una compensación);
  - borrado sobre datos sin ediciones, con los mismos libros e importes que antes (gate de equivalencia contra el cuerpo previo guardado en `evidence/`).
- [x] 1.5 Las proyecciones de lectura (`backend/repositories/sales_repository.py`, `purchase_repository.py`, `expense_repository.py`) pasan `has_account_charge`, `has_cash_movement`, `has_bank_movement` e `is_delete_blocked` a la huella neta, consumiendo la función de 1.2 y no un `EXISTS`. `is_payment_locked` todavía **no** se toca (grupo 10). Tests de backend: RED con una operación de huella compensada que hoy reporta `has_cash_movement = true`.

## 2. Tanda A — Emparejamiento de reversiones en el aging FIFO

- [x] 2.1 **RED**: en `supabase/tests/` y en `backend/tests/` (aging), una cuenta con un cargo A más viejo y un cargo B que se revierte y se vuelve a registrar con la misma referencia. Hoy la reversión cancela A. Agregar también una cadena de dos ediciones y el invariante de cierre con todos los tipos.
- [x] 2.2 Aplicar la regla de D9 en `backend/repositories/_account_aging_sql.py`, la única definición Python, con cuatro consumidores.
- [x] 2.3 Aplicar la misma regla desde el vivo en `rpc_receivables_report`, `rpc_payables_report`, `_produce_receivables_overdue_digest` y las dos RPCs de cambio de vencimiento de `20261033000001`. Gate que compare, para un mismo ledger sintético, el reparto que dan los siete lugares.
- [x] 2.4 Medir en prod antes y después (`SELECT` sobre la definición nueva aplicada a datos vivos, en el stack local con un volcado anónimo o por consulta de sólo lectura) el reparto por tramo de las cuentas con las 6 `credit_note` históricas. Saldo total sin cambios. Informar al PO en el PR.

## 3. Tanda A — Consumidor contable

- [x] 3.1 **Checkpoint**: `md5` vivo de `_journal_post_from_event` y del despachador. RED en `supabase/tests/`:
  - asiento vigente con un contra-asiento de igual referencia: hoy `SaleOperationDeleted` puede elegir el contra-asiento;
  - `CreditNoteIssued` sobre una venta cuyo asiento vigente es `SaleOperation`: hoy reintenta `P0451`.
- [x] 3.2 Reescritura desde el vivo:
  - `reversal_of IS NULL` y orden descendente en las búsquedas de `SaleOperationAdjusted`, `SaleOperationDeleted`, `PurchaseDeleted` y `CreditNoteIssued`, y en `ExpenseDeleted` si el vivo no lo tiene (`ExpenseAdjusted` ya lo tiene);
  - `SaleOperationAdjusted` con las dos convenciones (`sales_order_id` del payload);
  - `CreditNoteIssued` con las dos convenciones.

  Las demás ramas quedan byte a byte, con un gate de no-regresión que postea un evento de cada tipo preexistente y compara el asiento.
- [x] 3.3 Rama `PurchaseAdjusted`: reversión como `PurchaseDeleted` + posteo como `PurchaseCreated`, compartiendo la resolución de cuentas con una función o expresión única. `P0451` y `P0450`. RED → GREEN → triangular: efectivo→efectivo, efectivo→crédito, con IVA, adelantado al alta y doble proceso.
- [x] 3.4 Conjunto canónico de 15 tipos en el filtro del despachador **y** en el del helper, en el mismo commit. Actualizar el gate del invariante y su matriz de evasión.

## 4. Tanda A — Concurrencia y productor de `PurchaseAdjusted`

- [x] 4.1 **RED**: en un gate de carrera (`*_race.sh`, molde de `test_ventas_unidades_conversion_race.sh`), dos ediciones concurrentes de la misma compra. Hoy las dos aplican.
- [x] 4.2 `rpc_atomic_update_purchase_operation` desde el vivo:
  - toma las filas `FOR UPDATE` en orden ascendente y recuenta (`P0404`), como la venta;
  - emite `PurchaseAdjusted` si existe `PurchaseCreated` para la operación. En la tanda A la compra con dinero sigue bloqueada y el `operation_id` todavía se regenera, así que el payload lleva el `operation_id` viejo y el nuevo, y la rama de 3.3 resuelve por el viejo. La tanda B lo vuelve estable.
- [x] 4.3 `rpc_update_expense` desde el vivo: `FOR UPDATE` sobre la fila del gasto. Gate de carrera.
- [x] 4.4 Gate: compra asentada → editada → borrada termina con todos sus asientos revertidos y 0 eventos con `P0451` (cierra el defecto latente de `design.md` §Context).

## 5. Tanda A — Cierre

- [x] 5.1 `test_function_acl_gate.sql` con las funciones nuevas. Introspección al final de la migración:
  - una firma viva por función;
  - ACLs;
  - cuerpos con `reversal_of IS NULL` y los dos filtros con 15 tipos.

  Reaplicar la migración dos veces sin error.
- [x] 5.2 Cablear los gates nuevos en `KPI_Validation.yml`. Todos los gates del workflow en verde sobre `db reset` limpio. Backend y frontend en verde.
- [x] 5.3 Revisión adversarial del diff de la tanda A (un juez). PR `opsx/edicion-operaciones-con-dinero-apply-a`, CI verde, merge. — Revisión del diff por el orquestador, CI verde, mergeado (#659/#660/#661).
- [x] 5.4 **Verificación post-merge en prod**: — Verificado en prod 2026-11-05 por el orquestador (SQL de solo lectura): MAX(version)=20261089000001 sobre 336 migraciones; 15 funciones con una sola firma y ACLs esperadas; md5 de prosrc igual al de la migración; sin P0423 por dinero en los cuerpos vivos; 0 eventos pendientes; invariante SUM(abierto)=balance con 0 violaciones.
  - `MAX(version)`;
  - una firma viva y su ACL;
  - `md5` del vivo igual al de la migración;
  - 0 eventos pendientes con `P0451`;
  - invariante de cierre del aging en todas las cuentas corrientes (`SELECT`).

  Registrar en `CHANGES.md`.

## 6. Tanda B — Validación única del opt-in de caja

- [x] 6.1 **RED**: gate con la matriz de las tres condiciones (`kind`, sesión abierta de la sucursal y de la cuenta, fecha de hoy) contra `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation` (o `_purchase_operation_core`) y `rpc_create_expense`, registrando tokens y códigos actuales. Correrlo contra el vivo y guardar el resultado como referencia.
- [x] 6.2 Crear `_cash_optin_assert` (D16) con los predicados copiados del vivo. Agregar la variante "corrección" (sin fecha de hoy si ya había huella de caja).
  - **Desvío (D16)**: `_cash_optin_assert` recibe un séptimo parámetro, `p_doc` (`sale`|`purchase`|`expense`), sólo para elegir el sustantivo del mensaje y que el texto de cada alta no cambie ("de la venta", "una compra fechada…", "un gasto fechado…"). `p_account_id` se recibe por contrato y no se usa: la tenencia de la sesión la sigue dando el backstop de `c28_register_cash_movement` (P0401).
- [x] 6.3 Migrar las tres altas al helper, desde el vivo. Gate de 6.1: veredictos y mensajes idénticos.

## 7. Tanda B — Plan y edición de venta

- [x] 7.1 **RED** (`supabase/tests/test_edicion_operaciones_con_dinero.sql`, dos cuentas, roles reales y cleanup asertado), uno por escenario de `specs/operation-money-edit` y de los deltas de libros:
  - venta a crédito editada (sube, baja con `P0425`, cambio de cliente, vencimiento conservado o explícito);
  - efectivo del día y de una sesión cerrada (`P0426` sin sesión, `cash_intent_required` al cambiar de sucursal, `cash_optin_requires_today` para una retroactiva sin huella);
  - transferencia (espejo + nuevo, `P0424`, cuenta conservada);
  - sin cambio económico, sin escritura;
  - herencia (crédito histórico sin cargo);
  - cambio de forma de pago entre los cuatro libros;
  - venta del POS (referencias de la orden);
  - CAE, en vuelo y remito siguen bloqueados;
  - `operation_id` estable;
  - auditoría;
  - rol (OQ-4);
  - `p_dry_run` sin efectos.
- [x] 7.2 Función interna de **plan** (D13): huella, efecto deseado, acción y bloqueos, sin escrituras.
- [x] 7.3 `rpc_atomic_update_sale_operation` desde el vivo (`DROP` + `CREATE` con la firma nueva):
  - parámetros nuevos: `p_cash_session_id`/`p_cash_provided`, `p_bank_account_id`/`p_bank_account_provided`, `p_due_date`/`p_due_date_provided`, `p_reason`, `p_dry_run`;
  - se retiran los tres `P0423` de dinero;
  - orden de D12;
  - `operation_id` estable (legacy: uno nuevo);
  - escrituras por plan (cuenta corriente: nuevo y después reversión; caja; banco);
  - caso B y C contable extendido al POS;
  - `audit_logs`.

  Conservar el guard de remito, el fiscal, la tenencia del cliente y el recálculo de la orden.
  - **Desvíos**: (i) `P0999` es el código interno del sub-bloque que deshace la anulación del comprobante pendiente en vista previa (nada se anula en seco; un bloqueo fiscal `P0423` viaja como dato del plan). (ii) Un `p_due_date` explícito en `NULL` equivale a «volver a la cascada del plazo»: el helper del cargo es el único que resuelve el vencimiento y con `NULL` aplica la cascada, no deja el cargo sin vencimiento. (iii) `operation_id` ESTABLE se aplica en el RPC de la venta: el `UPDATE` de re-apuntado de la orden pasa a ser un no-op y se conserva porque devuelve la orden a recalcular.
- [x] 7.4 Checkpoint: verificar que `_sales_order_sync_from_operation` recalcula también la forma de pago de la orden. Si no lo hace, extenderlo desde el vivo con su gate, porque el listado lee `COALESCE(pm, pos_pm)`.
  - **Checkpoint 7.4 medido**: `_sales_order_sync_from_operation` NO recalcula la forma de pago de la orden (total, cliente, sucursal y líneas sí). Se alinea en el RPC de edición (`UPDATE sales_orders SET payment_method_id = …` tras la sincronización) y no en el helper, que comparte con la promoción de ventas legacy y cuyo contrato no cambia. Cubierto por el escenario V7 del gate.
- [x] 7.5 GREEN → **TRIANGULATE** hasta cubrir 7.1, más:
  - mutantes muertos: reversión antes del cargo, compensar por tipo en vez de neto, escribir con H = E, sin `reversal_of IS NULL`, la fecha de hoy exigida en la corrección;
  - gate de carrera: doble guardado, y dos ediciones que cruzan clientes sin `40P01`;
  - gate que **ejecuta** la RPC también en modo `p_dry_run`.
- [x] 7.6 Actualizar los gates existentes que asumían el `P0423` por dinero o el `operation_id` regenerado (`test_pagos_cableados_restantes.sql`, `test_pos_banco_movimientos.sql`, `test_asiento_venta_formulario.sql`, `test_edicion_preserva_contexto.sql`, `test_venta_editable_sin_cae.sql`, `test_operation_edit_lines.sql`, `test_stock_movements_edicion.sql` y los demás de 0.6). Cada cambio de aserción, justificado en el PR.

## 8. Tanda B — Edición de compra

- [x] 8.1 **RED**: escenarios de compra en el gate de 7.1:
  - crédito (sube, baja con `P0425`, cambio de proveedor traslada el cargo);
  - efectivo y transferencia;
  - efectivo→crédito (antes `credit_transition_not_allowed`);
  - crédito histórico sin proveedor y sin cargo;
  - compra de remito sigue bloqueada;
  - `PurchaseAdjusted` con id estable.
- [x] 8.2 `rpc_atomic_update_purchase_operation` desde el vivo, con la misma firma nueva que la venta y el mismo plan. Se retiran los tres `P0423` de dinero y `credit_transition_not_allowed`; se conserva `credit_requires_supplier` bajo la regla de herencia. GREEN → TRIANGULATE.
- [x] 8.3 Actualizar `test_purchase_cash_optin.sql` (incluida la aserción de `operation_id` distinto en `:410`), `test_compras_proveedor_cuenta_corriente.sql`, `test_compras_gastos_sucursal_por_defecto.sql` y los demás que la ejecutan.

## 9. Tanda B — Edición de gasto

- [x] 9.1 **RED**:
  - gasto en efectivo del día y de una sesión cerrada;
  - efectivo→transferencia (asiento acredita banco);
  - transferencia→efectivo (asiento acredita caja: la huella bancaria quedó en cero);
  - sólo categoría con la caja cerrada, sin escrituras;
  - `credit` sigue rechazado;
  - `p_dry_run`.
- [x] 9.2 `rpc_update_expense` desde el vivo (`DROP` + `CREATE`):
  - plan;
  - se retiran los dos `P0423`;
  - `ExpenseAdjusted` con la contrapartida de la huella **posterior**;
  - auditoría.

  GREEN → TRIANGULATE. Actualizar `test_gastos_forma_pago.sql` y `test_asiento_contable_gastos*.sql`.

## 10. Tanda B — Backend

- [x] 10.1 **RED** (pytest): tri-estado por `model_fields_set` de `cash_session_id`, `bank_account_id` y `due_date` en los tres esquemas; `reason` opcional; vista previa; historial; proyección sin `is_payment_locked` y con `edit_locked_reason`.
- [x] 10.2 Esquemas Pydantic v2 (`backend/schemas/sales.py`, `purchases.py`, `expenses.py`), routers, servicios y repositorios en tres capas:
  - `POST /sales/operation/edit-preview`, `POST /purchases/operation/edit-preview`, `POST /expenses/{id}/edit-preview`;
  - `GET .../edits`, con un único repositorio de lectura de auditoría filtrado por `account_id`.
  - **Desvío**: el historial se lee con una RPC nueva, `rpc_operation_edits` (SECURITY DEFINER, filtra por la cuenta ACTIVA de la sesión y sólo las tres acciones de edición), porque `audit_logs` sólo tiene una policy heredada por `company_id`: una lectura directa con la RLS del usuario no devolvería nunca estas filas. El repositorio único es `OperationEditRepository`.
- [x] 10.3 Proyecciones: `edit_locked_reason` (tokens de D15, fail-closed), `charge_due_date`, `charge_party_id`, `cash_cashbox_id` y su sesión abierta, `bank_account_id` de la huella. **Retirar `is_payment_locked`** de los tres esquemas de salida y de todos los tests de backend.
  - **Desvío (D15)**: los cuatro indicadores y los datos vigentes del formulario salen de UNA función, `op_money_footprint_state` (la hermana de `op_money_footprint_flags` con los datos de precarga), que consumen los tres repositorios por `LATERAL`. `service_lines_locked` pasa del cliente al servidor como token de `edit_locked_reason`.
- [x] 10.4 Capacidad `CAN_CORRECT_MONEY` según OQ-4 en `backend/core/rbac.py`, con el guard en el servicio (espejo de la RPC) y el test que ata base, backend y frontend.
  - **Alcance del guard**: el servicio no puede saber si una edición escribe dinero (lo decide el plan), así que un actor SIN `CAN_CORRECT_MONEY` pide la vista previa —la misma RPC en seco, sin efectos— y corta con 403 `money_edit_requires_admin` si el plan escribe; el dueño y el administrador no pagan ese viaje. `edit_locked_reason` NO emite `money_edit_requires_admin`: un cajero edita la descripción de una venta en efectivo (spec "Corregir dinero ya registrado requiere dueño o administrador").
- [x] 10.5 Mapeo RFC 7807 de los tokens nuevos (`cash_intent_required`, `money_edit_requires_admin`) y de `P0425`/`P0426`/`P0424` en contexto edición. Coverage ≥ el umbral de CI.

## 11. Tanda B — Cierre

- [x] 11.1 Frontend mínimo para no romper: `lib/types.ts` y los listados dejan de leer `isPaymentLocked`; los tests que lo usaban se migran (`grep -rn "isPaymentLocked\|is_payment_locked" frontend` vacío). La superficie completa llega en la tanda C.
- [x] 11.2 Introspección, ACLs (`test_function_acl_gate.sql`), reaplicación dos veces, `KPI_Validation.yml` y suites en verde.
  - **CI (`KPI_Validation.yml`)**: la tanda B cambia la firma de tres funciones, así que los reapply de 20261070000001…20261088000001 dejarían un overload fantasma. Mismo patrón que `multiusuario-operativo` B: tras el último reset de reconvergencia, `supabase/migrations_bak/rollback_20261089000001_edicion_operaciones_dinero.sql` restaura las seis funciones a sus cuerpos de producción (md5 verificado) y borra lo que la tanda B creó —además es la prueba del rollback—, se re-toma la línea base del schema y el reapply de 20261089000001 va al final de la cadena, después del de la tanda A, comparando contra la línea base previa al rebase.
- [x] 11.3 Revisión adversarial (un juez). PR `opsx/edicion-operaciones-con-dinero-apply-b`, CI verde, merge. — Revisión del diff por el orquestador, CI verde, mergeado (#659/#660/#661).
- [x] 11.4 Verificación post-merge en prod, igual que 5.4, más: 0 `P0423` por dinero en los cuerpos vivos y una sola firma de cada edición. — Verificado en prod 2026-11-05 por el orquestador (SQL de solo lectura): MAX(version)=20261089000001 sobre 336 migraciones; 15 funciones con una sola firma y ACLs esperadas; md5 de prosrc igual al de la migración; sin P0423 por dinero en los cuerpos vivos; 0 eventos pendientes; invariante SUM(abierto)=balance con 0 violaciones.

## 12. Tanda C — Formularios en modo edición

- [x] 12.1 **RED** (vitest): en `sale-form`, `purchase-form` y `expense-form-v2`, en modo edición:
  - aparecen los bloques de cuenta corriente (saldo proyectado, vencimiento precargado), caja ("Registrado en caja X" marcado si hay huella) y cuenta bancaria;
  - el payload manda las claves tri-estado sólo cuando cambian;
  - campo "Motivo del cambio".
- [x] 12.2 Quitar los `!isEdit` de `BankAccountDestinationSelect`, el bloque de crédito y el bloque de caja, reutilizando los mismos componentes del alta con copy de edición. Sesión de la sucursal nueva si cambia la sucursal.
  - Cuenta bancaria, cuenta corriente y caja se muestran al editar en los tres formularios con los MISMOS componentes (`BankAccountDestinationSelect`, `CashOptinBlock` con la prop nueva `hadFootprint`, el bloque de crédito de `PurchaseCheckoutFields` y el de `SaleForm`). `useDueDateCascade` gana `initialDueDate` (el vencimiento VIGENTE no sigue la cascada) y `usePurchaseCheckout` gana `hadCash`/`alreadyCharged`.
  - Lógica pura compartida en `lib/money-intent.ts` (`buildEditMoneyIntent`): el tri-estado por ausencia se prueba sin montar nada.
  - El bloque de crédito de la edición **estima** el saldo (sin contar dos veces el cargo vigente); el plan exacto lo da el servidor en la confirmación. Para la caja el formulario resuelve la sesión con `useCashOptin` (primera caja de la sucursal efectiva): si la sucursal tiene varias cajas y la huella está en otra, el plan del servidor lo dice (bloqueo o `cash_intent_required`) en vez de adivinarlo la pantalla.
  - Se retira el aviso de «borrala y volvé a cargarla» de `PurchaseCheckoutFields` (`credit_transition_not_allowed` se retiró en la tanda B).

## 13. Tanda C — Confirmación con el plan del servidor

- [x] 13.1 **RED**:
  - `OperationEditPlanDialog` muestra el plan por libro con el sentido real (entra o sale de la caja);
  - deshabilita la confirmación con su motivo ante un bloqueo;
  - no aparece si el plan no cambia ningún libro;
  - el resultado mostrado sale de la respuesta del servidor;
  - el foco vuelve al control que lo abrió.
- [x] 13.2 `lib/money-plan.ts` (única redacción) y un componente de lista compartido con `DeleteOperationDialog`; hooks `useOperationEditPreview` y mutaciones de edición que invalidan caja, banco, conciliación, cuentas corrientes, `receivables.*`, libro diario y formas de pago, reutilizando las claves existentes.
  - **Desvío (con motivo)**: no existe un hook `useOperationEditPreview`. La vista previa vive como `previewSaleOperationEdit` / `previewPurchaseOperationEdit` (devueltos por `useSales()` / `usePurchases()`) y como función suelta `previewExpenseEdit` (en `use-expenses-query.ts`), todas sobre la misma `fetchEditPreview` de `lib/operation-edit-api.ts` y el mismo constructor de payload que el PUT. Motivo: 25 archivos de test de formularios y listados ya mockean esos hooks de dominio; un hook nuevo importado por los formularios exigía tocar todos para mockear `python-client`. El flujo «guardar → plan → confirmar → ejecutar» es el hook `useEditPlanFlow` (`hooks/use-edit-plan-flow.ts`), compartido por los tres formularios.
  - Las invalidaciones son una sola definición, `invalidateAfterOperationEdit(queryClient, kind)` en `lib/query-invalidation.ts` (con su lista exportada y su test), reutilizando las raíces de `queryKeys`.

## 14. Tanda C — Historial de cambios

- [x] 14.1 **RED**: `OperationEditHistory` en el detalle expandido de las tres pantallas, con carga diferida: fecha, usuario y resumen. Vacío sin ediciones.
- [x] 14.2 Implementación con `useOperationEditHistory` sobre los endpoints de 10.2.
  - `OperationEditHistory` (componente compartido) con su cuerpo `HistoryBody` que recién monta el hook al abrir. Está en el detalle expandido de `/ventas` y `/compras` (sólo si la operación tiene `operation_id`) y, como `/gastos` **no tiene detalle expandido**, bajo cada fila de gasto (cerrado). Convertir las filas de `/gastos` en expandibles queda como candidato.

## 15. Tanda C — Listados y errores

- [x] 15.1 Listados de `/ventas`, `/compras` y `/gastos`:
  - motivo desde `edit_locked_reason` y derivados fiscales;
  - se retiran `PAYMENT_LOCKED_REASON` y sus equivalentes;
  - `title` del lápiz cuando hay dinero registrado;
  - "Editar" deshabilitado por rol según OQ-4.
- [x] 15.2 `lib/operation-errors.ts`: tokens nuevos y mensajes de edición para `P0425`, `P0426` y `P0424`, con tests.
  - `OperationErrorContext` gana `intent: "edit"` y `party`; los cinco bloqueos del plan se redactan con `describeBlock` de `lib/money-plan.ts` (una sola redacción, la misma del diálogo) y los siete tokens restantes tienen su texto. Fuera de la edición, `P0426`/`P0424` conservan su redacción del borrado.

## 16. Tanda C — Verificación visual y accesibilidad

- [x] 16.1 Pasada visual del formulario de edición, el diálogo del plan y el historial en escritorio y móvil (375 px), en tema claro y oscuro, con capturas en `evidence/`. Tokens semánticos y contraste AA (gate `token-contrast-aa`).
  - Arnés `app/dev-harness/edicion-dinero` (componentes REALES contra un backend simulado por intercept de `fetch`) + `e2e/harness/edicion-dinero-visual.spec.ts`: 32 pruebas (venta a crédito, venta en efectivo, compra, gasto, plan sin bloqueo, plan en efectivo, plan con bloqueo, historial × 1366/375 × claro/oscuro), todas verdes; capturas en `evidence/tanda-c/` (32 PNG). No se usó el stack completo con login: las pantallas reales exigen sesión y las tres RPCs ya están cubiertas por los gates SQL de la tanda B.
  - Sólo tokens semánticos (`border-border`, `bg-accent/30`, `text-destructive`, `bg-destructive/10`…); ningún color literal nuevo.
- [x] 16.2 Tests a11y (teclado, `aria-*` del diálogo y del historial) y `tsc` sin errores nuevos.
  - Diálogo: `alertdialog` con nombre y descripción, el foco entra y vuelve al control que lo abrió, `Escape` cierra sin confirmar, el botón deshabilitado apunta al motivo con `aria-describedby`, los bloqueos con `role="alert"`. Historial: botón nativo con `aria-expanded`/`aria-controls`, región con nombre, estados `status`/`alert`.
  - `tsc --noEmit`: los mismos 8 errores preexistentes en 5 archivos de test (LedgerMovementsPanel, purchase-operations-list-payment-lock, use-critical-stock, pos-payment-methods, revenue-canon); ninguno nuevo

## 17. Tanda C — Documentación, cierre y humo

- [x] 17.1 KB: actualizar `knowledge-base/05_reglas_de_negocio.md` (inmutabilidad por dinero retirada, huella neta, corrección de caja de sesión cerrada, emparejamiento del aging) y `knowledge-base/07_flujos_principales.md` (flujo de edición).
- [x] 17.2 `CHANGES.md`: entrada del change con las mediciones y los candidatos que deja ("Nota de crédito" como etiqueta de la reversión por edición; "Último cargo" del panel por `created_at`). Puntero en `CLAUDE.md` y `python scripts/ci/check_docs_sync.py --fix` en el mismo PR.
- [x] 17.3 Revisión adversarial: **revisión por el orquestador** (no se lanza un juez desde el apply). PR `opsx/edicion-operaciones-con-dinero-apply-c`, CI verde, merge. — Revisión del diff por el orquestador, CI verde, mergeado (#659/#660/#661).
- [ ] 17.4 **[PO]** Humo real en prod: — Queda para el PO, no bloquea el archive (docs/pendientes-manuales-po.md §5).
  - editar una venta a crédito (subir el total, cambiar el vencimiento);
  - una venta en efectivo del día;
  - una compra por transferencia;
  - un gasto en efectivo de una sesión cerrada (con la caja de hoy abierta).

  En cada caso, confirmar el plan mostrado, los libros resultantes y el historial de cambios.

### Evidencia TDD — tanda A (apply 2026-11-04)

Safety net (0.6): baseline en verde = la CI de #646 sobre `main` (`1dc70b7c`: pytest, vitest, validate-kpis, playwright). Corridas locales de esta tanda: backend `-m "not integration"` 4385 passed + 7 `test_invoice_pdf.py` (los preexistentes locales); integración de las tres suites nuevas 7 + 5 passed; vitest 580 archivos / 7036 tests passed; cadena de reaplicación de `KPI_Validation.yml` completa (CHAIN_EXIT=0, 20261088000001 idempotente) y los gates SQL del workflow en el orden real.

| Tarea | Test | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|------|------|------------|-----|-------|---------------|----------|
| 1.1–1.4 | `supabase/tests/test_op_money_footprint.sql` (+ `evidence/tanda-a/EQUIVALENCIA-borrado.txt`) | SQL | `test_delete_guard_ledgers`, `test_gastos_forma_pago` en verde | `S1-cc: la huella neta de cuenta corriente debia quedar en 0, es 1200.00` (db4e1319) | S1–S7 + F PASS | 7 escenarios (POS editado en 3 libros, gasto 500→300, caja en 2 sesiones, neto cero, signo invertido, venta sin ediciones, compra) + equivalencia contra el cuerpo previo | — |
| 1.5 | `backend/tests/test_op_money_footprint_projection.py` | Unit + integración | `test_purchases`, `test_gastos_forma_pago`, `test_delete_compensation_flags_contract` | 3 fallos reales: la huella compensada reportaba `(True, True, True)` | 7 passed | ventas, compras, gastos; `is_payment_locked` fijado | — |
| 2.1–2.3 | `supabase/tests/test_aging_reversal_pairing.sql`, `backend/tests/test_aging_reversal_pairing.py` | SQL + unit + integración | `test_receivables_overdue_digest`, `test_c30_customer_supplier_accounts` | `1-X: ... trae vencido=0, 1_30=0, vigente=1700` / `TypeError reversal_type` | 5 lugares SQL + CTE de Python | cadena de ediciones, nota huérfana, nota sin referencia, invariante de cierre | `_customer_open_items`/`_supplier_open_items` como única definición |
| 2.4 | consulta de sólo lectura en prod (`evidence/tanda-a/MEDICION-2.4-aging.md`) | medición | — | — | ningún tramo cambia, saldo intacto | clientes y proveedor | — |
| 3.1–3.4 | `test_journal_consumer_noregression.sql` (14 tipos, validado contra el cuerpo previo y el nuevo), `test_journal_consumer_edicion.sql`, `test_cobranzas_reverso.sql` bloque 11 | SQL | idem + `test_asiento_contable_gastos`, `test_asiento_venta_formulario`, `test_delete_guard_ledgers` | `B1: esperaba [R:SaleOperation:1300C1200,...] y posteo [...D1000,...]` (contra-asiento revertido) | B1–B7 + 11a/b/c | id estable, POS, nota de crédito, `PurchaseAdjusted` ×6 casos, despachador | `_journal_purchase_lines` compartido por Created y Adjusted |
| 4.1–4.3 | `test_edicion_locks_race.sh` (dos conexiones) | SQL race | `test_venta_editable_sin_cae_race` | (c) `la segunda edicion ... EDIT_OK`; (e) `lost update: 'desc original\|999'` | (c) y (e) PASS | compra y gasto | — |
| 4.4 | `test_purchase_edit_journal.sql` | SQL | idem | con el cuerpo previo: falta `PurchaseAdjusted` | PASS | alta → edición ×2 → borrado, histórica sin alta | — |
| 5.1 | `test_function_acl_gate.sql` (+ introspección de la migración) | SQL | gate verde en `main` | `ACL GATE (5a) FAILED ... rpc_atomic_update_purchase_operation` | PASS | reaplicación doble | — |

### Evidencia TDD — tanda B (apply 2026-11-04)

Safety net (0.6): baseline = el de la tanda A (CI de `main` en `78f30c36`); corridas locales de esta tanda: backend `-m "not integration"` 4418 passed + los 7 `test_invoice_pdf.py` preexistentes de este entorno; integración de las proyecciones 3 passed; vitest sin regresiones nuevas; los gates SQL rebasados sobre `db reset` limpio.

| Tarea | Test | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|------|------|------------|-----|-------|---------------|----------|
| 6.1–6.3 | `supabase/tests/test_cash_optin_assert.sql` | SQL | caracterización de las 3 altas (PASA contra el cuerpo vivo) | `function public._cash_optin_assert(...) does not exist` (bloque H) | M 18/18 + H | 3 altas × 6 casos con token, ERRCODE y mensaje exactos; helper directo y variante de corrección | las 3 altas delegan en el helper |
| 7.1–7.5 | `supabase/tests/test_edicion_dinero_venta.sql` (V1–V12) | SQL | `test_venta_editable_sin_cae`, `test_edicion_preserva_contexto` | `V4 estado: esperaba <00000> y dio <P0423>` | V1–V12 PASS | crédito sube/baja/cliente/vencimiento; efectivo del día y de sesión cerrada; sucursal; retroactiva; banco; herencia; entre libros; POS; id estable y auditoría; rol; en seco; borrado después de editar | plan único (`_op_edit_plan`) para las 3 ediciones |
| 7.5 | `supabase/tests/test_edicion_dinero_race.sh` (a, b) | SQL race | `test_edicion_locks_race.sh` | — (script nuevo; ver nota) | PASS | doble guardado de la misma venta (P0404, una sola edición) · dos ediciones que cruzan clientes (sin 40P01) | — |
| 8.1–8.3 | `supabase/tests/test_edicion_dinero_compra_gasto.sql` (P1–P9, R) | SQL | `test_purchase_cash_optin`, `test_compras_proveedor_cuenta_corriente` | `X4 estado: esperaba <00000> y dio <P0423>` | P1–P9 PASS | crédito sube/baja/proveedor; efectivo de sesión cerrada; transferencia; efectivo→crédito; crédito histórico sin proveedor; `PurchaseAdjusted` id estable; auditoría; rol | idem |
| 9.1–9.2 | idem (X1–X8) | SQL | `test_gastos_forma_pago`, `test_asiento_contable_gastos` | idem | X1–X8 PASS | efectivo del día y de sesión cerrada; efectivo↔transferencia con el `kind` del asiento por la huella posterior; solo categoría sin escrituras; `credit` rechazado; en seco | idem |
| 10.1–10.5 | `backend/tests/test_edicion_operaciones_con_dinero.py` + rebase de `test_sales/purchases/gastos/…` | Unit + integración | 4385 passed (A) | 26 failed / 8 passed antes de implementar | 34 passed | tri-estado ×3 esquemas; PUT ×3; vista previa ×3; historial ×3; proyecciones; `CAN_CORRECT_MONEY` atada a base y frontend; guard del servicio; 5 tokens RFC 7807 | `operation_edit` compartido |
| 11.1 | `frontend/__tests__/lib/rbac-capabilities.test.ts` (+ tests migrados) | Unit | vitest completo (A) | tsc: `isPaymentLocked` inexistente en 20 archivos de test | verde | `grep isPaymentLocked\|is_payment_locked frontend` vacío | — |

Nota RED de 7.5: el script de carrera es nuevo y no tiene RED contra un cuerpo anterior (la tanda A ya probó el lock de filas de la compra y del gasto con `test_edicion_locks_race.sh`); no se corrió un mutante que quite el `FOR UPDATE` del recuento, así que su capacidad de detectar la regresión queda sin demostrar por mutación y es un punto a mirar en la revisión.

### Evidencia TDD — tanda C (apply 2026-11-05)

Safety net: baseline de los archivos tocados corrido antes de modificarlos (`delete-operation-dialog`, `operation-errors`, `sale-form-edit-context`, formularios y listados: en verde sobre `main` `b666f343`). Resultado final: vitest completo 592/593 archivos y 7228 tests en verde; los 2 que fallan (banco-conciliacion-import-warnings) vencieron por timeout bajo la carga de la corrida y pasan en aislamiento (8/8). `tsc --noEmit`: los mismos 8 errores preexistentes en 5 archivos de test (LedgerMovementsPanel, purchase-operations-list-payment-lock, use-critical-stock, pos-payment-methods, revenue-canon); ninguno nuevo.

| Tarea | Test | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|------|------|------------|-----|-------|---------------|----------|
| 13.1–13.2 | `__tests__/lib/money-plan.test.ts` | Unit | — (módulo nuevo) | módulo inexistente (`Failed to resolve import`) | 22 passed | cuenta corriente revierte/registra (cliente y proveedor, con y sin vencimiento), caja de venta vs. compra/gasto (entra/sale/vuelve), `both`, banco ingreso/egreso/inverso, 6 tokens de bloqueo, comprobante, resumen del historial (venta/gasto/sin cambios), `moneyEditAffordance` | `voidedFiscalText` única, consumida por `delete-compensation` |
| 12.2 | `__tests__/lib/money-intent.test.ts` | Unit | — (módulo nuevo) | `Failed to resolve import "@/lib/money-intent"` | 13 passed | caja ×7 (sin huella, tildar, conservar, destildar, sucursal nueva, sin sesión, forma de pago no efectivo), banco, vencimiento, motivo, payload | — |
| 15.2 | `__tests__/lib/operation-errors-money-edit.test.ts` | Unit | 82 passed en `operation-errors*` | 14 failed (los tokens se mostraban crudos) | 82 passed | P0425 cliente/proveedor/sin contexto, P0426 y P0424 en edición y fuera de ella, 9 tokens nuevos | los bloqueos del plan delegan en `describeBlock` |
| 13.1 | `__tests__/components/OperationEditPlanDialog.test.tsx` | Component + a11y | 3 archivos del diálogo de borrado en verde | `Failed to resolve import` | 17 passed | sentido de la caja (venta/compra), respuesta del servidor, bloqueo (1 y varios), no aparece sin efecto, foco de vuelta, Escape, nombre/descripción | `MoneyPlanList` extraída y consumida por `DeleteOperationDialog` (sus 22 tests siguen verdes) |
| 13.2 | `__tests__/hooks/use-edit-plan-flow.test.tsx`, `__tests__/lib/query-invalidation-operation-edit.test.ts` | Unit | — | `Failed to resolve import` | 8 + 11 passed | directo / plan con efecto / sin efecto / bloqueo / error de vista previa / cancelar / doble guardado; raíces por documento | — |
| 14.1–14.2 | `__tests__/components/OperationEditHistory.test.tsx`, `__tests__/hooks/use-operation-edit.test.tsx` | Component + hook | — | `Failed to resolve import` | 10 + 6 passed | carga diferida, fecha/usuario/resumen/motivo, vacío, cargando, error + reintentar, gasto («Importe»), a11y | `HistoryBody` monta el hook sólo al abrir |
| 12.1 venta | `__tests__/components/sale-form-edit-money.test.tsx` | Component | 101 passed en 14 archivos `sale-form*`/`CashOptinBlock`/`use-due` | 17 failed / 4 passed | 21 passed | crédito (saldo sin doble cuenta, vencimiento vigente), efectivo con y sin huella, banco, motivo, 7 payloads por ausencia, plan (directo, mismo payload, confirmar, volver, bloqueo, aviso del servidor, error humanizado) | — |
| 12.1 compra | `__tests__/components/purchase-form-edit-money.test.tsx` + `use-purchase-checkout.test.ts` + `PurchaseCheckoutFields.test.tsx` | Component + hook | 93 passed en `purchase-form*` | 14 failed / 3 passed; hook 5 failed; fields 2 failed (contra el cuerpo previo) | 17 + 21 + 26 passed | espejo de venta + pasar a crédito sin aviso, `hadCash`, `requiresDate`, `alreadyCharged` | `PurchaseCheckoutFields` sin la rama de transición |
| 12.1 gasto | `__tests__/components/expense-form-edit-money.test.tsx` | Component | `expense-form*` + `gastos.a11y` en verde | 16 failed / 2 passed | 18 passed | caja marcada/desmarcada, banco requerido sólo si el kind pasa a bancario, payload, plan, aviso, error humanizado | — |
| 15.1 | `__tests__/components/operations-list-money-edit.test.tsx`, `__tests__/pages/GastosPage-money-edit.test.tsx` | Component | 131 passed en listados | 10 failed / 7 passed; 5 failed / 3 passed | 17 + 8 passed | 3 libros × (ventas, compras), rol sin capacidad con/sin dinero, historial por `operation_id`, gasto | — |
| 16.1 | `e2e/harness/edicion-dinero-visual.spec.ts` | Navegador (Playwright, arnés) | — | — | 32 passed | 4 formularios, 3 planes, historial × 2 anchos × 2 temas; sin desborde horizontal, CTA dentro del diálogo, confirmación deshabilitada con bloqueo | — |

**Tests previos migrados** (el comportamiento que fijaban cambió a propósito, cada cambio justificado en el PR): `use-purchase-checkout.test.ts` y `PurchaseCheckoutFields.test.tsx` (caja, banco y crédito se ofrecen al editar; se retira el aviso de transición), `purchase-form-cash-optin.test.tsx` y `purchase-form-supplier.test.tsx` (ídem), `expense-form-payment-effects.test.tsx` (edición ofrece caja y banco; espera la caja), tres tests de listado de compras (el lápiz tiene nombre accesible ahora), y el mock de `use-operation-edit` / `use-collection-settings` en 24 archivos de test que renderizan los listados, la página de gastos o `PurchaseForm`.

## Evidencia TDD (plantilla del plan)

| Tarea | Test | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|-------|------|------|------------|-----|-------|---------------|----------|
| 1.1–1.4 | `supabase/tests/test_op_money_footprint.sql` | SQL | | | | | |
| 1.5 | `backend/tests/test_*_repository*` | Unit | | | | | |
| 2.1–2.3 | `supabase/tests/…aging…`, `backend/tests/…aging…` | SQL/Unit | | | | | |
| 3.1–3.4 | `supabase/tests/…journal…`, gate del outbox | SQL | | | | | |
| 4.1–4.4 | `*_race.sh`, gate compra editada y borrada | SQL | | | | | |
| 6.1–6.3 | gate del opt-in | SQL | | | | | |
| 7.1–7.6 | `supabase/tests/test_edicion_operaciones_con_dinero.sql` | SQL | | | | | |
| 8.1–8.3 | ídem (compra) | SQL | | | | | |
| 9.1–9.2 | ídem (gasto) | SQL | | | | | |
| 10.1–10.5 | `backend/tests/test_edicion_operaciones_con_dinero.py` | Unit/Integration | | | | | |
| 12–15 | `frontend/__tests__/…` | Component | | | | | |
