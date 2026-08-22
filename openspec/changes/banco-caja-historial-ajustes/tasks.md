> **Governance MEDIUM** — toca dinero sobre helpers ya en producción. Implementar con checkpoints; surfacear decisiones no obvias.
> **Strict TDD** — todo grupo con lógica arranca por el test que falla. Suites base a preservar: backend **~1460+**, frontend **~1210+**.
> **Toda escritura va por PR** — nunca commit directo a `main`, ni siquiera un fix trivial de seguimiento.

## 1. Baseline y red de seguridad

- [x] 1.1 Guardar en `openspec/changes/banco-caja-historial-ajustes/baseline/` el `pg_get_functiondef` **vivo de prod** de `rpc_register_cash_movement`, `c28_register_cash_movement`, `rpc_close_cash_session` y `rpc_register_bank_movement` — toda reescritura parte de ahí, nunca de la migración original
- [x] 1.2 Verificar `SELECT MAX(version) FROM supabase_migrations.schema_migrations` en prod y fijar el timestamp del archivo nuevo (esperado `20261006000001`, posterior a `20261005000001`) — confirmado `20261005000001`, archivo nuevo `20261006000001`
- [x] 1.3 Correr las suites base y anotar los números exactos (backend y frontend) como red de seguridad; si algo ya falla, reportarlo como fallo preexistente y NO arreglarlo dentro de este change
- [x] 1.4 Registrar el conteo prod de partida (65 `cash_movements`, 2 sesiones abiertas, 37 cajas, 3 `bank_movements`, 4 cuentas bancarias) para poder afirmar impacto después — confirmado vía MCP (solo SELECT): 65/2/37/3, **8 cuentas bancarias** (no 4 — corregido contra prod real)

## 2. DB — esquema de ajustes (RED → GREEN)

- [x] 2.1 RED: verificado contra prod vivo (MCP, solo SELECT) — `cash_movements_movement_type_check` sin `adjustment`, sin columna `description`
- [x] 2.2 RED: consecuencia de 2.1 — sin el tipo `adjustment` ni el CHECK de motivo, nada rechaza un ajuste sin motivo
- [x] 2.3 RED: verificado contra prod vivo — `cash_sessions` sin columna `adjustments_total`
- [x] 2.4 RED: verificado contra prod vivo — `bank_movements_movement_type_check` no tiene CHECK de motivo para `manual_adjustment`
- [x] 2.5 GREEN: `supabase/migrations/20261006000001_banco_caja_historial_ajustes.sql` — todo lo listado, idempotente
- [x] 2.6 TRIANGULATE: verificado localmente (docker exec contra el stack Supabase local) — `VALIDATE CONSTRAINT` no reescribe filas, 0 errores sobre datos existentes
- [x] 2.7 Verificado localmente: reaplicado el archivo completo dos veces seguidas — 0 errores, mismo fingerprint (bug encontrado y corregido: `rpc_register_cash_movement`/`c28_register_cash_movement` debían ser `CREATE OR REPLACE`, no `CREATE` — el `DROP FUNCTION IF EXISTS` de la firma vieja de 4 args deja de matchear en el segundo reapply)

## 3. DB — RPCs con motivo y arqueo separable (RED → GREEN → TRIANGULATE)

- [x] 3.1 RED: verificado contra el `pg_get_functiondef` vivo (1.1) — firma de 4 args, sin `p_description`
- [x] 3.2 GREEN: `rpc_register_cash_movement` y `c28_register_cash_movement` con `p_description text DEFAULT NULL` al final, partiendo del baseline de 1.1
- [x] 3.3 Gate ANTI-OVERLOAD implementado en `supabase/tests/test_banco_caja_historial_ajustes.sql` (§1) — corrido localmente, verde
- [x] 3.4 `REVOKE ALL ... FROM PUBLIC, anon, authenticated` + `GRANT EXECUTE TO authenticated` explícitos para las 4 funciones — verificado localmente con `has_function_privilege`
- [x] 3.5 RED: verificado por inspección del baseline — `expected`/`difference` no distinguían ajustes
- [x] 3.6 GREEN: `rpc_close_cash_session` materializa `adjustments_total` y devuelve `difference_before_adjustments`; `expected_balance`/`difference` sin cambios de fórmula
- [x] 3.7 GREEN: `adjustments_total` sumado al payload de `CashSessionClosed`; `close_reason` menciona los ajustes cuando `adjustments_total <> 0`
- [x] 3.8 TRIANGULATE: los 3 casos corridos localmente contra Postgres real — sin ajustes, ajuste que tapa la diferencia (con el reason verificado), signos mixtos (+100/-30→+70)
- [x] 3.9 RED: verificado contra el baseline vivo — `rpc_register_bank_movement` acepta `manual_adjustment` con `p_description` NULL
- [x] 3.10 GREEN: guard `P0413 adjustment_reason_required` agregado antes del `INSERT INTO operation_idempotency`
- [x] 3.11 TRIANGULATE: los 3 casos corridos localmente — con motivo registra, sin motivo P0413 sin quemar el slot (reintento con la misma clave tiene éxito real), `transfer_in` sin motivo intacto
- [x] 3.12 Verificado localmente: `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_idempotency.sql`, `test_kpis.sql`, `test_kpis_edge_cases.sql`, `test_pos_banco_movimientos.sql`, `test_pagos_cableados_restantes.sql` — todos verdes tras la migración

## 4. CI — cadena de reapply

- [x] 4.1 Agregado a `.github/workflows/KPI_Validation.yml` el eslabón de reapply de `20261006000001` a continuación del de `20261005000001` — sin conflicto de firma con la cadena existente (documentado inline)
- [x] 4.2 Verificado localmente reproduciendo la cadena completa de reapply (`supabase db reset` + cada archivo en orden, incluida la tolerancia ya documentada del reapply de `20260928000001`) de punta a punta — verde, incluida una segunda pasada del gate nuevo al final

## 5. Backend — lectura paginada de ambos libros (3 capas)

- [x] 5.1 RED: confirmado por inspección — no existía `GET /cashboxes/{id}/movements` antes de este change (solo `GET /sessions/{id}/movements`, cortado por sesión)
- [x] 5.2 GREEN: `CashSessionRepository.list_movements_by_cashbox_page` — `cash_movements ⋈ cash_sessions` por `cashbox_id`, orden `created_at DESC`, `session_id`/`session_opened_at`/`session_status`/`description`; filtros de tipo (`ANY($n::text[])`), texto (`ILIKE`) y rango de fechas **en SQL** — reutiliza `BaseRepository.paginate` (helper ya existente, v3-api-standards §2)
- [x] 5.3 GREEN: `GET /cashboxes/{cashbox_id}/movements?page&size&types&q&from&to` (`routers/cash.py`) con envelope `{items, total, page, pages}` (`CashMovementPageOut`), Pydantic v2, JWT-passthrough, sin `service_role`
- [x] 5.4 RED: confirmado por inspección — no existía ningún endpoint de listado de `bank_movements`
- [x] 5.5 GREEN: `backend/routers/bank_movements.py` + `services/bank_movements.py` + `BankAccountRepository.list_movements_page` — `GET /bank-accounts/{bank_account_id}/movements?page&size&types&status&q&from&to`, orden `value_date DESC, created_at DESC`, mismo envelope
- [x] 5.6 TRIANGULATE: página 0 llena (test) · página fuera de rango `items:[]` con `total`/`pages` consistentes (test) · filtro de tipo pushed a SQL (test, `movement_type = any(`) · filtro de texto pushed a SQL (test, corrige el atajo del molde de Stock) · filtro por `status` bancario pushed a SQL (test)
- [x] 5.7 Aislamiento por tenant: cubierto por la RLS existente sobre `cash_movements`/`cash_sessions`/`bank_movements` (cadena de FKs / `account_id IN current_account_ids()`, JWT-passthrough sin `service_role`) — sin código nuevo de aislamiento, el filtro por `cashbox_id`/`bank_account_id` es defensa adicional, no la única barrera
- [x] 5.8 `GET /sessions/{id}/movements` verificado sin cambios — suite completa de `test_c28_cash_session.py` sigue en verde (no-regresión)

## 6. Backend — registro de ajustes (3 capas)

- [x] 6.1 RED: confirmado por inspección — `cash_movements.movement_type` no incluía `adjustment` en el schema Pydantic ni en el CHECK; escrito como test que falla antes del fix (`test_adjustment_without_description_rejected` fallaba con `TypeError`/sin validación hasta agregar `MovementType.adjustment` + el validador)
- [x] 6.2 GREEN: sin router/service nuevo — `movement_type='adjustment'` + `description` viajan por el `POST /sessions/{id}/movements` ya existente (mismo `require_role`, sin camino paralelo)
- [x] 6.3 GREEN: `ManualMovementIn.validate_adjustment_reason` (schema) + guard `P0413` en la RPC (§3) — motivo obligatorio para `manual_adjustment` en `POST /bank-accounts/{id}/movements`
- [x] 6.4 `P0413 → 422` con `field: description` agregado a `_BUSINESS_ERRCODE_STATUS`/`_FIELD_BY_ERRCODE` en `backend/core/errors.py` (test unitario + test de integración simulando el RAISE); `P0401`/`P0409` ya estaban mapeados (403/409) — sin cambios
- [x] 6.5 TRIANGULATE: ajuste `+`/`-` con motivo → 200 (tests) · sin motivo → 422 con `field=description`, **sin tocar la DB** (Pydantic lo ataja antes, verificado con `assert_not_called()`) · sin sesión abierta → cubierto por el guard `P0409` preexistente de `c28_register_cash_movement` (no tocado, sigue aplicando a `adjustment` igual que a cualquier tipo) · usuario de sólo lectura (`member`) → 403 (test, mismo guard `require_role` que el resto de movimientos)

**Hallazgo de TDD (fuera del alcance original, corregido dentro de este change):** `Field(default=None, validate_default=True)` fue necesario en ambos `description` (cash y banco) — sin eso, Pydantic v2 saltea el `field_validator` cuando el campo viene **ausente** del payload (el caso real: un formulario que no manda `description`), y solo lo dispara si se manda explícitamente `description: null`. Los tests HTTP (no solo los de schema aislado) lo atraparon: el primer test que armaba el JSON sin la clave `description` llegó hasta el mock de la DB en vez de rechazar en 422.

## 7. Frontend — componentes compartidos (capa canónica)

- [ ] 7.1 Antes de escribir nada: grep por lo existente (`stock-movements-panel`, `CashMovementsList`, `ReconciliationBoard`, hooks de movimientos) y confirmar por escrito qué se reutiliza y qué se crea
- [ ] 7.2 RED: vitest de `LedgerMovementsPanel` siguiendo el patrón de los tests del panel de Stock — render de filas, badge por tipo, filtro que dispara refetch server-side, "Ver más", vacío
- [ ] 7.3 GREEN: `components/ledger/LedgerMovementsPanel.tsx` — un componente parametrizado por descriptor de libro (`book`, `meta`, `families`, columna extra, `fetchPage`, `csvName`); heredar del molde de Stock el `Collapsible`, la fila memoizada, el `pageRef` anti double-fetch y el CSV; **corregir** el atajo del molde llevando el filtro de texto al servidor
- [ ] 7.4 GREEN: taxonomías `lib/ledger/cash-movement-meta.ts` y `lib/ledger/bank-movement-meta.ts` — fuente única de label/ícono/familia por tipo, con fallback neutro para tipos desconocidos
- [ ] 7.5 GREEN: `components/ledger/LedgerAdjustmentDialog.tsx` — radio Sobrante(+)/Faltante(−) + importe absoluto, motivo obligatorio validado con Zod, advertencia de irreversibilidad antes de confirmar, `value_date` e `Idempotency-Key` en el modo banco
- [ ] 7.6 GREEN: hooks `use-cash-movements.ts` (paginado por cashbox, conservando el hook por sesión) y `use-bank-movements.ts` (nuevo), con invalidación de queries tras registrar un ajuste
- [ ] 7.7 Tokens semánticos y `cva` en todo lo nuevo — cero colores literales; el gate `token-contrast-aa.test.ts` debe pasar (el molde de Stock usa `text-emerald-400` literales: **no** copiarlos)
- [ ] 7.8 TRIANGULATE: tipo desconocido no rompe la fila · filtro sin resultados muestra el estado vacío correcto · CSV respeta el filtro activo e incluye el motivo

## 8. Frontend — módulo Caja

- [ ] 8.1 RED: test que falle — no existe la ruta `/caja`
- [ ] 8.2 GREEN: `app/(dashboard)/caja/page.tsx` — selector de sucursal (auto si hay una sola) + selector de caja (oculto si hay una sola) + `CashSessionPanel` + barra de acciones + `LedgerMovementsPanel` en modo `cash` + historial de sesiones
- [ ] 8.3 GREEN: mostrar en el historial de sesiones, junto a la diferencia, el total de ajustes y la diferencia sin ajustes cuando la sesión tenga alguno
- [ ] 8.4 GREEN: acciones no aplicables **deshabilitadas con motivo visible**, no ocultas (cerrar y ajustar sin sesión abierta)
- [ ] 8.5 GREEN: convertir `app/(dashboard)/sucursales/[id]/caja/page.tsx` en un redirect de servidor a `/caja?branch=<id>` — sin `useEffect`, sin pantalla intermedia; borrar la lógica duplicada
- [ ] 8.6 GREEN: entrada de sidebar "Caja" → `/caja` en el grupo Operaciones (ícono `Banknote`, `pro:false`, `proOnly:false`), y verificar que no colisiona con el ícono de "Formas de pago"
- [ ] 8.7 Caso caja sin configurar: la pantalla ofrece crear la caja en el lugar (comportamiento actual preservado)

## 9. Frontend — módulo Banco

- [ ] 9.1 RED: test que falle — no existe la ruta `/banco`
- [ ] 9.2 GREEN: `app/(dashboard)/banco/page.tsx` con tabs **Movimientos** y **Conciliación**; la tab de conciliación monta `ReconciliationBoard`, el importador de extracto y `BankAccountFormDialog` **sin reescribirlos**
- [ ] 9.3 GREEN: tab Movimientos — selector de cuenta + saldo + botón "Registrar ajuste" + `LedgerMovementsPanel` en modo `bank` con filtro de estado de conciliación
- [ ] 9.4 GREEN: `app/(dashboard)/finanzas/conciliacion/page.tsx` pasa a redirect de servidor a `/banco?tab=conciliacion`
- [ ] 9.5 GREEN: sidebar "Bancos" → "Banco" apuntando a `/banco` (ícono `Landmark` se conserva)
- [ ] 9.6 Actualizar los tests E2E / de ruta que apunten a `/finanzas/conciliacion` al nuevo path, en el mismo PR

## 10. Verificación visual y de accesibilidad (regla PO)

- [ ] 10.1 `/caja` verificada en **desktop y mobile**
- [ ] 10.2 `/caja` verificada en **tema claro y oscuro**
- [ ] 10.3 `/banco` (ambas tabs) verificada en **desktop y mobile**
- [ ] 10.4 `/banco` (ambas tabs) verificada en **tema claro y oscuro**
- [ ] 10.5 Diálogo de ajuste verificado en los cuatro cruces (2 tamaños × 2 temas), incluida la advertencia de irreversibilidad y el error de motivo faltante
- [ ] 10.6 Sin scroll horizontal de página en mobile; el historial ancho scrollea dentro de su contenedor
- [ ] 10.7 Gate de contraste AA verde sobre las superficies nuevas

## 11. Cierre

- [ ] 11.1 Suites completas verdes: backend ≥ baseline del 1.3, frontend ≥ baseline del 1.3, más los tests nuevos
- [ ] 11.2 Verificar en prod, después del merge, que la migración aplicó (`MAX(version) = 20261006000001`) y que el hot path de venta sigue registrando `cash_movements` (POS y formulario)
- [ ] 11.3 Verificar que las 2 sesiones abiertas históricas siguen operando y que su total de ajustes se calcula al vuelo
- [ ] 11.4 Actualizar `CHANGES.md`: reemplazar la nota del candidato `banco-y-caja-consolidado` (superseded por el pedido del PO del 2026-08-22) y registrar este change con su estado, sus OQs y el próximo candidato
- [ ] 11.5 Dejar asentadas para el PO las tres preguntas abiertas: **OQ-1** caja siempre abierta (opciones A/B/C del design), **OQ-2** asiento contable del ajuste, **OQ-3** si el ajuste debe restringirse a `owner`/`admin` vía `v3-rbac-multirole`
- [ ] 11.6 `mem_save` con topic_key `opsx/banco-caja-historial-ajustes/apply` — decisiones, hallazgos y estado real
