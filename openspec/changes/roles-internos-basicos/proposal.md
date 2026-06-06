## Why

C-05 creó el modelo de cuenta compartida (`accounts` + `account_members`) con solo dos roles: `owner` y `member`. Los planes `avanzado` y `pro` prometen "roles internos" como feature diferenciadora (RN-06), pero hoy todos los miembros de una cuenta tienen los mismos permisos operativos. C-06 introduce el rol `admin` (solo `pro`) y define la matriz de permisos que diferencia qué puede hacer cada rol dentro de la cuenta.

## What Changes

- **Nuevo rol `admin` en `account_members`**: ampliar el `CHECK` de `role IN ('owner', 'member')` a `('owner', 'admin', 'member')`. El `admin` puede operar financieramente (crear ventas, compras, gastos) pero no puede cambiar el plan ni eliminar la cuenta.
- **Matriz de permisos por rol** (aplicada en RLS y en gating de UI):
  - `owner`: acceso total — operaciones financieras, cambio de plan, invitar/expulsar miembros, eliminar cuenta.
  - `admin` (solo `pro`): operaciones financieras completas; puede invitar `member`; NO puede cambiar plan, NO puede expulsar `owner`, NO puede eliminar cuenta.
  - `member` (todos los planes multi-usuario): solo lectura (dashboard, reportes); no puede crear/editar/borrar operaciones financieras.
- **Gating por plan**:
  - Plan `avanzado`: puede tener `owner` + `member`. Máximo 5 usuarios.
  - Plan `pro`: puede tener `owner` + `admin` + `member`. Máximo 10 usuarios.
  - El rol `admin` es exclusivo de `pro`; intentar asignarlo en `avanzado` retorna error.
- **Migración SQL**: actualizar el `CHECK` de `account_members.role`; función `rpc_change_member_role(account_id, target_user_id, new_role)` con validación de permisos y plan; función `rpc_remove_member(account_id, target_user_id)`.
- **RLS diferenciada**: las tablas de negocio (`sales`, `purchases`, `expenses`, `products`, etc.) agregan políticas `FOR INSERT/UPDATE/DELETE` que verifican que el miembro tenga rol `owner` o `admin` (los `member` solo leen).
- **UI `/organizacion/roles`**: listado de miembros con rol actual; botones de cambio de rol para `owner` (y `admin` para promover/degradar `member`); botón de expulsión.
- **UI `/organizacion/invitar`**: formulario email + selector de rol a asignar (con validación de cupo y plan).
- **Hook `useOrgRole()`**: expone el rol del usuario en la cuenta activa para guards de UI.

## Capabilities

### New Capabilities
- `org-roles`: Gestión de roles internos en una cuenta multi-usuario — matriz `owner/admin/member`, cambio de rol, expulsión, RLS por rol, gating de feature por plan.

### Modified Capabilities
- `multi-tenant`: La spec de `account_members` se amplía: el rol `admin` se agrega como valor válido, y se documenta la regla de que `admin` requiere plan `pro`.

## Impact

- **DB / Migraciones**: `ALTER TABLE account_members` (ampliar `CHECK`); nuevas RPCs `rpc_change_member_role`, `rpc_remove_member`; nuevas políticas RLS en tablas de negocio para separar lectores de escritores.
- **Edge Functions**: ninguna nueva; las RPCs van directo a Postgres.
- **Frontend**: nuevo hook `useOrgRole()`; nuevas páginas `/organizacion/roles` e `/organizacion/invitar`; guards de UI en formularios de venta/compra/gasto para bloquear a `member`.
- **Riesgo**: ALTO — tocar RLS de tablas de negocio puede romper acceso. Las políticas nuevas son aditivas (`FOR INSERT` separadas de `FOR SELECT`), no reemplazan las existentes. Hay 26 usuarios beta, todos `owner` de su cuenta → sin impacto visible durante beta.
