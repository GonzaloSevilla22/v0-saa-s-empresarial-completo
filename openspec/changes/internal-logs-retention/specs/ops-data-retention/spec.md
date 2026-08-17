## ADDED Requirements

### Requirement: Función canónica de purga de logs internos
El sistema SHALL exponer una única función `public.purge_internal_logs()` como punto canónico de purga de los artefactos internos de mantenimiento (logs de ejecución de pg_cron y log de emails transaccionales), y SHALL devolver los conteos purgados por tabla para que la purga quede auditada en el registro de ejecución del job.

Ninguna otra rutina programada SHALL contener lógica de retención embebida sobre esas tablas: las ventanas viven exclusivamente en esta función.

#### Scenario: La función existe y es invocable directamente
- **WHEN** se invoca `SELECT public.purge_internal_logs()`
- **THEN** la función ejecuta sin error y devuelve un `jsonb` con una clave por tabla purgada y su cantidad de filas eliminadas

#### Scenario: No queda lógica de retención duplicada en los comandos de cron
- **WHEN** se inspeccionan los comandos de los jobs registrados en `cron.job`
- **THEN** ningún job distinto de `purge-internal-logs` contiene un `DELETE` sobre `cron.job_run_details` ni sobre `public.email_logs`
- **AND** el comando del job `purge-internal-logs` se limita a invocar `public.purge_internal_logs()`

### Requirement: Retención escalonada de `cron.job_run_details` por frecuencia del job
El sistema SHALL retener las filas de `cron.job_run_details` con dos ventanas según la frecuencia del job que las generó: **1 día** para jobs de alta frecuencia (aquellos cuyo campo de minutos del `schedule` es `*` o `*/N`) y **14 días** para el resto de los jobs y para las filas huérfanas cuyo job ya no existe en `cron.job`.

La clasificación SHALL derivarse del `schedule` del job y nunca de su `jobid`, porque los identificadores rotan con cada `unschedule`/`schedule`.

#### Scenario: Una ejecución vieja de un job por minuto se purga
- **WHEN** existe una fila de `cron.job_run_details` de un job con schedule `* * * * *` cuyo `start_time` es anterior a `now() - interval '1 day'`
- **AND** se ejecuta `public.purge_internal_logs()`
- **THEN** esa fila deja de existir

#### Scenario: Una ejecución reciente de un job por minuto sobrevive
- **WHEN** existe una fila de un job con schedule `* * * * *` cuyo `start_time` es posterior a `now() - interval '1 day'`
- **AND** se ejecuta `public.purge_internal_logs()`
- **THEN** esa fila sigue existiendo

#### Scenario: Un job diario conserva dos semanas de historia
- **WHEN** existe una fila de un job con schedule `0 4 * * *` cuyo `start_time` tiene 10 días de antigüedad
- **AND** se ejecuta `public.purge_internal_logs()`
- **THEN** esa fila sigue existiendo
- **AND** una fila equivalente de 20 días de antigüedad deja de existir

#### Scenario: Las filas huérfanas usan la ventana larga
- **WHEN** existe una fila cuyo `jobid` ya no aparece en `cron.job` y tiene 3 días de antigüedad
- **AND** se ejecuta `public.purge_internal_logs()`
- **THEN** esa fila sigue existiendo, porque las huérfanas son evidencia de un job desprogramado y se retienen 14 días

### Requirement: Retención de `public.email_logs`
El sistema SHALL purgar las filas de `public.email_logs` con antigüedad mayor a **90 días** medida sobre `created_at`, para poner un techo al crecimiento del rastro de auditoría de emails transaccionales, que hoy crece sin límite.

La ventana SHALL estar expresada como un único literal dentro de `public.purge_internal_logs()`, de modo que ajustarla no requiera reescribir ningún comando de cron.

#### Scenario: Un log de email antiguo se purga
- **WHEN** existe una fila de `public.email_logs` con `created_at` anterior a `now() - interval '90 days'`
- **AND** se ejecuta `public.purge_internal_logs()`
- **THEN** esa fila deja de existir

#### Scenario: Un log de email dentro de la ventana sobrevive
- **WHEN** existe una fila de `public.email_logs` con `created_at` de 30 días de antigüedad
- **AND** se ejecuta `public.purge_internal_logs()`
- **THEN** esa fila sigue existiendo

### Requirement: Reclamo de espacio de `net._http_response`
El sistema SHALL reclamar periódicamente el espacio en disco de `net._http_response` mediante un job programado que ejecute `VACUUM (FULL, ANALYZE)`, y SHALL NOT programar ninguna purga por antigüedad sobre esa tabla.

La justificación es normativa, no incidental: `pg_net` aplica su propio TTL nativo (`pg_net.ttl`) sobre esa tabla, de modo que las filas ya se eliminan solas; lo que no se recupera sin un `VACUUM FULL` es el espacio del archivo. Una purga por antigüedad propia sería código muerto compitiendo con el worker de pg_net.

#### Scenario: El job de reclamo está registrado
- **WHEN** se consulta `cron.job` por el `jobname` del reclamo de espacio
- **THEN** existe exactamente un job activo cuyo comando ejecuta `VACUUM (FULL, ANALYZE)` sobre `net._http_response`

#### Scenario: No se programa purga por antigüedad sobre la tabla de pg_net
- **WHEN** se inspeccionan los comandos de todos los jobs de `cron.job`
- **THEN** ninguno contiene un `DELETE` sobre `net._http_response`

#### Scenario: El reclamo no corre dentro de la migración
- **WHEN** se aplica la migración de retención
- **THEN** la migración no ejecuta ningún `VACUUM` en su propio cuerpo, porque `supabase db push` corre cada migración dentro de un bloque transaccional y `VACUUM` no es admisible ahí

### Requirement: Superficie de autorización de la función de mantenimiento
La función `public.purge_internal_logs()` SHALL ser `SECURITY DEFINER` con `search_path` fijado y todos sus objetos calificados por schema, y sus ACLs SHALL declararse en el mismo archivo de migración que la crea.

Los roles de aplicación SHALL NOT poder ejecutarla: `PUBLIC`, `anon` y `authenticated` reciben `REVOKE ALL`, y `EXECUTE` se otorga únicamente al rol que ejecuta los jobs programados. El mantenimiento interno no es una operación de aplicación.

#### Scenario: Roles de aplicación sin permiso de ejecución
- **WHEN** se evalúa `has_function_privilege` para `anon` y para `authenticated` sobre `public.purge_internal_logs()`
- **THEN** ambos devuelven falso

#### Scenario: El rol de los jobs programados puede ejecutarla
- **WHEN** se evalúa `has_function_privilege` para el rol bajo el que corren los cron jobs del proyecto
- **THEN** devuelve verdadero

#### Scenario: `search_path` fijado
- **WHEN** se inspecciona la configuración de la función en `pg_proc.proconfig`
- **THEN** incluye un `search_path` explícito, de modo que la resolución de nombres no dependa del `search_path` del invocador

### Requirement: Registro idempotente de los jobs de retención
La migración SHALL dejar los jobs de retención registrados de forma idempotente: re-aplicarla SHALL NOT duplicar jobs, SHALL NOT fallar si un job no existía, y SHALL retirar el job de purga anterior superado por esta política.

El patrón normativo es `unschedule`-si-existe por **nombre** (consultando `cron.job`) seguido de `cron.schedule`, nunca `unschedule` a ciegas.

#### Scenario: Jobs registrados una sola vez
- **WHEN** se consulta `cron.job` después de aplicar la migración
- **THEN** existe exactamente una fila activa para el job de purga y exactamente una para el job de reclamo de espacio, cada una con su `schedule` esperado

#### Scenario: Re-aplicación sin duplicados ni errores
- **WHEN** la migración se aplica una segunda vez sobre una base que ya la tiene
- **THEN** termina sin error
- **AND** la cantidad de jobs con esos nombres sigue siendo exactamente uno por nombre

#### Scenario: El job de purga anterior queda retirado
- **WHEN** se consulta `cron.job` después de aplicar la migración
- **THEN** no existe ningún job llamado `purge-cron-job-run-details`, superado por la función canónica de purga

### Requirement: Purga inicial en el despliegue
La migración SHALL ejecutar una purga inicial invocando la función canónica en su propio cuerpo, para que el espacio se recupere en el despliegue y no en el primer tick del job programado.

#### Scenario: El backlog histórico se purga al aplicar
- **WHEN** se aplica la migración sobre una base con filas más viejas que las ventanas de retención
- **THEN** esas filas ya no existen al terminar la migración, sin esperar a la próxima ejecución programada
