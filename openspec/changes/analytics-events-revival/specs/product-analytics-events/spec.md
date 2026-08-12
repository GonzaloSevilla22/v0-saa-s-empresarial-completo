## ADDED Requirements

### Requirement: Emisión de telemetría desde un choke point único de base de datos
El sistema SHALL emitir el evento `operation_created` en `analytics_events` por cada fila insertada en `sales`, `purchases` o `expenses`, desde triggers `AFTER INSERT` de base de datos, con independencia de la ruta de escritura que originó la operación.

Ninguna capa de aplicación (FastAPI, RPCs `SECURITY DEFINER`, cliente Supabase JS, migraciones, backfills) puede quedar exenta ni necesita conocer la telemetría. El emisor es una única función de trigger `public.analytics_emit_operation_event()`.

#### Scenario: Gasto creado por el backend FastAPI emite telemetría
- **WHEN** el backend inserta un gasto vía `expense_repository.create` (INSERT directo con asyncpg)
- **THEN** existe en `analytics_events` una fila con `event_name = 'operation_created'` cuyo `event_data->>'entity_id'` es el id del gasto
- **AND** `event_data->>'entity_type'` es `'expense'`

#### Scenario: Venta creada por RPC emite telemetría
- **WHEN** se registra una venta vía `rpc_create_sale_operation`
- **THEN** existe en `analytics_events` una fila con `event_name = 'operation_created'` y `event_data->>'entity_type' = 'sale'` referida a esa venta

#### Scenario: Compra creada por cualquier ruta emite telemetría
- **WHEN** se inserta una fila en `purchases` por cualquier medio, incluido SQL directo
- **THEN** existe en `analytics_events` una fila con `event_name = 'operation_created'` y `event_data->>'entity_type' = 'purchase'` referida a esa compra

#### Scenario: Una ruta de escritura nueva no requiere cambios de telemetría
- **WHEN** se agrega una ruta de escritura nueva que inserta en `sales`, `purchases` o `expenses` sin emitir eventos explícitamente
- **THEN** la operación igualmente produce su `operation_created`

### Requirement: Payload canónico y tenancy del evento
El sistema SHALL poblar en cada evento emitido el `user_id` de la operación, el `account_id` de la cuenta propietaria, y un `event_data` que incluya `entity_id`, `entity_type` y `source`.

`user_id` se toma de la columna `user_id` de la fila de operación y nunca de `auth.uid()`, porque `auth.uid()` no está disponible en todas las rutas (backend con JWT-passthrough, jobs, migraciones). `entity_type` es uno de `'sale'`, `'purchase'`, `'expense'`. `source` es `'trigger'` para la emisión en línea y `'backfill'` para eventos derivados del histórico. `analytics_events.account_id` es una columna propia, indexada junto a `created_at`, y no un campo dentro de `event_data`.

#### Scenario: El evento identifica la operación que lo originó
- **WHEN** se emite un `operation_created`
- **THEN** `event_data->>'entity_id'` es el id de la operación y `event_data->>'entity_type'` indica la tabla de origen
- **AND** `event_data->>'source'` es `'trigger'`

#### Scenario: El evento es atribuible al tenant
- **WHEN** se emite un evento para una operación cuya fila tiene `account_id` poblado
- **THEN** la fila de `analytics_events` tiene ese mismo `account_id`

#### Scenario: El usuario del evento proviene de la operación, no de la sesión
- **WHEN** una RPC `SECURITY DEFINER` o un proceso sin claims de JWT inserta una operación
- **THEN** el evento emitido lleva el `user_id` de la fila de operación

### Requirement: Unicidad de la activación por usuario
El sistema SHALL garantizar mediante un índice único parcial que exista como máximo un evento `first_operation` por `user_id`, sin depender de chequeos `EXISTS` que corren carrera bajo concurrencia.

La activación de producto se define como registrar la primera venta, compra o gasto. `rpc_admin_retention_30d` construye cohortes con una fila por evento `first_operation` sin deduplicar por usuario, de modo que un duplicado infla `cohort_size` y subestima la tasa de retención. La emisión usa `ON CONFLICT DO NOTHING` contra ese índice. Antes de crear el índice, los duplicados históricos se limpian conservando el evento más antiguo por usuario.

#### Scenario: La primera operación del usuario emite activación
- **WHEN** un usuario sin operaciones previas registra su primera venta, compra o gasto
- **THEN** se emite un evento `first_operation` además del `operation_created`

#### Scenario: Operaciones posteriores no vuelven a emitir activación
- **WHEN** el mismo usuario registra una segunda operación, del mismo tipo o de otro
- **THEN** sigue existiendo exactamente un evento `first_operation` para ese usuario

#### Scenario: Dos operaciones concurrentes no duplican la activación
- **WHEN** dos operaciones del mismo usuario se insertan concurrentemente y ambas evalúan que no hay activación previa
- **THEN** el motor conserva un solo evento `first_operation` y la segunda emisión es descartada sin error

#### Scenario: Duplicados históricos se limpian antes de imponer la unicidad
- **WHEN** se aplica la migración sobre una base que ya contiene varios `first_operation` para un mismo usuario
- **THEN** se conserva el de `created_at` más antiguo, se eliminan los restantes y el índice único se crea con éxito

### Requirement: La telemetría nunca aborta la operación de negocio
El sistema SHALL envolver toda la emisión de eventos en un manejador `EXCEPTION WHEN OTHERS` que registre un `WARNING` y permita que la operación de negocio se complete.

Un evento perdido es un punto faltante en un gráfico; una venta perdida es un incidente de negocio. Se replica el patrón degrade-don't-fail del seed de provisioning en `handle_new_user`.

#### Scenario: Un fallo del emisor no tumba la operación
- **WHEN** la inserción del evento falla por cualquier motivo, por ejemplo una restricción que la rechaza
- **THEN** la venta, compra o gasto queda persistida igualmente
- **AND** el fallo se registra como `WARNING` en los logs de la base

#### Scenario: La operación se confirma aunque no haya evento
- **WHEN** el emisor falla durante el registro de un gasto
- **THEN** el gasto existe en `expenses` y no existe evento asociado, sin error propagado al usuario

### Requirement: Los eventos son atómicos con la operación
El sistema SHALL emitir el evento dentro de la misma transacción que la operación, de modo que una transacción abortada no deje eventos huérfanos.

#### Scenario: Transacción abortada no deja telemetría
- **WHEN** una transacción inserta una operación, emite su evento y luego hace `ROLLBACK`
- **THEN** no queda ninguna fila en `analytics_events` referida a esa operación

### Requirement: Un evento por operación, idempotente
El sistema SHALL garantizar mediante un índice único parcial sobre `(event_name, event_data->>'entity_id')` que una misma operación no produzca más de un `operation_created`.

Protege contra reintentos, contra emisores legacy que vuelvan a activarse y contra un backfill ejecutado sobre operaciones que ya emitieron en línea. El índice es parcial sobre `event_name = 'operation_created'` y filas que tengan la clave `entity_id`, de modo que los eventos históricos con claves distintas (`sale_id`, `purchase_id`, `expense_id`) no colisionan ni impiden crearlo.

#### Scenario: Reemisión sobre la misma operación no duplica
- **WHEN** se intenta emitir un `operation_created` para una operación que ya tiene el suyo
- **THEN** la fila duplicada es descartada y sigue existiendo exactamente un evento para esa operación

#### Scenario: Los eventos históricos no bloquean la unicidad
- **WHEN** se crea el índice único sobre una base que contiene eventos legacy sin la clave `entity_id`
- **THEN** el índice se crea con éxito y esos eventos quedan fuera de su alcance

### Requirement: Una fila de operación equivale a un evento
El sistema SHALL emitir un evento `operation_created` por cada fila insertada, incluso cuando varias filas se insertan en una única sentencia.

`operation_created` mide volumen de actividad y alimenta la distribución de uso semanal y la ventana de retención; colapsar una carga múltiple en un solo evento subcontaría la actividad real. Para distinguir cargas masivas de uso diario, el discriminador es la marca `source` en `event_data`, no la granularidad de la emisión.

#### Scenario: Un INSERT de varias filas emite un evento por fila
- **WHEN** una sola sentencia inserta N gastos
- **THEN** se emiten N eventos `operation_created`, uno por gasto

#### Scenario: Una carga múltiple no multiplica la activación
- **WHEN** la carga múltiple corresponde a un usuario sin operaciones previas
- **THEN** se emite un único evento `first_operation`

### Requirement: La emisión de telemetría de operaciones vive únicamente en la base
El sistema SHALL retirar la emisión de `operation_created` y `first_operation` del código de aplicación, dejando la base de datos como único emisor.

Dos emisores para el mismo hecho es la duplicación que originó el defecto. El emisor legacy en `frontend/lib/supabase/services.ts` escribe la clave `expense_id` en lugar de `entity_id`, por lo que el índice de idempotencia no lo desduplicaría y produciría doble conteo.

#### Scenario: El path legacy de gastos ya no emite
- **WHEN** se crea un gasto por el camino legacy del cliente Supabase
- **THEN** el gasto emite exactamente un `operation_created`, el del trigger, y ninguno adicional desde la aplicación

### Requirement: La función emisora es interna y no invocable por clientes
El sistema SHALL revocar los permisos de ejecución de la función emisora para `PUBLIC`, `anon` y `authenticated`, en el mismo archivo de migración que la crea o reemplaza.

La función es exclusivamente de trigger y nunca se invoca como RPC. `DROP` y `CREATE` de una función resetean sus ACLs, por lo que el `REVOKE` debe re-aplicarse junto a cada redefinición. La verificación del permiso de ejecución de una función de trigger ocurre al crear el trigger y no en cada disparo, de modo que la revocación no impide la emisión.

#### Scenario: La función no es ejecutable por roles de cliente
- **WHEN** se inspeccionan los privilegios de `analytics_emit_operation_event` tras aplicar la migración
- **THEN** ni `anon` ni `authenticated` ni `PUBLIC` tienen `EXECUTE`

#### Scenario: La emisión funciona con el rol de cliente activo
- **WHEN** se inserta una operación con el rol `authenticated` activo en la sesión
- **THEN** el evento se emite igualmente, sin error de permisos ni bloqueo por RLS

### Requirement: Backfill histórico de telemetría derivado de las operaciones
El sistema SHALL poder derivar eventos históricos a partir de las filas existentes de `sales`, `purchases` y `expenses`, marcados con `source = 'backfill'` y sin duplicar eventos ya presentes.

Esta capacidad queda condicionada a la decisión de producto OQ-2 y se despliega en una migración separada de la emisión, de modo que la reparación del defecto no dependa de ella. El `created_at` de cada evento derivado es el de la operación de origen. La deduplicación considera tanto los eventos con clave `entity_id` como los eventos legacy con claves `sale_id`, `purchase_id` o `expense_id`.

#### Scenario: El backfill reconstruye la actividad histórica
- **WHEN** se ejecuta el backfill sobre operaciones históricas sin telemetría
- **THEN** cada operación obtiene un `operation_created` con el `created_at` de la operación y `event_data->>'source' = 'backfill'`

#### Scenario: El backfill reconstruye la activación
- **WHEN** un usuario tiene operaciones históricas y ningún `first_operation`
- **THEN** el backfill emite un único `first_operation` fechado en su operación más antigua

#### Scenario: El backfill no duplica telemetría existente
- **WHEN** el backfill alcanza una operación que ya tiene evento, emitido en línea o por el path legacy
- **THEN** no se agrega un evento adicional para esa operación

#### Scenario: Los eventos derivados son distinguibles y reversibles
- **WHEN** se necesita separar telemetría observada de telemetría derivada
- **THEN** los eventos del backfill se identifican por `event_data->>'source' = 'backfill'` y pueden eliminarse selectivamente por ese criterio
