## ADDED Requirements

### Requirement: Tipos de notificación de resumen de deuda vencida

El Consumer 4 del relay SHALL despachar dos tipos de notificación nuevos —el resumen de deuda **por cobrar** vencida y el de deuda **por pagar** vencida—, cuya audiencia SHALL ser el target semántico de administración (los propietarios de la cuenta), cuya severidad SHALL ser `warning`, y cuyo `payload` SHALL llevar la cantidad de partes con deuda vencida, el importe total vencido y el día calendario argentino al que corresponde el resumen.

Ninguno de los dos tipos SHALL llevar sucursal: la cuenta corriente no referencia sucursal.

Los tipos SHALL incorporarse a la lista de eventos en alcance del helper de despacho **sin cambiar su firma**, y la campana de notificaciones SHALL renderizarlos con un rótulo legible en lugar del identificador crudo.

Ninguno de los dos tipos SHALL incorporarse al conjunto canónico de eventos que producen asiento contable: un vencimiento no mueve dinero y no tiene contrapartida contable. El conteo de ese conjunto canónico SHALL permanecer inalterado.

#### Scenario: El relay despacha el resumen de deuda por cobrar

- **WHEN** el relay procesa un evento de resumen de deuda por cobrar vencida
- **THEN** se crea una notificación con ese tipo, severidad `warning`, los propietarios de la cuenta como audiencia, sin sucursal, y un payload con la cantidad de deudores, el importe vencido y el día del resumen

#### Scenario: El relay despacha el resumen de deuda por pagar

- **WHEN** el relay procesa un evento de resumen de deuda por pagar vencida
- **THEN** se crea la notificación equivalente para el lado proveedor

#### Scenario: Los tipos previos siguen despachando igual

- **WHEN** el relay procesa cualquiera de los tipos de notificación que ya existían
- **THEN** su comportamiento no cambia, y los eventos fuera de la lista en alcance siguen siendo no-ops

#### Scenario: La campana muestra un rótulo legible

- **WHEN** una notificación de resumen de deuda vencida se muestra en la campana
- **THEN** se ve un rótulo legible en castellano y no el identificador del tipo

#### Scenario: El resumen no produce asiento contable

- **WHEN** el relay procesa un evento de resumen de deuda vencida
- **THEN** no se crea ningún asiento contable
- **AND** el conjunto canónico de tipos de evento que producen asiento sigue teniendo la misma cantidad de elementos que antes de este cambio

### Requirement: Deduplicación diaria del resumen de deuda vencida

El sistema SHALL emitir a lo sumo **un** resumen de deuda vencida por cuenta, por lado del circuito y por **día calendario argentino**, de modo que un barrido que vuelva a ejecutarse el mismo día no produzca un segundo aviso para la misma cuenta.

La deduplicación SHALL sostenerse **aunque los importes hayan cambiado** entre dos ejecuciones del mismo día: la unidad percibida por el usuario es el día, no la cifra.

La deduplicación SHALL cubrir con un mismo mecanismo los dos canales del aviso —la notificación y el correo—, de modo que no exista un estado en el que se envíe uno y no el otro.

#### Scenario: Una segunda corrida el mismo día no duplica

- **GIVEN** una cuenta que ya recibió hoy su resumen de deuda por cobrar vencida
- **WHEN** el barrido vuelve a ejecutarse el mismo día
- **THEN** no se crea ninguna notificación ni correo adicional para esa cuenta

#### Scenario: Un importe distinto el mismo día tampoco duplica

- **GIVEN** una cuenta que ya recibió hoy su resumen y desde entonces cobró parte de la deuda vencida
- **WHEN** el barrido vuelve a ejecutarse el mismo día
- **THEN** no se crea ningún aviso adicional

#### Scenario: Al día siguiente se emite de nuevo

- **GIVEN** una cuenta que recibió su resumen ayer y sigue con deuda vencida
- **WHEN** el barrido corre al día siguiente
- **THEN** se emite un resumen nuevo

#### Scenario: Los dos lados se deduplican por separado

- **GIVEN** una cuenta con deuda vencida por cobrar y por pagar
- **WHEN** corre el barrido
- **THEN** recibe un resumen de cada lado, y cada uno se deduplica de forma independiente
