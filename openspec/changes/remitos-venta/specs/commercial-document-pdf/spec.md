## ADDED Requirements

### Requirement: El constructor del PDF comercial admite el remito
El sistema SHALL construir el PDF del remito con el mismo constructor compartido de documentos comerciales, extendido de forma aditiva para el presupuesto, que no cambia. La vista suma dos campos opcionales:
- un **bloque de firma de recepción** con espacios para firma, aclaración, DNI y fecha, que no se parte entre páginas;
- un **rótulo de origen** con la sucursal de la que sale la mercadería.

Cuando la vista indica no mostrar precios, el PDF SHALL omitir las columnas de precio unitario y subtotal y el total, y la tabla de líneas SHALL quedar con descripción y cantidad con su unidad. La leyenda del remito SHALL ser "Remito — documento no válido como factura." Los datos del emisor SHALL resolverse igual que para el presupuesto, sin bloquear por datos faltantes.

#### Scenario: Remito sin precios
- **WHEN** se construye el PDF de un remito con la opción de no mostrar precios
- **THEN** el PDF contiene "REMITO", el número, la sucursal de origen, las cantidades con su unidad, el bloque de firma y la leyenda, y no contiene precios ni total

#### Scenario: Remito con precios
- **WHEN** se construye el mismo PDF con la opción de mostrar precios
- **THEN** el PDF incluye precio unitario, subtotal y total

#### Scenario: El presupuesto no cambia
- **WHEN** se construye el PDF de un presupuesto después de este cambio
- **THEN** no lleva bloque de firma ni rótulo de origen y su contenido es el mismo que antes

### Requirement: Endpoint del PDF del remito por id con tenencia
El sistema SHALL exponer `GET /delivery-notes/{id}/pdf` con `disposition` (`inline` o `attachment`) y `show_prices` (booleano, falso por defecto).

El endpoint SHALL devolver el PDF para cualquier estado del remito y para cualquier miembro de su cuenta. El archivo se llama `remito-R-00000012.pdf`.

Un remito de otra cuenta o inexistente SHALL responder 404 con el mismo cuerpo RFC 7807. Un parámetro inválido SHALL responder 422 y un pedido sin sesión, 401.

#### Scenario: Descarga por defecto
- **WHEN** un miembro de la cuenta pide el PDF de un remito sin `show_prices`
- **THEN** recibe 200 `application/pdf` sin precios, con el nombre de archivo del número del remito

#### Scenario: Remito de otra cuenta
- **WHEN** un usuario pide el PDF de un remito de otra cuenta
- **THEN** recibe 404 `delivery_note_not_found`, igual que para un id inexistente
