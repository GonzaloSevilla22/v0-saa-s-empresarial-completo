## ADDED Requirements

### Requirement: La transferencia entre sucursales se ofrece desde el módulo de Stock principal

El sistema SHALL ofrecer la transferencia de stock entre sucursales desde el **módulo de Stock principal**, en la ruta `/stock`, como una acción por producto del listado.

La transferencia ya existe y funciona, pero sólo se llega a ella recorriendo Sucursales → una sucursal → Stock → la fila del producto. El PO, que conoce el sistema, creyó que la función no existía; la usuaria del incidente del 22-08 desactivó una sucursal llena en vez de vaciarla, muy probablemente por lo mismo. Una función que nadie encuentra equivale a una función que no está.

La acción SHALL aparecer únicamente cuando tenga sentido: sólo si la cuenta tiene el módulo de sucursales habilitado por su plan y tiene **más de una** sucursal activa. Con una sola sucursal no hay a dónde transferir y el control sería ruido.

Al activar la acción, el sistema SHALL mostrar el **desglose por sucursal** de las existencias de ese producto, leído del ledger canónico por sucursal, para que el usuario elija el origen. La transferencia propiamente dicha SHALL **reutilizar el diálogo de transferencia existente** sin reescribirlo ni duplicar su lógica de validación.

#### Scenario: Cuenta con varias sucursales ve la acción de transferir

- **GIVEN** una cuenta con el módulo de sucursales y dos sucursales activas
- **WHEN** un miembro abre el módulo de Stock
- **THEN** cada producto del listado ofrece la acción de transferir stock

#### Scenario: Cuenta con una sola sucursal no ve la acción

- **GIVEN** una cuenta con una única sucursal activa
- **WHEN** un miembro abre el módulo de Stock
- **THEN** la acción de transferir stock no se ofrece

#### Scenario: La acción muestra el desglose por sucursal y transfiere

- **GIVEN** un producto con existencias repartidas en dos sucursales
- **WHEN** un miembro activa la acción de transferir desde el módulo de Stock
- **THEN** ve cuántas unidades hay en cada sucursal, elige el origen, y completa la transferencia con el mismo diálogo que ya se usa desde el inventario de una sucursal

#### Scenario: No se duplica el diálogo de transferencia

- **WHEN** se inspecciona la interfaz tras el cambio
- **THEN** existe un solo diálogo de transferencia de stock, consumido tanto desde el inventario de una sucursal como desde el módulo de Stock principal

---

### Requirement: El error de venta por falta de stock en la sucursal ofrece el camino a la transferencia

El sistema SHALL ofrecer, junto al aviso de error de una venta rechazada por falta de stock en la sucursal, un **camino directo** a la transferencia de stock del producto involucrado.

El aviso ya explica que puede haber unidades en otra sucursal y que conviene revisar el stock por sucursal, pero deja al usuario buscando dónde se hace eso. Ese es exactamente el momento en que la transferencia le resuelve el problema, y exactamente el momento en que hoy no la encuentra.

El texto del aviso SHALL seguir sin ocultar el error original cuando no lo reconoce, y la traducción existente SHALL extenderse en lugar de duplicarse.

#### Scenario: Venta rechazada por falta de stock en la sucursal

- **GIVEN** un producto con unidades en otra sucursal y ninguna en la sucursal de la venta
- **WHEN** el usuario intenta registrar la venta
- **THEN** el aviso explica que puede haber unidades en otra sucursal y ofrece una acción que lleva a transferir stock de ese producto

#### Scenario: Un error no reconocido se sigue mostrando tal cual

- **GIVEN** una venta que falla por un motivo que la traducción no reconoce
- **WHEN** el usuario intenta registrarla
- **THEN** el aviso muestra el mensaje original sin ocultarlo y sin ofrecer la acción de transferir
