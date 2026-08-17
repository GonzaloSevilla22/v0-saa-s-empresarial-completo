## 1. Preparación y red de seguridad

- [x] 1.1 Crear rama nueva desde `main` actualizado (regla del repo: nunca commitear a `main`; un PR por change).
- [x] 1.2 Confirmar el timestamp libre de la migración: `MAX(version)` en `supabase_migrations.schema_migrations` de prod (`gxdhpxvdjjkmxhdkkwyb`, SELECT de sólo lectura) contra el último archivo de `supabase/migrations/`. Esperado: ambos en `20260922000001` ⇒ usar `20260923000001`. Si difieren, **parar y reportar** (historial desincronizado).
- [x] 1.3 Levantar el stack local (`supabase start`) y capturar la línea base de los gates que ya corren en CI, para probar que este change no rompe lo que ya funcionaba. Si alguno falla **antes** de tocar nada, reportarlo como fallo preexistente y no arreglarlo acá.
- [x] 1.4 Verificar en el stack local si `pg_net` está precreado: `SELECT to_regclass('net._http_response')`. Anotar el resultado — decide si las aserciones de pg_net del gate corren o quedan skippeadas (OQ-3 / D7).

## 2. RED — Gate de CI primero (antes de cualquier SQL de producción)

- [x] 2.1 Crear `supabase/tests/test_internal_logs_retention.sql` con el header documental del repo (qué verifica y **por qué**: el diagnóstico medido, el TTL nativo de pg_net, el guard defensivo sobre el schema `net`) y el patrón de aserciones de `test_kpis.sql`: acumular fallos en `text[]` y un único `RAISE EXCEPTION` al final.
- [x] 2.2 Escribir las aserciones **estructurales**: existe `public.purge_internal_logs()`; los jobs `purge-internal-logs` (`0 4 * * *`) y `vacuum-full-net-http-response` (`20 4 * * *`) están registrados y activos en `cron.job` con exactamente una fila por nombre; no existe `purge-cron-job-run-details`; ningún job contiene un `DELETE` sobre `net._http_response`.
- [x] 2.3 Escribir la aserción **behavioral** núcleo de `cron.job_run_details`: insertar filas sintéticas asociadas a un job de alta frecuencia — una vieja (`now() - 2 días`) y una reciente (`now() - 1 hora`) — invocar `public.purge_internal_logs()` y verificar que la vieja desaparece y la reciente sobrevive.
- [x] 2.4 Escribir la aserción behavioral de `public.email_logs`: fila con `created_at` de 100 días desaparece; fila de 30 días sobrevive.
- [x] 2.5 Escribir las aserciones de **superficie de autorización**: `has_function_privilege` falso para `anon` y `authenticated`, verdadero para `postgres`; `pg_proc.proconfig` de la función incluye un `search_path` explícito.
- [x] 2.6 Ejecutar el gate contra el stack local: **debe fallar** (`psql -v ON_ERROR_STOP=1`, exit ≠ 0) porque la función y los jobs todavía no existen. Registrar la evidencia del RED. **No avanzar sin ver el fallo.**

## 3. GREEN — Migración mínima que pone el gate en verde

- [x] 3.1 Crear `supabase/migrations/20260923000001_internal_logs_retention.sql` con el header del repo: diagnóstico medido en prod, qué supera de `20260630000001`, y el `ROLLBACK PLAN` del design.
- [x] 3.2 Implementar `public.purge_internal_logs()` — `SECURITY DEFINER`, `SET search_path = ''`, todos los objetos calificados por schema, retorno `jsonb` con los conteos purgados por tabla.
- [x] 3.3 Implementar dentro de la función la retención escalonada de `cron.job_run_details`: **1 día** para jobs cuyo `schedule` en `cron.job` tiene el campo de minutos `*` o `*/N`; **14 días** para el resto y para las filas huérfanas (`jobid` ausente de `cron.job`). Clasificar por `schedule`, nunca por `jobid` (D3).
- [x] 3.4 Implementar la retención de `public.email_logs` a **90 días** sobre `created_at`, como un literal único y localizable (OQ-1: el PO puede moverlo sin reabrir el change).
- [x] 3.5 Declarar las ACLs **en el mismo archivo, inmediatamente después del `CREATE`**: `REVOKE ALL ON FUNCTION public.purge_internal_logs() FROM PUBLIC, anon, authenticated;` + `GRANT EXECUTE ... TO postgres;` (regla dura: `DROP`+`CREATE` resetea ACLs).
- [x] 3.6 Registrar los jobs de forma idempotente: `unschedule`-si-existe por nombre vía `FROM cron.job WHERE jobname IN (...)` para los tres nombres (incluido el retirado `purge-cron-job-run-details`), y luego `cron.schedule` de `purge-internal-logs` (`0 4 * * *`) y `vacuum-full-net-http-response` (`20 4 * * *`, comando `VACUUM (FULL, ANALYZE) net._http_response`).
- [x] 3.7 Agregar la purga inicial one-shot al final: `SELECT public.purge_internal_logs();`. **Verificar que la migración no contiene ningún `VACUUM` en su propio cuerpo** (D2: corre en bloque transaccional).
- [x] 3.8 Aplicar la migración en local (`supabase db reset` o `db push` contra el stack local) y ejecutar el gate: **debe pasar**. Registrar la evidencia del GREEN.

## 4. TRIANGULATE — Casos que rompen una implementación ingenua

- [x] 4.1 Agregar al gate el caso del **job diario**: fila de 10 días de un job con schedule `0 4 * * *` sobrevive; fila equivalente de 20 días desaparece. Rompe cualquier implementación que use una ventana plana.
- [x] 4.2 Agregar el caso de la **fila huérfana** (`jobid` inexistente en `cron.job`) de 3 días: sobrevive (ventana larga). Rompe una implementación que asuma que todo lo no clasificable es alta frecuencia.
- [x] 4.3 Agregar el caso de **idempotencia real**: ejecutar `public.purge_internal_logs()` dos veces seguidas — la segunda no falla y no altera las filas que sobrevivieron a la primera.
- [x] 4.4 Agregar el caso de **re-registro idempotente de los jobs**: re-ejecutar el bloque `unschedule`+`schedule` de la migración y verificar que sigue habiendo exactamente un job por nombre.
- [x] 4.5 Envolver las aserciones que dependan de `net._http_response` en el guard defensivo `to_regclass('net._http_response') IS NULL → RAISE NOTICE + skip`, documentando el guard en el header del archivo (D7). Ejecutar el gate y confirmar que pasa **tanto** con el schema presente como ausente.
- [x] 4.6 Ejecutar el gate completo tras cada caso agregado y confirmar verde en todos.

## 5. REFACTOR

- [x] 5.1 Extraer las ventanas de retención a constantes/variables nombradas dentro de la función, para que las tres ventanas (1 día, 14 días, 90 días) se lean de un vistazo y se ajusten en un solo lugar. Re-ejecutar el gate.
- [x] 5.2 Revisar la clasificación por `schedule` y dejar el patrón reconocido explícito en un comentario (incluida su limitación documentada: `0-59/1 * * * *` cae en la ventana larga — más filas, nunca pérdida). Re-ejecutar el gate.
- [x] 5.3 Verificar que no se duplicó lógica existente (regla de reutilización): la nueva función sigue el patrón de `_notifications_cleanup()` / `_sweep_plan_limit_exceeded()` y no reimplementa nada que ya exista en `supabase/migrations/`. Re-ejecutar el gate.

## 6. Cableado de CI

- [x] 6.1 Agregar el paso `Run internal logs retention gates` a `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1` (sin la bandera, psql sale 0 aun con excepciones y el gate sería decorativo) y un comentario que explique qué protege. **En el mismo PR que el archivo de test** — los archivos del workflow están listados uno por uno.
- [x] 6.2 Confirmar que el archivo SQL nuevo no tiene BOM (el workflow falla en el primer paso si lo detecta).
- [x] 6.3 Ejecutar la batería local completa de gates SQL y comparar contra la línea base de 1.3: mismo resultado, más el gate nuevo en verde.

## 7. Cierre y verificación en producción

- [x] 7.1 Abrir el PR con el resumen del diagnóstico medido y las tres ventanas elegidas, dejando **OQ-1 (ventana de `email_logs`) explícita para el PO** como no bloqueante. → PR #411.
- [x] 7.2 Esperar checks verdes (incluido `validate-kpis`) y mergear. El merge dispara build + deploy + `supabase db push` automáticos — no pedir aplicación manual de la migración. → `playwright` falló por timeout de 30min en `Install Playwright browsers` (infra flake no relacionado al PR — confirmado con `gh run rerun --failed`, pasó en 3m25s); todos los checks verdes tras el rerun. Merge squash `10340d4` (#411). `Build and Deploy` corrió `Deploy Database Migrations` + `Deploy Edge Functions` en verde.
- [x] 7.3 Verificación post-deploy en prod (SELECTs de sólo lectura): los tres jobs esperados en `cron.job` con sus schedules, `purge-cron-job-run-details` ausente, y `pg_total_relation_size` de las tres tablas. **Resultado real**: migración `20260923000001` registrada; `purge-internal-logs` (`0 4 * * *`) y `vacuum-full-net-http-response` (`20 4 * * *`) activos con los comandos esperados; `purge-cron-job-run-details` ausente; `email_logs` con 0 filas > 90 días. `cron.job_run_details` bajó de 22.738 a 2.983 filas (la purga inicial one-shot corrió) pero `pg_total_relation_size` se mantuvo en ~17 MB — **nuance de Postgres, no bug**: un `DELETE` no reduce el tamaño de archivo en disco sin `VACUUM`/`VACUUM FULL` (que este change deliberadamente NO programó para esta tabla, sólo para `net._http_response`); el tamaño dejará de CRECER y se irá compactando por reuso de páginas libres, pero un reclamo inmediato a ~2 MB requeriría un `VACUUM FULL` explícito que el design no incluyó para esta tabla. Anotado para el PO, no bloquea el change.
- [ ] 7.4 Verificación diferida (~24 h después del deploy): `net._http_response` bajó de ~31 MB a ~1-2 MB. Si no bajó, revisar el `return_message` del job en `cron.job_run_details` — el fallo esperable es pérdida del privilegio `MAINTAIN` (riesgo anotado en el design, degrada a "no se reclama espacio", nunca a pérdida de datos). **PENDIENTE** — no se puede verificar dentro de esta sesión (el primer tick del `VACUUM FULL` es a las 04:20 UTC); queda para la próxima sesión/PO.
- [x] 7.5 Registrar el resultado y las decisiones en engram (`topic_key: opsx/internal-logs-retention/apply`), incluida la respuesta del PO a OQ-1 si llegó (sin respuesta aún — no bloqueante).
