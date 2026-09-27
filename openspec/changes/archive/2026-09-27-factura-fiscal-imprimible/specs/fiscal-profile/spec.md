## MODIFIED Requirements

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

### Requirement: UI de configuración fiscal

El frontend SHALL proveer una página `/configuracion/fiscal` con un formulario del perfil fiscal (CUIT, condición IVA, IIBB, ambiente), un **CRUD mínimo de puntos de venta** (listar / agregar / desactivar, sin límite de cantidad) y una **guía de onboarding de la delegación en ARCA** que reemplaza los controles de upload del certificado. La guía SHALL mostrar el paso a paso para autorizar a EmprendeSmart (con el CUIT representante de la plataforma) en ARCA → Administrador de Relaciones → Facturación Electrónica, y SHALL ofrecer el control para atestiguar que la delegación fue autorizada (flag `delegacion_autorizada`). La sección de upload de certificado/clave privada (`CertUploadSection`) SHALL eliminarse u ocultarse del flujo de delegación. El CUIT SHALL validarse con el algoritmo módulo 11 (reusando el validador `isValidCuit` de C-22) antes de permitir guardar.

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

#### Scenario: Cargar los datos para imprimir la factura

- **WHEN** el owner completa razón social, domicilio comercial, número de IIBB e inicio de actividades y guarda
- **THEN** la mutación los persiste y el aviso de datos faltantes desaparece

#### Scenario: Aviso de datos faltantes

- **GIVEN** un perfil sin domicilio comercial ni inicio de actividades
- **WHEN** el owner abre `/configuracion/fiscal`
- **THEN** ve un aviso que dice que para imprimir facturas falta completar el domicilio comercial y el inicio de actividades
