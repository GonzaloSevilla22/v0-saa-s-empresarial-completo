## Why

La KB de este proyecto (DEC-13, `knowledge-base/08_arquitectura_propuesta.md`) afirma que el backend Python usa **JWT-passthrough** para que la RLS org-based siga activa "como red de seguridad". La auditoría 2026-07-07 (H-05) y la exploración del 2026-07-30 confirmaron que esa afirmación es **falsa en dos niveles independientes**, y ambos siguen sin remediar:

1. **El pool conecta como `postgres`, que tiene `rolbypassrls = true`** (verificado en prod). Con BYPASSRLS, Postgres **ni siquiera evalúa** las policies. Las 49 migraciones que escriben policies sobre `is_account_writer` / `current_account_ids` no protegen nada del lado del backend: el único aislamiento real hoy es el `WHERE account_id = $N` que cada repository recuerde poner.
2. **Los claims se inyectan con `set_config(..., false)` y sin transacción explícita** (`backend/core/database.py:52-60`). `is_local = false` es scope de **sesión**. Bajo Supavisor en *transaction mode*, un statement fuera de un bloque `BEGIN...COMMIT` puede aterrizar en una conexión física distinta de la del statement siguiente: el `set_config` puede quedar en la conexión A mientras la query de negocio corre en la B, donde `auth.uid()` es NULL — o, peor, conserva los claims de un request anterior reciclado.

El segundo punto no es teórico: es **la explicación mecánica del bug abierto K5** (compras responde 500 de forma intermitente, sin patrón reproducible). Y explica por qué es intermitente: depende de cómo el pooler reparta las conexiones físicas en ese instante.

Los dos problemas están acoplados y hay que resolverlos en ese orden. Quitar `BYPASSRLS` **sin** arreglar antes el scope de los claims convertiría un fallo intermitente en un fallo total: sin claims correctos, `current_account_ids()` devuelve vacío y toda query pasa a devolver 0 filas.

Hay una asimetría que hace esto urgente aunque el aislamiento "funcione" hoy: el camino híbrido navegador→PostgREST **sí** respeta la RLS (usa el rol `authenticated`, sin BYPASSRLS). O sea, las mismas tablas tienen dos puertas: una cerrada con llave y otra abierta de par en par. Cualquier bug futuro de filtrado en cualquiera de los 24 repositories es un IDOR cross-tenant directo, sin red que lo detenga — en un ERP con dinero real de 34 cuentas.

Este change es prerequisito duro de `v3-rbac-multirole`: migrar `is_account_writer` al pivot de roles no significa nada mientras el backend no evalúe policies.

## What Changes

El PO firmó el 2026-07-30 la **Opción A ejecutada en dos pasos**, ambos dentro de este change. El paso 2 tiene un gate explícito y no se ejecuta hasta que el paso 1 esté probado.

### Paso 1 — Transacción explícita por request y claims con alcance transaccional

- **`get_db_conn` envuelve cada request en una transacción explícita** y setea los claims con **alcance de transacción** (`set_config(..., true)`, equivalente a `SET LOCAL`) en lugar del alcance de sesión actual. Es el patrón que Supabase documenta para poolers en transaction mode y el que usa PostgREST internamente.
- **Se corrige el registro de la memoria del proyecto sobre C-17.** La nota "SET ROLE no funciona con pgBouncer transaction mode" es cierta para `SET ROLE` **de sesión** (sobrevive al fin de la transacción y puede filtrarse al siguiente cliente que reutilice la conexión física). NO es cierta para las variantes `LOCAL`, que se deshacen solas en `COMMIT`/`ROLLBACK`. La distinción es la base técnica de todo este change y queda documentada para que no se re-litigue.
- **Se elimina el GUC `app.jwt_claims`.** Barrido verificado sobre todo el repositorio: **cero lectores**. No lo lee ninguna policy, ninguna función, ningún RPC, ningún Edge Function y ningún código de aplicación — sólo se escribe en `database.py` y se afirma en un test. El comentario del código que dice "leído por RLS policies y código app" es incorrecto. Queda únicamente `request.jwt.claims`, que sí es el que lee `auth.uid()`.
- **Protección contra transacciones colgadas**: `idle_in_transaction_session_timeout` con alcance transaccional, para que un request lento (o una llamada externa dentro del request) no pueda retener una transacción abierta indefinidamente.
- **`get_service_conn` NO se toca en el paso 1** — no inyecta claims y no debe quedar dentro de una transacción de request. Se documenta explícitamente como camino separado.
- **Palanca de rollout por variable de entorno** en Render, de modo que volver al comportamiento anterior sea un cambio de configuración (reinicio del servicio) y no un redeploy de código.
- **Criterio de cierre del paso 1**: los 500 intermitentes de compras (K5) desaparecen, observado sobre operación real.

### Paso 2 — El backend deja de bypasear la RLS (gated)

- **Dentro de la misma transacción por request, el rol efectivo pasa a ser `authenticated`** (alcance transaccional). `authenticated` tiene `rolbypassrls = false` (verificado), y **las 68 tablas públicas ya tienen RLS activa y policies escritas `TO authenticated`** — que es exactamente el rol que el camino del navegador ya usa. No hay que escribir seguridad nueva: hay que dejar de ignorar la que existe.
- **Se descarta `ALTER ROLE postgres NOBYPASSRLS`** por una razón concreta y verificable: el mismo pool sirve a tres consumidores que **dependen** de BYPASSRLS para operar sin JWT de usuario — el webhook de pagos (dinero real), el endpoint de relay CAE del cron, y la tarea en segundo plano de emisión de CAE. Quitarle BYPASSRLS al rol de login los rompe a los tres de una vez. Cambiar el rol **por transacción** deja intacto ese camino: quien no hace el cambio de rol, sigue siendo `postgres`.
- **Auditoría de escrituras directas contra la matriz de policies.** Hallazgo preliminar que redimensiona el paso 2: **40 de las 68 tablas con RLS tienen policy de SELECT pero ninguna de INSERT/UPDATE/DELETE**. La mayoría de las escrituras del backend pasa por RPCs `SECURITY DEFINER` (DEC-24), que no se ven afectadas; pero los repositories **también escriben directo**, y un cruce preliminar ya identifica al menos cuatro colisiones reales (`fiscal_documents` con 4 UPDATE directos y 0 policy de UPDATE; `cashboxes` ídem; `events` y `email_logs` con INSERT directo y 0 policy de INSERT). El inventario completo y su resolución —encaminar por RPC o agregar la policy faltante— es trabajo de este paso, no un descubrimiento para el día del corte.
- **Verificación de aislamiento real**, no sólo "la suite pasa": prueba concurrente con dos usuarios de cuentas distintas que confirma que ninguna respuesta contiene datos de la otra cuenta.
- **Gate explícito**: el paso 2 no se ejecuta hasta que el paso 1 acumule el período de observación definido y el PO dé sign-off (ver `design.md`, "probado bajo carga").

### Fuera del alcance

- Los helpers `is_account_writer` / `current_account_ids` **no se migran** al pivot de roles — eso es `v3-rbac-multirole`. Acá sólo tienen que **funcionar** con el claim correcto por request, cosa que hoy no está garantizada.
- No se toca el hook de emisión de claims (`v31-authz-token-hook`, en paralelo).
- No se hace el barrido manual de `account_id` en los 24 repositories (Opción B, descartada por el PO).

**BREAKING (semántica interna, sin cambio de contrato HTTP)**: el paso 1 vuelve **atómico por request** el trabajo que hoy se comitea por partes. Si un request escribe y luego falla, lo escrito ya no queda. Es más correcto, y es un cambio de comportamiento que hay que verificar deliberadamente (ver `design.md` D3).

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `asyncpg-pool`: el requisito vigente describe la inyección de claims como `SET LOCAL app.jwt_claims` — una descripción que **no coincide con el código** (el código usa alcance de sesión) y que nombra un GUC que **nadie lee**. Se reemplaza por el contrato real: transacción explícita por request, claims con alcance transaccional sobre el GUC que las policies efectivamente consultan, y liberación garantizada al terminar el request.
- `multi-tenant`: se establece que el aislamiento entre cuentas SHALL estar respaldado por la base de datos y no depender exclusivamente de que cada consulta de la aplicación recuerde filtrar — con la evaluación de policies activa también para el backend, no sólo para el camino del navegador.
- `python-backend`: el camino de servicio (operaciones de máquina sin JWT de usuario: webhook de pagos, relay de comprobantes) se declara explícitamente como un camino distinto del camino de request, con su propio contexto de conexión y sin el alcance transaccional de claims.

## Impact

- **Código backend**: `backend/core/database.py` (el punto por el que pasa **todo** el backend: 56 usos de `get_db_conn`/`get_account_id` en routers), `backend/core/config.py` (palanca de rollout), `backend/tests/test_database.py` (afirma hoy el comportamiento defectuoso: `", false)" == 2`), tests de aislamiento nuevos.
- **Base de datos**: en el paso 1, **ninguna migración**. En el paso 2, una migración sólo si el inventario de escrituras directas obliga a agregar policies faltantes.
- **API**: ningún cambio de contrato. Se espera que **desaparezcan** los 500 intermitentes de compras (K5).
- **Infraestructura**: una variable de entorno nueva en Render por paso. Sin cambio de cadena de conexión, sin rol de login nuevo, sin cambio de puerto ni de modo de pooling.
- **Riesgo**: **el más alto del cluster.** Todo el backend pasa por este código. Un error en el manejo del alcance transaccional bajo el pooler puede producir *fail-open* cross-tenant — el peor escenario posible para un ERP con dinero real. Ver `design.md` (Riesgos) y la estrategia de despliegue en dos pasos con palanca de configuración.
- **Governance**: **CRÍTICO** (aislamiento entre cuentas + camino de dinero). El paso 1 se implementa y despliega con la palanca apagada por defecto; encenderla en producción y ejecutar el paso 2 requieren decisión explícita del PO.
- **Cluster**: prerequisito duro de `v3-rbac-multirole`, en paralelo lógico con `v31-authz-token-hook`. Depende de `v31-fix-auth-shape-500` ✅.
