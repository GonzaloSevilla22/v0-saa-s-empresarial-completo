## ADDED Requirements

### Requirement: El proveedor es un maestro con identidad fiscal compartida

El sistema SHALL persistir el proveedor en `public.suppliers` con `id`, `account_id` (tenancy, FK→`accounts`), `name` obligatorio, y los atributos de identidad fiscal y contacto `tax_id`, `iva_condition`, `legal_name`, `email`, `phone`, todos nullable. Los atributos de identidad fiscal SHALL usar los **mismos nombres de columna, los mismos tipos y el mismo vocabulario cerrado de condición IVA** que `public.clients`, porque `FiscalIdentity` es un Value Object compartido entre Customer y Supplier (RN-96, DEC-18) y una divergencia de nombres impediría extraerlo a una tabla común. La validación de CUIT SHALL reutilizar la del cliente, sin una segunda implementación.

#### Scenario: Alta de un proveedor con identidad fiscal

- **WHEN** se crea un proveedor con nombre, CUIT, razón social y condición IVA `responsable_inscripto`
- **THEN** la fila queda persistida con esos valores y `account_id` = la cuenta del usuario

#### Scenario: Alta de un proveedor solo con nombre

- **WHEN** se crea un proveedor informando únicamente el nombre
- **THEN** la fila se persiste y todos los atributos fiscales y de contacto quedan en `NULL`

#### Scenario: Condición IVA fuera del vocabulario es rechazada

- **WHEN** se intenta persistir un proveedor con una condición IVA que no pertenece al conjunto `{responsable_inscripto, monotributista, exento, consumidor_final}`
- **THEN** la operación es rechazada y no se crea el proveedor

#### Scenario: El vocabulario fiscal es el mismo que el del cliente

- **WHEN** se comparan las columnas de identidad fiscal de `suppliers` con las de `clients`
- **THEN** coinciden en nombre, tipo y conjunto de valores admitidos para la condición IVA

### Requirement: Aislamiento por cuenta de los proveedores

El sistema SHALL aislar los proveedores por cuenta: toda lectura y toda escritura SHALL estar restringida a `account_id IN (SELECT public.current_account_ids())` por RLS, y ningún camino de la aplicación SHALL devolver ni permitir modificar un proveedor de otra cuenta.

#### Scenario: Un usuario no ve proveedores de otra cuenta

- **GIVEN** dos cuentas con proveedores propios
- **WHEN** un usuario de la cuenta A lista proveedores
- **THEN** solo obtiene los proveedores cuyo `account_id` es el de la cuenta A

#### Scenario: No se puede editar un proveedor ajeno

- **WHEN** un usuario de la cuenta A intenta editar o borrar un proveedor de la cuenta B por su identificador
- **THEN** la operación responde 404 y no modifica ninguna fila

### Requirement: La baja de un proveedor es soft delete

El sistema SHALL borrar proveedores mediante soft delete (`deleted_at` + `deleted_by`), nunca con `DELETE` físico, aplicando la política única de maestros (RN-B1/RN-B2) a través del mismo helper centralizado que usan los demás maestros. Un proveedor borrado SHALL desaparecer de todas las lecturas por defecto, y las compras que lo referencian SHALL seguir siendo legibles.

#### Scenario: Borrar un proveedor lo saca de las lecturas

- **GIVEN** un proveedor existente
- **WHEN** se lo borra
- **THEN** la fila persiste con `deleted_at` y `deleted_by` seteados, y deja de aparecer en el listado y en el selector

#### Scenario: Las compras del proveedor borrado siguen siendo legibles

- **GIVEN** compras imputadas a un proveedor
- **WHEN** el proveedor se borra
- **THEN** las compras conservan su `supplier_id` y el nombre del proveedor sigue siendo resoluble para su lectura

#### Scenario: Borrar dos veces responde 404 sin modificar filas

- **WHEN** se borra un proveedor ya borrado
- **THEN** la operación responde 404 —el proveedor borrado ya no es visible para las lecturas— y no modifica ninguna fila: `deleted_at` y `deleted_by` conservan los valores del primer borrado. Es el mismo comportamiento que el borrado de un cliente

### Requirement: El límite de proveedores del plan tiene una sola definición

El sistema SHALL enforcear el límite de proveedores del plan efectivo en la **creación**, mediante el guard de base de datos que ya observa todos los inserts de la tabla, y NO SHALL duplicar el conteo del límite en la capa de servicio. El error del guard SHALL traducirse a una respuesta **403** con un mensaje que nombre el plan, el límite y la acción que destraba (borrar proveedores o subir de plan), en lugar de degradar a un error genérico de servidor.

#### Scenario: Alcanzar el límite del plan rechaza la creación

- **GIVEN** una cuenta con plan efectivo `gratis` (límite de 20 proveedores) que ya tiene 20 proveedores vivos
- **WHEN** intenta crear un proveedor más
- **THEN** la operación falla con 403 y el mensaje nombra el plan y el límite

#### Scenario: Un proveedor borrado libera cupo

- **GIVEN** una cuenta en el límite de su plan
- **WHEN** borra un proveedor y crea otro
- **THEN** la creación es aceptada, porque el conteo excluye los proveedores con `deleted_at`

#### Scenario: La superficie anticipa el límite sin ser la que lo enforcea

- **GIVEN** una cuenta que alcanzó el límite de proveedores de su plan
- **WHEN** el usuario abre el listado de proveedores
- **THEN** la acción de alta aparece deshabilitada con el motivo visible, y el enforcement real sigue ocurriendo en el servidor

### Requirement: API REST de proveedores

El sistema SHALL exponer el ABM de proveedores como endpoints REST del backend Python, con arquitectura de tres capas (router → service → repository), validación Pydantic v2 en el borde, guard de rol en el service y JWT-passthrough hacia la base (la RLS por cuenta permanece activa). El listado SHALL devolver los proveedores vivos de la cuenta ordenados por nombre.

#### Scenario: Listar proveedores

- **WHEN** un usuario autenticado consulta el listado de proveedores
- **THEN** recibe los proveedores vivos de su cuenta ordenados por nombre

#### Scenario: Crear, editar y borrar requieren rol de escritura

- **WHEN** un usuario sin rol de escritura intenta crear, editar o borrar un proveedor
- **THEN** la operación es rechazada por el guard de rol antes de llegar a la base

#### Scenario: Un proveedor inexistente responde 404

- **WHEN** se consulta, edita o borra un proveedor que no existe en la cuenta
- **THEN** la respuesta es 404 con el formato de error estándar de la plataforma

### Requirement: Pantalla de proveedores con acceso a su cuenta corriente

El sistema SHALL exponer una pantalla de proveedores en la ruta `/proveedores`, alcanzable desde una entrada propia del menú lateral en el grupo de maestros (junto a Clientes), que permita listar, buscar, crear, editar y dar de baja proveedores, y navegar desde cada fila a la cuenta corriente del proveedor. La pantalla de cuenta corriente del proveedor —que ya existe— SHALL dejar de ser inalcanzable y su navegación de retorno SHALL apuntar al listado de proveedores.

#### Scenario: Llegar a proveedores desde el menú

- **WHEN** el usuario abre el menú lateral
- **THEN** existe una entrada "Proveedores" en el grupo de maestros que lleva a `/proveedores`

#### Scenario: Llegar a la cuenta corriente desde el listado

- **GIVEN** un proveedor en el listado
- **WHEN** el usuario elige la acción de cuenta corriente de esa fila
- **THEN** navega a la cuenta corriente de ese proveedor, con su saldo, su historial y la acción de registrar pago

#### Scenario: Volver desde la cuenta corriente

- **WHEN** el usuario usa la navegación de retorno desde la cuenta corriente de un proveedor
- **THEN** vuelve al listado de proveedores

#### Scenario: La pantalla funciona en desktop y en mobile, en tema claro y oscuro

- **WHEN** se abre el listado de proveedores en viewport de escritorio y en viewport móvil, con tema claro y con tema oscuro
- **THEN** el contenido es legible y operable en las cuatro combinaciones, usando los tokens semánticos del sistema de diseño

### Requirement: Selector de proveedor con alta inline en el formulario de compra

El sistema SHALL ofrecer en el formulario de compra un selector de proveedor buscable, con la posibilidad de **crear un proveedor sin salir del formulario** y que el proveedor recién creado quede seleccionado. El selector SHALL estar disponible tanto en el alta como en la edición de la operación, y su valor SHALL viajar al servidor como atributo de la operación.

#### Scenario: Elegir un proveedor al cargar una compra

- **WHEN** el usuario selecciona un proveedor y confirma la compra
- **THEN** todas las líneas de la operación quedan imputadas a ese proveedor

#### Scenario: Crear un proveedor sin salir del formulario

- **WHEN** el usuario elige crear un proveedor desde el formulario de compra y le da un nombre
- **THEN** el proveedor queda creado y seleccionado en el formulario, sin perder los ítems ya cargados

#### Scenario: Compra sin proveedor

- **WHEN** el usuario confirma una compra sin elegir proveedor y sin imputar una forma de pago de cuenta corriente
- **THEN** la compra se registra con proveedor no informado

#### Scenario: El listado de compras muestra el proveedor imputado

- **GIVEN** una compra imputada a un proveedor
- **WHEN** el usuario consulta el listado de operaciones de compra
- **THEN** la fila de esa operación identifica al proveedor, y las operaciones sin proveedor se muestran como tales
