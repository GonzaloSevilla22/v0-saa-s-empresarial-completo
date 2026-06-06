## ADDED Requirements

### Requirement: Matriz de permisos por rol dentro de una cuenta

El sistema SHALL aplicar permisos diferenciados según el rol del miembro dentro de la cuenta: `owner` acceso total, `admin` operaciones financieras sin gestión de billing, `member` solo lectura.

#### Scenario: Member no puede crear una venta
- **GIVEN** un usuario con `role = 'member'` en la cuenta A
- **WHEN** intenta hacer INSERT en `sales` con `account_id` de la cuenta A
- **THEN** la operación es rechazada por RLS (sin registrar fila)

#### Scenario: Admin puede crear una venta
- **GIVEN** un usuario con `role = 'admin'` en la cuenta A
- **WHEN** hace INSERT en `sales` con `account_id` de la cuenta A
- **THEN** la fila se registra correctamente

#### Scenario: Owner puede crear una venta
- **GIVEN** un usuario con `role = 'owner'` en la cuenta A
- **WHEN** hace INSERT en `sales` con `account_id` de la cuenta A
- **THEN** la fila se registra correctamente

#### Scenario: Member puede leer reportes
- **GIVEN** un usuario con `role = 'member'` en la cuenta A
- **WHEN** consulta `sales` con `account_id` de la cuenta A
- **THEN** ve todas las filas de la cuenta (SELECT no está bloqueado por rol)

### Requirement: Rol `admin` exclusivo del plan `pro`

El sistema SHALL impedir asignar el rol `admin` en cuentas con plan distinto de `pro`.

#### Scenario: Asignar admin en plan avanzado falla
- **GIVEN** una cuenta con `billing_plan = 'avanzado'`
- **WHEN** `rpc_change_member_role` intenta asignar `role = 'admin'` a un miembro
- **THEN** retorna `{error: 'El rol admin requiere plan pro'}`

#### Scenario: Asignar admin en plan pro funciona
- **GIVEN** una cuenta con `billing_plan = 'pro'`
- **WHEN** el `owner` llama `rpc_change_member_role` con `new_role = 'admin'`
- **THEN** retorna `{ok: true}` y el miembro queda con `role = 'admin'`

### Requirement: Cambio de rol controlado por jerarquía

El sistema SHALL permitir cambiar roles solo a miembros con autoridad suficiente: el `owner` puede cambiar cualquier rol; el `admin` solo puede promover/degradar `member`.

#### Scenario: Owner puede degradar a admin a member
- **GIVEN** el caller es `owner` de la cuenta
- **WHEN** llama `rpc_change_member_role` con `new_role = 'member'` sobre un `admin`
- **THEN** el miembro queda con `role = 'member'`

#### Scenario: Admin no puede degradar a otro admin
- **GIVEN** el caller es `admin` de la cuenta
- **WHEN** intenta `rpc_change_member_role` sobre otro `admin`
- **THEN** retorna `{error: 'Sin permisos para cambiar este rol'}`

#### Scenario: Owner no puede degradarse a sí mismo
- **GIVEN** el caller es el único `owner` de la cuenta
- **WHEN** intenta `rpc_change_member_role` sobre sí mismo con `new_role = 'member'`
- **THEN** retorna `{error: 'No se puede degradar al único owner'}`

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

El sistema SHALL restringir qué roles puede asignar el invitador: el `owner` puede invitar con cualquier rol compatible con el plan; el `admin` solo puede invitar `member`.

#### Scenario: Owner invita con rol admin (plan pro)
- **GIVEN** una cuenta con plan `pro` y el caller es `owner`
- **WHEN** crea una invitación con `role = 'admin'`
- **THEN** la invitación se crea correctamente

#### Scenario: Admin intenta invitar con rol admin
- **GIVEN** el caller es `admin`
- **WHEN** intenta crear invitación con `role = 'admin'`
- **THEN** retorna `{error: 'Solo el owner puede invitar admins'}`

### Requirement: Guard de UI bloquea operaciones de escritura para `member`

El sistema SHALL ocultar o deshabilitar en la UI los botones de creación/edición/eliminación de operaciones financieras cuando el usuario tiene `role = 'member'`.

#### Scenario: Member ve formulario de ventas en modo solo-lectura
- **GIVEN** un usuario con `role = 'member'` accede a `/ventas`
- **WHEN** la página carga
- **THEN** el botón "Nueva venta" no está visible (o está deshabilitado con tooltip explicativo)

#### Scenario: Owner ve el botón de nueva venta habilitado
- **GIVEN** un usuario con `role = 'owner'` accede a `/ventas`
- **WHEN** la página carga
- **THEN** el botón "Nueva venta" está visible y habilitado
