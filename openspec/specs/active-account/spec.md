# active-account Specification

## Purpose

Garantiza que un usuario que pertenece a varias cuentas opere, en cada request, sobre **una única cuenta activa**: la que eligió, persistida y resuelta con un solo criterio canónico en la base, el backend, las funciones de borde y el frontend (la cuenta que declara el token, si sigue siendo membresía; si no, la elegida por el usuario; si no, la membresía más antigua). Define también el selector de cuenta, que resincroniza todas las pestañas, y el rechazo con conflicto de una pantalla desfasada que declara una cuenta distinta de la activa. Introducido por `multiusuario-operativo` (2026-10-17).

## Requirements

### Requirement: Un usuario opera siempre sobre una única cuenta activa
El sistema SHALL resolver, para cada request de un usuario autenticado, **una única** cuenta activa, y toda lectura y escritura de datos de negocio de ese request SHALL operar sobre esa cuenta y sólo sobre ella.

La función de base que expone las cuentas del caller a las RPCs y a las políticas de aislamiento por fila SHALL devolver a lo sumo una fila: la cuenta activa. Un usuario que pertenece a varias cuentas NOT SHALL ver en una misma consulta datos de más de una de ellas, ni agregados que sumen más de una.

Para un usuario que pertenece a una sola cuenta, el resultado SHALL ser idéntico al anterior a este requirement.

#### Scenario: El usuario de dos cuentas sólo ve la activa
- **GIVEN** un usuario miembro de las cuentas A y B, con A como cuenta activa
- **WHEN** lista las ventas o consulta los totales del Tablero
- **THEN** ve sólo las ventas y los totales de A, nunca los de B ni la suma de ambas

#### Scenario: Una venta sin producto queda en la cuenta activa
- **GIVEN** un usuario miembro de su cuenta personal y de la cuenta del negocio, con el negocio como cuenta activa
- **WHEN** registra una venta de servicio, sin producto
- **THEN** la venta queda registrada en la cuenta del negocio

#### Scenario: El usuario de una sola cuenta no nota ningún cambio
- **GIVEN** un usuario miembro de una sola cuenta
- **WHEN** opera con un token que trae la cuenta activa, y también con uno que no la trae
- **THEN** en los dos casos opera sobre su única cuenta, igual que antes del cambio

### Requirement: La cuenta activa se elige, se persiste y se resuelve con un único criterio
El sistema SHALL persistir por usuario la cuenta que eligió como activa y SHALL resolver la cuenta activa con este único criterio, en este orden:
1. si el token del request declara una cuenta activa, esa cuenta, siempre que el usuario siga siendo miembro de ella;
2. si el token no declara ninguna, la cuenta elegida por el usuario, siempre que siga siendo miembro de ella;
3. si no eligió ninguna o la elegida dejó de ser una membresía, la membresía más antigua, desempatada por su identificador.

Si el token declara una cuenta de la que el usuario **ya no es miembro**, el sistema SHALL considerar que no hay cuenta activa y NOT SHALL operar en silencio sobre otra cuenta del usuario.

Ningún componente —base de datos, backend, funciones de borde ni frontend— SHALL implementar un criterio propio de cuenta activa: todos SHALL usar el resolver canónico. El resolver que recibe un usuario por parámetro NOT SHALL ser invocable por los roles de aplicación.

#### Scenario: La cuenta elegida gana sobre la más antigua
- **GIVEN** un usuario miembro de A (más antigua) y de B, que eligió B
- **WHEN** se emite su token y opera
- **THEN** la cuenta activa es B

#### Scenario: Una elección que dejó de ser válida cae a la más antigua
- **GIVEN** un usuario que había elegido B y fue quitado de B
- **WHEN** se emite su próximo token
- **THEN** la cuenta activa es su membresía más antigua

#### Scenario: Un token que declara una cuenta revocada no opera sobre otra
- **GIVEN** un usuario con un token vigente que declara la cuenta B, de la que fue quitado después de emitido el token
- **WHEN** hace un request con ese token
- **THEN** no hay cuenta activa: el request se rechaza como "sin cuenta activa" y no lee ni escribe en ninguna otra cuenta del usuario

#### Scenario: Elegir una cuenta ajena se rechaza sin revelar si existe
- **WHEN** un usuario intenta elegir como activa una cuenta de la que no es miembro
- **THEN** la operación se rechaza con el mismo error que una cuenta inexistente, y su cuenta activa no cambia

#### Scenario: El resolver por usuario no está expuesto
- **WHEN** un usuario autenticado intenta invocar el resolver que recibe un identificador de usuario
- **THEN** la invocación se rechaza por falta de permiso

### Requirement: La cuenta activa se cambia desde un selector y todas las pestañas se resincronizan
El sistema SHALL ofrecer, a todo usuario miembro de dos o más cuentas, un selector de cuenta activa en el encabezado del menú lateral, visible en escritorio y en el menú móvil. Para quien pertenece a una sola cuenta el selector SHALL no mostrarse.

El selector SHALL mostrar el nombre visible de cada negocio, resuelto con la misma cascada que usan los documentos comerciales, y el rol del usuario en cada uno.

Al cambiar de cuenta, el sistema SHALL persistir la elección, renovar el token para que sus claims describan la cuenta nueva, descartar los datos en caché de la cuenta anterior, llevar al usuario al Tablero y avisar del cambio a las demás pestañas abiertas, que SHALL resincronizarse de la misma manera. La señal entre pestañas NOT SHALL transportar el token.

La superficie SHALL verificarse en escritorio y en móvil, y en tema claro y oscuro, antes de considerarse completa.

#### Scenario: El selector aparece sólo con varias cuentas
- **GIVEN** un usuario miembro de una sola cuenta
- **WHEN** abre la aplicación
- **THEN** el encabezado del menú no muestra selector de cuenta

#### Scenario: Cambiar de cuenta lleva al Tablero de la cuenta nueva
- **GIVEN** un usuario miembro de A y B, operando en A
- **WHEN** elige B en el selector
- **THEN** queda en el Tablero de B, con los datos de B, y el selector muestra B como activa

#### Scenario: Otra pestaña abierta se resincroniza
- **GIVEN** dos pestañas abiertas en la cuenta A
- **WHEN** el usuario cambia a B en una de ellas
- **THEN** la otra pestaña descarta los datos de A y pasa al Tablero de B

### Requirement: Una pantalla desfasada no escribe en una cuenta distinta de la que muestra
El cliente SHALL declarar en cada request al backend la cuenta que la pantalla está mostrando. El backend SHALL rechazar con un conflicto el request que declara una cuenta distinta de la cuenta activa del token, sin ejecutar ninguna lectura ni escritura de negocio. El cliente SHALL tratar ese conflicto renovando el token, descartando los datos en caché y llevando al usuario al Tablero con un aviso.

Un request que no declara cuenta SHALL procesarse sobre la cuenta activa, sin comparación, para no romper a los clientes que todavía no la envían.

#### Scenario: Una pestaña vieja intenta registrar un gasto
- **GIVEN** una pestaña que todavía muestra la cuenta A, mientras el token ya fue renovado con la cuenta B desde otra pestaña
- **WHEN** desde la pestaña vieja se registra un gasto
- **THEN** el backend responde un conflicto, el gasto no se registra en ninguna cuenta, y la pestaña pasa al Tablero de B con un aviso

#### Scenario: Un request sin cuenta declarada se procesa normalmente
- **WHEN** un cliente que no declara cuenta hace un request válido
- **THEN** el request opera sobre la cuenta activa del token

