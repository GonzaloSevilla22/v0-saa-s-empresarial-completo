> **Governance CRÍTICO** (autorización y aislamiento entre cuentas). **Nada se aplica sin la firma del PO** sobre OQ-1 a OQ-9 (`design.md` §Open Questions).
>
> **Tres tandas, tres PRs, en orden**:
> - **A**: cuenta activa única. No toca ninguna RPC de operaciones y puede ir primera.
> - **B**: guards de operaciones. Va después de los changes hermanos que correspondan, según D11.
> - **C**: invitación de punta a punta. Necesita la B en producción.
>
> **TDD estricto**: cada grupo de producción abre con su RED (un gate o un test que falla por la razón correcta) y deja evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR, nunca a `main`. Conventional commits.
> - Toda RPC se reescribe desde su `pg_get_functiondef` **vivo de producción**, con *preflight* de `md5` sin `\r`. Se conservan el `COMMENT` y las ACLs, que se re-emiten. Para cambiar una firma: `DROP` + `CREATE`, nunca `CREATE OR REPLACE` con un `DEFAULT` nuevo (`42725`).
> - Nada contra producción salvo lectura (MCP `execute_sql` de sólo lectura) o lo que autoriza el PO. Nunca el MCP `apply_migration`.
> - La base local es compartida con otros agentes: los applies y los gates corren **en serie**.
> - Usuarios de prueba sólo en la base local (`@test.local`).

## 0. Sign-off y checkpoints previos (sólo lectura)

- [x] 0.1 **[PO]** Firma de OQ-1 a OQ-9. Registrar la respuesta textual en una sección "Sign-off del PO" de `design.md`.
  - **Hecho (2026-10-16)**: el PO dijo «dale, aplicá multiusuario-operativo»; se firman OQ-1 a OQ-9 por su opción recomendada. Registrado en `design.md` §"Sign-off del PO".
  - Sin respuesta explícita, **no** se aplica nada: es governance CRÍTICO.
  - Si alguna OQ se resuelve distinto de la recomendación, ajustar en el mismo PR los deltas de `active-account` (OQ-1), `operation-member-authorization` (OQ-3, OQ-4) y `account-invitation-flow` (OQ-2, OQ-5, OQ-6, OQ-8).
- [x] 0.2 Re-medir en producción (sólo lectura) lo que afirma `design.md` §Context:
  - cuentas con más de un miembro y usuarios en más de una cuenta (hoy 0 y 0);
  - invitaciones (hoy 0);
  - filas con un autor que no es miembro de su cuenta (hoy 0, salvo los 10 *insights* legacy con `account_id NULL`);
  - `MAX(version)`.

  Si ya hay cuentas con más de un miembro, avisar al PO **antes** de seguir: cambia la exposición y puede exigir una auditoría de daño.
  - **Medido el 2026-10-16** (producción, sólo lectura): 41 cuentas, 41 miembros, **0** cuentas con más de un miembro, **0** usuarios con más de una membresía, 0 invitaciones, 0 emails `org_invite`, 0 filas con autor que no es miembro en `products`/`sales`/`purchases`/`expenses`, `MAX(version) = 20261081000001` (328 migraciones). Igual que el 2026-10-14: no hay nada que avisar.
- [x] 0.3 Re-confirmar el inventario contra la base viva: los 45 sitios del patrón A, los 5 del patrón B, los 4 agregados del patrón C, las 6 funciones del patrón E y las 8 del patrón F (consultas en `design.md` §Context). Si un change mergeado en el medio sumó un sitio nuevo, agregarlo al alcance de la tanda que corresponda.
  - **Re-confirmado contra prod (2026-10-16)**: patrón A **45** (regex estricta `current_account_ids() AS x LIMIT 1`); patrón B **5** sitios (`custom_access_token_hook`, `rpc_my_active_account_roles`, `rpc_my_effective_plan`, `rpc_atomic_log_ai_insight`, `set_insight_account_id`) más `rpc_accept_invitation`, que sólo lee la membresía para otro fin y queda en la allow-list de membresía; patrón C: `get_dashboard_financials`, `get_dashboard_critical_stock`, `get_dashboard_critical_stock_items` (`IN (SELECT current_account_ids())`), `rpc_period_comparison` (`ARRAY(SELECT …)`) y `rpc_import_products` (`cuenta_ambigua`). Patrón E: **la lista cambió**: ahora también `_purchase_operation_core` (la extracción de `remitos-compra` tanda B, mergeada en #647) lleva `user_id <> v_uid`, y `rpc_create_purchase_operation` ya es un wrapper que delega en él. **Es alcance de la tanda B (D11), no de la A.** Patrón F: las 8 funciones siguen sin `is_account_writer`. Policies: 90 sobre 62 tablas con la regex `current_account_ids` en `pg_policies.qual/with_check` (el diseño decía 98/64; la diferencia es de cómo se cuenta —el diseño incluía las que la usan a través de otra función—, no hay un sitio nuevo).
- [x] 0.4 **Coordinación (D11)**: anotar acá el estado de cada hermano en `main` y en prod:
  - `fix/stock-edicion-sucursal-y-piso`;
  - `remitos-compra` tanda B: ¿existe `public._purchase_operation_core`?
  - `edicion-operaciones-con-dinero`.

  Recalcular el orden de la tanda B con esos datos y con la respuesta de OQ-9.
  - **Estado al 2026-10-16**: `fix/stock-edicion-sucursal-y-piso` = PR #646, **abierto, rojo y en conflicto** (migración `20261080000001`, reescribe `rpc_atomic_update_sale_operation` y `_purchase_operation`); `remitos-compra` tanda B **ya está en `main` y en prod** (#647, migración `20261081000001`): **`public._purchase_operation_core` existe** y es donde va el guard de producto de la compra en la tanda B; `edicion-operaciones-con-dinero` = PR #644, **sólo propose** (sin código). OQ-9 (a): multiusuario B antes que el hermano. Otros PRs con migración: #645 (`20261079000001`, importador de productos). **La tanda A no toca ninguna RPC de operaciones**, así que no se pisa con ninguno; el número de migración libre es `20261082000001`.

## 1. Tanda A — RED: gate de cuenta activa

- [x] 1.1 Crear `supabase/tests/test_multiusuario_cuenta_activa.sql`, molde de `test_tenancy_guard_caja_outbox.sql`: fixtures propios, cleanup con `session_replication_role = replica` y asserts con `RAISE EXCEPTION`. Usuarios: U1 de una sola cuenta; U2 miembro de su cuenta personal P (la más antigua) y de la cuenta A.
  - **Hecho (2026-10-16)**: `supabase/tests/test_multiusuario_cuenta_activa.sql` (fixtures O, U1, U2, Z; cada bloque en su sub-bloque con `EXCEPTION`, así el RED muestra de una vez qué falla).
- [x] 1.2 Bloques de comportamiento, ejecutando como `authenticated` con `request.jwt.claims` armado a mano:
  - (a) U1, con claim y sin claim, ve exactamente su cuenta (no regresión);
  - (b) U2 sin preferencia ve sólo P; con la preferencia en A, ve sólo A;
  - (c) `rpc_set_active_account(A)` funciona, y con una cuenta ajena da `P0404`, indistinguible;
  - (d) un claim `app_metadata.account_id = P` gana sobre la preferencia A;
  - (e) un claim de una cuenta de la que U2 fue quitado devuelve 0 filas;
  - (f) el hook (`custom_access_token_hook(event)`) emite `account_id`, `account_roles` y `plan` de la cuenta activa;
  - (g) RLS con `SET LOCAL ROLE authenticated`: `SELECT` de `sales` devuelve sólo las de la cuenta activa;
  - (h) `get_dashboard_financials` y `rpc_period_comparison` no suman la otra cuenta;
  - (i) R3j y R3l: con A activa, `rpc_quick_sale` y la venta de servicio quedan en A;
  - (j) un gasto de U2 queda en la cuenta activa;
  - (k) `rpc_import_products` en dry run no responde `cuenta_ambigua`;
  - (l) `rpc_my_active_account_roles()` devuelve los roles de U2 en la cuenta activa.
  - **Hecho**: bloques (a)-(p) como los de esta lista + (q), agregado en el apply: desempate determinista de dos membresías con el mismo `created_at`.
- [x] 1.3 Bloques estructurales:
  - `resolve_active_account` sin `EXECUTE` para `anon` ni `authenticated`, y con `EXECUTE` para `supabase_auth_admin`;
  - `profiles.active_account_id` fuera de los privilegios de columna de `authenticated` (ampliar `test_accounts_privilege_columns.sql`);
  - **barrido por convención** (D15): ninguna función de `public` fuera de la allow-list contiene `account_members … user_id = … LIMIT 1` sin `account_id = <parámetro>`.
  - **Hecho**: (s1) ACL de `resolve_active_account`, (s2) ACL y una definición viva por función, (s3) `profiles.active_account_id` fuera de los privilegios de columna (con la ampliación de `test_accounts_privilege_columns.sql`), (s4) el barrido por convención.
- [x] 1.4 Correr el gate contra la base local **antes** de la migración: tiene que fallar en (b), (d), (e), (f), (g), (h), (i), (k) y en el estructural, por la razón esperada. Guardar la salida en `evidence/tanda-a/red.log`.
  - **Hecho**: `evidence/tanda-a/red.log` — 18 bloques fallan antes de la migración por la razón esperada (R3j `P0409 ... disponible 0.0000`, claims ignorados, columna inexistente, funciones con criterio propio). El bloque (q), agregado después, tuvo su propio RED visto contra la migración sin el desempate (falla sólo (q)).

## 2. Tanda A — GREEN: migración de cuenta activa

- [x] 2.1 Elegir el número: `ls supabase/migrations`, PRs abiertos con migraciones y `MAX(version)` de prod. Tomar el siguiente libre y anotarlo acá.
  - **Hecho**: `20261082000001_multiusuario_cuenta_activa.sql` (`MAX(version)` de prod = `20261081000001`; los PRs abiertos con migración, #645 y #646, usan `20261079000001` y `20261080000001`).
- [x] 2.2 *Preflight* de `md5` sin `\r` contra prod de `current_account_ids`, `custom_access_token_hook`, `rpc_my_active_account_roles`, `rpc_my_effective_plan`, `rpc_atomic_log_ai_insight` y `set_insight_account_id`. Guardar los cuerpos vivos en `evidence/tanda-a/` para el rollback.
  - **Hecho**: *preflight* de `md5` de `prosrc` (sin `\r`) de las seis funciones, igual en prod y en la base local; los cuerpos vivos están en `evidence/tanda-a/cuerpos-previos/` (el rollback).
- [x] 2.3 Escribir la migración:
  - columna `profiles.active_account_id`;
  - `resolve_active_account(uuid)` (`DEFINER`, `STABLE`, `EXECUTE` sólo para `supabase_auth_admin`);
  - redefinir `current_account_ids()` (D1, D3), con un `COMMENT` que diga "cuenta activa, 0 o 1 fila";
  - `rpc_set_active_account(uuid)`;
  - `rpc_my_accounts()`, que devuelve los campos crudos del nombre (D5);
  - las cinco reescrituras del patrón B (D4).

  `REVOKE`/`GRANT` explícitos al final, porque `DROP` + `CREATE` resetea las ACLs. Re-`REVOKE` de `anon`.
  - **Hecho**, con una precisión: además de las cinco reescrituras del patrón B, `custom_access_token_hook` conserva su `EXCEPTION WHEN OTHERS` (claims intactos + `WARNING`) y el `COMMENT` y las ACLs de cada función se re-emiten. El resolver desempata, a igual `created_at`, a favor de la cuenta propia.
- [x] 2.4 Correr el gate (verde) y la cadena completa de gates de `KPI_Validation.yml` en su orden, sobre un `db reset` limpio. Atención a `test_custom_access_token_hook_account_roles.sql`: se ajusta **a propósito** para el claim `account_id`. Documentar cada ajuste.
  - **Hecho**: `evidence/tanda-a/green.log` (EXIT=0) y la cadena completa de `KPI_Validation.yml` en su orden sobre un `db reset` limpio — 117 pasos (004-120): 117/117 en verde. La corrida completa dio 3 con rc != 0 y se re-corrieron en verde: 100 (el gate de balanza tenía un vendedor de dos membresías sin declarar la cuenta; se corrigió el gate) y 108 y 111 (carreras de presupuestos y remitos de venta: el arnés local no reenviaba `PGAPPNAME` al contenedor y el gate no encontraba su sesión; con el shim corregido pasan). Resumen en `evidence/tanda-a/chain-kpi.txt`. Ajustes deliberados a gates existentes (cada uno documentado en `CHANGES.md`): hook (bloque 7), privilegios, `test_kpis_edge_cases.sql` (4.5a/4.5a-bis y la fecha de la membresía), `test_product_import_batch.sql` (13), `test_documentos_marca_empresa.sql`, `test_presupuestos_modulo.sql` y `test_punto_venta_predeterminado.sql` (i).
- [x] 2.5 `EXPLAIN (ANALYZE)` de una consulta de `/ventas` y del Tablero, antes y después, en la base local. Anotar el costo en `evidence/tanda-a/explain.md`.
  - **Hecho**: `evidence/tanda-a/explain.md` — con claim (el camino de producción) `current_account_ids()` pasa de 0,13 a 0,07 ms y las consultas de negocio quedan en el ruido; los planes son idénticos (una evaluación por sentencia).
- [x] 2.6 Agregar la reaplicación de la migración al final de la cadena de `KPI_Validation.yml`.
  - **Hecho**: bloque de reaplicación `MCA_*` al final de la cadena de reaplicación y paso nuevo "Run multiusuario cuenta activa gate" (YAML validado).

## 3. Tanda A — backend

- [x] 3.1 RED en `backend/tests/test_database.py`: `get_db_conn` empuja `app_metadata.account_id` cuando el contexto lo trae, y no lo inventa cuando falta.
  - **Hecho**: `test_database.py` (RED visto: 2 casos).
- [x] 3.2 RED en `test_deps.py`: `get_account_id` lee `current_account_ids()`. Un `X-Account-Id` distinto da `409` con `type` `account_switched`; sin header, no compara; sin cuenta, `403` "No active account found".
  - **Hecho**: `test_deps.py` reescrito (RED visto: 6 casos).
- [x] 3.3 RED en `test_guards.py`: `require_account_role` ignora los claims de rol cuando el contexto no trae `account_id` y consulta la base. Con `account_id`, usa el claim. La excepción de `CAN_CONFIGURE` no cambia.
  - **Hecho**: `test_guards.py` (RED visto: 3 casos).
- [x] 3.4 GREEN:
  - `core/auth.py`: `AuthContext.account_id`, leído de `app_metadata.account_id`;
  - `core/database.py`: los claims empujados;
  - `core/deps.py`;
  - `core/guards.py`;
  - `core/cors.py`: `X-Account-Id` permitido;
  - `core/errors.py`: el problema `account_switched`.
  - **Hecho**. `core/cors.py` **sin cambio funcional**: `allow_headers=["*"]` ya devuelve en el preflight lo que el navegador pide; el candado nuevo vive en `test_cors_allowlist.py`. `schemas/auth.py` y `claims-status` suman `account_id_claim_present`.
- [x] 3.5 Revisar `services/product_categories.py`: la divergencia documentada en `set_default_category` queda cerrada por construcción. Actualizar el docstring y su test.
  - **Hecho**: el docstring de `set_default_category` y su test.
- [x] 3.6 Suite completa de backend y coverage ≥ el umbral de CI.
  - **Hecho**: pytest como en CI, 4230 passed y 7 failed (`test_invoice_pdf.py`, preexistentes en el entorno local), cobertura 95,38 % (umbral 87 %); integración contra la base local 119 passed. Detalle en `evidence/tanda-a/suites.txt`.

## 4. Tanda A — Edge Functions

- [x] 4.1 RED: `resolveActiveAccountId` (`_shared/reporting-canon.ts`) invoca la RPC canónica y no ordena `account_members`.
  - **Hecho**: el espejo de la copia (`__tests__/reporting/edge-product-ranking.test.ts`) y `product-ranking.test.ts` (RED visto).
- [x] 4.2 GREEN: migrar `_shared/reporting-canon.ts`. `ai-estadisticas` deja su copia en línea y usa la compartida. Grep de todo `supabase/functions/` por `account_members` para confirmar que no queda otra resolución.
  - **Hecho**: `_shared/reporting-canon.ts` es la única copia; `ai-estadisticas`, `ai-insights`, `ai-precio` y `generate-export` la usan; grep de `supabase/functions/` sin otra resolución por `account_members`.
- [x] 4.3 `deno check` fuera del monorepo (`DENO_NO_PACKAGE_JSON=1`) y los tests de las funciones tocadas.
  - **Hecho**: `evidence/tanda-a/deno-check.log` (EXIT=0).

## 5. Tanda A — frontend

- [x] 5.1 RED (vitest):
  - `auth-context` toma la cuenta activa de `rpc_my_accounts()`;
  - `auth-headers.ts` agrega `X-Account-Id`;
  - el cliente de FastAPI intercepta el `409 account_switched`: renueva el token, limpia la caché y navega;
  - `session-bus` emite y adopta `account:switched` sin token en el mensaje (candado existente: no nace un segundo `BroadcastChannel`).
  - **Hecho** (RED visto en 10 archivos, `evidence/tanda-a/red-frontend.log`): `auth-context-active-account.test.tsx`, `auth-headers`, `python-client`, `session-bus`, `active-account-store`, `accounts`.
- [x] 5.2 RED: `AccountSwitcher` no se muestra con una cuenta; con dos, lista ambas con el nombre de `previewIssuer` y el rol; al elegir, llama `rpc_set_active_account`, `refreshSession()`, `queryClient.clear()` y navega al Tablero.
  - **Hecho**: `AccountSwitcher.test.tsx` (incluye: con una sola cuenta no pide el catálogo de roles).
- [x] 5.3 GREEN:
  - `contexts/auth-context.tsx`;
  - `lib/api/auth-headers.ts` y `lib/api/python-client.ts`;
  - `lib/auth/session-bus.ts`;
  - `components/accounts/AccountSwitcher.tsx`, nuevo, en PascalCase, con tokens semánticos y componentes base;
  - montaje en el `SidebarHeader` de `components/app-sidebar.tsx`.

  Sin `any`.
  - **Hecho**. Desvío declarado: `X-Account-Id` se compone en `getBackendHeaders` y no en `getAuthHeaders` (ésta también sirve a las Edge Functions, cuyo CORS no admite la cabecera). **Y un hallazgo del humo**: releer el token no cambia la cuenta (el token handler sólo renueva un token por vencer y el hook emite el claim al emitir); se agregó `refreshSessionAction` (acción de servidor) y `switchAccount` la llama entre persistir y releer.
- [x] 5.4 Manejo de "sin cuenta activa" (`403 No active account found`): renovar el token una vez y recargar. Si persiste, pantalla de error con "Cerrar sesión".
  - **Hecho**: `auth-context` + `active-account-store` (tope de 15 s para el 403 repetido) + pantalla de error con "Cerrar sesión".
- [x] 5.5 `tsc` sin errores nuevos y suite de vitest completa.
  - **Hecho**: `tsc` con los mismos 8 errores de 5 archivos de test ajenos (`evidence/tanda-a/tsc.log`); vitest completo, 564 archivos y 6724 tests, 0 fallos (`evidence/tanda-a/suites.txt`).

## 6. Tanda A — verificación y PR

- [x] 6.1 Verificación visual del selector: escritorio y móvil (drawer), tema claro y oscuro, con una y con dos cuentas. Targets de 44 px en móvil. Capturas en `evidence/tanda-a/`.
  - **Hecho**: 12 capturas en `evidence/tanda-a/visual-*.png` y `visual.log` (escritorio y drawer móvil, claro y oscuro, una y dos cuentas; el selector mide 44 px de alto y los ítems de la lista 48 px).
- [x] 6.2 Humo en el stack local con un build de producción:
  - usuario de una cuenta: todo igual;
  - usuario de dos cuentas: el selector cambia de cuenta, el Tablero y `/ventas` muestran la cuenta elegida, y una venta de servicio queda en ella;
  - dos pestañas: cambiar en una resincroniza la otra;
  - un gasto desde la pestaña vieja recibe el `409`.
  - **Hecho** con el build de producción y el backend real: `evidence/tanda-a/humo.log` (15/15 PASS). La primera corrida **falló** y destapó el defecto de la renovación del token (ver 5.3); se corrigió y se re-corrió completa.
- [ ] 6.3 PR de la tanda A (cuerpo que termina en la línea de Claude Code) y CI en verde.
  - **PR abierto: (pendiente de crear)**. La CI y el merge quedan a cargo del orquestador.
- [ ] 6.4 **Post-merge** (sólo lectura):
  - `MAX(version)`;
  - ACLs de las funciones nuevas;
  - `current_account_ids()` devuelve una fila para un usuario real (por `sub` en una transacción de lectura);
  - `auth_logs` sin `custom_access_token_hook degradado` en la hora siguiente al deploy;
  - el deploy de Render existe (`GET /deploys`).

## 7. Tanda B — checkpoints

- [ ] 7.1 Re-ejecutar 0.4 y confirmar el orden. Si `_purchase_operation_core` existe, el guard de producto de la compra va en el núcleo (D11).
- [ ] 7.2 *Preflight* de `md5` contra prod de las ocho funciones del patrón F (y del núcleo de compra, si existe). Guardar los cuerpos vivos en `evidence/tanda-b/`.
- [ ] 7.3 Listar con `grep` los gates que introspectan o ejecutan esas funciones (`supabase/tests/`, `KPI_Validation.yml`) y anotarlos acá: son los que se re-corren en 9.3.

## 8. Tanda B — RED: gate de operaciones

- [ ] 8.1 Crear `supabase/tests/test_multiusuario_operaciones.sql`. Una cuenta A con owner, admin, seller, cashier, stock, purchases y viewer; una cuenta B con un producto y una venta; un usuario de dos cuentas.
- [ ] 8.2 Bloques de la matriz de D9:
  - **alta de venta** por formulario: owner, admin, seller y cashier lo logran; stock da `P0403`; viewer da `P0401`;
  - **alta de compra**: owner, admin y purchases lo logran; seller, cashier y stock dan `P0403`; viewer da `P0401`;
  - **edición y borrado de venta y de compra**: owner y admin sobre lo ajeno, sí; seller sobre lo propio, sí; seller sobre lo del owner, `P0403`; viewer, `P0401`.
- [ ] 8.3 Controles negativos de tenencia:
  - un producto de B vendido o comprado desde A da `P0404`, con el **mismo texto** que un id inexistente;
  - una venta de B editada o borrada desde A da `P0404`;
  - el usuario de dos cuentas, con un producto de la cuenta no activa, da `P0404`;
  - en ningún caso hay filas nuevas ni movimiento de stock.
- [ ] 8.4 Correr el gate contra la base local **antes** de la migración: falla en R3a, R3b, R3d, R3f y R3g, y en el viewer sin rechazo (patrón F). Guardar en `evidence/tanda-b/red.log`.

## 9. Tanda B — GREEN: migración de guards

- [ ] 9.1 Número de migración (como 2.1).
- [ ] 9.2 Escribir la migración:
  - `_account_assert_capability(uuid, text[], text)`: `INVOKER`, `STABLE`, sin `EXECUTE` para los roles de aplicación;
  - las ocho funciones desde el vivo (D8, D9): filtro de cuenta en el `SELECT … FOR UPDATE` del producto; documento por cuenta; el guard de rol al principio, antes de cualquier escritura; la regla de autor en edición y borrado;
  - se elimina todo `v_product.user_id <> v_uid` y todo `user_id != v_uid` de documento; `user_id` se sigue escribiendo como autoría.
- [ ] 9.3 Gate de la tanda B en verde, más la lista de 7.3 y la cadena completa de `KPI_Validation.yml` sobre un `db reset` limpio.
- [ ] 9.4 Mutantes: quitar el filtro de cuenta del `SELECT` del producto, y quitar el guard de rol del borrado. El gate tiene que fallar en los dos. Restaurar y dejarlo anotado.
- [ ] 9.5 Reaplicación en `KPI_Validation.yml`, al final de la cadena.

## 10. Tanda B — backend y frontend

- [ ] 10.1 RED (pytest): los services de ventas y compras llaman `require_account_role` con `CAN_SELL` / `CAN_PURCHASE` en alta, edición y borrado. Test espejo: lee la migración de la tanda B y `backend/core/rbac.py`, y falla si los conjuntos divergen.
- [ ] 10.2 GREEN: `backend/services/sales.py` y `backend/services/purchases.py`.
- [ ] 10.3 RED (vitest):
  - `lib/rbac-capabilities.ts` suma `CAN_PURCHASE`, con su test espejo contra `rbac.py`;
  - `/ventas` y `/compras` ocultan "Nueva", "Editar" y "Eliminar" sin la capacidad;
  - "Editar" y "Eliminar" sobre un documento ajeno, sin owner ni admin, también se ocultan.
- [ ] 10.4 GREEN en las pantallas y componentes de listado y fila de ventas y compras (con `hasCapability` y `useOrgRole`). Los errores `P0401`/`P0403` se humanizan con `operation-errors.ts`.
- [ ] 10.5 Verificación visual con un usuario viewer y con uno seller: escritorio y móvil, tema claro y oscuro.

## 11. Tanda B — humo y PR

- [ ] 11.1 Humo local: re-correr `smoke_stock.sql` S20, que debe quedar todo en OK salvo R3h y R3i, esperados, más el gate de la tanda B, como `authenticated`.
- [ ] 11.2 PR de la tanda B y CI en verde.
- [ ] 11.3 **Post-merge** (sólo lectura): `MAX(version)`, una sola definición viva de cada una de las ocho funciones sin overload nuevo, ACLs, el `md5` de cada cuerpo igual al de la migración, y el deploy de Render.

## 12. Hallazgo `email_logs` (OQ-7)

- [ ] 12.1 Según OQ-7:
  - **(a)**: abrir el hotfix aparte, con su propio PR, y esperar a que esté en prod antes de la tanda C;
  - **(b)**: sumar a la tanda C la migración del caller de `frontend/app/api/billing/cancel/route.ts` al servidor, el `DROP POLICY email_logs_backend_insert`, el `REVOKE INSERT` a `authenticated`, el escape en todas las plantillas de `send-email` y su gate;
  - **(c)**: registrar el candidato en `CHANGES.md`.

## 13. Tanda C — RED: gate de invitaciones

- [ ] 13.1 Crear `supabase/tests/test_multiusuario_invitaciones.sql`, con los bloques de D15:
  - el envío encola un `org_invite` con el `recipient` de la fila y el token de la fila, y un seller recibe `P0403`;
  - el reenvío rota el token, el viejo falla y el vencimiento se renueva;
  - revocar hace fallar la aceptación con el error genérico;
  - `rpc_invitation_preview` con otra identidad devuelve el mismo error que un token inexistente;
  - la aceptación fija `profiles.active_account_id`;
  - se cumplen el enfriamiento y el tope diario (`P0439`);
  - `rpc_invite_member(text, uuid)` ya no existe;
  - "Not authenticated" da `P0401`.
- [ ] 13.2 Ajustar a propósito `test_accept_invitation_binding.sql` (la cuenta activa tras aceptar) y `test_invite_member_roles_and_plan_gate.sql` (el overload retirado). Documentar cada ajuste.
- [ ] 13.3 Correr el gate **antes** de la migración: falla por la razón esperada. `evidence/tanda-c/red.log`.

## 14. Tanda C — GREEN: migración de invitaciones

- [ ] 14.1 Número de migración (como 2.1).
- [ ] 14.2 Migrar los callers del overload de 2 argumentos **antes** del `DROP` (grep de `frontend/`, `backend/` y `supabase/functions/`, más `pg_proc.prosrc` de prod).
- [ ] 14.3 Escribir la migración:
  - columna `account_invitations.account_display_name` y valor `revoked` en el `CHECK` de estado;
  - funciones nuevas: `rpc_send_invitation_email`, `rpc_list_account_invitations`, `rpc_revoke_invitation` y `rpc_invitation_preview`;
  - reescritura desde el vivo de `rpc_accept_invitation` (activa la cuenta) y de `rpc_invite_member` (3 argumentos);
  - `P0001` → `P0401`;
  - `DROP FUNCTION rpc_invite_member(text, uuid)`.

  ACLs explícitas.
- [ ] 14.4 Gate en verde, más la cadena completa de `KPI_Validation.yml`, más la reaplicación al final.

## 15. Tanda C — backend

- [ ] 15.1 RED (pytest), para los endpoints de D10:
  - crear (llama a la invitación y al envío en la misma transacción, con el nombre de `resolve_commercial_issuer`);
  - listar (sin token);
  - reenviar y revocar (`CAN_CONFIGURE`);
  - vista previa y aceptación (`P0404` → 404, `P0409` → 409, `P0402` → 403, `P0439` → 429).
- [ ] 15.2 GREEN: router, service, repository y schemas Pydantic v2 (tres capas). Agregar `P0439` a `core/errors.py`.
- [ ] 15.3 Suite completa y coverage.

## 16. Tanda C — email

- [ ] 16.1 RED (Deno):
  - `_shared/html-escape.ts` escapa `& < > " '`;
  - la plantilla `org_invite` escapa el nombre del negocio y el del invitador;
  - el CTA es `APP_URL + /invitacion/ + encodeURIComponent(token)`;
  - una URL en la metadata no aparece en el HTML.
- [ ] 16.2 GREEN en `supabase/functions/send-email/index.ts` y `_shared/html-escape.ts`. `deno check` fuera del monorepo.
- [ ] 16.3 El redeploy de la Edge Function lo hace el pipeline de `deploy.yml`. Confirmarlo en el post-merge.

## 17. Tanda C — frontend

- [ ] 17.1 RED (vitest):
  - `/invitacion/[token]`, sin sesión: tarjeta genérica, sin datos del negocio, con "Ingresar" y "Crear cuenta" que vuelven a la invitación;
  - con la identidad correcta: vista previa y "Aceptar";
  - con otra identidad o un token inválido: el mensaje único;
  - si ya es miembro: "Ya sos parte de {negocio}" con "Cambiar a esa cuenta";
  - tras aceptar: `refreshSession()`, `account:switched` y el Tablero con un toast.
- [ ] 17.2 GREEN:
  - `app/invitacion/[token]/page.tsx`;
  - prefijo `/invitacion/` en `PUBLIC_PREFIXES` (`lib/auth/route-access.ts`);
  - `Referrer-Policy: no-referrer` y `noindex` para esa ruta (`lib/supabase/middleware.ts`, metadata de la página);
  - el registro acepta `next` **sólo** con el prefijo `/invitacion/` (allow-list, con test del rechazo de cualquier otro destino).
- [ ] 17.3 RED/GREEN `/organizacion/invitar`:
  - crea por FastAPI y deja de llamar a `rpc_invite_member` por supabase-js;
  - lista las pendientes con "Reenviar" y "Revocar" (con confirmación);
  - "Copiar link" según OQ-6, con el link y no el token suelto;
  - la copia de éxito ya no dice "compartí el token", sino "le enviamos un email a …".
- [ ] 17.4 RED/GREEN `components/settings/TeamSection.tsx`: la invitación rápida pasa al conjunto de roles y a FastAPI.
- [ ] 17.5 `tsc` sin errores nuevos y suite de vitest completa.

## 18. Tanda C — verificación, humo y demo

- [ ] 18.1 Verificación visual de `/invitacion/[token]` (los cuatro estados) y de `/organizacion/invitar` (con y sin pendientes): escritorio y móvil, tema claro y oscuro. Contraste AA (gate `token-contrast-aa`). Capturas en `evidence/tanda-c/`.
- [ ] 18.2 Humo local de punta a punta con Inbucket:
  1. el owner invita a un email nuevo como seller;
  2. llega el email, con el nombre escapado y el link correcto;
  3. el invitado se registra desde el link, verifica, vuelve a la invitación y acepta;
  4. aterriza en el Tablero del negocio, el selector muestra dos cuentas, y vende por formulario un producto del owner;
  5. el owner edita esa venta;
  6. reenviar invalida el link viejo, y revocar impide aceptar.
- [ ] 18.3 PR de la tanda C y CI en verde.
- [ ] 18.4 **[PO]** Demo real en prod con un segundo usuario propio (su familiar), con los mismos pasos del humo. Si pasa, el PO decide cuándo activar `Enforce single session per user` en el Dashboard.

## 19. Specs, KB y documentación (en el PR de cada tanda)

- [x] 19.1 Validar los deltas: `npx openspec validate multiusuario-operativo --strict`. Si una OQ cambió el alcance, ajustar el delta en el mismo PR.
  - **Hecho**: `npx openspec validate multiusuario-operativo --strict` — válido.
- [ ] 19.2 KB (**tanda A hecha**: `03_actores_y_roles.md`, `04_modelo_de_datos.md` y `08_arquitectura_propuesta.md`; `05` y `10` van con las tandas B y C):
  - `knowledge-base/03_actores_y_roles.md` (cuenta activa, invitación);
  - `knowledge-base/05_reglas_de_negocio.md` (reglas nuevas de autorización de operaciones);
  - `knowledge-base/08_arquitectura_propuesta.md` (resolver único);
  - `knowledge-base/10_preguntas_abiertas.md` (cerrar lo que este change resuelve).
- [ ] 19.3 `CHANGES.md` (**ficha de la tanda A hecha**; el cierre de los candidatos absorbidos va con las tandas B y C): ficha del change con las mediciones. Cerrar los candidatos absorbidos (`invitacion-aceptar-ui`, `cuenta-activa-selector`, la invitación rápida de `TeamSection`, `membership-rpcs-not-authenticated-p0401` y la parte de `v4-producto-calidad-05`) y dar de alta los que deja (`design.md` §Candidatos).
- [ ] 19.4 (**a cargo del orquestador**: el apply de la tanda A no toca `CLAUDE.md`/`AGENTS.md`) `CLAUDE.md`: el puntero del roadmap y una regla dura nueva ("la cuenta activa se resuelve sólo con `current_account_ids()` / `resolve_active_account`; ningún componente ordena `account_members` por su cuenta"). Correr `python scripts/ci/check_docs_sync.py --fix` en el mismo PR.

## 20. Archive

- [ ] 20.1 Con las tres tandas en prod y la demo del PO aprobada: `/opsx:archive multiusuario-operativo`, verificando los requirements en `HEAD` después del archive (gotchas conocidas de `openspec archive`).

## Evidencia TDD

| Tarea | Archivo de test o gate | Capa | Safety net | RED | GREEN | Triangulación | Refactor |
|---|---|---|---|---|---|---|---|
| 1.x / 2.x | `supabase/tests/test_multiusuario_cuenta_activa.sql` | SQL | gates de `main` 004-094 sobre `db reset` limpio (`baseline-gates.txt`; 4 pasos con rc != 0 por el arnés local, no por `main`) | 18 bloques fallan (`red.log`); (q) con su RED aparte | EXIT=0 (`green.log`) | 17 bloques de comportamiento con dos usuarios de dos cuentas, uno de una, claim vs preferencia vs revocada, + (q) | comentarios del cuerpo y *md5* recalculado; desempate determinista |
| 3.x | `backend/tests/test_deps.py`, `test_guards.py`, `test_database.py`, `test_auth*.py` | Unit | 96 passed en los archivos tocados | 18 failed (`red-backend.log`) | 114 passed | header igual / distinto / malformado / ausente; con y sin `account_id` en el token | `make_token`/`_auth` declaran cuenta |
| 4.x | `__tests__/reporting/edge-product-ranking.test.ts`, `product-ranking.test.ts` (espejo de `_shared/reporting-canon.ts`) | Unit | 4 failed antes (RED en `red-frontend.log`) | RED visto | verde | resolver canónico vía RPC vs `account_members` | `deno check` limpio |
| 5.x | `__tests__/components/AccountSwitcher.test.tsx`, `auth-context`, `session-bus`, `auth-headers` | Unit | 12 failed / 55 passed en los 10 archivos tocados (`red-frontend.log`) | 10 archivos fallan | 564 archivos / 6724 tests verdes | selector con 0, 1, 2 cuentas; cambio, fallo del proveedor, orden de pasos; 409 y 403 | `AccountSwitcher` partido (el catálogo sólo con 2+ cuentas) |
| 8.x / 9.x | `supabase/tests/test_multiusuario_operaciones.sql` | SQL | | | | | |
| 10.x | `backend/tests/test_sales*.py`, `test_purchases*.py`, el espejo de capacidades, `rbac-capabilities.test.ts` | Unit | | | | | |
| 13.x / 14.x | `supabase/tests/test_multiusuario_invitaciones.sql` | SQL | | | | | |
| 15.x | `backend/tests/test_invitations.py` | Unit | | | | | |
| 16.x | tests de `send-email` y `_shared/html-escape.ts` | Unit (Deno) | | | | | |
| 17.x | `__tests__/app/invitacion.test.tsx`, `organizacion-invitar`, `TeamSection` | Unit | | | | | |
