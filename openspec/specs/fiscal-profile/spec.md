# fiscal-profile — Spec (v21-fiscal-profile C-27)

## Purpose

Gestión del perfil fiscal AFIP de una organización: datos del emisor (CUIT, condición IVA/IIBB, ambiente homologación/producción), certificado AFIP en Storage privado, y puntos de venta (multi-PV) registrados ante AFIP. Backbone de la emisión de comprobantes electrónicos con CAE (C-27), con wiring al POS en C-29.
## Requirements
### Requirement: Persistencia del perfil fiscal de la organización

El sistema SHALL persistir un perfil fiscal por cuenta en la tabla `fiscal_profiles` (`id` UUID PK, `account_id` UUID FK `accounts` con UNIQUE, `cuit` TEXT NOT NULL, `iva_condition` TEXT, `iibb_condition` TEXT, `certificado_afip_path` TEXT, `ambiente` TEXT NOT NULL DEFAULT `'homologacion'`, `created_at` TIMESTAMPTZ). El perfil **no** contiene la columna `punto_de_venta`: los puntos de venta viven en `points_of_sale` (ver "Puntos de venta de la organización"). `iva_condition` MUST estar restringida por CHECK a `'responsable_inscripto'`, `'monotributista'`, `'exento'`, `'consumidor_final'`. `ambiente` MUST estar restringida por CHECK a `'homologacion'`, `'produccion'`. El UNIQUE en `account_id` garantiza a lo sumo un perfil por organización.

**Agregado por `factura-fiscal-imprimible`.** El perfil SHALL persistir además los datos del emisor que exige la representación impresa de la factura, todos NULLABLE para no afectar a los perfiles existentes ni a la emisión: `razon_social TEXT`, `nombre_fantasia TEXT`, `domicilio_comercial TEXT`, `iibb_numero TEXT` e `inicio_actividades DATE`. Su ausencia NOT SHALL bloquear la emisión de comprobantes; sólo condiciona la impresión (ver `fiscal-invoice-print`).

#### Scenario: Cuenta crea su perfil fiscal

- **WHEN** el owner de una cuenta sin perfil fiscal lo crea con `cuit` e `iva_condition = 'responsable_inscripto'`
- **THEN** se inserta una fila en `fiscal_profiles` con `account_id` de la cuenta, `ambiente = 'homologacion'` por default y `created_at = now()`

#### Scenario: Una cuenta no puede tener dos perfiles fiscales

- **GIVEN** una cuenta que ya tiene un `fiscal_profiles`
- **WHEN** se intenta insertar un segundo perfil para la misma `account_id`
- **THEN** el INSERT falla por violación del UNIQUE constraint `(account_id)`

#### Scenario: Condición IVA inválida es rechazada por la DB

- **WHEN** se intenta insertar un perfil con `iva_condition = 'inscripto_raro'`
- **THEN** el INSERT falla por violación del CHECK constraint

#### Scenario: Ambiente inválido es rechazado por la DB

- **WHEN** se intenta insertar un perfil con `ambiente = 'testing'`
- **THEN** el INSERT falla por violación del CHECK constraint

#### Scenario: Un perfil sin datos del emisor sigue emitiendo

- **GIVEN** un perfil con `razon_social`, `domicilio_comercial`, `iibb_numero` e `inicio_actividades` en NULL
- **WHEN** se emite un comprobante
- **THEN** la emisión procede igual que antes de este change

---

### Requirement: Ambiente AFIP configurable por cuenta

El sistema SHALL resolver el ambiente AFIP (homologación o producción) a partir de `fiscal_profiles.ambiente` de la cuenta emisora, no de una variable de entorno global. El cutover de una cuenta a producción SHALL consistir en cambiar `ambiente` a `'produccion'` y subir el certificado real, sin requerir cambios de código ni re-deploy.

#### Scenario: El adaptador WSFE usa el ambiente del perfil de la cuenta

- **GIVEN** la cuenta A con `ambiente = 'homologacion'` y la cuenta B con `ambiente = 'produccion'`
- **WHEN** cada una solicita un CAE
- **THEN** el adaptador apunta al web service de homologación para A y al de producción para B, sin re-deploy del backend

#### Scenario: Default de homologación para cuentas nuevas

- **WHEN** se crea un perfil fiscal sin especificar `ambiente`
- **THEN** el perfil queda en `'homologacion'`

---

### Requirement: RLS del perfil fiscal por account_id

El sistema SHALL proteger `fiscal_profiles` con RLS basada en `account_id`: SELECT permitido a los miembros de la cuenta (`account_id = ANY(current_account_ids())`); INSERT y UPDATE permitidos solo a `owner`/`admin` (`is_account_writer(account_id)` en WITH CHECK).

#### Scenario: Miembro de otra cuenta no ve el perfil fiscal

- **GIVEN** dos cuentas A y B, cada una con su perfil fiscal
- **WHEN** un miembro de A consulta `fiscal_profiles`
- **THEN** solo recibe el perfil de A (RLS aísla)

#### Scenario: Member no puede editar el perfil fiscal

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** intenta UPDATE sobre `fiscal_profiles` de su cuenta
- **THEN** la RLS rechaza la operación (solo owner/admin)

---

### Requirement: Puntos de venta de la organización (multi-PV)

El sistema SHALL persistir los puntos de venta AFIP de una cuenta en la tabla `points_of_sale` (`id` UUID PK, `fiscal_profile_id` UUID FK NOT NULL `fiscal_profiles`, `account_id` UUID FK NOT NULL `accounts` (desnormalizado para RLS), `branch_id` UUID FK NULL `branches`, `numero` INTEGER NOT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `is_default` BOOLEAN NOT NULL DEFAULT FALSE, `created_at` TIMESTAMPTZ), con UNIQUE `(fiscal_profile_id, numero)`. Una cuenta SHALL poder registrar **dos o más** puntos de venta, sin límite artificial de cantidad. `numero` es el número de punto de venta dado de alta ante AFIP. `branch_id` es opcional en V2.1 (el vínculo con la sucursal se endurece cuando el POS emita, C-29). La tabla SHALL tener RLS por `account_id` (SELECT a miembros de la cuenta; INSERT/UPDATE a `owner`/`admin` vía `is_account_writer(account_id)` en WITH CHECK).

**MODIFIED por `punto-venta-seleccion` (2026-09-25).** Reason: con dos o más puntos de venta activos no había forma de decir cuál usar por defecto, y la emisión sin PV explícito fallaba siempre (`P0422`) — en prod, el 100% de las cuentas con puntos de venta tiene dos activos. Una cuenta SHALL poder marcar **como mucho un** punto de venta como **predeterminado** (`is_default = true`), garantizado por un índice único parcial sobre `account_id` donde `is_default`. Sólo un punto de venta **activo** SHALL poder ser predeterminado (CHECK `NOT is_default OR is_active`). Desactivar el punto de venta predeterminado SHALL quitarle la marca en la misma operación, de modo que la cuenta queda sin predeterminado (nunca con uno inactivo). Ninguna cuenta existente SHALL recibir un predeterminado automáticamente: la marca la pone el dueño.

#### Scenario: La cuenta registra dos puntos de venta

- **GIVEN** una cuenta con perfil fiscal y sin puntos de venta
- **WHEN** el owner agrega un PV `numero = 1` y luego un PV `numero = 2`
- **THEN** se insertan dos filas en `points_of_sale` para el mismo `fiscal_profile_id`, ambas `is_active = true` y `is_default = false`

#### Scenario: No se pueden repetir dos PVs con el mismo numero en la cuenta

- **GIVEN** un perfil fiscal con un PV `numero = 1`
- **WHEN** se intenta agregar otro PV con `numero = 1` para el mismo perfil
- **THEN** el INSERT falla por violación del UNIQUE constraint `(fiscal_profile_id, numero)`

#### Scenario: Desactivar un punto de venta

- **GIVEN** un PV `numero = 2` activo
- **WHEN** el owner lo desactiva
- **THEN** la fila queda con `is_active = false` y deja de ofrecerse como PV emisor (no se borra; conserva su historial y secuencia)

#### Scenario: Member no puede crear ni desactivar puntos de venta

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** intenta INSERT o UPDATE sobre `points_of_sale`
- **THEN** la RLS rechaza la operación (solo owner/admin)

#### Scenario: La RLS aísla los puntos de venta por cuenta

- **GIVEN** dos cuentas A y B, cada una con sus puntos de venta
- **WHEN** un miembro de A consulta `points_of_sale`
- **THEN** solo recibe los PVs de A

#### Scenario: Una cuenta no puede tener dos predeterminados

- **GIVEN** una cuenta con el PV 3 marcado como predeterminado y el PV 9999 activo
- **WHEN** se intenta marcar también el PV 9999 con `is_default = true` sin quitar la marca del 3
- **THEN** la escritura falla por el índice único parcial y el PV 3 sigue siendo el único predeterminado

#### Scenario: Un punto de venta inactivo no puede ser predeterminado

- **GIVEN** un PV inactivo
- **WHEN** se intenta marcarlo con `is_default = true`
- **THEN** la escritura falla por el CHECK y la fila no cambia

#### Scenario: Desactivar el predeterminado deja la cuenta sin predeterminado

- **GIVEN** una cuenta con el PV 3 activo y predeterminado, y el PV 9999 activo
- **WHEN** el owner desactiva el PV 3
- **THEN** el PV 3 queda `is_active = false` y `is_default = false`, y la cuenta no tiene ningún predeterminado (el 9999 NO se promueve solo)

---

### Requirement: Un CUIT no puede tener el mismo punto de venta activo en dos cuentas

El sistema SHALL rechazar dejar ACTIVO un punto de venta cuyo `numero` ya está activo en OTRO `fiscal_profile`, de OTRA cuenta, con el mismo CUIT normalizado (sin guiones ni otros caracteres no numéricos) — tanto al dar de alta/reactivar/renumerar un punto de venta como al cambiarle el CUIT a un perfil fiscal cuyos puntos de venta activos colisionarían con el nuevo CUIT. El rechazo SHALL usar un código de error de negocio distinguible (no un 500 genérico). Esta verificación SHALL alcanzar únicamente puntos de venta ACTIVOS: un punto de venta inactivo, o de una cuenta con un CUIT distinto, NO SHALL verse afectado. El sistema NO SHALL modificar ni desactivar ninguna fila existente al introducir esta verificación — sólo impide que el caso se cree o se agrande a partir de este punto; una colisión que ya existiera en la base sigue intacta hasta que se corrija el dato (el propio CUIT equivocado) manualmente.

**ADDED por `fiscal-emision-segura` (2026-09-22).** Reason: `points_of_sale` sólo tiene UNIQUE `(fiscal_profile_id, numero)` — dos `fiscal_profiles` de CUENTAS DISTINTAS con el mismo CUIT pueden tener cada uno un PV con el mismo `numero`, sin que nada lo impida. ARCA numera por `(CUIT, PtoVta, CbteTipo)`, no por `fiscal_profile_id`: dos cuentas así compiten por LA MISMA secuencia de numeración de ARCA (prod tuvo este caso real: dos perfiles con el mismo CUIT, ambos con el punto de venta 3 activo, uno cargado con el CUIT equivocado). La segunda cuenta en emitir reservaría localmente un número que ARCA ya le dio a la primera.

#### Scenario: Activar un punto de venta con el mismo número y CUIT que otra cuenta se rechaza

- **GIVEN** la cuenta A con CUIT `20-11111111-1` y un punto de venta activo `numero = 3`
- **WHEN** la cuenta B, con el mismo CUIT `20-11111111-1`, intenta activar (crear o reactivar) un punto de venta con `numero = 3`
- **THEN** la operación se rechaza con un código de error de negocio, y el punto de venta de B no queda activo

#### Scenario: El mismo número con un CUIT distinto se acepta

- **GIVEN** la cuenta A con CUIT `20-11111111-1` y un punto de venta activo `numero = 3`
- **WHEN** la cuenta C, con CUIT `20-22222222-2` (distinto), activa un punto de venta con `numero = 3`
- **THEN** la operación se acepta — el conflicto es por CUIT compartido, no por el número en sí

#### Scenario: Cambiarle el CUIT a un perfil puede crear el mismo conflicto y también se rechaza

- **GIVEN** la cuenta A con CUIT `20-11111111-1` y un punto de venta activo `numero = 3`, y la cuenta B con un punto de venta activo `numero = 3` bajo un CUIT distinto
- **WHEN** B actualiza el CUIT de su perfil fiscal a `20-11111111-1`
- **THEN** la actualización se rechaza (colisionaría con el punto de venta activo de A)

#### Scenario: Un punto de venta inactivo no compite

- **GIVEN** la cuenta A con CUIT `20-11111111-1` y un punto de venta **inactivo** `numero = 3`
- **WHEN** la cuenta B, con el mismo CUIT, activa un punto de venta con `numero = 3`
- **THEN** la operación se acepta — un PV inactivo no numera nada ante ARCA

#### Scenario: Una colisión preexistente no se toca al introducir el guard

- **GIVEN** dos cuentas que YA tenían, antes de este requisito, el mismo CUIT y el mismo punto de venta activo
- **WHEN** se despliega esta verificación
- **THEN** ninguna de las dos filas existentes se modifica ni se desactiva automáticamente — la corrección del dato (el CUIT equivocado) queda a cargo de quien administra esa cuenta

---

### Requirement: Selección del punto de venta en la emisión

El sistema SHALL aceptar un `point_of_sale_id` **opcional** al emitir un comprobante de venta (`rpc_emit_pending_cae`) y SHALL resolver el punto de venta efectivo en este orden: (1) si se especifica `point_of_sale_id`, ese — y si no pertenece a la cuenta o está inactivo, SHALL rechazar la emisión (`P0404`) aunque la cuenta tenga predeterminado (un PV explícito inválido nunca se corrige en silencio); (2) si la cuenta tiene **un único** punto de venta activo, ese; (3) si tiene **dos o más** activos y uno es el **predeterminado**, el predeterminado; (4) si tiene dos o más activos y ninguno es predeterminado, SHALL rechazar la emisión con `P0422 ambiguous_point_of_sale` sin reservar ningún número; (5) sin puntos de venta activos, SHALL rechazar con `P0404 no_active_point_of_sale`.

**MODIFIED por `punto-venta-seleccion` (2026-09-25).** Reason: se agrega el paso (3). Antes, dos o más PV activos sin PV explícito fallaban siempre con `P0422`, lo que dejaba sin poder facturar desde `/ventas/ordenes` (donde se facturan las ventas del POS) a toda cuenta con más de un PV. La emisión de comprobantes de **pago de suscripción** de la plataforma (`rpc_emit_subscription_payment_cae`) NO adopta este cambio: conserva su resolución previa (único → ese; varios sin explícito → `P0422`), porque su único caller siempre exige elegir el PV.

#### Scenario: Un solo PV activo se selecciona automáticamente

- **GIVEN** una cuenta con un único punto de venta activo `numero = 1`
- **WHEN** se emite un comprobante sin especificar `point_of_sale_id`
- **THEN** la emisión usa ese PV y reserva el número de su secuencia

#### Scenario: Varios PVs activos sin especificar y sin predeterminado es ambiguo

- **GIVEN** una cuenta con dos puntos de venta activos y ninguno predeterminado
- **WHEN** se emite un comprobante sin especificar `point_of_sale_id`
- **THEN** la emisión falla con error `P0422 ambiguous_point_of_sale` y no reserva ningún número

#### Scenario: Varios PVs activos sin especificar usan el predeterminado

- **GIVEN** una cuenta con los PV 3 y 9999 activos y el 9999 marcado como predeterminado
- **WHEN** se emite un comprobante de venta sin especificar `point_of_sale_id`
- **THEN** el comprobante se crea en `pending_cae` con `point_of_sale_id` del PV 9999 y `punto_de_venta = 9999`, con el número reservado de la secuencia del 9999

#### Scenario: Un PV explícito gana sobre el predeterminado

- **GIVEN** una cuenta con los PV 3 y 9999 activos y el 9999 predeterminado
- **WHEN** se emite un comprobante especificando el PV 3
- **THEN** el comprobante se crea con `punto_de_venta = 3`

#### Scenario: Un PV explícito inactivo se rechaza aunque haya predeterminado

- **GIVEN** una cuenta con un PV inactivo y otro activo predeterminado
- **WHEN** se emite un comprobante especificando el PV inactivo
- **THEN** la emisión falla con `P0404 point_of_sale_not_found_or_inactive` y no usa el predeterminado

#### Scenario: PV explícito de otra cuenta es rechazado

- **GIVEN** un `point_of_sale_id` que pertenece a otra cuenta
- **WHEN** se emite un comprobante especificando ese PV
- **THEN** la emisión es rechazada (la RLS/guard impide usar un PV ajeno)

#### Scenario: La facturación de suscripciones no usa el predeterminado

- **GIVEN** la cuenta emisora de la plataforma con dos puntos de venta activos, uno predeterminado
- **WHEN** se emite el comprobante de un pago de suscripción sin especificar `point_of_sale_id`
- **THEN** la emisión falla con `P0422 ambiguous_point_of_sale`, igual que antes de este cambio

---

### Requirement: API del perfil fiscal

El backend Python SHALL exponer un router `fiscal` con endpoints para leer y crear/actualizar el perfil fiscal de la cuenta activa. Los schemas Pydantic `FiscalProfileCreate`/`FiscalProfileUpdate` SHALL validar `iva_condition` (Literal de los 4 valores) y `ambiente` (Literal de los 2 valores) antes de tocar la DB; `FiscalProfileOut` SHALL devolver todos los campos excepto el contenido del certificado (solo el path). El acceso a datos vive en `FiscalProfileRepository` vía JWT-passthrough; el router no contiene lógica de negocio.

**Agregado por `factura-fiscal-imprimible`.** `FiscalProfileCreate` y `FiscalProfileOut` SHALL incluir `razon_social`, `nombre_fantasia`, `domicilio_comercial`, `iibb_numero` e `inicio_actividades`. El upsert SHALL ser tri-estado para estos campos y para `iibb_condition`: un campo ausente del payload conserva el valor guardado; un `null` explícito lo borra; un valor lo reemplaza. El schema SHALL rechazar con 422, antes de tocar la DB, textos por encima de su largo máximo (razón social y nombre de fantasía 120, domicilio 200, IIBB 30) y un `inicio_actividades` posterior a la fecha actual.

#### Scenario: Obtener el perfil fiscal de la cuenta

- **WHEN** se hace GET `/fiscal/profile` con un usuario cuya cuenta tiene perfil
- **THEN** la respuesta 200 incluye `cuit`, `iva_condition`, `ambiente`, `certificado_afip_path` y los datos del emisor (`razon_social`, `nombre_fantasia`, `domicilio_comercial`, `iibb_numero`, `inicio_actividades`), sin el contenido del certificado (el punto de venta NO es parte del perfil — se consulta vía `/fiscal/points-of-sale`)

#### Scenario: Crear perfil con condición IVA inválida rechazado en el endpoint

- **WHEN** se hace POST `/fiscal/profile` con `iva_condition = 'otro'`
- **THEN** la API responde 422 sin tocar la DB

#### Scenario: Ambiente inválido rechazado en el endpoint

- **WHEN** se hace POST `/fiscal/profile` con `ambiente = 'sandbox'`
- **THEN** la API responde 422 sin tocar la DB

#### Scenario: Un campo ausente no borra lo guardado

- **GIVEN** un perfil con `domicilio_comercial = 'Av. San Martín 1234, Mendoza'`
- **WHEN** se hace POST `/fiscal/profile` con `cuit` e `iva_condition` y sin `domicilio_comercial`
- **THEN** el perfil conserva `domicilio_comercial = 'Av. San Martín 1234, Mendoza'`

#### Scenario: Null explícito borra el dato

- **GIVEN** un perfil con `nombre_fantasia = 'Sumar'`
- **WHEN** se hace POST `/fiscal/profile` con `nombre_fantasia: null`
- **THEN** el perfil queda con `nombre_fantasia` NULL

#### Scenario: Inicio de actividades futuro rechazado

- **WHEN** se hace POST `/fiscal/profile` con `inicio_actividades` posterior a hoy
- **THEN** la API responde 422 sin tocar la DB

---

### Requirement: API de puntos de venta

El backend Python SHALL exponer en el router `fiscal` endpoints para listar, crear, desactivar y marcar como predeterminado los puntos de venta de la cuenta activa: `GET /fiscal/points-of-sale`, `POST /fiscal/points-of-sale`, `PATCH /fiscal/points-of-sale/{id}` (desactivar), `POST /fiscal/points-of-sale/{id}/default` (marcar como predeterminado) y `DELETE /fiscal/points-of-sale/default` (dejar la cuenta sin predeterminado). El acceso a datos vive en `PointOfSaleRepository` vía JWT-passthrough; los guards de rol (`owner`/`admin`) viven en el service, no en el router. Los schemas `PointOfSaleCreate`/`PointOfSaleOut` (Pydantic v2) SHALL validar `numero` (entero positivo) y exponer `branch_id` opcional; `PointOfSaleOut` SHALL exponer `is_default`.

**MODIFIED por `punto-venta-seleccion` (2026-09-25).** Reason: se agregan los dos endpoints del predeterminado y el campo `is_default`. Marcar un PV como predeterminado SHALL quitar la marca de cualquier otro PV de la cuenta y marcar el pedido dentro de la misma transacción, filtrando explícitamente por `account_id` (la RLS es red, no guard único). Marcar un PV inexistente, de otra cuenta o inactivo SHALL responder 404 sin modificar la marca vigente.

#### Scenario: Listar los puntos de venta de la cuenta

- **WHEN** se hace GET `/fiscal/points-of-sale` con un usuario de una cuenta con dos PVs
- **THEN** la respuesta 200 lista los dos PVs (con `numero`, `branch_id`, `is_active`, `is_default`), aislados por cuenta

#### Scenario: Crear un punto de venta duplicado es rechazado

- **WHEN** se hace POST `/fiscal/points-of-sale` con un `numero` que ya existe para el perfil de la cuenta
- **THEN** la API responde 409 (violación del UNIQUE `(fiscal_profile_id, numero)`)

#### Scenario: Member no puede crear un punto de venta

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** hace POST `/fiscal/points-of-sale`
- **THEN** la API responde 403 (guard `require_role` owner/admin)

#### Scenario: Marcar un predeterminado reemplaza al anterior

- **GIVEN** una cuenta con el PV 3 predeterminado y el PV 9999 activo
- **WHEN** el owner hace POST `/fiscal/points-of-sale/{id del 9999}/default`
- **THEN** la respuesta 200 devuelve el 9999 con `is_default = true`, y un GET posterior muestra al 3 con `is_default = false`

#### Scenario: Marcar un PV inactivo o ajeno responde 404

- **GIVEN** una cuenta con el PV 3 predeterminado
- **WHEN** el owner hace POST `/fiscal/points-of-sale/{id}/default` con el id de un PV inactivo o de otra cuenta
- **THEN** la API responde 404 y el PV 3 sigue siendo el predeterminado

#### Scenario: Quitar el predeterminado

- **GIVEN** una cuenta con un PV predeterminado
- **WHEN** el owner hace DELETE `/fiscal/points-of-sale/default`
- **THEN** la respuesta es 204 y ningún PV de la cuenta queda con `is_default = true`

#### Scenario: Member no puede cambiar el predeterminado

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** hace POST `/fiscal/points-of-sale/{id}/default` o DELETE `/fiscal/points-of-sale/default`
- **THEN** la API responde 403 y la marca no cambia

---

### Requirement: UI de configuración fiscal

El frontend SHALL proveer una página `/configuracion/fiscal` con un formulario del perfil fiscal (CUIT, condición IVA, IIBB, ambiente), un **CRUD mínimo de puntos de venta** (listar / agregar / desactivar / marcar como predeterminado, sin límite de cantidad) y una **guía de onboarding de la delegación en ARCA** que reemplaza los controles de upload del certificado. La guía SHALL mostrar el paso a paso para autorizar a EmprendeSmart (con el CUIT representante de la plataforma) en ARCA → Administrador de Relaciones → Facturación Electrónica, y SHALL ofrecer el control para atestiguar que la delegación fue autorizada (flag `delegacion_autorizada`). La sección de upload de certificado/clave privada (`CertUploadSection`) SHALL eliminarse u ocultarse del flujo de delegación. El CUIT SHALL validarse con el algoritmo módulo 11 (reusando el validador `isValidCuit` de C-22) antes de permitir guardar.

**MODIFIED por `punto-venta-seleccion` (2026-09-25).** Reason: la lista de puntos de venta SHALL mostrar cuál es el predeterminado (badge "Predeterminado") y SHALL ofrecer, en cada PV activo que no lo es, una acción accesible "Usar como predeterminado", y en el predeterminado una acción "Quitar predeterminado". Cuando la cuenta tiene dos o más PV activos y ninguno predeterminado, la sección SHALL explicar en una línea para qué sirve marcar uno (qué PV se usa si no se elige al facturar). Los números de PV SHALL mostrarse con el formato de ARCA (4 dígitos, `0003`) usando el mismo helper que el comprobante.

**Agregado por `factura-fiscal-imprimible`.** La página SHALL incluir una sección "Datos para imprimir la factura" con razón social, nombre de fantasía (opcional), domicilio comercial, número de Ingresos Brutos e inicio de actividades, y SHALL mostrar un aviso que nombre los datos que faltan para poder imprimir facturas mientras falte alguno. La sección SHALL usar los componentes de formulario y los tokens semánticos del resto de la página y verse correctamente en desktop y en móvil, en tema claro y oscuro.

#### Scenario: Guardar el perfil fiscal con CUIT válido

- **WHEN** el owner completa CUIT válido + condición IVA y guarda
- **THEN** la mutación persiste el perfil y la página refleja los datos guardados

#### Scenario: CUIT con dígito verificador inválido bloquea el submit

- **WHEN** el usuario ingresa un CUIT con formato correcto pero dígito verificador incorrecto
- **THEN** el formulario muestra error y no envía la mutación

#### Scenario: Agregar un punto de venta desde la UI

- **WHEN** el owner agrega un punto de venta con `numero` (y opcionalmente una sucursal)
- **THEN** la lista de puntos de venta de la página se actualiza con el nuevo PV activo

#### Scenario: Desactivar un punto de venta desde la UI

- **GIVEN** un punto de venta activo en la lista
- **WHEN** el owner lo desactiva
- **THEN** la lista lo refleja como inactivo y deja de ofrecerse como PV emisor

#### Scenario: La página muestra la guía de delegación en vez del upload de certificado

- **WHEN** el owner abre la configuración fiscal
- **THEN** ve los pasos para autorizar a EmprendeSmart (CUIT representante) en ARCA → Administrador de Relaciones → Facturación Electrónica
- **AND** no ve controles para subir un certificado ni una clave privada

#### Scenario: Atestiguar la delegación desde la UI

- **WHEN** el owner marca que ya autorizó la delegación en ARCA
- **THEN** la mutación persiste `delegacion_autorizada = true` y la página refleja el estado "delegación autorizada"

#### Scenario: Marcar un punto de venta como predeterminado desde la UI

- **GIVEN** la lista con los PV 0003 y 9999 activos, ninguno predeterminado
- **WHEN** el owner elige "Usar como predeterminado" en el 9999
- **THEN** el 9999 muestra el badge "Predeterminado" y la acción del 0003 sigue disponible

#### Scenario: La sección explica el predeterminado cuando hace falta

- **GIVEN** una cuenta con dos PV activos y ninguno predeterminado
- **WHEN** el owner abre la sección de puntos de venta
- **THEN** ve una línea que explica que el predeterminado es el que se usa si no se elige otro al facturar

#### Scenario: Cargar los datos para imprimir la factura

- **WHEN** el owner completa razón social, domicilio comercial, número de IIBB e inicio de actividades y guarda
- **THEN** la mutación los persiste y el aviso de datos faltantes desaparece

#### Scenario: Aviso de datos faltantes

- **GIVEN** un perfil sin domicilio comercial ni inicio de actividades
- **WHEN** el owner abre `/configuracion/fiscal`
- **THEN** ve un aviso que dice que para imprimir facturas falta completar el domicilio comercial y el inicio de actividades

### Requirement: Onboarding de delegación ARCA en el perfil fiscal

El sistema SHALL guiar al usuario para autorizar a EmprendeSmart como **representante** del servicio "Facturación Electrónica" en ARCA (Administrador de Relaciones de Clave Fiscal), reemplazando el trámite de certificado por usuario. El perfil fiscal SHALL persistir una **atestación de delegación** por cuenta (flag booleano, p. ej. `fiscal_profiles.delegacion_autorizada DEFAULT FALSE`), editable solo por `owner`/`admin` (misma RLS que el resto del perfil). La API del perfil (`FiscalProfileOut`) SHALL exponer ese flag y el CUIT representante de la plataforma necesario para mostrar el paso a paso de la autorización. La atestación NO SHALL tratarse como verificación: la confirmación real de que la delegación está vigente es que `FECAESolicitar` se autorice (estrategia "intentar y exponer el error").

#### Scenario: La cuenta atestigua la delegación

- **WHEN** el owner marca que ya autorizó a EmprendeSmart en ARCA
- **THEN** `fiscal_profiles.delegacion_autorizada` queda en verdadero para esa cuenta

#### Scenario: El perfil expone el flag y el CUIT representante

- **WHEN** se hace `GET /fiscal/profile` para una cuenta
- **THEN** la respuesta incluye el estado de la delegación (`delegacion_autorizada`) y el CUIT representante de la plataforma para guiar la autorización
- **AND** nunca incluye material criptográfico (ni de la cuenta ni del representante)

#### Scenario: Member no puede atestiguar la delegación

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** intenta cambiar el flag de delegación
- **THEN** la API responde 403 (guard `require_role` owner/admin)

