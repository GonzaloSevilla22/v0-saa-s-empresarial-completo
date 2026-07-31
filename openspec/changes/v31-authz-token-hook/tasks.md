> **Modo TDD estricto.** Cada tarea de código va precedida por su test (RED) y el test debe fallar por la razón esperada antes de escribir la implementación (GREEN). Ninguna tarea `[x]` sin ejecución real de la suite.
> **Governance CRÍTICO** — auth de 34 usuarios reales. El agente prepara, migra y testea; **la activación en producción (grupo 8) es acción del PO** y requiere OQ-1 resuelta (ver `design.md`). No se fabrican credenciales ni se inicia sesión en nombre de nadie.

## 1. Red de seguridad y evidencia previa

- [ ] 1.1 Ejecutar la suite backend completa (`pytest backend/tests`) y registrar el baseline exacto. Si algo ya falla, **NO** arreglarlo: reportarlo como fallo preexistente y detenerse para confirmar con el orquestador.
- [ ] 1.2 Baseline acotado de los archivos que este change toca: `test_auth.py`, `test_database.py`, `test_cost_center_service.py`, `test_cost_center_router.py`, `test_products.py`, `test_organizations.py`.
- [ ] 1.3 Re-verificar contra prod (read-only, MCP) los seis números que sostienen el diseño y pegarlos en el PR: distribución de `profiles.role`, de `account_members.role`, de `accounts.billing_plan`, cuentas con trial vigente, usuarios con 2+ membresías, y `count(*)` de `cost_centers`. **Si alguno cambió** respecto de `design.md` (§Context), detenerse y revisar D1/D3 antes de seguir.
- [ ] 1.4 Barrido de call sites: contar `require_role(auth, [...])` por lista de roles y confirmar la partición del diseño (56 `["user","admin"]`, 3 `["owner","admin"]` en `cost_centers`, el resto individualmente identificado). Cualquier call site que no encaje en la partición se documenta antes de tocar nada.
- [ ] 1.5 Confirmar los GRANTs actuales de `supabase_auth_admin` sobre `profiles`, `account_members` y `accounts` (esperado: sólo `profiles`).

## 2. Migración del hook — claims de rol (D1, D5)

- [ ] 2.1 **RED (DB)** — Escribir el gate de verificación de la migración: invocar `public.custom_access_token_hook` con un `user_id` real y exigir que el resultado contenga `app_metadata.role` **y** `app_metadata.account_role`. Ejecutar `npx supabase db reset` local: debe fallar porque el hook todavía no emite `account_role`.
- [ ] 2.2 **GREEN** — Nueva migración idempotente que redefine el hook (`CREATE OR REPLACE`, misma firma `(jsonb)`): lee `profiles.role` → `role` (sin cambio semántico) y `account_members.role` de la cuenta activa → `account_role`. Agrega `SET search_path = public, pg_temp`, conserva `EXCEPTION WHEN OTHERS → claims intactos` y suma `RAISE WARNING` con `SQLSTATE` en el handler. Ejecutar el reset: el gate de 2.1 pasa.
- [ ] 2.3 **GREEN (permisos)** — En la misma migración: `GRANT SELECT` sobre `account_members` para `supabase_auth_admin` + policy `auth_admin_can_read_memberships` (patrón idéntico al de `profiles` en `20260800000004`). Verificar que sin el GRANT el gate falla y con él pasa — es la prueba de que el blindaje no está tapando un error de permisos.
- [ ] 2.4 **TRIANGULATE (DB)** — Segundo y tercer caso en el gate: (a) un usuario **sin** membresía produce claims sin `account_role` pero **con** `role`, y el login no falla; (b) un `user_id` inexistente devuelve los claims originales intactos sin lanzar excepción. Ejecutar: los tres casos pasan.
- [ ] 2.5 Verificar que la función quedó con **una sola** definición (`SELECT count(*) FROM pg_proc WHERE proname='custom_access_token_hook'` = 1) y que `proconfig` contiene el `search_path`.

## 3. Migración del hook — claim de plan (D3)

- [ ] 3.1 **RED (DB)** — Extender el gate: el resultado debe contener `app_metadata.plan` con el plan **efectivo** de la cuenta. Caso obligatorio: cuenta con trial vigente de un plan superior → el claim trae el plan del trial, no el contratado. Ejecutar: falla.
- [ ] 3.2 **GREEN** — Agregar la lectura de `accounts` al hook con la regla de plan efectivo de la capability `plan-gating` (trial vigente tiene precedencia), más `GRANT SELECT` + policy `auth_admin_can_read_account_plan` para `supabase_auth_admin` sobre `accounts`. Ejecutar: 3.1 pasa.
- [ ] 3.3 **TRIANGULATE (DB)** — Casos adicionales en el gate: cuenta sin trial → `billing_plan`; cuenta con trial **vencido** → `billing_plan`; cuenta sin plan → el valor por defecto más restrictivo, nunca el más alto. Ejecutar: todos pasan.
- [ ] 3.4 Documentar en la cabecera de la migración la salida de OQ-1 opción (c): qué línea exacta se comenta para emitir sólo los claims de rol, y que la migración es re-aplicable tal cual.

## 4. Cuenta activa determinística (D4)

- [ ] 4.1 **RED** — Test en `backend/tests/` que ejercita `get_account_id` con un usuario de dos membresías y afirma que devuelve la determinada por el criterio explícito (la más antigua, desempatada por PK). Debe fallar mientras la query no tenga `ORDER BY`.
- [ ] 4.2 **GREEN** — Agregar el `ORDER BY` explícito en `backend/core/deps.py::get_account_id`. Ejecutar: 4.1 pasa.
- [ ] 4.3 **GREEN (DB)** — Alinear el hook al mismo criterio y agregar al gate el caso de dos membresías: la cuenta que describe el claim es la misma que devuelve el resolver.
- [ ] 4.4 **TRIANGULATE** — Invertir el orden de creación de las dos membresías y verificar que ambos lados siguen coincidiendo (descarta que el resultado dependa del orden físico de las filas).

## 5. Backend — contrato del contexto y guard de rol de tenant (D6)

- [ ] 5.1 **RED** — Test de contrato en `test_auth.py`: un JWT con `app_metadata` completo produce un contexto cuyas claves coinciden con `AuthContext.__annotations__`, ahora incluyendo `account_role`. Debe fallar (la clave no existe).
- [ ] 5.2 **GREEN** — Agregar `account_role: str | None` a `AuthContext` y su lectura en `get_current_user`. Ejecutar: 5.1 pasa y el test anti-deriva existente sigue verde.
- [ ] 5.3 **RED** — Test del **no-op de autorización** (el riesgo central de D1): un JWT con `app_metadata = {"role":"user","account_role":"owner","plan":"gratis"}` ejercita un endpoint con guard `require_role(["user","admin"])` y **debe seguir pasando**. Verificar que el test falla si se inyecta `account_role` en la clave `role` (prueba de que el test detecta el modo de fallo catastrófico, no es una tautología).
- [ ] 5.4 **RED** — Test de `require_account_role`: con el claim presente autoriza sin tocar la base; el mock de conexión no debe recibir ninguna query.
- [ ] 5.5 **GREEN** — Implementar `require_account_role(conn, auth, allowed)` en `backend/core/guards.py`, siguiendo el patrón asíncrono de `require_platform_admin`. Ejecutar: 5.4 pasa.
- [ ] 5.6 **TRIANGULATE** — Tres casos más: (a) claim ausente → resuelve contra la base y autoriza igual; (b) claim ausente y sin membresía → **403** (nunca permisivo); (c) claim presente con rol no permitido → 403 sin consultar la base. Ejecutar: todos pasan.

## 6. `cost_centers` deja de dar 403 universal (D9, criterio (a))

- [ ] 6.1 **RED** — Test en `test_cost_center_service.py`: un usuario cuyo `account_role` es `owner` crea un centro de costo y la operación **tiene éxito**. Debe fallar hoy con 403.
- [ ] 6.2 **GREEN** — Migrar los 3 guards de `backend/services/cost_centers.py` a `await require_account_role(conn, auth, ["owner","admin"])`, propagando la conexión desde el router (arquitectura de 3 capas: el router inyecta, el service decide). Ejecutar: 6.1 pasa.
- [ ] 6.3 **TRIANGULATE** — (a) `account_role="member"` → 403; (b) claim ausente + membresía `owner` en la base → éxito (camino de transición); (c) los otros endpoints de `cost_centers` (lectura) no cambian de comportamiento. Ejecutar: todos pasan.
- [ ] 6.4 **REFACTOR** — Confirmar por barrido que **ningún otro** service quedó comparando rol de tenant contra el espacio de plataforma ni al revés. Ejecutar la suite completa: sin regresiones respecto de 1.1.

## 7. Diagnóstico de claims y regresión de plan (D8, D3)

- [ ] 7.1 **RED** — Test del endpoint `GET /auth/claims-status`: con un JWT que trae los tres claims, la respuesta reporta las tres presencias en `true` y los valores efectivos. Debe fallar (el endpoint no existe).
- [ ] 7.2 **GREEN** — Implementar el endpoint. **Sólo** booleanos de presencia + valores efectivos del propio llamante. Ejecutar: 7.1 pasa.
- [ ] 7.3 **TRIANGULATE** — (a) JWT sin `app_metadata` → las tres presencias en `false` y los valores efectivos de fallback; (b) sin token → 401; (c) test explícito que afirma que la respuesta **no** contiene el token ni el payload crudo ni el identificador de ningún otro usuario.
- [ ] 7.4 **RED** — Test en `test_products.py`: un JWT con `plan="gratis"` sobre una cuenta que ya alcanzó el límite del plan gratis recibe 403 al crear un producto. Debe fallar hoy (el default `"pro"` concede 999.999).
- [ ] 7.5 **GREEN/TRIANGULATE** — Confirmar que el enforcement queda correcto con el claim presente, y agregar el caso complementario: los productos **existentes** por encima del límite siguen siendo legibles y editables (sólo se impide crear).
- [ ] 7.6 **REFACTOR** — Documentar en `backend/core/auth.py`, junto al default `"pro"`, que es un valor de **transición** ligado a la ventana de convivencia de tokens, con referencia a la capability `plan-gating`.

## 8. Activación en producción — **MANUAL PO** (D7, gate OQ-1)

- [ ] 8.1 **Gate OQ-1** — Ejecutar la query de reconciliación de plan (cuentas cuyo consumo actual excede el límite de su plan real, con nombre de cuenta, plan y conteo) y entregarla al PO. **Bloquea 8.3.** Registrar la decisión del PO: (a) enforcar, (b) grandfatherear, (c) diferir el claim `plan` (salida documentada en 3.4).
- [ ] 8.2 Verificación previa a la activación (agente, read-only): invocar el hook en prod vía MCP con un `user_id` real y confirmar que devuelve los tres claims con los valores correctos. **La función ya está desplegada y dormida** — esto no cambia nada en producción.
- [ ] 8.3 **MANUAL PO — activar el hook.** Instrucciones exactas: Supabase Dashboard → proyecto `gxdhpxvdjjkmxhdkkwyb` → **Authentication** → **Hooks (Beta)** → **Customize Access Token** → habilitar y seleccionar la función Postgres `public.custom_access_token_hook` → **Save**. Confirmar que la pantalla la muestra como habilitada. *(Alternativa a criterio del PO: `PATCH /v1/projects/{ref}/config/auth` de la Management API — requiere un Personal Access Token propio del PO; verificar los nombres exactos de los campos del toggle contra la referencia viva de la API antes de enviarla. El agente no maneja ese token.)*
- [ ] 8.4 **MANUAL PO — verificar el claim en un usuario real.** Cerrar sesión y volver a entrar en la app; consultar `GET /auth/claims-status` desde esa sesión y confirmar las tres presencias en `true` con el rol y el plan correctos. **NO** verificar con `auth.users.raw_app_meta_data`: el hook no escribe esa columna y la query seguiría dando 0 con el hook perfectamente activo (D8).
- [ ] 8.5 **Prueba de aceptación (a)** — Con una cuenta real, crear un centro de costo. `cost_centers` pasa de 0 a 1 fila en prod. Registrar el resultado.
- [ ] 8.6 **Observación 24-48 h** — Revisar logs del backend (Render) buscando 403 nuevos en endpoints que antes funcionaban, y logs de Postgres buscando el `RAISE WARNING` del hook. Ambos deben estar en cero. Si aparecen 403 masivos → desactivar el toggle (rollback inmediato, sin migración) y reportar.

## 9. Cierre

- [ ] 9.1 Ejecutar la suite backend completa dos veces seguidas (descarta flake) y confirmar el conteo de tests nuevos respecto del baseline de 1.1.
- [ ] 9.2 Verificar que el frontend no requirió cambios (barrido de `app_metadata` en `frontend/`, esperado: 0 resultados) y dejarlo registrado.
- [ ] 9.3 Correr los advisors de Supabase y confirmar que `function_search_path_mutable` ya no reporta `custom_access_token_hook`, y que las policies nuevas de `supabase_auth_admin` no abren ningún hallazgo.
- [ ] 9.4 Abrir el PR con la tabla de evidencia del ciclo TDD (tarea / archivo de test / safety net / RED / GREEN / TRIANGULATE / REFACTOR), los números de prod de 1.3 y la decisión del PO sobre OQ-1.
- [ ] 9.5 Actualizar la ficha de `v3-rbac-multirole` en `CHANGES.md`: marcar la dependencia dura `v31-authz-token-hook` como satisfecha y anotar el contrato de evolución `account_role` → `account_roles` (D2) para que el pivot no lo re-litigue.
- [ ] 9.6 Registrar las Open Questions vivas (OQ-2 comunicación, OQ-3 selector de cuenta activa) donde el PO las vea, sin resolverlas en este change.
