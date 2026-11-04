# operation-member-authorization Specification

## Purpose

Define cómo se autorizan el alta, la edición y el borrado de ventas y compras en una cuenta con más de un miembro: por la pertenencia de cada producto y cada documento a la cuenta activa y por el conjunto de roles del miembro —con la base como autoridad y el backend como espejo—, nunca por quién creó la entidad. El dueño y el administrador corrigen cualquier documento de la cuenta; el resto sólo los propios; un producto o documento de otra cuenta se rechaza como inexistente. Introducido por `multiusuario-operativo` (2026-10-17).

## Requirements

### Requirement: Las operaciones de venta y compra no se autorizan por el autor de la entidad
El sistema SHALL autorizar el alta, la edición y el borrado de ventas y compras según la pertenencia de cada entidad involucrada a la cuenta activa del caller y según el conjunto de roles activos del caller en esa cuenta, y NOT SHALL usar como criterio de autorización qué usuario creó el producto, el cliente, el proveedor o el documento.

La columna de autoría SHALL seguir registrando quién creó cada fila.

#### Scenario: Un vendedor vende un producto cargado por el dueño
- **GIVEN** una cuenta con un producto creado por el dueño y un miembro con rol de vendedor
- **WHEN** el vendedor registra una venta de ese producto por el formulario de venta
- **THEN** la venta queda registrada en la cuenta, con el vendedor como autor, y el stock baja

#### Scenario: Un administrador vende un producto cargado por el dueño
- **GIVEN** una cuenta con un producto creado por el dueño y un miembro con rol de administrador
- **WHEN** el administrador registra una venta de ese producto por el formulario de venta
- **THEN** la venta queda registrada

#### Scenario: Un miembro de compras carga una compra de un producto del dueño
- **GIVEN** una cuenta con un producto creado por el dueño y un miembro con rol de compras
- **WHEN** ese miembro registra una compra del producto
- **THEN** la compra queda registrada y el stock sube

### Requirement: Cada producto y cada documento de una operación pertenece a la cuenta activa
Toda operación de alta o edición de venta o compra SHALL verificar, dentro de la misma lectura con bloqueo que toma la fila, que cada producto de sus líneas pertenece a la cuenta activa del caller. Toda edición y todo borrado SHALL verificar que cada documento afectado pertenece a la cuenta activa.

Un producto o un documento de otra cuenta SHALL rechazarse con el mismo error y el mismo texto que un identificador inexistente, de modo que la respuesta no revele que existe en otra cuenta.

La verificación SHALL ser autosuficiente en cada operación de la base: NOT SHALL depender de un chequeo posterior de la misma operación ni de una validación del backend.

#### Scenario: Un producto de otra cuenta se rechaza como inexistente
- **GIVEN** un producto de la cuenta B
- **WHEN** un miembro de la cuenta A intenta venderlo o comprarlo indicando su identificador
- **THEN** la operación se rechaza con el mismo error que un producto inexistente, sin registrar filas ni mover stock en ninguna cuenta

#### Scenario: Un producto de la cuenta no activa del propio usuario se rechaza
- **GIVEN** un usuario miembro de A y B, con A como cuenta activa, y un producto de B
- **WHEN** intenta venderlo con A activa
- **THEN** la operación se rechaza como producto inexistente

#### Scenario: Un documento de otra cuenta no se edita ni se borra
- **GIVEN** una venta de la cuenta B
- **WHEN** un miembro de la cuenta A intenta editarla o borrarla
- **THEN** la operación se rechaza como documento inexistente y la venta no cambia

### Requirement: El rol del miembro habilita cada operación, y la base es la autoridad
El sistema SHALL exigir, en la propia operación de la base y también en el backend, un rol que habilite cada operación:
- el alta de una venta por el formulario SHALL requerir un rol de venta (dueño, administrador, vendedor o cajero);
- el alta de una compra SHALL requerir un rol de compra (dueño, administrador o compras).

Un miembro sin ningún rol de escritura SHALL ser rechazado por falta de autorización. Un miembro con rol de escritura pero sin el rol del dominio SHALL ser rechazado por rol insuficiente, con un mensaje que nombre los roles requeridos.

Los conjuntos de roles SHALL declararse una sola vez por capa como capacidades con nombre, y un test SHALL fallar si la capacidad de la base y la del backend divergen.

La interfaz SHALL ocultar las acciones de alta, edición y borrado que el rol del usuario no habilita.

#### Scenario: Un observador no puede crear una venta
- **GIVEN** un miembro cuyo único rol activo es el de observador
- **WHEN** intenta registrar una venta por el formulario, por el backend o invocando directamente la operación de la base
- **THEN** la operación se rechaza por falta de autorización y no se registra ninguna fila

#### Scenario: Un cajero no puede registrar una compra
- **GIVEN** un miembro cuyo único rol activo es el de cajero
- **WHEN** intenta registrar una compra
- **THEN** la operación se rechaza por rol insuficiente

#### Scenario: Un depósito no puede registrar una venta por el formulario
- **GIVEN** un miembro cuyo único rol activo es el de depósito
- **WHEN** intenta registrar una venta por el formulario
- **THEN** la operación se rechaza por rol insuficiente

#### Scenario: La interfaz no ofrece lo que el rol no permite
- **GIVEN** un miembro cuyo único rol activo es el de observador
- **WHEN** abre la pantalla de ventas o la de compras
- **THEN** no ve las acciones de nueva venta, nueva compra, editar ni eliminar

### Requirement: Editar o borrar un documento ajeno requiere ser dueño o administrador
El sistema SHALL permitir que el dueño y el administrador de la cuenta editen y borren cualquier venta y cualquier compra de la cuenta. Un miembro con el rol del dominio pero sin rol de dueño ni de administrador SHALL poder editar y borrar sólo los documentos de los que es autor, y SHALL ser rechazado por rol insuficiente sobre los documentos de otro miembro.

La regla SHALL aplicarse en la operación de la base.

#### Scenario: El dueño corrige una venta del empleado
- **GIVEN** una venta registrada por un vendedor de la cuenta
- **WHEN** el dueño la edita
- **THEN** la edición se aplica

#### Scenario: El administrador corrige una venta del dueño
- **GIVEN** una venta registrada por el dueño
- **WHEN** un administrador la edita
- **THEN** la edición se aplica

#### Scenario: Un vendedor corrige su propia venta
- **GIVEN** una venta registrada por un vendedor
- **WHEN** ese mismo vendedor la edita
- **THEN** la edición se aplica

#### Scenario: Un vendedor no corrige la venta de otro
- **GIVEN** una venta registrada por el dueño
- **WHEN** un vendedor intenta editarla o borrarla
- **THEN** la operación se rechaza por rol insuficiente y la venta no cambia

