## ADDED Requirements

### Requirement: El webhook de entrega de correo SHALL autenticarse con un secreto compartido

La Edge Function `send-email` SHALL exigir el header `x-webhook-secret` en toda request y SHALL rechazarla cuando el valor esté ausente o no coincida con el secreto configurado en la propia función. La verificación SHALL ejecutarse como **primera operación del handler**, antes de leer o parsear el cuerpo de la request y antes de cualquier llamada al proveedor de correo.

La comparación del secreto SHALL realizarse en **tiempo constante** respecto del contenido, de modo que el tiempo de respuesta no revele cuántos caracteres del secreto son correctos.

La función NOT SHALL depender de `verify_jwt` para su control de acceso: el llamador legítimo es un trigger de base de datos vía `pg_net`, que no dispone de un JWT de usuario.

Una request rechazada NOT SHALL producir ningún efecto sobre la tabla `email_logs` ni ningún envío de correo.

#### Scenario: Request sin el header es rechazada

- **GIVEN** la Edge Function `send-email` desplegada con su secreto configurado
- **WHEN** se envía un `POST` con un payload perfectamente válido (`type = 'INSERT'`, `table = 'email_logs'`, `record.status = 'pending'`) pero **sin** el header `x-webhook-secret`
- **THEN** la función responde HTTP **401**
- **AND** no se invoca al proveedor de correo
- **AND** no se modifica ninguna fila de `email_logs`

#### Scenario: Request con secreto incorrecto es rechazada

- **GIVEN** la Edge Function `send-email` desplegada con su secreto configurado
- **WHEN** se envía un `POST` con un payload válido y el header `x-webhook-secret` con un valor distinto del configurado
- **THEN** la función responde HTTP **401**
- **AND** no se invoca al proveedor de correo

#### Scenario: Request con el secreto correcto es procesada

- **GIVEN** la Edge Function `send-email` desplegada con su secreto configurado
- **WHEN** el trigger de producción envía un `POST` con el header `x-webhook-secret` correcto y un `record` con `status = 'pending'`
- **THEN** la función procesa el envío y actualiza la fila de `email_logs` con `status = 'sent'`, `provider_id` y `sent_at`, exactamente igual que antes de este cambio

#### Scenario: La verificación ocurre antes de parsear el cuerpo

- **GIVEN** la Edge Function `send-email` desplegada con su secreto configurado
- **WHEN** se envía un `POST` con un cuerpo que no es JSON válido y **sin** el header `x-webhook-secret`
- **THEN** la función responde HTTP **401** (rechazo por origen), y **no** HTTP 400 (error de forma del payload)

### Requirement: La función SHALL distinguir el fallo de configuración del rechazo de origen

Cuando la Edge Function `send-email` no tenga su secreto configurado en el entorno, SHALL responder HTTP **503** con una causa identificable como error de configuración, en lugar de HTTP 401. La función NOT SHALL degradar a aceptar la request (comportamiento *fail-open*) cuando el secreto no esté configurado.

#### Scenario: Función sin secreto configurado rechaza con 503

- **GIVEN** la Edge Function `send-email` desplegada **sin** el secreto en su entorno
- **WHEN** llega cualquier request, con o sin el header `x-webhook-secret`
- **THEN** la función responde HTTP **503** indicando configuración faltante
- **AND** no se invoca al proveedor de correo

#### Scenario: Ausencia de configuración nunca habilita el paso libre

- **GIVEN** la Edge Function `send-email` desplegada **sin** el secreto en su entorno
- **WHEN** llega una request con un payload válido
- **THEN** la request es rechazada
- **AND** en ningún caso se procesa el envío por el hecho de que el secreto no esté configurado

### Requirement: El trigger de entrega SHALL tomar su destino y su secreto de configuración, no del código

La función del trigger `public.send_email_log_webhook()` SHALL obtener la URL de destino y el secreto compartido desde **Supabase Vault** (`vault.decrypted_secrets`), y NOT SHALL contener ninguno de los dos valores literales en el cuerpo de la migración ni de la función.

La función SHALL ser `SECURITY DEFINER` para poder leer Vault sin otorgar acceso a Vault a los roles de aplicación.

Al invocar el endpoint, SHALL incluir el secreto en el header `x-webhook-secret`.

#### Scenario: El trigger envía el header de autenticación

- **GIVEN** una base con ambos secretos presentes en Vault
- **WHEN** se inserta una fila en `email_logs` con `status = 'pending'`
- **THEN** el trigger emite un `net.http_post` hacia la URL tomada de Vault
- **AND** la request incluye el header `x-webhook-secret` con el valor tomado de Vault

#### Scenario: Ninguna URL de proyecto queda literal en la migración

- **WHEN** se inspecciona el cuerpo de `public.send_email_log_webhook()` en la base
- **THEN** no aparece ninguna URL de proyecto Supabase literal
- **AND** no aparece ningún valor de secreto literal

### Requirement: El trigger SHALL ser inerte en toda base sin la configuración de producción

Cuando falte en Vault el secreto compartido o la URL de destino, la función del trigger SHALL registrar un aviso (`RAISE NOTICE`) y retornar **sin emitir ninguna request HTTP**.

La posesión de la configuración SHALL ser el único criterio que determina si el trigger emite tráfico: la función NOT SHALL inferir el entorno por otros medios (nombre de base, banderas, variables de entorno).

Esta condición SHALL garantizar que ninguna base de CI, de preview o local pueda emitir tráfico hacia la Edge Function de producción, aun teniendo el trigger instalado.

#### Scenario: Base de CI no emite tráfico hacia producción

- **GIVEN** una base efímera de CI creada con `supabase db reset`, sin secretos en Vault
- **WHEN** los gates de comportamiento de las migraciones siembran usuarios sintéticos y `handle_new_user` inserta filas en `email_logs`
- **THEN** el trigger no emite ninguna request HTTP
- **AND** se registra un `NOTICE` por cada fila omitida
- **AND** la Edge Function de producción no recibe ninguna request originada en esa base

#### Scenario: Configuración parcial también inhibe el envío

- **GIVEN** una base donde existe en Vault el secreto compartido pero **no** la URL de destino (o viceversa)
- **WHEN** se inserta una fila en `email_logs` con `status = 'pending'`
- **THEN** el trigger no emite ninguna request HTTP
- **AND** se registra un `NOTICE`

#### Scenario: El INSERT nunca falla por culpa del webhook

- **GIVEN** una base sin la configuración de producción
- **WHEN** un productor inserta una fila en `email_logs`
- **THEN** el `INSERT` se confirma normalmente y la fila queda persistida
- **AND** la ausencia de configuración no aborta la transacción del productor

### Requirement: El trigger SHALL emitir la request solo para filas pendientes de envío

La función del trigger SHALL omitir la llamada HTTP cuando la fila insertada tenga un `status` distinto de `'pending'`, dado que la Edge Function rechaza esas filas sin producir correo.

#### Scenario: Fila no pendiente no genera tráfico

- **GIVEN** una base con la configuración de producción presente
- **WHEN** se inserta en `email_logs` una fila con `status = 'sent'`
- **THEN** el trigger no emite ninguna request HTTP

#### Scenario: Fila pendiente sí genera tráfico

- **GIVEN** una base con la configuración de producción presente
- **WHEN** se inserta en `email_logs` una fila con `status = 'pending'`
- **THEN** el trigger emite la request HTTP autenticada

### Requirement: La lógica de verificación SHALL residir en un módulo puro y cubierto por tests

La verificación del secreto SHALL vivir en un módulo compartido bajo `supabase/functions/_shared/`, expuesto como función pura que recibe el valor provisto y el valor esperado como parámetros y devuelve un resultado explícito.

El módulo NOT SHALL referenciar `Deno.*` en scope de módulo, de modo que sea importable por el runner de tests vigente del repositorio (vitest desde `frontend/__tests__/`).

La suite SHALL importar el archivo real del módulo y NOT SHALL re-declarar la lógica de verificación dentro del test.

#### Scenario: El módulo es importable y verificable desde la suite del repo

- **WHEN** se ejecuta la suite de vitest del frontend
- **THEN** el test importa el módulo real de `supabase/functions/_shared/` por ruta relativa
- **AND** cubre al menos: secreto correcto, secreto incorrecto, valor ausente y configuración faltante

#### Scenario: La divergencia entre función y test queda detectada

- **GIVEN** que el test importa el archivo real en lugar de reimplementar la regla
- **WHEN** alguien modifica la regla de verificación en el módulo compartido
- **THEN** la suite refleja el cambio sin necesidad de editar el test para que siga pasando

### Requirement: El fan-out a `recipient = 'all_users'` SHALL restringirse a una allowlist de `event_type`

Cuando una fila insertada en `email_logs` tenga `recipient = 'all_users'`, la Edge Function `send-email` SHALL verificar que su `event_type` pertenezca a una allowlist explícita (`meeting_notice`, `pool_notice`) antes de resolver la lista de destinatarios. Un `event_type` fuera de la allowlist NOT SHALL producir ningún envío de correo.

> Añadido durante el apply (sign-off PO 2026-07-31, OQ3 = sí — ver `design.md` §Risks y §Open Questions). Antes de este sign-off el fan-out masivo era alcanzable desde afuera del sistema (relay abierto); tras la autenticación del webhook deja de serlo, pero persiste como riesgo de accidente interno: un `INSERT` erróneo en `email_logs` dispararía un envío a todos los usuarios reales sin confirmación.

La lógica de la allowlist SHALL residir en un módulo puro bajo `supabase/functions/_shared/`, con las mismas restricciones de testabilidad (sin `Deno.*` en scope de módulo) que la verificación del secreto.

#### Scenario: Fan-out a todos los usuarios con un event_type permitido

- **GIVEN** una fila en `email_logs` con `recipient = 'all_users'` y `event_type = 'meeting_notice'` (o `'pool_notice'`)
- **WHEN** la Edge Function procesa la fila
- **THEN** se resuelve la lista completa de usuarios reales y se envía el correo normalmente

#### Scenario: Fan-out a todos los usuarios con un event_type no permitido es rechazado

- **GIVEN** una fila en `email_logs` con `recipient = 'all_users'` y un `event_type` que no está en la allowlist (p. ej. `welcome`)
- **WHEN** la Edge Function procesa la fila
- **THEN** no se invoca la resolución de usuarios ni el proveedor de correo
- **AND** la fila de `email_logs` queda en un estado terminal (`failed`) con la causa del rechazo
- **AND** se registra la causa en el log de la función sin exponer datos de usuarios
