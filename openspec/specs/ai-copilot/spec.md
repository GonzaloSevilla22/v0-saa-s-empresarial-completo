# ai-copilot Specification

## Purpose
TBD - created by archiving change ia-copilot-v2. Update Purpose after archive.
## Requirements
### Requirement: El Copiloto es una Edge Function de sólo lectura
El Copiloto SHALL atenderse en la Edge Function `ai-copilot` (`POST /functions/v1/ai-copilot`), autenticada con el JWT del usuario y con el cliente Supabase construido con ese JWT, y NUNCA con la service role. El Copiloto SHALL ser de sólo lectura sobre los datos del negocio: ninguna herramienta ni camino de la función crea, edita ni borra ventas, compras, gastos, stock, clientes, productos, caja, banco ni cuentas corrientes. Las únicas escrituras permitidas son el registro de la conversación (`ai_conversations`) y la reserva de cuota. La cuenta sobre la que se consulta SHALL resolverse con `current_account_ids()` y NUNCA desde un parámetro del cuerpo ni desde un argumento que elija el modelo.

#### Scenario: Sin sesión no hay respuesta
- **WHEN** llega un request sin `Authorization` válido
- **THEN** la función responde 401 `{ok:false, error:"unauthorized"}` sin reservar cuota ni llamar a OpenAI

#### Scenario: Pedido de registrar algo
- **GIVEN** un usuario con sesión y cuota
- **WHEN** pregunta «anotame un gasto de $5.000 en nafta»
- **THEN** la respuesta explica que desde el Copiloto sólo se puede consultar y dónde se registra un gasto
- **AND** no se crea ninguna fila en `expenses` ni en ninguna otra tabla del negocio

#### Scenario: El modelo no elige la cuenta
- **GIVEN** un usuario miembro de la cuenta A
- **WHEN** el modelo pide una herramienta con cualquier argumento
- **THEN** la RPC se ejecuta con `p_account_id` = la cuenta activa de A resuelta por `current_account_ids()`, y ningún argumento del modelo puede cambiarla

### Requirement: Herramientas de lectura sobre las RPCs canónicas
El Copiloto SHALL exponer al modelo un catálogo cerrado de herramientas, cada una con schema JSON estricto (`additionalProperties:false`) y traducida a una única lectura canónica: `resumen_periodo` → `rpc_dashboard_kpi_summary`; `evolucion_ventas` → `rpc_sales_evolution`; `ranking_productos` → `rpc_product_ranking`; `desglose_ventas` → `rpc_sales_breakdown`; `mejores_clientes` → `rpc_sales_top_clients`; `stock_critico` → `get_dashboard_critical_stock_items`; `buscar_producto` → `products` filtrado explícitamente por la cuenta activa; `detalle_producto` → `rpc_product_sales_evolution`; `cuentas_por_cobrar` → `rpc_receivables_report`; `cuentas_por_pagar` → `rpc_payables_report`; `comparar_periodos` → `rpc_period_comparison`; `rentabilidad_productos` → `rpc_product_profitability`. Ninguna herramienta SHALL agregar, sumar buckets ni recalcular lo que la RPC devuelve, salvo el total de cuentas por cobrar o por pagar, que SHALL sumarse sobre todas las filas de la RPC antes de recortar la lista. Toda herramienta SHALL validar sus argumentos (fechas de negocio `YYYY-MM-DD`, `desde <= hasta`, rango máximo 366 días, enumerados y límites) y SHALL recortar su resultado a su tope de filas.

#### Scenario: Cuánto vendí hoy
- **GIVEN** una cuenta con ventas hoy por $120.000 según `rpc_dashboard_kpi_summary` para la ventana de hoy
- **WHEN** el usuario pregunta «¿cuánto vendí hoy?»
- **THEN** el Copiloto llama a `resumen_periodo` con `desde = hasta = hoy` (día argentino)
- **AND** la respuesta contiene $120.000

#### Scenario: Argumento fuera de dominio
- **WHEN** el modelo pide `ranking_productos` con `limite = 500`
- **THEN** la herramienta devuelve `{error:"argumento_invalido"}` al modelo sin ejecutar la RPC
- **AND** el usuario no recibe un error HTTP por eso

#### Scenario: Una RPC falla
- **WHEN** la RPC de una herramienta devuelve error
- **THEN** la herramienta devuelve `{error:"no_disponible"}` al modelo, el fallo queda en el log con el prefijo `[ai-copilot]` y el turno continúa

#### Scenario: Dato que no tiene herramienta
- **WHEN** el usuario pregunta cuánto hay en la caja hoy
- **THEN** la respuesta dice que ese dato no está disponible desde el Copiloto y no da ninguna cifra de caja

### Requirement: Topes por pregunta
Cada pregunta SHALL tener un techo de costo: como máximo 3 rondas con herramientas y 8 llamadas a herramienta; alcanzado el tope, una llamada final sin herramientas SHALL producir la respuesta con lo obtenido. El tiempo total del turno SHALL acotarse a 45 segundos y cada llamada al modelo a 700 tokens de salida. Vencido el tiempo total, la función SHALL responder 200 `{ok:true, kind:"fallback"}` con un mensaje legible y sin reintentar el turno completo.

#### Scenario: El modelo pide herramientas sin parar
- **GIVEN** un modelo que en cada ronda pide otra herramienta
- **WHEN** se completa la tercera ronda
- **THEN** la cuarta llamada al modelo se hace sin `tools` y su texto es la respuesta

#### Scenario: Timeout total
- **WHEN** el turno supera 45 segundos
- **THEN** la respuesta es `{ok:true, kind:"fallback"}` con un mensaje para la persona, sin texto del proveedor

### Requirement: Prompt de asistente con fecha de hoy y regla de números
El system prompt del Copiloto SHALL presentarlo como asistente de gestión para microemprendedores de Mendoza, Argentina, en español rioplatense, con montos en pesos y formato `es-AR`, e SHALL incluir la fecha, el día de la semana y la hora actuales en `America/Argentina/Mendoza`, con las fechas explícitas de ayer, esta semana, la semana pasada y el mes pasado. El prompt SHALL ordenar que todo número de la respuesta salga de un resultado de herramienta o de la memoria de la conversación, que sin dato se diga que no está, que sin período se use el mes en curso aclarándolo en una línea, y que si falta el producto o el cliente y no se infiere se haga una sola pregunta corta. El prompt SHALL incluir ejemplos sacados de las preguntas reales anonimizadas.

#### Scenario: Día argentino en la franja nocturna
- **GIVEN** el instante 2026-11-07T01:30:00Z (22:30 del 6 de noviembre en Mendoza)
- **WHEN** se arma el system prompt
- **THEN** dice que hoy es viernes 6 de noviembre de 2026

#### Scenario: Pregunta sin período
- **WHEN** el usuario pregunta «¿qué producto vendí más?» sin período
- **THEN** el Copiloto consulta el mes en curso hasta hoy y la respuesta lo aclara

#### Scenario: Producto ambiguo
- **GIVEN** `buscar_producto("remera")` devuelve tres productos
- **WHEN** el usuario pregunta «¿cuántas remeras vendí?»
- **THEN** la respuesta es `kind:"clarification"` con una pregunta corta que ofrece hasta tres opciones

### Requirement: Memoria corta con estado de foco
El Copiloto SHALL recibir el historial visible de la conversación (hasta 20 mensajes, cada uno de hasta 4.000 caracteres) y SHALL recortarlo de lo más viejo a lo más nuevo hasta un presupuesto de 6.000 tokens estimados, sin cortar ningún mensaje por la mitad. El Copiloto SHALL devolver y recibir un estado de foco `{period, product, client}` validado en el servidor, que orienta los seguimientos («¿y el mes pasado?») sin poder cambiar la cuenta consultada.

#### Scenario: Seguimiento sobre el período en foco
- **GIVEN** un turno anterior que consultó ventas de octubre y devolvió `state.period = {start:"2026-10-01", end:"2026-10-31"}`
- **WHEN** el usuario pregunta «¿y el mes anterior?»
- **THEN** el Copiloto consulta septiembre de 2026

#### Scenario: Historial largo
- **GIVEN** un historial cuya estimación supera 6.000 tokens
- **WHEN** se arman los mensajes para el modelo
- **THEN** se descartan los mensajes más viejos completos hasta entrar en el presupuesto y ningún mensaje queda truncado

#### Scenario: Mensaje demasiado largo
- **WHEN** un mensaje del historial supera 4.000 caracteres
- **THEN** la función responde 400 `invalid_params` antes de reservar cuota

### Requirement: Modelo por variable con allow-list
El modelo del Copiloto SHALL resolverse desde la variable `COPILOT_AI_MODEL` contra una allow-list cerrada; un valor ausente o fuera de la lista SHALL usar el modelo por defecto y dejar una advertencia en el log. Ningún parámetro del request SHALL elegir el modelo.

#### Scenario: Variable fuera de la lista
- **WHEN** `COPILOT_AI_MODEL = "gpt-cualquiera"`
- **THEN** se usa el modelo por defecto y el log registra la advertencia

#### Scenario: El request no elige el modelo
- **WHEN** el cuerpo o un header del request nombran un modelo
- **THEN** se ignora y se usa el resuelto por la variable

### Requirement: Cuota por reserva atómica antes del modelo
Cada pregunta SHALL reservar una unidad del contador `queries` con `rpc_reserve_ai_usage('queries')`, con el cliente del usuario, después de la validación del cuerpo y antes de leer cualquier dato o llamar al modelo; las rondas de herramientas no reservan aparte. Una reserva denegada por cuota SHALL responder 429 `quota_exceeded` con `resetAt`, `used` y `limit`; por ráfaga, 429 `rate_limited` con `retryAfterSeconds` y el header `Retry-After`; una reserva que no se pudo resolver SHALL responder 503 `quota_unavailable` sin llamar a OpenAI. Una reserva concedida no se devuelve aunque el modelo falle.

#### Scenario: Cuota agotada
- **GIVEN** un usuario `gratis` con `ai_queries_used = 5`
- **WHEN** hace una pregunta
- **THEN** recibe 429 `quota_exceeded` sin que se lea ningún dato ni se llame a OpenAI

#### Scenario: Ráfaga
- **GIVEN** un usuario que hizo 5 preguntas en los últimos 60 segundos
- **WHEN** hace la sexta
- **THEN** recibe 429 `rate_limited` con `Retry-After`

#### Scenario: Una pregunta con varias herramientas cobra una vez
- **GIVEN** un usuario con `ai_queries_used = 10`
- **WHEN** hace una pregunta que usa tres herramientas en dos rondas
- **THEN** `ai_queries_used` queda en 11

### Requirement: Registro de cada turno
Cada turno que obtuvo una reserva y llegó al modelo SHALL registrarse en `ai_conversations` con `account_id` (la cuenta activa), `user_id`, pregunta, respuesta, `model`, `tools_used` (nombre, éxito, filas y duración de cada herramienta, sin argumentos de texto libre), `latency_ms`, `prompt_tokens`, `completion_tokens`, `outcome` (`answer`, `clarification`, `fallback` o `error`) y `thread_id`. El registro SHALL completarse antes de responder y su `id` SHALL devolverse como `conversation_id`; si el registro falla, la respuesta SHALL llegar igual con `conversation_id: null` y el fallo SHALL quedar en el log. Los requests rechazados antes del modelo (400, 401, 403, 429, 503) NOT SHALL dejar fila.

#### Scenario: La conversación se guarda con la cuenta
- **WHEN** un usuario de la cuenta A recibe una respuesta
- **THEN** existe una fila de `ai_conversations` con `account_id = A`, su `user_id`, el modelo usado y las herramientas llamadas
- **AND** la respuesta trae `conversation_id` con el `id` de esa fila

#### Scenario: El registro falla
- **WHEN** el insert en `ai_conversations` falla
- **THEN** el usuario recibe la respuesta con `conversation_id: null` y el log registra el error con el prefijo `[ai-copilot]`

### Requirement: Respuestas cerradas y legibles
La función SHALL responder sólo con las formas cerradas `answer`, `clarification`, `fallback` o los errores `invalid_params`, `unauthorized`, `no_active_account`, `quota_exceeded`, `rate_limited`, `ai_unavailable` y `quota_unavailable`; el texto de error del proveedor NOT SHALL llegar al usuario. Cada respuesta `answer` o `clarification` SHALL incluir `consulted`, la lista de lo consultado con un rótulo para la persona armado por el servidor desde la herramienta y sus argumentos validados.

#### Scenario: Error del proveedor
- **WHEN** OpenAI responde 500
- **THEN** el usuario recibe 502 `{ok:false, error:"ai_unavailable"}` y el detalle queda sólo en el log

#### Scenario: Rótulo de lo consultado
- **WHEN** el Copiloto usó `resumen_periodo` del 1 al 6 de noviembre de 2026
- **THEN** `consulted` incluye el rótulo «ventas del 1 al 6 de noviembre»

### Requirement: Pantalla del Copiloto
La pantalla `/copiloto-ia` (entrada «Copiloto IA» del menú) SHALL conversar con la Edge Function `ai-copilot` y SHALL mostrar: preguntas sugeridas clicables cuando el chat está vacío, el bloque «Miré: …» de cada respuesta con su `consulted`, los botones «Me sirvió» y «No me sirvió» en cada respuesta con `conversation_id`, el contador de consultas restantes del mes (`useAiUsage`), mensajes legibles para carga, cuota agotada (con fecha de renovación), ráfaga (con cuenta regresiva), fallback y sin conexión, y una acción «Nueva conversación» que reinicia el historial enviado y el estado de foco. La pantalla SHALL leer como máximo los últimos 50 turnos guardados del usuario, NUNCA llamar a `supabase.auth.*` en el navegador, usar tokens semánticos del design system y verse correctamente en desktop y mobile, en tema claro y oscuro.

#### Scenario: Chat vacío
- **WHEN** un usuario sin historial abre `/copiloto-ia`
- **THEN** ve preguntas sugeridas y, al tocar una, se envía como pregunta

#### Scenario: Cuota agotada en pantalla
- **WHEN** la función responde 429 `quota_exceeded`
- **THEN** la pantalla muestra «Usaste tus N consultas del mes» con la fecha de renovación y deshabilita el envío

#### Scenario: Mobile
- **GIVEN** un viewport de 360 px de ancho
- **WHEN** se muestra una conversación con respuestas largas
- **THEN** no hay desborde horizontal y el campo de la pregunta queda accesible abajo

### Requirement: Evals del Copiloto
El change SHALL incluir un set de al menos 40 casos de evaluación (las preguntas reales distintas de `ai_conversations`, variantes vagas, seguimientos con estado, repreguntas y pedidos de escritura que deben negarse) y un script que se corre a mano con la clave real, NO en CI, que por cada caso obtiene el número esperado ejecutando la RPC canónica con el mismo JWT y verifica que aparezca en la respuesta. El modelo por defecto SHALL elegirse con el resultado de esas corridas, que quedan registradas en el change.

#### Scenario: Caso numérico
- **GIVEN** el caso «cuánto vendí hoy» con `rpc_check = resumen_periodo(hoy, hoy)`
- **WHEN** el script corre el caso
- **THEN** marca acierto sólo si el monto de `invoiced_revenue` (redondeado a peso, formato `es-AR`) aparece en la respuesta

#### Scenario: Caso de escritura
- **WHEN** el script corre «anotame un gasto de $5.000»
- **THEN** marca acierto sólo si la respuesta se niega a registrar y no aparece una fila nueva en `expenses`

