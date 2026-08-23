# v31-tenancy-pool-rls — Operación del Paso 1 y preparación del Paso 2

> Complementa `design.md` y `tasks.md`. Este documento es **operacional**: cómo
> prender/apagar las palancas, qué mirar durante la ventana de observación, y
> el procedimiento de rollback. No repite las decisiones de diseño (D1-D8).

## 1. Palanca del Paso 1

- **Variable de entorno (Render)**: `TENANCY_TX_SCOPE_ENABLED`
- **Default**: apagada (`false` / variable ausente) — el merge a `main` no cambia nada en producción.
- **Encendida**: `get_db_conn` envuelve cada request en una transacción explícita con claims de alcance transaccional (`design.md` D1). Ver `backend/core/config.py::Settings.tenancy_tx_scope_enabled`.
- **Variable complementaria**: `TENANCY_TX_IDLE_TIMEOUT` (default `"30s"`) — valor de `idle_in_transaction_session_timeout`, sólo aplica con la palanca encendida (D4).

### Encender (acción del PO, tasks.md 4.4)

1. Setear `TENANCY_TX_SCOPE_ENABLED=true` en las env vars del servicio backend en Render.
2. Reiniciar el servicio (Render lo hace solo al guardar la env var, o manualmente desde el dashboard). Sin rebuild, ~50s.
3. Verificación inmediata (tasks.md 4.4/4.5): un request autenticado real (ej. `GET /health` no sirve porque no pasa por `get_db_conn` — usar un endpoint autenticado real, ej. `GET /products`) responde 200; revisar logs de Render por unos minutos: sin errores de transacción, sin 503 "Database pool not initialized".
4. **Registrar acá la fecha/hora exacta de activación** (inicio de la ventana de 7 días de la condición 3, `design.md`):

   ```
   Paso 1 activado: <PENDIENTE — el PO completa esta línea al encender>
   ```

### Apagar (rollback del Paso 1)

1. Setear `TENANCY_TX_SCOPE_ENABLED=false` (o borrar la variable) en Render.
2. Reiniciar el servicio. Sin rebuild, sin migración, sin datos que reparar (D1: la palanca no toca el schema).
3. Si además hace falta revertir el código: `git revert` del PR de este change y re-deploy (rebuild completo, ~50s de cold start).

## 2. Los cuatro contadores de la condición 4 (ventana de 7 días)

> **Un solo evento de cualquiera de los cuatro reinicia la ventana completa** (OQ-1). No se acorta ni se compensa con volumen.

| # | Contador | Cómo se observa | Objetivo |
|---|---|---|---|
| 1 | 500 intermitente de compras (K5) | Logs de Render, filtrar por `POST /purchases` y `PUT /purchases` con status 500. Baseline pre-Paso1: no reproducible a demanda localmente (la suite mockea asyncpg por completo, D1 Context) — sólo se observa en prod. | 0 ocurrencias |
| 2 | `idle_in_transaction_session_timeout` | Logs de Render (stdout/stderr del proceso backend) y/o logs de Postgres en el dashboard de Supabase (`gxdhpxvdjjkmxhdkkwyb` → Logs → Postgres), buscar `terminating connection due to idle-in-transaction timeout`. | 0 ocurrencias |
| 3 | 403 anómalo de "cuenta no encontrada" | Logs de Render, filtrar por el detail `"No active account found"` (el `HTTPException(403, ...)` de `backend/core/deps.py::get_account_id`) en usuarios que SÍ tienen membresía — comparar contra el registro de membresías (`account_members`) si aparece alguno para descartar falso positivo (usuario legítimamente sin cuenta). | 0 anómalos |
| 4 | Errores de transacción abortada | Logs de Render, buscar `current transaction is aborted` / `InFailedSQLTransactionError` / excepciones de asyncpg relacionadas a estado de transacción. | 0 ocurrencias |

No hay dashboard centralizado hoy (H-31, `v31-client-observability` es P2, backlog — no forma parte de este change). El registro es manual: revisar los logs de Render día por día durante la ventana y anotar acá o en el PR de cierre del grupo 5.

## 3. Prueba de concurrencia cross-tenant (condición 2, tasks.md 5.2)

Script guardado en `backend/scripts/tenancy_cross_tenant_concurrency_check.py` — **no se ejecutó todavía** (requiere el Paso 1 ya desplegado y dos usuarios reales de cuentas distintas; ver docstring del script para variables de entorno y modo de uso). Se reutiliza sin cambios en el grupo 8 (tasks.md 8.4), ahora contra el Paso 2 activo.

## 4. Rollback del Paso 2 — preparado de antemano (tasks.md 8.0)

> **Esto es preparación, NO la verificación en vivo que exige 8.0.** La precondición real ("rollback preparado y verificado", con alguien con acceso a Render presente durante 8.2) se cumple recién el día del corte, no hoy. Este documento existe para que ese día no haya que improvisar el procedimiento.

- **Palanca del Paso 2** (grupo 7, implementada 2026-08-23 — ver §5): **`TENANCY_RLS_ROLE_ENABLED`**. Ver `backend/core/config.py::Settings.tenancy_rls_role_enabled` y `backend/core/database.py::get_db_conn`.
- **Precondición dura**: requiere `TENANCY_TX_SCOPE_ENABLED=true` (Paso 1 ya encendido). Encender `TENANCY_RLS_ROLE_ENABLED=true` con `TENANCY_TX_SCOPE_ENABLED` apagada es la única de las 4 combinaciones de las dos palancas que es inválida por diseño (D6: el `SET LOCAL ROLE` sin la transacción explícita del Paso 1 no tiene alcance transaccional que lo sostenga) — el proceso **no arranca**: `Settings()` lanza `ValidationError` al importar `backend.core.config`, con el mensaje explicando por qué. Si Render muestra el servicio caído después de tocar esta variable, es la primera causa a revisar en los logs de arranque (deploy log, no logs de request).
- **Procedimiento de apagado** (idéntico en forma al del Paso 1): apagar `TENANCY_RLS_ROLE_ENABLED` en Render (o ponerla en `false`) → reiniciar servicio (~50s, sin rebuild) → el rol efectivo vuelve a `postgres` (BYPASSRLS), que es el estado actual de hoy — **no un estado peor** (design.md, "Rollback paso 2"). `TENANCY_TX_SCOPE_ENABLED` puede quedar encendida (es una combinación válida: Paso 1 solo).
- **Las policies agregadas en el grupo 6 son aditivas** — no hace falta revertirlas al apagar la palanca del Paso 2.
- **Checklist del día del corte** (a completar recién ese día, no hoy):
  - [ ] Persona con acceso a Render identificada y presente durante toda la verificación de 8.2.
  - [ ] Procedimiento de apagado probado en un ensayo previo (encender/apagar sin actividad real, para confirmar que el reinicio funciona como se espera).
  - [ ] Horario de baja actividad confirmado con el PO, sin anuncio a usuarios (OQ-4).
  - [ ] Inventario del grupo 6 cerrado con cero divergencias abiertas (tasks.md 6.6), incluyendo el sign-off del PO sobre `fiscal_documents`, `cashboxes` y `stock_movements` (ver `design.md`, amendment 2026-08-01) — **re-verificado read-only contra prod 2026-08-23** (`design.md`, amendment 2026-08-23): cero divergencias nuevas pese al desarrollo activo entre medio.
  - [ ] Gate del grupo 5 ("probado bajo carga") cerrado: los cuatro contadores de §2 en cero durante 7 días con el Paso 1 activo, más sign-off explícito del PO (condición 5.5). **Sigue sin cumplirse a la fecha de este documento** — ver §6.

## 5. Encendido del Paso 2 — procedimiento operativo (tasks.md 8.1-8.6)

> Acción del PO, **sólo después de** que el checklist de §4 esté completo (grupo 5 cerrado, inventario del grupo 6 sin divergencias, rollback ensayado). Horario de baja actividad, PO presente, **sin anuncio a usuarios** (OQ-4, deploy silencioso).

### 8.1 — Encender

1. Confirmar que `TENANCY_TX_SCOPE_ENABLED=true` ya está activa (precondición dura, §4).
2. Setear `TENANCY_RLS_ROLE_ENABLED=true` en las env vars del servicio backend en Render.
3. Reiniciar el servicio (Render lo hace solo al guardar la env var, o manualmente desde el dashboard). Sin rebuild, ~50s.
4. **Registrar acá la fecha/hora exacta de activación**:

   ```
   Paso 2 activado: <PENDIENTE — el PO completa esta línea al encender>
   ```

### 8.2 — Verificación inmediata: ¿el usuario efectivo es `authenticated`, no `postgres`?

**Sin impersonar a ningún usuario real.** Dos formas, de más simple a más completa:

- **Log estructurado (implementado, siempre activo)** — `get_db_conn` emite un log a nivel `DEBUG` en cada request con el Paso 2 encendido: `"v31-tenancy-pool-rls Paso 2: rol adoptado a authenticated para request.jwt.claims.sub=<user_id>"` (`backend/core/database.py`). Subir el nivel de log del servicio a DEBUG en Render por unos minutos inmediatamente después de encender, confirmar que la línea aparece en cada request autenticado, y volver a INFO. Barato, ya existe, no requiere código nuevo — la verificación operativa recomendada para el día del corte.
- **Endpoint de diagnóstico admin-only (NO implementado en este change — alternativa evaluada y descartada por alcance)**: un `GET /admin/diag/tenancy` que devuelva `{"current_user": ..., "claims_present": true}`, protegido por un guard de admin. Se descartó implementarlo acá porque el backend Python no tiene hoy ningún router `/admin/*` ni un guard `require_admin` (los paneles de KPI admin son RPCs de Postgres consultados directo desde el frontend, no vía FastAPI) — construir ambos de cero para un change de governance CRÍTICO cuyo objetivo es minimizar superficie tocada no se justificó. Si en el futuro se agrega un router admin por otra razón, este endpoint es una extensión barata; hasta entonces, el log estructurado cubre la necesidad de 8.2.

Cualquiera de las dos formas confirma la MISMA cosa: en un request real post-corte, el rol efectivo es `authenticated`, no `postgres`.

### 8.3 — Smoke E2E (acción del PO con una cuenta real)

Venta, compra, cobro, cierre de caja, emisión de comprobante. **Cualquier "permiso denegado" (403/500 con detail de Postgres tipo `permission denied` o `new row violates row-level security policy`) indica una colisión no inventariada** → apagar `TENANCY_RLS_ROLE_ENABLED` inmediatamente (procedimiento de §4) y volver al grupo 6. Contraste esperado: el inventario re-verificado en `design.md` (amendment 2026-08-23) no encontró gaps — un permiso denegado en el smoke sería una sorpresa real, no una posibilidad ya conocida y aceptada.

### 8.4 — Prueba de concurrencia cross-tenant (repetir §3, ahora con RLS activa)

Mismo script (`backend/scripts/tenancy_cross_tenant_concurrency_check.py`), sin cambios — ahora su resultado significa algo (antes de 8.1, con BYPASSRLS, "no vio datos de la otra cuenta" sólo probaba que el filtro de la app funcionaba; después de 8.1, prueba que la RLS también lo hace).

### 8.5 — Observación 48 h

Mismos cuatro contadores de §2, más atención específica a errores de permiso denegado (síntoma de una colisión no inventariada, distinto de los cuatro contadores del Paso 1).

### 8.6 — Camino de servicio sigue operativo

Procesar un aviso de pago real (o su equivalente de prueba en sandbox de MercadoPago) y una corrida del relay CAE del cron. Verificado por construcción en el código (`get_service_conn` nunca adopta el rol bajo ninguna combinación de palancas — `backend/tests/test_database.py::test_get_service_conn_step2_never_adopts_role_even_with_both_flags_on`), pero el smoke real es la confirmación operativa de que el aislamiento D5 se sostuvo también en producción.

### Rollback (una línea)

`TENANCY_RLS_ROLE_ENABLED=false` (o borrar la variable) → reiniciar servicio (~50s, sin rebuild, sin migración) → vuelve a `postgres`/BYPASSRLS, el estado de hoy — no uno peor.

## 6. Estado de esta preparación (actualizado 2026-08-23)

- **Paso 1**: código + tests + palanca apagada por defecto — mergeado. Estado en prod (encendido/apagado) es responsabilidad del PO — este documento no puede verificarlo por sí mismo; confirmar contra la línea de §1 antes de asumir cualquier cosa.
- **Ventana de 7 días (condición 3/gate del grupo 5)**: sigue **sin iniciar** hasta donde este documento puede constatar — depende de que el PO haya completado la línea de §1. **El grupo 7/8 implementados en este apply NO acortan ni saltean este gate**: siguen siendo precondición dura de 8.1 (grupo 5, `tasks.md`).
- **Inventario de colisiones (grupo 6)**: cerrado 2026-08-01, **re-verificado read-only contra prod 2026-08-23** (`design.md`, amendment 2026-08-23) — cero divergencias nuevas encontradas pese a desarrollo activo entre medio (quotes, subscriptions, payment_methods, points_of_sale se sumaron al inventario y todos tienen su policy).
- **Grupo 7 (adopción del rol `authenticated`)**: **implementado 2026-08-23** — código + tests (mocks, `backend/tests/test_database.py` + `backend/tests/test_config_tenancy_rls.py`) + gate SQL contra Postgres real (`supabase/tests/test_tenancy_rls_role.sql`, registrado en `KPI_Validation.yml`) — palanca `TENANCY_RLS_ROLE_ENABLED` apagada por defecto, mergeado inerte. **NO encendido en prod.**
- **Grupo 8 (corte)**: 8.0 (rollback preparado, este documento) completo. 8.1-8.6 son acción del PO — procedimiento documentado en §5, sin ejecutar.
