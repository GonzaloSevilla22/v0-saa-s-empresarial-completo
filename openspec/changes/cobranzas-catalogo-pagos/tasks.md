> **Governance: MEDIA.** Cambia la firma de dos RPCs que mueven dinero real (caja, banco, cuenta corriente, asiento contable), pero siguiendo un molde ya aplicado y verificado tres veces (`metodos-pago-operaciones`, `pos-catalogo-pagos`, `gastos-forma-pago`) y sin inventar semántica nueva. Implementar con checkpoints y elevar al PO las decisiones no obvias.
>
> **TDD estricto**: cada grupo con lógica nueva escribe primero el test que falla (RED), después el mínimo para pasarlo (GREEN), triangula con un segundo caso, y refactoriza con los tests en verde. Los grupos SQL usan los gates `supabase/tests/*.sql` como capa de test.

## 1. Checkpoint de integridad — ANTES de escribir una sola línea de código

- [ ] 1.1 Re-capturar el `pg_get_functiondef` **vivo** de prod de las 9 funciones del Context del design y comparar los md5 contra la tabla registrada. **Un hash que no coincide DETIENE el apply**: significa que prod divergió del baseline y hay que revisar el diseño, no forzarlo.
- [ ] 1.2 Guardar los cuerpos vivos de `rpc_register_payment_received` (`4d5de674…`) y `rpc_register_payment_made` (`07acdadb…`) en `openspec/changes/cobranzas-catalogo-pagos/baseline/live_functiondefs/` — las reescrituras parten de ahí, NUNCA del archivo de migración (que ya divergió una vez en este proyecto).
- [ ] 1.3 Re-contar en prod `payments_received`/`payments_made` con `payment_method IS NOT NULL`. **Debe seguir en 0/7.** Si apareciera alguna fila poblada (un cobro cargado entre el propose y el apply), DETENER y decidir el backfill de esa fila puntual antes del `DROP COLUMN`.
- [ ] 1.4 Verificar que las ramas `PaymentReceived`/`PaymentMade` de `_journal_post_from_event` (`1106ce77…`) **no** comparan el payload contra la lista literal de 4 formas de pago. Si lo hicieran, ampliar la rama forma parte de este change (D8 lo previó como confirmación, no como supuesto).
- [ ] 1.5 Re-verificar la correlativa de migración contra `origin/main` **y** contra `supabase_migrations.schema_migrations` en prod. `20261020000001` es la previsión (ambos en `20261019000001`, 268 filas); la numeración se corrió 3 veces en `cuenta-corriente-party-guard`.
- [ ] 1.6 **Enumerar TODOS los callers** de las dos RPCs con `pg_get_functiondef` + `grep`, no de memoria: gates SQL, repositories Python, hooks del frontend, migraciones que las recrean. La regla de la casa desde el incidente #451 es literal — *al endurecer un contrato, migrar TODOS los callers*.

## 2. Migración SQL — schema

- [ ] 2.1 Crear `supabase/migrations/20261020000001_cobranzas_catalogo_pagos.sql`, idempotente de punta a punta (Supabase auto-aplica desde GitHub; una reaplicación no debe fallar).
- [ ] 2.2 `ALTER TABLE public.payments_received ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL REFERENCES public.payment_methods(id)` — sin `ON DELETE` (la baja del catálogo es desactivación, nunca borrado: `NO ACTION` es la salvaguarda correcta).
- [ ] 2.3 Espejo exacto en `public.payments_made`.
- [ ] 2.4 `ALTER TABLE ... DROP COLUMN IF EXISTS payment_method` en ambas tablas, **después** de que 1.3 confirme 0 filas pobladas.
- [ ] 2.5 Índice sobre `payment_method_id` en ambas tablas sólo si el reporte de formas de pago lo necesita — medir el plan de `rpc_payment_method_report` antes de agregarlo, no por reflejo.

## 3. Migración SQL — `rpc_register_payment_received`

- [ ] 3.1 RED: extender `supabase/tests/test_party_payment_cash.sql` con el caso "cobro imputado a `payment_method_id` de `kind='cash'` con sesión abierta ⇒ `cash_movement` positivo". Debe fallar (la firma nueva no existe).
- [ ] 3.2 `DROP FUNCTION IF EXISTS public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid, uuid)` — la firma vieja, **explícito**. Nunca `CREATE OR REPLACE` con el tipo cambiado: dejaría un overload vivo (gotcha `42725`, D1).
- [ ] 3.3 `CREATE FUNCTION` con `p_payment_method_id uuid DEFAULT NULL` en 5.ª posición, partiendo del cuerpo vivo de 1.2. Preservar **sin tocar** el guard de tenencia del cliente (`P0404` de `cuenta-corriente-party-guard`), la idempotencia DEC-06 y el bloque de opt-in de caja.
- [ ] 3.4 Resolver el `kind`: `SELECT kind FROM payment_methods WHERE id = p_payment_method_id AND account_id = v_account_id` → `P0404` si no encuentra, con mensaje que **no revela** si el id existe en otra cuenta (D5). `p_payment_method_id IS NULL` ⇒ sin imputar, sin efectos.
- [ ] 3.5 Rechazar `kind = 'credit'` con `P0400` (D2). Retirar por completo la lista literal `('cash','transfer','card','check')` del cuerpo — el requirement nuevo exige que **no quede ninguna enumeración**.
- [ ] 3.6 Reemplazar el bloque bancario inline por `_pay_register_operation_bank_movement(..., p_direction => 'in', p_source_doc_type => 'payment_received', ...)` (D4). **Conservar** el guard `P0400 bank_account_required` + `P0412` que exige cuenta bancaria explícita: sin él, con 0/266 destinos configurados, el helper haría `RETURN NULL` en silencio.
- [ ] 3.7 Adaptar el opt-in de caja para evaluar la condición 1 sobre el `kind` derivado en vez de sobre el texto. Mantener `P0422 cash_optin_requires_cash_kind` / `cash_optin_requires_open_session` y el movimiento **dentro** del alcance de la clave de idempotencia.
- [ ] 3.8 Payload del evento `PaymentReceived`: `payment_method` pasa a llevar el `kind` derivado y se suma `payment_method_id`. Verificar contra 1.4 que ningún consumidor se rompe.
- [ ] 3.9 `REVOKE ALL ... FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE TO authenticated` en la misma migración. Un `DROP`+`CREATE` **resetea las ACLs** y el proyecto hospedado otorga a los roles de forma directa.
- [ ] 3.10 GREEN + TRIANGULATE: los 6 kinds admitidos (`cash`, `transfer`, `card`, `check`, `wallet`, `other`) + el rechazo de `credit` + la forma de pago de otro tenant.

## 4. Migración SQL — `rpc_register_payment_made`

- [ ] 4.1 RED: caso espejo en `test_party_payment_cash.sql` para el pago a proveedor (`cash_movement` **negativo**).
- [ ] 4.2 Repetir 3.2 → 3.9 como espejo exacto: `DROP` de `(text, uuid, numeric, uuid, text, uuid, uuid)`, `CREATE` con `p_payment_method_id`, resolución de `kind` bajo tenant, rechazo de `credit`, helper bancario con `p_direction => 'out'` y `source_doc_type = 'payment_made'`, opt-in por `kind`, payload, `REVOKE`/`GRANT`.
- [ ] 4.3 Verificar que el `movement_type` bancario que produce el helper para `out` es `transfer_out` (y `card_settlement` para `card`), compatible con la tabla de inversión del reverso.
- [ ] 4.4 GREEN + TRIANGULATE: los 6 kinds + rechazo de `credit` + tenant ajeno, del lado proveedor.

## 5. Gates SQL — los tres callers que rompen

- [ ] 5.1 `supabase/tests/test_cuenta_corriente_party_guard.sql` L887/L901: actualizar las dos firmas resueltas por `::regprocedure` a `(text, uuid, numeric, uuid, uuid, uuid, uuid)`. **Ya se rompió dos veces por esto** — es el tercer renumerado de firma sobre este mismo archivo.
- [ ] 5.2 `supabase/tests/test_party_payment_cash.sql`: migrar las ~14 llamadas `p_payment_method => 'cash'` a `p_payment_method_id => <id del método cash del tenant de prueba>`, y los 2 asserts sobre la columna de texto (casos 4.8 y 4.8-pago) a `payment_method_id`.
- [ ] 5.3 `supabase/tests/test_cobranzas_reverso.sql`: migrar las 8 llamadas a la firma nueva. **No tocar ninguna aserción del reverso**: el objetivo es que sigan pasando sin cambios de expectativa, que es la prueba de D7.
- [ ] 5.4 Extender el chequeo de firma única (`SELECT count(*) FROM pg_proc WHERE proname = ...` = 1) a las dos RPCs — la red contra el overload de D1.
- [ ] 5.5 Gate nuevo: **ninguna enumeración literal de formas de pago** sobrevive en el cuerpo vivo de las dos RPCs (detector de texto sobre `pg_get_functiondef`). Ejercitar la matriz de evasión antes de darlo por bueno — lección de `tenancy-guard-caja-outbox` (*un detector de texto necesita su matriz de evasión ejecutada*).
- [ ] 5.6 Gate nuevo (D7, el que protege el reverso): **las funciones de anulación no referencian la columna de forma de pago** de `payments_received`/`payments_made`. Es el requirement `payment-reversal` vuelto ejecutable.
- [ ] 5.7 Caso de gate: anular un cobro **imputado por catálogo** y verificar que los cuatro libros compensan igual que para uno sin imputar.
- [ ] 5.8 Verificar que el gate de ACLs (`test_function_acl_gate.sql`) sigue verde con las dos funciones recreadas.

## 6. Backend — schemas Pydantic v2

- [ ] 6.1 RED: casos en `backend/tests/test_c30_customer_supplier_accounts.py` para `payment_method_id` (válido, `None`, y coherencia con `cash_session_id`).
- [ ] 6.2 `backend/schemas/customer_accounts.py`: `PaymentReceivedIn.payment_method` (`str = "cash"`) → `payment_method_id: uuid.UUID | None = None`. **Retirar** `validate_payment_method` (la taxonomía ya no vive acá) y adaptar los dos `model_validator` restantes.
- [ ] 6.3 El validador de cuenta bancaria ya no puede decidir por el texto: el `kind` lo conoce el servidor. Mover esa exigencia a la RPC (que ya la tiene) y dejar en Pydantic sólo lo que se puede validar sin catálogo. **No inventar una consulta al catálogo desde el schema.**
- [ ] 6.4 `validate_cash_session_requires_cash_method`: misma consideración — la defensa en profundidad por texto deja de ser posible; la autoridad es la RPC (`P0422`). Documentar el porqué en el docstring, no borrarlo en silencio.
- [ ] 6.5 `AccountMovementOut.payment_method: str | None` pasa a resolverse por `JOIN` a `payment_methods` (nombre configurado). Mantener el nombre del campo para no romper el frontend, o renombrarlo y migrar sus consumidores — decidir y documentar.
- [ ] 6.6 Espejo exacto en `backend/schemas/supplier_accounts.py`.
- [ ] 6.7 GREEN + TRIANGULATE.

## 7. Backend — services y repositories

- [ ] 7.1 `backend/repositories/customer_account_repository.py`: pasar `payment_method_id` a la RPC en la posición 5. Verificar el orden posicional contra la firma nueva — un desplazamiento silencioso acá manda el uuid al parámetro equivocado.
- [ ] 7.2 Actualizar la query de movimientos con el `LEFT JOIN` a `payment_methods` para el nombre, preservando los 4 derivados de `cobranzas-reverso` (`is_reversible`, `is_reversal_blocked`, `has_cash_movement`, `has_bank_movement`).
- [ ] 7.3 Espejo en `backend/repositories/supplier_account_repository.py`.
- [ ] 7.4 `backend/services/customer_accounts.py` y `supplier_accounts.py`: propagar el campo. Sin lógica de negocio nueva en los routers (regla de 3 capas).
- [ ] 7.5 Verificar que el mapeo de `P0404` → 404 RFC 7807 en `backend/core/errors.py` ya cubre el caso nuevo (D5 no agrega ERRCODEs).
- [ ] 7.6 Suite backend completa en verde, coverage ≥87%.

## 8. Frontend — el selector y su contexto

- [ ] 8.1 RED: test de `PaymentMethodSelect` con `context="collection"` — ofrece los 6 kinds, **no** ofrece `credit`.
- [ ] 8.2 `PaymentMethodContext` suma `"collection"`; `paymentMethodOptionsFor` filtra `credit` para ese contexto (junto a `"expense"`). **Extensión aditiva del componente único**, nunca un selector paralelo (D6).
- [ ] 8.3 `PaymentMethodSupportText`: rama de `cash` para `"collection"` con la redacción del opt-in **pre-marcado** (*"salvo que destildes…"*), NO la de venta (que describe un opt-in destildado). Decirlo al revés es el bug que `qa-integral-modulos` G10/H8 corrigió para compra.
- [ ] 8.4 Rama de `credit` para `"collection"`: aunque el selector no lo ofrezca, un cobro histórico podría tener imputado un método que después pasó a `credit` — el texto tiene que decir cuál es el camino correcto (mismo patrón que la rama de `expense`).
- [ ] 8.5 GREEN + TRIANGULATE.

## 9. Frontend — los dos modales

- [ ] 9.1 RED: extender `frontend/__tests__/components/RegisterPaymentForms.test.tsx` y `RegisterPaymentForms-cash-optin.test.tsx` para el catálogo.
- [ ] 9.2 **Test de regresión de D11, el modo de falla más probable del change**: con el selector emitiendo un UUID, el bloque de opt-in de caja **sigue apareciendo** al elegir una forma de pago de `kind='cash'`. Hoy funciona porque los `value` del `<Select>` local coinciden con los `kind` por nomenclatura; con UUIDs, `kind === "cash"` daría siempre falso y el bloque desaparecería **sin ningún error**.
- [ ] 9.3 `RegisterPaymentForm.tsx`: eliminar `PAYMENT_METHODS` y `BANK_METHODS` locales; montar `PaymentMethodSelect` con `context="collection"`. El schema Zod pasa de `z.enum([...])` a un uuid opcional.
- [ ] 9.4 Derivar el `kind` del método elegido vía `usePaymentMethods()` (el hook que el selector ya usa — **cero fetch nuevo**) y pasarlo a `useCashOptin({ kind, ... })`. D11: esto es núcleo, no acompañamiento.
- [ ] 9.5 Reemplazar el `<Select>` de cuenta bancaria propio por `BankAccountDestinationSelect` con `required`, visible sólo para `kind` bancario (ahora incluye `wallet`).
- [ ] 9.6 Espejo exacto en `RegisterPaymentMadeForm.tsx`.
- [ ] 9.7 `hooks/data/use-customer-account.ts` y `use-supplier-account.ts`: el payload manda `paymentMethodId`. Verificar que **todas** las mutaciones que postean cargos siguen invalidando las queries de cuentas corrientes (gotcha registrado de `compras-proveedor-cuenta-corriente`).
- [ ] 9.8 GREEN + TRIANGULATE.

## 10. Frontend — historiales

- [ ] 10.1 `CustomerAccountHistory.tsx`: mostrar el nombre configurado de la forma de pago en las filas de cobro; **omitir** la mención cuando no hay imputación (los 7 históricos), nunca mostrar un valor inventado.
- [ ] 10.2 Espejo en `SupplierAccountHistory.tsx`.
- [ ] 10.3 Verificar que la acción **Anular** de `cobranzas-reverso` sigue funcionando en ambas pantallas, con sus flags `is_reversible` / `is_reversal_blocked` intactos.

## 11. Verificación visual (regla PO 2026-08-02, obligatoria)

- [ ] 11.1 Capturas de los **dos modales** × **desktop y mobile** × **tema claro y oscuro** = 8 combinaciones mínimo.
- [ ] 11.2 **Desplegable del selector dentro del modal**: verificar que scrollea dentro y que todas las opciones son alcanzables. Es el escenario exacto del bug raíz que `qa-integral-modulos` G1 corrigió (popover portalizado fuera del shard de scroll del modal) — se prueba, no se asume que el fix cubre.
- [ ] 11.3 Contraste WCAG AA sobre el texto de apoyo y las opciones, en las cuatro combinaciones (gate `token-contrast-aa.test.ts`).
- [ ] 11.4 a11y: `htmlFor`/`id` y `aria-describedby` del selector dentro del modal (el precedente ya encontró este gap dos veces: `supplier-form.tsx` y `searchable-select.tsx`).
- [ ] 11.5 Verificar el bloque de opt-in de caja en sus tres estados: elegible y marcado, elegible y desmarcado, no elegible con motivo visible.

## 12. Verificación integral pre-merge

- [ ] 12.1 Backend: suite completa verde, coverage ≥87%.
- [ ] 12.2 Frontend: `pnpm vitest run` completo + `tsc` sin errores nuevos (ojo con `next-env.d.ts` sucio tras `next dev`).
- [ ] 12.3 Los 6 gates SQL afectados en verde, incluidos los 3 migrados y los 3 nuevos.
- [ ] 12.4 Revisión adversarial del diff: ¿queda alguna enumeración literal de formas de pago? ¿algún caller sin migrar? ¿el `DROP FUNCTION` cubre exactamente la firma vieja? ¿el `REVOKE` incluye `authenticated`?
- [ ] 12.5 `git diff --stat` para confirmar que la superficie tocada es la declarada — sin archivos sorpresa.

## 13. PR, merge y verificación en producción

- [ ] 13.1 Rama nueva, PR con conventional commit `feat(cobranzas): los modales de cobro y pago usan el catálogo de formas de pago`. **NUNCA commitear a main** — todo cambio vía PR, incluidos los fixes triviales post-merge.
- [ ] 13.2 Esperar los checks (incluido `KPI_Validation`) y mergear sin preguntar si están verdes.
- [ ] 13.3 Post-merge en prod: `MAX(version) = 20261020000001`; **exactamente una firma viva** por función; `anon` sin `EXECUTE` sobre ambas; cuerpo vivo conteniendo `_pay_register_operation_bank_movement`; columnas `payment_method_id` presentes y `payment_method` ausentes.
- [ ] 13.4 **Humo real con el PO**: (a) un cobro por **billetera virtual** —el kind que hoy no se puede registrar—; (b) un cobro en efectivo verificando el movimiento en `/caja`; (c) la **anulación** de ese cobro verificando que los cuatro libros compensan; (d) el cobro aparece en `/reportes/formas-pago`.
- [ ] 13.5 Verificar que los 7 documentos históricos siguen legibles, sin forma de pago, sin errores en el historial.

## 14. Cierre documental

- [ ] 14.1 Entrada propia en `CHANGES.md` con las decisiones, los hallazgos y los candidatos que deje abiertos.
- [ ] 14.2 Actualizar el puntero "próximo change" del `CLAUDE.md` y correr `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** (gate `Docs Sync`; nunca editar `AGENTS.md` a mano).
- [ ] 14.3 Registrar como candidato la OQ-5 (configurar destinos bancarios por defecto: siguen 0/266).
- [ ] 14.4 Retirar de `CHANGES.md` el candidato `cobranzas-catalogo-pagos`, que este change cierra.
- [ ] 14.5 `mem_save` a engram con `topic_key: "opsx/cobranzas-catalogo-pagos/apply"`.
