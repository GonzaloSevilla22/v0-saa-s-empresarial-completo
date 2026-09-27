## MODIFIED Requirements

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
