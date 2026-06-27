## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: UI de configuración fiscal

El frontend SHALL proveer una página `/configuracion/fiscal` con un formulario del perfil fiscal (CUIT, condición IVA, IIBB, ambiente), un **CRUD mínimo de puntos de venta** (listar / agregar / desactivar, sin límite de cantidad) y una **guía de onboarding de la delegación en ARCA** que reemplaza los controles de upload del certificado. La guía SHALL mostrar el paso a paso para autorizar a EmprendeSmart (con el CUIT representante de la plataforma) en ARCA → Administrador de Relaciones → Facturación Electrónica, y SHALL ofrecer el control para atestiguar que la delegación fue autorizada (flag `delegacion_autorizada`). La sección de upload de certificado/clave privada (`CertUploadSection`) SHALL eliminarse u ocultarse del flujo de delegación. El CUIT SHALL validarse con el algoritmo módulo 11 (reusando el validador `isValidCuit` de C-22) antes de permitir guardar.

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

## REMOVED Requirements

### Requirement: API de upload del certificado AFIP

**Reason**: El modelo de delegación elimina el certificado por usuario. La plataforma factura con su propio certificado representante (capability `afip-platform-credential`), por lo que los endpoints `POST /fiscal/profile/cert-upload-url` y `PUT /fiscal/profile/cert-path` dejan de formar parte del flujo. Mantenerlos activos induciría a los usuarios a un trámite innecesario y sostiene superficie de ataque (subida de material criptográfico) sin propósito.

**Migration**: Ningún usuario nuevo sube certificado. Para el flujo de delegación, el onboarding pasa por la "guía de delegación ARCA" (atestación `delegacion_autorizada` + alta de PV). La decisión de **eliminar vs. conservar como opción avanzada/fallback** los endpoints de upload es una Open Question del Gate 0 (sign-off del PO); por defecto se deprecan (no se exponen en la UI de delegación). La cuenta del PO (CUIT 20422662457, `AliadataProd`) — la única con cert per-user y cadena de producción validada — transiciona según lo que el PO defina en el sign-off (típicamente: pasa a representarse a sí misma vía el cert de plataforma, dado que es el mismo CUIT/cert candidato a representante).

### Requirement: Certificado AFIP en Storage privado

**Reason**: En el modelo de delegación no hay certificado por cuenta. El único material criptográfico es el del representante de la plataforma, custodiado en una ubicación fija server-side (capability `afip-platform-credential`), no en `{account_id}/afip.crt|afip.key` del bucket `afip-certs`. El esquema de dos objetos PEM por cuenta deja de aplicar.

**Migration**: El campo `fiscal_profiles.certificado_afip_path` queda como columna legada (no se puebla en el flujo de delegación) y deja de gobernar la selección real-vs-stub del adaptador (ahora gobernada por la config de plataforma — ver delta de `afip-fiscal-document`). Los objetos ya subidos al bucket `afip-certs` (la cuenta del PO) quedan inertes; su retiro/limpieza y el destino del bucket son parte del sign-off del Gate 0. El certificado de plataforma se aloja según lo que defina el PO (env/secret manager o un bucket restringido de plataforma, leído solo por el backend).
