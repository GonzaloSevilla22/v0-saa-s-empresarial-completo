## MODIFIED Requirements

### Requirement: account_id obtenido desde el request context en backend Python

El sistema SHALL proveer un dependency `get_account_id` en `core/deps.py` que retorna el `account_id` de la cuenta activa del request, resuelto por la misma función canónica de la base que usan las RPCs y las políticas de aislamiento por fila, a través de la conexión JWT-passthrough del request. Ningún repositorio SHALL derivar `account_id` desde JWT claims directamente, y `get_account_id` NOT SHALL implementar un criterio de cuenta activa propio.

Para que la base resuelva la misma cuenta que describen los claims del token, la conexión del request SHALL transportar a la base, junto con el sujeto y el rol de conexión, la cuenta activa que declara el token cuando éste la declara.

Si el request declara la cuenta que muestra el cliente y no coincide con la cuenta activa resuelta, `get_account_id` SHALL rechazarlo con un conflicto antes de que el endpoint ejecute ninguna lectura ni escritura.

#### Scenario: Dependency retorna account_id del tenant activo
- **WHEN** un endpoint recibe `account_id: UUID = Depends(get_account_id)` con un JWT válido de un usuario miembro de una cuenta
- **THEN** `get_account_id` consulta la función canónica de cuenta activa de la base y retorna el UUID de esa cuenta

#### Scenario: El backend y las RPCs operan sobre la misma cuenta
- **GIVEN** un usuario miembro de dos cuentas
- **WHEN** un endpoint lee con `get_account_id` y, en el mismo request, invoca una RPC que resuelve su propia cuenta
- **THEN** ambas operan sobre la misma cuenta

#### Scenario: Usuario sin cuenta activa recibe 403
- **GIVEN** un JWT válido de un usuario sin ninguna fila en `account_members`, o cuyo token declara una cuenta de la que ya no es miembro
- **WHEN** el endpoint invoca `Depends(get_account_id)`
- **THEN** se lanza `HTTPException(status_code=403)` con mensaje "No active account found"

#### Scenario: Una cuenta declarada distinta se rechaza con conflicto
- **GIVEN** un request que declara la cuenta A mientras el token describe la cuenta B
- **WHEN** el endpoint invoca `Depends(get_account_id)`
- **THEN** se responde un conflicto 409 con el formato de error estándar, sin ejecutar el endpoint
