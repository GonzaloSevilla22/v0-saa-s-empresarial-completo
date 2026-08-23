## Context

Todo el backend Python pasa por 20 líneas de código:

```python
async def get_db_conn(user: dict = Depends(get_current_user)):
    async with pool.acquire() as conn:
        await conn.execute("""
            SELECT set_config('app.jwt_claims',     $1, false),
                   set_config('request.jwt.claims', $2, false)
        """, json.dumps(user), json.dumps({"sub": user["user_id"], "role": "authenticated"}))
        yield conn
```

Hay dos defectos superpuestos y un tercero cosmético que resulta ser diagnóstico:

1. **`is_local = false`** → alcance de **sesión**. Bajo Supavisor en *transaction mode*, la conexión física de servidor se devuelve al pool entre statements: el `set_config` puede quedar en una conexión y la query de negocio ejecutarse en otra. Los claims viajan a veces, no siempre. Es la mecánica exacta del bug intermitente K5.
2. **No hay `BEGIN`** → no hay nada que ate ambos statements a la misma conexión física. El defecto 1 sólo es explotable por el defecto 2; el fix también es conjunto.
3. **`app.jwt_claims` no lo lee nadie.** Barrido sobre todo el repositorio (migraciones, backend, frontend, edge functions): **cero lectores**. Se escribe en `database.py` y se afirma en `test_database.py`. El comentario del código ("leído por RLS policies y código app") es falso. Que un GUC inventado haya convivido dos años con el que sí importa es la señal de que este código nunca se verificó contra la base de verdad.

Y por encima de todo eso: **el pool conecta como `postgres`, con `rolbypassrls = true`**. Con BYPASSRLS, Postgres ni siquiera evalúa las policies — los claims correctos o incorrectos dan igual, porque nadie los consulta. Los defectos 1-2 sólo se vuelven visibles a través de los RPCs `SECURITY DEFINER` que llaman `auth.uid()` internamente, que es exactamente donde aparece K5.

### Evidencia de prod (`gxdhpxvdjjkmxhdkkwyb`, read-only vía MCP, 2026-07-31)

| Dato | Valor | Consecuencia |
|---|---|---|
| `postgres.rolbypassrls` | **true** | RLS inerte para el backend |
| `authenticated.rolbypassrls` | **false** | es el rol correcto para el camino de request |
| Tablas en `public` | 68 · **0 sin RLS** | no hay que activar RLS en ningún lado |
| Tablas con SELECT para `authenticated` | **68 / 68** | las lecturas no necesitan GRANTs nuevos |
| Tablas con RLS y **sin** policy de INSERT/UPDATE/DELETE | **40** | el riesgo real del paso 2 |
| Funciones `rpc_*` | 68 · **66** con EXECUTE para `authenticated` · 67 `SECURITY DEFINER` | la superficie de escritura por RPC está casi lista |
| Escrituras directas desde repositories | 15 tablas con `INSERT INTO`, ~13 con `UPDATE` | el inventario a cruzar contra las 40 |
| Consumidores que dependen de BYPASSRLS | **3** (webhook de pagos, endpoint de relay CAE del cron, tarea en segundo plano de CAE) | descarta `ALTER ROLE postgres NOBYPASSRLS` |
| Usos de `.transaction()` en repositories | **9** | pasan a ser savepoints (ver D3) |
| Usos de `get_db_conn`/`get_account_id` en routers | **56** | dimensiona el blast radius |

### Restricciones del proyecto

- Supavisor en **transaction mode**. Bajar a session pooler reduce el techo de conexiones concurrentes — inaceptable con el objetivo comercial de crecer en junio 2026, y además innecesario (ver D1).
- Deploy en Render: un `git revert` redeploya (~50 s de cold start). Un cambio de variable de entorno reinicia el servicio sin rebuild — es la palanca más rápida disponible.
- **No hay infraestructura de load testing.** Cualquier definición de "probado bajo carga" tiene que construirse con lo que hay: operación real observada + una prueba de concurrencia casera. Ver "probado bajo carga".
- DEC-24: la unidad de trabajo transaccional del proyecto son los RPCs `SECURITY DEFINER`. Los services no comitean.
- Governance CRÍTICO: aislamiento entre 34 cuentas con dinero real.

### La nota de C-17, corregida

La memoria del proyecto registra que **"SET ROLE no funciona con pgBouncer en transaction mode"**. Esto es cierto para `SET ROLE` **de sesión**: sobrevive al fin de la transacción, la conexión física vuelve al pool con el rol cambiado, y el próximo cliente la hereda. Es un bug de seguridad, no una limitación.

**`SET LOCAL ROLE` es otra cosa**: su efecto se deshace automáticamente en `COMMIT`/`ROLLBACK`, por lo que la conexión siempre vuelve al pool limpia. Es el patrón que PostgREST usa contra Supavisor en transaction mode desde siempre. La misma distinción vale para `set_config(..., true)` vs `set_config(..., false)`.

Toda la Opción A depende de esta distinción. Si fuera falsa, el paso 2 no sería viable — por eso el paso 1 la prueba en producción **antes** de que el paso 2 dependa de ella.

## Goals / Non-Goals

**Goals:**
- Que los claims lleguen **siempre** a la conexión que ejecuta la query, con alcance transaccional y sin filtrarse entre requests.
- Que desaparezcan los 500 intermitentes de compras (K5).
- Que la RLS pase a evaluarse también para el backend, convirtiendo DEC-13 / KB-08 en una descripción verdadera del sistema.
- Que el corte del paso 2 sea una decisión informada por datos de producción, no un salto de fe.
- Que cada paso sea reversible con una acción, sin migración destructiva.

**Non-Goals:**
- **No** se migran `is_account_writer` / `current_account_ids` al pivot de roles (`v3-rbac-multirole`). Acá sólo tienen que funcionar con el claim correcto.
- **No** se hace el barrido manual de `account_id` en los 24 repositories (Opción B — descartada por el PO). Si el inventario del paso 2 encuentra una consulta sin filtro, la policy la frena: ése es justamente el punto.
- **No** se cambia el modo de pooling, ni el puerto, ni la cadena de conexión, ni se crea un rol de login nuevo (ver D6).
- **No** se toca el hook de claims (`v31-authz-token-hook`, en paralelo).
- **No** se refactoriza el camino de servicio más allá de aislarlo explícitamente.

## Decisions

### D1 — Una transacción explícita por request, con claims de alcance transaccional

`get_db_conn` pasa a:

1. adquirir conexión del pool,
2. abrir una transacción explícita,
3. setear `request.jwt.claims` con `set_config(..., true)` (alcance de transacción),
4. `yield` la conexión,
5. commit al terminar el request; rollback ante excepción.

Con la transacción abierta, Supavisor pinea la conexión física de servidor hasta el `COMMIT`: los claims y las queries de negocio **están garantizadamente en la misma conexión**. El `is_local = true` hace que el GUC se deshaga solo al cerrar, así que la conexión vuelve al pool sin residuo de un usuario para el siguiente.

**Alternativa descartada — bajar al session pooler (puerto 5432).** Resolvería el problema de raíz (una conexión física por cliente durante toda su vida), pero recorta drásticamente el techo de conexiones concurrentes. Cambiar la topología de conexión para evitar escribir `BEGIN` es pagar capacidad de crecimiento por no escribir cuatro líneas.

**Alternativa descartada — enviar los claims en cada query** (como parámetro de cada llamada a RPC). Requiere tocar los 24 repositories y los 68 RPCs, y deja fuera cualquier query que alguien escriba mañana. Es Opción B con otro nombre.

**Alternativa descartada — `statement_timeout` / reintentos.** Trata el síntoma intermitente de K5 sin tocar la causa.

### D2 — `app.jwt_claims` se elimina

Cero lectores en todo el repositorio (verificado). Mantenerlo cuesta la mitad del payload de cada request y, sobre todo, **cuesta credibilidad**: un GUC que el código dice que las policies leen y que ninguna policy lee es documentación mintiendo dentro del código fuente. Se elimina, se corrige el comentario, y `test_database.py` pasa a afirmar el contrato real.

Antes de eliminarlo, el barrido se re-ejecuta como tarea explícita (migraciones + backend + frontend + edge functions), porque un lector olvidado convertiría esta limpieza en una regresión silenciosa.

### D3 — Atomicidad por request: el cambio de comportamiento que hay que mirar de frente

Hoy los 9 bloques `async with conn.transaction()` de los repositories son transacciones **de nivel superior**: cuando comitean, su trabajo es durable de inmediato. Con una transacción externa abierta, asyncpg los convierte en **savepoints**.

Consecuencia real: si un request escribe algo (que hoy queda comiteado) y **después** falla en otro punto, con el cambio ese trabajo se deshace junto con el request.

Esto es **más correcto** — un request es una unidad de trabajo, y DEC-24 ya declara que la transaccionalidad vive en Postgres — pero es un cambio de comportamiento con dinero de por medio, y merece verificación explícita en lugar de asumirse benigno. Tarea dedicada: un test que ejercita un request que escribe y luego falla, y afirma que **no** queda trabajo parcial.

Punto que **no** cambia: los RPCs `SECURITY DEFINER` siguen siendo la unidad de trabajo de negocio. Una transacción externa no rompe su atomicidad; la envuelve.

### D4 — Protección contra transacciones colgadas

Una transacción abierta durante todo el request significa que un request lento retiene una conexión física **y** una transacción. Postgres castiga las transacciones ociosas con bloat de vacuum y locks retenidos.

Mitigación dentro de la misma transacción: `idle_in_transaction_session_timeout` con alcance transaccional, de modo que una transacción que se quede esperando sea abortada por la base en vez de acumularse.

Auditoría de E/S externa dentro del request (hecha, no supuesta):
- **Emisión de CAE a AFIP (SOAP, lento)**: corre en una tarea en segundo plano **con su propia conexión de servicio**, después de que la respuesta se envió. **No** queda dentro de la transacción del request. Verificado en `backend/services/fiscal/fiscal_profile_service.py`.
- **Webhook de MercadoPago**: usa el camino de servicio, que no se envuelve (D5).
- **Generación de URL firmada de Storage**: un endpoint, marcado `deprecated`, operación corta.

No se encontró ningún endpoint que haga una llamada externa lenta reteniendo la conexión del request. Igual se instrumenta el timeout, porque el próximo endpoint que lo haga no va a avisar.

### D5 — El camino de servicio queda explícitamente afuera

`get_service_conn` (webhook de pagos, relay CAE del cron) y el `pool.acquire()` directo de la tarea en segundo plano **no inyectan claims** y **no deben** quedar dentro de una transacción de request: son operaciones de máquina, cross-account por diseño, y en el caso del webhook, dinero real.

Se dejan intactos en el paso 1 y se documentan como camino separado en la capability `python-backend`. Que hoy compartan el mismo pool es un detalle de implementación aceptable mientras el rol de login siga siendo el mismo; el paso 2 lo vuelve una distinción **semántica** (ver D6), no sólo de convención.

Los stubs `init_service_pool` / `close_service_pool` (hoy no-op) se conservan como la costura donde separar los pools si alguna vez hiciera falta. No se activan acá.

### D6 — Paso 2: cambio de rol **por transacción** a `authenticated`, no un rol de login nuevo

Dentro de la misma transacción del paso 1, y antes de ejecutar nada de negocio, el rol efectivo pasa a `authenticated` con alcance transaccional.

**Por qué funciona.** Postgres evalúa BYPASSRLS sobre el rol **actual**, no sobre el rol de login. Con el rol actual en `authenticated` (`rolbypassrls = false`, verificado) las policies se evalúan. Y `authenticated` es precisamente el rol para el que **están escritas las 49 migraciones de policies** y los `GRANT EXECUTE` de los helpers — es el rol que el camino navegador→PostgREST ya usa contra las mismas tablas. No se escribe seguridad nueva: se deja de ignorar la que existe.

**Por qué NO `ALTER ROLE postgres NOBYPASSRLS`.** Tres consumidores dependen de BYPASSRLS para operar sin JWT de usuario: el **webhook de pagos** (dinero real), el **endpoint de relay CAE del cron**, y la **tarea en segundo plano de CAE**. Quitarle BYPASSRLS al rol de login los rompe a los tres simultáneamente, y son justamente los caminos donde un fallo silencioso es más caro. El cambio por transacción los deja intactos por construcción: quien no cambia de rol, sigue siendo `postgres`.

**Por qué NO un rol de login dedicado** (`app_request` con credenciales propias y cadena de conexión distinta). Es la opción que el brief del PO anticipaba y tiene una ventaja real —**falla cerrado**: si un camino de código olvidara el cambio de rol, con un rol de login restringido igual quedaría sin BYPASSRLS. Se descarta como opción **primaria** por tres razones concretas: (i) obliga a replicar y mantener a mano los GRANTs que `authenticated` ya tiene sobre 68 tablas y 68 funciones; (ii) obliga a separar los pools el mismo día del corte, porque el camino de servicio necesita seguir bypaseando; (iii) el formato de usuario que Supavisor acepta para roles no estándar debe verificarse contra el plan contratado antes de comprometerse — incertidumbre de infraestructura en el punto más crítico. **Resuelto por el PO el 2026-07-31 (OQ-2)**: el rol de login dedicado se planifica como **Paso 3 FUTURO**, sobre un paso 2 ya estabilizado, y **no se ejecuta en este change**. La garantía de fallar cerrado se obtiene después, sin apostar en el mismo corte las dos incertidumbres de infraestructura.

**Mitigación del "falla abierto"** (el trade-off honesto de esta decisión): el cambio de rol y la inyección de claims ocurren **en el mismo lugar y en la misma transacción** — no pueden divergir sin que un test lo note. Se agrega una verificación que afirma, desde dentro de un request real, que el usuario efectivo de la sesión **no** es el rol con BYPASSRLS.

### D7 — Antes del corte: inventario de escrituras directas contra la matriz de policies

**40 de las 68 tablas con RLS tienen policy de SELECT y ninguna de escritura.** Con BYPASSRLS eso no importa; sin él, toda escritura directa a esas tablas se rechaza.

La mayor parte de las escrituras de negocio pasa por los 68 RPCs `SECURITY DEFINER`, que corren como su dueño y **no** se ven afectados (66 de 68 ya tienen `EXECUTE` para `authenticated`; los 2 restantes son parte del inventario). Pero los repositories **también escriben directo**: 15 tablas con `INSERT INTO` y ~13 con `UPDATE`.

Un cruce preliminar ya identifica al menos cuatro colisiones reales:

| Tabla | Escritura directa | Policy de escritura |
|---|---|---|
| `fiscal_documents` | 4 × UPDATE | **0 de UPDATE** |
| `cashboxes` | 1 × UPDATE | **0 de UPDATE** |
| `events` | INSERT | **0 de INSERT** |
| `email_logs` | INSERT | **0 de INSERT** |

(La deuda de `bank_accounts`/`cashboxes` sin policy de UPDATE ya estaba anotada desde `v3-soft-delete-policy`; acá deja de ser deuda anotada y pasa a ser bloqueante.)

El inventario completo es una tarea del paso 2. **Criterio fijado por el PO el 2026-07-31 (OQ-3): el RPC `SECURITY DEFINER` es la vía por defecto**, coherente con DEC-24. Agregar la policy de escritura faltante queda como **excepción**, admisible para tablas de infraestructura donde el predicado de tenencia es trivial y la escritura no tiene invariantes de negocio — y cada excepción se justifica por escrito en el inventario. Los **casos sensibles (`fiscal_documents` y `cashboxes`) se elevan al PO uno a uno ANTES de aplicar** su resolución.

Con eso, la pregunta del inventario deja de ser "¿RPC o policy?" tabla por tabla y pasa a ser "¿hay una razón para **no** usar RPC acá?" — una decisión con carga de la prueba invertida y mucho más barata de revisar. Lo que **no** es aceptable es descubrir la colisión el día del corte.

Este inventario es la razón principal por la que el paso 2 es L y no una línea de configuración.

### D8 — Palanca de rollout por variable de entorno, un paso a la vez

Cada paso queda detrás de su propia variable de entorno en Render, **apagada por defecto al mergear**:

- El merge despliega código inerte: nada cambia hasta encender.
- Encender y apagar es un cambio de configuración con reinicio (~50 s), sin rebuild ni redeploy — la reversión más rápida disponible.
- Los dos pasos se encienden por separado: se puede tener el paso 1 activo y el 2 apagado, que es exactamente el estado de observación que el PO firmó.

Coste asumido: dos caminos de código conviviendo mientras dure la transición, y tests que cubren ambos. Se retiran las palancas (y el camino viejo) en un change de limpieza posterior, una vez que el paso 2 lleve tiempo estable.

**Alternativa descartada — desplegar sin palanca y revertir con `git revert`.** Funciona, pero el rollback pasa por rebuild + redeploy en el peor momento posible (producción con síntomas). Una variable de entorno es un orden de magnitud más rápida y no depende de que el pipeline esté sano.

### "Probado bajo carga" — definición operacional

El proyecto **no tiene infraestructura de load testing** y no se va a inventar una para este change. La definición es deliberadamente humilde y verificable con lo que hay:

**El paso 2 no se ejecuta hasta que se cumplan las cinco condiciones:**

1. **Suite backend completa verde dos veces seguidas** con el paso 1 activo, incluidos los tests nuevos de alcance transaccional y de atomicidad por request.
2. **Prueba de concurrencia cross-tenant** (barata, reproducible, sin infraestructura nueva): un script con `asyncio` + `httpx` (ya en el proyecto) que dispara al menos 50 requests concurrentes intercalando **dos usuarios de cuentas distintas** contra endpoints de lectura, y afirma que **ninguna respuesta contiene datos de la otra cuenta** y que ninguna falla por claims ausentes. Es la prueba que ataca directamente el modo de fallo que importa (claims cruzados entre conexiones recicladas). Se ejecuta contra el entorno desplegado, no contra mocks.
3. **7 días naturales corridos de operación real** con el paso 1 activo, que incluyan al menos **dos cierres de caja** y un día de actividad alta. Se registra el volumen real de requests del período **como número observado**, no contra un umbral inventado. *(Ventana confirmada por el PO el 2026-07-31 — OQ-1.)*
4. **Los cuatro contadores en cero durante esos 7 días**: cero ocurrencias del 500 intermitente de compras (K5), cero `idle_in_transaction_session_timeout`, cero 403 anómalos de "cuenta no encontrada" (el síntoma de claims ausentes), cero errores de transacción abortada en los logs de Render. **Un solo evento reinicia la ventana de 7 días**; no la acorta ni se compensa con más volumen.
5. **Sign-off explícito del PO** para ejecutar el paso 2, con el inventario de D7 ya resuelto y a la vista.

Si alguna condición falla, el paso 1 se apaga con la palanca y el paso 2 no se discute hasta entender por qué.

## Risks / Trade-offs

- **Fail-open cross-tenant por un error en el alcance transaccional** → El riesgo peor y el que justifica los dos pasos. Mitigado por: alcance transaccional (que se deshace solo, en vez de persistir), la prueba de concurrencia con dos cuentas (condición 2), los 7 días de observación **antes** de que la RLS dependa de esto, y la palanca de apagado. Nótese la asimetría a favor: mientras el paso 2 no esté activo, un error de claims produce **menos** acceso (403/0 filas), no más.
- **Un request lento retiene una transacción abierta** → `idle_in_transaction_session_timeout` transaccional (D4) + auditoría de E/S externa dentro del request (hecha: la llamada lenta a AFIP ya corre fuera del request con su propia conexión).
- **La atomicidad por request deshace trabajo que hoy quedaba comiteado** → D3. Cambio deliberado, con test dedicado. Es el riesgo con más probabilidad de sorprender a alguien en producción, y el menos peligroso: se manifiesta como "no se guardó", no como "se guardó mal".
- **El paso 2 rompe escrituras directas contra las 40 tablas sin policy de escritura** → D7. Mitigado por el inventario **antes** del corte, no por la suite. La suite usa repositories mockeados en buena parte, así que **no** es una red confiable acá: hay que cruzar código contra `pg_policies`.
- **`SET LOCAL ROLE` no se comporta como se espera bajo Supavisor** → Es la hipótesis técnica central. Se prueba en el paso 1 (donde el fallo es visible pero inofensivo: claims ausentes → 403, no fuga) antes de que el paso 2 dependa de ella. Si resulta falsa, el paso 2 se replantea con el rol de login dedicado (OQ-2) o se recurre a Opción B.
- **El cambio de rol por transacción falla abierto si un camino lo omite** → D6, trade-off explícito. Mitigado porque rol y claims se setean juntos, más una verificación que afirma el usuario efectivo desde dentro de un request. OQ-2 ofrece la alternativa que falla cerrado.
- **Los tests actuales afirman el comportamiento defectuoso** — `test_database.py` verifica literalmente `query.count(", false)") == 2` y la presencia de `app.jwt_claims`. Es un test que **protege el bug**. Se reescribe como parte del paso 1 (RED antes que GREEN), no se borra en silencio.
- **La capability `asyncpg-pool` documenta algo que el código nunca hizo** (dice `SET LOCAL app.jwt_claims`; el código usa alcance de sesión y ese GUC no lo lee nadie). Riesgo de repetir el patrón: escribir un spec aspiracional. Mitigado exigiendo que la verificación del paso 1 observe el comportamiento **contra una base real**, no contra un mock que confirme lo que ya se cree.
- **Dos pasos = dos ventanas de riesgo y dos sign-offs** → Aceptado explícitamente por el PO. La alternativa (un big bang) concentra todo el riesgo en un solo despliegue sobre el código por el que pasa el 100% del backend.

## Migration Plan

**Paso 1**

1. Código + tests + palanca; merge a `main` con la palanca **apagada**. Producción no cambia.
2. Encender la palanca en Render (decisión del PO). Verificar de inmediato: un request real llega con claims (endpoint de salud/diagnóstico), compras responde 200.
3. Observación de 7 días con los cuatro contadores de la condición 4.
4. Ejecutar la prueba de concurrencia cross-tenant (condición 2) contra el entorno desplegado.

*Rollback paso 1*: apagar la variable de entorno (reinicio, sin rebuild). Si además hay que revertir el código, `git revert` del PR. **Sin migración, sin datos que reparar.**

**Paso 2** (sólo tras las cinco condiciones + sign-off)

5. Inventario de escrituras directas contra `pg_policies` (D7) y resolución de cada colisión, **con el RPC como vía por defecto** y cada excepción justificada por escrito. `fiscal_documents` y `cashboxes` se elevan al PO **antes** de aplicar su resolución. Si aparecen policies faltantes, van en una migración idempotente propia.
6. Encender la palanca del paso 2 en un horario de baja actividad, con el PO presente y **sin anuncio a los usuarios** (OQ-4). Precondición no negociable del deploy silencioso: el **rollback ya preparado y verificado** — palanca identificada, procedimiento de apagado escrito, y alguien con acceso a Render listo para ejecutarlo durante toda la verificación del punto 7. **Si el rollback no está listo, el corte no se hace**: sin anuncio previo, el rollback es la única mitigación que queda.
7. Verificación inmediata: el usuario efectivo dentro de un request **no** es el rol con BYPASSRLS; un smoke E2E de las operaciones críticas (venta, compra, cobro, cierre de caja, emisión de comprobante); la prueba de concurrencia cross-tenant repetida — ahora con la RLS activa, que es donde su resultado realmente significa algo.
8. Observación 48 h con atención específica a errores de permiso denegado (el síntoma de una colisión no inventariada).

*Rollback paso 2*: apagar la variable (vuelve a `postgres` con BYPASSRLS = estado actual, no peor). Las policies agregadas en el punto 5 son aditivas y pueden quedarse.

**Recién después del paso 2** DEC-13 / KB-08 pasan a describir el sistema real, y `v3-rbac-multirole` puede migrar `is_account_writer` sabiendo que migrarlo cambia algo.

## Amendment 2026-08-01 — revisión de los 9 call sites de `.transaction()` (tasks.md 3.4)

Aplicado el Paso 1 (grupos 1-4), se revisó uno por uno cada `async with self._conn.transaction()` de `backend/repositories/` para confirmar que promoverlo de transacción de nivel superior a SAVEPOINT (D3) no altera ninguna expectativa del código que lo rodea:

| # | Call site | Patrón | ¿Camino? | ¿Traga su propia excepción y continúa? | Veredicto |
|---|---|---|---|---|---|
| 1 | `fiscal_document_repository.py:61` (`update_authorized`) | UPDATE status + `rpc_record_fiscal_transition` en el mismo bloque | **Servicio** (único caller: `cae_relay_processor.py` vía `get_service_conn`) | No | Seguro — D3 **no aplica**: `get_service_conn` nunca se envuelve (D5), este `.transaction()` sigue siendo de nivel superior siempre, con o sin la palanca |
| 2 | `fiscal_document_repository.py:88` (`update_rejected`) | Ídem, UPDATE + historial | **Servicio** (mismo caller) | No | Ídem #1 — D3 no aplica |
| 3 | `product_repository.py:57` (`create`) | INSERT + RPC de stock inicial en branch_stock | Request (`products.py` vía `get_db_conn`) | No | Seguro — D3 aplica, se promueve a SAVEPOINT |
| 4 | `purchase_repository.py:89` (`delete_by_id`) | `return False` temprano si no existe, ANTES de cualquier escritura | Request (`purchases.py`) | No | Seguro (el early-return no pierde nada: no había nada escrito todavía) |
| 5 | `purchase_repository.py:140` (`delete_by_operation`) | Ídem, `return False` temprano | Request | No | Seguro |
| 6 | `purchase_repository.py:281` (creación con idempotencia) | Hit de idempotencia retorna ANTES de abrir la transacción; si no, RPC de creación + evento outbox (DEC-20) en el mismo bloque | Request | No | Seguro |
| 7 | `sales_repository.py:87` (`delete_by_id`) | Espejo de #4 | Request (`sales.py`) | No | Seguro |
| 8 | `sales_repository.py:137` (`delete_by_operation`) | Espejo de #5 | Request | No | Seguro |
| 9 | `stock_repository.py:76` (`adjust_with_event`) | RPC de ajuste de stock + evento outbox (DEC-20) en el mismo bloque | Request (`stock.py`) | No | Seguro |

**Hallazgo común**: de los 9 call sites, **2 (#1, #2) corren exclusivamente por el camino de servicio** (`get_service_conn`, D5) — nunca se envuelven en la transacción del Paso 1, así que D3 no les aplica en absoluto: siguen siendo transacciones de nivel superior, igual que hoy, con la palanca en cualquier posición. Los otros **7 corren por el camino de request** (`get_db_conn`) y sí se promueven a SAVEPOINT cuando la palanca está encendida. Ninguno de los 9, en ningún camino, atrapa una excepción lanzada DENTRO de su propio `.transaction()` para tragarla y continuar asumiendo que ese trabajo ya quedó comiteado de forma independiente — o bien completan el bloque entero, o dejan que la excepción se propague al caller. Ese es el caso seguro para la promoción a SAVEPOINT de los 7: su atomicidad *interna* no cambia; sólo cambia que su durabilidad queda atada al COMMIT final del request (D3), el comportamiento deliberado que este change introduce. No se encontró ningún caso dudoso que requeriría elevarse antes de continuar.

### Amendment 2026-08-01 — inventario de escrituras directas (tasks.md 6.1-6.3, preparación — SIN aplicar resoluciones)

Inventario completo, cruzado contra `pg_policies` de prod (`gxdhpxvdjjkmxhdkkwyb`, read-only vía MCP). **Sólo lectura — ninguna resolución de este inventario se aplicó**, conforme al gate del grupo 5/6 y a que los casos sensibles requieren decisión previa del PO (OQ-3).

**Números re-verificados (tasks.md 1.3) — una precisión sobre design.md §Context:**
- `postgres.rolbypassrls=true`, `authenticated.rolbypassrls=false` — coincide.
- 68 tablas en `public`, 0 sin RLS — coincide.
- Funciones `rpc_*`: 68 (dos overloads: `rpc_invite_member`, `rpc_safe_delete_product`), 66 con `EXECUTE` para `authenticated`, 67 `SECURITY DEFINER` — coincide exactamente.
- **"68/68 con SELECT para authenticated" — impreciso en 1: son 67/68.** La única excepción es `platform_wsaa_tickets` (RLS activa, **CERO policies** — ni siquiera SELECT). No es un defecto: es una tabla de caché de tickets WSAA de plataforma (H-26/H-27, `CHANGES.md`), y el código que la usa (`backend/services/fiscal/wsaa_ticket_cache.py`) **no pasa por el pool asyncpg en absoluto** — usa el cliente REST de Supabase Admin con `service_role_key`. No es una colisión de este change (nunca pasa por `get_db_conn` ni `get_service_conn`), pero es la explicación real del número, no un error del diseño original.
- **"40 tablas con RLS y sin policy de escritura" — coincide, con la definición correcta: tablas a las que les falta AL MENOS UNO de {INSERT, UPDATE, DELETE}** (una policy `ALL` cuenta como las tres). Con la definición más estricta ("cero policies de escritura de cualquier tipo") son 25, más `platform_wsaa_tickets` = 26 sin ninguna. Los 14 restantes tienen cobertura parcial (p.ej. `accounts` tiene UPDATE pero no INSERT/DELETE).

**Escrituras directas confirmadas (`backend/repositories/*.py`, sin pasar por RPC `SECURITY DEFINER`), cruzadas contra la policy de escritura real:**

| Tabla | Escritura directa (archivo:línea) | Policy de escritura en prod | Colisión |
|---|---|---|---|
| `fiscal_documents` | 4× UPDATE (`fiscal_document_repository.py:64,91,131,194`) | 0 (sólo INSERT+SELECT) | **SÍ — sensible, elevar al PO (OQ-3)** |
| `cashboxes` | 1× UPDATE (`cashbox_repository.py:32`) | 0 (sólo INSERT+SELECT) | **SÍ — sensible, elevar al PO (OQ-3)** |
| `events` | 1× INSERT (`outbox_repository.py:179`) | 0 (sólo SELECT) | SÍ — candidata a excepción justificada (tabla de outbox, sin invariantes de negocio de usuario) |
| `email_logs` | 1× INSERT (`outbox_repository.py:114`) | 0 (sólo SELECT) | SÍ — candidata a excepción justificada (log técnico de envíos) |
| **`stock_movements`** | 4× DELETE (`purchase_repository.py:123,170`, `sales_repository.py:120,165`) | Policy DELETE **y** UPDATE existen, pero con `qual = false` (`stock_movements_no_delete`, `stock_movements_no_update`) — **deny explícito, a propósito**: es un ledger append-only por diseño | **SÍ — hallazgo NUEVO, no estaba en la lista preliminar de design.md. Más grave que "falta policy": hay una policy que PROHÍBE la escritura a propósito, y el backend la hace directo hoy (enmascarado por BYPASSRLS). Elevar al PO junto con `fiscal_documents`/`cashboxes` — la resolución por defecto (RPC) acá no es mecánica: el RPC tendría que decidir si preserva la inmutabilidad (insertar un movimiento compensatorio en vez de borrar) o si la policy debe relajarse. Es una decisión de modelo, no sólo de plomería** |

Todas las demás tablas con escritura directa (`branches`, `cost_centers`, `client_addresses`, `clients`, `fiscal_profiles`, `expenses`, `audit_logs`, `operation_idempotency`, `products`, `quotes`/`quote_items`, `purchases`, `sales`, `points_of_sale`) tienen policy real (no `qual=false`) para cada cmd que el backend efectivamente ejecuta contra ellas — sin colisión.

**Hallazgo aparte, no relacionado con RLS (no requiere resolución de este change, pero se deja registrado):** `backend/repositories/organization_repository.py` (usado por `backend/routers/organizations.py`) hace `SELECT`/`UPDATE` contra una tabla `organizations` que **no existe en prod** (sólo existe `companies`). Esto rompe con `UndefinedTableError` HOY, con o sin RLS/BYPASSRLS — no es un hallazgo de este change, es código muerto/roto preexistente. Se deja fuera de alcance; ver spawn_task del apply.

**Cierre del inventario**: 4 colisiones confirmadas (`fiscal_documents`, `cashboxes`, `events`, `email_logs`) + 1 colisión nueva más severa (`stock_movements`, deny explícito). **`fiscal_documents`, `cashboxes` y `stock_movements` se elevan al PO uno a uno antes de aplicar cualquier resolución** (OQ-3, extendido a `stock_movements` por el mismo criterio de "sensible"). `events`/`email_logs` son candidatas razonables a excepción-de-policy (tablas de infraestructura, sin invariantes de negocio de usuario) pero **tampoco se resuelven en este apply** — quedan para cuando el grupo 6 se ejecute de verdad, después del gate del grupo 5.

### Resolución (2026-08-01, sign-off del PO sobre las 3 colisiones sensibles)

El PO firmó las 3 resoluciones el mismo día, antes de escribir código (gate de este change para colisiones sensibles):

- **`fiscal_documents`**: los 4 UPDATE → 4 RPCs `SECURITY DEFINER` dedicadas (`rpc_fiscal_document_authorize`/`reject`/`retry`/`claim_pending`). La tabla queda sin escritura directa del backend. `rpc_fiscal_document_authorize`/`reject` encapsulan también la llamada (antes condicional en Python) a `rpc_record_fiscal_transition`.
- **`cashboxes`**: el UPDATE → `rpc_soft_delete_cashbox`, con el mismo check `is_account_writer` que ya usa `cashboxes_insert`.
- **`stock_movements`**: los 4 DELETE de reversa → `rpc_reverse_stock_movement`, que resuelve el trade-off señalado arriba a favor de **preservar la inmutabilidad**: inserta el movimiento opuesto (`type` `purchase_return`/`sale_return`, ya permitidos por el CHECK de `type` desde antes de este change) con `metadata.reverses_movement_id` apuntando al original, que permanece — la policy `qual=false` NO se relaja (sigue prohibiendo la escritura directa para siempre; la RPC es `SECURITY DEFINER`, corre como el dueño, no le aplica la policy). **Cambio de comportamiento visible, deliberado**: el historial de stock ya no "olvida" un movimiento anulado — aparece el contramovimiento. El efecto neto sobre `branch_stock` es idéntico (misma aritmética que antes, delegada a `rpc_apply_product_stock_delta`; probado en el gate SQL stock-c).

Implementado en `supabase/migrations/20260828000001_v31_rls_collision_rpcs.sql` (6 RPCs + 2 policies de INSERT para `events`/`email_logs` + CHECK ampliado de `stock_movements.reference_type`), con gates SQL estructurales (ACL: `authenticated` sí, `anon` no — igual que el resto del proyecto) y de comportamiento (DB vacía/CI). Repositories Python (`fiscal_document_repository.py`, `cashbox_repository.py`, `purchase_repository.py`, `sales_repository.py`) actualizados para llamar las RPCs; tests de contrato reescritos donde la arquitectura interna (antes visible al mock de Python) pasó a vivir dentro de la RPC.

**Solapamiento con `v31-sales-delete-rpc-reversal` (H-10, `CHANGES.md`)**: resuelto — este apply sólo cierra la colisión RLS puntual de `stock_movements` (compensación en vez de DELETE, sin tocar la escritura directa de `sales`/`purchases`/`operation_idempotency`, que no tenían colisión). La arquitectura completa "borrado de venta/compra = un solo RPC-as-UoW" que H-10 propone queda íntegra para cuando se proponga ese change — ver la nota cruzada agregada en `CHANGES.md`.

Cobertura de test: `backend/tests/test_tenancy_tx_atomicity.py` prueba el mecanismo de anidamiento (SAVEPOINT bajo transacción externa) con un doble de conexión (`FakeTxConnection`) que sí modela la semántica BEGIN/SAVEPOINT/RELEASE/ROLLBACK — un mock de `unittest.mock` no puede reproducirla. No sustituye una prueba de integración contra Postgres real (fuera de alcance del Paso 1).

### Amendment 2026-08-23 — grupo 7 implementado (D6) + verificación de precondiciones contra prod

> **Orden explícita del PO 2026-08-23**: implementar el grupo 7 (adopción del rol) y 8.0 (rollback preparado) detrás de palancas apagadas — merge inerte. **8.1+ (encender en Render) sigue siendo del PO.** El gate del grupo 5 ("probado bajo carga") no se re-litiga acá: sigue exactamente igual de pendiente que el 2026-08-01 (ventana de 7 días no arrancada, condición 5.5 sin sign-off) — este amendment documenta código + verificación de precondiciones, no un cierre del gate.

**Implementación (D6)**: `backend/core/config.py` gana `tenancy_rls_role_enabled: bool = False`, con un `model_validator` que **falla explícito al construir `Settings()`** (arranque del proceso) si `tenancy_rls_role_enabled=True` y `tenancy_tx_scope_enabled=False` — la única de las 4 combinaciones inválida por diseño (tasks.md 7.5), verificada en las 4 (`backend/tests/test_config_tenancy_rls.py` + la suite completa corrida a mano en las 3 válidas). `backend/core/database.py::get_db_conn` ejecuta, dentro de la MISMA transacción del Paso 1 e inmediatamente después de `set_config('request.jwt.claims', ...)`, el statement literal `SET LOCAL ROLE authenticated` — no `SET ROLE` de sesión. `get_service_conn` (D5) no se toca: sigue sin abrir transacción, sin claims y sin cambio de rol bajo ninguna combinación de palancas (`test_get_service_conn_step2_never_adopts_role_even_with_both_flags_on`).

**Hallazgo nuevo sobre el mecanismo (no invalida D6, lo precisa)**: `pg_roles.rolsuper` de `postgres` en este proyecto es **`false`** — no es superusuario, al revés de lo que D6 asumía implícitamente ("un superusuario puede SET ROLE a cualquier rol"). Verificado en su lugar (`pg_auth_members`, read-only, prod): `postgres` es **miembro** de `authenticated` con `admin_option=true, inherit_option=true` — la vía real por la que `SET LOCAL ROLE authenticated` funciona en Supabase gestionado. Mecánicamente equivalente para este change (el `SET ROLE` igual tiene éxito), pero la explicación correcta es membership, no superusuario — corregido en el docstring de `get_db_conn`.

**Verificación de precondiciones (read-only, MCP, prod `gxdhpxvdjjkmxhdkkwyb`, 2026-08-23)** — las 3 que tasks.md 7 pide antes de que el corte sea seguro:

1. **GRANTs de tabla para `authenticated`**: las 68 tablas de `public` tienen SELECT/INSERT/UPDATE/DELETE otorgados a `authenticated` — **sin excepción**. Cero gaps de ACL (distinto de gap de *policy*, ver 2).
2. **Policies de escritura vs. escrituras directas reales**: re-grepeado `backend/repositories/*.py` en busca de `INSERT INTO`/`UPDATE`/`DELETE FROM` directos (no vía RPC) — la lista creció desde el inventario original de 6.1 (se sumaron `quotes`/`quote_items`, `subscriptions`/`subscription_intents`, `payment_methods`, `points_of_sale`, `cashboxes` INSERT) porque el proyecto siguió avanzando desde 2026-08-01. **Cero colisiones nuevas**: cada escritura directa real tiene su policy (`quotes`/`quote_items` vía `roles={public}` — el chequeo original de pg_policies por `'authenticated' = ANY(roles)` tiene un falso negativo si la policy es `{public}`, corregido acá con `roles && ARRAY['authenticated','public']`). El único caso que a primera vista parecía un gap nuevo — `subscriptions`/`subscription_intents`, con policy de sólo-SELECT — resultó ser exclusivamente camino de servicio: `SubscriptionsRepository` sólo se instancia en `backend/routers/payments.py` sobre `Depends(get_service_conn)`, nunca sobre `get_db_conn` — mismo patrón D5 que el webhook de pagos, fuera del alcance de la adopción de rol por construcción, no por suerte.
3. **`EXECUTE` de RPCs para `authenticated`**: de ~54 nombres `rpc_*` reales invocados desde `backend/` (excluidos 5 falsos positivos que son nombres de variable en tests, p.ej. `rpc_calls`), **51 tienen EXECUTE**. Los 3 sin EXECUTE son exactamente los ya conocidos + uno nuevo, los tres confirmados fuera de alcance: `rpc_record_fiscal_transition` y `rpc_trigger_cae_relay` (servicio, ya documentados 2026-08-01) + **`rpc_process_outbox_dispatch`** (hallazgo nuevo: no lo llama ningún router/service Python — lo invoca `pg_cron` directo en el body del job, nunca pasa por el pool asyncpg de ningún camino, ni request ni servicio).

**Cierre**: cero gaps que resolver antes del corte, con los datos disponibles hoy. Esto no reemplaza el inventario vivo de 6.6 ni el gate del grupo 5 — es una foto re-verificada del mismo territorio, tomada 3 semanas después, que no encontró divergencias nuevas pese a desarrollo activo en el medio.

**Gate SQL nuevo** (`supabase/tests/test_tenancy_rls_role.sql`, registrado en `KPI_Validation.yml`): reproduce el mecanismo de `get_db_conn` con ambas palancas encendidas (`SET LOCAL ROLE authenticated` + claims) contra Postgres real, en los 3 dominios de escritura que tasks.md 7.4 pide (productos, caja, ventas) — con y sin el filtro de `account_id` que ya usan los repositories (7.3c). Verificado con un control negativo local (RLS deshabilitada a propósito en `products`): el gate detecta la fuga y aborta con exit≠0 — no es un gate que pase en falso. En el stack local de CI (`supabase start`) el gate degrada por el mismo límite ya documentado en `test_payment_methods_catalog.sql` (6): el entorno no replica el GRANT base de `authenticated` que sí existe en prod (verificado con un GRANT temporal local, no persistido: con el grant presente, el gate corre en verde de punta a punta contra datos reales).

## Open Questions

**Las cuatro OQ del propose quedaron resueltas por el sign-off del PO del 2026-07-31.** Se conservan con su resolución para que el apply no las re-litigue.

- **OQ-1 — período de observación del paso 1 → RESUELTA: 7 días naturales con los cuatro contadores en cero.** Se confirma la condición 3 tal como está redactada (7 días corridos, al menos dos cierres de caja, un día de actividad alta) junto con la condición 4 (cero K5, cero `idle_in_transaction_session_timeout`, cero 403 anómalos de "cuenta no encontrada", cero errores de transacción abortada). **Los cuatro contadores tienen que estar en cero durante los siete días**: un solo evento reinicia la ventana, no la acorta. No se sustituye el criterio temporal por un umbral de volumen.
- **OQ-2 — rol de login dedicado → RESUELTA: opción (b), un Paso 3 FUTURO.** Se planifica **después** de estabilizar el paso 2, y **no se ejecuta en este change**. El cambio de rol por transacción (D6) queda como la implementación del paso 2; la garantía de fallar cerrado se obtiene más adelante, sobre un paso 2 ya probado, sin apostar las dos incertidumbres (alcance transaccional del `SET LOCAL ROLE` + formato de usuario que acepta Supavisor para roles no estándar) en el mismo corte. El paso 3 no forma parte del alcance ni de las tareas de este change; se registra como trabajo posterior.
- **OQ-3 — colisiones de D7: ¿RPC o policy? → RESUELTA: RPC por defecto (DEC-24).** El criterio queda fijado: **encaminar la escritura por un RPC `SECURITY DEFINER` es la opción por defecto**, coherente con DEC-24 (la unidad de trabajo transaccional del proyecto son los RPCs). Agregar la policy queda como excepción justificada caso por caso. Los **casos sensibles** —`fiscal_documents` y `cashboxes`— **se elevan al PO uno a uno ANTES de aplicar** cualquier resolución, no se deciden dentro del inventario. Esto acota el inventario del paso 2: la pregunta deja de ser "¿RPC o policy?" para cada tabla y pasa a ser "¿hay una razón para no usar RPC acá?".
- **OQ-4 — corte del paso 2 → RESUELTA: deploy silencioso, sin anuncio.** Decisión explícita del PO: **no** se anuncia una ventana horaria a los usuarios. El corte se hace en baja actividad con el PO presente y con el **rollback inmediato preparado de antemano** — es decir, la palanca del paso 2 identificada, el procedimiento de apagado escrito y probado, y alguien con acceso a Render listo para ejecutarlo mientras dura la verificación del punto 7 del plan de migración. La ausencia de anuncio traslada todo el peso de la mitigación al rollback: si el rollback no está listo y verificado, el corte no se hace.
