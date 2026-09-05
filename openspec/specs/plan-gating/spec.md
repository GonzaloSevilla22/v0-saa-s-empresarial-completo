# plan-gating — Spec (plan-gating-engine)

## Purpose

Enforcement en runtime de límites y features por plan. Determina el plan efectivo del usuario, provee hooks de gating, y aplica restricciones en UI y Edge Functions.

## Requirements

### Requirement: Plan efectivo con soporte de trial

El sistema SHALL calcular el plan efectivo desde la **cuenta activa** del usuario (`accounts`), no desde `profiles`. La determinación SHALL delegarse en la definición normativa única `public.get_effective_plan(account_id)` (capability `billing-trial-lifecycle`): exención de cortesía vigente tiene precedencia sobre el trial, el trial vigente tiene precedencia sobre `billing_plan`, y la ausencia de información resuelve a `gratis`.

Ninguna capa SHALL redefinir la regla por su cuenta: el backend Python consume el plan efectivo **desde el claim del token** y NOT SHALL recomputarlo; el frontend mantiene un espejo verificado por una prueba de paridad contra la función SQL.

#### Scenario: Usuario con trial activo accede a features de plan superior
- **GIVEN** un usuario con `billing_plan = 'gratis'`, `trial_plan = 'pro'`, `trial_expires_at = now() + 15 days`
- **WHEN** el sistema evalúa su acceso a la feature "rentabilidad por producto"
- **THEN** el acceso es concedido (efectivo = 'pro')

#### Scenario: Usuario sin trial usa su plan base
- **GIVEN** un usuario con `billing_plan = 'inicial'`, `trial_plan = null`
- **WHEN** el sistema evalúa su acceso a "reportes comparativos"
- **THEN** el acceso es denegado (efectivo = 'inicial', requiere 'avanzado')

#### Scenario: Trial vencido cae al plan base
- **GIVEN** un usuario con `billing_plan = 'gratis'`, `trial_plan = 'pro'`, `trial_expires_at = now() - 1 day`
- **WHEN** el sistema evalúa su plan efectivo
- **THEN** el plan efectivo es 'gratis'

#### Scenario: Miembros comparten el plan de la cuenta
- **GIVEN** una cuenta con `billing_plan = 'pro'` y 5 miembros
- **WHEN** cualquiera de los 5 miembros evalúa su acceso a una feature 'pro'
- **THEN** el acceso es concedido (el plan vive en la cuenta, no en cada usuario)

#### Scenario: Trial de cuenta aplica a todos los miembros
- **GIVEN** una cuenta con trial PRO vigente
- **WHEN** un miembro evalúa el acceso a "rentabilidad por producto"
- **THEN** el acceso es concedido para ese miembro (plan efectivo de la cuenta = 'pro')

#### Scenario: La cuenta exenta accede como plan máximo
- **GIVEN** una cuenta con `billing_exempt = true`
- **WHEN** se evalúa su acceso a cualquier feature
- **THEN** el acceso es concedido (plan efectivo = 'pro')

#### Scenario: El backend no recomputa el plan
- **GIVEN** un request autenticado cuyo token trae el plan efectivo resuelto
- **WHEN** el backend evalúa un límite de plan
- **THEN** usa el valor del token y no consulta ni recalcula la regla de trial/exención

### Requirement: Jerarquía de planes

El sistema SHALL aplicar una jerarquía ordenada `gratis < inicial < avanzado < pro`. Una feature disponible desde el plan X es accesible por todos los planes >= X.

#### Scenario: Plan superior tiene acceso a features de planes inferiores
- **GIVEN** un usuario con `billing_plan = 'pro'`
- **WHEN** accede a cualquier feature disponible desde 'gratis', 'inicial' o 'avanzado'
- **THEN** el acceso es concedido

### Requirement: Límites numéricos de recursos

El sistema SHALL contar los recursos (productos, clientes, proveedores, operaciones/mes, exportaciones/mes) **por cuenta** (`account_id`), no por usuario, al comparar contra los límites del plan.

Los límites SHALL leerse de `plan_limits` en runtime **en todas las capas que los enforcean**, incluido el backend Python. Ninguna capa SHALL enforcear un límite desde constantes hardcodeadas.

El enforcement de los límites de recursos maestros (productos, clientes, proveedores) SHALL aplicarse en la **creación**. Los límites de contadores mensuales (operaciones/mes, exportaciones/mes) quedan fuera del enforcement de creación de este comportamiento.

#### Scenario: Usuario gratis intenta crear el producto 101
- **GIVEN** un usuario con plan efectivo 'gratis' que ya tiene 100 productos
- **WHEN** intenta acceder al formulario de creación de producto
- **THEN** el sistema muestra un banner "Límite alcanzado" en lugar del formulario, con CTA de upgrade

#### Scenario: Usuario avanzado crea productos sin restricción hasta 1.500
- **GIVEN** un usuario con plan efectivo 'avanzado' con 1.499 productos
- **WHEN** crea un producto más
- **THEN** la creación es permitida (límite = 1.500 según `plan_limits`)

#### Scenario: El límite se lee desde `plan_limits` en la DB
- **GIVEN** que el admin actualiza `plan_limits SET max_products = 150 WHERE plan = 'gratis'`
- **WHEN** un usuario gratis con 120 productos intenta crear uno más
- **THEN** el sistema permite la creación (límite actualizado a 150)

#### Scenario: El backend enforcea el límite de `plan_limits`, no una constante propia
- **GIVEN** que `plan_limits.max_products` para 'avanzado' vale 1500
- **WHEN** el backend evalúa la creación de un producto para una cuenta 'avanzado'
- **THEN** el límite aplicado es 1500 y no un valor distinto embebido en el código

#### Scenario: El límite de productos es compartido por la cuenta
- **GIVEN** una cuenta 'inicial' (max_products=500) con 2 miembros que crearon 498 y 1 productos (499 total)
- **WHEN** cualquier miembro crea un producto más
- **THEN** la creación es permitida (499 < 500); el siguiente (#501) es bloqueado para todos los miembros

#### Scenario: El límite de clientes se enforcea en la creación
- **GIVEN** una cuenta con plan efectivo 'gratis' (max_clients = 50) que ya tiene 50 clientes
- **WHEN** intenta crear un cliente más
- **THEN** la creación es rechazada con el mensaje de límite de plan

#### Scenario: El límite de proveedores se enforcea en la creación
- **GIVEN** una cuenta con plan efectivo 'gratis' (max_suppliers = 20) que ya tiene 20 proveedores
- **WHEN** intenta crear un proveedor más
- **THEN** la creación es rechazada con el mensaje de límite de plan

#### Scenario: Registrar una venta no se bloquea por límite de plan
- **GIVEN** una cuenta con plan efectivo 'gratis' que superó `max_operations_per_month`
- **WHEN** registra una venta
- **THEN** la operación es permitida (los contadores mensuales no bloquean la operación del negocio)

#### Scenario: `usePlanLimits()` expone `maxExportsPerMonth` y `exportsUsed`
- **GIVEN** un usuario con plan efectivo 'avanzado' y `exports_used = 7`
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** retorna `{ ..., maxExportsPerMonth: 15, exportsUsed: 7, exportsRemaining: 8 }`

#### Scenario: `plan_limits` incluye `max_exports_per_month` por plan
- **GIVEN** la tabla `plan_limits` con el seed actualizado
- **WHEN** se consulta `SELECT max_exports_per_month FROM plan_limits WHERE plan = 'inicial'`
- **THEN** retorna `3`

### Requirement: Gating de features exclusivas

El sistema SHALL restringir el acceso a features marcadas como exclusivas de planes superiores.

#### Scenario: Acceso a rentabilidad por producto (avanzado+)
- **GIVEN** un usuario con plan efectivo 'inicial'
- **WHEN** intenta acceder a la sección de rentabilidad por producto
- **THEN** ve el contenido bloqueado con el componente `PlanGate` mostrando el plan mínimo requerido

#### Scenario: Acceso a comunidad para postear (avanzado+)
- **GIVEN** un usuario con plan efectivo 'gratis'
- **WHEN** intenta crear un post en la comunidad
- **THEN** la acción es bloqueada tanto en UI como en DB (RLS)

### Requirement: Límites de IA con verificación server-side

El sistema SHALL rechazar llamadas a las Edge Functions de IA cuando el usuario agotó su cuota mensual, sin llamar a OpenAI.

#### Scenario: Usuario gratis agotó sus 5 consultas IA
- **GIVEN** un usuario con plan efectivo 'gratis' con `ai_queries_used = 5`
- **WHEN** llama a cualquier Edge Function de IA (ai-insights, ai-prediccion, etc.)
- **THEN** la Edge Function retorna HTTP 429 `{ ok: false, error: 'quota_exceeded', resetAt: <usage_reset_at> }` sin llamar a OpenAI

#### Scenario: Usuario pro usa IA sin restricción práctica
- **GIVEN** un usuario con plan efectivo 'pro' con `ai_queries_used = 299`
- **WHEN** llama a una Edge Function de IA
- **THEN** la llamada es procesada normalmente (límite = 300/mes)

#### Scenario: Contador se incrementa tras cada llamada exitosa
- **GIVEN** una llamada IA exitosa para un usuario con `ai_queries_used = 10`
- **WHEN** la Edge Function completa la llamada a OpenAI
- **THEN** `profiles.ai_queries_used` se incrementa a 11

### Requirement: Límite de usuarios por cuenta

El sistema SHALL enforcear `plan_limits.max_users` como la cantidad máxima de miembros activos de una cuenta.

#### Scenario: El límite de usuarios refleja el plan
- **GIVEN** una cuenta con plan 'avanzado'
- **WHEN** se consulta el límite de usuarios
- **THEN** es 5 (de `plan_limits.max_users WHERE plan='avanzado'`)

#### Scenario: Upgrade de plan amplía el cupo de usuarios
- **GIVEN** una cuenta 'inicial' (max=2) llena que sube a 'avanzado' (max=5)
- **WHEN** se recalcula el cupo
- **THEN** la cuenta puede aceptar 3 invitaciones más

### Requirement: Lectura de límites desde DB en runtime

El sistema SHALL obtener los límites del plan desde `plan_limits` (DB) en runtime, no desde constantes hardcodeadas.

#### Scenario: `usePlanLimits()` retorna los límites del plan efectivo
- **GIVEN** un usuario con plan efectivo 'avanzado'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** retorna `{ maxProducts: 1500, maxClients: 1000, maxAiQueriesPerMonth: 120, ... }` leídos de `plan_limits`

#### Scenario: Los límites están cacheados por 1 hora
- **GIVEN** `usePlanLimits()` fue llamado hace 30 minutos
- **WHEN** un nuevo componente llama a `usePlanLimits()`
- **THEN** se retorna el resultado cacheado sin llamar a la DB

### Requirement: RLS de comunidad por plan

La RLS de INSERT en `posts` y `replies` SHALL verificar `billing_plan IN ('avanzado', 'pro')` (reemplaza la verificación legacy `plan = 'pro'` del ENUM).

#### Scenario: Usuario avanzado puede postear en comunidad
- **GIVEN** un usuario con `billing_plan = 'avanzado'`
- **WHEN** intenta INSERT en `posts`
- **THEN** la RLS permite la operación

#### Scenario: Usuario gratis no puede postear
- **GIVEN** un usuario con `billing_plan = 'gratis'`
- **WHEN** intenta INSERT en `posts`
- **THEN** la RLS rechaza la operación con error de policy

### Requirement: Cuota IA aplica a todas las Edge Functions de IA (C-04)

El sistema SHALL verificar la cuota IA **antes** de llamar a OpenAI y SHALL incrementar el contador **después** de una llamada exitosa, en **todas** las Edge Functions de IA del proyecto: `ai-insights`, `ai-comparativo`, `ai-precio`, `ai-prediccion`, `ai-rentabilidad`, `ai-resumen`, `ai-simulador` (counter `'queries'`) y `fair-advisor` (counter `'advice'`).

El incremento SHALL realizarse mediante el RPC atómico `rpc_increment_ai_usage` (no read-modify-write desde el cliente).

El límite contra el que se compara el contador SHALL corresponder al **plan efectivo de la cuenta**, resuelto según la definición normativa de la base de datos. La verificación de cuota NOT SHALL derivar el plan de `public.profiles`.

#### Scenario: fair-advisor bloqueado al exceder cuota de advice

- **GIVEN** un usuario `gratis` con `ai_advice_used = 3` (límite = 3)
- **WHEN** llama a `fair-advisor`
- **THEN** la función retorna HTTP 429 con `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: fair-advisor procede cuando hay cuota disponible

- **GIVEN** un usuario `avanzado` con `ai_advice_used = 1` (límite = 10)
- **WHEN** llama a `fair-advisor`
- **THEN** la función procesa la solicitud y retorna resultado de IA, `ai_advice_used` queda en 2

#### Scenario: ai-insights bloqueado al exceder cuota de queries

- **GIVEN** un usuario `gratis` con `ai_queries_used = 5` (límite = 5)
- **WHEN** llama a `ai-insights`
- **THEN** la función retorna HTTP 429 con `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: El límite de la cuenta que pagó corresponde a su plan pagado

- **GIVEN** una cuenta con `accounts.billing_plan = 'pro'` cuyo registro en `profiles` conserva `'gratis'`, y un miembro con `ai_queries_used = 10`
- **WHEN** ese miembro llama a una Edge Function de IA
- **THEN** la llamada es procesada, porque el contador se compara contra el límite de `'pro'` (300) y no contra el de `'gratis'` (5)

### Requirement: Límite de sucursales por plan (C-07)

El sistema SHALL leer `plan_limits.max_branches` y `plan_limits.has_branches_module` para cada plan y rechazar la creación de sucursales que supere el cupo. El módulo SHALL estar disponible solo para `pro`.

#### Scenario: `usePlanLimits()` expone `maxBranches` y `hasBranchesModule`

- **GIVEN** un usuario con plan efectivo 'pro'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** el objeto retornado incluye `maxBranches: 3` y `hasBranchesModule: true`

#### Scenario: `usePlanLimits()` retorna `hasBranchesModule: false` para planes sin sucursales

- **GIVEN** un usuario con plan efectivo 'avanzado'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** el objeto retornado incluye `hasBranchesModule: false`

#### Scenario: Seed de `plan_limits` incluye `max_branches` y `has_branches_module`

- **GIVEN** la tabla `plan_limits` correctamente seedeada
- **WHEN** se consulta `SELECT max_branches, has_branches_module FROM plan_limits WHERE plan = 'pro'`
- **THEN** retorna `max_branches = 3`, `has_branches_module = true`

#### Scenario: UI oculta módulo de sucursales para planes sin acceso

- **GIVEN** un usuario con plan 'avanzado' (`hasBranchesModule = false`)
- **WHEN** navega al sidebar principal
- **THEN** el item de menú "Sucursales" no está presente en el DOM (no solo oculto con CSS)

### Requirement: La capa Edge Function no redefine el plan efectivo

Ninguna Edge Function SHALL implementar su propia lógica de plan efectivo ni derivarla de `public.profiles`. El plan efectivo SHALL obtenerse de la definición normativa de la base de datos (`public.get_effective_plan`), invocada a través de un único módulo compartido en `supabase/functions/_shared/`.

La resolución SHALL derivar la cuenta del usuario autenticado a partir de su propia identidad, de modo que una Edge Function NOT SHALL poder obtener el plan efectivo de una cuenta ajena.

Cuando el plan efectivo no pueda resolverse, la resolución SHALL degradar a `'gratis'` (fail-closed), nunca a un plan superior, y SHALL registrar el error para que la degradación sea observable.

#### Scenario: La cuenta que pagó recibe el plan que pagó
- **GIVEN** una cuenta con `accounts.billing_plan = 'pro'` cuyo registro en `profiles` conserva el valor por defecto `'gratis'`
- **WHEN** cualquier miembro de esa cuenta invoca una Edge Function que aplica gating por plan
- **THEN** el plan efectivo usado para decidir es `'pro'`

#### Scenario: La cuenta exenta es reconocida por las Edge Functions
- **GIVEN** una cuenta con `accounts.billing_exempt = true`
- **WHEN** un miembro invoca una Edge Function que aplica gating por plan
- **THEN** el plan efectivo usado para decidir es `'pro'`

#### Scenario: `billing_status` no altera la decisión de una Edge Function
- **GIVEN** dos cuentas con idéntico `billing_plan`, `trial_plan` y `trial_expires_at`, que difieren solo en `billing_status`
- **WHEN** ambas invocan la misma Edge Function
- **THEN** el plan efectivo resuelto es el mismo para las dos

#### Scenario: El trial vencido cae al plan base sin depender de ningún barrido
- **GIVEN** una cuenta con `trial_plan = 'pro'` y `trial_expires_at` en el pasado, sobre la que el barrido de vencimiento todavía no corrió
- **WHEN** invoca una Edge Function que aplica gating por plan
- **THEN** el plan efectivo resuelto es su `billing_plan`, no `'pro'`

#### Scenario: Un fallo al resolver el plan degrada a gratis
- **GIVEN** que la resolución del plan efectivo falla por un error transitorio
- **WHEN** una Edge Function necesita el plan para decidir
- **THEN** usa `'gratis'` y registra el error, en lugar de conceder un plan superior

#### Scenario: Una Edge Function no puede consultar el plan de otra cuenta
- **GIVEN** un usuario autenticado miembro de una cuenta
- **WHEN** se resuelve el plan efectivo desde una Edge Function
- **THEN** la cuenta evaluada es una de las cuentas del propio usuario, sin admitir un identificador de cuenta provisto por el llamador

#### Scenario: Un usuario miembro de varias cuentas resuelve de forma determinista
- **GIVEN** un usuario que pertenece a más de una cuenta
- **WHEN** se resuelve su plan efectivo desde una Edge Function
- **THEN** la resolución selecciona siempre la misma cuenta según una regla documentada, sin producir error

### Requirement: El enforcement de límites no destruye datos existentes

Cuando el plan efectivo de una cuenta baja y sus recursos existentes superan el límite del plan nuevo, el sistema NOT SHALL borrar, archivar, ocultar ni impedir la lectura o edición de esos recursos. Sólo la creación de recursos nuevos del tipo excedido SHALL bloquearse.

#### Scenario: Bajar de plan no borra nada
- **GIVEN** una cuenta con 2372 productos cuyo plan efectivo pasa de 'pro' a 'gratis'
- **WHEN** se consulta la cantidad de productos vivos de la cuenta
- **THEN** siguen siendo 2372

#### Scenario: El recurso excedido se puede editar y borrar
- **GIVEN** una cuenta en excedente de productos
- **WHEN** edita o borra uno de sus productos
- **THEN** la operación es permitida

### Requirement: El límite de historial es enforceable en el servidor, no sólo en la interfaz

`plan_limits.history_days` SHALL tratarse como un límite **enforceable**, no como una sugerencia de presentación: todo read-model que exponga una ventana temporal elegida por el usuario SHALL recortar esa ventana al historial que el plan de la cuenta habilita, dentro del propio read-model.

La resolución del plan efectivo para este recorte SHALL hacerse contra la base de datos por la definición normativa única de plan efectivo, y NOT SHALL derivarse de la información de plan que viaja en el token de acceso: mientras esa información no viaje de forma garantizada, el camino que la lee cae a un valor por defecto permisivo y el límite deja de existir sin que nada falle.

El recorte SHALL preservar el acceso al módulo —recorta la ventana, no rechaza la consulta— y el read-model SHALL informar la ventana efectivamente aplicada, de modo que la superficie pueda explicar el recorte en lugar de mostrar un período vacío sin causa aparente.

#### Scenario: El recorte ocurre aunque el cliente pida más

- **GIVEN** una cuenta cuyo plan habilita 30 días de historial
- **WHEN** se consulta un read-model con una ventana de 365 días, sin pasar por la interfaz
- **THEN** el resultado cubre únicamente los últimos 30 días

#### Scenario: El límite no depende del claim de plan del token

- **GIVEN** un token de acceso que no transporta información de plan
- **WHEN** se consulta un read-model con ventana temporal
- **THEN** el historial aplicado es el del plan efectivo de la cuenta resuelto contra la base, no el del valor por defecto del camino que lee el token

#### Scenario: La ventana aplicada viaja en la respuesta

- **WHEN** un read-model recorta la ventana solicitada
- **THEN** informa la ventana que efectivamente aplicó

#### Scenario: Recorte, no rechazo

- **GIVEN** un usuario del plan más restrictivo
- **WHEN** solicita una ventana mayor a la que su plan habilita
- **THEN** recibe los datos de la ventana recortada, no un error de autorización

### Requirement: El enforcement del backend deriva el plan del token, no de un valor optimista

El enforcement de límites por plan que realiza el backend SHALL derivar el plan efectivo del claim de plan del token de acceso, que refleja el plan de la cuenta activa con el período de prueba vigente teniendo precedencia.

La ausencia de información de plan NOT SHALL resolverse concediendo el plan más alto. Mientras convivan tokens emitidos antes de habilitar la emisión de claims, el backend PUEDE aplicar un valor de transición explícitamente documentado como tal; ese valor de transición NOT SHALL sobrevivir al cierre de la ventana de convivencia.

#### Scenario: El límite aplicado corresponde al plan de la cuenta

- **GIVEN** una cuenta con plan básico cuyo token trae el claim de plan
- **WHEN** un miembro de esa cuenta intenta superar el límite de recursos del plan básico
- **THEN** la operación se rechaza indicando el límite del plan básico, en lugar de aplicar el límite de un plan superior

#### Scenario: Un período de prueba vigente eleva el límite aplicado

- **GIVEN** una cuenta con plan básico y un período de prueba vigente de un plan superior
- **WHEN** un miembro de esa cuenta consume recursos por encima del límite del plan básico y por debajo del límite del plan de prueba
- **THEN** la operación se permite

#### Scenario: Los recursos existentes por encima del límite no se destruyen al empezar a enforcar

- **GIVEN** una cuenta cuyo consumo actual ya supera el límite de su plan
- **WHEN** empieza a aplicarse el límite real de su plan
- **THEN** los recursos ya existentes se conservan y siguen siendo legibles y editables, y lo que se impide es la creación de recursos nuevos

