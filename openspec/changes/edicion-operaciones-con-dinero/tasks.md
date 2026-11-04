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

- [ ] 0.1 **[PO]** Sign-off de OQ-1..OQ-6 (`design.md` §Open Questions).
  - Registrar la respuesta textual en `design.md` antes de escribir producción.
  - Si el PO elige una alternativa a la recomendada, actualizar en el mismo PR la decisión, las specs y estas tareas.
  - **OQ-4 (rol) se cierra junto con `multiusuario`.** Sin sign-off no hay apply: es governance ALTA.
- [ ] 0.2 Confirmar que ya están mergeados y en prod: `fix/stock-edicion-sucursal-y-piso`, la tanda B de `remitos-compra` y, antes de la tanda B de este change, `multiusuario`. Anotar los números de migración que ocuparon (`gh pr list --state all`, `MAX(version)` de prod). Si alguno no mergeó, la tanda que depende de él no empieza (la tanda A sólo depende de los dos primeros).
- [ ] 0.3 **Checkpoint de cuerpo vivo de la tanda en curso.**
  - Leer de prod `pg_get_functiondef`, `obj_description` y ACL de cada función que la tanda redefine.
  - Comparar el `md5` (sin `\r`) contra el de `design.md` §Context, tomado el 2026-10-14. Los hermanos cambian varias de estas funciones, así que **se espera divergencia**: partir siempre del vivo y anotar el desvío.
  - Guardar los cuerpos previos en `evidence/<tanda>/` para el rollback.
- [ ] 0.4 Re-medir en prod (sólo `SELECT`) las cifras de `proposal.md` (bloqueadas por motivo, cajas cerradas, cargos con saldo menor, movimientos en período conciliado, 0 eventos pendientes) y las 6 `credit_note` históricas con su referencia. Si algo cambió, actualizar `design.md` en el mismo PR.
- [ ] 0.5 **Inventario de CI.** En `.github/workflows/KPI_Validation.yml`, listar los bloques de reaplicación que fijan cuerpos de las funciones que la tanda redefine, y aplicar su "REGLA PARA EL PR SIGUIENTE" en el mismo PR (retirarlos o actualizarlos), igual que `remitos-compra` 1.9.
- [ ] 0.6 **Safety net**: baseline en verde, registrado.
  - backend `-m "not integration"` + integración;
  - vitest completo y `tsc`;
  - los gates SQL del workflow sobre `db reset` limpio, en especial los 17 que ejecutan las RPCs de edición, `test_delete_guard_ledgers.sql`, `test_gastos_forma_pago.sql`, `test_cobranzas_vencimientos*.sql`, el gate del conjunto canónico del outbox y `test_function_acl_gate.sql`.

  Un pre-existente en rojo se reporta y no se corrige acá.

## 1. Tanda A — Huella neta y borrado sobre la huella

- [ ] 1.1 **RED**: gate `supabase/tests/test_op_money_footprint.sql`, con dos cuentas, fixtures propios y cleanup asertado.
  - Una venta del POS con caja, editada a mano como `postgres` (movimiento original + reversión + nuevo con la misma referencia), se borra.
  - Hoy `rpc_delete_sale_operation` compensa la suma del tipo `sale`, no el neto: ver el doble conteo.
  - Lo mismo para un gasto y para la caja repartida en dos sesiones de la misma caja.
- [ ] 1.2 Función interna de huella neta (D3), por `(libro, cuenta del libro, referencia)`:
  - cuenta corriente: `sale`/`credit_note` y `purchase`/`debit_note`;
  - caja: agrupada por caja;
  - banco: agrupado por cuenta y por familia de tipo.

  Más su variante legible por la aplicación (`SECURITY INVOKER`, sin `_` inicial). Nombre y ACL compatibles con los chequeos (3) y (4) de `test_function_acl_gate.sql`.
- [ ] 1.3 Reescribir `rpc_delete_sale_operation`, `rpc_delete_purchase_operation` y `rpc_delete_expense` desde el vivo para que compensen la huella neta, con una compensación por fila de huella y la **misma referencia**. Se conservan el orden de guards, `P0425`, `P0426`, el espejo `unreconciled`, el remito y los eventos.
- [ ] 1.4 GREEN → **TRIANGULATE**:
  - venta del formulario y del POS, compra, gasto;
  - neto cero sin movimientos;
  - signo invertido plantado (se compensa igual);
  - caja en dos sesiones (una compensación);
  - borrado sobre datos sin ediciones, con los mismos libros e importes que antes (gate de equivalencia contra el cuerpo previo guardado en `evidence/`).
- [ ] 1.5 Las proyecciones de lectura (`backend/repositories/sales_repository.py`, `purchase_repository.py`, `expense_repository.py`) pasan `has_account_charge`, `has_cash_movement`, `has_bank_movement` e `is_delete_blocked` a la huella neta, consumiendo la función de 1.2 y no un `EXISTS`. `is_payment_locked` todavía **no** se toca (grupo 10). Tests de backend: RED con una operación de huella compensada que hoy reporta `has_cash_movement = true`.

## 2. Tanda A — Emparejamiento de reversiones en el aging FIFO

- [ ] 2.1 **RED**: en `supabase/tests/` y en `backend/tests/` (aging), una cuenta con un cargo A más viejo y un cargo B que se revierte y se vuelve a registrar con la misma referencia. Hoy la reversión cancela A. Agregar también una cadena de dos ediciones y el invariante de cierre con todos los tipos.
- [ ] 2.2 Aplicar la regla de D9 en `backend/repositories/_account_aging_sql.py`, la única definición Python, con cuatro consumidores.
- [ ] 2.3 Aplicar la misma regla desde el vivo en `rpc_receivables_report`, `rpc_payables_report`, `_produce_receivables_overdue_digest` y las dos RPCs de cambio de vencimiento de `20261033000001`. Gate que compare, para un mismo ledger sintético, el reparto que dan los siete lugares.
- [ ] 2.4 Medir en prod antes y después (`SELECT` sobre la definición nueva aplicada a datos vivos, en el stack local con un volcado anónimo o por consulta de sólo lectura) el reparto por tramo de las cuentas con las 6 `credit_note` históricas. Saldo total sin cambios. Informar al PO en el PR.

## 3. Tanda A — Consumidor contable

- [ ] 3.1 **Checkpoint**: `md5` vivo de `_journal_post_from_event` y del despachador. RED en `supabase/tests/`:
  - asiento vigente con un contra-asiento de igual referencia: hoy `SaleOperationDeleted` puede elegir el contra-asiento;
  - `CreditNoteIssued` sobre una venta cuyo asiento vigente es `SaleOperation`: hoy reintenta `P0451`.
- [ ] 3.2 Reescritura desde el vivo:
  - `reversal_of IS NULL` y orden descendente en las búsquedas de `SaleOperationAdjusted`, `SaleOperationDeleted`, `PurchaseDeleted` y `CreditNoteIssued`, y en `ExpenseDeleted` si el vivo no lo tiene (`ExpenseAdjusted` ya lo tiene);
  - `SaleOperationAdjusted` con las dos convenciones (`sales_order_id` del payload);
  - `CreditNoteIssued` con las dos convenciones.

  Las demás ramas quedan byte a byte, con un gate de no-regresión que postea un evento de cada tipo preexistente y compara el asiento.
- [ ] 3.3 Rama `PurchaseAdjusted`: reversión como `PurchaseDeleted` + posteo como `PurchaseCreated`, compartiendo la resolución de cuentas con una función o expresión única. `P0451` y `P0450`. RED → GREEN → triangular: efectivo→efectivo, efectivo→crédito, con IVA, adelantado al alta y doble proceso.
- [ ] 3.4 Conjunto canónico de 15 tipos en el filtro del despachador **y** en el del helper, en el mismo commit. Actualizar el gate del invariante y su matriz de evasión.

## 4. Tanda A — Concurrencia y productor de `PurchaseAdjusted`

- [ ] 4.1 **RED**: en un gate de carrera (`*_race.sh`, molde de `test_ventas_unidades_conversion_race.sh`), dos ediciones concurrentes de la misma compra. Hoy las dos aplican.
- [ ] 4.2 `rpc_atomic_update_purchase_operation` desde el vivo:
  - toma las filas `FOR UPDATE` en orden ascendente y recuenta (`P0404`), como la venta;
  - emite `PurchaseAdjusted` si existe `PurchaseCreated` para la operación. En la tanda A la compra con dinero sigue bloqueada y el `operation_id` todavía se regenera, así que el payload lleva el `operation_id` viejo y el nuevo, y la rama de 3.3 resuelve por el viejo. La tanda B lo vuelve estable.
- [ ] 4.3 `rpc_update_expense` desde el vivo: `FOR UPDATE` sobre la fila del gasto. Gate de carrera.
- [ ] 4.4 Gate: compra asentada → editada → borrada termina con todos sus asientos revertidos y 0 eventos con `P0451` (cierra el defecto latente de `design.md` §Context).

## 5. Tanda A — Cierre

- [ ] 5.1 `test_function_acl_gate.sql` con las funciones nuevas. Introspección al final de la migración:
  - una firma viva por función;
  - ACLs;
  - cuerpos con `reversal_of IS NULL` y los dos filtros con 15 tipos.

  Reaplicar la migración dos veces sin error.
- [ ] 5.2 Cablear los gates nuevos en `KPI_Validation.yml`. Todos los gates del workflow en verde sobre `db reset` limpio. Backend y frontend en verde.
- [ ] 5.3 Revisión adversarial del diff de la tanda A (un juez). PR `opsx/edicion-operaciones-con-dinero-apply-a`, CI verde, merge.
- [ ] 5.4 **Verificación post-merge en prod**:
  - `MAX(version)`;
  - una firma viva y su ACL;
  - `md5` del vivo igual al de la migración;
  - 0 eventos pendientes con `P0451`;
  - invariante de cierre del aging en todas las cuentas corrientes (`SELECT`).

  Registrar en `CHANGES.md`.

## 6. Tanda B — Validación única del opt-in de caja

- [ ] 6.1 **RED**: gate con la matriz de las tres condiciones (`kind`, sesión abierta de la sucursal y de la cuenta, fecha de hoy) contra `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation` (o `_purchase_operation_core`) y `rpc_create_expense`, registrando tokens y códigos actuales. Correrlo contra el vivo y guardar el resultado como referencia.
- [ ] 6.2 Crear `_cash_optin_assert` (D16) con los predicados copiados del vivo. Agregar la variante "corrección" (sin fecha de hoy si ya había huella de caja).
- [ ] 6.3 Migrar las tres altas al helper, desde el vivo. Gate de 6.1: veredictos y mensajes idénticos.

## 7. Tanda B — Plan y edición de venta

- [ ] 7.1 **RED** (`supabase/tests/test_edicion_operaciones_con_dinero.sql`, dos cuentas, roles reales y cleanup asertado), uno por escenario de `specs/operation-money-edit` y de los deltas de libros:
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
- [ ] 7.2 Función interna de **plan** (D13): huella, efecto deseado, acción y bloqueos, sin escrituras.
- [ ] 7.3 `rpc_atomic_update_sale_operation` desde el vivo (`DROP` + `CREATE` con la firma nueva):
  - parámetros nuevos: `p_cash_session_id`/`p_cash_provided`, `p_bank_account_id`/`p_bank_account_provided`, `p_due_date`/`p_due_date_provided`, `p_reason`, `p_dry_run`;
  - se retiran los tres `P0423` de dinero;
  - orden de D12;
  - `operation_id` estable (legacy: uno nuevo);
  - escrituras por plan (cuenta corriente: nuevo y después reversión; caja; banco);
  - caso B y C contable extendido al POS;
  - `audit_logs`.

  Conservar el guard de remito, el fiscal, la tenencia del cliente y el recálculo de la orden.
- [ ] 7.4 Checkpoint: verificar que `_sales_order_sync_from_operation` recalcula también la forma de pago de la orden. Si no lo hace, extenderlo desde el vivo con su gate, porque el listado lee `COALESCE(pm, pos_pm)`.
- [ ] 7.5 GREEN → **TRIANGULATE** hasta cubrir 7.1, más:
  - mutantes muertos: reversión antes del cargo, compensar por tipo en vez de neto, escribir con H = E, sin `reversal_of IS NULL`, la fecha de hoy exigida en la corrección;
  - gate de carrera: doble guardado, y dos ediciones que cruzan clientes sin `40P01`;
  - gate que **ejecuta** la RPC también en modo `p_dry_run`.
- [ ] 7.6 Actualizar los gates existentes que asumían el `P0423` por dinero o el `operation_id` regenerado (`test_pagos_cableados_restantes.sql`, `test_pos_banco_movimientos.sql`, `test_asiento_venta_formulario.sql`, `test_edicion_preserva_contexto.sql`, `test_venta_editable_sin_cae.sql`, `test_operation_edit_lines.sql`, `test_stock_movements_edicion.sql` y los demás de 0.6). Cada cambio de aserción, justificado en el PR.

## 8. Tanda B — Edición de compra

- [ ] 8.1 **RED**: escenarios de compra en el gate de 7.1:
  - crédito (sube, baja con `P0425`, cambio de proveedor traslada el cargo);
  - efectivo y transferencia;
  - efectivo→crédito (antes `credit_transition_not_allowed`);
  - crédito histórico sin proveedor y sin cargo;
  - compra de remito sigue bloqueada;
  - `PurchaseAdjusted` con id estable.
- [ ] 8.2 `rpc_atomic_update_purchase_operation` desde el vivo, con la misma firma nueva que la venta y el mismo plan. Se retiran los tres `P0423` de dinero y `credit_transition_not_allowed`; se conserva `credit_requires_supplier` bajo la regla de herencia. GREEN → TRIANGULATE.
- [ ] 8.3 Actualizar `test_purchase_cash_optin.sql` (incluida la aserción de `operation_id` distinto en `:410`), `test_compras_proveedor_cuenta_corriente.sql`, `test_compras_gastos_sucursal_por_defecto.sql` y los demás que la ejecutan.

## 9. Tanda B — Edición de gasto

- [ ] 9.1 **RED**:
  - gasto en efectivo del día y de una sesión cerrada;
  - efectivo→transferencia (asiento acredita banco);
  - transferencia→efectivo (asiento acredita caja: la huella bancaria quedó en cero);
  - sólo categoría con la caja cerrada, sin escrituras;
  - `credit` sigue rechazado;
  - `p_dry_run`.
- [ ] 9.2 `rpc_update_expense` desde el vivo (`DROP` + `CREATE`):
  - plan;
  - se retiran los dos `P0423`;
  - `ExpenseAdjusted` con la contrapartida de la huella **posterior**;
  - auditoría.

  GREEN → TRIANGULATE. Actualizar `test_gastos_forma_pago.sql` y `test_asiento_contable_gastos*.sql`.

## 10. Tanda B — Backend

- [ ] 10.1 **RED** (pytest): tri-estado por `model_fields_set` de `cash_session_id`, `bank_account_id` y `due_date` en los tres esquemas; `reason` opcional; vista previa; historial; proyección sin `is_payment_locked` y con `edit_locked_reason`.
- [ ] 10.2 Esquemas Pydantic v2 (`backend/schemas/sales.py`, `purchases.py`, `expenses.py`), routers, servicios y repositorios en tres capas:
  - `POST /sales/operation/edit-preview`, `POST /purchases/operation/edit-preview`, `POST /expenses/{id}/edit-preview`;
  - `GET .../edits`, con un único repositorio de lectura de auditoría filtrado por `account_id`.
- [ ] 10.3 Proyecciones: `edit_locked_reason` (tokens de D15, fail-closed), `charge_due_date`, `charge_party_id`, `cash_cashbox_id` y su sesión abierta, `bank_account_id` de la huella. **Retirar `is_payment_locked`** de los tres esquemas de salida y de todos los tests de backend.
- [ ] 10.4 Capacidad `CAN_CORRECT_MONEY` según OQ-4 en `backend/core/rbac.py`, con el guard en el servicio (espejo de la RPC) y el test que ata base, backend y frontend.
- [ ] 10.5 Mapeo RFC 7807 de los tokens nuevos (`cash_intent_required`, `money_edit_requires_admin`) y de `P0425`/`P0426`/`P0424` en contexto edición. Coverage ≥ el umbral de CI.

## 11. Tanda B — Cierre

- [ ] 11.1 Frontend mínimo para no romper: `lib/types.ts` y los listados dejan de leer `isPaymentLocked`; los tests que lo usaban se migran (`grep -rn "isPaymentLocked\|is_payment_locked" frontend` vacío). La superficie completa llega en la tanda C.
- [ ] 11.2 Introspección, ACLs (`test_function_acl_gate.sql`), reaplicación dos veces, `KPI_Validation.yml` y suites en verde.
- [ ] 11.3 Revisión adversarial (un juez). PR `opsx/edicion-operaciones-con-dinero-apply-b`, CI verde, merge.
- [ ] 11.4 Verificación post-merge en prod, igual que 5.4, más: 0 `P0423` por dinero en los cuerpos vivos y una sola firma de cada edición.

## 12. Tanda C — Formularios en modo edición

- [ ] 12.1 **RED** (vitest): en `sale-form`, `purchase-form` y `expense-form-v2`, en modo edición:
  - aparecen los bloques de cuenta corriente (saldo proyectado, vencimiento precargado), caja ("Registrado en caja X" marcado si hay huella) y cuenta bancaria;
  - el payload manda las claves tri-estado sólo cuando cambian;
  - campo "Motivo del cambio".
- [ ] 12.2 Quitar los `!isEdit` de `BankAccountDestinationSelect`, el bloque de crédito y el bloque de caja, reutilizando los mismos componentes del alta con copy de edición. Sesión de la sucursal nueva si cambia la sucursal.

## 13. Tanda C — Confirmación con el plan del servidor

- [ ] 13.1 **RED**:
  - `OperationEditPlanDialog` muestra el plan por libro con el sentido real (entra o sale de la caja);
  - deshabilita la confirmación con su motivo ante un bloqueo;
  - no aparece si el plan no cambia ningún libro;
  - el resultado mostrado sale de la respuesta del servidor;
  - el foco vuelve al control que lo abrió.
- [ ] 13.2 `lib/money-plan.ts` (única redacción) y un componente de lista compartido con `DeleteOperationDialog`; hooks `useOperationEditPreview` y mutaciones de edición que invalidan caja, banco, conciliación, cuentas corrientes, `receivables.*`, libro diario y formas de pago, reutilizando las claves existentes.

## 14. Tanda C — Historial de cambios

- [ ] 14.1 **RED**: `OperationEditHistory` en el detalle expandido de las tres pantallas, con carga diferida: fecha, usuario y resumen. Vacío sin ediciones.
- [ ] 14.2 Implementación con `useOperationEditHistory` sobre los endpoints de 10.2.

## 15. Tanda C — Listados y errores

- [ ] 15.1 Listados de `/ventas`, `/compras` y `/gastos`:
  - motivo desde `edit_locked_reason` y derivados fiscales;
  - se retiran `PAYMENT_LOCKED_REASON` y sus equivalentes;
  - `title` del lápiz cuando hay dinero registrado;
  - "Editar" deshabilitado por rol según OQ-4.
- [ ] 15.2 `lib/operation-errors.ts`: tokens nuevos y mensajes de edición para `P0425`, `P0426` y `P0424`, con tests.

## 16. Tanda C — Verificación visual y accesibilidad

- [ ] 16.1 Pasada visual del formulario de edición, el diálogo del plan y el historial en escritorio y móvil (375 px), en tema claro y oscuro, con capturas en `evidence/`. Tokens semánticos y contraste AA (gate `token-contrast-aa`).
- [ ] 16.2 Tests a11y (teclado, `aria-*` del diálogo y del historial) y `tsc` sin errores nuevos.

## 17. Tanda C — Documentación, cierre y humo

- [ ] 17.1 KB: actualizar `knowledge-base/05_reglas_de_negocio.md` (inmutabilidad por dinero retirada, huella neta, corrección de caja de sesión cerrada, emparejamiento del aging) y `knowledge-base/07_flujos_principales.md` (flujo de edición).
- [ ] 17.2 `CHANGES.md`: entrada del change con las mediciones y los candidatos que deja ("Nota de crédito" como etiqueta de la reversión por edición; "Último cargo" del panel por `created_at`). Puntero en `CLAUDE.md` y `python scripts/ci/check_docs_sync.py --fix` en el mismo PR.
- [ ] 17.3 Revisión adversarial (un juez). PR `opsx/edicion-operaciones-con-dinero-apply-c`, CI verde, merge.
- [ ] 17.4 **[PO]** Humo real en prod:
  - editar una venta a crédito (subir el total, cambiar el vencimiento);
  - una venta en efectivo del día;
  - una compra por transferencia;
  - un gasto en efectivo de una sesión cerrada (con la caja de hoy abierta).

  En cada caso, confirmar el plan mostrado, los libros resultantes y el historial de cambios.

## Evidencia TDD

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
