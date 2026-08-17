## Context

Post-incidente 2026-08-15 (cuota de disco de la organización agotada por preview branches; resuelto con upgrade a Pro + branching a deshabilitar), el diagnóstico mostró **48 MB de 86 MB de la DB de prod ocupados por logs internos**. En plan Pro el disco se factura, así que la prevención es barata y permanente.

Estado real medido en prod (`gxdhpxvdjjkmxhdkkwyb`, SELECTs de sólo lectura, 2026-08-17 ~22:00 UTC):

```
pg_ver 17.6 · pg_cron 1.6.4 · pg_net 0.19.5 · MAX(schema_migrations) = 20260922000001

net._http_response      360 vivas / 0 muertas · heap 30 MB · TOAST 40 kB · idx 432 kB · UNLOGGED
                        owner supabase_admin · pg_net.ttl = '6 hours' (source: default)
                        oldest 15:59 → newest 21:58  ⇒ exactamente 6 h de ventana
cron.job_run_details 22.738 filas · heap 16 MB · owner supabase_admin
                        oldest = now() - 7d exactos ⇒ purga de 20260630000001 VIVA y funcionando
                        22.316 filas (98%) de jobid 8 y 9 (ambos '* * * * *')
public.email_logs     5.210 filas · heap 1976 kB · idx 1688 kB · desde 2026-03-01 · SIN retención
                        194 filas > 90 días · 0 filas > 180 días
```

Tres constataciones cambian el diseño respecto del brief inicial:

1. **pg_net YA tiene TTL nativo** (`pg_net.ttl = 6 hours`) y funciona: 360 filas ≡ 6 h × 60 min del job `* * * * *`. Los 30 MB son **bloat de heap**, no filas retenidas — el TOAST son 40 kB, o sea las filas vivas son diminutas. `VACUUM` normal (autovacuum corrió el 2026-08-05) marca el espacio como reusable pero **no lo devuelve al SO**.
2. **`cron.job_run_details` ya tiene purga de 7 días** (`purge-cron-job-run-details`, migración `20260630000001`). No falta un job: sobra ventana para los dos relays por minuto.
3. **`email_logs` es el único caso de retención cero real**, y su reclamo hoy es marginal (194 filas): el valor es el techo futuro.

Restricciones de plataforma relevantes:
- `supabase db push` corre cada migración **dentro de un bloque transaccional** ⇒ `VACUUM` / `VACUUM FULL` son imposibles en la migración (`VACUUM cannot run inside a transaction block`).
- Los cron jobs del proyecto corren como rol **`postgres`**, que **NO** es miembro de `supabase_admin` (`pg_has_role = false`), owner de `net._http_response` y `cron.job_run_details`.
- Verificado en prod: `postgres` tiene `DELETE`, `TRUNCATE` **y `MAINTAIN`** sobre `net._http_response`, y `DELETE`/`MAINTAIN` sobre `cron.job_run_details`. El privilegio `MAINTAIN` (nuevo en PG 17) **habilita `VACUUM FULL` sin ser owner ni superusuario** — sin él este change no tendría cómo reclamar los 30 MB.
- `pg_net` se usa **fire-and-forget**: ningún archivo de `supabase/`, `backend/` o `frontend/` llama a `net.http_collect_response` ni lee `net._http_response`.

## Goals / Non-Goals

**Goals:**
- Poner un techo automático y auditable al crecimiento de los tres artefactos internos, con ventanas justificadas por el uso medido y no por intuición.
- Reclamar de una vez los ~30 MB de bloat de `net._http_response` y evitar que la marca de agua se reconstruya.
- Centralizar la lógica de purga en **una** función invocable, para que el gate de CI la ejerza directamente sin depender de un tick de cron.
- Dejar el estado de los cron jobs **idempotente** (re-aplicar la migración no duplica jobs ni acumula nombres muertos).

**Non-Goals:**
- Tocar `analytics_events` o `insights` — son datos de producto con valor analítico, no logs de mantenimiento.
- Tocar `operation_idempotency` — su ciclo de vida es parte del contrato de los RPCs de escritura; borrar filas ahí puede reabrir ventanas de doble-ejecución (ver OQ-2).
- Cualquier superficie frontend. **Este change no expone nada al usuario ni al admin** (mantenimiento interno puro) — declaración explícita exigida por la regla PO 2026-08-02.
- Rediseñar el logging de emails (formato, columnas, índices). `email_logs` tiene casi tanto índice como datos (1688 kB vs 1976 kB); eso es otro change.
- Reducir la frecuencia de los jobs `* * * * *` (`relay-process-outbox`, `relay-process-pending-cae`). Son la causa raíz del volumen de logs, pero su cadencia es un requisito funcional del outbox y del relay de CAE.

## Decisions

### D1 — `net._http_response`: reclamo de espacio, NO retención

**Decisión**: no se programa ninguna purga por antigüedad sobre `net._http_response`. Se programa un `VACUUM (FULL, ANALYZE)` diario.

**Por qué**: `pg_net.ttl = 6 hours` ya borra las filas y está demostrablemente activo (la ventana observada es exactamente de 6 h). Agregar un `DELETE ... WHERE created < ...` sería código muerto que compite con el worker de pg_net y esconde el problema real, que es la marca de agua del archivo.

**Alternativas consideradas**:
- *`TRUNCATE net._http_response`* — reclama el espacio instantáneamente y sólo requiere el privilegio `TRUNCATE` (que `postgres` tiene). **Rechazada**: destruye respuestas en vuelo aún no recolectadas. Hoy nadie las recolecta, pero la política quedaría siendo una bomba silenciosa para el primer consumidor de `http_collect_response` que aparezca.
- *Bajar `pg_net.ttl`* — requiere `ALTER SYSTEM`/config de plataforma, fuera del alcance de una migración, y no reclama el espacio ya perdido.
- *No hacer nada* — defendible (la tabla está en estado estacionario y no crece), pero deja 30 MB facturables tirados por tiempo indefinido.

### D2 — El `VACUUM FULL` va por pg_cron, no en la migración

**Decisión**: job `vacuum-full-net-http-response`, schedule `20 4 * * *` (04:20 UTC = 01:20 ART), comando `VACUUM (FULL, ANALYZE) net._http_response`.

**Por qué**: `VACUUM` no puede ejecutarse dentro del bloque transaccional en el que `supabase db push` corre la migración. pg_cron ejecuta cada job fuera de transacción — es el caso de uso documentado del propio pg_cron (`cron.schedule('nightly-vacuum', ...)`).

**Por qué diario y no semanal**: después del primer reclamo la tabla queda en ~1-2 MB; un `VACUUM FULL` sobre eso toma un `ACCESS EXCLUSIVE` de milisegundos. Diario hace que (a) el espacio se recupere dentro de las 24 h del deploy en vez de esperar hasta una semana, y (b) la marca de agua no pueda reconstruirse silenciosamente. El costo de la cadencia agresiva es despreciable justamente porque la tabla es chica.

### D3 — Retención escalonada de `cron.job_run_details` por frecuencia del job

**Decisión**: 1 día para jobs de alta frecuencia (schedule cuyo campo de minutos es `*` o `*/N`), 14 días para el resto y para las filas huérfanas (job ya desprogramado).

**Por qué**: el 98% del volumen viene de dos jobs por minuto, cuya historia envejece sin valor (1.440 muestras/día alcanzan de sobra para depurar; un fallo relevante se detecta en horas). En cambio los jobs de negocio diarios (`expire-trials`, `process-cancellations`, los sweeps de billing) generan 1 fila/día y su historia sí vale — hoy la ventana plana de 7 días la tira antes de tiempo. El escalonado **reduce 17 MB → ~2 MB y a la vez DUPLICA** (7 → 14 días) la historia de lo que realmente se audita.

**Por qué la clasificación se hace por `schedule` y no por `jobid`**: los `jobid` cambian con cada `unschedule`/`schedule` (la migración misma los rota). El `schedule` es una propiedad estable del job, y un job nuevo por minuto queda cubierto automáticamente sin tocar esta función.

**Huérfanas a 14 días** (ventana larga, no corta): son la evidencia de un job desprogramado — precisamente lo que uno quiere poder mirar después de un incidente.

**Alternativa considerada**: ventana plana de 2-3 días para todo. Más simple, pero tira la historia de los jobs de negocio para ahorrar sobre filas que ya son el 2% del volumen. Peor relación información/byte.

### D4 — Una función `public.purge_internal_logs()` en vez de DELETEs embebidos en el comando del cron

**Decisión**: la lógica vive en una función; el job sólo hace `SELECT public.purge_internal_logs()`. La función devuelve los conteos purgados por tabla (`jsonb`).

**Por qué**:
- **Testeable**: el gate de CI la llama directo y verifica el comportamiento en la misma transacción. Con la lógica embebida en el string del cron, el gate sólo podría verificar que el texto del comando existe — un assert de sintaxis, no de comportamiento.
- **Regla de reutilización (PO 2026-08-02)**: hoy la ventana de retención está escrita como literal dentro del `command` de un job; cualquier ajuste implica reescribir un string opaco. Un solo punto canónico.
- **Observable**: los conteos devueltos quedan en `cron.job_run_details.return_message`, así que la purga se audita a sí misma.
- Precedente del repo: `_notifications_cleanup()`, `_sweep_plan_limit_exceeded()`, `_produce_plan_expiring_soon()` ya siguen exactamente este patrón (función + job que sólo la invoca).

### D5 — Superficie de autorización: `SECURITY DEFINER` + `search_path` fijo + ACLs explícitas

**Decisión**: `SECURITY DEFINER`, `SET search_path = ''` con **todos** los objetos calificados por schema (`cron.job_run_details`, `public.email_logs`, `cron.job`), y en el **mismo archivo**: `REVOKE ALL ON FUNCTION public.purge_internal_logs() FROM PUBLIC, anon, authenticated;` + `GRANT EXECUTE ... TO postgres;`.

**Por qué**: `SECURITY DEFINER` es necesario porque el schema `cron` no es accesible para roles de aplicación. Las ACLs van en el mismo archivo por la regla dura del repo (**`DROP`+`CREATE` resetea las ACLs a `EXECUTE` para `PUBLIC`**) y porque el gate `test_function_acl_gate.sql` falla si una función `SECURITY DEFINER` queda ejecutable por `anon` fuera de la allowlist. Ningún rol de aplicación tiene por qué poder disparar mantenimiento interno.

### D6 — `email_logs` a 90 días, marcado como pregunta abierta no bloqueante

**Decisión**: implementar 90 días; dejar **OQ-1** abierta para que el PO la mueva sin reabrir el change (es un cambio de un literal en la función).

**Por qué 90 y no menos**: es el rastro de auditoría de emails transaccionales del PO (`transactional-email-delivery`), no un log de máquina. **El reclamo inmediato es irrelevante (194 filas, ~70 kB)** — se implementa por el techo, no por el ahorro. Con 180 días la purga de hoy sería literalmente cero filas.

### D7 — El gate de CI debe correr con guard defensivo sobre el schema `net`

**Decisión**: `test_internal_logs_retention.sql` verifica `pg_cron` sin condiciones (existe en el stack local: `20260605040000_grace_period.sql` hace `CREATE EXTENSION IF NOT EXISTS pg_cron`, y toda migración posterior que llama a `cron.schedule` ya prueba que está), pero **envuelve toda aserción sobre `net._http_response` en un guard** `to_regclass('net._http_response') IS NULL → RAISE NOTICE + skip`.

**Por qué**: ninguna migración del repo hace `CREATE EXTENSION pg_net` — en prod lo habilitó la plataforma. Si el stack local de `supabase start` no lo trae precreado, un assert duro volvería rojo el CI por una razón que no es una regresión. El guard se documenta en el header del archivo para que el skip sea una decisión visible y no una omisión silenciosa.

**Patrón de aserción** (heredado de `test_kpis.sql` / `test_analytics_events.sql`): acumular fallos en `text[]` y un único `RAISE EXCEPTION` al final, para que `psql -v ON_ERROR_STOP=1` salga distinto de cero. **Sin `ON_ERROR_STOP=1` psql sale 0 aun con excepciones** (regresión real documentada en el propio workflow) — el paso nuevo debe copiar la bandera.

### D8 — Timestamp de migración `20260923000001`

Verificado que `MAX(version)` en `supabase_migrations.schema_migrations` de prod es `20260922000001` y que el último archivo local (`20260922000001_client_activity_support_index.sql`) coincide: historial sincronizado, siguiente slot libre = `20260923000001`. Aplicar **siempre por `npx supabase db push`**, nunca por el MCP `apply_migration` (desincroniza el historial — regla dura del repo).

## Risks / Trade-offs

- **El `VACUUM FULL` bloquea `net._http_response` (`ACCESS EXCLUSIVE`)** → La tabla post-reclamo pesa ~1-2 MB (lock sub-segundo), corre a las 01:20 ART y el worker de pg_net reintenta. Si el lock no se obtiene, pg_cron registra el fallo y el siguiente tick es en 24 h.
- **`postgres` pierde el privilegio `MAINTAIN` en una actualización de plataforma** → El `VACUUM FULL` empezaría a fallar con permission denied, visible en `cron.job_run_details` del propio job. Degrada a "no se reclama espacio", nunca a pérdida de datos. El gate no puede cubrir esto (depende del entorno); queda como riesgo aceptado y anotado.
- **Purgar `cron.job_run_details` a 1 día borra evidencia de un incidente de más de 24 h en los relays** → Los relays no dependen de esa tabla para su corrección (el outbox tiene su propio estado y el CAE su `next_attempt_at`); la tabla es sólo observabilidad. Ante una investigación, subir la ventana es un `UPDATE` de un literal + re-deploy.
- **La clasificación por `schedule` es sintáctica**: un job `0-59/1 * * * *` corre por minuto pero no matchea el patrón `*`/`*/N` → caería en la ventana de 14 días (más filas, nunca pérdida). Ningún job actual usa esa forma; el gate documenta el patrón exacto reconocido.
- **Retirar `purge-cron-job-run-details` deja su migración histórica mintiendo** → La migración `20260630000001` queda en el historial (nunca se edita una migración aplicada); la superación se documenta en el header de la nueva y en el proposal.
- **Trade-off aceptado**: nada de esto ataca la causa raíz del volumen (dos jobs `* * * * *`). Es tratamiento sintomático deliberado — bajar la cadencia del outbox o del relay de CAE es un cambio funcional con riesgo real, y el costo de los logs no lo justifica.

## Migration Plan

1. `supabase/migrations/20260923000001_internal_logs_retention.sql` — un solo archivo, idempotente de punta a punta:
   - `CREATE OR REPLACE FUNCTION public.purge_internal_logs()` + `REVOKE`/`GRANT` inmediatamente después, en el mismo archivo.
   - `SELECT cron.unschedule(jobname) FROM cron.job WHERE jobname IN ('purge-cron-job-run-details','purge-internal-logs','vacuum-full-net-http-response');` (patrón unschedule-if-exists del repo: el `FROM cron.job` hace que no falle cuando el job no existe).
   - `SELECT cron.schedule('purge-internal-logs', '0 4 * * *', $$SELECT public.purge_internal_logs()$$);`
   - `SELECT cron.schedule('vacuum-full-net-http-response', '20 4 * * *', $$VACUUM (FULL, ANALYZE) net._http_response$$);`
   - Purga inicial one-shot: `SELECT public.purge_internal_logs();`
2. `supabase/tests/test_internal_logs_retention.sql` + su paso en `.github/workflows/KPI_Validation.yml`, **en el mismo PR** (los archivos del workflow están listados uno por uno; agregar el test sin la línea = gate que nunca corre).
3. Deploy por merge a `main` → la migración la aplica el pipeline (`supabase db push`) automáticamente.
4. Verificación post-deploy (SELECTs): los tres jobs esperados en `cron.job` con sus schedules; `pg_total_relation_size` de las tres tablas; a las 24 h, `net._http_response` debe haber caído de ~31 MB a ~1-2 MB.

**Rollback**:
```sql
SELECT cron.unschedule('purge-internal-logs');
SELECT cron.unschedule('vacuum-full-net-http-response');
DROP FUNCTION IF EXISTS public.purge_internal_logs();
-- restituir la purga previa si hiciera falta:
SELECT cron.schedule('purge-cron-job-run-details','0 4 * * *',
  $$DELETE FROM cron.job_run_details WHERE start_time < now() - interval '7 days'$$);
```
Las filas ya purgadas no se recuperan — son logs, y el rollback restituye la política, no los datos.

## Open Questions

- **OQ-1 (NO bloqueante, decide el PO)**: ventana de retención de `public.email_logs`. Se implementa **90 días**. Datos para decidir: 5.210 filas desde 2026-03-01 (~1.000/mes, ~730 kB/mes con índices); a 90 días se purgan **194 filas hoy**, a 180 días **0**. Es el rastro de auditoría de emails del PO: si necesita un año, el cambio es un literal en `purge_internal_logs()`. No bloquea el apply.
- **OQ-2 (fuera de alcance, sólo anotada)**: `public.operation_idempotency` no se toca en este change. Su ciclo de vida es parte del contrato de los RPCs de escritura (`test_idempotency.sql` verifica el contrato por-fila de `operation_id`): purgar ahí puede reabrir ventanas de doble-ejecución en operaciones de dinero. Si su tamaño empieza a figurar entre los objetos grandes de la DB, amerita su propio change **con análisis del período de reintento real**, no una ventana genérica.
- **OQ-3 (bajo, para el apply)**: si el stack local de `supabase start` no trae `pg_net` precreado, las aserciones sobre `net._http_response` quedan skippeadas en CI (D7) y la verificación del `VACUUM FULL` pasa a ser sólo post-deploy en prod. Se confirma en la primera corrida del gate; el `RAISE NOTICE` del skip lo deja explícito en el log.
