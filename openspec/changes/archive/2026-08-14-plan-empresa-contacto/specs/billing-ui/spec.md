## ADDED Requirements

### Requirement: Bloque de contacto Empresa en /planes
La pantalla `/planes` SHALL presentar, debajo del comparativo de los cuatro planes, un bloque de contacto para el tier Empresa que no participa del flujo de compra.

El bloque MUST montarse como hermano del comparativo y NOT dentro de él, de modo que el comparativo conserve sus cuatro columnas, su orden y su lógica de compra sin modificación. El bloque MUST NOT mostrarse nunca como "tu plan actual", MUST NOT ofrecer contratar, subir ni bajar de plan, y su acción MUST NOT invocar la creación de preferencias de pago ni de suscripciones.

#### Scenario: Usuario ve el bloque debajo del comparativo
- **WHEN** un usuario autenticado visita `/planes` con el canal de contacto configurado
- **THEN** ve las cuatro columnas de planes y, debajo, el bloque de contacto del tier Empresa

#### Scenario: El comparativo no cambia
- **WHEN** se renderiza `/planes` con el bloque presente
- **THEN** el comparativo sigue mostrando exactamente los planes Gratis, Inicial, Avanzado y PRO, con su plan actual destacado y sus CTA de compra intactos

#### Scenario: La acción del bloque no dispara pagos
- **WHEN** el usuario activa la acción del bloque de contacto Empresa
- **THEN** no se hace ninguna llamada de creación de preferencia ni de suscripción, y el plan de la cuenta permanece igual

#### Scenario: Sin canal de contacto configurado
- **WHEN** el número de contacto no está configurado y el usuario visita `/planes`
- **THEN** el bloque de contacto Empresa no se renderiza y el comparativo de los cuatro planes se muestra con normalidad
