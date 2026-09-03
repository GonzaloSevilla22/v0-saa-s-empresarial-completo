## ADDED Requirements

### Requirement: Plantilla de correo para el resumen de deuda vencida

El sistema SHALL disponer de una plantilla de correo propia para el resumen de deuda vencida, que SHALL renderizar la cantidad de partes con deuda vencida, el importe total vencido y un acceso directo a la pantalla de cobranzas, dentro del mismo diseño de marca que usan las plantillas existentes.

La plantilla SHALL obtener esas cifras de los metadatos del registro de correo, de modo que el cuerpo del mensaje sea autosuficiente y no obligue a entrar a la aplicación para saber si el aviso amerita atención.

El destinatario SHALL ser el propietario de la cuenta, y el envío SHALL viajar por el mismo canal de entrega transaccional ya existente, sin introducir un camino de envío propio.

Un tipo de evento de correo desconocido SHALL seguir cayendo en el comportamiento genérico ya definido, sin romper el envío.

#### Scenario: El correo informa las cifras

- **GIVEN** un registro de correo de resumen de deuda vencida con 3 partes y 45000 de importe vencido
- **WHEN** se entrega el correo
- **THEN** el cuerpo informa las 3 partes, los 45000 y ofrece el acceso a la pantalla de cobranzas

#### Scenario: El correo usa el canal existente

- **WHEN** se produce un resumen de deuda vencida
- **THEN** el envío se resuelve por el mismo mecanismo de entrega transaccional que las demás plantillas, sin un camino propio

#### Scenario: El resumen de deuda por pagar tiene su propio texto

- **WHEN** se entrega el resumen de deuda por pagar vencida
- **THEN** el texto habla de deuda con proveedores y no de deuda de clientes

#### Scenario: Las plantillas existentes no cambian

- **WHEN** se entrega un correo de cualquiera de los tipos que ya existían
- **THEN** su asunto y su cuerpo son los mismos que antes de este cambio
