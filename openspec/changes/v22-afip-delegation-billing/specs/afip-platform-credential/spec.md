## ADDED Requirements

### Requirement: Certificado representante de la plataforma (single secret server-side)

El sistema SHALL custodiar **un único** certificado digital AFIP de la plataforma (el "representante") y su clave privada en una ubicación fija server-side (variable de entorno / secret manager, o un objeto en un bucket privado restringido leído únicamente por el backend con `service_role`), NUNCA por cuenta y NUNCA expuesto al cliente. La clave privada del representante es el secreto más sensible del sistema: con ella se puede facturar por **cualquier** CUIT representado, por lo que SHALL leerse solo server-side, NUNCA SHALL loguearse y NUNCA SHALL devolverse en ninguna respuesta de la API. La configuración SHALL exponer el certificado + clave + el **CUIT representante** (p. ej. `afip_platform_cuit`), resueltos por el backend al construir el adaptador real.

#### Scenario: El certificado de plataforma vive en una sola ubicación server-side

- **WHEN** el backend necesita autenticar contra WSAA para cualquier cuenta representada
- **THEN** lee el certificado y la clave privada del **representante** desde la ubicación fija de plataforma (no desde `{account_id}/afip.crt`)
- **AND** el mismo material criptográfico se usa para todos los CUIT representados (no hay material por cuenta)

#### Scenario: La clave privada del representante nunca se expone

- **WHEN** se inspecciona cualquier respuesta de la API fiscal (perfil, PV, emisión) o los logs
- **THEN** el contenido del certificado y de la clave privada del representante no aparece en ninguna respuesta ni en ningún log

#### Scenario: CUIT representante configurado

- **WHEN** el backend resuelve la configuración del representante
- **THEN** dispone del CUIT del representante (configurado, p. ej. `afip_platform_cuit`) para distinguirlo del CUIT del emisor/representado en cada factura

---

### Requirement: Gate de configuración del representante (real vs stub)

El sistema SHALL seleccionar el adaptador real `WSFEAdapter` cuando el **certificado de plataforma está configurado** (cert + key + CUIT representante presentes y legibles server-side), y SHALL usar `WSFEStubAdapter` en cualquier otro caso. La selección NO SHALL depender de `fiscal_profiles.certificado_afip_path` por cuenta. El `WSFEStubAdapter` SHALL permanecer como **default seguro**: si el certificado de plataforma no está configurado, ninguna cuenta intenta una llamada real a AFIP.

#### Scenario: Sin certificado de plataforma configurado se usa el stub

- **GIVEN** un entorno donde el certificado de plataforma no está configurado
- **WHEN** la factory construye el adaptador para procesar un comprobante de cualquier cuenta
- **THEN** devuelve un `WSFEStubAdapter` (no toca AFIP) y el comportamiento no cambia

#### Scenario: Con certificado de plataforma configurado se usa el adaptador real

- **GIVEN** un entorno con el certificado de plataforma + CUIT representante configurados y legibles server-side
- **WHEN** la factory construye el adaptador para procesar un comprobante
- **THEN** devuelve un `WSFEAdapter` real que autenticará con el cert de plataforma y pondrá `Auth.Cuit` = CUIT del emisor de la cuenta

#### Scenario: La selección no depende del cert por cuenta

- **GIVEN** una cuenta con `fiscal_profiles.certificado_afip_path = NULL`
- **WHEN** el certificado de plataforma está configurado
- **THEN** la factory igualmente devuelve el `WSFEAdapter` real (el gate es plataforma, no per-account)

---

### Requirement: Flag de delegación autorizada por cuenta

El sistema SHALL registrar por cuenta si el usuario atestiguó haber completado la **relación de delegación** en ARCA (autorizó al CUIT de la plataforma como representante del servicio "Facturación Electrónica" en el Administrador de Relaciones de Clave Fiscal). Dado que AFIP no expone una forma fácil de verificar la relación programáticamente, el flag SHALL representar una **atestación del usuario** (no una verificación), y el sistema SHALL adoptar la estrategia de **intentar y exponer el error**: la única confirmación real de que la delegación está vigente es que `FECAESolicitar` se autorice. El flag SHALL ser editable solo por `owner`/`admin` (mismas reglas RLS que el resto del perfil fiscal).

#### Scenario: El usuario atestigua que autorizó la delegación

- **WHEN** el owner marca "Ya autoricé a EmprendeSmart en ARCA" en su perfil fiscal
- **THEN** el flag de delegación autorizada de su cuenta queda en verdadero

#### Scenario: El flag es una atestación, no una verificación

- **GIVEN** una cuenta con el flag de delegación en verdadero pero que en realidad no completó la relación en ARCA
- **WHEN** se intenta obtener el CAE
- **THEN** la llamada falla con el error de autorización de AFIP (la verdad la da AFIP, no el flag) y el error se mapea a un mensaje accionable

#### Scenario: Member no puede modificar el flag de delegación

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** intenta cambiar el flag de delegación autorizada
- **THEN** la operación es rechazada (solo owner/admin)

---

### Requirement: Mapeo del error de delegación faltante a mensaje accionable

El sistema SHALL detectar el caso en que la cuenta **aún no autorizó** al representante de la plataforma en ARCA — que se manifiesta como un rechazo de autorización al solicitar el CAE (el certificado de plataforma no está habilitado para representar a ese CUIT) — y SHALL mapearlo a un mensaje de dominio accionable que indique al usuario autorizar a EmprendeSmart (con el CUIT representante configurado) en ARCA → Administrador de Relaciones → Facturación Electrónica. El comprobante NO SHALL quedar `authorized` ante este error; SHALL persistir el error normalizado (reintentable o rechazo según corresponda) sin un CAE falso.

#### Scenario: Cuenta sin delegación recibe un mensaje accionable

- **GIVEN** una cuenta cuyo CUIT no autorizó al representante de la plataforma en ARCA
- **WHEN** se solicita el CAE para un comprobante de esa cuenta
- **THEN** la solicitud falla con el error de autorización de AFIP
- **AND** el sistema expone un mensaje accionable del estilo "Autorizá a EmprendeSmart (CUIT <representante>) en ARCA → Administrador de Relaciones → Facturación Electrónica"
- **AND** el comprobante no queda `authorized` (no se persiste un CAE)

#### Scenario: El error de delegación no se confunde con un rechazo de datos

- **WHEN** el adaptador normaliza el resultado de AFIP
- **THEN** el error de "no autorizado a representar" se distingue (código/detalle) de un rechazo por datos del comprobante (p. ej. Code 10246, Code 10016), de modo que el mensaje de onboarding solo se muestra para el caso de delegación faltante
