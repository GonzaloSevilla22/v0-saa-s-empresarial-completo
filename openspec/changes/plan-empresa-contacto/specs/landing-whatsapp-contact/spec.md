## MODIFIED Requirements

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
