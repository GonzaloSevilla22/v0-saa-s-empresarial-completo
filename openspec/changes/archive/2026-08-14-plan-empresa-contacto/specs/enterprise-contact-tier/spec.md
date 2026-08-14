## ADDED Requirements

### Requirement: Tier Empresa presente en las superficies de precios
Las superficies que presentan la oferta comercial SHALL incluir un tier "Empresa" adicional a los cuatro planes de precio cerrado.

El tier MUST aparecer tanto en la sección de precios de la landing pública como en la pantalla de planes de la aplicación, MUST presentarse después de los cuatro planes comprables y MUST NOT formar parte de la grilla comparativa de esos planes.

#### Scenario: Visible en la landing pública
- **WHEN** un visitante llega a la sección de precios de la landing pública con el canal de contacto configurado
- **THEN** ve el tier Empresa presentado a continuación de los cuatro planes

#### Scenario: Visible en la pantalla de planes de la aplicación
- **WHEN** un usuario autenticado abre la pantalla de planes con el canal de contacto configurado
- **THEN** ve el tier Empresa presentado a continuación del comparativo de los cuatro planes

#### Scenario: No altera el comparativo de planes comprables
- **WHEN** se renderiza cualquiera de las dos superficies con el tier Empresa presente
- **THEN** los cuatro planes comprables conservan su cantidad, su orden y sus acciones de compra

### Requirement: Contenido de contacto en lugar de precio
El tier Empresa SHALL comunicar adaptación del sistema a medida y MUST NOT exhibir un precio mensual.

En el lugar del importe MUST mostrar una indicación de precio a convenir, MUST acompañarla de una descripción de adaptación a la forma de trabajo de la empresa y MUST enumerar las capacidades que distinguen al tier. Las capacidades enunciadas MUST corresponder a funcionalidad existente o a acompañamiento comercial, y MUST NOT prometer desarrollos inexistentes.

#### Scenario: Sin importe mensual
- **WHEN** se renderiza el tier Empresa
- **THEN** no se muestra ningún importe ni período de facturación, sino una indicación de precio a convenir

#### Scenario: Mensaje de adaptación a medida
- **WHEN** se renderiza el tier Empresa
- **THEN** el texto comunica que el sistema se adapta a la forma de trabajar de la empresa

#### Scenario: Capacidades enumeradas
- **WHEN** se renderiza el tier Empresa
- **THEN** se listan sus capacidades diferenciales, incluida al menos la ampliación de sucursales y usuarios más allá del plan de mayor precio

### Requirement: Fuente única del contenido del tier
El contenido del tier Empresa SHALL provenir de una única definición canónica compartida por todas las superficies que lo presentan.

Ninguna superficie MUST redactar por su cuenta el nombre, la descripción, las capacidades ni la etiqueta de la acción: modificar cualquiera de esos textos MUST impactar en todas las superficies a la vez.

#### Scenario: Mismo contenido en ambas superficies
- **WHEN** se comparan el tier Empresa de la landing y el de la pantalla de planes
- **THEN** el nombre, la descripción, las capacidades y la etiqueta de la acción son idénticos

#### Scenario: Un cambio de copy alcanza a todas las superficies
- **WHEN** se modifica la definición canónica del contenido del tier
- **THEN** ambas superficies reflejan el cambio sin edición adicional

### Requirement: Acción de contacto por WhatsApp con mensaje del tier
La acción principal del tier Empresa SHALL abrir una conversación de WhatsApp con el número comercial de ALIADATA, con un mensaje inicial pre-cargado que identifique el interés en el tier Empresa.

El destino MUST construirse con el helper canónico de contacto del proyecto a partir del número configurado, y el mensaje MUST ser distinto del mensaje general del canal para que la conversación llegue ya calificada. La acción MUST NOT iniciar ningún flujo de pago ni de cambio de plan.

#### Scenario: El enlace lleva al WhatsApp comercial con contexto
- **WHEN** el visitante activa la acción del tier Empresa
- **THEN** WhatsApp abre la conversación con el número comercial configurado y el mensaje sobre el plan Empresa ya escrito

#### Scenario: Mensaje propio del tier
- **WHEN** se comparan el mensaje del tier Empresa y el mensaje general del canal de contacto
- **THEN** son distintos y el del tier menciona el interés en el plan Empresa

#### Scenario: No hay checkout
- **WHEN** el visitante activa la acción del tier Empresa
- **THEN** no se crea ninguna preferencia de pago ni suscripción, y el plan de la cuenta no cambia

### Requirement: Seguridad y accesibilidad de la acción de contacto
La acción del tier Empresa SHALL abrirse en una pestaña nueva protegida y MUST ser operable y comprensible con teclado y lector de pantalla.

El enlace MUST declarar `rel` con `noopener` y `noreferrer`, MUST exponer un nombre accesible que mencione WhatsApp, el plan Empresa y la apertura en pestaña nueva, MUST ser alcanzable por tabulación con indicador de foco visible sobre el fondo de cada superficie, y su área táctil MUST medir al menos 44 × 44 píxeles CSS.

#### Scenario: Apertura protegida en pestaña nueva
- **WHEN** el visitante activa la acción del tier Empresa
- **THEN** el destino se abre en una pestaña nueva y el enlace declara `noopener` y `noreferrer`

#### Scenario: Nombre accesible descriptivo
- **WHEN** un lector de pantalla anuncia la acción del tier Empresa
- **THEN** lee un nombre que menciona WhatsApp, el plan Empresa y que el enlace abre una pestaña nueva

#### Scenario: Operable por teclado
- **WHEN** el visitante navega con la tecla de tabulación
- **THEN** la acción recibe foco con un indicador visible y se activa con Enter

### Requirement: Degradación sin canal de contacto configurado
Cuando el número de contacto no esté configurado o no pueda normalizarse a un número válido, el tier Empresa SHALL omitirse por completo en lugar de publicarse con una acción sin destino.

Ninguna superficie MUST renderizar la acción del tier apuntando a un enlace de WhatsApp sin número, ni deshabilitada, ni inerte. La ausencia de configuración MUST NOT provocar errores de renderizado ni alterar el resto de la superficie.

#### Scenario: Sin número configurado en la landing
- **WHEN** el número de contacto no está definido y se renderiza la sección de precios de la landing
- **THEN** el tier Empresa no aparece y los cuatro planes se muestran con normalidad

#### Scenario: Sin número configurado en la pantalla de planes
- **WHEN** el número de contacto no está definido y se renderiza la pantalla de planes
- **THEN** el tier Empresa no aparece y el comparativo de los cuatro planes se muestra con normalidad

#### Scenario: Número inválido
- **WHEN** el número configurado no puede normalizarse a un número argentino válido
- **THEN** el tier Empresa no se renderiza y no se emite ningún enlace de WhatsApp sin número

### Requirement: El tier Empresa queda fuera del motor de facturación
El tier Empresa SHALL ser exclusivamente una oferta de contacto y MUST NOT existir como plan del sistema de facturación.

El tier MUST NOT incorporarse al conjunto de planes del sistema, al catálogo de límites por plan ni a ninguna tabla de planes de la base de datos; MUST NOT participar de la evaluación de límites y permisos por plan; y MUST NOT influir en los indicadores de negocio derivados de los planes, incluido el ingreso recurrente mensual.

#### Scenario: El conjunto de planes no cambia
- **WHEN** se inspecciona el catálogo de planes y límites del sistema con el tier Empresa ya publicado
- **THEN** contiene exactamente los cuatro planes previos, sin una entrada para Empresa

#### Scenario: El gating no reconoce un plan Empresa
- **WHEN** se evalúan límites o permisos de cualquier cuenta
- **THEN** la evaluación se resuelve contra uno de los cuatro planes existentes y nunca contra un plan Empresa

#### Scenario: Los indicadores de negocio no se alteran
- **WHEN** se calculan los indicadores de negocio por plan después de publicar el tier
- **THEN** el ingreso recurrente mensual y las poblaciones por plan se derivan solo de los cuatro planes existentes

### Requirement: Presentación coherente con la superficie que lo contiene
La presentación visual del tier Empresa SHALL adaptarse a la superficie donde se monta, sin duplicar el componente.

En la pantalla de planes de la aplicación el tier MUST usar exclusivamente los tokens semánticos del design system y MUST resultar legible en tema claro y oscuro; en la landing pública MUST usar la paleta de la sección de precios que lo contiene. La presentación MUST ser legible y operable en viewport de escritorio y de teléfono.

#### Scenario: Tema claro y oscuro en la aplicación
- **WHEN** un usuario alterna entre tema claro y oscuro en la pantalla de planes
- **THEN** el tier Empresa conserva contraste suficiente y ningún color queda fijado a un solo tema

#### Scenario: Continuidad visual en la landing
- **WHEN** se renderiza la sección de precios de la landing
- **THEN** el tier Empresa comparte la paleta de esa sección y no introduce un bloque claro sobre el fondo oscuro

#### Scenario: Legible en teléfono
- **WHEN** la superficie se renderiza en un viewport de 375 píxeles de ancho
- **THEN** el contenido del tier apila sin desbordes horizontales y la acción conserva su área táctil mínima
