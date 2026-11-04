## Why

Una cuenta con más de un usuario **no funciona**, y la forma en que falla es peligrosa. Lo confirmó la auditoría de stock del 2026-10-14 ejecutando contra el stack local (humo `smoke_stock.sql`, bloque S20, pasos R3a-R3l, en `ROLLBACK`):

- **El formulario de venta y el de compra rechazan a todo el que no sea el dueño.** `rpc_create_sale_operation(_v2)` y `rpc_create_purchase_operation(_v2)` exigen `products.user_id = auth.uid()`: un vendedor o un administrador que vende o compra un producto cargado por el dueño recibe `P0403 Permission denied to product` (R3a, R3b, R3g). Editar exige además `sales.user_id = auth.uid()` (o `purchases.user_id`): el dueño no puede corregir una venta del empleado ni el administrador una del dueño (R3d, R3f). El POS y el borrado, que filtran por cuenta, sí funcionan (R3c, R3e).
- **El invitado opera en la cuenta equivocada sin enterarse.** Todo invitado tiene además su cuenta personal (la crea `handle_new_user` al registrarse), y **45 funciones** resuelven la cuenta con `current_account_ids() … LIMIT 1` **sin orden**. En la prueba devolvieron la personal: la venta de servicio del invitado quedó en su cuenta vacía y no en la del negocio (R3l), y el POS buscó el stock en la cuenta personal (R3j, `P0409`). Mientras tanto el token, FastAPI, el frontend y las Edge Functions eligen **otra** cuenta (la membresía más antigua): hay cuatro criterios de "cuenta activa" conviviendo.
- **Cuando funcione, un observador va a poder escribir.** Las ocho RPCs de alta, edición y borrado de ventas y compras no exigen ningún rol: hoy las frena sólo el guard por usuario del producto, y FastAPI sólo pide el rol de **plataforma**. Sacar ese guard sin poner otro le daría a un `viewer` la capacidad de crear, editar y borrar ventas.
- **No hay forma de sumarse a una cuenta.** `/organizacion/invitar` crea el token, pero no manda ningún email y no existe la ruta `/invitacion/[token]`: `rpc_accept_invitation` no tiene llamador. Es el candidato `invitacion-aceptar-ui` (CHANGES.md), y de él dependen `cuenta-activa-selector` y la activación de `single-session-per-user`.

**Por qué ahora**: el PO está por instalar ALIADATA a un cliente con empleados (onboarding de General Roca). En producción, medido el 2026-10-14: 41 cuentas, 41 miembros, **0 cuentas con más de un miembro, 0 usuarios en más de una cuenta, 0 invitaciones creadas**. El defecto es latente: no hay daño histórico (0 de 5.595 productos, 1.178 ventas, 679 compras, 259 gastos, 1.209 clientes y 5.154 movimientos de stock tienen un autor que no sea miembro de su cuenta). Se vuelve real con el primer invitado.

## What Changes

El change se aplica en **tres tandas**, en este orden, porque cada una es precondición de la siguiente:

**Tanda A — una sola cuenta activa, la misma en todos los canales** (no toca el cuerpo de ninguna RPC de operaciones):
- **Preferencia persistida.** `profiles.active_account_id` guarda la cuenta elegida; sólo la escriben `rpc_set_active_account` (valida la membresía) y la aceptación de una invitación. Nace protegida por la allow-list de columnas de `profiles`.
- **Un resolver canónico.** `resolve_active_account(user_id)` (interno): la preferencia si sigue siendo una membresía, si no la membresía más antigua por `(created_at, id)`.
- **`current_account_ids()` pasa a devolver sólo la cuenta activa (0 o 1 fila).** Primero el claim `app_metadata.account_id` del token, validado contra la membresía viva; si el claim falta, el resolver. Si el claim apunta a una cuenta de la que el usuario ya no es miembro, **no hay cuenta activa**: nunca cae en silencio a otra. Con ese único cambio, las 45 funciones con `LIMIT 1`, las 98 policies de RLS sobre 64 tablas que la usan y los agregados que hoy mezclan cuentas (`get_dashboard_financials`, `get_dashboard_critical_stock(_items)`, `rpc_period_comparison`) operan sobre la cuenta activa sin reescribir cada cuerpo. El nombre conserva el plural por compatibilidad; se documenta.
- **Los otros cinco criterios se alinean al resolver**: el hook de token, `rpc_my_active_account_roles`, `rpc_my_effective_plan`, `rpc_atomic_log_ai_insight` y el trigger `set_insight_account_id`.
- **El token transporta la cuenta.** El hook emite `app_metadata.account_id` junto con los roles y el plan **de esa misma cuenta**. FastAPI empuja ese claim a la base junto con `sub` y `role`.
- **FastAPI y las Edge Functions dejan de tener resolver propio.** `get_account_id` lee `current_account_ids()`. `require_account_role` usa los claims de rol **sólo si traen `account_id`**; si no, consulta la base. Las Edge Functions usan el mismo resolver por RPC.
- **Guard de pestaña desfasada.** El frontend manda `X-Account-Id` en cada request a FastAPI; si no coincide con la cuenta activa del token, la respuesta es `409 account_switched` (RFC 7807) y la pantalla se resincroniza.
- **Selector de cuenta** en el encabezado del menú lateral, visible sólo con dos o más cuentas. Cambiar de cuenta renueva el token, limpia la caché, avisa a las otras pestañas por el bus de sesión y lleva al Tablero.

**Tanda B — autorizar operaciones por pertenencia y rol, no por autor** (reescribe RPCs que también tocan dos changes hermanos; ver Impact):
- Las seis RPCs con guard por usuario pasan a exigir que **cada producto pertenezca a la cuenta activa** (filtro en el `SELECT … FOR UPDATE`, `P0404` indistinguible para un producto de otra cuenta) y que **cada documento editado pertenezca a la cuenta activa**.
- **Guard de rol en la base, autosuficiente**, en alta, edición y borrado de ventas y compras (ocho funciones): helper canónico nuevo `_account_assert_capability(account_id, roles, mensaje)` (la Regla de Tres ya está alcanzada por `_stock_assert_can_adjust`, `_quote_assert_can_write` y `_delivery_note_assert_role_dir`). Matriz recomendada en OQ-3 y OQ-4.
- **FastAPI** suma `require_account_role` con las capacidades nombradas en los services de ventas y compras (hoy sólo exigen el rol de plataforma). El frontend oculta las acciones que el rol no permite.

**Tanda C — invitación de punta a punta** (precondición: tanda B en producción, para que ningún invitado nazca con más poder que su rol):
- La invitación se crea, reenvía, revoca y lista por **FastAPI** (`/members/invitations`), que traduce los `P04xx` a RFC 7807. Una sola RPC encola el email `org_invite` dentro de la misma transacción: el destinatario y el token salen de la fila de la invitación, nunca de un parámetro.
- **Email** con plantilla nueva en `send-email`: todo dato del usuario escapado y el link armado con la URL fija de la app.
- **Ruta pública `/invitacion/[token]`** (sin `Referer`, sin indexar). Anónimo: mensaje genérico con "Ingresar" y "Crear cuenta", que vuelven a la invitación. Identidad correcta: vista previa con negocio, quién invita, roles y vencimiento, y botón **Aceptar**. Identidad incorrecta: el mismo error que un token vencido.
- **Aceptar** crea la membresía (como hoy), **deja el negocio como cuenta activa**, renueva el token y lleva al Tablero del negocio.
- `/organizacion/invitar` suma la lista de invitaciones pendientes con **Reenviar** (rota el token) y **Revocar**. La invitación rápida de `/configuracion` pasa al conjunto de roles. **BREAKING (contrato interno)**: se retira el overload de 2 argumentos de `rpc_invite_member`, después de migrar sus callers.
- Topes anti-abuso: enfriamiento por invitación y tope diario de emails por cuenta (OQ-8).

**Gates SQL nuevos que ejecutan las RPCs con un segundo miembro** (seller, admin, viewer, owner) y con un usuario de dos cuentas. Son los pasos R3a-R3l del humo convertidos en gate, más los controles negativos de cada guard: producto de otra cuenta, documento de otra cuenta, rol insuficiente, claim desfasado y membresía revocada.

## Capabilities

### New Capabilities

- `active-account`: qué es la cuenta activa de un usuario, dónde se persiste, cómo se elige y se cambia, y la obligación de que la base, el token, FastAPI, las Edge Functions y el frontend resuelvan siempre la misma. Incluye el guard de pestaña desfasada y el selector.
- `operation-member-authorization`: las operaciones de venta y compra se autorizan por pertenencia del producto y del documento a la cuenta activa más el rol del miembro, nunca por el autor. Incluye la regla de edición y borrado de documentos ajenos.
- `account-invitation-flow`: el recorrido completo de la invitación (envío por email, ruta de aceptación, vista previa ligada a la identidad, aceptación que activa la cuenta, reenvío, revocación, topes) y lo que ve el invitado al entrar.

### Modified Capabilities

- `authz-token-claims`: «Resolución determinística de la cuenta activa» deja de ser "la membresía más antigua" y pasa a ser "la preferencia válida o, si no hay, la más antigua", con el mismo criterio en todos los canales. Nace el requirement de que el token transporte la cuenta que describen sus claims.
- `account-tenancy`: «account_id obtenido desde el request context en backend Python» deja de describir un `LIMIT 1` y pasa a describir el resolver canónico y el chequeo de `X-Account-Id`.
- `multi-tenant`: «RPCs de operaciones sellan la cuenta» se reescribe sobre la cuenta activa (el texto vigente nombra `rpc_create_operation_aggregate`, que ya no existe) y suma el escenario del usuario con dos cuentas.
- `backend-auth`: nace el requirement de que los claims de rol de tenant sólo valen si describen la cuenta activa del request.
- `transactional-email-delivery`: nace la plantilla del email de invitación (escape de datos del usuario y link con la URL fija de la app).

## Impact

- **Base de datos** (tres migraciones, una por tanda; los números se confirman en cada apply contra `MAX(version)` de prod y los PRs abiertos, porque `remitos-compra` tanda B toma "el siguiente libre"):
  - **A**: columna `profiles.active_account_id` (FK `ON DELETE SET NULL`). Funciones nuevas: `resolve_active_account`, `rpc_set_active_account` y `rpc_my_accounts`. Redefinición de `current_account_ids()`. Reescritura, desde el `pg_get_functiondef` **vivo**, de `custom_access_token_hook`, `rpc_my_active_account_roles`, `rpc_my_effective_plan`, `rpc_atomic_log_ai_insight` y `set_insight_account_id`. Ninguna RPC de operaciones cambia de cuerpo.
  - **B**: `_account_assert_capability` nuevo. Reescritura desde el vivo de `rpc_create_sale_operation`, `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation`, `rpc_create_purchase_operation_v2`, `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation`, `rpc_delete_sale_operation` y `rpc_delete_purchase_operation`, misma firma (`CREATE OR REPLACE`), con `COMMENT` y ACLs re-emitidos.
  - **C**: funciones nuevas `rpc_send_invitation_email`, `rpc_list_account_invitations`, `rpc_revoke_invitation` y `rpc_invitation_preview`. Reescritura de `rpc_accept_invitation` (activa la cuenta) y de `rpc_invite_member` (3 argumentos). `DROP` del overload de 2 argumentos. Valor `revoked` en el `CHECK` de estado y columna snapshot `account_display_name` en `account_invitations`.
- **Backend**: `core/deps.py`, `core/auth.py` (clave `account_id` en el contexto), `core/database.py` (claims empujados), `core/guards.py`, `core/cors.py` (header permitido). Services de ventas y compras (capacidades). Router y service nuevos de invitaciones y de cuenta activa (`/me/accounts`, `/me/active-account`).
- **Edge Functions**: `_shared/reporting-canon.ts` (`resolveActiveAccountId`), `ai-estadisticas`, `ai-precio`, `ai-insights`, `generate-export`; `send-email` (plantilla `org_invite`) y un `_shared/html-escape.ts` nuevo.
- **Frontend**: `contexts/auth-context.tsx`, `lib/api/python-client.ts` y `auth-headers.ts` (`X-Account-Id`), `lib/auth/session-bus.ts` (señal `account:switched`), `components/app-sidebar.tsx` (selector), componente nuevo `components/accounts/AccountSwitcher.tsx`, ruta nueva `app/invitacion/[token]/page.tsx`, `lib/auth/route-access.ts` (prefijo público), `app/auth/register` (retorno a la invitación), `app/(dashboard)/organizacion/invitar/page.tsx` (FastAPI + pendientes), `components/settings/TeamSection.tsx`, `lib/rbac-capabilities.ts` (`CAN_PURCHASE`), botones de alta, edición y borrado de `/ventas` y `/compras`.
- **Gates y CI**: `test_multiusuario_cuenta_activa.sql`, `test_multiusuario_operaciones.sql` y `test_multiusuario_invitaciones.sql` nuevos. Ajustados a propósito: `test_custom_access_token_hook_account_roles.sql`, `test_accept_invitation_binding.sql` y `test_invite_member_roles_and_plan_gate.sql`. Se re-corren sin tocar los gates que introspectan los cuerpos de las ocho funciones de la tanda B. Reaplicación de cada migración al final de la cadena de `KPI_Validation.yml`.
- **Coordinación con changes hermanos** (D11):
  - `edicion-operaciones-con-dinero` (propose en paralelo) reescribe `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation`.
  - El fix en curso `fix/stock-edicion-sucursal-y-piso` toca las mismas dos.
  - `remitos-compra` tanda B (pendiente) extrae `_purchase_operation_core` de `rpc_create_purchase_operation` y reescribe el borrado y la edición de compras.
  - **Orden recomendado**: el fix de stock → `remitos-compra` tanda B → **multiusuario tanda B** → `edicion-operaciones-con-dinero`. La tanda A no se pisa con ninguno y puede ir antes que todos. Quien aplica segundo parte del cuerpo **vivo** y re-corre los gates del primero.
- **Absorbe candidatos**: `invitacion-aceptar-ui`, `cuenta-activa-selector`, la invitación rápida de `TeamSection` con conjunto de roles, `membership-rpcs-not-authenticated-p0401`, la parte de selector y resolución determinística de `v4-producto-calidad-05`, y el guard por usuario de la compra que dejó anotado `remitos-compra`.
- **Hallazgo lateral, fuera de alcance (OQ-7)**: cualquier usuario autenticado puede insertar en `email_logs` (policy `email_logs_backend_insert WITH CHECK (true)` + `INSERT` a nivel tabla) y el trigger manda el email a cualquier destinatario. Es un vector de phishing desde el dominio de ALIADATA, preexistente y explotable hoy sin multiusuario. Recomendado como hotfix propio, antes de la tanda C.
- **Governance**: **CRÍTICO** (autorización y aislamiento entre cuentas). Análisis y diseño solamente: nada se aplica sin la firma del PO sobre las OQs. Cada tanda parte del cuerpo vivo de producción, con *preflight* de `md5`.
- **Superficie frontend**: sí.
  - **Selector de cuenta**: en el encabezado del menú lateral, en escritorio y en el drawer móvil.
  - **`/invitacion/[token]`**: ruta pública nueva, a la que se llega por el link del email.
  - **`/organizacion/invitar`**: lista de pendientes con reenviar y revocar. Se llega como hoy, desde Configuración → Equipo y desde `/organizacion/roles`.
  - **`/ventas` y `/compras`**: acciones ocultas según el rol.
  - Todo se verifica en escritorio y en móvil, con tema claro y oscuro.
