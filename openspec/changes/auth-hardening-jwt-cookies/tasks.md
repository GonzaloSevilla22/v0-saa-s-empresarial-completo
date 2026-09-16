> **Tres applies independientes.** Los grupos 1-10 son la **Parte A** (un PR), 11-16 la **Parte B** (otro PR), 17-23 la **Parte C** (otro PR). Cada parte se mergea, se verifica en prod y recibe humo del PO antes de empezar la siguiente. El orden A → B → C es una restricción de riesgo, no una preferencia: D16 del design explica por qué el token handler no se mergea antes de que las rutas estén cubiertas. El grupo 24 es **operación del PO**, no código.
>
> **Governance CRÍTICO (auth).** El PO firmó el **enfoque** el 2026-09-16. Cada parte necesita su sign-off de merge y su verificación en prod antes de la siguiente.
>
> **TDD estricto en todo el change**: por cada task de implementación, el test que la describe se escribe y **se ve fallar** antes del código. Cada parte arranca con su red de seguridad (correr la suite existente y registrar el baseline); un fallo preexistente se **reporta**, no se arregla acá.
>
> **Regla de integridad de función**: toda función SQL reescrita parte de su cuerpo **vivo de prod** (`pg_get_functiondef`), nunca del último archivo de migración. *Gotcha registrado*: el `md5` local y el de prod difieren por los CRLF del checkout de Windows — comparar por líneas con `\r` removido, no por hash crudo.
>
> **Nunca commitear a `main`**: todo por PR, incluso los fixes triviales post-merge. **Nunca** `apply_migration` del MCP para migraciones de prod. El agente **no hace login en prod** (regla: el Browser pane sobre `/auth/login` de prod cuelga el cliente); los `Set-Cookie` de una sesión real los mide el PO.

## 1. Parte A — Checkpoint de estado real (antes de escribir una línea)

- [ ] 1.1 SAFETY NET: correr `pytest backend/tests/` completo y registrar el baseline exacto (pasados/fallados/skips + coverage). Un fallo preexistente se reporta como tal y **no** se arregla en esta parte
- [ ] 1.2 Prod (sólo lectura, MCP): confirmar `MAX(version)` y el conteo de migraciones; confirmar que **`20261051000001`** sigue libre (`ls supabase/migrations | tail`). El propose lo verificó el 2026-09-16 sobre `20261050000001` / 299 migraciones
- [ ] 1.3 Prod (sólo lectura): capturar el `pg_get_functiondef` **vivo** de `rpc_accept_invitation(text)` y diffear línea a línea (con `\r` removido) contra el cuerpo del último archivo de migración. El propose midió md5 `02517dd9bcbbabd723a5bbb0f1c1a406`, 4853 chars, `prosecdef=true`, **firma única**, `proacl={postgres,authenticated,service_role}` — si algo cambió, el design se corrige **antes** de escribir SQL
- [ ] 1.4 Prod (sólo lectura): reconfirmar `SELECT tablename FROM pg_publication_tables WHERE pubname='supabase_realtime'`. El propose midió **una sola fila: `notifications`**; si `fiscal_documents` ya apareciera, el `ALTER PUBLICATION` queda como no-op guardado y se documenta
- [ ] 1.5 Confirmar que `SUPABASE_URL` está puesta en Render **antes** de mergear esta parte (el fail-fast de 3.x depende de eso). Prod corre la rama JWKS (F4), así que debería estar; si no se puede confirmar, el merge espera a la task 24.3
- [ ] 1.6 `grep -rn "ws_manager\|routers.ws\|/ws/" backend/ frontend/ --include=*.py --include=*.ts --include=*.tsx` (sin `.venv`/`node_modules`) → inventario cerrado de lo que toca el retiro del grupo 5

## 2. Parte A — Verificación del JWT: emisor, audiencia, `exp`, `sub`, tolerancia de reloj (D8)

- [ ] 2.1 RED→GREEN: `backend/tests/test_auth_jwks.py::test_jwks_es256_token_is_accepted` — clave EC P-256 generada en el test, token firmado con ella, `PyJWKClient.get_signing_key_from_jwt` parcheado para devolverla. **Cierra el hueco de §10 de la auditoría**: hoy `grep -E "jwks|ES256|RS256|PyJWKClient" backend/tests/` da 0 hits y la única rama que corre en prod no tiene tests
- [ ] 2.2 RED→GREEN: `test_auth_jwks.py::test_token_from_other_issuer_is_rejected` — mismo token, `iss` ajeno → 401. GREEN: pasar `issuer=f"{settings.supabase_url}/auth/v1"` en `_decode_supabase_jwt` (`backend/core/auth.py:76-92`)
- [ ] 2.3 RED→GREEN: `test_auth_jwks.py::test_token_with_wrong_audience_is_rejected` + `::test_token_with_expected_audience_is_accepted` — GREEN: `audience="authenticated"` y `verify_aud` **encendido** en las dos ramas (hoy `options={"verify_aud": False}` en `auth.py:83` y `:91`)
- [ ] 2.4 RED→GREEN: `backend/tests/test_auth.py::test_token_without_exp_is_rejected` — hoy un token válidamente firmado **sin `exp`** se acepta. GREEN: `options={"require": ["exp", "sub"]}`
- [ ] 2.5 RED→GREEN: `backend/tests/test_auth.py::test_token_without_sub_returns_401_not_500` — hoy `payload["sub"]` (`auth.py:130`) da KeyError y sale como **500** por el catch-all (`backend/main.py:132-140`). GREEN: cubierto por el `require` de 2.4, con aserción explícita sobre el status
- [ ] 2.6 RED→GREEN: `test_auth.py::test_clock_skew_within_leeway_is_accepted` — token con `iat` levemente futuro. GREEN: `leeway=30` (hoy 0 con `verify_iat` activo)
- [ ] 2.7 RED→GREEN: `test_auth_jwks.py::test_jwks_fetch_failure_logs_warning_and_returns_401` con `caplog` — hoy `PyJWKClientError` hereda de `PyJWTError` y sale por el mismo `except` (`auth.py:93-94`), indistinguible de un token forjado y sin log propio. GREEN: `except PyJWKClientError` propio con `logger.warning`, antes del `except PyJWTError`
- [ ] 2.8 TRIANGULATE: `test_auth_jwks.py::test_forged_token_does_not_log_jwks_warning` — el control negativo de 2.7 (una firma inválida **no** debe emitir esa advertencia)
- [ ] 2.9 Verificar que `GET /auth/claims-status` sigue usando la **misma** `_decode_supabase_jwt` (`auth.py:153`, intención declarada en `:63-66`) y que no nació un segundo decoder

## 3. Parte A — Palanca HS256 explícita y fail-fast de arranque (D9)

- [ ] 3.1 RED→GREEN: `backend/tests/test_config_auth_failfast.py::test_startup_fails_without_supabase_url_and_without_flag` — GREEN: `auth_allow_hs256_fallback: bool = False` en `backend/core/config.py` y `@model_validator` que rechaza `supabase_url` ausente o no-`https` cuando la palanca está apagada
- [ ] 3.2 RED→GREEN: `::test_startup_error_names_the_missing_variable` — el mensaje debe nombrar la variable, no decir "configuración inválida"
- [ ] 3.3 RED→GREEN: `::test_hs256_branch_requires_explicit_flag` — con la palanca apagada y `supabase_url=""`, la rama HS256 **no** se ejecuta. GREEN: condicionar el `else` de `auth.py:85-92` a la palanca (hoy la elección es por `startswith("http")`, `:76`)
- [ ] 3.4 GREEN: activar la palanca en `backend/tests/conftest.py` (que hoy fija `mock_settings.supabase_url = ""`, `:112-113`) para que los 17 bloques de patch de `test_auth.py` y el `jwt.encode(..., algorithm="HS256")` de `conftest.py:5`/`:21` sigan corriendo **sin reescribirse**
- [ ] 3.5 TRIANGULATE: correr la suite entera de backend y confirmar cero regresiones sobre el baseline de 1.1
- [ ] 3.6 Verificar que `app_env` (declarado en `config.py:7` y hoy **no leído en ninguna línea de la app**) queda leído al menos en el validator de CORS de 4.x — o documentar por qué sigue sin lectores

## 4. Parte A — CORS por allow-list, sin credenciales (D10)

- [ ] 4.1 RED→GREEN: `backend/tests/test_cors_allowlist.py::test_foreign_origin_gets_no_acao` — preflight con `Origin: https://evil.example` → sin `access-control-allow-origin`. Reproduce **F5** medido en prod
- [ ] 4.2 RED→GREEN: `::test_production_origin_allowed_with_and_without_www` y `::test_vercel_preview_origin_allowed` — GREEN: `allow_origin_regex` con `^https://(www\.)?aliadata\.com\.ar$` y `^https://v0-saa-s-empresarial-completo-eie(-[a-z0-9-]+)?\.vercel\.app$` en `backend/main.py:64-70`
- [ ] 4.3 RED→GREEN: `::test_localhost_allowed_only_outside_production` — `http://localhost:3000` permitido cuando `app_env != "production"`
- [ ] 4.4 RED→GREEN: `::test_allow_credentials_is_false` — GREEN: `allow_credentials=False`. Justificación en el design (D10): cero lecturas de cookie en `backend/`, ningún caller manda `credentials:'include'`
- [ ] 4.5 RED→GREEN: `::test_problem_body_does_not_reflect_foreign_origin` — un 404/422 con formato de problema hacia un origen ajeno tampoco lleva encabezados de CORS. GREEN: `backend/core/errors.py:78-85` (`cors_error_headers`) usa el mismo criterio que el middleware, no `allowed == "*"`
- [ ] 4.6 RED→GREEN: `test_config_auth_failfast.py::test_wildcard_origin_forbidden_in_production` — con `app_env == "production"` y `backend_allowed_origin == "*"` el arranque falla
- [ ] 4.7 GREEN: defaults seguros verificados — con `BACKEND_ALLOWED_ORIGIN` **sin definir** (el estado real de Render hoy), prod sigue funcionando por el regex, no por el comodín

## 5. Parte A — Retiro del canal WebSocket (D11)

- [ ] 5.1 RED→GREEN: `backend/tests/test_no_websocket_surface.py::test_openapi_has_no_ws_route` y `::test_no_ws_router_registered` — el candado que impide que el canal vuelva por descuido
- [ ] 5.2 GREEN: eliminar `backend/routers/ws.py`, `backend/core/ws_manager.py` y `backend/tests/test_ws.py`; quitar `app.include_router(ws.router)` de `backend/main.py:143` y el import correspondiente
- [ ] 5.3 TRIANGULATE: `::test_no_query_param_token_extraction` — grep programático que falla si algún camino del backend extrae un token de un parámetro de consulta (hoy `ws.py:41` lo hace). Cubre el requirement nuevo "El token viaja únicamente por el encabezado de autorización"
- [ ] 5.4 Verificar que el retiro no rompe nada: `grep -rn "ws_manager\|routers.ws" backend/` (sin `.venv`) → 0 hits; suite de backend en verde
- [ ] 5.5 Registrar en el PR que el segundo decoder de JWT (`ws.py:12-34`, sin rama HS256, sin `iss`, sin `aud`, nunca ejercitado) desaparece con el módulo — queda **un solo** decoder canónico

## 6. Parte A — Re-chequeo en la base para las acciones de configuración (D12)

- [ ] 6.1 RED→GREEN: `backend/tests/test_guards_config_recheck.py::test_configuration_guard_queries_db_even_with_claim` — con el claim presente, el guard debe consultar `rpc_my_active_account_roles()`. GREEN: rama en `require_account_role` (`backend/core/guards.py:49-75`) cuando el conjunto permitido es `CAN_CONFIGURE` (`backend/core/rbac.py:26`)
- [ ] 6.2 RED→GREEN: `::test_revoked_role_denied_before_token_expiry` — claim que declara el rol, base que ya no lo tiene → 403. Es el hallazgo de staleness de la fila 2 de §8 de la auditoría
- [ ] 6.3 TRIANGULATE: `::test_non_configuration_guard_still_short_circuits_on_claim` — el hot path **no** paga la query. Candado contra la alternativa rechazada de OQ-4
- [ ] 6.4 TRIANGULATE: `::test_configuration_guard_denies_when_db_returns_empty` — sin roles vigentes, deniega; nunca concede por ausencia de información
- [ ] 6.5 GREEN: refrescar el docstring envejecido de `backend/core/guards.py:81` ("no existe custom access token hook" — el hook **sí** copia `profiles.role` a `app_metadata.role`, `20260827000001:151-153`)
- [ ] 6.6 Correr la suite de los 4 services que consumen `require_account_role` (`cost_centers`, `payment_methods`, `product_categories`, `account_charges`) y confirmar cero regresiones

## 7. Parte A — Edge Function `invoice-ocr` (D13)

- [ ] 7.1 RED→GREEN: test de la función (molde de los tests de `supabase/functions/` existentes) — `storage_path` del body distinto del de la fila → se descarga el de la **fila**, no el del body
- [ ] 7.2 GREEN: sumar `storage_path` al `SELECT` de `invoice_documents` (`supabase/functions/invoice-ocr/index.ts:112-115`) y usarlo en la descarga con el cliente de service role (`:132-135`)
- [ ] 7.3 TRIANGULATE: el body sigue aceptándose por compatibilidad (`:104-107`) y el caller existente (`frontend/lib/services/invoiceOcrService.ts:117-119`) sigue funcionando sin cambios
- [ ] 7.4 Verificar con `npx deno check` desde una copia **fuera del monorepo** con `DENO_NO_PACKAGE_JSON=1` (gotcha registrado: dentro, Deno escribe `workspaces` en `package.json`). Registrar los errores preexistentes de `ai-insights`/`ai-resumen` como tales, sin arreglarlos acá

## 8. Parte A — Migración `20261051000001` (D14)

- [ ] 8.1 RED→GREEN: `supabase/tests/test_accept_invitation_binding.sql` bloque (1) — invitación con `email` aceptada por **otra** identidad → rechazo, y cero filas nuevas en `account_members` y en el pivot de roles
- [ ] 8.2 RED→GREEN: bloque (2) — la identidad invitada acepta con normalidad; bloque (3) — comparación insensible a mayúsculas
- [ ] 8.3 RED→GREEN: bloque (4) — invitación **sin** `email` sigue canjeable por cualquier identidad autenticada
- [ ] 8.4 RED→GREEN: bloque (5) — dos aceptaciones concurrentes del mismo token: una gana, la otra se rechaza por invitación ya usada, sin segunda membresía. Requiere el `SELECT … FOR UPDATE` antes de validar
- [ ] 8.5 GREEN: escribir la migración `20261051000001` reescribiendo `rpc_accept_invitation(text)` **desde el cuerpo vivo capturado en 1.3**, con `DROP FUNCTION` + `CREATE` (nunca `CREATE OR REPLACE` con firma cambiada — gotcha `42725`) y **re-emisión de ACLs** tras el `DROP`: `GRANT EXECUTE` a `authenticated` y `service_role`, `REVOKE` explícito de `anon` (Supabase otorga `EXECUTE` a `anon` por default en función nueva)
- [ ] 8.6 RED→GREEN: bloque (6) de integridad de función — `pg_get_functiondef('public.rpc_accept_invitation(text)'::regprocedure)` contiene el guard de email y el `FOR UPDATE` (molde de `supabase/tests/test_operacion_party_guard.sql:521-561`)
- [ ] 8.7 RED→GREEN: bloque (7) — **cero overloads** de `rpc_accept_invitation` y ACLs exactas (`anon` sin `EXECUTE`)
- [ ] 8.8 RED→GREEN: `supabase/tests/test_realtime_publication.sql` — `fiscal_documents` **y** `notifications` en `supabase_realtime`; y la reaplicación del `ALTER PUBLICATION` guardado no falla (idempotencia probada ×2)
- [ ] 8.9 GREEN: cablear los dos gates nuevos a `.github/workflows/KPI_Validation.yml` (steps al final de la lista, junto a los 77 existentes) y sumar `20261051000001` a la cadena de reaplicación idempotente
- [ ] 8.10 Verificar la migración contra la base local aplicándola **dos veces** consecutivas; **no** correr `supabase db reset` (la base local puede estar compartida con otro worktree)

## 9. Parte A — Documentación y configuración reconciliadas (D15)

- [ ] 9.1 `openspec/specs/backend-auth/spec.md:11` — la línea normativa "SHALL … `HS256`" se reconcilia al archivar vía el delta de este change; verificar que el delta cubre el texto vigente y no deja la afirmación vieja en pie
- [ ] 9.2 `knowledge-base/08_arquitectura_propuesta.md` — `:238`/`:310` documentan HS256 sin mencionar `SUPABASE_URL` (la variable que **elige la rama**); `:132` dice que el service role es "solo Edge Functions" cuando `backend/services/payments.py:117-126` lo usa
- [ ] 9.3 `knowledge-base/02_descripcion_general.md` y `knowledge-base/09_decisiones_y_supuestos.md` (DEC-16) — retirar la mención del canal WebSocket propio como superficie viva del backend
- [ ] 9.4 `backend/core/config.py:11-12` — mover/documentar `supabase_url` como variable de **auth**, no bajo el header de pagos
- [ ] 9.5 `CLAUDE.md` — retirar la nota de divergencia `python-jose` vs `PyJWT` (ambos manifiestos declaran sólo `PyJWT[crypto]`: `backend/requirements.txt:3`, `backend/pyproject.toml:8`) y la mención de `ws.py`/`ws_manager` en la superficie del backend; correr `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** (el gate `Docs Sync` lo verifica)
- [ ] 9.6 `supabase/config.toml:396`/`:407`/`:418`/`:429`/`:449` — los cinco `verify_jwt = true` pasan a `false` con un comentario explicando que el deploy pasa `--no-verify-jwt` a toda la flota (`.github/workflows/deploy.yml:63`) y que cada función autentica en código, fail-closed
- [ ] 9.7 Registrar la ficha de la Parte A en `CHANGES.md`

## 10. Parte A — Verificación y cierre

- [ ] 10.1 `pytest backend/tests/` completo: cero regresiones sobre el baseline de 1.1, coverage ≥ el umbral de CI
- [ ] 10.2 Los 2 gates SQL nuevos + `test_function_acl_gate.sql` + `test_errcode_5char_gate.sql` en verde
- [ ] 10.3 Declarado: **sin superficie frontend** en esta parte — `git diff --stat` no debe tocar ningún archivo bajo `frontend/`
- [ ] 10.4 Ronda de revisión adversarial pre-merge; aplicar findings y re-verificar
- [ ] 10.5 **Verificación post-merge en prod** (sólo lectura): `MAX(version) = 20261051000001`; **una sola** definición de `rpc_accept_invitation` sin overload y con el guard en el cuerpo vivo; `anon` sin `EXECUTE`; `pg_publication_tables` con `notifications` **y** `fiscal_documents`; `GET /openapi.json` del backend sin ninguna ruta `/ws`; preflight con `Origin: https://evil.example` → **sin** `access-control-allow-origin` (hoy lo refleja, F5); una llamada real autenticada sigue respondiendo 200 (el `verify_aud`/`iss` nuevo no rompió nada)
- [ ] 10.6 Sign-off del PO para la Parte A antes de empezar la Parte B

## 11. Parte B — Checkpoint y red de seguridad

- [ ] 11.1 SAFETY NET: `pnpm vitest run` completo en `frontend/` y registrar el baseline exacto. El flaky preexistente de `AdminSegurosPage.test.tsx` bajo carga está documentado — se reporta, no se arregla
- [ ] 11.2 SAFETY NET: `pnpm tsc --noEmit` y registrar el estado (gotcha: `next-env.d.ts` queda sucio tras un `next dev` previo)
- [ ] 11.3 Medir el estado de hoy que la parte corrige: `curl` anónimo sobre los 12 árboles sin gate (`/caja`, `/cobranzas`, `/banco`, `/estadisticas`, `/exportaciones`, `/facturacion`, `/finanzas`, `/organizacion`, `/planes`, `/rentabilidad`, `/reportes`, `/sucursales`) → registrar cuáles devuelven 200 hoy, para el antes/después de 16.4
- [ ] 11.4 Confirmar que la Parte A está mergeada y verificada en prod (11.x no arranca antes)

## 12. Parte B — Cobertura de rutas por construcción (D4)

- [ ] 12.1 RED: `frontend/__tests__/lib/protected-routes-coverage.test.ts` — lee `frontend/app/(dashboard)/` del filesystem, ignora directorios que empiezan con `_` y los grupos de ruta `(…)`, y falla si algún árbol no queda cubierto. **Debe fallar hoy nombrando los 12** de 11.3
- [ ] 12.2 GREEN: invertir `PROTECTED_PREFIXES` (`frontend/lib/supabase/middleware.ts:57-61`) a una **allow-list de rutas públicas** + protección por defecto de todo `app/(dashboard)`
- [ ] 12.3 TRIANGULATE: `::test_auth_routes_are_never_protected` — `/auth/*` queda fuera del conjunto protegido (razón documentada en `middleware.ts:129-130`: gatear `/auth/callback` produce un loop)
- [ ] 12.4 TRIANGULATE: `::test_a_new_route_tree_without_coverage_fails` — crear un directorio temporal en el fixture y ver el test fallar. Sin esto, el candado no está probado
- [ ] 12.5 Verificar que `frontend/__tests__/lib/protected-prefixes-proveedores.test.ts` (que hoy assertea **un** prefijo) sigue en verde o se absorbe en el test nuevo, sin perder la aserción
- [ ] 12.6 Verificar que `frontend/__tests__/idle-server-enforcement.test.ts:176` (que importa `PROTECTED_PREFIXES`) sigue en verde tras el cambio de forma

## 13. Parte B — `safeNext()` compartido, redirect al login real, cookies en redirects (D5)

- [ ] 13.1 RED→GREEN: `frontend/__tests__/lib/safe-next.test.ts` — destino externo (`@evil.example/`, `//evil.example`, `\\evil.example`, `https://…`) resuelve a la ruta principal; destino interno se conserva. GREEN: extraer el helper desde la validación que hoy vive sólo en `middleware.ts:186`
- [ ] 13.2 RED→GREEN: `frontend/__tests__/app/auth-callback-next.test.ts` — el manejador de `/auth/callback` (`route.ts:9`, `:43`, hoy concatena sin validar) aplica `safeNext()`. Cierra el open redirect latente
- [ ] 13.3 RED→GREEN: `frontend/__tests__/lib/no-login-literal.test.ts` — falla si aparece el literal `"/login"` como destino de redirect en el árbol de páginas. **Debe fallar hoy** nombrando los 4 de F2
- [ ] 13.4 GREEN: los cuatro `redirect("/login")` pasan a `redirect("/auth/login?next=…")` — `frontend/app/(dashboard)/planes/page.tsx:30`, `planes/success/page.tsx:27`, `facturacion/page.tsx:78`, `ventas/ordenes/[id]/page.tsx:60`
- [ ] 13.5 RED→GREEN: `frontend/__tests__/lib/middleware-redirect-cookies.test.ts` — un redirect del middleware conserva las cookies de sesión escritas por `setAll` (`middleware.ts:77-82`). GREEN: copiarlas en las seis salidas por redirect

## 14. Parte B — Cierre de sesión uniforme y recuperación del 401 (D6, D7)

- [ ] 14.1 RED→GREEN: `frontend/__tests__/lib/clear-auth-ux-cookies.test.ts` — el helper compartido borra `auth:last-activity` **y** `tenant:active`. GREEN: crearlo en `frontend/lib/cookies.ts` y consumirlo desde los tres caminos
- [ ] 14.2 RED→GREEN: `frontend/__tests__/lib/idle-logout.test.ts::clears_last_activity_cookie` — hoy `performIdleLogout` borra sólo `tenant:active` (`frontend/lib/auth/idle-logout.ts:50`)
- [ ] 14.3 RED→GREEN: `::uses_local_scope` — `signOut({ scope: 'local' })` en `logout()` (`frontend/contexts/auth-context.tsx:295`) y en `performIdleLogout` (`idle-logout.ts:43`); `closeAllSessions()` (`auth-context.tsx:344`) **conserva** `'global'`. Hoy el `signOut()` pelado es global por default de la librería
- [ ] 14.4 RED→GREEN: `::close_all_sessions_clears_cookies_too` — hoy `closeAllSessions` no borra ninguna (`auth-context.tsx:341-347`)
- [ ] 14.5 RED→GREEN: `frontend/__tests__/lib/middleware-idle-revokes.test.ts` — la rama idle del middleware (`middleware.ts:131-165`) revoca contra el proveedor **antes** de borrar cookies. Hoy no hay un solo `signOut` en ese archivo
- [ ] 14.6 RED→GREEN: `frontend/__tests__/lib/relogin-after-idle.test.ts` — re-login inmediato tras un cierre por inactividad **no** rebota. Es el bounce del primer intento descrito en la fila 5 de §8
- [ ] 14.7 RED→GREEN: `frontend/__tests__/lib/python-client-401.test.ts` — un 401 con sesión ausente navega a `/auth/login?reason=expired&next=…`; con sesión viva conserva el error actual. GREEN: `frontend/lib/api/python-client.ts:26-30`
- [ ] 14.8 GREEN: mismo tratamiento en el transporte duplicado `frontend/lib/api/subscriptions-client.ts:47-57` y en los dos `fetch` a mano que hoy mandan `Bearer ` con token vacío — `frontend/components/ventas/sale-receipt-button.tsx:132-140` y `frontend/app/(dashboard)/admin/pagos/page.tsx:146-152`
- [ ] 14.9 GREEN: el botón del sidebar espera el `logout()` antes de navegar (`frontend/components/app-sidebar.tsx:353-355` hoy lanza `logout()` y en la línea siguiente fuerza `window.location.href`), con `.catch()` en el call site

## 15. Parte B — Atributo `Secure` y comentarios que mienten

- [ ] 15.1 RED→GREEN: `frontend/__tests__/lib/cookie-options.test.ts` — el objeto compartido emite `secure: true` cuando el entorno es producción y `false` fuera. GREEN: crear `frontend/lib/supabase/cookie-options.ts`
- [ ] 15.2 GREEN: consumirlo desde los cuatro sitios que construyen cliente — `frontend/lib/supabase/client.ts:4`, `server.ts:6`, `middleware.ts:69`, `frontend/app/auth/callback/route.ts:13`. **En esta parte `httpOnly` sigue en `false`**: cambiarlo rompe el Bearer de FastAPI hasta que exista el token handler (D16)
- [ ] 15.3 TRIANGULATE: `::test_all_four_call_sites_share_the_options` — grep programático que falla si un sitio declara sus propios atributos
- [ ] 15.4 GREEN: corregir los comentarios falsos — `frontend/lib/cookies.ts:5` ("tokens stay in Supabase httpOnly cookies"), `frontend/lib/api/python-client.ts:14` ("reads from local storage"), `frontend/lib/auth/idle-logout.ts:25` y `:42` ("local scope", que recién ahora será cierto)

## 16. Parte B — Verificación y cierre

- [ ] 16.1 `pnpm vitest run` completo: cero regresiones sobre el baseline de 11.1
- [ ] 16.2 `pnpm tsc --noEmit`: sin errores nuevos sobre 11.2
- [ ] 16.3 Humo en el stack local: login → dashboard → navegar a una de las 12 rutas antes descubiertas → cerrar sesión → verificar que una segunda pestaña abierta se entera; y que cerrar sesión en el navegador A **no** desloguea al navegador B
- [ ] 16.4 **Verificación post-merge en prod**: `curl` anónimo sobre los 12 árboles de 11.3 → **307** a `/auth/login?next=…`; `curl` anónimo sobre `/planes` → 307 sin `/login` en el stream
- [ ] 16.5 Ronda de revisión adversarial pre-merge; aplicar findings y re-verificar
- [ ] 16.6 Registrar la ficha de la Parte B en `CHANGES.md`; sign-off del PO antes de empezar la Parte C

## 17. Parte C — Checkpoint y red de seguridad

- [ ] 17.1 SAFETY NET: `pnpm vitest run` y `pnpm tsc --noEmit`, baseline registrado. La Parte C parte de `main` con la Parte B ya mergeada (nunca en paralelo: las dos tocan `middleware.ts`)
- [ ] 17.2 Inventario cerrado y congelado de los **43 archivos** con `supabase.auth.*` en el navegador (getUser ×30, getSession ×16, signOut ×4, updateUser ×3, onAuthStateChange ×2, signUp/signInWithPassword/signInWithOtp/resetPasswordForEmail/resend/refreshSession/exchangeCodeForSession ×1) y de los **69** que importan `@/lib/supabase/client`, cada uno con su destino
- [ ] 17.3 Confirmar en `node_modules` las capacidades que el diseño asume: `createClient(url, key, { accessToken })` en `@supabase/supabase-js` 2.104.1 (`dist/index.mjs:135-138`, `:383-407`, `:527`) y el callback de `accessToken` en `realtime-js` (`dist/main/RealtimeClient.js:119-120`, `:166`, `:333-344`). Si la versión instalada cambió, el design se corrige antes de escribir código
- [ ] 17.4 Verificar que no hay obstáculos para el nonce: cero `<Script>`/`next/script` en el árbol y un único `dangerouslySetInnerHTML`, que es un `<style>` (`frontend/components/ui/chart.tsx:81`, `style-src`, no `script-src`)

## 18. Parte C — Operaciones de auth al servidor y cookies httpOnly (D1, D2)

- [ ] 18.1 RED→GREEN: `frontend/__tests__/lib/cookie-options.test.ts::emits_http_only` — el objeto compartido de 15.1 emite `httpOnly: true` y `sameSite: 'lax'`
- [ ] 18.2 GREEN: documentar en el propio archivo por qué `Lax` y **no** `Strict` (D2): los enlaces por email entran por `/auth/callback` como navegación top-level y deben llevar la cookie PKCE del verificador
- [ ] 18.3 RED→GREEN: `frontend/__tests__/app/auth-actions.test.ts::sign_in_runs_on_the_server` — la acción de inicio de sesión recibe credenciales + token de captcha y es el servidor quien contacta al proveedor. GREEN: Server Action bajo `frontend/app/auth/`
- [ ] 18.4 GREEN: mover al servidor el resto de las operaciones — `signUp`, `signInWithOtp`, `resetPasswordForEmail`, `resend`, `updateUser` (contraseña y email), `exchangeCodeForSession`, `signOut`. Las pantallas conservan su UI y se recablean
- [ ] 18.5 TRIANGULATE: `::captcha_token_still_reaches_the_provider` — el `captchaToken` sigue viajando; el helper `submitWithFreshCaptcha` sigue siendo el único camino de envío en toda pantalla con captcha (regla del proyecto)
- [ ] 18.6 TRIANGULATE: `::existing_session_survives_the_switch` — una cookie con el formato actual (no-httpOnly) sigue siendo válida y el servidor la reescribe como httpOnly en el primer refresh. **Cero re-login forzado** es requisito duro
- [ ] 18.7 GREEN: `frontend/app/auth/callback/route.ts` escribe las cookies con las opciones compartidas y conserva el `safeNext()` de 13.2

## 19. Parte C — Token handler y cliente de navegador (D1)

- [ ] 19.1 RED→GREEN: `frontend/__tests__/app/api-auth-token.test.ts::never_returns_refresh_token` — la respuesta contiene `access_token`, `expires_at` y `user`, y **no** contiene el refresh token bajo ningún nombre
- [ ] 19.2 RED→GREEN: `::returns_no_session_when_cookie_absent` — sin cookie válida, no entrega token
- [ ] 19.3 RED→GREEN: `::refresh_rotates_cookies` — cuando el token vencido se renueva, la respuesta emite las cookies rotadas con las opciones compartidas
- [ ] 19.4 GREEN: crear el Route Handler `frontend/app/api/auth/token/route.ts` sobre `createServerClient` + opciones compartidas
- [ ] 19.5 RED→GREEN: `frontend/__tests__/lib/access-token-store.test.ts` — el token vive **sólo** en memoria del módulo: no se escribe en cookie, ni en `localStorage`, ni en `sessionStorage`; se renueva antes de vencer, en `visibilitychange` y tras un 401
- [ ] 19.6 GREEN: `frontend/lib/supabase/client.ts` pasa a `createClient(url, anonKey, { accessToken: () => getAccessToken() })`
- [ ] 19.7 RED→GREEN: `frontend/__tests__/lib/no-browser-auth-calls.test.ts` — grep programático que falla si queda algún `supabase.auth.*` en código de navegador (con `accessToken` configurado, cualquiera de ellos **lanza** en runtime: `index.mjs:389`). Recorre el inventario de 17.2
- [ ] 19.8 GREEN: migrar los 43 archivos. Los `getUser()`/`getSession()` que sólo querían el token pasan por `getAccessToken()`; los que querían la identidad, por el contexto de sesión de la app
- [ ] 19.9 TRIANGULATE: `frontend/__tests__/hooks/use-notifications-realtime.test.ts` — Realtime recibe el token por el callback y lo re-empuja en cada renovación (hoy lo hacía `supabase-js` en `SIGNED_IN`/`TOKEN_REFRESHED`, `index.mjs:554`, `:557-566`)
- [ ] 19.10 TRIANGULATE: Storage y Functions siguen funcionando con el token del callback — `frontend/components/settings/AvatarUpload.tsx`, `frontend/lib/services/invoiceOcrService.ts` (upload/remove + `functions.invoke`), y los `functions.invoke` de `ai-summary-card.tsx`, `aiInsightService.ts`, `fairAdvisorService.ts`, `frontend/lib/supabase/services.ts`
- [ ] 19.11 TRIANGULATE: las llamadas a Edge Functions por `fetch` a mano siguen llevando el Bearer correcto — `frontend/hooks/auth/use-export-usage.ts:85-92`, `frontend/hooks/data/use-statistics-ai.ts:60-67`, `simulador/page.tsx:118`/`:137`, `PriceSuggestionModal.tsx:69`/`:77`

## 20. Parte C — Bus de eventos de sesión (D1)

- [ ] 20.1 RED→GREEN: `frontend/__tests__/lib/session-bus.test.ts` — el cierre de sesión en una pestaña alcanza a la otra. GREEN: montar el bus sobre `frontend/lib/auth/idle-transport.ts` (BroadcastChannel con fallback a localStorage, `:43-49`, `:115-118`)
- [ ] 20.2 TRIANGULATE: `::no_second_cross_tab_transport` — grep programático que falla si nace un segundo `new BroadcastChannel` fuera del transporte compartido (regla "reutilización antes que repetición")
- [ ] 20.3 GREEN: retirar las dos suscripciones a `onAuthStateChange` (`frontend/contexts/auth-context.tsx:202` y la otra del árbol) y reemplazarlas por suscripciones al bus
- [ ] 20.4 TRIANGULATE: `::token_refresh_propagates` — una renovación en una pestaña deja a las otras con el token nuevo sin pedirlo por separado

## 21. Parte C — CSP con nonce (D3)

- [ ] 21.1 RED→GREEN: `frontend/__tests__/lib/csp-nonce.test.ts::production_script_src_has_no_unsafe` — en producción, `script-src` lleva nonce + `'strict-dynamic'` y **no** lleva `'unsafe-inline'` ni `'unsafe-eval'`
- [ ] 21.2 RED→GREEN: `::nonce_differs_per_request` — dos invocaciones producen nonces distintos
- [ ] 21.3 RED→GREEN: `::unsafe_eval_survives_outside_production` — fuera de producción se conserva
- [ ] 21.4 RED→GREEN: `::style_src_keeps_unsafe_inline` — candado explícito: Tailwind/Radix y el `<style>` de `frontend/components/ui/chart.tsx:81` lo necesitan
- [ ] 21.5 RED→GREEN: `::turnstile_host_still_allowed` — `https://challenges.cloudflare.com` sigue en `script-src`, `connect-src` y `frame-src`
- [ ] 21.6 GREEN: generar el nonce en `frontend/middleware.ts`, propagarlo por el encabezado de petición `x-nonce` y aplicarlo en `buildContentSecurityPolicy()` (`frontend/lib/supabase/middleware.ts:40-52`)
- [ ] 21.7 GREEN: pasar el nonce a `next-themes` vía la prop `nonce` de `frontend/components/theme-provider.tsx:10`, para que su script en línea de tema se ejecute
- [ ] 21.8 TRIANGULATE: `frontend/__tests__/lib/csp-frame-src.test.ts` y `csp-worker-src.test.ts` (preexistentes) siguen en verde — `frame-src` con YouTube nocookie y `worker-src 'self' blob:` (que los decoders de R3F necesitan) no se tocan

## 22. Parte C — Verificación visual y funcional de las siete pantallas

- [ ] 22.1 Humo funcional en el stack local, ciclo completo: login → dashboard → una llamada a FastAPI que escriba → una notificación en tiempo real → logout. Los cuatro consumidores del token (PostgREST, FastAPI, Realtime, Storage/Functions) ejercitados
- [ ] 22.2 Verificar en el navegador local que la cookie de sesión aparece marcada `HttpOnly` y que `document.cookie` **no** la muestra
- [ ] 22.3 Verificar el ciclo de renovación: dejar la pestaña oculta más allá del vencimiento del token, volver, y confirmar que la app sigue operando sin recargar
- [ ] 22.4 Pasada visual de las **siete** pantallas recableadas (`/auth/login`, `/auth/register`, `/auth/forgot-password`, `/auth/reset-password`, `/auth/verify-email`, `/auth/callback` en su estado de error, y `/configuracion`) en **4 combinaciones**: desktop + móvil × claro + oscuro. Se verifican los estados de carga y de error, que son los que el recableado toca
- [ ] 22.5 **Verificación en un preview de Vercel, no sólo local**: consola abierta, cero violaciones de CSP en las 7 pantallas de auth + una del dashboard con gráficos (Recharts) + una con 3D (R3F). El CSP de dev es más laxo y el captcha tiene stub local: este paso es el único que prueba la política real
- [ ] 22.6 E2E: `frontend/e2e/fixtures/auth.setup.ts` sigue funcionando (hace login por la UI y guarda `storageState`, que **sí** captura cookies httpOnly); `frontend/e2e/auth.spec.ts` sigue en verde. Actualizar el comentario de `auth.spec.ts:41` sobre el scope global, que dejó de aplicar en la Parte B

## 23. Parte C — Verificación y cierre

- [ ] 23.1 `pnpm vitest run` y `pnpm tsc --noEmit`: cero regresiones sobre 17.1
- [ ] 23.2 `pytest backend/tests/` sin regresiones (no debería tocarse, pero el token cambia de origen)
- [ ] 23.3 Ronda de revisión adversarial pre-merge; aplicar findings y re-verificar
- [ ] 23.4 **Verificación post-merge en prod**: `curl -I` de una página cualquiera → `Content-Security-Policy` con nonce y sin `'unsafe-inline'`/`'unsafe-eval'` en `script-src`. Los atributos de `Set-Cookie` de una sesión real los reporta **el PO** tras su propio login (task 24.5) — el agente no hace login en prod
- [ ] 23.5 Registrar la ficha de la Parte C en `CHANGES.md`, con el riesgo residual declarado (un XSS sigue pudiendo actuar en la página durante la vida del access token) y el candidato que queda abierto: el prefijo `__Host-` de OQ-1
- [ ] 23.6 Actualizar a mano el `## Purpose` de `openspec/specs/python-backend/spec.md` (hoy dice "expone una API HTTP + WebSocket") y el de `openspec/specs/realtime-websocket/spec.md` al archivar — **gotcha registrado: el `## Purpose` no lo cubre el delta**

## 24. Operación (PO) — acciones en dashboards, no código

- [ ] 24.1 Confirmar en el Dashboard de Supabase que el hook `Customize Access Token` está habilitado (el repo **no puede probarlo**: `config.toml:270-272` gobierna sólo el stack local y `deploy.yml` nunca corre `supabase config push`)
- [ ] 24.2 Tras el merge de la Parte C, poner `Access token expiry` en **900 s** (OQ-5). Antes del token handler **no** conviene: cuadruplicaría los refresh escritos sobre cookies legibles por JS
- [ ] 24.3 Confirmar/poner en Render: `SUPABASE_URL` (de la que depende el fail-fast de 3.x, y que ya debería estar porque prod corre la rama JWKS), `SUPABASE_JWT_SECRET` y `BACKEND_ALLOWED_ORIGIN`. **Previo al merge de la Parte A**
- [ ] 24.4 Confirmar que Turnstile está habilitado en el Dashboard del proyecto (§9.6 de la auditoría: el bloque `[auth.captcha]` está comentado en `config.toml` y no hay ninguna llamada de verificación en el repo, así que los `captchaToken` que la app manda sólo tienen efecto si el proyecto lo tiene activo)
- [ ] 24.5 Humo real del PO tras la Parte C: iniciar sesión en prod desde su propio navegador y reportar los atributos del `Set-Cookie` de la sesión (`HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`), más el recorrido de una venta completa para confirmar que nada del recableado rompió la operación diaria
- [ ] 24.6 Decidir las 6 OQs del design (o firmar sus recomendaciones): `__Host-` (recomendación: no ahora), retiro de `/ws` (retirar), scope del logout (local), re-chequeo en base (sólo configuración), expiry del token (900 s), binding de email (estricto)
