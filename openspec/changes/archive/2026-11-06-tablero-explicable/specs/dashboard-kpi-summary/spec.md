## ADDED Requirements

### Requirement: Cada tarjeta KPI del Tablero explica de dónde sale su número
Las tarjetas «Ganancia Neta», «Margen por Canal», «Stock sin Rotación», «Costo por Venta», «Ticket Promedio», «Ventas del mes», «Gastos del mes», «Ganancia neta del mes» y «Productos en alerta» del Tablero SHALL ser botones accesibles que abren un diálogo superpuesto con el origen del número; la tarjeta «Por cobrar» SHALL conservar su enlace a `/cobranzas` y NOT SHALL abrir el diálogo. El diálogo SHALL mostrar, en lenguaje llano: qué mide el número, la cuenta con la que se obtiene, el período y los filtros que aplican en ese momento (mes del selector de período —o «ahora» para «Productos en alerta»—, sucursal del filtro activo o «Todas», y el mes contra el que compara el badge cuando corresponde), de qué datos sale, qué no incluye, y un enlace a la pantalla donde se ve el detalle. Los textos SHALL salir de un único catálogo del frontend redactado contra la definición vigente de la RPC que calcula cada tarjeta, y NOT SHALL contradecirla: en particular, «Ticket Promedio» y «Margen por Canal» SHALL decir que no restan notas de crédito, «Gastos del mes» SHALL decir que no incluye compras, y «Ganancia neta del mes» SHALL decir que resta las compras. El diálogo SHALL cerrarse con una cruz visible, con `Esc` y con un clic fuera, SHALL atrapar el foco mientras está abierto y SHALL devolverlo a la tarjeta al cerrarse. Las tarjetas que se reutilizan fuera del Tablero NOT SHALL cambiar de comportamiento.

#### Scenario: Abrir el origen de una tarjeta
- **WHEN** el usuario hace clic (o Enter/Espacio con el foco) en la tarjeta «Ganancia neta del mes»
- **THEN** se abre un diálogo titulado «Ganancia neta del mes» con la cuenta «Ventas del mes − Gastos del mes − Compras del mes», el mes y la sucursal vigentes, la fuente, lo que no incluye y un enlace a la pantalla de detalle

#### Scenario: El contexto del diálogo sigue a los filtros del Tablero
- **GIVEN** el Tablero con `?period=2026-10` y una sucursal «Centro» seleccionada
- **WHEN** el usuario abre el diálogo de «Ticket Promedio»
- **THEN** el diálogo dice que el período es octubre de 2026, que compara contra septiembre de 2026 y que la sucursal es «Centro»

#### Scenario: Productos en alerta es una foto de ahora
- **WHEN** el usuario abre el diálogo de «Productos en alerta» con un mes anterior seleccionado
- **THEN** el diálogo dice que el número es de ahora y no depende del mes elegido

#### Scenario: Cerrar con la cruz o con Esc devuelve el foco
- **WHEN** el diálogo está abierto y el usuario toca la cruz o presiona `Esc`
- **THEN** el diálogo se cierra y el foco vuelve a la tarjeta que lo abrió

#### Scenario: Por cobrar sigue llevando a Cobranzas
- **WHEN** el usuario hace clic en «Por cobrar»
- **THEN** navega a `/cobranzas` y no se abre ningún diálogo

#### Scenario: Las tarjetas fuera del Tablero no cambian
- **WHEN** se renderiza una tarjeta de `/estadisticas` o de `/admin/analytics` sin explicación configurada
- **THEN** se ve y se comporta igual que antes de este cambio (no es un botón ni abre diálogo)

### Requirement: Gráfico de ventas del Tablero con rango elegible y comparación con el período anterior
El gráfico de ventas del Tablero SHALL permitir elegir el rango entre «7 días» (por defecto), «30 días», «90 días» y un rango personalizado de dos fechas, y SHALL mostrar la serie del período inmediatamente anterior de igual longitud junto con la variación porcentual del total. Los datos SHALL salir del read-model canónico de evolución de ventas (`rpc_sales_evolution` vía `GET /reports/statistics/evolution`, capability `sales-statistics`): la facturación graficada es neta de notas de crédito, el filtro de sucursal activo del Tablero SHALL aplicarse, y el recorte de historial del plan lo aplica el servidor. NOT SHALL agregarse ventas en el cliente a partir de un listado paginado. La granularidad SHALL elegirse por el largo del rango (hasta 31 días por día, hasta 180 por semana, más por mes). Cuando el período anterior cae total o parcialmente fuera del historial del plan, la comparación NOT SHALL mostrarse y el gráfico SHALL decirlo con un enlace a `/planes`. El selector de período mensual del Tablero NOT SHALL cambiar el rango del gráfico. El gráfico SHALL usar los colores del design system y verse correctamente en tema claro y oscuro, en desktop y en móvil.

#### Scenario: Por defecto, últimos 7 días
- **WHEN** el usuario entra al Tablero
- **THEN** el gráfico muestra un punto por día de los últimos 7 días argentinos, hoy incluido, y la serie de los 7 días anteriores

#### Scenario: Elegir 30 días
- **WHEN** el usuario elige «30 días»
- **THEN** el gráfico muestra 30 puntos diarios, la serie de los 30 días anteriores y la variación porcentual del total

#### Scenario: Más de 25 ventas en el rango
- **GIVEN** una cuenta con 60 ventas en los últimos 7 días
- **WHEN** se renderiza el gráfico
- **THEN** la suma de los puntos es igual a la facturación neta del período que devuelve el read-model (no a la de las 25 ventas más recientes)

#### Scenario: La sucursal acota el gráfico
- **WHEN** el Tablero tiene una sucursal seleccionada
- **THEN** el gráfico y su comparación se calculan sólo para esa sucursal

#### Scenario: Período anterior fuera del historial del plan
- **GIVEN** una cuenta con 30 días de historial por su plan
- **WHEN** el usuario elige «30 días»
- **THEN** el gráfico muestra el período elegido sin la serie anterior ni la variación, con el aviso de que el período anterior queda fuera del historial y un enlace a `/planes`

#### Scenario: Rango personalizado
- **WHEN** el usuario elige «Personalizado» y dos fechas dentro del historial de su plan
- **THEN** el gráfico muestra ese rango con la granularidad que corresponde a su largo y el período anterior de igual longitud

### Requirement: Resumen IA del día visible, con estados de carga y error y sin regenerar en cada visita
La tarjeta «Resumen IA del día» SHALL mostrar el texto que genera la Edge Function `ai-resumen`, aceptando su respuesta tanto cuando trae la fila del insight guardado (texto en `message`) como cuando trae el texto crudo, y NOT SHALL mostrar un mensaje de falla cuando la función respondió con éxito. Mientras la llamada está en curso SHALL mostrarse un indicador de carga con la leyenda de que suele tardar unos segundos; la espera SHALL tener un tope que cubra toda la operación (resolución del token, petición y lectura de la respuesta), vencido el cual se muestra un error legible, de modo que la tarjeta NOT SHALL quedar en carga indefinidamente; y un desmontaje y remontaje de la tarjeta con la llamada en curso NOT SHALL perder su resultado ni disparar otra llamada. Los errores SHALL distinguir el límite mensual de IA del plan (429), la sesión vencida (401) y el resto. El botón «Regenerar» SHALL estar deshabilitado sólo mientras hay una llamada en curso y SHALL volver a pedir el resumen al tocarlo. El resumen SHALL generarse a lo sumo una vez por cuenta, día argentino y sesión de la aplicación salvo que el usuario toque «Regenerar»: volver al Tablero en la misma sesión NOT SHALL consumir otra consulta de IA.

#### Scenario: La función responde con la fila del insight
- **GIVEN** que `ai-resumen` responde `{ ok: true, data: { message: "Hoy vendiste…", … } }`
- **WHEN** la tarjeta recibe la respuesta
- **THEN** muestra «Hoy vendiste…»

#### Scenario: La función responde con el texto crudo
- **GIVEN** que `ai-resumen` responde `{ ok: true, data: "Hoy vendiste…" }`
- **WHEN** la tarjeta recibe la respuesta
- **THEN** muestra «Hoy vendiste…»

#### Scenario: Mientras se genera
- **WHEN** la llamada está en curso
- **THEN** la tarjeta muestra un indicador de carga y la leyenda de que suele tardar unos segundos, y «Regenerar» está deshabilitado
- **AND** el lugar del resumen no contiene un texto de resumen provisorio («Cargando resumen inteligente...»): el estado de carga es distinguible de un resumen

#### Scenario: La llamada no responde
- **WHEN** la llamada supera el tope de espera
- **THEN** la tarjeta muestra un error legible y «Regenerar» vuelve a estar habilitado

#### Scenario: Nunca queda cargando para siempre
- **GIVEN** que la resolución del token o la llamada a `ai-resumen` no se asienta
- **WHEN** vence el tope de espera
- **THEN** la tarjeta deja de mostrar el indicador de carga, muestra un error legible y «Regenerar» queda habilitado

#### Scenario: Un remontaje no pierde el resultado
- **GIVEN** una llamada a `ai-resumen` en curso
- **WHEN** la tarjeta se desmonta y vuelve a montarse antes de que la llamada termine
- **THEN** la tarjeta montada muestra el resultado de esa misma llamada y no se dispara una segunda

#### Scenario: Límite de IA del plan
- **WHEN** la función responde 429
- **THEN** la tarjeta dice que se alcanzó el límite mensual de consultas de IA y cuándo se reinicia

#### Scenario: Volver al Tablero no regenera
- **GIVEN** que el resumen de hoy ya se generó en esta sesión
- **WHEN** el usuario va a otra pantalla y vuelve al Tablero
- **THEN** la tarjeta muestra el mismo resumen sin invocar de nuevo a `ai-resumen`

#### Scenario: Regenerar pide uno nuevo
- **WHEN** el usuario toca «Regenerar»
- **THEN** se invoca `ai-resumen` una vez y la tarjeta muestra el texto nuevo
