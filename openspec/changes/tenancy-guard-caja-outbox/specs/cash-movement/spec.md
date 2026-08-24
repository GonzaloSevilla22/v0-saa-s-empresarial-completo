## ADDED Requirements

### Requirement: El helper transaccional de caja rechaza una sesión de otra cuenta

El sistema SHALL rechazar todo intento de registrar un movimiento de efectivo contra una sesión de caja que no pertenezca a alguna de las cuentas de las que el usuario en curso es miembro, sin insertar ninguna fila.

El helper intra-transacción es el **punto de paso obligado** de todo movimiento de caja del sistema: lo invocan el camino del mostrador, el del formulario de venta, el de compensación por borrado y la operación manual de ajuste. Hasta ahora sólo verificaba que la sesión estuviera abierta y que la sucursal estuviera operativa, sin mirar de quién era la caja; como todos sus llamadores tienen privilegio de definidor, las políticas de seguridad a nivel de fila no intervienen. Poner la verificación acá SHALL cubrir por construcción a **todo llamador presente y futuro**, incluido cualquiera que se agregue sin acordarse del invariante.

La cuenta SHALL resolverse recorriendo la cadena de claves foráneas que va de la sesión a la caja y de la caja a la sucursal, **sin agregar parámetros**: la firma del helper SHALL permanecer intacta, para no arrastrar una eliminación y recreación de función ni el riesgo de dejar dos definiciones convivientes. Esa misma resolución ya existe en el comando público de registro manual y SHALL reutilizarse en lugar de escribirse de nuevo.

La verificación SHALL ser de **pertenencia** a la cuenta y no de rol de escritura. El comando público de registro manual exige además rol de escritura, y esa exigencia SHALL permanecer donde está: elevarla al punto de paso obligado le quitaría al miembro sin rol de escritura la posibilidad de registrar una venta en efectivo, que hoy tiene — un endurecimiento de permisos encubierto dentro de un cambio de seguridad.

El error elegido SHALL ser el mismo que el comando público ya usa para el mismo predicado, y SHALL NOT ser el código genérico de excepción de procedimiento, porque existen verificaciones de comportamiento embebidas en migraciones históricas que atrapan ese código genérico y lo vuelven a lanzar: elegirlo abortaría la reconstrucción del esquema desde cero.

#### Scenario: Registrar un movimiento en la caja de otra cuenta es rechazado

- **GIVEN** una sesión de caja abierta perteneciente a la cuenta B
- **WHEN** un usuario que sólo es miembro de la cuenta A invoca el registro de un movimiento contra esa sesión, por cualquier camino
- **THEN** la operación es rechazada y la cantidad de movimientos de la sesión de B queda sin cambios

#### Scenario: El registro por el camino propio sigue funcionando

- **GIVEN** una sesión de caja abierta de la propia cuenta, con saldo de apertura conocido
- **WHEN** se registra un movimiento de venta
- **THEN** la fila se inserta con el saldo posterior calculado como saldo previo más importe, igual que antes del cambio

#### Scenario: La verificación no cambia la firma del helper

- **WHEN** se inspeccionan las funciones de registro de movimiento de caja tras la migración
- **THEN** existe exactamente una definición viva de cada una, con la misma lista de parámetros que antes del cambio

#### Scenario: Un miembro sin rol de escritura sigue pudiendo vender en efectivo

- **GIVEN** un usuario que es miembro de la cuenta pero no tiene rol de escritura
- **WHEN** registra una venta en efectivo por el camino del formulario contra una sesión abierta de su propia cuenta
- **THEN** el movimiento se registra, porque la verificación del punto de paso obligado es de pertenencia y no de rol

#### Scenario: La compensación por borrado sigue funcionando

- **GIVEN** una venta de la propia cuenta que registró un ingreso de caja y una sesión abierta en esa misma caja
- **WHEN** se borra la venta
- **THEN** el contra-movimiento se registra normalmente, porque la caja se deriva de la operación que ya fue verificada

#### Scenario: El saldo posterior sigue calculándose por suma de importes y no por máximo

- **GIVEN** una sesión con saldo de apertura conocido
- **WHEN** se registran, en orden, un ingreso, un egreso menor y otro ingreso
- **THEN** el saldo posterior de cada movimiento refleja la suma acumulada de los importes y no el máximo histórico alcanzado
