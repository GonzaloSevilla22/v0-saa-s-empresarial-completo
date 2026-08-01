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

- **Palanca del Paso 2** (a introducir en el grupo 7, `tasks.md` 7.2 — NO existe todavía, este change sólo completó el Paso 1): variable de entorno separada de `TENANCY_TX_SCOPE_ENABLED`, ej. `TENANCY_TX_ROLE_ENABLED` — nombre definitivo a fijar cuando se implemente el grupo 7.
- **Procedimiento de apagado** (idéntico en forma al del Paso 1): apagar la variable en Render → reiniciar servicio (~50s, sin rebuild) → el rol efectivo vuelve a `postgres` (BYPASSRLS), que es el estado actual de hoy — **no un estado peor** (design.md, "Rollback paso 2").
- **Las policies agregadas en el grupo 6 (si las hubo) son aditivas** — no hace falta revertirlas al apagar la palanca del Paso 2.
- **Checklist del día del corte** (a completar recién ese día, no hoy):
  - [ ] Persona con acceso a Render identificada y presente durante toda la verificación de 8.2.
  - [ ] Procedimiento de apagado probado en un ensayo previo (encender/apagar sin actividad real, para confirmar que el reinicio funciona como se espera).
  - [ ] Horario de baja actividad confirmado con el PO, sin anuncio a usuarios (OQ-4).
  - [ ] Inventario del grupo 6 cerrado con cero divergencias abiertas (tasks.md 6.6), incluyendo el sign-off del PO sobre `fiscal_documents`, `cashboxes` y `stock_movements` (ver `design.md`, amendment 2026-08-01).

## 5. Estado de esta preparación (2026-08-01)

- Paso 1: código + tests + palanca apagada por defecto — mergeado, NO encendido en prod todavía.
- Ventana de 7 días: **no iniciada** — arranca cuando el PO complete la línea de la sección 1.
- Inventario de colisiones (grupo 6): construido y documentado en `design.md` (read-only, sin aplicar ninguna resolución). Tres colisiones elevadas al PO: `fiscal_documents`, `cashboxes`, `stock_movements`.
- Grupo 7 (adopción del rol `authenticated`) y grupo 8 (corte): sin empezar — tasks sin marcar, correctamente gateadas.
