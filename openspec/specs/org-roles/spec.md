# org-roles — Spec

> Capability: **org-roles** — roles internos dentro de una cuenta multi-usuario: catálogo cerrado de ocho roles (`owner`, `admin`, `seller`, `cashier`, `stock`, `purchases`, `accountant`, `viewer`), disponible en todos los planes. Diferenciación de permisos de escritura en RLS (grueso, escritor/no-escritor) y en la capa de aplicación (fino, por capacidad de dominio) y en UI.

## Purpose

Dentro de una cuenta compartida (C-05), no todos los miembros tienen los mismos derechos operativos. C-06 introdujo el rol `admin`; `v3-rbac-multirole` (2026-09-12) reemplazó el rol único por un conjunto de roles por membresía (capability `account-membership-roles`) y retiró la exclusividad de `admin` al plan `pro` — el gating comercial del trabajo en equipo pasa a ser únicamente por cantidad de usuarios. La capa de aislamiento de fila distingue escritor/no-escritor; la separación fina entre dominios (`cashier` no configura, `stock` no confirma compras) la hace cumplir el backend.

## Requirements

### Requirement: Matriz de permisos por rol dentro de una cuenta

El sistema SHALL aplicar permisos diferenciados según el **conjunto de roles activos** de la membresía dentro de la cuenta, NOT según un rol único.

La capa de aislamiento a nivel de fila SHALL distinguir escritura de solo lectura: un miembro cuyo conjunto de roles activos incluya al menos un rol que conceda escritura SHALL poder escribir los datos de negocio de su cuenta; un miembro cuyos roles activos no concedan ninguno SHALL quedar limitado a lectura. La condición de escritura SHALL derivarse del catálogo de roles, NOT de una lista de roles fijada dentro de la función que la evalúa.

La separación **fina** entre dominios —que un cajero no altere el catálogo de productos, que el encargado de depósito no confirme compras— SHALL hacerse cumplir en la capa de aplicación mediante guards por capacidad. Esta asimetría es deliberada y SHALL documentarse: la capa de fila actúa como red que separa escritura de lectura, y la capa de aplicación como control fino por dominio.

La lectura NOT SHALL restringirse por rol: todo miembro de la cuenta ve los datos de su cuenta.

#### Scenario: Un miembro solo-lectura no puede crear una venta
- **GIVEN** un miembro cuyo único rol activo es el de observador
- **WHEN** intenta registrar una venta en su cuenta
- **THEN** la operación es rechazada por la capa de aislamiento, sin registrar fila

#### Scenario: Un miembro con rol de venta puede crear una venta
- **GIVEN** un miembro cuyo conjunto de roles activos incluye el de vendedor
- **WHEN** registra una venta en su cuenta
- **THEN** la venta queda registrada

#### Scenario: Un rol vencido no concede escritura
- **GIVEN** un miembro cuyo único rol que concedía escritura ya venció
- **WHEN** intenta registrar una venta
- **THEN** la operación es rechazada

#### Scenario: Un miembro solo-lectura puede leer reportes
- **GIVEN** un miembro cuyo único rol activo es el de observador
- **WHEN** consulta las ventas de su cuenta
- **THEN** ve todas las filas de la cuenta

#### Scenario: La separación fina la aplica la capa de aplicación
- **GIVEN** un miembro cuyo único rol activo es el de cajero
- **WHEN** intenta dar de alta un producto a través de la aplicación
- **THEN** la operación es rechazada por el guard de capacidad correspondiente

#### Scenario: Incorporar un rol nuevo no obliga a reescribir la evaluación de escritura
- **WHEN** se incorpora un rol al catálogo declarándolo como rol que concede escritura
- **THEN** los miembros que lo tengan asignado pueden escribir, sin modificar la función que la capa de aislamiento evalúa

### Requirement: Cambio de rol controlado por jerarquía

El sistema SHALL permitir asignar y revocar roles sólo a quien tenga autoridad suficiente dentro de la cuenta: quien ostenta el rol de propietario puede asignar y revocar cualquier rol; quien ostenta el de administrador puede asignar y revocar los roles operativos, y NOT SHALL poder otorgar ni retirar los roles de propietario y administrador.

La operación SHALL preservar la garantía de que la cuenta conserva al menos un propietario activo.

#### Scenario: El propietario asigna un rol operativo
- **GIVEN** el actor tiene el rol de propietario en la cuenta
- **WHEN** asigna el rol de cajero a otro miembro
- **THEN** la asignación queda registrada

#### Scenario: El administrador no puede otorgar el rol de administrador
- **GIVEN** el actor tiene el rol de administrador
- **WHEN** intenta asignar el rol de administrador a otro miembro
- **THEN** la operación es rechazada

#### Scenario: No se puede dejar la cuenta sin propietario
- **GIVEN** el actor es el único miembro con el rol de propietario activo
- **WHEN** intenta revocarse ese rol a sí mismo
- **THEN** la operación es rechazada y conserva el rol

### Requirement: Expulsión de miembro con autoridad suficiente

El sistema SHALL permitir expulsar miembros de la cuenta a quienes tengan permisos: `owner` puede expulsar a cualquiera; `admin` puede expulsar solo a `member`.

#### Scenario: Owner expulsa a un admin
- **GIVEN** el caller es `owner`
- **WHEN** llama `rpc_remove_member` sobre un `admin`
- **THEN** la fila de `account_members` se elimina

#### Scenario: Admin expulsa a un member
- **GIVEN** el caller es `admin`
- **WHEN** llama `rpc_remove_member` sobre un `member`
- **THEN** la fila de `account_members` se elimina

#### Scenario: Admin no puede expulsar a otro admin
- **GIVEN** el caller es `admin`
- **WHEN** llama `rpc_remove_member` sobre otro `admin`
- **THEN** retorna `{error: 'Sin permisos para expulsar este miembro'}`

#### Scenario: No se puede expulsar al owner
- **GIVEN** cualquier caller
- **WHEN** intenta `rpc_remove_member` sobre el `owner`
- **THEN** retorna `{error: 'No se puede expulsar al owner'}`

### Requirement: Invitación diferenciada por rol que puede invitar

El sistema SHALL restringir qué roles puede declarar el invitador en una invitación: quien ostenta el rol de propietario puede invitar con cualquier conjunto de roles del catálogo; quien ostenta el de administrador puede invitar con roles operativos, y NOT SHALL poder invitar con los roles de propietario ni de administrador.

Los roles que un invitador puede declarar NOT SHALL depender del plan contratado por la cuenta.

#### Scenario: El propietario invita con un conjunto de roles operativos
- **GIVEN** el actor tiene el rol de propietario
- **WHEN** crea una invitación declarando los roles de vendedor y cajero
- **THEN** la invitación se crea con ambos roles

#### Scenario: El administrador no puede invitar con rol de administrador
- **GIVEN** el actor tiene el rol de administrador
- **WHEN** intenta crear una invitación declarando el rol de administrador
- **THEN** la operación es rechazada

#### Scenario: El plan no limita qué roles se pueden declarar
- **GIVEN** una cuenta en el plan de menor precio, con cupo de usuarios disponible
- **WHEN** el propietario crea una invitación declarando un rol operativo
- **THEN** la invitación se crea, sin que el plan lo impida

### Requirement: Guard de UI bloquea operaciones de escritura para `member`

El sistema SHALL ocultar o deshabilitar en la interfaz los controles de creación, edición y eliminación de operaciones financieras cuando el conjunto de roles activos del usuario no concede escritura.

Ese guard de interfaz SHALL conservar su comportamiento **permisivo ante la incertidumbre**: únicamente un estado de solo-lectura **confirmado** SHALL ocultar los controles. Cualquier estado indeterminado —roles todavía no hidratados, error transitorio al resolverlos, o un valor heredado proveniente de una sesión o de una caché anterior al cambio de modelo— SHALL tratarse como escritor, para NOT bloquear falsamente a un propietario legítimo. La barrera real de permisos SHALL seguir siendo la base y el guard de la aplicación; el guard de interfaz es informativo.

#### Scenario: Un miembro solo-lectura ve la pantalla de ventas sin el control de alta
- **GIVEN** un usuario cuyo conjunto de roles activos no concede escritura
- **WHEN** carga la pantalla de ventas
- **THEN** el control de nueva venta no está disponible y se muestra el aviso de solo lectura

#### Scenario: Un propietario ve el control de alta habilitado
- **GIVEN** un usuario con el rol de propietario
- **WHEN** carga la pantalla de ventas
- **THEN** el control de nueva venta está visible y habilitado

#### Scenario: Un estado indeterminado no bloquea al propietario
- **GIVEN** un usuario cuyo conjunto de roles todavía no pudo resolverse
- **WHEN** carga la pantalla de ventas
- **THEN** el control de nueva venta está disponible, y es la base quien rechazaría la escritura si no correspondiera

#### Scenario: Un valor heredado de una sesión anterior no bloquea al propietario
- **GIVEN** un usuario cuya interfaz todavía recibe el valor de rol en el vocabulario anterior al cambio de modelo
- **WHEN** carga la pantalla de ventas
- **THEN** el guard de interfaz lo interpreta con la misma semántica que antes y no lo bloquea indebidamente
