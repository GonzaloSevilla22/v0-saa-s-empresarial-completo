## Why

El incidente del 2026-08-15 (la organización Supabase agotó su cuota de disco por preview branches) expuso que **48 de los 86 MB de la DB de producción son logs internos de mantenimiento**, no datos de negocio. Ahora que el proyecto está en plan **Pro el disco se factura**, así que un piso de basura que crece solo es costo recurrente y ruido operativo permanente.

El diagnóstico en prod (SELECTs sobre `gxdhpxvdjjkmxhdkkwyb`, 2026-08-17) corrigió dos supuestos del reporte inicial — el change se dimensiona sobre los hechos medidos, no sobre el titular:

| Objeto | Tamaño | Filas | Diagnóstico real |
|---|---|---|---|
| `net._http_response` | **31 MB** | 360 vivas, 0 muertas | **NO es falta de retención.** `pg_net.ttl = 6 hours` es nativo y **está funcionando** (360 filas = exactamente 6 h × 60 min de tráfico). Los 31 MB son **bloat de heap** (30 MB de heap con TOAST de sólo 40 kB): marca de agua histórica que `VACUUM` normal nunca devuelve al SO. |
| `cron.job_run_details` | **17 MB** | 22.738 | **Ya tiene purga** (`purge-cron-job-run-details`, 7 días, migración `20260630000001`) y **funciona** (fila más vieja = exactamente 7 días). El problema es la **ventana**: 22.316 de 22.738 filas (98%) las generan los dos jobs `* * * * *` (`relay-process-outbox`, `relay-process-pending-cae`) = ~2.880 filas/día. |
| `public.email_logs` | 3,7 MB | 5.210 (desde 2026-03-01) | **Único caso de cero retención real.** Crece ~1.000 filas/mes sin tope. |

O sea: el trabajo real no es "agregar retención a tres tablas" — es **ajustar una ventana existente, reclamar espacio que la retención nativa no puede devolver, y poner el único techo que falta**.

## What Changes

Una **migración SQL única e idempotente** (`20260923000001_internal_logs_retention.sql`, siguiente timestamp libre verificado contra el MAX real de prod `20260922000001`) que:

- **Crea `public.purge_internal_logs()`** — función de mantenimiento `SECURITY DEFINER` con `search_path` fijado, ACLs explícitas (REVOKE a `PUBLIC`/`anon`/`authenticated`; EXECUTE sólo a `postgres`), que devuelve los conteos purgados. Centraliza la lógica hoy dispersa en el cuerpo de un cron job, y la hace **invocable directamente por el gate de CI** sin esperar un tick de cron.
- **Retención escalonada de `cron.job_run_details`** (reemplaza la ventana plana de 7 días):
  - jobs de alta frecuencia (schedule que arranca con `*` o `*/N`, es decir corren cada ≤N minutos) → **1 día** (1.440 muestras: de sobra para depurar un job por minuto);
  - todos los demás jobs + filas huérfanas (job ya desprogramado) → **14 días** (duplica la historia útil de los jobs de negocio diarios: trials, cancelaciones, sweeps de billing).
  - Efecto medido: 17 MB → ~2 MB, **ganando** historia en los jobs que importan.
- **Retención de `public.email_logs` a 90 días** — purga 194 filas hoy; su valor es el **techo futuro**, no el reclamo inmediato. Ventana marcada como **OQ-1 NO bloqueante** (es el rastro de auditoría de emails del PO).
- **Job diario `vacuum-full-net-http-response`** (`VACUUM (FULL, ANALYZE) net._http_response`) para reclamar los 30 MB de bloat. `VACUUM` no puede correr dentro del bloque transaccional de una migración → va por pg_cron, que sí lo ejecuta fuera de transacción. Viable verificado: `postgres` tiene privilegio **MAINTAIN** sobre la tabla (PG 17), aunque el owner sea `supabase_admin`.
- **Retira el job `purge-cron-job-run-details`** (unschedule idempotente por nombre), superado por `purge-internal-logs`.
- **Purga inicial one-shot** en la misma migración (`SELECT public.purge_internal_logs()`), para no esperar al primer tick.
- **Gate SQL nuevo** `supabase/tests/test_internal_logs_retention.sql` + su paso en `.github/workflows/KPI_Validation.yml` (precedente: `test_analytics_events.sql`, PR #383): asserts de registro de los cron jobs (`cron.job` por `jobname`/`schedule`) **y behavioral** (fila vieja sintética → purga → desaparece; fila reciente sobrevive), con guard defensivo si el schema `net` no existe en el stack local de CI.

**Sin superficie frontend** — mantenimiento interno puro: ninguna pantalla, ruta ni entrada de menú. Declarado explícitamente por la regla PO 2026-08-02 (omisión como decisión, no como olvido).

**Fuera de alcance**: `analytics_events` e `insights` (datos de producto, no logs); `operation_idempotency` (contrato con los RPCs — ver OQ-2).

## Capabilities

### New Capabilities
- `ops-data-retention`: retención y reclamo de espacio de los artefactos internos de mantenimiento de la plataforma (logs de ejecución de pg_cron, respuestas de pg_net, log de emails transaccionales). Cubre las ventanas de retención, la superficie de autorización de la función de purga, el registro idempotente de los jobs y la purga inicial de despliegue.

### Modified Capabilities
Ninguna. `transactional-email-delivery` define la **emisión** de emails, no el ciclo de vida de su tabla de log: la retención de `email_logs` es una política de infraestructura, no un cambio en el contrato de entrega. Se referencia cruzada desde el nuevo spec.

## Impact

- **Migración**: `supabase/migrations/20260923000001_internal_logs_retention.sql` (nueva).
- **Supersede**: `supabase/migrations/20260630000001_purge_cron_job_run_details.sql` (queda histórica; su job se desprograma).
- **CI**: `.github/workflows/KPI_Validation.yml` (+1 paso), `supabase/tests/test_internal_logs_retention.sql` (nuevo).
- **Objetos de DB**: `public.purge_internal_logs()` (nueva); cron jobs `purge-internal-logs` y `vacuum-full-net-http-response` (nuevos), `purge-cron-job-run-details` (retirado).
- **Datos**: se pierde historia de `cron.job_run_details` de más de 1 día para jobs por minuto (se gana: de 7 a 14 días para los jobs de negocio) y de más de 90 días en `email_logs` (194 filas). **Ningún dato de negocio se toca.**
- **Riesgo operativo**: el `VACUUM FULL` diario toma un `ACCESS EXCLUSIVE` sobre `net._http_response`; post-reclamo la tabla es de ~1-2 MB, el lock es sub-segundo y la ventana es 04:20 UTC (01:20 ART, tráfico mínimo). `pg_net` es fire-and-forget en este proyecto — **ningún código lee `net._http_response` ni llama a `net.http_collect_response`** (verificado por grep sobre `supabase/`, `backend/`, `frontend/`).
- **Governance**: MEDIUM. Sin datos de usuario, sin auth, sin billing.
