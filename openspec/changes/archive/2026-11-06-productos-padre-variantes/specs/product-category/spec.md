## MODIFIED Requirements

### Requirement: La variante hereda la categoría de su producto padre

El sistema SHALL asignar a un producto variante la misma categoría que su producto padre, resolviéndola en el servidor a partir del padre y no del payload del cliente. El formulario NO SHALL pedir la categoría cuando se está creando o editando una variante: SHALL mostrarla como sólo lectura, tomada del padre. Una edición de variante que informe una categoría SHALL ignorarla sin validarla ni escribirla. El producto padre `variant_only` SHALL crearse con su categoría (es uno de los tres datos que pide el formulario del padre, junto con el nombre y la unidad de la familia).

#### Scenario: Alta de variante hereda la categoría

- **GIVEN** un producto padre imputado a "Indumentaria"
- **WHEN** se crea una variante de ese padre
- **THEN** la variante queda con el mismo `category_id` que el padre, sin que se le haya pedido categoría al usuario

#### Scenario: La variante no puede contradecir al padre

- **WHEN** una solicitud crea una variante informando una categoría distinta a la del padre
- **THEN** el sistema aplica la categoría del padre

#### Scenario: La edición de una variante no cambia su categoría

- **GIVEN** una variante de un padre imputado a "Indumentaria"
- **WHEN** una edición de la variante informa otra categoría
- **THEN** la variante conserva "Indumentaria" y el formulario la muestra como sólo lectura

#### Scenario: El padre se crea con categoría

- **WHEN** se crea un producto con variantes eligiendo la categoría "Bebidas"
- **THEN** el padre queda imputado a "Bebidas" y su primera variante la hereda
