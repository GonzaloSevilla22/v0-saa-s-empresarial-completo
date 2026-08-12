# admin-analytics-kpis Specification

## Purpose

El motor de KPIs de los paneles de administración (`/admin/analytics`, `/admin/metricas`, `/admin/metricas/*`). Define dónde vive cada definición (SQL, no cliente), cómo se cuentan personas contra eventos, de qué fuente sale el MRR, cómo se define la retención por cohorte, y cómo se declara la cobertura de datos cuando la telemetría tiene huecos.

## Requirements

### Requirement: Las definiciones de los KPI admin viven en la base de datos
El sistema SHALL calcular cada KPI de cabecera de los paneles de administración dentro de la RPC que lo sirve, y el cliente SHALL limitarse a presentar los valores recibidos sin agregarlos, promediarlos ni re-filtrarlos.

Toda agregación en el cliente es una segunda definición de la métrica: no la cubre ningún test de base de datos, no la ve ningún otro consumidor y se desincroniza de la definición SQL en la primera corrección que se aplique de un solo lado. Los KPI de cabecera viajan en el objeto `summary` de `rpc_admin_kpi_overview`; los arrays de series (`time_series`, `insights_breakdown`, `community_engagement`) siguen siendo insumo de gráficos, no de tarjetas.

#### Scenario: El panel no recalcula un KPI que la RPC ya resuelve
- **WHEN** un panel admin muestra usuarios de comunidad, activaciones, UMV, total de insights, tasa UMV o promedio de días activos por usuario-semana
- **THEN** el valor mostrado proviene de un campo de `summary` devuelto por la RPC
- **AND** el código del panel no contiene ninguna reducción, suma ni división sobre las series para obtener ese valor

#### Scenario: Una corrección de definición se aplica en un solo lugar
- **WHEN** cambia la definición de un KPI de cabecera
- **THEN** el cambio se realiza en la RPC y ningún panel necesita modificarse para reflejarlo

#### Scenario: Cada serie de un gráfico tiene una única fuente
- **WHEN** un panel admin grafica una serie temporal o una distribución de uso
- **THEN** los datos provienen de la RPC que ya produce esa serie
- **AND** ninguna otra RPC duplica esa misma serie en su respuesta

### Requirement: Los conteos de personas cuentan personas
El sistema SHALL calcular todo KPI cuyo nombre refiera a usuarios como `COUNT(DISTINCT user_id)` sobre el rango completo consultado, y no como suma de conteos parciales por período, por tipo de evento ni por ninguna otra dimensión de agrupación.

El nombre del campo declara su unidad: los campos de usuarios cuentan personas distintas, los campos de eventos cuentan eventos y los de interacciones cuentan filas transaccionales. La confusión entre unidades es la causa directa del KPI "Usuarios Comunidad", que sumaba usuarios activos ya agrupados por período y por `event_name`: una persona que publicó y respondió en tres días distintos contaba seis veces.

#### Scenario: Una persona activa varios días cuenta una vez
- **WHEN** un usuario genera actividad de comunidad en varios días distintos dentro del rango consultado
- **THEN** el KPI de usuarios de comunidad lo cuenta exactamente una vez

#### Scenario: Una persona con varios tipos de actividad cuenta una vez
- **WHEN** un usuario publica un post y además responde a otro dentro del rango consultado
- **THEN** el KPI de usuarios de comunidad lo cuenta exactamente una vez

#### Scenario: Personas distintas suman
- **WHEN** tres usuarios distintos generan actividad de comunidad dentro del rango consultado
- **THEN** el KPI de usuarios de comunidad vale tres

#### Scenario: Activaciones y UMV cuentan usuarios distintos del rango
- **WHEN** el rango consultado abarca varios períodos de la serie temporal
- **THEN** el total de activaciones y el total de UMV del `summary` son conteos de usuarios distintos sobre todo el rango, no la suma de los conteos por período

### Requirement: La ventana de observación de las cohortes la declara la RPC
El sistema SHALL devolver, para cada cohorte de retención, la ventana de observación con la que fue evaluada y si la cohorte ya vivió esa ventana completa, de modo que ningún consumidor necesite conocer ni replicar la ventana para decidir qué cohortes son comparables.

Hoy el panel descarta cohortes restando 37 días hardcodeados en el cliente: si la RPC cambia su ventana, el filtro del cliente queda desalineado en silencio y el panel muestra como madura una cohorte que no lo es. La madurez se evalúa en SQL contra la hora del servidor.

#### Scenario: La cohorte informa su ventana y su madurez
- **WHEN** un consumidor pide las cohortes de retención
- **THEN** cada fila incluye la ventana de observación en días y un indicador de madurez

#### Scenario: Una cohorte reciente se marca como no madura
- **WHEN** una cohorte se activó hace menos días que su ventana de observación
- **THEN** la fila de esa cohorte se marca como no madura

#### Scenario: El panel filtra por el indicador, no por aritmética de fechas
- **WHEN** el panel selecciona la última cohorte con dato representativo
- **THEN** usa el indicador de madurez devuelto por la RPC
- **AND** el código del panel no contiene ninguna constante de días de retención

### Requirement: Los paneles declaran la cobertura de los datos que muestran
El sistema SHALL exponer en la respuesta de los KPI admin la fecha del evento de operación más reciente y su antigüedad en días, y el panel SHALL advertir visiblemente cuando esa antigüedad supere el umbral configurado.

Un panel que muestra cero sin declarar cobertura es indistinguible de un panel que informa que el negocio se detuvo. Entre junio y agosto de 2026 la telemetría de operaciones no tuvo emisor: la frecuencia semanal, la retención y la UMV de ese período son huecos de medición, no hechos del negocio, y el panel debe decirlo.

#### Scenario: La respuesta informa la cobertura
- **WHEN** un consumidor pide los KPI de cabecera
- **THEN** la respuesta incluye la fecha del último evento de operación registrado y su antigüedad en días

#### Scenario: Telemetría estancada produce un aviso
- **WHEN** el evento de operación más reciente es más antiguo que el umbral configurado
- **THEN** el panel muestra un aviso de cobertura de datos junto a las métricas afectadas

#### Scenario: Telemetría al día no produce aviso
- **WHEN** existen eventos de operación dentro del umbral configurado
- **THEN** el panel no muestra el aviso de cobertura

### Requirement: La actividad de comunidad se mide sobre las tablas transaccionales
El sistema SHALL calcular los KPI de comunidad —interacciones, actividad por módulo y pools activos— consultando las tablas del schema `community` con el schema calificado explícitamente, y no la tabla de eventos de analítica.

Los eventos de comunidad nunca tuvieron un emisor confiable: hay seis eventos `post_created` y ninguno `reply_created` contra cinco publicaciones y cuatro respuestas reales. Además, desde la separación del schema de comunidad las funciones que leen esas tablas sin calificar el schema fallan en ejecución, porque `search_path` apunta a `public`. La calificación explícita, en lugar de ampliar `search_path`, mantiene visible cualquier movimiento futuro de tablas.

#### Scenario: El conteo de interacciones refleja las filas reales
- **WHEN** existen publicaciones y respuestas creadas dentro del rango consultado
- **THEN** el total de interacciones de comunidad es la suma de publicaciones y respuestas de ese rango

#### Scenario: El panel de comunidad responde sin error de relación inexistente
- **WHEN** un administrador abre el detalle de métricas del módulo de comunidad
- **THEN** la RPC devuelve el resumen y la serie temporal sin fallar por una relación inexistente

#### Scenario: Los pools activos se cuentan, no se asumen
- **WHEN** un consumidor pide los KPI de negocio
- **THEN** la cantidad de pools activos es el conteo real de pools en el schema de comunidad
- **AND** vale cero cuando no existe ningún pool

#### Scenario: El conteo de interacciones tiene una sola implementación
- **WHEN** más de una RPC admin necesita el total de interacciones de comunidad
- **THEN** todas reutilizan la misma función de conteo en lugar de reimplementarla

### Requirement: El MRR proviene del motor de billing vigente
El sistema SHALL calcular el MRR a partir del plan efectivo de cada cuenta y del precio vigente de ese plan, tomando el importe de la suscripción real cuando exista una suscripción viva para la cuenta, y SHALL excluir del MRR las cuentas en período de prueba y las cuentas exentas.

La columna legacy de plan del perfil no la escribe el motor de billing y valía `pro` en la totalidad de los perfiles de producción, de modo que el MRR reportado y la tasa de conversión eran ficciones: la cifra publicada correspondía a treinta y cinco cuentas cuando existe una sola cuenta paga real. El precio no se hardcodea: vive en la tabla de límites de plan, en pesos argentinos, para los cuatro tiers. El plan efectivo de cada cuenta se deriva de la función normativa única del motor de billing — ningún consumidor re-implementa esa lógica por su cuenta. Sign-off del PO 2026-08-12 (OQ-4): fuente = plan efectivo × tarifa vigente, con el importe de una suscripción viva como término preferente cuando existe.

#### Scenario: Una cuenta paga aporta el precio de su plan efectivo
- **WHEN** una cuenta tiene un plan pago vigente y no tiene suscripción registrada
- **THEN** aporta al MRR el precio mensual vigente de ese plan

#### Scenario: Una suscripción viva manda sobre la tarifa de lista
- **WHEN** una cuenta tiene una suscripción autorizada con importe propio
- **THEN** aporta al MRR el importe de esa suscripción y no el precio de lista del plan

#### Scenario: Un período de prueba no es ingreso
- **WHEN** una cuenta accede a un plan pago por un período de prueba vigente
- **THEN** no aporta nada al MRR

#### Scenario: Una cuenta exenta no es ingreso
- **WHEN** una cuenta tiene exención de cortesía sobre un plan pago
- **THEN** no aporta nada al MRR

#### Scenario: Las poblaciones de billing se informan por separado
- **WHEN** un consumidor pide los KPI de negocio
- **THEN** la respuesta distingue cuentas pagas, en prueba, exentas y gratuitas
- **AND** informa la moneda del MRR

### Requirement: La retención por cohorte responde a una definición única y comparable
El sistema SHALL evaluar la retención de cada cohorte sobre un horizonte de observación idéntico para todas las cohortes comparadas, contado desde la activación de cada usuario, y SHALL exponer ese horizonte junto al resultado.

La visión del producto define la retención como seguir operando a los treinta días o más, mientras que una ventana de observación abierta hace subir la retención de las cohortes viejas por el solo paso del tiempo y las vuelve incomparables entre las cohortes recientes. Sign-off del PO 2026-08-12 (OQ-5, cierra PA-07): horizonte común censurado, con el usuario retenido si opera entre el día treinta y el fin del horizonte desde su activación; sólo se comparan cohortes que ya vivieron el horizonte completo.

#### Scenario: Un usuario que vuelve dentro del horizonte cuenta como retenido
- **WHEN** un usuario registra una operación después del día treinta desde su activación y dentro del horizonte de observación
- **THEN** se lo cuenta como retenido en su cohorte

#### Scenario: Un usuario que sólo opera antes del día treinta no cuenta como retenido
- **WHEN** un usuario opera únicamente durante los primeros treinta días desde su activación
- **THEN** no se lo cuenta como retenido en su cohorte

#### Scenario: Todas las cohortes comparadas usan el mismo horizonte
- **WHEN** el panel muestra varias cohortes en una misma serie
- **THEN** todas fueron evaluadas con el mismo horizonte de observación
- **AND** ese horizonte viaja en la respuesta

#### Scenario: Una cohorte que no completó el horizonte no se compara
- **WHEN** una cohorte es más joven que el horizonte de observación
- **THEN** se la marca como no madura y el panel no la usa como dato representativo

### Requirement: Redefinir una RPC admin conserva su superficie de autorización
El sistema SHALL mantener, después de cualquier redefinición de las RPCs de analítica admin, exactamente una definición por nombre de función, el permiso de ejecución para el rol autenticado, la ausencia de permiso para el rol anónimo y el rechazo de toda llamada de un usuario que no sea administrador.

Recrear una función borra sus permisos y agregarle un parámetro sin eliminar la firma previa deja dos definiciones conviviendo, de modo que el enrutador de API puede elegir la que no corresponde. Ambos efectos son silenciosos: la función sigue existiendo y el panel falla en producción, no en la migración.

#### Scenario: La función redefinida tiene una sola definición
- **WHEN** una migración recrea una RPC de analítica admin
- **THEN** existe exactamente una definición de esa función en el schema

#### Scenario: Los permisos sobreviven a la recreación
- **WHEN** una migración elimina y vuelve a crear una RPC de analítica admin
- **THEN** el rol autenticado conserva el permiso de ejecución
- **AND** el rol anónimo no tiene permiso de ejecución

#### Scenario: Un usuario no administrador no obtiene métricas
- **WHEN** un usuario autenticado sin rol de administrador invoca una RPC de analítica admin
- **THEN** la llamada es rechazada y no devuelve datos
