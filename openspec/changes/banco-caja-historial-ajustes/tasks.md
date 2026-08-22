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

- [x] 7.1 Grep hecho: `stock-movements-panel.tsx` (molde), `CashMovementsList.tsx` (session-scoped, **superseded** por `LedgerMovementsPanel` — borrado, quedaba sin uso tras 8.5), `ReconciliationBoard`/`BankAccountFormDialog`/importador (reusados **sin tocar** en la tab Conciliación), `use-cash-session.ts`/`use-cashboxes.ts`/`use-branches.ts` (reusados), `useRegisterManualMovement` (reusado y extendido para `manual_adjustment`)
- [x] 7.2 RED→GREEN: `__tests__/components/LedgerMovementsPanel.test.tsx` — render de filas, badge por tipo, filtro server-side, buscador server-side (debounce), "Ver más", vacío, tipo desconocido, cambio de `scopeKey` — corrido con **ambos descriptores** (`cash`/`bank`, `describe.each`)
- [x] 7.3 GREEN: `components/ledger/LedgerMovementsPanel.tsx` — genérico por `LedgerBookConfig<TRow>`; `Collapsible`, fila memoizada, `pageRef`, CSV heredados del molde; buscador va al servidor (corrección del atajo)
- [x] 7.4 GREEN: `lib/ledger/cash-movement-meta.ts` y `lib/ledger/bank-movement-meta.ts` + fallback `UNKNOWN_MOVEMENT_META` en `lib/ledger/types.ts`
- [x] 7.5 GREEN: `components/ledger/LedgerAdjustmentDialog.tsx` — RHF + Zod, radio Sobrante/Faltante, motivo obligatorio, alerta de irreversibilidad, `valueDate` en modo banco
- [x] 7.6 GREEN: `fetchCashMovementsByCashboxPage` (use-cash-movements.ts) y `fetchBankMovementsPage` (use-bank-movements.ts nuevo) — **funciones planas, no hooks** (hallazgo de diseño: el panel administra su propio estado imperativo de acumulación de páginas, como el molde de Stock — un hook de TanStack Query no encaja con "Ver más" incremental); refresco tras ajuste vía `refreshToken` (prop que el panel escucha), no invalidación de queryClient
- [x] 7.7 Tokens semánticos vía `cva` (`toneBadgeVariants`/`amountToneVariants` en el panel) — `success`/`destructive`/`warning`/`muted`, cero literales; `token-contrast-aa.test.ts` sigue verde (no lo toca — audita `globals.css`, no componentes)
- [x] 7.8 TRIANGULATE: cubierto en 7.2 (tipo desconocido → "Otro"; filtro sin resultados → estado vacío; export CSV usa `csvRow`/`csvHeader` del config activo)

## 8. Frontend — módulo Caja

- [x] 8.1 RED→GREEN: `__tests__/pages/caja-page-preselection.test.tsx` (ruta no existía antes de crear `app/(dashboard)/caja/page.tsx`)
- [x] 8.2 GREEN: `app/(dashboard)/caja/page.tsx` — selector de sucursal (auto si 1) + selector de caja (auto si 1, override manual si hay más) + `CashSessionPanel` + barra de acciones + `LedgerMovementsPanel` modo `cash` + historial de sesiones
- [x] 8.3 GREEN: historial de sesiones muestra `adjustmentsTotal` y `difference − (−adjustmentsTotal)` ("sin ajustes: …") cuando `adjustmentsTotal ≠ 0`
- [x] 8.4 GREEN: "Registrar ajuste" deshabilitado con `title` explicando el motivo cuando no hay sesión abierta (no se oculta)
- [x] 8.5 GREEN: `sucursales/[id]/caja/page.tsx` → Server Component puro con `redirect()`, lógica duplicada borrada
- [x] 8.6 GREEN: sidebar "Caja" → `/caja`, ícono `Banknote` — sin colisión (Formas de pago usa `Wallet`, verificado por grep)
- [x] 8.7 Preservado: mismo flujo de `handleCreateCashbox` del original

## 9. Frontend — módulo Banco

- [x] 9.1 RED→GREEN: cubierto por la reestructuración de `/finanzas/conciliacion` → `/banco` (ruta nueva creada, redirect verificado en `__tests__/redirects/`)
- [x] 9.2 GREEN: `app/(dashboard)/banco/page.tsx` — tabs Movimientos/Conciliación; la tab Conciliación es el contenido **completo e intacto** de la ex `ConciliacionPage` (import, sesiones, `ReconciliationBoard`, `BankAccountFormDialog`)
- [x] 9.3 GREEN: tab Movimientos — selector heredado del selector de cuenta de arriba, botón "Registrar ajuste", `LedgerMovementsPanel` modo `bank` con `extraFilter` de estado de conciliación
- [x] 9.4 GREEN: `finanzas/conciliacion/page.tsx` → Server Component con `redirect("/banco?tab=conciliacion")`
- [x] 9.5 GREEN: sidebar "Bancos"→"Banco", `/banco`, ícono `Landmark` preservado
- [x] 9.6 Verificado: `grep -rl "finanzas/conciliacion"` sobre `__tests__/`+`e2e/` solo encuentra el test nuevo del propio redirect — no había ningún otro test apuntando a la ruta vieja que actualizar

## 10. Verificación visual y de accesibilidad (regla PO)

> **Método real**: no fue posible obtener screenshots (el pane del navegador no compone frames en este entorno — "Screenshot timed out... pane no está mostrado"). Verificación por stack local REAL en su lugar: `backend-dev` (uvicorn contra el Postgres local de `supabase start`, ya migrado con `20261006000001`) + `next-dev`, sesión inyectada vía cookie `sb-127-auth-token` (usuario real creado por signup local + JWT HS256 propio firmado con el `SUPABASE_JWT_SECRET` local — el backend verifica HS256, GoTrue local emite ES256 por default, así que el token de signup no le servía al backend; documentado como hallazgo de infraestructura local, no del change), datos sembrados con las RPCs reales (`rpc_register_cash_movement`/`rpc_close_cash_session`/`rpc_register_bank_movement`, mismo camino que producción). Verificación por `read_page` (accessibility tree completo) + `getComputedStyle`/`getBoundingClientRect` vía `javascript_tool`, no por inspección visual de píxeles — más verificable mecánicamente que una captura, aunque no sustituye una revisión ocular real del PO.

- [x] 10.1 `/caja` verificada en **desktop (1280×720)**: `CashSessionPanel` (saldo inicial/esperado, badge Abierta), barra de acciones, `LedgerMovementsPanel` con 8 filas reales abarcando DOS sesiones (la cerrada Y la abierta — el corazón del pedido del PO), "Historial de sesiones". **mobile (375×812, UA Android)**: `docScrollWidth === windowInnerWidth` (sin overflow horizontal), mismo contenido accesible, diálogo de ajuste cabe en el viewport (325.85px de 375px)
- [x] 10.2 `/caja` verificada en **tema claro y oscuro**: badge "Ajuste" — oscuro `text: rgb(250,204,20)` sobre `rgba(250,204,20,0.15)`; claro `text: rgb(139,94,4)` sobre el mismo tinte — confirma que el token `-text` se resuelve distinto por tema (no hardcodeado) y que reutiliza los MISMOS tokens (`warning`) que ya pasan `token-contrast-aa.test.ts`, no tokens nuevos sin gatear
- [x] 10.3 `/banco` verificada en **desktop**: selector de cuenta, tabs Movimientos/Conciliación, historial con 3 filas reales (`Transferencia ent.` +3.000, `Ajuste` "diferencia contra extracto de agosto" -1.200 con badge "Sin conciliar", `Comisión` "comision mensual" -450), filtro `extraFilter` de conciliación (Todos/Sin conciliar/Conciliado) presente y funcional (verificado con `read_page`, no se probó el toggle mobile de esta tab específica por límite de tiempo — riesgo bajo: mismo `LedgerMovementsPanel` ya verificado responsive en `/caja`)
- [x] 10.4 `/banco` tab Conciliación verificada **intacta**: `innerText` de la tab = exactamente el contenido de la ex `ConciliacionPage` ("Importar extracto", "No hay una sesión de conciliación abierta para esta cuenta.", "Nueva conciliación") — confirma D8 (cero reescritura de C3) a nivel de contenido real, no solo de código
- [x] 10.5 Diálogo de ajuste verificado: contenido completo (radio Sobrante/Faltante, importe, motivo, advertencia de irreversibilidad) en desktop claro; en **mobile+oscuro** el diálogo cabe en el viewport (`dialogWidth 325.85 ≤ 375`), fondo oscuro aplicado (`rgb(9,9,11)`), y el error Zod "El motivo es obligatorio" se renderiza con `.text-destructive` cuando se confirma sin motivo. **Flujo E2E real completo**: llenar importe+motivo → `POST /sessions/{id}/movements` → 200 → refetch automático del historial (incluido el filtro activo `types=adjustment`) vía `refreshToken` — confirma que el ajuste registrado por la UI aparece en el historial sin recargar la página
- [x] 10.6 Sin scroll horizontal en mobile: confirmado (`hasHorizontalOverflow: false`) en `/caja`
- [x] 10.7 Gate de contraste AA: `token-contrast-aa.test.ts` sigue en 28/28 verde (no lo toca este change — audita `globals.css`, y el componente nuevo reutiliza los tokens `success`/`warning`/`destructive`/`muted` ya gateados, sin agregar ninguno)

## 11. Cierre

- [ ] 11.1 Suites completas verdes: backend ≥ baseline del 1.3, frontend ≥ baseline del 1.3, más los tests nuevos
- [ ] 11.2 Verificar en prod, después del merge, que la migración aplicó (`MAX(version) = 20261006000001`) y que el hot path de venta sigue registrando `cash_movements` (POS y formulario)
- [ ] 11.3 Verificar que las 2 sesiones abiertas históricas siguen operando y que su total de ajustes se calcula al vuelo
- [ ] 11.4 Actualizar `CHANGES.md`: reemplazar la nota del candidato `banco-y-caja-consolidado` (superseded por el pedido del PO del 2026-08-22) y registrar este change con su estado, sus OQs y el próximo candidato
- [ ] 11.5 Dejar asentadas para el PO las tres preguntas abiertas: **OQ-1** caja siempre abierta (opciones A/B/C del design), **OQ-2** asiento contable del ajuste, **OQ-3** si el ajuste debe restringirse a `owner`/`admin` vía `v3-rbac-multirole`
- [ ] 11.6 `mem_save` con topic_key `opsx/banco-caja-historial-ajustes/apply` — decisiones, hallazgos y estado real
