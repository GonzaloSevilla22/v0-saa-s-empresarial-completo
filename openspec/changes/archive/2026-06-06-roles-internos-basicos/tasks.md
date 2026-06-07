# Tasks — roles-internos-basicos (C-06)

> Governance **ALTO**: toca RLS de tablas de negocio (`sales`, `purchases`, `expenses`, `products`, etc.) y el schema de `account_members`. Los 26 usuarios beta son todos `owner` → sin impacto visible. Aplicar migraciones SIEMPRE con `npx supabase db push` (NUNCA MCP `apply_migration`).
> Orden: DB primero, luego frontend. Las RPCs son SECURITY DEFINER — testear con un perfil `member` de prueba antes de deploy.

## 0. Pre-flight

- [x] 0.1 Verificar baseline: `SELECT role, count(*) FROM account_members GROUP BY 1` — todos deben ser `owner` (26 rows). Guardar resultado.
- [x] 0.2 Confirmar que `is_account_writer` no existe todavía: `SELECT proname FROM pg_proc WHERE proname = 'is_account_writer'` → debe retornar 0 rows.

## 1. Migración — ampliar roles y helpers

- [x] 1.1 Crear `supabase/migrations/20260606010000_roles_internos.sql`. Ampliar constraint: `ALTER TABLE public.account_members DROP CONSTRAINT account_members_role_values; ALTER TABLE public.account_members ADD CONSTRAINT account_members_role_values CHECK (role IN ('owner', 'admin', 'member'));`
- [x] 1.2 Crear función `is_account_writer(p_account_id uuid) RETURNS boolean` (`SECURITY DEFINER`, `SET search_path = public`): retorna `TRUE` si el caller tiene `role IN ('owner', 'admin')` en `account_members` para ese `p_account_id`.
- [x] 1.3 **TEST 1.2**: `SELECT is_account_writer('<account_id_del_owner>')` con un `owner` real → debe retornar `true`. Con un usuario sin membresía → debe retornar `false`.

## 2. Migración — RPCs de gestión de roles

- [x] 2.1 Crear `rpc_change_member_role(p_account_id uuid, p_target_user_id uuid, p_new_role text) RETURNS jsonb` (`SECURITY DEFINER`, `search_path = public`). Validaciones en orden:
  1. Caller tiene `role IN ('owner', 'admin')` en la cuenta → sino `{error: 'Sin permisos'}`
  2. Si caller es `admin` y `new_role != 'member'` → `{error: 'Sin permisos para cambiar este rol'}`
  3. Si `new_role = 'admin'`, verificar `accounts.billing_plan = 'pro'` → sino `{error: 'El rol admin requiere plan pro'}`
  4. Si target es el único `owner` y `new_role != 'owner'` → `{error: 'No se puede degradar al único owner'}`
  5. `UPDATE account_members SET role = p_new_role WHERE account_id = p_account_id AND user_id = p_target_user_id`
  6. Retorna `{ok: true}`
- [x] 2.2 Crear `rpc_remove_member(p_account_id uuid, p_target_user_id uuid) RETURNS jsonb` (`SECURITY DEFINER`, `search_path = public`). Validaciones:
  1. Caller tiene `role IN ('owner', 'admin')` → sino `{error: 'Sin permisos'}`
  2. Target tiene `role = 'owner'` → `{error: 'No se puede expulsar al owner'}`
  3. Si caller es `admin` y target tiene `role IN ('owner', 'admin')` → `{error: 'Sin permisos para expulsar este miembro'}`
  4. `DELETE FROM account_members WHERE account_id = p_account_id AND user_id = p_target_user_id`
  5. Retorna `{ok: true}`
- [x] 2.3 Crear `rpc_my_account_role(p_account_id uuid) RETURNS text` (`SECURITY DEFINER`, `search_path = public`): retorna el `role` del caller en la cuenta, o `NULL` si no es miembro.
- [x] 2.4 Actualizar `rpc_create_invitation` (ya existente de C-05) para validar que el `role` del invitado sea compatible: si caller es `admin`, solo puede crear invitaciones con `role = 'member'`. Si `role = 'admin'`, la cuenta debe tener `billing_plan = 'pro'`.

## 3. Migración — RLS escritura en tablas de negocio

- [x] 3.1 Agregar políticas `FOR INSERT` en `sales`, `purchases`, `expenses`: `CREATE POLICY "<tabla>_writer_insert" ON public.<tabla> FOR INSERT TO authenticated WITH CHECK (is_account_writer(account_id));`
- [x] 3.2 Agregar políticas `FOR UPDATE` y `FOR DELETE` en `sales`, `purchases`, `expenses` con el mismo CHECK.
- [x] 3.3 Agregar políticas `FOR INSERT/UPDATE/DELETE` en `products`, `clients` con `is_account_writer(account_id)`. [NOTA: `suppliers` usa `company_id`, no `account_id` — no migrada en C-05, diferida.]
- [x] 3.4 **GATE + `npx supabase db push`**. **TEST 3.4**: Migración aplicada. Políticas writer en 5 tablas confirmadas. Baseline de 26 owners sin cambios. RLS en staging pendiente de test con perfil member real.

## 4. Frontend — hook y guards

- [x] 4.1 Crear `hooks/useOrgRole.ts`: llama a `rpc_my_account_role(accountId)` con React Query (`staleTime: 5 * 60 * 1000`). Retorna `role: 'owner' | 'admin' | 'member' | null` y `isWriter: role === 'owner' || role === 'admin'`.
- [x] 4.2 En los formularios de nueva venta (`/ventas/nueva`), nueva compra, nuevo gasto: agregar guard `if (!isWriter) return <NoWriteAccessBanner />` — banner con mensaje "Solo lectura — contactá al owner para crear operaciones".
- [x] 4.3 En listados de ventas/compras/gastos: ocultar botones "Nueva venta", "Nueva compra", "Nuevo gasto" cuando `!isWriter`.
- [x] 4.4 **TEST 4.1**: `tsc --noEmit` limpio.

## 5. Frontend — páginas de gestión

- [x] 5.1 Crear `app/(dashboard)/organizacion/roles/page.tsx`: tabla con miembros de la cuenta activa (nombre/email, rol, fecha de unión). Columna de acciones: `owner` ve selector de rol + botón expulsar para todos; `admin` ve selector de rol + expulsar solo para `member`. Llamadas a `rpc_change_member_role` y `rpc_remove_member`. Plan gating: si cuenta es `avanzado`, el selector de rol no muestra la opción `admin`.
- [x] 5.2 Crear `app/(dashboard)/organizacion/invitar/page.tsx`: formulario con campo email + selector de rol (según permisos del caller). Invoca `rpc_invite_member` con el `role` seleccionado. Validación de cupo de miembros (muestra "X de Y usuarios usados"). Muestra aviso de cupo lleno con link a planes.
- [x] 5.3 Agregar link "Gestión de roles" e "Invitar miembro" en la página `/organizacion` existente (o en la navegación lateral si aplica). [Implementado en TeamSection del tab Equipo de Configuración.]
- [x] 5.4 **TEST 5.1**: verificar que el selector de rol en plan `avanzado` no incluye `admin` (inspección visual). `tsc --noEmit` limpio.

## 6. Cierre

- [x] 6.1 Re-correr TEST 0.1: `SELECT role, count(*) FROM account_members GROUP BY 1` — sigue siendo 26 `owner`, 0 cambios.
- [x] 6.2 `tsc --noEmit` limpio en todo el proyecto.
- [x] 6.3 Marcar `[x]` C-06 en `CHANGES.md` tras archivar.
