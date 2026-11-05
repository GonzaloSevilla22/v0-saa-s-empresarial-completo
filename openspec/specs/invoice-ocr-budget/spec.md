# invoice-ocr-budget Specification

## Purpose
Acotar el costo de la lectura de facturas con IA (`invoice-ocr`, OpenAI `gpt-4o` con visión): cuota mensual por plan, límite de ráfaga por ventana corta y reserva atómica del cupo antes de llamar al proveedor, para que ningún usuario pueda generar un gasto ilimitado. Origen: H-11 del Roadmap v3.1 (`v31-ia-ratelimit-budget`).
## Requirements
### Requirement: Cuota mensual de lecturas de factura por plan

El sistema SHALL limitar la cantidad de lecturas de factura con IA (`invoice-ocr`) que cada usuario puede consumir por mes calendario al valor de `plan_limits.max_ai_ocr_per_month` del plan efectivo de su cuenta activa, contado en `profiles.ai_ocr_used`. Los valores sembrados SHALL ser gratis 5, inicial 30, avanzado 120 y pro 300. El plan efectivo SHALL resolverse con `rpc_my_effective_plan()` y NOT SHALL derivarse de `public.profiles`. El contador de lecturas de factura SHALL ser independiente de `ai_queries_used` y `ai_advice_used`.

#### Scenario: Usuario gratis con cupo disponible lee una factura

- **GIVEN** un usuario con plan efectivo `gratis` y `ai_ocr_used = 4`
- **WHEN** pide leer una factura válida
- **THEN** la lectura se procesa y `ai_ocr_used` queda en 5

#### Scenario: Usuario gratis sin cupo es rechazado sin llamar a OpenAI

- **GIVEN** un usuario con plan efectivo `gratis` y `ai_ocr_used = 5`
- **WHEN** pide leer una factura válida
- **THEN** la función responde HTTP 429 con `{ ok: false, error: 'quota_exceeded', resetAt, used: 5, limit: 5 }`
- **AND** no se realiza ninguna llamada a OpenAI
- **AND** la fila de `invoice_documents` conserva su estado anterior

#### Scenario: Leer facturas no consume consultas IA

- **GIVEN** un usuario con `ai_queries_used = 2`
- **WHEN** lee una factura con éxito
- **THEN** `ai_queries_used` sigue en 2

### Requirement: Reserva atómica del cupo antes de llamar a OpenAI

El sistema SHALL consumir el cupo de lectura de factura mediante la RPC `rpc_reserve_ai_usage(p_counter text)` **antes** de llamar a OpenAI, comprobando cuota mensual y ráfaga e incrementando el contador en una única sentencia condicional, de modo que N pedidos concurrentes de un usuario con K lecturas de cupo restante concedan como máximo K reservas. La RPC SHALL ser `SECURITY DEFINER`, SHALL tomar el usuario de `auth.uid()` (sin parámetro de usuario), SHALL aceptar sólo el contador `'ocr'`, SHALL ser ejecutable por `authenticated` y NOT SHALL ser ejecutable por `anon` ni `PUBLIC`. Una reserva concedida NOT SHALL devolverse aunque la llamada a OpenAI falle o su respuesta no se pueda interpretar. Las columnas `ai_ocr_used`, `ai_ocr_window_count` y `ai_ocr_window_started_at` NOT SHALL ser escribibles por `anon` ni `authenticated`.

#### Scenario: Ráfaga concurrente no supera el cupo

- **GIVEN** un usuario con cupo restante de 1 lectura
- **WHEN** dos sesiones invocan `rpc_reserve_ai_usage('ocr')` concurrentemente
- **THEN** exactamente una recibe `allowed = true` y la otra `allowed = false` con `reason = 'quota_exceeded'`
- **AND** `ai_ocr_used` queda igual al límite, nunca por encima

#### Scenario: Contador desconocido es rechazado

- **WHEN** un usuario invoca `rpc_reserve_ai_usage('queries')`
- **THEN** la RPC lanza un error con SQLSTATE `22023` y no modifica ningún contador

#### Scenario: Sin sesión no hay reserva

- **WHEN** la RPC se invoca sin `auth.uid()`
- **THEN** lanza un error con SQLSTATE `P0401`

#### Scenario: La llamada a OpenAI falla después de reservar

- **GIVEN** una reserva concedida que dejó `ai_ocr_used = 3`
- **WHEN** OpenAI responde con error o vence el timeout
- **THEN** la fila queda `failed` con el mensaje y `ai_ocr_used` sigue en 3

#### Scenario: El cliente no puede reescribir su contador

- **WHEN** un usuario `authenticated` intenta `UPDATE profiles SET ai_ocr_used = 0` por PostgREST
- **THEN** la base rechaza la escritura por falta de privilegio

### Requirement: Límite de ráfaga de lecturas de factura

El sistema SHALL rechazar una lectura de factura cuando el usuario ya consumió 3 reservas dentro de la ventana fija de 60 segundos vigente, con HTTP 429 `{ ok: false, error: 'rate_limited', retryAfterSeconds }` y header `Retry-After` igual a `retryAfterSeconds` (entero ≥ 1). La ventana SHALL vivir en `profiles.ai_ocr_window_started_at` y `profiles.ai_ocr_window_count`, medida con el reloj de la base. Cuando se cumplen a la vez el agotamiento de la cuota mensual y la ráfaga, SHALL informarse `quota_exceeded`. Un rechazo por ráfaga NOT SHALL consumir cuota mensual.

#### Scenario: Cuarta lectura dentro del mismo minuto

- **GIVEN** un usuario con cupo mensual disponible que reservó 3 lecturas hace 20 segundos
- **WHEN** pide una cuarta lectura
- **THEN** recibe 429 `rate_limited` con `retryAfterSeconds` cercano a 40 y header `Retry-After`
- **AND** `ai_ocr_used` no cambia

#### Scenario: La ventana vencida se reinicia

- **GIVEN** un usuario cuya ventana arrancó hace 61 segundos con `ai_ocr_window_count = 3`
- **WHEN** pide una lectura con cupo mensual disponible
- **THEN** la reserva se concede y la ventana reinicia con `ai_ocr_window_count = 1`

### Requirement: Techo de costo por lectura

La Edge Function `invoice-ocr` SHALL rechazar con HTTP 413, sin reservar cupo y sin llamar a OpenAI, una imagen cuyos bytes descargados superen 6 MiB (6.291.456 bytes), medidos sobre el objeto descargado y no sobre `file_size_bytes`. La función SHALL usar sólo un modelo de la allow-list `gpt-4o-mini`, `gpt-4o`; un `INVOICE_AI_MODEL` fuera de la lista o vacío SHALL resolverse a `gpt-4o-mini` y dejar un aviso en el log. La salida SHALL estar acotada por `max_tokens = 2000` y la llamada por un timeout de 55 segundos. La codificación base64 de la imagen NOT SHALL expandir un argumento de función por byte.

#### Scenario: Imagen de 7 MiB

- **GIVEN** un documento cuyo objeto descargado pesa 7 MiB
- **WHEN** se pide leerlo
- **THEN** la función responde 413, la fila queda `failed` con el motivo y el contador no cambia

#### Scenario: Modelo fuera de la allow-list

- **GIVEN** `INVOICE_AI_MODEL = 'gpt-4.1'`
- **WHEN** se lee una factura
- **THEN** la llamada a OpenAI usa `gpt-4o-mini` y el log registra el valor ignorado

#### Scenario: Imagen de 5 MiB se codifica sin error

- **GIVEN** una imagen válida de 5 MiB
- **WHEN** se codifica a base64
- **THEN** el resultado es idéntico a la codificación de referencia y no se lanza `RangeError`

### Requirement: Orden de rechazos y estado del documento

La función `invoice-ocr` SHALL evaluar en este orden: autenticación, parseo, autorización de la fila (404/409), descarga, tipo MIME (422), tamaño (413), reserva de cupo (429/503) y recién entonces marcar la fila `processing` y llamar a OpenAI. Un rechazo por cupo o por indisponibilidad de la reserva NOT SHALL modificar la fila de `invoice_documents`. Una fila en `processing` actualizada hace menos de 90 segundos SHALL responder 409 sin reservar cupo; este candado protege contra el doble envío y NOT SHALL considerarse el control de abuso, que es la reserva de cupo. Si la reserva no puede resolverse (error de la RPC, respuesta con forma inesperada o límite del plan ausente), la función SHALL responder 503 `{ ok: false, error: 'quota_unavailable' }` sin llamar a OpenAI.

#### Scenario: 429 deja el documento reintentable

- **GIVEN** un documento `pending` y un usuario sin cupo
- **WHEN** pide leerlo
- **THEN** recibe 429 y el documento sigue `pending`

#### Scenario: Doble clic

- **GIVEN** un documento que pasó a `processing` hace 5 segundos
- **WHEN** llega un segundo pedido para el mismo documento
- **THEN** responde 409 «La factura ya se está leyendo» y el contador no cambia

#### Scenario: Reserva no disponible

- **GIVEN** la RPC de reserva devuelve error
- **WHEN** se pide leer una factura
- **THEN** la función responde 503 `quota_unavailable` y no llama a OpenAI

### Requirement: Cupo de lecturas visible en Compras

La pantalla `/compras` SHALL mostrar, dentro del diálogo «Leer factura con IA» abierto desde el botón «Subir factura IA», las lecturas de factura restantes del mes del usuario y, cuando el saldo es 0, SHALL reemplazar la zona de subida por un aviso con el límite del plan, la fecha de la próxima renovación (día 1 del mes siguiente) y un acceso a `/planes`. Los rechazos `quota_exceeded`, `rate_limited`, 413 y `quota_unavailable` SHALL mostrarse con un mensaje propio en español, y el saldo SHALL refrescarse después de cada intento que llegó a la reserva. La superficie SHALL usar tokens semánticos del design system y SHALL verificarse en desktop y mobile, tema claro y oscuro.

#### Scenario: Usuario con saldo ve cuántas lecturas le quedan

- **GIVEN** un usuario `inicial` con `ai_ocr_used = 12`
- **WHEN** abre el diálogo de lectura de factura en `/compras`
- **THEN** ve «Te quedan 18 lecturas de factura este mes»

#### Scenario: Usuario sin saldo no puede subir

- **GIVEN** un usuario `gratis` con `ai_ocr_used = 5`
- **WHEN** abre el diálogo
- **THEN** no ve la zona de subida, ve el aviso con la fecha de renovación y el enlace «Ver planes»

#### Scenario: Ráfaga traducida

- **WHEN** la función responde 429 `rate_limited` con `retryAfterSeconds = 40`
- **THEN** el usuario ve «Esperá 40 segundos y volvé a intentar»

