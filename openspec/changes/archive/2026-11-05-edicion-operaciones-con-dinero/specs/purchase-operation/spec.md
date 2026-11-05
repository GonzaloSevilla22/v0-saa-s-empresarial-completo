## MODIFIED Requirements

### Requirement: La superficie de compra ofrece el descuento de caja pre-marcado y explica cuándo no aplica

La interfaz de alta de compra SHALL ofrecer la afirmación del descuento de caja **pre-marcada** cuando las tres condiciones se cumplen, y SHALL mostrar el motivo concreto cuando no se cumplen, sin ocultar el bloque en silencio.

El valor inicial marcado es deliberado y SHALL alinearse con el del gasto y no con el de la venta: la venta arranca sin marcar porque su formulario se usa masivamente para carga retroactiva de administración, mientras que una compra imputada a efectivo y fechada hoy describe casi siempre plata que salió del cajón. Con la verificación de fecha ya filtrando lo retroactivo, un valor inicial sin marcar reproduciría el estado previo al cambio —la caja sigue sin ver la plata salvo que alguien se acuerde de marcarlo.

La interfaz de **edición** de compra SHALL ofrecer el mismo bloque, con el estado vigente de la operación:

- **Compra que ya descontó de una caja**: la afirmación aparece marcada, nombrando la caja. Desmarcarla saca la compra de la caja, y la edición compensa el egreso.
- **Compra sin movimiento de caja**: se ofrece con las mismas tres condiciones que el alta, y arranca sin marcar, porque la edición no debe agregar en silencio un egreso que la compra nunca tuvo.

Las reglas de cuándo la edición escribe en la caja SHALL ser las de las capabilities `operation-money-edit` y `cash-movement`.

La interfaz SHALL reutilizar la resolución de condiciones compartida que ya emplean el formulario de venta y el de gasto, en vez de reimplementarla; la autoridad sobre la decisión SHALL seguir siendo el servidor.

#### Scenario: Condiciones cumplidas

- **GIVEN** una compra en efectivo fechada hoy con una sesión de caja abierta en su sucursal
- **WHEN** el usuario ve el formulario de compra
- **THEN** la afirmación de descuento de caja aparece marcada, nombrando la sesión

#### Scenario: Condiciones no cumplidas

- **GIVEN** una compra en efectivo fechada hoy sin sesión de caja abierta en su sucursal
- **WHEN** el usuario ve el formulario de compra
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** una compra en efectivo con las tres condiciones cumplidas
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** la compra se registra sin movimiento de caja

#### Scenario: La edición muestra el estado de caja vigente

- **GIVEN** una compra en efectivo que descontó de la caja
- **WHEN** el usuario la edita
- **THEN** el bloque de caja aparece marcado nombrando la caja, y desmarcarlo anticipa en la confirmación que el egreso se va a revertir

#### Scenario: La edición de una compra sin caja no la agrega sola

- **GIVEN** una compra en efectivo de hoy sin movimiento de caja y una sesión abierta en su sucursal
- **WHEN** el usuario la edita
- **THEN** la afirmación de descuento de caja aparece disponible pero sin marcar

#### Scenario: Presentación responsive y por tema

- **WHEN** el bloque de descuento de caja se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
