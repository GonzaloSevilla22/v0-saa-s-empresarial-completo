> **Tres applies independientes.** Los grupos 1-6 son la **Parte A** (un PR), 7-13 la **Parte B** (otro PR), 14-20 la **Parte C** (otro PR). Cada parte se mergea, se verifica en prod y recibe humo del PO antes de empezar la siguiente. El orden A → B → C es sign-off del PO (6.6) y además una restricción técnica: D3 del design explica por qué ningún rol funcional puede asignarse antes de que B migre `is_account_writer`.
>
> **TDD estricto en todo el change**: por cada task de implementación, el test que la describe se escribe y **se ve fallar** antes del código. Cada grupo arranca con su red de seguridad (correr la suite existente y registrar el baseline); un fallo preexistente se reporta, no se arregla acá.
>
> **Regla de integridad de función**: toda función reescrita parte de su cuerpo **vivo de prod** (`pg_get_functiondef`), nunca del último archivo de migración. *Gotcha registrado*: el `md5` local y el de prod difieren por los CRLF del checkout de Windows — comparar por líneas con `\r` removido, no por hash crudo.

## 1. Parte A — Checkpoint de estado real (antes de escribir una línea de SQL)

- [ ] 1.1 SAFETY NET: correr la suite backend y la frontend completas; registrar el baseline (`N passed`) y cualquier fallo preexistente como tal, sin corregirlo
- [ ] 1.2 Reconfirmar contra prod (read-only, agregados sin PII): `MAX(version)` de `schema_migrations` y fijar el número de migración de esta parte — el propose lo estimó en `20261047000001` sobre un `MAX` de `20261045000001`, y este proyecto ya renumeró una migración tres veces por PRs concurrentes
- [ ] 1.3 Reconfirmar el conteo y el reparto de `account_members` por rol, y la cantidad de cuentas con 2+ miembros (el propose midió 39 / 100% `owner` / 0). Si apareció un `admin` o un `member` real, el backfill de 5.2 deja de ser trivial y hay que decidir su mapeo antes de seguir
- [ ] 1.4 Reconfirmar que `account_member_roles` y `account_role_catalog` no existen en prod, y que `document_status_transitions.allowed_role` sigue en `text` con 0/19 pobladas
- [ ] 1.5 Capturar el cuerpo **vivo de prod** de las 5 funciones que esta parte reescribe o cuyo comportamiento debe preservar byte a byte (`rpc_change_member_role`, `rpc_remove_member`, `rpc_accept_invitation`, `rpc_invite_member`, `rpc_my_account_role`) y guardarlo en el PR como línea base de comparación
- [ ] 1.6 Verificar que `P0405` y `P0406` siguen libres (0 usos en `supabase/` y `backend/`); si alguno fue tomado por un PR intermedio, elegir el siguiente libre y actualizar el design

## 2. Parte A — Catálogo de roles (D1, D2)

- [ ] 2.1 RED: gate SQL que asserta que el catálogo existe, tiene exactamente 8 entradas con los códigos en **minúscula**, y que sólo la entrada `viewer` tiene `is_writer = false`
- [ ] 2.2 RED: gate SQL que asserta que `authenticated` y `anon` no pueden insertar, modificar ni eliminar entradas del catálogo, y que `authenticated` sí puede leerlo
- [ ] 2.3 GREEN: crear `account_role_catalog` (`code` PK, `label`, `description`, `sort_order`, `is_writer`) con RLS de solo lectura y `REVOKE` de escritura, molde de `document_status_transitions`
- [ ] 2.4 GREEN: sembrar las 8 entradas con etiqueta y descripción en castellano y `sort_order` estable; seed idempotente (`ON CONFLICT DO UPDATE`) porque el auto-apply de Supabase puede reejecutar
- [ ] 2.5 TRIANGULATE: caso de un código fuera del catálogo, y caso de una entrada con `is_writer` que cambia sin tocar ninguna función

## 3. Parte A — Pivot de asignaciones (D3, D4, D5)

- [ ] 3.1 RED: gate SQL que asserta unicidad `(member_id, role)`, FK al catálogo, y `ON DELETE CASCADE` desde `account_members`
- [ ] 3.2 RED: gate SQL que asserta que asignar `owner` con `expires_at` es rechazado (D5) y que asignarlo sin vencimiento se acepta
- [ ] 3.3 RED: test de `member_active_roles` — rol sin vencimiento activo, rol con vencimiento futuro activo, rol con vencimiento pasado **no** activo
- [ ] 3.4 GREEN: crear `account_member_roles` (`id`, `member_id`, `role`, `assigned_by`, `assigned_at`, `expires_at`) con el CHECK de D5 y la unicidad de 3.1
- [ ] 3.5 GREEN: índices B-tree sobre `(member_id)` y sobre `(expires_at) WHERE expires_at IS NOT NULL` — **ningún índice parcial con `now()` en el predicado** (no es inmutable; D4)
- [ ] 3.6 GREEN: funciones `member_active_roles(member_id)` y `account_user_active_roles(account_id, user_id)`, `STABLE`, `SECURITY DEFINER` con `search_path` fijo, y `REVOKE` de los roles de aplicación salvo lo que la UI necesite
- [ ] 3.7 TRIANGULATE: miembro con 3 roles, miembro con 1 vencido y 1 vigente, miembro sin ninguna asignación

## 4. Parte A — Invariante de propietario y espejo (D3, D6)

- [ ] 4.1 RED: gate SQL con las **cuatro** formas de intentar dejar la cuenta sin propietario (revocar el único `owner`, borrar su fila del pivot, borrar su membresía conservando otros miembros, y un `UPDATE` que lo desplace) — las cuatro deben fallar con `P0405`
- [ ] 4.2 RED: gate SQL del caso que **debe pasar**: transferir la propiedad quitándosela a A y dándosela a B **en la misma transacción** (es la razón por la que el trigger es `DEFERRABLE INITIALLY DEFERRED` y no `BEFORE` por fila)
- [ ] 4.3 RED: gate SQL del caso vacuo: vaciar una cuenta de todos sus miembros **debe** completarse sin que el invariante lo bloquee
- [ ] 4.4 GREEN: constraint trigger `DEFERRABLE INITIALLY DEFERRED` sobre `account_member_roles` que verifica el invariante al cierre de la transacción y levanta `P0405`
- [ ] 4.5 GREEN: mapear `P0405` (409) y `P0406` (422) en `backend/core/errors.py`, con test de que ambos traducen a RFC 7807 con su `code`
- [ ] 4.6 RED: gate SQL que asserta `account_members.role ≡ precedencia(member_active_roles)` para toda fila, y que un intento de escribir la columna directamente queda revertido por el espejo
- [ ] 4.7 GREEN: trigger de espejo sobre el pivot que recalcula `account_members.role` con la precedencia de D3 (`owner` → `admin` → solo lectura)
- [ ] 4.8 GREEN: trigger de auditoría que registra `role.assigned` y `role.revoked` en `audit_logs` con el shape canónico `(account_id, user_id, action, entity_type, entity_id, metadata, created_at)`; `REVOKE` de la función del trigger (PostgREST expone por default toda función `public`)
- [ ] 4.9 Documentar en el propio archivo del gate que **no puede correr bajo `session_replication_role = replica`** (desactiva constraint triggers) — el proyecto tiene 41 wraps de `replica` sobre 20 archivos de gates

## 5. Parte A — Reescritura de los RPCs de membresía y backfill

- [ ] 5.1 RED: tests que fijan que los 3 RPCs reescritos conservan **firma, contrato `{ok}|{error}` y el orden exacto de sus validaciones** — incluido el gate de plan de `admin`, que en esta parte se conserva **byte a byte** (D17: se retira recién en C)
- [ ] 5.2 GREEN: backfill idempotente `INSERT … SELECT id, 'owner', created_at FROM account_members ON CONFLICT DO NOTHING`, con `assigned_by` NULL (nadie lo asignó: vino del provisioning)
- [ ] 5.3 GREEN: reescribir `rpc_change_member_role`, `rpc_remove_member` y `rpc_accept_invitation` para escribir **a través del pivot**, partiendo del cuerpo vivo capturado en 1.5
- [ ] 5.4 GREEN: reescribir `rpc_my_account_role` para derivar del pivot, devolviendo el **mismo vocabulario heredado** que hoy (no romper `useOrgRole`)
- [ ] 5.5 TRIANGULATE: degradar al único `owner` sigue devolviendo el mismo `{error}` de antes; expulsar a un `member` sigue funcionando; aceptar una invitación crea la asignación equivalente
- [ ] 5.6 Verificar que ninguna de las 4 funciones quedó con un **overload** vivo (gotcha `42725`: usar `DROP FUNCTION` + `CREATE` cuando cambie la firma, nunca `CREATE OR REPLACE` con `DEFAULT` nuevo)

## 6. Parte A — Cierre

- [ ] 6.1 Cablear los gates SQL nuevos en `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1`, y sumar la migración a la cadena de reaplicación idempotente del workflow
- [ ] 6.2 Correr la migración contra `supabase db reset` local y confirmar que los gates preexistentes que limpian con `DELETE FROM account_members` siguen pasando (el CASCADE al pivot no debe bloquearlos — D6)
- [ ] 6.3 SAFETY NET de cierre: suite backend y frontend verdes contra el baseline de 1.1; `tsc` sin errores nuevos
- [ ] 6.4 Declarar explícitamente en el PR: **sin superficie frontend** en esta parte (regla PO 2026-08-02 — la omisión es una decisión, no un olvido)
- [ ] 6.5 Verificación post-merge en prod (read-only, agregados): `MAX(version)` = el número de 1.2; `count(*)` del pivot = `count(*)` de `account_members`; **0** filas con el espejo desincronizado; las 4 funciones vivas sin overload; ACLs sin `EXECUTE` para `anon`
- [ ] 6.6 Registrar en `CHANGES.md` el resultado de la Parte A y los hallazgos que haya dejado

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
