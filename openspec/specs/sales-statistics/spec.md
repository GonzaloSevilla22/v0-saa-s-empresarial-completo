# sales-statistics Specification

## Purpose
Módulo de estadísticas de ventas (`/estadisticas`, sin gate de plan): evolución temporal con comparación de período, desgloses por canal, sucursal, día de la semana, horario de carga y categoría de producto (todos comparten la misma forma de salida — una RPC por forma, `rpc_sales_breakdown`), top de clientes, y análisis con IA. Define el **helper canónico compartido** (`reporting_sales_lines_in_window`) del que deriva su población de líneas todo agregado del módulo — y del que también depende `product-profitability` — de modo que ningún consumidor reimplemente el revenue de línea o los bordes del período por su cuenta. El límite de historial por plan se aplica en el read-model, nunca sólo en la interfaz.

## Requirements

### Requirement: Definición única de "línea de venta del período"

Todo agregado del módulo de estadísticas SHALL derivar su conjunto de líneas de un **helper canónico compartido** que resuelve, en un solo lugar: el revenue de línea (`COALESCE(total, amount)`), los bordes del período en fecha local del tenant (`>= inicio` y `< fin + 1 día`), el filtro de cuenta, y los filtros opcionales de sucursal y canal aplicados uniformemente a todos los términos.

Ningún agregado del módulo SHALL escribir su propia expresión de revenue en el punto de uso, conforme al requirement "Enforcement de consumo" de la capability `reporting-invariants`. El mismo helper SHALL ser consumido también por el read-model de rentabilidad por producto, de modo que la agregación de ventas por producto exista una sola vez en la base.

#### Scenario: Dos agregados del módulo informan la misma facturación

- **GIVEN** una cuenta con ventas en un período
- **WHEN** se consultan la evolución temporal y el desglose por canal sobre la misma ventana, la misma cuenta y el mismo filtro de sucursal
- **THEN** la suma de la facturación de ambos es idéntica

#### Scenario: El módulo coincide con el read-model del Tablero

- **GIVEN** una ventana con ventas y al menos una nota de crédito
- **WHEN** se compara la facturación total del módulo de estadísticas con la del read-model canónico del Tablero sobre esa misma ventana y cuenta
- **THEN** ambas informan el mismo importe

#### Scenario: Venta multi-unidad aporta su total de línea

- **GIVEN** una venta de 2 unidades a precio unitario $1.000 (`amount = 1000`, `quantity = 2`, `total = 2000`)
- **WHEN** cualquier agregado del módulo suma la facturación del período
- **THEN** esa línea aporta $2.000, no $1.000

#### Scenario: El día final del rango se incluye completo

- **GIVEN** una venta cuya fecha de negocio es el último día del rango consultado
- **WHEN** se consulta cualquier agregado del módulo con ese rango
- **THEN** la venta está incluida

### Requirement: Evolución de ventas en el tiempo con comparación de período

El sistema SHALL exponer la evolución de las ventas de la cuenta agrupada por **día, semana o mes**, sobre un rango elegido por el usuario, informando por cada intervalo la facturación, las unidades y la cantidad de operaciones.

El conteo de operaciones SHALL usar `COUNT(DISTINCT COALESCE(operation_id, id))`, de modo que una operación multi-línea cuente una sola vez y las ventas legacy sin `operation_id` cuenten una cada una.

El sistema SHALL informar además los mismos totales para el **período inmediatamente anterior de igual longitud**, para permitir la comparación. La agrupación semanal SHALL comenzar los lunes.

La evolución SHALL restar las notas de crédito del período a través del helper único de notas de crédito que ya consumen los read-models diario y mensual — nunca reimplementando la regla.

#### Scenario: Evolución diaria con comparación

- **GIVEN** una cuenta con ventas en los últimos 30 días y en los 30 anteriores
- **WHEN** se consulta la evolución diaria de los últimos 30 días
- **THEN** se devuelve un punto por día con facturación, unidades y operaciones
- **AND** se devuelven los totales del período anterior de 30 días para comparar

#### Scenario: La semana empieza el lunes

- **GIVEN** ventas registradas un domingo y el lunes siguiente
- **WHEN** se consulta la evolución agrupada por semana
- **THEN** ambas ventas caen en semanas distintas, y la del lunes abre la semana siguiente

#### Scenario: Una operación multi-línea cuenta una vez

- **GIVEN** una venta de 3 productos registrada en una sola operación
- **WHEN** se consulta la evolución del período que la contiene
- **THEN** ese intervalo cuenta exactamente 1 operación

#### Scenario: La nota de crédito resta en la evolución

- **GIVEN** un período con $10.000 facturados y una nota de crédito de $1.000 emitida en ese período
- **WHEN** se consulta la evolución del período
- **THEN** la facturación del período es $9.000

### Requirement: Desglose por canal y por sucursal con tramo explícito para lo no imputado

El sistema SHALL exponer la facturación, las unidades y las operaciones del período desglosadas **por canal de venta** y **por sucursal**.

Las ventas sin canal o sin sucursal SHALL aparecer como un tramo propio y visible ("Sin canal" / "Sin sucursal"), NUNCA omitidas del resultado: en producción son la mayoría de las operaciones, y omitirlas haría que el desglose informe menos facturación que el total del período. La suma de los tramos SHALL ser igual al total del período.

#### Scenario: Las ventas sin canal aparecen en su propio tramo

- **GIVEN** un período con ventas con canal y ventas sin canal
- **WHEN** se consulta el desglose por canal
- **THEN** existe un tramo explícito para las ventas sin canal con su importe
- **AND** la suma de todos los tramos es igual a la facturación total del período

#### Scenario: Las ventas sin sucursal aparecen en su propio tramo

- **GIVEN** un período con ventas sin sucursal asignada
- **WHEN** se consulta el desglose por sucursal
- **THEN** existe un tramo explícito para las ventas sin sucursal con su importe

#### Scenario: El desglose no resta notas de crédito y lo declara

- **GIVEN** un período con una nota de crédito
- **WHEN** se consulta el desglose por canal o por sucursal
- **THEN** la nota de crédito no se resta de ningún tramo
- **AND** la superficie que lo muestra declara esa exclusión al usuario

### Requirement: Desglose por categoría de producto con tramo explícito para lo no imputado

El sistema SHALL exponer la facturación, las unidades y las operaciones del período desglosadas **por categoría de producto**, resuelta desde `products.category_id` del catálogo de la cuenta (capability `product-category`) y compartiendo la misma forma de salida que los desgloses por canal, sucursal, día de la semana y horario — es una dimensión más del mismo mecanismo, no una vista del ranking de productos.

Los productos sin categoría asignada SHALL aparecer como un tramo propio y visible ("Sin categoría"), NUNCA omitidos. Las líneas de venta sin producto asociado (líneas de servicio) NO SHALL contarse en este desglose — no son productos y no tienen categoría — y su importe queda declarado por la evolución de ventas del módulo, no por este desglose.

#### Scenario: Facturación por categoría

- **GIVEN** un período con ventas de productos de varias categorías
- **WHEN** se consulta el desglose por categoría
- **THEN** se devuelve una fila por categoría con su facturación, sus unidades y sus operaciones

#### Scenario: Los productos sin categoría aparecen en su propio tramo

- **GIVEN** un período con ventas de productos sin categoría asignada
- **WHEN** se consulta el desglose por categoría
- **THEN** existe un tramo explícito "Sin categoría" con su importe

#### Scenario: Las líneas de servicio quedan fuera del desglose por categoría

- **GIVEN** un período con líneas de venta sin producto asociado
- **WHEN** se consulta el desglose por categoría
- **THEN** ninguna fila ni tramo del desglose las incluye

### Requirement: Patrones de venta por día de la semana

El sistema SHALL exponer la facturación, las unidades y las operaciones del período agrupadas por **día de la semana** (lunes a domingo), derivadas de la **fecha de negocio declarada** de la venta.

El día de la semana SHALL derivarse de la fecha de negocio sin conversión de zona horaria, conforme al invariante de la capability `reporting-invariants` que distingue fecha de negocio de instante: convertir de zona una fecha de negocio desplaza cada venta un día, y con ello el día de la semana que informa.

#### Scenario: La venta de un lunes se informa como lunes

- **GIVEN** una venta cuya fecha de negocio declarada es un lunes
- **WHEN** se consulta el patrón por día de la semana
- **THEN** esa venta aporta al lunes, no al domingo

#### Scenario: Los siete días están representados

- **GIVEN** un período con ventas en algunos días de la semana
- **WHEN** se consulta el patrón por día de la semana
- **THEN** los días sin ventas se informan en cero, no se omiten

### Requirement: Patrones por horario derivados del instante de registro y rotulados como tales

El sistema SHALL exponer la distribución de las operaciones del período por **hora del día**, derivada del **instante de registro** de la operación (`created_at`) convertido a la zona horaria local del tenant.

La superficie que lo muestre SHALL rotular la métrica como horario de **registro** de la operación, NO como horario de venta, y SHALL declarar la salvedad: para las ventas cargadas en el momento coincide con la venta, y para las cargadas después no. La fecha de negocio de la venta NO SHALL usarse como fuente de esta métrica, porque no contiene hora.

#### Scenario: La hora deriva del instante de registro

- **GIVEN** una venta con fecha de negocio declarada del día anterior y registrada a las 14:00 hora local
- **WHEN** se consulta la distribución por horario
- **THEN** la operación aporta a la hora 14

#### Scenario: La superficie no promete horario de venta

- **WHEN** un usuario abre la vista de horarios
- **THEN** el rótulo describe el horario de registro de la operación y la salvedad es visible

### Requirement: Top clientes del período

El sistema SHALL exponer los clientes con mayor facturación del período, informando por cada uno su importe y su cantidad de operaciones.

Las ventas sin cliente asignado NO SHALL competir en el ranking, y su importe SHALL declararse en la superficie que lo muestra: en producción son más de un tercio de las líneas, así que ocuparían el primer puesto de forma permanente sin ser accionables, y omitirlas en silencio dejaría una diferencia inexplicada contra el total del período.

#### Scenario: Ranking de clientes por importe

- **GIVEN** un período con ventas a varios clientes
- **WHEN** se consulta el top de clientes
- **THEN** se devuelven ordenados por importe descendente, con importe y cantidad de operaciones

#### Scenario: Las ventas sin cliente no encabezan el ranking

- **GIVEN** un período donde las ventas sin cliente superan en importe a cualquier cliente identificado
- **WHEN** se consulta el top de clientes
- **THEN** ninguna fila del ranking representa "sin cliente"
- **AND** la superficie declara el importe de las ventas sin cliente

### Requirement: El límite de historial del plan se aplica en el servidor y se informa

El módulo SHALL estar disponible en **todos los planes**, sin candado de entrada. El **rango consultable** SHALL limitarse al historial que el plan de la cuenta habilita (`plan_limits.history_days`).

El límite SHALL aplicarse en el **read-model**, resolviendo el plan efectivo de la cuenta contra la base de datos: la información de plan que viaja en el token no es una fuente confiable para esta decisión, y un límite aplicado sólo en la interfaz es cooperación del cliente, no enforcement.

Un rango que exceda el historial del plan SHALL **recortarse**, no rechazarse, y el read-model SHALL devolver la ventana efectivamente aplicada para que la superficie pueda informar el recorte. Un recorte silencioso es indistinguible de un período sin ventas.

La resolución del plan SHALL ser fail-closed: una cuenta cuyo plan no se pueda determinar recibe el historial del plan más restrictivo.

#### Scenario: Un rango mayor al historial del plan se recorta

- **GIVEN** una cuenta cuyo plan habilita 30 días de historial
- **WHEN** consulta cualquier agregado del módulo con un rango de 365 días
- **THEN** el resultado cubre únicamente los últimos 30 días
- **AND** el read-model informa la ventana efectivamente aplicada

#### Scenario: El recorte es visible para el usuario

- **GIVEN** una consulta cuyo rango fue recortado por el plan
- **WHEN** el usuario ve el resultado
- **THEN** la superficie le informa que su plan limita el historial consultable

#### Scenario: El límite no depende del cliente

- **GIVEN** un cliente que solicita un rango mayor al que su plan habilita, sin pasar por la interfaz
- **WHEN** el read-model responde
- **THEN** el resultado sigue recortado al historial del plan

#### Scenario: Cuenta sin plan determinable

- **GIVEN** una cuenta cuyo plan efectivo no se puede resolver
- **WHEN** consulta el módulo
- **THEN** se le aplica el historial del plan más restrictivo

#### Scenario: El módulo es accesible en el plan gratuito

- **GIVEN** un usuario con plan gratuito
- **WHEN** abre el módulo de estadísticas
- **THEN** ve el contenido del módulo, con su rango limitado, y no un componente de upgrade

### Requirement: Superficie del módulo de estadísticas

El sistema SHALL proveer la pantalla `/estadisticas`, alcanzable desde una entrada propia en el grupo "Inteligencia" del menú lateral, sin gate de plan.

La pantalla SHALL permitir elegir el rango de fechas y la granularidad temporal, y SHALL presentar la evolución, los desgloses por dimensión y el top de clientes. SHALL declarar al pie qué queda excluido de cada agregado (notas de crédito en los desgloses, ventas sin cliente en el top).

La superficie SHALL funcionar en tema claro y oscuro, en escritorio y móvil, usando los tokens semánticos del sistema de diseño, y toda tabla de varias columnas SHALL ser desplazable horizontalmente dentro de su contenedor sin desbordar el shell.

#### Scenario: La pantalla es alcanzable desde el menú

- **GIVEN** un usuario autenticado de cualquier plan
- **WHEN** abre el menú lateral
- **THEN** existe una entrada al módulo de estadísticas en el grupo "Inteligencia" que lleva a `/estadisticas`

#### Scenario: Período sin ventas

- **GIVEN** un rango sin ninguna venta
- **WHEN** el usuario lo consulta
- **THEN** la pantalla muestra un estado vacío explicativo, distinguible de un estado de error

#### Scenario: Fallo de carga visible

- **WHEN** la consulta de un agregado falla
- **THEN** la pantalla muestra un estado de error visible, nunca presentando el fallo como "sin datos"

#### Scenario: La tabla no desborda en móvil

- **GIVEN** la pantalla en un viewport móvil
- **WHEN** se muestra una tabla de varias columnas
- **THEN** la tabla se desplaza horizontalmente dentro de su contenedor y el documento no desborda

### Requirement: Análisis IA del módulo de estadísticas

El sistema SHALL proveer una Edge Function `ai-estadisticas` que genere un análisis en lenguaje natural de las estadísticas del período.

La función SHALL verificar la cuota de IA del usuario antes de consultar al modelo, SHALL derivar sus datos de los read-models canónicos del módulo —nunca agregando ventas por su cuenta—, SHALL persistir el análisis generado en la tabla canónica de insights, y SHALL incrementar el contador de uso sólo cuando el análisis se generó.

#### Scenario: Genera el análisis con cuota disponible

- **GIVEN** un usuario con cuota de IA disponible y ventas en el período
- **WHEN** solicita el análisis con IA desde el módulo
- **THEN** se genera un análisis, se persiste como insight y se incrementa el contador de uso

#### Scenario: Cuota agotada

- **GIVEN** un usuario que agotó su cuota de IA del mes
- **WHEN** solicita el análisis
- **THEN** la función responde con el error de cuota excedida y no consulta al modelo

#### Scenario: El modelo no responde

- **GIVEN** que el proveedor de IA no responde dentro del tiempo límite
- **WHEN** se solicita el análisis
- **THEN** la función devuelve una respuesta de fallback sin persistir insight ni incrementar el contador

#### Scenario: La IA no reimplementa los agregados

- **WHEN** la función construye el contexto que envía al modelo
- **THEN** las cifras provienen de los read-models canónicos del módulo, no de una agregación propia

