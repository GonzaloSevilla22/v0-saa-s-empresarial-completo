## ADDED Requirements

### Requirement: Persistencia del perfil fiscal de la organización
El sistema SHALL persistir un perfil fiscal por cuenta en la tabla `fiscal_profiles` (`id` UUID PK, `account_id` UUID FK `accounts` con UNIQUE, `cuit` TEXT NOT NULL, `iva_condition` TEXT, `iibb_condition` TEXT, `punto_de_venta` INTEGER, `certificado_afip_path` TEXT, `ambiente` TEXT NOT NULL DEFAULT `'homologacion'`, `created_at` TIMESTAMPTZ). `iva_condition` MUST estar restringida por CHECK a `'responsable_inscripto'`, `'monotributista'`, `'exento'`, `'consumidor_final'`. `ambiente` MUST estar restringida por CHECK a `'homologacion'`, `'produccion'`. El UNIQUE en `account_id` garantiza a lo sumo un perfil por organización.

#### Scenario: Cuenta crea su perfil fiscal
- **WHEN** el owner de una cuenta sin perfil fiscal lo crea con `cuit`, `iva_condition = 'responsable_inscripto'` y `punto_de_venta = 1`
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

### Requirement: Ambiente AFIP configurable por cuenta
El sistema SHALL resolver el ambiente AFIP (homologación o producción) a partir de `fiscal_profiles.ambiente` de la cuenta emisora, no de una variable de entorno global. El cutover de una cuenta a producción SHALL consistir en cambiar `ambiente` a `'produccion'` y subir el certificado real, sin requerir cambios de código ni re-deploy.

#### Scenario: El adaptador WSFE usa el ambiente del perfil de la cuenta
- **GIVEN** la cuenta A con `ambiente = 'homologacion'` y la cuenta B con `ambiente = 'produccion'`
- **WHEN** cada una solicita un CAE
- **THEN** el adaptador apunta al web service de homologación para A y al de producción para B, sin re-deploy del backend

#### Scenario: Default de homologación para cuentas nuevas
- **WHEN** se crea un perfil fiscal sin especificar `ambiente`
- **THEN** el perfil queda en `'homologacion'`

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

### Requirement: API del perfil fiscal
El backend Python SHALL exponer un router `fiscal` con endpoints para leer y crear/actualizar el perfil fiscal de la cuenta activa. Los schemas Pydantic `FiscalProfileCreate`/`FiscalProfileUpdate` SHALL validar `iva_condition` (Literal de los 4 valores) y `ambiente` (Literal de los 2 valores) antes de tocar la DB; `FiscalProfileOut` SHALL devolver todos los campos excepto el contenido del certificado (solo el path). El acceso a datos vive en `FiscalProfileRepository` vía JWT-passthrough; el router no contiene lógica de negocio.

#### Scenario: Obtener el perfil fiscal de la cuenta
- **WHEN** se hace GET `/fiscal/profile` con un usuario cuya cuenta tiene perfil
- **THEN** la respuesta 200 incluye `cuit`, `iva_condition`, `punto_de_venta`, `ambiente` y `certificado_afip_path`, sin el contenido del certificado

#### Scenario: Crear perfil con condición IVA inválida rechazado en el endpoint
- **WHEN** se hace POST `/fiscal/profile` con `iva_condition = 'otro'`
- **THEN** la API responde 422 sin tocar la DB

#### Scenario: Ambiente inválido rechazado en el endpoint
- **WHEN** se hace POST `/fiscal/profile` con `ambiente = 'sandbox'`
- **THEN** la API responde 422 sin tocar la DB

### Requirement: Certificado AFIP en Storage privado
El sistema SHALL almacenar el certificado AFIP (`.crt`/`.key`) en un bucket de Storage privado (no público), con policies de INSERT, SELECT y UPDATE scoped por `account_id`. `fiscal_profiles.certificado_afip_path` SHALL guardar únicamente la ruta del objeto, nunca su contenido. El certificado SHALL leerse solo server-side (backend/Edge) para firmar la autenticación WSAA; nunca SHALL exponerse al cliente.

#### Scenario: El certificado no es accesible públicamente
- **GIVEN** un certificado subido al bucket `afip-certs`
- **WHEN** se intenta acceder a su URL pública sin autenticación
- **THEN** el acceso es denegado (bucket privado)

#### Scenario: Solo la cuenta dueña puede subir su certificado
- **GIVEN** dos cuentas A y B
- **WHEN** un miembro de A intenta subir un objeto a la ruta del certificado de B
- **THEN** la policy de Storage rechaza el INSERT (scoped por `account_id`)

### Requirement: UI de configuración fiscal
El frontend SHALL proveer una página `/configuracion/fiscal` con un formulario del perfil fiscal (CUIT, condición IVA, IIBB, punto de venta, ambiente) y un control de upload del certificado AFIP al bucket privado. El CUIT SHALL validarse con el algoritmo módulo 11 (reusando el validador de C-22) antes de permitir guardar.

#### Scenario: Guardar el perfil fiscal con CUIT válido
- **WHEN** el owner completa CUIT válido + condición IVA + punto de venta y guarda
- **THEN** la mutación persiste el perfil y la página refleja los datos guardados

#### Scenario: CUIT con dígito verificador inválido bloquea el submit
- **WHEN** el usuario ingresa un CUIT con formato correcto pero dígito verificador incorrecto
- **THEN** el formulario muestra error y no envía la mutación

#### Scenario: Subir el certificado AFIP
- **WHEN** el owner selecciona un archivo de certificado y lo sube
- **THEN** el archivo va al bucket privado y `certificado_afip_path` se actualiza con la ruta
