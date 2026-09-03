## ADDED Requirements

### Requirement: El saldo de cuenta corriente viaja en el read-model de actividad del cliente

El sistema SHALL exponer, para cada cliente del listado de actividad, el **saldo de su cuenta corriente**, resuelto dentro de la misma consulta que recupera la página de clientes y sus agregados de actividad.

El saldo SHALL obtenerse del saldo materializado de la cuenta corriente y NO SHALL calcularse sumando el ledger de movimientos, coherentemente con el invariante de la capability `customer-account`. El cliente sin cuenta corriente SHALL exponer saldo cero, no un valor ausente: "sin cuenta corriente" y "cuenta corriente en cero" describen lo mismo para quien lee la lista.

La incorporación NO SHALL emitir una consulta por cliente ni alterar la cantidad de filas de la página ni el total del envelope de paginación: la relación entre cliente y cuenta corriente es a lo sumo uno a uno.

#### Scenario: Cliente con deuda en el listado

- **GIVEN** un cliente con saldo 12000 en su cuenta corriente
- **WHEN** se solicita la página del listado de clientes con actividad que lo contiene
- **THEN** ese cliente incluye su saldo de 12000

#### Scenario: Cliente sin cuenta corriente

- **GIVEN** un cliente que nunca compró a crédito
- **WHEN** se solicita la página que lo contiene
- **THEN** ese cliente incluye saldo cero

#### Scenario: Sin consulta por cliente

- **WHEN** se solicita una página del listado con sus saldos
- **THEN** la respuesta se resuelve en una sola consulta de datos, sin una consulta adicional por cliente

#### Scenario: La paginación no cambia

- **GIVEN** una cuenta cuyo listado de clientes devolvía un total y una cantidad de filas por página determinados
- **WHEN** se solicita el mismo listado con el saldo incorporado
- **THEN** el total y la cantidad de filas por página son idénticos, y ningún cliente aparece dos veces

#### Scenario: El detalle expone el mismo saldo

- **WHEN** se consulta el resumen de actividad de un cliente individual
- **THEN** expone el mismo saldo que la fila de ese cliente en el listado

### Requirement: La lista de clientes muestra el saldo y ofrece acceso a la cuenta corriente

La lista de clientes SHALL mostrar el saldo de cuenta corriente de cada cliente y SHALL ofrecer en cada fila un acceso directo a la cuenta corriente de ese cliente, nivelando la lista de clientes con la de proveedores, que ya lo ofrece.

El acceso SHALL tener nombre accesible y NO SHALL depender únicamente de un ícono sin etiqueta. El saldo SHALL presentarse con tokens semánticos del sistema de diseño, legible en tema claro y oscuro, en escritorio y en móvil, y NO SHALL comunicarse únicamente por color.

El acceso a la cuenta corriente SHALL convivir con la activación de la fila que abre el detalle del cliente, sin que una acción dispare la otra.

#### Scenario: Saldo visible en la fila

- **GIVEN** un cliente con saldo 12000 en su cuenta corriente
- **WHEN** el usuario abre la lista de clientes
- **THEN** la fila de ese cliente muestra su saldo

#### Scenario: Acceso a la cuenta corriente

- **WHEN** el usuario usa el acceso a la cuenta corriente de una fila
- **THEN** navega a la cuenta corriente de ese cliente y no al detalle del cliente

#### Scenario: Cliente sin deuda

- **WHEN** la lista muestra un cliente con saldo cero
- **THEN** su saldo se presenta como cero y la fila sigue ofreciendo el acceso a la cuenta corriente

#### Scenario: Presentación responsive y por tema

- **WHEN** la lista se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** el saldo y el acceso a la cuenta corriente son legibles y operables en las cuatro combinaciones
