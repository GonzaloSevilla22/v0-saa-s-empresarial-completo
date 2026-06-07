## Context

C-05 creó `accounts` + `account_members` con dos roles: `owner` y `member`. La constraint actual es `CHECK (role IN ('owner', 'member'))`. Los 26 usuarios beta son todos `owner` de su propia cuenta — no hay `member` real en producción, lo que hace este cambio de bajo riesgo real aunque sea ALTO por tocar RLS de tablas de negocio.

El scoping de datos ya corre por `account_id` (no por `user_id`) gracias a C-05. C-06 agrega la capa de *autorización por rol*: dentro de una cuenta, no todos los miembros tienen los mismos derechos de escritura.

## Goals / Non-Goals

**Goals:**
- Agregar rol `admin` exclusivo de plan `pro`
- Diferencias de permisos entre `owner`, `admin` y `member` en RLS y en UI
- RPCs para cambio de rol y expulsión con validación de permisos
- Páginas de gestión de roles e invitaciones
- Hook `useOrgRole()` para guards de UI

**Non-Goals:**
- Roles granulares por módulo (ej: "solo ventas") — fuera de scope de MVP
- Audit log de cambios de rol (puede hacerse en C-06b si se requiere)
- Roles de plataforma (`admin` de EmprendeSmart) — son `profiles.role`, no tocar

## Decisions

### D1 — Ampliar `CHECK` con `ALTER TABLE` en nueva migración (no reescribir C-05)

La constraint `CHECK (role IN ('owner', 'member'))` de C-05 se amplía con `ALTER TABLE public.account_members DROP CONSTRAINT account_members_role_values; ALTER TABLE public.account_members ADD CONSTRAINT account_members_role_values CHECK (role IN ('owner', 'admin', 'member'));` en una migración nueva (`20260606010000_roles_internos.sql`). No se toca la migración C-05.

**Alternativa descartada**: Recrear la tabla — destructivo y sin upside.

### D2 — Permisos de escritura vía políticas RLS separadas (`FOR INSERT/UPDATE/DELETE`)

Las tablas de negocio ya tienen `FOR SELECT` scoped a `account_id`. Agregar políticas `FOR INSERT`, `FOR UPDATE`, `FOR DELETE` que verifiquen que el miembro tenga `role IN ('owner', 'admin')`. Los `member` solo leen.

Función helper `is_account_writer(account_id uuid) RETURNS boolean` (`SECURITY DEFINER`) para evitar repetir la subquery en cada política.

**Alternativa descartada**: Agregar columna `can_write` a `account_members` — más flexible pero sobre-ingenierizado para MVP.

### D3 — RPCs `SECURITY DEFINER` para cambio de rol y expulsión

`rpc_change_member_role(p_account_id, p_target_user_id, p_new_role)`:
- Verifica que el caller sea `owner` (o `admin` solo si nuevo rol = 'member')
- Verifica que el nuevo rol sea compatible con el plan de la cuenta (`admin` requiere `pro`)
- Un `owner` no puede degradarse a sí mismo (requiere ceder ownership primero)
- Retorna `{ok: true}` o `{error: string}`

`rpc_remove_member(p_account_id, p_target_user_id)`:
- Solo `owner` puede expulsar a cualquiera; `admin` puede expulsar `member`
- No se puede expulsar al `owner`

**Alternativa descartada**: Políticas RLS directas para UPDATE/DELETE de `account_members` — lógica de validación compleja en SQL puro, más difícil de testear.

### D4 — Gating del rol `admin` en la RPC (no solo en UI)

La validación `admin` requiere `pro` ocurre dentro de `rpc_change_member_role`, no solo en frontend. Si el plan es `avanzado` e intentan asignar `admin`, la RPC retorna `{error: 'El rol admin requiere plan pro'}`.

### D5 — Hook `useOrgRole()` lee de `account_members` vía RPC

Nueva RPC `rpc_my_account_role(p_account_id)` retorna el rol del usuario en la cuenta. El hook cachea el resultado en React Query (staleTime 5 min). Se usa en guards de UI: bloquear formularios de nueva venta/compra/gasto para `member`.

## Risks / Trade-offs

- **[RLS en tablas de negocio]** → Políticas `FOR INSERT/UPDATE/DELETE` nuevas pueden romper flujos si `is_account_writer()` falla silenciosamente. Mitigación: testear con un perfil `member` en staging antes de aplicar; la función es `SECURITY DEFINER` con `search_path` fijo.
- **[Owner auto-degradación]** → Un owner podría quedar sin owner si se permite degradarse. Mitigación: la RPC bloquea degradar al caller si es el único `owner`.
- **[26 usuarios beta todos son owner]** → Cambio invisible en producción durante beta. No hay riesgo de impacto en acceso. Permite desplegar sin comunicación a usuarios.

## Migration Plan

1. Migración `20260606010000_roles_internos.sql`:
   - Ampliar `CHECK` de `account_members.role`
   - Función `is_account_writer()`
   - RPCs `rpc_change_member_role`, `rpc_remove_member`, `rpc_my_account_role`
   - Políticas RLS escritura en tablas de negocio
2. Aplicar con `npx supabase db push` (NUNCA MCP)
3. Deploy frontend — hooks, páginas, guards
4. Verificar con perfiles de prueba: `member` no puede crear venta, `admin` sí

**Rollback**: Las políticas RLS pueden droppearse; el `CHECK` puede revertirse a `('owner', 'member')`; las RPCs pueden droppearse. Sin datos migrados que revertir.

## Open Questions

- ¿El `admin` puede crear invitaciones directamente, o siempre pasa por el `owner`? → Decisión adoptada: `admin` puede invitar `member`; solo `owner` puede invitar `admin`.
- ¿Hay página de "ceder ownership"? → No en este change. El owner no puede degradarse sin un flujo de transferencia que está fuera de scope.
