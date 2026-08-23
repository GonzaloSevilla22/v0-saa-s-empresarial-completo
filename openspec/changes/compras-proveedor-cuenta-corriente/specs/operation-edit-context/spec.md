## ADDED Requirements

### Requirement: El proveedor es reimputable al editar una compra mediante contrato tri-estado

La edición de una operación de compra SHALL aceptar `supplier_id` como parámetro tri-estado, con la misma mecánica ya definida para `branch_id` y `canal`, distinguiendo la intención por **ausencia o presencia** del parámetro y nunca por su valor:

- parámetro **ausente** → preservar el proveedor vigente;
- parámetro **presente con `NULL`** → desimputar explícitamente (compra sin proveedor);
- parámetro **presente con valor** → reimputar.

La distinción SHALL implementarse con un booleano `p_supplier_provided` en la RPC y con `model_fields_set` en la capa Python. NO SHALL inferirse desde `is None`.

Un proveedor reimputado SHALL validarse antes de aplicarse: SHALL pertenecer a la cuenta de la operación y NO SHALL estar borrado. Si no cumple, la edición SHALL fallar sin modificar la operación.

La reimputación del proveedor NO SHALL postear, mover ni revertir cargos de cuenta corriente: una operación que ya tiene un cargo posteado es inmutable por la capability `supplier-account`, de modo que el único caso editable es el de una compra sin cargo, donde el proveedor es una imputación analítica.

#### Scenario: reimputar el proveedor de una compra

- **GIVEN** una compra sin cargo de cuenta corriente, imputada al proveedor A
- **WHEN** se edita la operación informando el proveedor B, perteneciente a la cuenta y no borrado
- **THEN** todas las líneas de la operación quedan imputadas a B, y no se crea ni se revierte ningún movimiento de cuenta corriente

#### Scenario: omitir el proveedor preserva el vigente

- **GIVEN** una compra imputada a un proveedor
- **WHEN** se edita la operación sin incluir el campo proveedor en el payload
- **THEN** la operación conserva el mismo proveedor

#### Scenario: desimputar el proveedor explícitamente

- **WHEN** se edita una compra informando proveedor `NULL` con el indicador de "informado" en verdadero
- **THEN** la operación queda sin proveedor, y el valor previo no se restaura

#### Scenario: reimputar a un proveedor ajeno o borrado es rechazado

- **WHEN** se edita una compra informando un proveedor de otra cuenta, inexistente, o con `deleted_at` seteado
- **THEN** la edición falla y la operación queda intacta, sin reversa ni reaplicación de stock

#### Scenario: el formulario de edición expone el selector que la RPC acepta

- **WHEN** el usuario abre una compra editable en el formulario de edición
- **THEN** el selector de proveedor aparece precargado con el proveedor vigente de la operación y su cambio produce un efecto real al guardar

### Requirement: La edición no puede convertir una compra en compra a cuenta corriente

Como la edición de una compra NO postea cargos en cuenta corriente, el sistema SHALL rechazar toda edición cuyo resultado sea una compra imputada a una forma de pago de `kind = 'credit'` **sin el cargo correspondiente**. Concretamente, sobre el `kind` **efectivo** que queda tras aplicar el contrato tri-estado de forma de pago:

- si el `kind` efectivo final es `credit` y el proveedor efectivo final queda sin informar, la edición SHALL rechazarse con el **mismo código y el mismo mensaje de negocio** que usa el alta de compra a crédito sin proveedor, de modo que el mapeo de error del backend y de la superficie sea uno solo;
- si la edición **informa explícitamente** la forma de pago y con ello mueve la operación desde un `kind` distinto de `credit` (incluida la ausencia de forma de pago) **hacia** `credit`, la edición SHALL rechazarse, y el mensaje SHALL nombrar el camino de corrección: borrar la compra y volver a cargarla como compra a crédito, que es el camino que sí postea el cargo.

Ambos rechazos SHALL ocurrir **antes** de cualquier reversa, borrado o reaplicación de líneas y de stock, y SHALL usar el código de error de negocio ya existente para entrada inválida, sin acuñar uno nuevo.

Una compra que **ya** estaba imputada a `kind = 'credit'` y no tiene cargo posteado —el estado de las compras registradas antes de que este circuito existiera— SHALL seguir siendo editable: la restricción alcanza la **transición** hacia crédito, no la permanencia en él. Salir de `credit` hacia cualquier otro `kind` SHALL estar permitido cuando no hay cargo posteado; si lo hay, la operación ya es inmutable por la capability `supplier-account` y ese bloqueo SHALL tener precedencia.

#### Scenario: mover una compra a crédito desde la edición es rechazado

- **GIVEN** una compra imputada a una forma de pago de `kind = 'cash'`, con proveedor y sin cargo posteado
- **WHEN** se edita la operación informando una forma de pago de `kind = 'credit'`
- **THEN** la edición es rechazada nombrando el camino de corrección (borrar y volver a cargar), y la operación queda intacta: mismas líneas, mismo stock, misma forma de pago y ningún movimiento de cuenta corriente creado

#### Scenario: mover una compra a crédito sin proveedor también es rechazado

- **WHEN** se edita una compra informando a la vez una forma de pago de `kind = 'credit'` y proveedor `NULL`
- **THEN** la edición es rechazada y no se modifica ni la operación, ni el stock, ni la cuenta corriente de ningún proveedor

#### Scenario: desimputar el proveedor de una compra a crédito es rechazado

- **GIVEN** una compra imputada a una forma de pago de `kind = 'credit'`
- **WHEN** se edita la operación informando proveedor `NULL` con el indicador de "informado" en verdadero
- **THEN** la edición falla con el mismo error que el alta de una compra a crédito sin proveedor

#### Scenario: una compra que ya era a crédito y no tiene cargo sigue siendo editable

- **GIVEN** una compra imputada a `kind = 'credit'` sin ningún movimiento posteado en la cuenta corriente del proveedor
- **WHEN** se edita su cantidad sin tocar la forma de pago
- **THEN** la edición se aplica normalmente y no se postea ningún cargo

#### Scenario: salir de crédito está permitido cuando no hay cargo

- **GIVEN** la misma compra a crédito sin cargo posteado
- **WHEN** se edita informando una forma de pago de `kind = 'cash'`
- **THEN** la edición se aplica y no se crea ni se revierte ningún movimiento de cuenta corriente

#### Scenario: con cargo posteado, la inmutabilidad tiene precedencia

- **GIVEN** una compra a crédito con su cargo ya posteado
- **WHEN** se intenta editarla, con o sin cambio de forma de pago
- **THEN** la operación es rechazada por el conflicto de estado de operación inmutable, antes que por cualquier regla de transición
