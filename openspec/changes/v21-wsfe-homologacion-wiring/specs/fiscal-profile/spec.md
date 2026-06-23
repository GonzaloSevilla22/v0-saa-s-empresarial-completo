# fiscal-profile — Delta (v21-wsfe-homologacion-wiring C-31)

## ADDED Requirements

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

## MODIFIED Requirements

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
