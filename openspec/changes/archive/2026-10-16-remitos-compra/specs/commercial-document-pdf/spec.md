## ADDED Requirements

### Requirement: El constructor del PDF comercial admite el remito de compra
El sistema SHALL generar el PDF del remito de compra con el constructor compartido de documentos comerciales y la vista del remito parametrizada por sentido: título "REMITO DE COMPRA", bloque "Recibido de" con el proveedor y su número de remito si existe, la sucursal donde ingresa la mercadería, el bloque de firma de quien recibe, precios y total sólo si se piden, sello "ANULADO" si corresponde y la leyenda "Remito — documento no válido como factura". El archivo SHALL llamarse `remito-compra-RC-<número>.pdf` (con el sufijo `-con-precios` si los muestra), tanto en la respuesta del endpoint como en el nombre que pone la pantalla al descargarlo o compartirlo.

#### Scenario: PDF con precios
- **WHEN** se descarga el PDF de un remito de compra pidiendo mostrar precios
- **THEN** el PDF muestra el precio por línea y el total, y el archivo se llama `remito-compra-RC-00000012-con-precios.pdf`

#### Scenario: El presupuesto y el remito de venta no cambian
- **WHEN** se generan el PDF de un presupuesto y el de un remito de venta
- **THEN** su contenido es el mismo que antes de este cambio
