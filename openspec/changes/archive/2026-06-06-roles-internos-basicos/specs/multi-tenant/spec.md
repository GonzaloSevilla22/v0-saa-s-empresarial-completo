## MODIFIED Requirements

### Requirement: Modelo de cuenta y membresía

El sistema SHALL representar una cuenta (`accounts`) que puede ser compartida por múltiples usuarios a través de una tabla de membresía (`account_members`), donde cada miembro tiene un rol (`owner`, `admin` o `member`). El rol `admin` está disponible únicamente en cuentas con `billing_plan = 'pro'`.

#### Scenario: Una cuenta tiene un owner
- **WHEN** se crea una `account`
- **THEN** existe exactamente un `account_members` con `role = 'owner'` para esa cuenta

#### Scenario: Un usuario pertenece a una cuenta
- **GIVEN** un usuario miembro de una cuenta
- **WHEN** se consulta `current_account_ids()` para ese usuario
- **THEN** el resultado incluye el `account_id` de su cuenta

#### Scenario: Los valores de rol permitidos son owner, admin y member
- **GIVEN** se intenta insertar un `account_members` con `role = 'superuser'`
- **WHEN** se ejecuta el INSERT
- **THEN** la DB rechaza la fila por violación del CHECK constraint
