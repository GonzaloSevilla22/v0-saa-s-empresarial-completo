> **Tres applies independientes.** Los grupos 1-6 son la **Parte A** (un PR), 7-13 la **Parte B** (otro PR), 14-20 la **Parte C** (otro PR). Cada parte se mergea, se verifica en prod y recibe humo del PO antes de empezar la siguiente. El orden A → B → C es sign-off del PO (6.6) y además una restricción técnica: D3 del design explica por qué ningún rol funcional puede asignarse antes de que B migre `is_account_writer`.
>
> **TDD estricto en todo el change**: por cada task de implementación, el test que la describe se escribe y **se ve fallar** antes del código. Cada grupo arranca con su red de seguridad (correr la suite existente y registrar el baseline); un fallo preexistente se reporta, no se arregla acá.
>
> **Regla de integridad de función**: toda función reescrita parte de su cuerpo **vivo de prod** (`pg_get_functiondef`), nunca del último archivo de migración. *Gotcha registrado*: el `md5` local y el de prod difieren por los CRLF del checkout de Windows — comparar por líneas con `\r` removido, no por hash crudo.

## 1. Parte A — Checkpoint de estado real (antes de escribir una línea de SQL)

- [x] 1.1 SAFETY NET: backend `2227 passed, 4 skipped` (baseline, medido antes de tocar código); frontend no se corrió como baseline previo (se corrió como cierre en 6.3: `2641 passed, 1 failed` — el único fallo, `banco-conciliacion-import-warnings.test.tsx` por timeout de 20s, es ajeno a RBAC, módulo de conciliación bancaria, cero archivos frontend tocados por esta parte)
- [x] 1.2 Prod (read-only, 2026-09-11): `MAX(version) = 20261045000001`, 294 filas — coincide con el design. Migración de esta parte: **`20261047000001`** confirmada (local ya tenía `20261046000001` de `importador-gate-plan` aplicado por el workflow paralelo; no se dependió de su contenido)
- [x] 1.3 Prod: `account_members` 39 filas, **39 owner / 0 admin / 0 member**; 39 cuentas con exactamente 1 miembro, **0 con 2+**; 0 invitaciones pendientes — idéntico al propose, backfill trivial confirmado
- [x] 1.4 Prod: `to_regclass('account_member_roles')` y `to_regclass('account_role_catalog')` → NULL (no existen); `document_status_transitions.allowed_role` = `text`, `0/19` pobladas
- [x] 1.5 Cuerpo vivo de prod capturado vía `pg_get_functiondef` para las 5 funciones (`rpc_change_member_role`, `rpc_remove_member`, `rpc_accept_invitation`, `rpc_invite_member` [2 overloads existentes, no tocado], `rpc_my_account_role`) — diff línea a línea con `\r` removido contra el cuerpo local: **idéntico en las 4 reescritas** (única diferencia: una línea en blanco de formato del `psql -t -A`, no del cuerpo)
- [x] 1.6 `grep -rn "P0405\|P0406" supabase/ backend/` → 0 usos en ambos frentes. Confirmados libres

## 2. Parte A — Catálogo de roles (D1, D2)

- [x] 2.1 RED→GREEN: `supabase/tests/test_account_role_catalog.sql` bloque (1)+(2) — 8 entradas, minúsculas, sólo `viewer` con `is_writer=false`
- [x] 2.2 RED→GREEN: mismo gate, bloques (3)+(4)+(5) — `authenticated`/`anon` sin INSERT/UPDATE/DELETE; `authenticated` sí SELECT (policy scopeada, sin `anon`/`public`)
- [x] 2.3 GREEN: `account_role_catalog` creada (molde `document_status_transitions`), RLS solo-lectura + `REVOKE` de escritura
- [x] 2.4 GREEN: 8 filas sembradas, castellano, `sort_order` 1-8, seed `ON CONFLICT (code) DO UPDATE` — verificado idempotente en reaplicación ×2 (siempre 8 filas)
- [x] 2.5 TRIANGULATE: bloque (6) rol fuera de catálogo → `23503` sin dejar fila; bloque (7) `is_writer` editado y revertido con `UPDATE` simple, sin tocar ninguna función — **7/7 bloques PASS**

## 3. Parte A — Pivot de asignaciones (D3, D4, D5)

- [x] 3.1 RED→GREEN: `supabase/tests/test_account_member_roles_pivot.sql` bloque (1) unicidad `23505`; bloque (2) `CASCADE` real (borra la membresía, 0 filas del pivot después)
- [x] 3.2 RED→GREEN: `test_account_owner_invariant.sql` bloque (5) — owner+`expires_at` rechazado con `P0406`; owner sin vencimiento aceptado
- [x] 3.3 RED→GREEN: bloque (3) del gate del pivot — sin vencimiento activo, futuro activo, pasado NO activo (`member_active_roles`)
- [x] 3.4 GREEN: `account_member_roles` creada con `account_id` (denormalizado, ver nota de diseño en la migración — lo exige el constraint trigger diferido de 4.4 para resolver la cuenta aun con el `member_id` ya borrado en cascada), `member_id`, `role`, `assigned_by`, `assigned_at`, `expires_at`; CHECK de D5 + unicidad `(member_id, role)`
- [x] 3.5 GREEN: índices B-tree `(member_id)`, `(account_id)`, y `(expires_at) WHERE expires_at IS NOT NULL` — ningún parcial con `now()`
- [x] 3.6 GREEN: `member_active_roles`/`account_user_active_roles` `STABLE SECURITY DEFINER search_path=public`; `REVOKE ALL FROM PUBLIC, anon, authenticated` **sin ningún GRANT** — la ronda 1 retiró el `GRANT EXECUTE TO authenticated` original por no llevar guard de tenencia (un usuario ajeno leía los roles de cualquier `member_id`); si la Parte B las expone, debe hacerlo con su propio guard, nunca con un GRANT desnudo (candado: bloque (8) de `test_account_member_roles_pivot.sql`) — **hallazgo del gate `test_function_acl_gate.sql`**: un `REVOKE ALL FROM PUBLIC` solo no alcanza, Supabase otorga `EXECUTE` a `anon` por defecto en función nueva; corregido revocando explícito de `anon` también
- [x] 3.7 TRIANGULATE: bloque (6) miembro con 4 roles simultáneos (owner+seller+stock+cashier); bloque (7) 1 vencido + 1 vigente; verificado además a mano `member_active_roles(uuid_sin_asignaciones) = '{}'` (no NULL) — **9/9 bloques PASS** (bloques (8)/(9) sumados en la ronda 1: ACLs sin GRANT a `authenticated`/`anon`, FK compuesta anti-fantasma)

## 4. Parte A — Invariante de propietario y espejo (D3, D6)

- [x] 4.1 RED→GREEN: `test_account_owner_invariant.sql` — las **cuatro formas** de dejar a una cuenta con miembros y sin propietario activo, todas rechazadas con `P0405`: (1) `DELETE` directo sobre la fila del pivot (revocación); (10) `UPDATE` que degrada directamente el rol del único owner; (12) `UPDATE` que mueve la fila `owner` a OTRA cuenta; (13) **ronda 3 (finding MINOR-1)** `DELETE FROM account_members` que borra la MEMBRESÍA completa del único owner conservando otro miembro — dispara el MISMO constraint trigger vía el `ON DELETE CASCADE` hacia el pivot, molde del bloque (1). El bloque (4) reejercita (1) con un `DELETE` directo sin pasar por ningún RPC para mostrar que la garantía no depende del procedimiento que la invoque — no es una quinta forma distinta, es la misma (1) desde otro llamador. **Ronda 2 (finding MAJOR)**: la primera versión de este task sólo cubrió INSERT/DELETE; el UPDATE cross-account evadía `fn_guard_account_owner_invariant` (sólo miraba `NEW.account_id`), corregido en la migración y cerrado con el bloque (12). **Ronda 3 (finding MINOR-1)**: el texto de este task enumeraba "cuatro formas" pero sólo mapeaba a tres bloques reales distintos ((1)≈(4), (10), (12)) — la forma que faltaba (borrar `account_members`, no el pivot) se cerró con el bloque (13) nuevo
- [x] 4.2 RED→GREEN: bloque (2) — revocar a A + asignar a B en la misma transacción (forzado con `SET CONSTRAINTS ... IMMEDIATE`) se completa sin error
- [x] 4.3 RED→GREEN: bloque (3) — vaciar la cuenta por completo no bloqueado (satisfecho de forma vacua, verificado hasta el COMMIT real del gate)
- [x] 4.4 GREEN: `CREATE CONSTRAINT TRIGGER trg_guard_account_owner_invariant ... DEFERRABLE INITIALLY DEFERRED` sobre `account_member_roles`, `P0405`
- [x] 4.5 GREEN: `P0405`→409, `P0406`→422 en `backend/core/errors.py`; test RED→GREEN confirmado a mano (comentando las 2 entradas: 2 tests fallan con 500; restauradas: 17/17 pasan) en `backend/tests/test_errors_business_codes.py`
- [x] 4.6 RED→GREEN: bloque (6) — escritura directa de `account_members.role` revertida por el espejo; columna refleja la precedencia real del pivot para ambos miembros del fixture
- [x] 4.7 GREEN: **arquitectura de espejo de dos triggers** (no uno): `trg_derive_account_member_role` (BEFORE INSERT/UPDATE en `account_members`, única fuente de verdad de la derivación) + `trg_touch_account_member_role` (AFTER en el pivot, "toca" la membresía para forzar la re-derivación) — así una escritura directa a la columna y un cambio en el pivot convergen al MISMO resultado sin caminos duplicados. **Ronda 2 (finding MAJOR)**: la primera versión de `fn_touch_account_member_role` sólo tocaba `NEW.member_id` — un UPDATE que mueve `member_id` (bloque (11)) dejaba el espejo del miembro ORIGEN desincronizado (rol viejo). Corregido a `WHERE id = ANY (ARRAY[NEW.member_id, OLD.member_id])`, cerrado con el bloque (11)
- [x] 4.8 GREEN: `trg_audit_account_member_role` (AFTER INSERT/DELETE en el pivot) — `role.assigned`/`role.revoked` en `audit_logs`, shape canónico confirmado; `REVOKE ALL ... FROM PUBLIC, anon, authenticated` en las 5 funciones trigger nuevas — bloque (7) del gate de invariante confirma ambos tipos de registro
- [x] 4.9 Documentado en la cabecera de `test_account_owner_invariant.sql`: el gate NO puede correr bajo `replica` (usa `SET CONSTRAINTS ... IMMEDIATE`, que un `replica` global desactivaría junto con el propio invariante) — su cleanup usa `replica` sólo para `branches`, DESPUÉS de que todas las aserciones ya corrieron

## 5. Parte A — Reescritura de los RPCs de membresía y backfill

- [x] 5.1 RED→GREEN: `test_membership_rpcs_pivot_rewrite.sql` bloques (2)-(5) — firma/contrato/orden de validaciones intactos, incluido el gate `admin`⇒`pro` byte a byte (bloque 5)
- [x] 5.2 GREEN: backfill `INSERT ... SELECT account_id, id, 'owner', NULL, created_at ... ON CONFLICT (member_id, role) DO NOTHING` — verificado idempotente (reaplicación ×2, 0 filas nuevas la segunda vez)
- [x] 5.3 GREEN: `rpc_change_member_role` y `rpc_accept_invitation` reescritas escribiendo a través del pivot (mapeo `member`→`viewer`, D2); `rpc_remove_member` **sin escritura explícita al pivot** — el `DELETE` en `account_members` ya cascada al pivot vía FK, disparando invariante+auditoría automáticamente (documentado en la migración, sección 6.2); su único cambio de cuerpo es el guard de tenencia `v_caller_role IS NULL OR` de la ronda 1
- [x] 5.4 GREEN: `rpc_my_account_role` reescrita derivando de `member_active_roles()`, mismo vocabulario heredado — bloque (8) del gate confirma `owner`/`admin` para dos usuarios distintos
- [x] 5.5 TRIANGULATE: bloque (4) degradar único owner → mismo `{error}` exacto; bloque (6) `rpc_remove_member` cascada limpia; bloque (7) `rpc_accept_invitation` crea membresía + asignación equivalente con `assigned_by = invited_by`
- [x] 5.6 Verificado bloque (12) del gate — 0 overloads en las 5 funciones tocadas (las 4 RPCs + `handle_new_user`, ver hallazgo 6.3b más abajo)

## 6. Parte A — Cierre

- [x] 6.1 4 gates nuevos cableados en `KPI_Validation.yml` (steps al final de la lista) + migración sumada a la cadena de reaplicación idempotente, inmediatamente después de `20261045000001`
- [x] 6.2 **Desvío del literal de la task**: NO se corrió `supabase db reset` (regla dura del brief: "el implementador NUNCA corre db reset" — la base local es compartida con otro workflow). En su lugar: la migración se aplicó 2 veces consecutivas por `psql` sobre la base local compartida (que ya refleja la migration history completa vía `supabase start`/`db reset` de sesiones previas) y se corrió la **suite completa de 72 gates preexistentes** — 65/72 verdes; los 7 restantes son ruido preexistente de este entorno compartido (6 por email duplicado de fixtures de OTROS gates ya presentes ANTES de esta sesión — confirmado el email exacto pre-existía; 1 por conteo de KPIs contaminado por la acumulación de correr 72 gates en secuencia sin reset). Ninguno de los 7 toca `account_member_roles`/el invariante — confirmado que el `CASCADE` del pivot no bloquea ningún cleanup existente
- [x] 6.3 SAFETY NET de cierre: backend `2229 passed, 4 skipped` (2227 baseline + 2 tests nuevos de P0405/P0406); frontend `2641 passed, 1 failed` (el fallo es un timeout ajeno, módulo de conciliación bancaria, ver 1.1). `tsc`: no se corrió — no hay NINGÚN archivo frontend tocado por esta parte, por lo que no puede haber errores nuevos por construcción
- [x] 6.4 Declarado: **sin superficie frontend** en esta Parte A — ningún archivo bajo `frontend/` fue modificado
- [ ] 6.5 Verificación post-merge en prod — **pendiente**: sólo puede correr después de que el PR se mergee y la migración se aplique a prod (`npx supabase db push`, nunca MCP). Dejado explícitamente sin marcar
- [x] 6.6 Registrado en `CHANGES.md` (ficha `v3-rbac-multirole`, entrada de apply Parte A)
- [x] 6.7 **Ronda 1 de revisión adversarial aplicada (pre-merge)**: 1 blocker (backfill de la sección 5 hardcodeaba `'owner'` para toda fila — corregido a un `CASE` que mapea a la asignación equivalente), 3 major (`GRANT EXECUTE` de `member_active_roles`/`account_user_active_roles` a `authenticated` sin guard de tenencia — retirado; `rpc_change_member_role` aceptaba cualquier código del catálogo — rechazo agregado; agujero de tenencia preexistente en `rpc_change_member_role`/`rpc_remove_member` cuando el caller no es miembro — cerrado con `IS NULL OR`), 2 minor (target inexistente crasheaba con `23502` — corregido a `{error}`; wording del hallazgo 6.3b corregido en migración/CHANGES.md/gate — el signup degradaba en silencio, no abortaba) y 1 hardening no bloqueante (FK compuesta `(member_id, account_id)` en el pivot). 2 gates existentes ampliados (`test_membership_rpcs_pivot_rewrite.sql` 9→13 bloques, `test_account_member_roles_pivot.sql` 7→9 bloques) para cubrir cada finding. Re-verificado: migración reaplicable ×2, los 4 gates de la Parte A + `test_function_acl_gate.sql` en verde, backend `2229 passed, 4 skipped` (sin regresiones sobre el baseline de 1.1/6.3). Detalle completo en `CHANGES.md`.
- [x] 6.8 **Ronda 2 de revisión adversarial aplicada (pre-merge)**: 2 major (`fn_guard_account_owner_invariant` sólo miraba `NEW.account_id` — un UPDATE que mueve la fila owner a otra cuenta dejaba la cuenta de ORIGEN con miembros y 0 owners sin ningún error, reproducido en transacción aislada y commiteada; corregido a verificar ambas cuentas con un `FOREACH` sobre `unnest(ARRAY[NEW.account_id, OLD.account_id])`. `fn_touch_account_member_role` sólo tocaba `NEW.member_id` — un UPDATE que mueve `member_id` dejaba el espejo del miembro origen desincronizado; corregido a `WHERE id = ANY (ARRAY[NEW.member_id, OLD.member_id])`), 1 minor (el gate del blocker de la ronda 1, bloque (13), verificaba su PROPIA copia de la sentencia del backfill, no la del archivo real — demostrado reintroduciendo el hardcodeo `'owner'` en el archivo real y viendo el gate seguir en verde; corregido moviendo el bloque (13) a una Fase separada que reaplica el ARCHIVO REAL vía `\i`, molde de `test_cuentas_billetera_tipo.sql`) y 4 nits de fidelidad documental (`tasks.md` 3.6/3.7/5.3/5.6 desactualizados tras la ronda 1; comentario interno de `handle_new_user` seguía diciendo que el signup "abortaría" en vez de degradar en silencio; 3 gates nuevos con signup dejaban cashboxes huérfanas por borrar `branches` antes que `cashboxes` bajo `replica`; backfill de la sección 5 sin guard de "ya migrado", trampa para la Parte B). `test_account_owner_invariant.sql` ampliado 9→12 bloques (los 3 nuevos ejercitan exactamente la rama UPDATE que la task 4.1/R1 del design pedía y que la ronda 1 no cubrió — 2 para los majors, 1 candado adicional); `test_account_role_catalog.sql` bloque (6) con un degrade-don't-fail que antes era inalcanzable (resuelto el anchor antes de decidir, no después). Re-verificado: migración reaplicable ×2, los 4 gates de la Parte A + `test_function_acl_gate.sql` en verde, backend sin regresiones sobre el baseline. Detalle completo en `CHANGES.md`.
- [x] 6.9 **Ronda 3 de revisión adversarial aplicada (pre-merge, veredicto `ready=true`)**: 0 blocker/major, **3 minor + 4 nit**, todos aplicados. **MINOR-1**: faltaba cubrir la cuarta forma de dejar a una cuenta con miembros y sin owner — un `DELETE FROM account_members` (no del pivot) del único owner conservando otro miembro; el comportamiento ya era correcto (verificado por el revisor), sólo faltaba el gate — cerrado con el bloque (13) nuevo de `test_account_owner_invariant.sql` y el texto de la task 4.1 corregido para que las cuatro formas mapeen a bloques reales ((1), (10), (12), (13); (4) reejercita (1), no es una quinta forma). **MINOR-2**: fuera del lote de findings a aplicar en esta pasada (sin cambio de código asociado en este apply). **MINOR-3**: el pivot auditaba `INSERT`/`DELETE` pero no `UPDATE` — un cambio de `expires_at` o un movimiento de `member_id`/`account_id` (blocs (11)/(12)) no dejaba rastro; cerrado agregando `OR UPDATE` al trigger `trg_audit_account_member_role` y una rama `role.updated` en `fn_audit_account_member_role` con el snapshot OLD/NEW completo (`member_id`, `account_id`, `role`, `expires_at`), gateado por el bloque (14) nuevo. **NIT-1**: el marcador `(PR #PRA)` de `CHANGES.md` reemplazado por el número real `#557`. **NIT-2**: `REVOKE TRUNCATE` agregado sobre ambas tablas (`account_member_roles`, `account_role_catalog`) para que "cerrado por completo a authenticated/anon" sea literalmente cierto — verificado por `relacl` antes/después y `test_function_acl_gate.sql` en verde. **NIT-3**: esta misma task, documentando la ronda 3 en `tasks.md`/`CHANGES.md`. **NIT-4** (orden de bloques): dejado tal cual, cosmético, sin acción. Re-verificado: migración reaplicable ×2 en local, los 4 gates de la Parte A (`test_account_owner_invariant.sql` ahora 14 bloques) + `test_function_acl_gate.sql` + `test_errcode_5char_gate.sql` en verde, `pytest backend/tests/test_errors_business_codes.py` sin regresiones, `openspec validate --changes --strict` 1/1. Detalle completo en `CHANGES.md`.

## 7. Parte B — Checkpoint de estado real (CRÍTICO — antes de escribir SQL)

- [ ] 7.1 SAFETY NET: suite backend y frontend completas; baseline registrado
- [ ] 7.2 Reconfirmar `MAX(version)` en prod y fijar el número de migración de esta parte
- [ ] 7.3 Capturar el cuerpo **vivo de prod** de `is_account_writer`, `record_status_transition` y `custom_access_token_hook`, y guardarlo en el PR como línea base. Comparar por líneas con `\r` removido, no por `md5` crudo
- [ ] 7.4 Reconfirmar que las **48 policies sobre 20 tablas** que invocan `is_account_writer` siguen siendo esas y no crecieron; si crecieron, revisar si alguna nueva rompe el supuesto de D11
- [ ] 7.5 Enumerar los llamadores vivos de `record_status_transition` y verificar, uno por uno, **qué actor pasa cada uno** (`auth.uid()`, una variable, o NULL) — es lo que decide si la exención de sistema de D14 los cubre
- [ ] 7.6 Reconfirmar que ningún camino nuevo del frontend escribe por PostgREST alguna de las 20 tablas gateadas (la medición que sostiene D12)

## 8. Parte B — `is_account_writer` sobre el pivot (D11)

- [ ] 8.1 RED: gate SQL que, sobre dos cuentas y varios roles, asserta que un miembro con rol que concede escritura pasa, un `viewer` no pasa, y un rol **vencido** no pasa
- [ ] 8.2 RED: gate SQL que asserta que la firma de `is_account_writer` no cambió y que las 48 policies siguen existiendo con sus nombres actuales
- [ ] 8.3 GREEN: reescribir sólo el **cuerpo** de `is_account_writer` para resolver contra el pivot derivando el conjunto de escritores del catálogo (`is_writer`), partiendo del cuerpo vivo de 7.3
- [ ] 8.4 Confirmar que `current_account_ids()` **no se toca** (resuelve tenencia, no rol — medición del design) y dejar constancia en el PR
- [ ] 8.5 TRIANGULATE: miembro con 2 roles de los cuales 1 vencido; miembro sólo `viewer`; miembro de otra cuenta

## 9. Parte B — Claim del conjunto de roles (D8)

- [ ] 9.1 RED: test de que el hook emite el claim nuevo con los roles **activos** y conserva el claim singular derivado por precedencia
- [ ] 9.2 RED: test de que una asignación **vencida** no viaja en el claim, aunque su fila siga existiendo
- [ ] 9.3 RED: test de que un error al resolver los roles degrada devolviendo los claims intactos, deja `RAISE WARNING`, y **no rompe el login**
- [ ] 9.4 GREEN: reescribir `custom_access_token_hook` desde el cuerpo vivo de 7.3, agregando el claim del conjunto **dentro** del bloque protegido por el `EXCEPTION WHEN OTHERS` existente
- [ ] 9.5 GREEN: conceder al proceso de emisión de claims los permisos de lectura sobre el pivot y el catálogo (precedente D5 de `v31-authz-token-hook`: `supabase_auth_admin` no tenía ningún grant y los claims salían ausentes sin explicación)
- [ ] 9.6 Verificar la activación **por `auth_logs`**, nunca por `auth.users.raw_app_meta_data` — trampa ya documentada: da 0/38 aunque el hook esté activo

## 10. Parte B — Guards del backend (D10)

- [ ] 10.1 RED: test de que `require_account_role` autoriza cuando **alguno** de los roles del conjunto está permitido, y deniega cuando ninguno lo está
- [ ] 10.2 RED: test del orden de resolución de las tres vías (claim del conjunto → claim singular como conjunto de uno → asignaciones en la base) y de que sin ninguna de las tres **deniega**, nunca concede
- [ ] 10.3 RED: test de que el fallback a la base lee las **asignaciones vigentes**, no la columna de rol único (R6)
- [ ] 10.4 RED: test de contrato anti-deriva de `AuthContext` con la clave nueva del conjunto (el test existente debe fallar hasta declararla)
- [ ] 10.5 GREEN: agregar la clave del conjunto a `AuthContext` y extraerla en `get_current_user`
- [ ] 10.6 GREEN: migrar `require_account_role` a evaluar el conjunto, reescribiendo el fallback a la base
- [ ] 10.7 GREEN: crear `backend/core/rbac.py` con las capacidades nombradas de D15 (`CAN_CONFIGURE`, `CAN_SELL`, `CAN_CASH`, `CAN_STOCK`, `CAN_PURCHASE`, `CAN_ACCOUNT`) y migrar las **15 llamadas** de los 4 services a usarlas — `CAN_CONFIGURE` deja las 15 con el mismo conjunto efectivo que hoy (`owner, admin`), así que el comportamiento no cambia
- [ ] 10.8 Confirmar que las **59** llamadas a `require_role(auth, ["user","admin"])` quedan **intactas**: son rol de plataforma, otro espacio de nombres, y mezclarlos es lo que `authz-token-claims` prohíbe

## 11. Parte B — Matriz rol × transición (D13, D14, D15)

- [ ] 11.1 RED: gate SQL que asserta el reparto exacto **14 pobladas / 5 NULL** sobre las 19 filas, y que las 5 NULL son precisamente las 3 de `fiscal_document` y las 2 de `quote → expired`
- [ ] 11.2 RED: gate SQL de la segregación de funciones — un `cashier` confirma una venta pero **no la anula**; un `stock` completa una transferencia; un `accountant` abre y cierra conciliación; un rol **vencido** no habilita nada
- [ ] 11.3 RED: gate SQL de las dos exenciones de D14: actor nulo (relay fiscal, cron) y fila sin roles declarados
- [ ] 11.4 GREEN: `ALTER COLUMN allowed_role TYPE text[] USING (CASE WHEN allowed_role IS NULL THEN NULL ELSE ARRAY[allowed_role] END)` — no-op sobre datos, 0/19 pobladas
- [ ] 11.5 GREEN: poblar las 14 filas con la matriz normativa de D15 del design
- [ ] 11.6 GREEN: reescribir `record_status_transition` desde el cuerpo vivo de 7.3, agregando la verificación de rol con sus dos exenciones y `P0403` (ya mapeado a 403)
- [ ] 11.7 TRIANGULATE: ejercitar la transición desde el POS, desde el formulario de venta y desde el relay, confirmando que con las 39 cuentas actuales (100% `owner`) **ninguna** cambia de resultado

## 12. Parte B — Barrido de vencimientos (D16)

- [ ] 12.1 RED: gate SQL de idempotencia — reejecutar el barrido no agrega un segundo registro `role.expired` para la misma asignación
- [ ] 12.2 RED: gate SQL de que el barrido **no borra** asignaciones ni cambia ningún permiso
- [ ] 12.3 RED: gate SQL de que, con el barrido detenido, un rol vencido **igual** deja de autorizar (el corte lo produce el predicado, no el cron)
- [ ] 12.4 GREEN: función del barrido con dedup por día argentino (molde del digest de `cobranzas-vencimientos`, D8) y registro `role.expired` en `audit_logs`
- [ ] 12.5 GREEN: registrar el job `pg_cron` diario y confirmarlo activo

## 13. Parte B — Cierre (CRÍTICO)

- [ ] 13.1 Cablear los gates nuevos en `KPI_Validation.yml` y sumar la migración a la cadena de reaplicación idempotente
- [ ] 13.2 Migración limpia contra `supabase db reset` local + los 68+ gates preexistentes en el orden real del workflow
- [ ] 13.3 SAFETY NET de cierre: suites verdes contra el baseline de 7.1; `tsc` sin errores nuevos
- [ ] 13.4 Revisión adversarial propia del PR antes de pedir merge: buscar específicamente el fail-open (un guard que conceda por ausencia de dato), la divergencia RLS/guard (R4) y el caso del rol vencido en cada una de las tres capas
- [ ] 13.5 Declarar en el PR: **sin superficie frontend propia**; el requisito es que las ~40 pantallas que leen `accountRole`/`isWriter` no se rompan
- [ ] 13.6 Verificación post-merge en prod (read-only, agregados): `MAX(version)`; reparto **14/5** de `allowed_role`; cuerpo vivo de `is_account_writer` leyendo el pivot; claim nuevo presente vía `auth_logs`; cron activo; **0** rechazos `P0403` de transición — **con control positivo**, para distinguir "no hubo rechazos" de "no hubo tráfico"
- [ ] 13.7 Humo del PO: confirmar que su operación diaria sigue igual — vender, cobrar, cerrar caja
- [ ] 13.8 Registrar en `CHANGES.md` el resultado de la Parte B y sus hallazgos

## 14. Parte C — Checkpoint y endpoints

- [ ] 14.1 SAFETY NET: suites completas; baseline registrado. Reconfirmar `MAX(version)` y fijar el número de migración
- [ ] 14.2 Capturar el cuerpo vivo de `rpc_invite_member` y de los RPCs de membresía tal como quedaron tras la Parte A
- [ ] 14.3 RED: tests de las RPCs nuevas de asignación y revocación — autoridad insuficiente, rol fuera del catálogo, `owner` con vencimiento, y el invariante de propietario
- [ ] 14.4 GREEN: RPCs de asignar rol (con vencimiento opcional) y revocar rol, `SECURITY DEFINER` con `search_path` fijo, con la jerarquía de D-`org-roles` (el administrador no otorga ni retira `owner`/`admin`)
- [ ] 14.5 RED: tests del router/service/repository nuevos de administración de miembros — 3 capas, sin lógica de negocio en el router, errores RFC 7807
- [ ] 14.6 GREEN: endpoints FastAPI de listar miembros con sus roles, asignar, revocar y quitar miembro

## 15. Parte C — Retiro del gate de plan y normalización de errores (D17, D18)

- [ ] 15.1 RED: test de que una cuenta en el plan de menor precio, con cupo disponible, puede asignar cualquier rol del catálogo
- [ ] 15.2 RED: test de que el cupo sigue contando **miembros**, no asignaciones: un miembro con 4 roles consume un lugar
- [ ] 15.3 GREEN: retirar la condición de plan de `rpc_change_member_role` y de `rpc_invite_member`, conservando el resto de sus validaciones
- [ ] 15.4 GREEN: normalizar los `P0001` de `rpc_invite_member` y `rpc_accept_invitation` (cupo, invitación duplicada, falta de autoridad) a `P04xx` **conservando el texto del mensaje** (precedente: `rpc_close_branch` de `P0409` a `P0428`)
- [ ] 15.5 GREEN: invitación con **conjunto** de roles; una invitación sin roles declarados resuelve al rol de solo lectura
- [ ] 15.6 Corregir la tabla comercial de `knowledge-base/03_actores_y_roles.md`, que promete "Roles internos: ❌ / ❌ / Básicos / Avanzados" por plan — la decisión 6.2 del PO la deroga. **`CLAUDE.md`/`AGENTS.md` no se tocan**

## 16. Parte C — Frontend: tipos y hook (D19)

- [ ] 16.1 RED: test de que `isWriter` sigue siendo *fail-OPEN* — trata como escritor el estado indeterminado, el error transitorio **y** el valor heredado `member` de una caché vieja
- [ ] 16.2 RED: test de que `useOrgRole` devuelve el derivado singular con la misma forma que hoy, además del array nuevo
- [ ] 16.3 GREEN: `OrgRole` pasa a la unión de los 8 códigos; `useOrgRole` devuelve `{ role, roles, isWriter, isLoading }`
- [ ] 16.4 GREEN: ajustar `isWriter` a `role !== "viewer" && role !== "member"` — **los dos** valores (R8)
- [ ] 16.5 Recorrer los archivos que consumen `accountRole`/`isWriter` y confirmar que ninguno rompe; los que sólo preguntan "¿puedo escribir?" **no se migran al array** (minimiza el churn, recomendación del explore §4 Parte C)

## 17. Parte C — Superficie de gestión de roles

- [ ] 17.1 RED: tests de la pantalla — listado con varios roles por miembro, vencimiento visible, asignación vencida distinguible de vigente, estado vacío con un solo miembro, y ausencia de controles para quien no tiene autoridad
- [ ] 17.2 GREEN: extender `/organizacion/roles` **en la misma ruta** (D0/6.3): listar, asignar, asignar con vencimiento, revocar y quitar miembro
- [ ] 17.3 GREEN: las etiquetas y descripciones salen del **catálogo**, no de un objeto codificado en la pantalla (hoy `ROLE_LABELS` está hardcodeado)
- [ ] 17.4 GREEN: retirar el aviso "El rol Admin está disponible solo en el plan Pro" y el `availableRoles` gateado por plan
- [ ] 17.5 GREEN: `/organizacion/invitar` invita con conjunto de roles
- [ ] 17.6 Verificar que los accesos existentes siguen llegando: desde `/organizacion/invitar` y desde `/configuracion` (`components/settings/TeamSection.tsx`)
- [ ] 17.7 Invalidación de las queries de miembros y de rol en **todas** las mutaciones nuevas, para que el listado refresque sin recargar

## 18. Parte C — Pasada visual

- [ ] 18.1 Pasada visual en las **4 combinaciones** (escritorio/móvil × claro/oscuro) de `/organizacion/roles` y `/organizacion/invitar`, con capturas en el PR
- [ ] 18.2 Verificar tokens semánticos (nada de colores literales nuevos) y contraste AA — el gate `token-contrast-aa` debe seguir verde
- [ ] 18.3 Verificar que la pantalla no desborda horizontalmente en móvil (el `<main>` con `min-w-0` de `qa-integral-modulos` G2 ya lo cubre; confirmarlo, no asumirlo)
- [ ] 18.4 Verificar accesibilidad de los controles nuevos: etiquetas asociadas, foco visible, y el selector de fecha de vencimiento operable por teclado

## 19. Parte C — Cierre

- [ ] 19.1 Cablear los gates nuevos en `KPI_Validation.yml` y sumar la migración a la cadena de reaplicación
- [ ] 19.2 SAFETY NET de cierre: suites verdes contra el baseline de 14.1; `tsc` sin errores nuevos
- [ ] 19.3 Verificación post-merge en prod (read-only, agregados): `MAX(version)`; ausencia del gate de plan en el cuerpo vivo de los RPCs; ACLs de las RPCs nuevas sin `EXECUTE` para `anon`
- [ ] 19.4 Humo real del PO — **el humo que importa de todo el change** (R7): crear una segunda membresía en una cuenta **de prueba** (nunca una con datos de un cliente real), asignarle `cashier` con vencimiento, comprobar que puede cobrar, que **no** puede anular una venta confirmada, y que al vencer pierde el acceso
- [ ] 19.5 Confirmar que `audit_logs` registró `role.assigned` y, tras el vencimiento, `role.expired`

## 20. Cierre del change completo

- [ ] 20.1 Actualizar la ficha `### \`v3-rbac-multirole\`` de `CHANGES.md` con el resultado de las tres partes, sus hallazgos y los candidatos que deja
- [ ] 20.2 Dar de alta el candidato **`rbac-rls-grano-fino`** (D12) con su alcance: helpers `is_account_writer_for(account_id, domain)` y migración de las 48 policies
- [ ] 20.3 Registrar el estado de las 3 OQs del design (selector de cuenta activa, aviso de vencimiento, `accountant` y el cierre de caja) con lo que el PO haya resuelto
- [ ] 20.4 Sincronizar specs y archivar: `openspec validate --specs --strict` verde, y verificar que los requirements movidos aparecen **en HEAD** y no sólo en el árbol de trabajo (gotcha conocido de `openspec archive`)
- [ ] 20.5 Notificar a los 4 changes represados (`v4-seguridad-04`/`05`, `v4-ia-09`/`v3-ai-agent-mcp-tools`, `v4-plataforma-01`, `v4-seguridad-09`) que su dependencia quedó satisfecha
