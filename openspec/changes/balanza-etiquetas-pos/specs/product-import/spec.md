## ADDED Requirements

### Requirement: La importación acepta el código de balanza como columna opcional

El importador de productos SHALL aceptar una columna opcional "Código balanza" (también reconocida con los encabezados `PLU` y `codigo balanza`) e incluirla en la plantilla descargable y en la plantilla generada desde el catálogo. El cliente SHALL validar que el valor sea un entero de 1 a 999.999 (en otro caso, error de su fila) y SHALL marcar como error de fila un mismo código de balanza repetido en dos filas del archivo. Una celda vacía SHALL viajar como **ausencia**: al actualizar un producto existente conserva su código de balanza, y al crear uno nuevo lo deja sin código. En el servidor, la unidad de trabajo de importación SHALL persistir el código de balanza con la misma regla de ausencia, y un código de balanza que ya pertenece a otro producto vivo de la cuenta SHALL rechazar el lote entero sin escritura parcial, informando el error en la fila que lo trae.

#### Scenario: Importar productos con código de balanza

- **WHEN** se importa un archivo con una fila "Tomate" con código de balanza 261
- **THEN** el producto queda con `scale_plu = 261`

#### Scenario: Celda vacía conserva el código existente

- **GIVEN** un producto de SKU `TOM-01` con código de balanza 261
- **WHEN** se importa una fila con SKU `TOM-01` y la celda de código de balanza vacía
- **THEN** el producto conserva el código de balanza 261

#### Scenario: Código repetido dentro del archivo

- **WHEN** dos filas del archivo traen el código de balanza 261
- **THEN** la vista previa marca error en la segunda fila y no se envía el lote

#### Scenario: Código que ya usa otro producto del catálogo

- **GIVEN** un producto vivo "Papa" con código de balanza 509
- **WHEN** se importa una fila de otro producto con código de balanza 509
- **THEN** el lote se rechaza sin escribir ninguna fila y el error identifica la fila y el código 509

#### Scenario: Código inválido

- **WHEN** una fila trae el código de balanza `12a` o `0`
- **THEN** la vista previa marca error en esa fila
