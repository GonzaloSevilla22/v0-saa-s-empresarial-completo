> **Governance: MEDIA con tramo ALTO.** Los grupos 3, 4, 5 y 6 escriben dinero real en cuatro
> libros. Cada uno lleva un **🛑 checkpoint** explícito: se para, se muestra lo hecho y se sigue
> sólo con visto bueno. Los grupos 1, 2, 8-14 son autónomos.
>
> **TDD estricto** en backend y frontend: test que falla → mínimo código → triangular → refactor.
> Nunca aserciones triviales. Los gates SQL exigen **control negativo** (§7.7).
>
> **Toda commit vía PR, jamás a `main`.** Rama: `opsx/cobranzas-reverso-apply`.

> **Sign-off del PO (2026-09-02, "continua"):** las 5 OQs del design quedan resueltas
> por su recomendación (default del proyecto cuando el PO no objeta, confirmado por
> el "continua"): **OQ-1** el cobro/pago anulado se BORRA (no `voided_at`); **OQ-2**
> motivo OPCIONAL pero visible en el diálogo y viaja al contra-movimiento de caja y
> al payload del evento; **OQ-3** `is_account_writer` anula, igual que cobra; **OQ-4**
> SIN ventana temporal — el molde `P0426` + sesión abierta actual ya produce el único
> límite que importa; **OQ-5** `payment_method` NULL de las filas con documento
> borrado se acepta (cosmético, ya pasa con los 7 pagos históricos).

## 1. Checkpoint de integridad de función (ANTES de escribir una línea de SQL)

- [x] 1.1 Re-capturar `md5(pg_get_functiondef(oid))` + `length` de las 12 funciones de `baseline/prod_measurements_2026-09-02.md` (la query está en el archivo) vía `mcp__supabase__execute_sql`.
- [x] 1.2 Comparar contra la tabla del baseline. **12/12 hashes COINCIDEN EXACTO** contra el baseline — cero divergencia. PASA.
- [x] 1.3 Volcados a `baseline/live_functiondefs/`: `_journal_post_from_event.sql`, `rpc_process_outbox_dispatch.sql` (las dos que se reescriben) y `rpc_delete_expense.sql` (el molde). La reescritura partió de esos archivos.
- [x] 1.4 Re-verificada la correlativa: `MAX(version)` en prod = `20261018000001` (267 filas), idéntico al último archivo de `origin/main` tras `git fetch` (`249bfbd`, sin ninguna rama `opsx/*-apply` de otro change pendiente de merge). `20261019000001` confirmado, sin renumerar.
- [x] 1.5 Estado de datos re-medido 2026-09-02, **idéntico al baseline**: 6 `payments_received` + 1 `payments_made`, 0/7 con `payment_method`, 6/6 y 1/1 con asiento `posted`, 6 `bank_movements`, 0 `cash_movements` de tipo pago, 75 `cash_movements` totales, 4 sesiones abiertas. Nada cambió materialmente.

## 2. Migración — CHECKs de los tres ledgers (idempotente, aditiva)

- [x] 2.1 Creado `supabase/migrations/20261019000001_cobranzas_reverso.sql` con cabecera que documenta procedencia, hashes del baseline y el número de change.
- [x] 2.2 `cash_movements.movement_type`: `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` con los **13** tipos. Idempotente (verificado con reaplicación directa vía psql — sin error, mismo resultado).
- [x] 2.3 `customer_account_movements.movement_type`: ampliado a **5**.
- [x] 2.4 `supplier_account_movements.movement_type`: ampliado a **5**.
- [x] 2.5 Verificado con `supabase db reset` (aplica desde cero, sin filas previas que invalidar) + reaplicación directa del archivo vía `psql` sobre la DB ya poblada: sin error, `ALTER TABLE` × 6 no-op en el segundo pase.

## 3. 🛑 Migración — `rpc_reverse_payment_received`

- [x] 3.1 RPC `SECURITY DEFINER`, `SET search_path = public`, firma `(p_payment_id uuid, p_reason text DEFAULT NULL) RETURNS jsonb`, calcada de `rpc_delete_expense`.
- [x] 3.2 Guards en orden: `auth.uid()` no nulo → `current_account_ids()` (`P0403`) → `is_account_writer` (`P0401`) → resolver el pago con `WHERE id = p_payment_id AND account_id = v_account_id`, `P0404` si no aparece, mensaje que no revela tenencia ajena (D8).
- [x] 3.3 Cuenta corriente: `c30_register_customer_account_movement(v_payment.customer_account_id, v_payment.amount, 'payment_received_reversal', p_payment_id)`. Sin traducción `P0409`→`P0425` — comentario D6 en el cuerpo.
- [x] 3.4 Caja: bloque calcado del molde, guard `v_cash_amount <> 0`, sesión abierta más reciente de la misma caja, `P0426` si no hay, `c28_register_cash_movement(v_open_session_id, -v_cash_amount, 'payment_received_reversal', p_payment_id, p_reason)`.
- [x] 3.5 Banco: loop sobre `bank_movements` con `source_doc_type='payment_received'`, inversión `transfer_in↔transfer_out`, `_register_bank_movement`, descripción con motivo.
- [x] 3.6 Evento: `INSERT` plano sin `EXCEPTION` de `PaymentReceivedReversed`, `aggregate_type='CustomerAccount'`, payload completo.
- [x] 3.7 `DELETE FROM payments_received ...` al final, después de las cuatro compensaciones.
- [x] 3.8 `RETURN jsonb` con `payment_id`, `reversed=true`, `account_movement_id`, `cash_reversal_id`, `bank_reversals`.
- [x] 3.9 `REVOKE ALL ... FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE TO authenticated` en la misma migración. Verificado: `anon_exec=false`, `auth_exec=true`.
- [x] 3.10 🛑 Checkpoint: SQL completo escrito, aplicado y verificado contra el molde antes de seguir con el grupo 4.

## 4. 🛑 Migración — `rpc_reverse_payment_made` (espejo)

- [x] 4.1 Espejo exacto del grupo 3 sobre `payments_made` / `supplier_account_movements` / `supplier_accounts`, `payment_made_reversal`, `source_doc_type='payment_made'`, evento `PaymentMadeReversed` (`aggregate_type='SupplierAccount'`).
- [x] 4.2 Signo: movimiento de caja del pago es negativo, reversa positiva. Guard sigue siendo `<> 0` (comentado en el cuerpo).
- [x] 4.3 `REVOKE`/`GRANT` igual que 3.9. Verificado: `anon_exec=false`, `auth_exec=true`.
- [x] 4.4 🛑 Checkpoint: diff contra el grupo 3 confirmado — única diferencia tabla/tipo/signo/evento.

## 5. 🛑 Migración — dos ramas en `_journal_post_from_event`

- [x] 5.1 Partido del volcado vivo de 1.3, copiado el archivo entero y editado (no reescrito de memoria).
- [x] 5.2 Filtro `v_event_type NOT IN (...)` ampliado de 9 a 11 tipos.
- [x] 5.3 Rama `PaymentReceivedReversed` calcada de `PurchaseDeleted`: localiza por `(CustomerAccount, payment_id, posted, account_id)`; `P0451` si no aparece; contra-entry con `reversal_of`; líneas invertidas.
- [x] 5.4 Rama `PaymentMadeReversed`: idéntica con `SupplierAccount`.
- [x] 5.5 Verificado: el ASSERT de balance genérico (`v_event_type != 'CreditNoteIssued'`) cubre las dos ramas nuevas sin código adicional.
- [x] 5.6 Diff contra el volcado vivo: las 9 ramas preexistentes quedaron byte a byte (verificado por lectura del archivo final contra el baseline).
- [x] 5.7 🛑 Checkpoint: diff mostrado y aplicado sin error en `supabase db reset`.

## 6. 🛑 Migración — filtro del Consumer 3 en `rpc_process_outbox_dispatch`

- [x] 6.1 Partido del volcado vivo de 1.3. `IF v_event.event_type IN (...)` del Consumer 3 ampliado de 9 a 11 tipos, mismo conjunto que 5.2.
- [x] 6.2 Comentario de cabecera actualizado.
- [x] 6.3 Diff contra el volcado: Consumers 1, 2 y 4 y el aislamiento por evento quedaron byte a byte.
- [x] 6.4 🛑 Checkpoint: diff mostrado y aplicado sin error.

## 7. Gates SQL

- [x] 7.1 `supabase/tests/test_cobranzas_reverso.sql` — nuevo, con el patrón de los gates existentes (setup de 2 tenants + 11 bloques de escenario + cleanup).
- [x] 7.2 Caso: anular un cobro en efectivo con cuenta corriente + caja + asiento → los tres contra-movimientos existen, el documento no, el saldo volvió al valor previo. (Caso bancario en 7.3, dado que un mismo pago no tiene simultáneamente caja Y banco — cubre las 4 patas entre los dos.)
- [x] 7.3 Caso: anular un cobro **bancario** (sin movimiento de caja) con **todas las cajas cerradas** → procede igual (no exige sesión) — cta cte + banco + asiento.
- [x] 7.4 Caso: anular un cobro **con** movimiento de caja y sin sesión abierta → `P0426`, y **nada** cambió (cuenta corriente y documento intactos).
- [x] 7.5 Caso: anular dos veces → el segundo intento `P0404`, sin segundo contra-movimiento.
- [x] 7.6 Caso: anular un pago de otro tenant → `P0404`, sin efectos en ninguna de las dos cuentas.
- [x] 7.7 **Control negativo obligatorio**: se inyecta a mano un movimiento `payment_received` con signo NEGATIVO (el opuesto al que produce el alta real) y se verifica que la anulación lo compensa igual, por el importe exactamente opuesto al INYECTADO (no al "típico" del tipo). Prueba directa de que el guard es `<> 0`.
- [x] 7.8 Caso: anular el cobro que dejó el saldo en 0 → procede, saldo vuelve al original, **no** aparece `P0425` (D6).
- [x] 7.9 Caso contable: se procesa el evento de anulación (`_journal_post_from_event` invocado directo, bypaseando el orden del dispatcher) **antes** que el del alta → `P0451`, cero asientos; se procesa el alta y se reprocesa el reverso → contra-asiento correcto + original `reversed`; reproceso del mismo evento → no duplica.
- [x] 7.10 **Gate del invariante D13**: extrae de los cuerpos vivos (`pg_get_functiondef`) los conjuntos de `event_type` de `_journal_post_from_event` y del Consumer 3 de `rpc_process_outbox_dispatch` vía regex anclado + `regexp_matches`, los compara, y valida los 11 tipos canónicos. **Matriz de evasión ejecutada** (11b): el mismo extractor+comparador corrido contra dos textos sintéticos con una divergencia plantada (`Foo/Bar/Baz` vs `Foo/Bar/Qux`) demuestra que SÍ la detecta — no es un detector vacío.
- [x] 7.11 Extendido `test_cash_movement_types.sql`: los dos tipos nuevos con signos opuestos entre sí (2.3-cash-types), header actualizado a 13 tipos, y el bloque de idempotencia (2.5) reescrito para reaplicar la definición VIGENTE de 13 tipos en vez de la de 11 de `caja-compras-cobranzas` (evita downgradear el CHECK en silencio si este gate corre después del mío).
- [x] 7.12 Verificado: `test_function_acl_gate.sql` pasa sin cambios — las dos RPCs nuevas son `rpc_*` con `GRANT` sólo a `authenticated` (no a `anon`), fuera del alcance de los chequeos (2)/(3)/(4)/(5) por diseño (igual que las ~76 RPCs de API existentes).
- [x] 7.13 Corridos los **42 gates SQL existentes** en una pasada limpia (`supabase db reset` + loop secuencial): **41/42 OK**. El único que falla (`test_sales_order_payment_method_drop.sql`) es un **hallazgo pre-existente**, verificado independiente de esta migración (falla igual con `20261019000001` removido del todo): su regex de exclusión no contempla que `payments_received.payment_method` / `payments_made.payment_method` (columnas reales, `caja-compras-cobranzas` OQ-1) son legítimas, y matchea el `payment_method)` crudo en el `INSERT` de `rpc_register_payment_received`/`_made` — funciones que este change **no toca**. Reportado, no corregido acá (fuera de alcance del design; candidato anotado en §15).

## 8. Backend — schemas

- [x] 8.1 `backend/schemas/cash.py`: `MovementType` suma `payment_received_reversal` y `payment_made_reversal`; `_EXPENSE_TYPES` suma el primero, `_INCOME_TYPES` el segundo (D10 — signos opuestos, verificado por test).
- [x] 8.2 `backend/schemas/customer_accounts.py`: `AccountMovementOut` gana `is_reversible: bool = False` e `is_reversal_blocked: bool = False`; nuevo `PaymentReversalOut`; nuevo `PaymentReversalIn` con `reason: str | None = None`.
- [x] 8.3 `backend/schemas/supplier_accounts.py`: espejo exacto.
- [x] 8.4 Tests de schema en `test_cobranzas_reverso.py` (Sections 1-2): los dos derivados default a `False`; `RegisterMovementIn` valida el signo de los dos tipos nuevos (positivo/negativo rechazados donde corresponde).

## 9. Backend — repositories

- [x] 9.1 `customer_account_repository.py`: `reverse_payment_received(payment_id, reason)` → `SELECT public.rpc_reverse_payment_received($1::uuid, $2::text)`.
- [x] 9.2 `customer_account_repository.py`: `list_movements_page` suma los dos `EXISTS` derivados con el **mismo predicado** que evalúa la RPC (D12). No columnas denormalizadas.
- [x] 9.3 `supplier_account_repository.py`: espejo de 9.1 y 9.2.
- [x] 9.4 Tests de repository con `asyncpg` mockeado (Sections 3-4 de `test_cobranzas_reverso.py`): SQL emitida, parámetros posicionales (`payment_id`, `reason`), y presencia de los `EXISTS` en `list_movements_page`.

## 10. Backend — services y routers

- [x] 10.1 `services/customer_accounts.py`: `reverse_payment_received(repo, auth, payment_id, payload)` con `require_role(["user","admin"])`; cero lógica en el router.
- [x] 10.2 `services/supplier_accounts.py`: espejo (`reverse_payment_made`).
- [x] 10.3 `routers/customer_accounts.py`: `DELETE /customer-accounts/payments/{payment_id}`, `response_model=PaymentReversalOut`, `payload: PaymentReversalIn | None = None` (motivo opcional, cuerpo entero opcional).
- [x] 10.4 `routers/supplier_accounts.py`: `DELETE /supplier-accounts/payments/{payment_id}`, espejo.
- [x] 10.5 `core/errors.py`: `P0451` sumado al mapa global (409, misma familia P042x). Los mapas LOCALES de `services/customer_accounts.py` y `services/supplier_accounts.py` (usados por `_pg_to_http`, distintos del handler global) también ganaron `P0426`/`P0451` — sin ellos, esos dos ERRCODEs habrían caído en 500 para estos dos endpoints específicos (hallazgo del propio TDD: el service tiene su PROPIO mapa, no delega en `core/errors.py`). Cero ERRCODEs nuevos.
- [x] 10.6 Tests de router/service (Sections 5-6): 403 sin rol + repo no invocado, 404 por `P0404`, 409 por `P0426` y por `P0451`, 200 con `reversed=true`, DELETE con y sin body.
- [x] 10.7 Coverage: suite completa **1746 passed** (repo root), sin fallos nuevos. Cobertura de los archivos tocados: 94-100 % (todos ≥ umbral 87 % de CI). RED genuino verificado: se removió `P0426` del mapa local, el test `test_propagates_p0426_as_409` falló con 500 (no 409), confirmando que la aserción no es trivial.

## 11. Frontend — librerías compartidas

- [x] 11.1 `lib/types.ts`: `CashMovementType` suma los dos tipos.
- [x] 11.2 `lib/ledger/cash-movement-meta.ts`: entradas para los dos tipos — etiquetas "Anulación de cobro" / "Anulación de pago", ícono propio (`Undo2`), tonos OPUESTOS (destructive/success), **familia "Reversas"** para los dos (D10).
- [x] 11.3 `lib/delete-compensation.ts`: `DeletableDocument` suma `"cobro"` y `"pago"`; `NO_OPEN_SESSION_BLOCKED_REASON` gana sus dos frases completas (verbo "anular", no "borrar"); la rama de `hasCashMovement` distingue **salida** (cobro) de **ingreso** (pago, junto a gasto/compra); ítem propio de "reposición de deuda" (no reutiliza `hasAccountCharge`) y de "reversión del asiento contable" (D5: siempre, nunca diferido) para `document === "cobro" | "pago"`.
- [x] 11.4 `lib/operation-errors.ts`: mensajes legibles para `no_open_session_for_reversal` (P0426), `payment_not_found` (P0404) y `journal_entry_original_not_found` (P0451).
- [x] 11.5 Tests unitarios extendidos (no duplicados): `cash-movement-meta.test.ts` (11→13 tipos + 2 casos de tono opuesto), `operation-errors.test.ts` (+3 casos), `delete-operation-dialog.test.tsx` (+5 casos de `getDeleteCompensation` con `document="cobro"/"pago"`), `python-client.test.ts` (+2 casos del body opcional de `delete`). Extra: `components/shared/delete-operation-dialog.tsx` (compartido por venta/compra/gasto) ganó `actionVerb`/`actionVerbGerund`/`icon`/`reasonField` opcionales con defaults que preservan el comportamiento de los 3 consumidores existentes (8 tests preexistentes siguen en verde) — reutilizado por la superficie de anulación del grupo 13 en vez de duplicar el diálogo.

## 12. Frontend — hooks de datos

- [ ] 12.1 `hooks/data/use-customer-account.ts`: mutación `useReversePaymentReceived`; el tipo del movimiento suma los dos derivados nuevos.
- [ ] 12.2 `hooks/data/use-supplier-account.ts`: espejo.
- [ ] 12.3 **Invalidaciones**: las dos mutaciones invalidan cuenta corriente, **caja**, **banco** y **KPIs del dashboard** con las claves que ya existen en `lib/query-keys.ts`. (Lección de `compras-proveedor-cuenta-corriente`: invalidar en TODAS las mutaciones que postean en libros.)
- [ ] 12.4 Tests de hook con `vi.hoisted` para los mocks; correr con `pnpm vitest run <archivo>` (nunca pipeando a `tail`, que enmascara el exit code).

## 13. Frontend — superficie

- [ ] 13.1 `components/customer-accounts/CustomerAccountHistory.tsx`: acción "Anular" por fila, visible sólo con `isReversible`; deshabilitada con motivo cuando `isReversalBlocked`; etiquetas e íconos para el tipo `payment_received_reversal` en `MOVEMENT_LABELS` / `MOVEMENT_ICONS` (hoy son `Record` cerrados sobre 4 tipos — agregar el quinto o el build rompe).
- [ ] 13.2 `components/supplier-accounts/SupplierAccountHistory.tsx`: espejo, con `payment_made_reversal`.
- [ ] 13.3 Diálogo de confirmación que enumera las compensaciones vía `getDeleteCompensation({...}, party, "cobro"|"pago")` y nombra el efecto sobre la deuda ("se repondrá la deuda del cliente por $X"), con campo de motivo opcional.
- [ ] 13.4 Verificar que el signo del ledger se sigue mostrando en valor absoluto con el signo puesto por el componente (el bug del PO de 2026-08-21, "Cobro −$-58.750,00", ya está corregido — no reintroducirlo con el tipo nuevo).
- [ ] 13.5 `/caja`: comprobar que el historial muestra los dos tipos nuevos con su familia de filtro correcta (el meta de 11.2 alcanza; verificarlo en pantalla, no asumirlo).
- [ ] 13.6 Verificación visual: capturas en **desktop y móvil × tema claro y oscuro** (4 combinaciones) del historial con la acción, de la acción bloqueada y del diálogo. Contraste medido ≥ 4,5:1.
- [ ] 13.7 Revisión de accesibilidad: la acción de fila tiene nombre accesible, el diálogo tiene foco atrapado y el motivo del bloqueo llega a lectores de pantalla (no sólo como `title`).
- [ ] 13.8 `pnpm tsc --noEmit` sin errores nuevos y suite de frontend en verde.

## 14. Verificación, PR y cierre

- [ ] 14.1 Suite completa: backend (`pytest`, coverage ≥ 87 %), frontend (`vitest`), `tsc`, gates SQL.
- [ ] 14.2 Revisión adversarial del diff propio antes del PR, con foco en: el guard `<> 0` en las dos RPCs, que las 9 ramas contables preexistentes no cambiaron, que los dos filtros de `event_type` coinciden, y que ningún `REVOKE` quedó sin su `GRANT`.
- [ ] 14.3 PR contra `main` con descripción que enumere los cuatro libros afectados y el sign-off pedido. **Nunca commitear a `main` directo.**
- [ ] 14.4 Esperar checks verdes (incluido `KPI_Validation`) y mergear.
- [ ] 14.5 **Verificación post-merge en prod**: `MAX(version)` = la correlativa nueva; los tres `CHECK` con sus tipos nuevos; ACLs de las 2 RPCs (`anon` sin `EXECUTE`); cuerpos vivos de `_journal_post_from_event` y `rpc_process_outbox_dispatch` con los 11 tipos en ambos filtros.
- [ ] 14.6 **Humo real en prod**: registrar un cobro de prueba en efectivo con caja abierta, verificar los cuatro libros, anularlo, y verificar los cuatro contra-movimientos + que `collected_revenue` del dashboard volvió a su valor previo. Limpiar los datos de prueba dejando el rastro documentado.
- [ ] 14.7 Confirmar que el `pg_cron` del relay procesó los dos eventos de anulación y que los asientos quedaron `reversed` + contra-asiento posteado.
- [ ] 14.8 Actualizar `CHANGES.md`: entrada propia del change, corregir el puntero de "próximo change recomendado", y dar de baja `cobranzas-reverso` de la lista de candidatos.
- [ ] 14.9 Anotar en `CHANGES.md` los hallazgos laterales que este change deja abiertos (§15).
- [ ] 14.10 `openspec archive cobranzas-reverso` y verificar que los requirements sincronizados están en **HEAD**, no sólo en el árbol de trabajo (gotcha conocido del archive).

## 15. Hallazgos laterales a registrar (no se arreglan acá)

- [ ] 15.1 **`transactional-outbox/spec.md` tiene dos requirements con el nombre malformado `### MODIFIED Requirement: ...`** — el prefijo del delta quedó horneado en el nombre durante un archive anterior. Además, su enumeración del Consumer 3 lista **7** tipos y quedó desactualizada cuando `delete-guard-ledgers` agregó `SaleOperationDeleted` y `PurchaseDeleted`: la spec afirma algo falso y **ningún gate lo detecta**. Este change lo neutraliza declarando el conjunto canónico en un requirement nuevo, pero no corrige los headers ni la enumeración vieja. Anotar como candidato barato.
- [ ] 15.2 **`payment_method` es NULL en los 7 pagos históricos.** El historial de cuenta corriente lo resuelve por `LEFT JOIN`, así que ya lo muestra vacío para ellos, y tras una anulación lo mostrará vacío también para el cobro anulado (OQ-5). Cosmético; anotar.
- [ ] 15.3 **`bank_movements` no tiene tipo de reversa para `card_settlement`** (D11): la reversa conserva el tipo con importe negativo. Es el comportamiento del molde, pero merece revisarse cuando la conciliación bancaria trate liquidaciones de tarjeta con más detalle.
- [ ] 15.4 Registrar en engram (`topic_key: "opsx/cobranzas-reverso/apply"`) los hallazgos reales del apply, especialmente cualquier divergencia detectada en el checkpoint 1.2.
- [x] 15.5 **`test_sales_order_payment_method_drop.sql` tiene un falso positivo pre-existente**, descubierto en el gate sweep completo (7.13) de este apply: su regex de exclusión (diseñada para `sales_orders.payment_method`, ya retirada) no contempla las columnas reales `payments_received.payment_method` / `payments_made.payment_method` que `caja-compras-cobranzas` (OQ-1, PR #485) agregó, y falla nombrando `rpc_register_payment_received`/`rpc_register_payment_made` — funciones que **cobranzas-reverso no toca**. Verificado independiente de esta migración (falla igual con `20261019000001` removido). El fix es acotado (sumar `payments_received`/`payments_made` a la lista de tablas con columna `payment_method` legítima en la exclusión de la regex) pero pertenece a la línea `caja-compras-cobranzas`/`limpiezas-pagos-admin`, no a este change. Candidato barato.
