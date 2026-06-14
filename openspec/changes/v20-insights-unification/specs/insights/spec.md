## ADDED Requirements

### Requirement: Almacén único canónico de insights
El sistema SHALL persistir todos los insights en una única tabla canónica llamada `insights`, con el esquema `id, user_id, account_id, type, priority, message, created_at`. No SHALL existir ninguna otra tabla activa que almacene insights.

#### Scenario: Existe una sola tabla de insights tras la migración
- **WHEN** se inspecciona el esquema `public` después de aplicar el change
- **THEN** existe la tabla `insights` con las columnas `id, user_id, account_id, type, priority, message, created_at`
- **AND** no existe ninguna tabla `ai_insights` (solo, transitoriamente, una vista de compatibilidad)

#### Scenario: La vista de compatibilidad expone los mismos datos
- **WHEN** un cliente aún desplegado consulta `ai_insights` durante la ventana de transición
- **THEN** la vista `ai_insights` devuelve exactamente las mismas filas que la tabla `insights`

### Requirement: Migración sin pérdida de los insights legacy
El sistema SHALL migrar todas las filas de la tabla legacy `insights` al esquema canónico, preservando `id`, `user_id`, `created_at` y el contenido (`content → message`), sin perder ni duplicar filas.

#### Scenario: Todas las filas legacy quedan accesibles en el esquema canónico
- **WHEN** se ejecuta la migración de datos
- **THEN** la cantidad de filas migradas es igual a la cantidad de filas de la tabla legacy original
- **AND** cada fila migrada conserva su `id`, `user_id` y `created_at` originales y su `content` en `message`

#### Scenario: Re-ejecución idempotente de la migración
- **WHEN** la migración de backfill se ejecuta más de una vez
- **THEN** no se crean filas duplicadas (las filas con `id` ya existente se omiten)

#### Scenario: Derivación de account_id por membership (RLS account-based)
- **WHEN** se migra una fila legacy de un usuario con membership de cuenta
- **THEN** la fila migrada toma el `account_id` de ese usuario
- **AND** la fila es visible para el usuario bajo la policy RLS account-based (`account_id IN current_account_ids()`)
- **WHEN** se migra una fila legacy de un usuario sin membership
- **THEN** la fila migrada queda con `account_id` NULL y permanece invisible (sin regresión respecto del estado legacy), y la migración reporta su conteo

### Requirement: Todos los caminos de IA escriben en el almacén canónico
El sistema SHALL hacer que las 7 Edge Functions que generan insights persistan en la tabla canónica `insights`: las que insertan directo (`ai-insights`, `ai-precio`, `ai-rentabilidad`, `ai-comparativo`) y las que lo hacen vía el RPC `rpc_atomic_log_ai_insight` (`ai-prediccion`, `ai-resumen`, `ai-simulador`).

#### Scenario: Insight generado vía RPC es visible para el usuario
- **WHEN** una Edge Function (`ai-prediccion`, `ai-resumen` o `ai-simulador`) genera un insight vía `rpc_atomic_log_ai_insight`
- **THEN** el insight se inserta en la tabla canónica `insights` con `message` = contenido generado y `priority` = `'media'`
- **AND** el frontend lo muestra en el listado de insights del usuario

#### Scenario: Insight generado por inserción directa sigue funcionando
- **WHEN** una Edge Function (`ai-insights`, `ai-precio`, `ai-rentabilidad` o `ai-comparativo`) inserta un insight
- **THEN** el insight queda en la tabla canónica `insights` y es legible por el frontend

### Requirement: El contador de uso de plan se preserva
El sistema SHALL mantener el incremento de `profiles.insights_used` y el límite del plan al generar un insight vía `rpc_atomic_log_ai_insight`, sin cambiar la firma del RPC ni los call sites existentes.

#### Scenario: El contador incrementa al generar un insight
- **WHEN** un usuario genera un insight vía el RPC
- **THEN** su `profiles.insights_used` aumenta en 1
- **AND** la telemetría `analytics_events` registra el evento `insight_generated`

#### Scenario: El límite del plan free se respeta
- **WHEN** un usuario en plan `free` con `insights_used >= 5` intenta generar otro insight vía el RPC
- **THEN** el RPC rechaza la operación con error de límite alcanzado
