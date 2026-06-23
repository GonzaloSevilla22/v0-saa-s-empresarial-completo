# fiscal-profile — Spec (v21-fiscal-profile C-27)

## Purpose

Gestión del perfil fiscal AFIP de una organización: datos del emisor (CUIT, condición IVA/IIBB, ambiente homologación/producción), certificado AFIP en Storage privado, y puntos de venta (multi-PV) registrados ante AFIP. Backbone de la emisión de comprobantes electrónicos con CAE (C-27), con wiring al POS en C-29.

## Requirements

### Requirement: Persistencia del perfil fiscal de la organización

El sistema SHALL persistir un perfil fiscal por cuenta en la tabla `fiscal_profiles` (`id` UUID PK, `account_id` UUID FK `accounts` con UNIQUE, `cuit` TEXT NOT NULL, `iva_condition` TEXT, `iibb_condition` TEXT, `certificado_afip_path` TEXT, `ambiente` TEXT NOT NULL DEFAULT `'homologacion'`, `created_at` TIMESTAMPTZ). El perfil **no** contiene la columna `punto_de_venta`: los puntos de venta viven en `points_of_sale` (ver "Puntos de venta de la organización"). `iva_condition` MUST estar restringida por CHECK a `'responsable_inscripto'`, `'monotributista'`, `'exento'`, `'consumidor_final'`. `ambiente` MUST estar restringida por CHECK a `'homologacion'`, `'produccion'`. El UNIQUE en `account_id` garantiza a lo sumo un perfil por organización.

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

El sistema SHALL persistir los puntos de venta AFIP de una cuenta en la tabla `points_of_sale` (`id` UUID PK, `fiscal_profile_id` UUID FK NOT NULL `fiscal_profiles`, `account_id` UUID FK NOT NULL `accounts` (desnormalizado para RLS), `branch_id` UUID FK NULL `branches`, `numero` INTEGER NOT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `created_at` TIMESTAMPTZ), con UNIQUE `(fiscal_profile_id, numero)`. Una cuenta SHALL poder registrar **dos o más** puntos de venta, sin límite artificial de cantidad. `numero` es el número de punto de venta dado de alta ante AFIP. `branch_id` es opcional en V2.1 (el vínculo con la sucursal se endurece cuando el POS emita, C-29). La tabla SHALL tener RLS por `account_id` (SELECT a miembros de la cuenta; INSERT/UPDATE a `owner`/`admin` vía `is_account_writer(account_id)` en WITH CHECK).

#### Scenario: La cuenta registra dos puntos de venta

- **GIVEN** una cuenta con perfil fiscal y sin puntos de venta
- **WHEN** el owner agrega un PV `numero = 1` y luego un PV `numero = 2`
- **THEN** se insertan dos filas en `points_of_sale` para el mismo `fiscal_profile_id`, ambas `is_active = true`

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

---

### Requirement: Selección del punto de venta en la emisión

El sistema SHALL aceptar un `point_of_sale_id` **opcional** al emitir un comprobante. Si la cuenta tiene **un único** punto de venta activo, el sistema SHALL usarlo sin requerir que se especifique. Si la cuenta tiene **dos o más** puntos de venta activos y no se especifica `point_of_sale_id`, el sistema SHALL rechazar la emisión con error `P0422 ambiguous_point_of_sale`. Si el `point_of_sale_id` especificado no pertenece a la cuenta o está inactivo, el sistema SHALL rechazar la emisión (`P0404`/`P0422`).

#### Scenario: Un solo PV activo se selecciona automáticamente

- **GIVEN** una cuenta con un único punto de venta activo `numero = 1`
- **WHEN** se emite un comprobante sin especificar `point_of_sale_id`
- **THEN** la emisión usa ese PV y reserva el número de su secuencia

#### Scenario: Varios PVs activos sin especificar es ambiguo

- **GIVEN** una cuenta con dos puntos de venta activos
- **WHEN** se emite un comprobante sin especificar `point_of_sale_id`
- **THEN** la emisión falla con error `P0422 ambiguous_point_of_sale` y no reserva ningún número

#### Scenario: PV explícito de otra cuenta es rechazado

- **GIVEN** un `point_of_sale_id` que pertenece a otra cuenta
- **WHEN** se emite un comprobante especificando ese PV
- **THEN** la emisión es rechazada (la RLS/guard impide usar un PV ajeno)

---

### Requirement: API del perfil fiscal

El backend Python SHALL exponer un router `fiscal` con endpoints para leer y crear/actualizar el perfil fiscal de la cuenta activa. Los schemas Pydantic `FiscalProfileCreate`/`FiscalProfileUpdate` SHALL validar `iva_condition` (Literal de los 4 valores) y `ambiente` (Literal de los 2 valores) antes de tocar la DB; `FiscalProfileOut` SHALL devolver todos los campos excepto el contenido del certificado (solo el path). El acceso a datos vive en `FiscalProfileRepository` vía JWT-passthrough; el router no contiene lógica de negocio.

#### Scenario: Obtener el perfil fiscal de la cuenta

- **WHEN** se hace GET `/fiscal/profile` con un usuario cuya cuenta tiene perfil
- **THEN** la respuesta 200 incluye `cuit`, `iva_condition`, `ambiente` y `certificado_afip_path`, sin el contenido del certificado (el punto de venta NO es parte del perfil — se consulta vía `/fiscal/points-of-sale`)

#### Scenario: Crear perfil con condición IVA inválida rechazado en el endpoint

- **WHEN** se hace POST `/fiscal/profile` con `iva_condition = 'otro'`
- **THEN** la API responde 422 sin tocar la DB

#### Scenario: Ambiente inválido rechazado en el endpoint

- **WHEN** se hace POST `/fiscal/profile` con `ambiente = 'sandbox'`
- **THEN** la API responde 422 sin tocar la DB

---

### Requirement: API de puntos de venta

El backend Python SHALL exponer en el router `fiscal` endpoints para listar, crear y desactivar puntos de venta de la cuenta activa: `GET /fiscal/points-of-sale`, `POST /fiscal/points-of-sale`, `PATCH /fiscal/points-of-sale/{id}` (desactivar). El acceso a datos vive en `PointOfSaleRepository` vía JWT-passthrough; los guards de rol (`owner`/`admin`) viven en el service, no en el router. Los schemas `PointOfSaleCreate`/`PointOfSaleOut` (Pydantic v2) SHALL validar `numero` (entero positivo) y exponer `branch_id` opcional.

#### Scenario: Listar los puntos de venta de la cuenta

- **WHEN** se hace GET `/fiscal/points-of-sale` con un usuario de una cuenta con dos PVs
- **THEN** la respuesta 200 lista los dos PVs (con `numero`, `branch_id`, `is_active`), aislados por cuenta

#### Scenario: Crear un punto de venta duplicado es rechazado

- **WHEN** se hace POST `/fiscal/points-of-sale` con un `numero` que ya existe para el perfil de la cuenta
- **THEN** la API responde 409 (violación del UNIQUE `(fiscal_profile_id, numero)`)

#### Scenario: Member no puede crear un punto de venta

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** hace POST `/fiscal/points-of-sale`
- **THEN** la API responde 403 (guard `require_role` owner/admin)

---

### Requirement: API de upload del certificado AFIP

El backend Python SHALL exponer en el router `fiscal` dos endpoints para subir el material criptográfico del emisor al bucket privado `afip-certs`: `POST /fiscal/profile/cert-upload-url` y `PUT /fiscal/profile/cert-path`. `cert-upload-url` SHALL recibir `filename`, `content_type` y `kind` (`'cert'` | `'key'`) y devolver una **signed upload URL** y el **path canónico** del objeto en el bucket privado; el path SHALL derivarse server-side del `account_id` del JWT del request (`{account_id}/afip.crt` para `kind='cert'`, `{account_id}/afip.key` para `kind='key'`), NUNCA de un valor provisto por el cliente. `cert-path` SHALL recibir el `path` del certificado (`.crt`) y persistirlo en `fiscal_profiles.certificado_afip_path`. Los guards de rol (`owner`/`admin`) viven en el service. La generación de la signed URL para el bucket privado SHALL ocurrir server-side; el contenido del certificado y de la clave privada NUNCA SHALL pasar por la respuesta de ningún endpoint.

#### Scenario: Obtener la signed URL para el certificado

- **WHEN** el owner hace `POST /fiscal/profile/cert-upload-url` con `kind = 'cert'`
- **THEN** la respuesta 200 incluye una `uploadUrl` firmada y `path = '{account_id}/afip.crt'`, con el `account_id` resuelto del JWT

#### Scenario: Obtener la signed URL para la clave privada

- **WHEN** el owner hace `POST /fiscal/profile/cert-upload-url` con `kind = 'key'`
- **THEN** la respuesta 200 incluye una `uploadUrl` firmada y `path = '{account_id}/afip.key'`

#### Scenario: Kind inválido es rechazado en el endpoint

- **WHEN** se hace `POST /fiscal/profile/cert-upload-url` con `kind = 'otro'`
- **THEN** la API responde 422 sin generar ninguna URL ni tocar Storage

#### Scenario: El path no puede apuntar a otra cuenta

- **GIVEN** un usuario de la cuenta A
- **WHEN** solicita una signed URL de upload
- **THEN** el path devuelto está scoped a `A` (`{A}/afip.crt|afip.key`); el cliente no puede inducir un path de otra cuenta

#### Scenario: Persistir el path del certificado

- **WHEN** el owner hace `PUT /fiscal/profile/cert-path` con el path del `.crt`
- **THEN** `fiscal_profiles.certificado_afip_path` queda con ese path y la respuesta no incluye el contenido del certificado

#### Scenario: Member no puede subir el certificado

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** hace `POST /fiscal/profile/cert-upload-url` o `PUT /fiscal/profile/cert-path`
- **THEN** la API responde 403 (guard `require_role` owner/admin)

---

### Requirement: Certificado AFIP en Storage privado

El sistema SHALL almacenar el certificado AFIP en un bucket de Storage privado (no público) como **dos objetos PEM separados** en rutas canónicas scoped por `account_id`: `{account_id}/afip.crt` (certificado X.509) y `{account_id}/afip.key` (clave privada RSA en PEM, **sin password**, cargable con `load_pem_private_key(key, password=None)`). El bucket SHALL tener policies de INSERT, SELECT y UPDATE scoped por `account_id` que cubran **ambos** objetos. `fiscal_profiles.certificado_afip_path` SHALL guardar únicamente la ruta del objeto `.crt` (marcador de "cert cargado"), nunca el contenido de ningún archivo; la ruta de la `.key` se infiere por convención (mismo prefijo `{account_id}/`) y NUNCA se expone en la API. La clave privada (`.key`) es el secreto más sensible del sistema: SHALL viajar únicamente en el body del signed PUT hacia el bucket privado, NUNCA SHALL loguearse y NUNCA SHALL devolverse en ninguna respuesta (GET de perfil incluido). El certificado y la clave SHALL leerse solo server-side (backend, `service_role` aislado — D7/DEC-13) para firmar la autenticación WSAA; nunca SHALL exponerse al cliente.

#### Scenario: El certificado no es accesible públicamente

- **GIVEN** un certificado subido al bucket `afip-certs`
- **WHEN** se intenta acceder a su URL pública sin autenticación
- **THEN** el acceso es denegado (bucket privado)

#### Scenario: Solo la cuenta dueña puede subir su certificado

- **GIVEN** dos cuentas A y B
- **WHEN** un miembro de A intenta subir un objeto a la ruta del certificado de B
- **THEN** la policy de Storage rechaza el INSERT (scoped por `account_id`)

#### Scenario: La clave privada se sube como segundo objeto PEM

- **GIVEN** una cuenta con perfil fiscal
- **WHEN** el owner sube el `.crt` a `{account_id}/afip.crt` y la `.key` a `{account_id}/afip.key`
- **THEN** ambos objetos quedan en el bucket privado bajo el prefijo de la cuenta y el adaptador WSFE puede leer los dos

#### Scenario: La clave privada nunca se devuelve en la API

- **WHEN** se hace `GET /fiscal/profile` para una cuenta con certificado y clave cargados
- **THEN** la respuesta incluye a lo sumo `certificado_afip_path` (la ruta del `.crt`), nunca el contenido del `.crt` ni del `.key` ni la ruta del `.key`

---

### Requirement: UI de configuración fiscal

El frontend SHALL proveer una página `/configuracion/fiscal` con un formulario del perfil fiscal (CUIT, condición IVA, IIBB, ambiente), un **CRUD mínimo de puntos de venta** (listar / agregar / desactivar, sin límite de cantidad) y controles de upload del material criptográfico AFIP al bucket privado. El upload SHALL constar de **dos controles separados**: uno para el certificado (`.crt`/`.pem`) y otro para la clave privada (`.key`/`.pem`), cada uno enviando su `kind` (`'cert'` | `'key'`) al endpoint `cert-upload-url` y subiendo el archivo a la signed URL devuelta. El CUIT SHALL validarse con el algoritmo módulo 11 (reusando el validador `isValidCuit` de C-22) antes de permitir guardar. El contenido de la clave privada NUNCA SHALL exponerse client-side más allá del PUT a la signed URL.

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

#### Scenario: Subir el certificado AFIP

- **WHEN** el owner selecciona el archivo de certificado (`.crt`) en su control y lo sube
- **THEN** el archivo va a `{account_id}/afip.crt` en el bucket privado y `certificado_afip_path` se actualiza con la ruta

#### Scenario: Subir la clave privada AFIP

- **WHEN** el owner selecciona el archivo de clave privada (`.key`) en su control y lo sube
- **THEN** el archivo va a `{account_id}/afip.key` en el bucket privado; su contenido no queda expuesto client-side más allá del PUT firmado
