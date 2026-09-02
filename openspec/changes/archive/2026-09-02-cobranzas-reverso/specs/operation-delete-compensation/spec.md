## ADDED Requirements

### Requirement: La anulación de un cobro o de un pago se incorpora al contrato transversal de compensación de libros

El contrato transversal de compensación SHALL alcanzar también a la anulación de un cobro de cuenta corriente y de un pago a proveedor, que SHALL seguir las mismas reglas que ya rigen para el borrado de una venta, de una compra y de un gasto:

1. **Atomicidad**: todas las compensaciones y el borrado del documento ocurren en una sola transacción, o ninguna ocurre.
2. **Orden**: primero se compensan los libros, después se borra el documento. Nunca al revés.
3. **Disparo por existencia**: cada pata se dispara si existe el movimiento correspondiente, evaluado con un predicado distinto de cero, y **nunca** por un signo esperado ni por una etiqueta declarada en el documento.
4. **Append-only**: ningún movimiento original se modifica ni se borra; la compensación se expresa siempre como un movimiento nuevo de tipo propio.
5. **Sesiones cerradas intocables**: el contra-movimiento de caja va a la sesión abierta actual de la misma caja, y su ausencia bloquea la operación entera con `P0426`.

La anulación de un pago SHALL ser el primer documento del sistema cuya compensación incluye el **libro diario** en el mismo cambio que la introduce, en lugar de diferirla: sus ramas contables ya existen y están vivas.

#### Scenario: Atomicidad de la anulación

- **WHEN** falla cualquier compensación durante la anulación de un cobro
- **THEN** ningún libro queda modificado y el documento del cobro sigue existiendo

#### Scenario: El documento se borra después de compensar

- **WHEN** se anula un cobro que movió cuenta corriente, caja y banco
- **THEN** los tres contra-movimientos existen y el documento del cobro ya no
- **AND** el orden es observable: ninguna compensación pudo fallar por ausencia del documento

#### Scenario: Los movimientos originales sobreviven a la anulación

- **WHEN** se anula un cobro
- **THEN** su movimiento de cuenta corriente, su movimiento de caja y su movimiento bancario originales siguen existiendo sin modificarse
- **AND** cada uno tiene su contra-movimiento propio junto a él

### Requirement: El diálogo de anulación enumera las compensaciones que aplican y respeta el sentido del movimiento

La interfaz SHALL enumerar, antes de confirmar una anulación, únicamente las compensaciones que ese pago va a producir, y SHALL NOT enumerar patas que no apliquen. La redacción del efecto sobre la caja SHALL respetar el sentido real del movimiento: anular un cobro **saca** dinero del cajón, anular un pago a proveedor lo **repone**.

Cuando la anulación está bloqueada, el control SHALL aparecer deshabilitado con el motivo visible, derivado del servidor.

#### Scenario: Anulación de un cobro bancario

- **WHEN** se pide anular un cobro por transferencia con asiento posteado
- **THEN** el diálogo enumera la reposición de la deuda del cliente, el movimiento bancario inverso y la reversión del asiento
- **AND** no menciona la caja

#### Scenario: Anulación de un cobro en efectivo

- **WHEN** se pide anular un cobro en efectivo
- **THEN** el diálogo dice que se registrará la **salida** correspondiente en la caja abierta actual
- **AND** no dice "ingreso", que sería mentir sobre el arqueo

#### Scenario: Anulación de un pago a proveedor en efectivo

- **WHEN** se pide anular un pago a proveedor en efectivo
- **THEN** el diálogo dice que se registrará el **ingreso** correspondiente en la caja abierta actual

#### Scenario: Anulación bloqueada por caja cerrada

- **GIVEN** un cobro con movimiento de caja y ninguna sesión abierta en esa caja
- **WHEN** se muestra su fila en el historial de cuenta corriente
- **THEN** el control de anulación aparece deshabilitado, con el motivo indicando que hay que abrir la caja
- **AND** el usuario no descubre el bloqueo recién al recibir el error del servidor
