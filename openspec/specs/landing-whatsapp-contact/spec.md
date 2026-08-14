# landing-whatsapp-contact Specification

## Purpose

Canal de contacto directo por WhatsApp desde la landing pública: un botón flotante (FAB) fijo en la esquina inferior derecha de la home `/`, que abre una conversación con el número comercial de ALIADATA con mensaje inicial pre-cargado. Cubre la visibilidad y el alcance del botón (exclusivo de la home, montado en la página — nunca en un layout ni componente compartido), el origen configurable del número (variable de entorno de servidor `ALIADATA_WHATSAPP_PHONE`), su normalización al formato `wa.me` reutilizando las utilidades canónicas de `lib/phone-utils.ts`, la degradación silenciosa cuando no hay número válido (no renderizar nada antes que publicar un enlace al selector de contactos), y las garantías de seguridad (`noopener noreferrer`) y accesibilidad del enlace saliente.

Origen: change `landing-whatsapp-fab` (PR #360, 2026-08-05). Sin superficie de backend ni migraciones.

## Requirements

### Requirement: Botón flotante de WhatsApp en la landing pública
La landing pública SHALL presentar un botón flotante de contacto por WhatsApp que permanezca fijo y visible durante todo el recorrido de la página, sin importar la posición de scroll del visitante.

El botón MUST estar anclado a la esquina inferior derecha del viewport mediante posicionamiento fijo, MUST ser visible desde el estado inicial de la página (sin requerir scroll previo) y MUST permanecer visible al llegar al final del documento.

#### Scenario: Visible al cargar la landing
- **WHEN** un visitante abre la landing pública con el número de contacto configurado
- **THEN** el botón de WhatsApp se muestra en la esquina inferior derecha sin necesidad de hacer scroll

#### Scenario: Acompaña el scroll
- **WHEN** el visitante hace scroll hasta cualquier sección de la landing, incluido el pie de página
- **THEN** el botón permanece fijo en la esquina inferior derecha del viewport

#### Scenario: No se superpone a la barra de navegación ni a los diálogos
- **WHEN** el botón se renderiza junto al resto de la landing
- **THEN** su nivel de apilado es inferior al de la barra de navegación fija y al de los diálogos y paneles modales de la aplicación

### Requirement: Alcance exclusivo de la home pública
El botón flotante de WhatsApp SHALL renderizarse únicamente en la home pública (`/`).

El botón MUST NOT aparecer en ninguna otra ruta de la aplicación, incluidas la variante de landing `/landing`, las pantallas de autenticación y todas las pantallas del dashboard. Para garantizarlo estructuralmente, el botón MUST montarse en la página de la home y NOT en un layout, componente compartido o cualquier otro punto reutilizado por otras rutas.

#### Scenario: Presente en la home
- **WHEN** se renderiza la ruta `/`
- **THEN** el botón flotante de WhatsApp forma parte del árbol renderizado

#### Scenario: Ausente en el resto de la aplicación
- **WHEN** se renderiza cualquier ruta distinta de `/`, incluidas `/landing`, las rutas de autenticación y las del dashboard
- **THEN** el botón flotante de WhatsApp no forma parte del árbol renderizado

### Requirement: Origen configurable del número de destino
El número de WhatsApp de destino SHALL provenir de una variable de entorno de servidor y NOT estar embebido como literal en el código de los componentes.

El sistema MUST leer la variable en el servidor y pasar su valor al botón. Cambiar el número de contacto MUST NOT requerir modificar código de la aplicación.

#### Scenario: El número configurado determina el destino del enlace
- **WHEN** la variable de entorno contiene un número de WhatsApp válido
- **THEN** el enlace del botón apunta a ese número

#### Scenario: Cambiar la configuración cambia el destino
- **WHEN** el valor de la variable de entorno se reemplaza por otro número válido
- **THEN** el enlace del botón apunta al nuevo número sin que se haya modificado el código de la aplicación

### Requirement: Normalización del número al formato de enlace de WhatsApp
El sistema SHALL normalizar el número configurado al formato internacional que exigen los enlaces `wa.me` para móviles argentinos, reutilizando las utilidades de teléfono existentes del proyecto.

El número MUST aceptarse en los formatos habituales de escritura (con o sin prefijo internacional, con espacios, guiones o paréntesis) y MUST convertirse a la forma canónica de solo dígitos con prefijo `549`.

#### Scenario: Número con prefijo internacional y separadores
- **WHEN** la variable de entorno contiene `+54 9 2617 63-5174`
- **THEN** el enlace generado apunta a `https://wa.me/5492617635174`

#### Scenario: Número en formato local
- **WHEN** la variable de entorno contiene un número argentino en formato local con prefijo de discado nacional, por ejemplo `0261 763-5174`
- **THEN** el enlace generado apunta al mismo número en forma canónica con prefijo `549`

### Requirement: Mensaje inicial pre-cargado
El enlace del botón SHALL incluir un mensaje inicial pre-cargado, codificado para URL, de modo que la conversación comience con contexto sobre el origen del contacto.

El canal MUST admitir un mensaje distinto por superficie de origen, definido junto al resto de la configuración canónica del contacto. Cuando una superficie no especifique mensaje propio, MUST usarse el mensaje general del canal, de modo que las superficies ya existentes conserven su texto actual sin cambios.

#### Scenario: El enlace lleva el mensaje pre-cargado
- **WHEN** el visitante toca el botón de WhatsApp
- **THEN** WhatsApp abre la conversación con el mensaje inicial ya escrito en el campo de texto, listo para enviar

#### Scenario: El mensaje viaja codificado
- **WHEN** el mensaje inicial contiene espacios o caracteres no ASCII
- **THEN** el parámetro `text` del enlace los transporta codificados para URL, sin romper la URL

#### Scenario: Mensaje propio de una superficie
- **WHEN** una superficie de contacto solicita el enlace indicando su propio mensaje inicial
- **THEN** el enlace generado transporta ese mensaje codificado, y no el mensaje general del canal

#### Scenario: Superficies sin mensaje propio
- **WHEN** una superficie solicita el enlace sin indicar mensaje
- **THEN** el enlace generado transporta el mensaje general del canal, idéntico al comportamiento previo

### Requirement: Degradación silenciosa sin número válido
Cuando el número de contacto no esté configurado o no pueda normalizarse a un número válido, el sistema SHALL omitir por completo el botón en lugar de publicar un enlace sin destino.

El sistema MUST NOT renderizar un enlace a `wa.me` sin número, porque ese enlace abre el selector de contactos de WhatsApp y obligaría al visitante a elegir manualmente el destinatario. La ausencia de configuración MUST NOT provocar errores de renderizado en la landing. Esta garantía MUST valer para toda superficie que consuma el canal, cualquiera sea el mensaje inicial que solicite.

#### Scenario: Variable de entorno ausente
- **WHEN** la variable de entorno del número de contacto no está definida
- **THEN** el botón no se renderiza y el resto de la landing se muestra con normalidad

#### Scenario: Variable de entorno vacía
- **WHEN** la variable de entorno está definida pero vacía o solo con espacios
- **THEN** el botón no se renderiza y el resto de la landing se muestra con normalidad

#### Scenario: Número inválido
- **WHEN** la variable de entorno contiene un valor que no puede normalizarse a un número argentino válido, por ejemplo `123`
- **THEN** el botón no se renderiza y no se emite ningún enlace a `wa.me`

#### Scenario: Mensaje propio con número inválido
- **WHEN** una superficie solicita el enlace con su propio mensaje inicial y el número configurado es inválido
- **THEN** no se genera enlace alguno y la superficie omite su acción de contacto

### Requirement: Seguridad del enlace saliente
El botón SHALL abrir WhatsApp en un contexto de navegación nuevo y MUST impedir que el destino obtenga una referencia a la ventana de origen.

El enlace MUST declarar `rel` con `noopener` y `noreferrer` junto a la apertura en pestaña nueva, para evitar el secuestro de la pestaña de origen (*tabnabbing*).

#### Scenario: Apertura protegida en pestaña nueva
- **WHEN** el visitante toca el botón de WhatsApp
- **THEN** el destino se abre en una pestaña nueva y el enlace declara `noopener` y `noreferrer`

### Requirement: Accesibilidad del botón de contacto
El botón SHALL ser operable y comprensible con teclado y con lector de pantalla.

El botón MUST exponer un nombre accesible que identifique el destino y advierta que abre una pestaña nueva; su ícono MUST tratarse como decorativo; MUST ser alcanzable por tabulación con un indicador de foco visible sobre el fondo oscuro de la landing; y su área táctil MUST medir al menos 44 × 44 píxeles CSS.

#### Scenario: Nombre accesible descriptivo
- **WHEN** un lector de pantalla anuncia el botón
- **THEN** lee un nombre accesible que menciona WhatsApp e indica que el enlace abre una pestaña nueva

#### Scenario: Ícono decorativo
- **WHEN** un lector de pantalla recorre el contenido del botón
- **THEN** el glifo de WhatsApp está marcado como decorativo y no se anuncia por separado

#### Scenario: Operable por teclado
- **WHEN** el visitante navega con la tecla de tabulación
- **THEN** el botón recibe foco con un indicador visible y se activa con Enter

#### Scenario: Área táctil suficiente
- **WHEN** el botón se muestra en un viewport móvil
- **THEN** su área interactiva mide al menos 44 × 44 píxeles CSS

### Requirement: Movimiento respetuoso de las preferencias del sistema
La micro-interacción de hover y foco del botón SHALL anularse cuando el sistema operativo del visitante declare preferencia por movimiento reducido.

#### Scenario: Preferencia de movimiento reducido activa
- **WHEN** el visitante tiene activada la preferencia de movimiento reducido y apunta o enfoca el botón
- **THEN** el botón no aplica la transición de escala y cambia de estado sin animación
