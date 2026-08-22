## ADDED Requirements

### Requirement: Ajuste manual con motivo obligatorio en el libro de caja
El sistema SHALL permitir registrar en el libro de caja un movimiento de ajuste manual (`movement_type = 'adjustment'`) con importe signado —positivo para sobrante, negativo para faltante— y **motivo obligatorio no vacío**, destinado a consolidar el saldo del sistema contra el efectivo real. El motivo SHALL persistirse junto al movimiento y SHALL ser exigido por un CHECK a nivel de base de datos, de modo que ningún camino de escritura pueda registrar un ajuste sin él.

#### Scenario: Registrar un sobrante de caja
- **GIVEN** una sesión de caja `open` con saldo corriente `8000`
- **WHEN** un usuario con permiso registra un ajuste de `+500` con motivo `"sobrante detectado en el conteo del mediodía"`
- **THEN** se inserta un `cash_movement` de tipo `adjustment` con `balance_after = 8500` y el motivo persistido

#### Scenario: Registrar un faltante de caja
- **GIVEN** una sesión de caja `open` con saldo corriente `8000`
- **WHEN** un usuario con permiso registra un ajuste de `-300` con motivo `"faltante por vuelto mal dado"`
- **THEN** se inserta un `cash_movement` de tipo `adjustment` con `balance_after = 7700` y el motivo persistido

#### Scenario: Ajuste de caja sin motivo es rechazado por la base de datos
- **WHEN** se intenta insertar un `cash_movement` de tipo `adjustment` con motivo nulo o en blanco, por cualquier camino
- **THEN** la inserción falla por violación del CHECK y no queda ninguna fila

#### Scenario: Un usuario sin permiso de escritura no puede ajustar
- **WHEN** un usuario de sólo lectura intenta registrar un ajuste de caja
- **THEN** la operación es rechazada con `P0401` y no se inserta ninguna fila

### Requirement: Ajuste manual con motivo obligatorio en el libro bancario
El sistema SHALL exigir un motivo no vacío al registrar un movimiento bancario de tipo `manual_adjustment`, rechazando con un error de dominio propio la carga manual que no lo provea, y SHALL replicar la exigencia con un CHECK a nivel de tabla para que ningún escritor futuro la evada. Los demás tipos de carga manual conservan el motivo como opcional.

#### Scenario: Registrar un ajuste bancario con motivo
- **WHEN** un usuario con permiso registra un movimiento `manual_adjustment` de `-1200` con motivo `"diferencia contra extracto de agosto"` sobre una cuenta activa
- **THEN** el movimiento se registra con su `balance_after` y el motivo persistido

#### Scenario: Ajuste bancario sin motivo es rechazado
- **WHEN** un usuario con permiso llama a la carga manual con `movement_type = 'manual_adjustment'` y motivo nulo o en blanco
- **THEN** la operación es rechazada con un error de dominio propio y no se inserta ninguna fila

#### Scenario: Los otros tipos manuales no exigen motivo
- **WHEN** un usuario con permiso registra un `transfer_in` sin motivo
- **THEN** el movimiento se registra normalmente (la exigencia aplica sólo a `manual_adjustment`)

### Requirement: Los ajustes son append-only y se corrigen con otro ajuste
El sistema SHALL tratar los movimientos de ajuste como filas append-only igual que el resto de cada libro: no SHALL existir camino de UPDATE ni de DELETE sobre un ajuste registrado. Un ajuste equivocado SHALL corregirse registrando otro ajuste de signo contrario, quedando ambos visibles en el historial con su motivo.

#### Scenario: Corregir un ajuste equivocado
- **GIVEN** un ajuste de `+500` ya registrado por error
- **WHEN** el usuario quiere deshacerlo
- **THEN** el sistema no ofrece borrarlo ni editarlo, y la corrección se hace con un ajuste de `-500` con su propio motivo, quedando los dos en el historial

#### Scenario: No hay endpoint de modificación de ajustes
- **WHEN** se inspecciona la superficie de la API de ambos libros
- **THEN** no existe endpoint de UPDATE ni de DELETE de movimientos de ajuste

### Requirement: El ajuste de caja no encubre la diferencia de arqueo
El sistema SHALL conservar la señal antifraude del arqueo (RN-95) frente a los ajustes manuales: el cierre de sesión SHALL materializar el total de los ajustes de la sesión y SHALL exponer, junto a la diferencia de arqueo, la diferencia que habría resultado **sin** los ajustes. La interfaz SHALL mostrar ambas cifras siempre que la sesión tenga al menos un ajuste, de modo que un ajuste que lleva la diferencia a cero quede evidenciado en vez de pasar inadvertido.

#### Scenario: Un ajuste que lleva la diferencia a cero queda evidenciado
- **GIVEN** una sesión cuyo esperado sin ajustes es `900` y cuyo efectivo contado es `1000`
- **WHEN** el usuario registra un ajuste de `+100` y luego cierra la sesión declarando `1000`
- **THEN** la sesión queda con `difference = 0`, con el total de ajustes `+100` persistido, y la interfaz muestra que sin ajustes la diferencia habría sido `+100`

#### Scenario: Sesión sin ajustes se comporta como antes
- **GIVEN** una sesión sin ningún movimiento de ajuste
- **WHEN** el usuario la cierra
- **THEN** el total de ajustes es `0`, la diferencia conserva su cálculo actual y la interfaz no agrega ninguna cifra adicional

#### Scenario: Los ajustes se distinguen en el historial
- **WHEN** el usuario mira el historial de una sesión que contiene ajustes
- **THEN** los ajustes aparecen con badge y etiqueta propios, con su motivo visible, distinguibles de retiros y de egresos operativos

### Requirement: El ajuste declara al usuario que es irreversible y queda registrado
El sistema SHALL advertir en la superficie de registro del ajuste, antes de confirmar, que el movimiento es irreversible, que queda asentado con su motivo y su autor, y que se corrige registrando otro ajuste. La superficie SHALL pedir el importe en valor absoluto junto con una elección explícita de sobrante o faltante, en lugar de exigir que el usuario escriba el signo.

#### Scenario: El usuario elige sobrante o faltante
- **WHEN** el usuario abre el diálogo de ajuste
- **THEN** elige entre "Sobrante (+)" y "Faltante (−)" e ingresa el importe en positivo, y el sistema arma el signo

#### Scenario: La advertencia es visible antes de confirmar
- **WHEN** el usuario tiene el diálogo de ajuste completo
- **THEN** ve, antes del botón de confirmación, que el ajuste es irreversible y queda registrado con motivo y autor

#### Scenario: El motivo se valida también en el cliente
- **WHEN** el usuario intenta confirmar un ajuste sin escribir el motivo
- **THEN** el formulario lo impide y señala el campo, sin que ello reemplace la validación del servidor

### Requirement: Los ajustes no postean asiento contable
El sistema NO SHALL generar asientos en el libro diario a partir de movimientos de ajuste de caja ni de banco, en coherencia con que el consumidor contable se alimenta de eventos de negocio y no de filas de ledger, y con que el plan de cuentas vigente no define cuenta de resultado para diferencias de caja o banco. El ajuste SHALL ser una corrección del libro correspondiente, y su ausencia de asiento SHALL estar documentada como decisión y no como omisión.

#### Scenario: Un ajuste de caja no produce asiento
- **WHEN** se registra un ajuste de caja
- **THEN** no se emite ningún evento contable ni se crea ningún asiento asociado a ese movimiento

#### Scenario: Un ajuste bancario no produce asiento
- **WHEN** se registra un ajuste bancario
- **THEN** no se emite ningún evento contable ni se crea ningún asiento asociado a ese movimiento
