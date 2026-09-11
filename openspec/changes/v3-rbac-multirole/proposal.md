## Why

Hoy una membresía tiene **un solo rol** (`account_members.role` ∈ `owner|admin|member`, CHECK sin cambios desde C-06). El encargado de una PyME vende, cobra y mueve stock: con un rol único hay que darle `admin` —permiso total de escritura sobre ventas, compras, gastos, productos y clientes— para que pueda hacer su trabajo. La inflación de permisos no es un descuido de configuración: es una consecuencia del modelo de datos. El Modelo V3 §5 la corrige con un pivot multi-rol con `assigned_by`/`assigned_at`/`expires_at`.

**Por qué ahora**: los tres bloqueantes duros que este change arrastraba desde la auditoría del 2026-07-07 están cerrados, archivados y verificados en prod — `v31-fix-auth-shape-500` (H-06), `v31-authz-token-hook` (H-07, hook emitiendo `role`/`account_role`/`plan` desde el 2026-08-01) y `v31-tenancy-pool-rls` + `v31-tenancy-role-assertion` (H-05, la RLS se evalúa de verdad para el backend). El único portón que faltaba era el **sign-off del PO**, firmado el **2026-09-11** con respuesta a las 7 preguntas del explore refrescado (`openspec/explore/2026-09-10-v3-rbac-multirole-refresh.md`). Además, cuatro changes del roadmap están represados esperando exactamente esta pieza: `v4-seguridad-04`/`05` (maker-checker), `v4-ia-09`/`v3-ai-agent-mcp-tools` (tools de escritura del agente), `v4-plataforma-01` (accesos temporales) y `v4-seguridad-09`.

**Lo que este change NO es**: un incendio de UX. Medido en prod el 2026-09-11: **39 cuentas, 39 miembros, 100% `owner`, 0 cuentas con 2+ miembros, 0 invitaciones pendientes**. Es infraestructura de autorización para el futuro cercano — y por eso se parte en tres, con la parte aditiva primero.

## What Changes

El change se ejecuta en **tres partes, cada una con su propio apply/PR, revisión adversarial y verificación en prod**.

### Parte A — Modelo de datos (aditivo, sin cambio de comportamiento observable)

- Catálogo global de roles como datos (tabla de solo lectura sembrada por migración, molde de `document_status_transitions`): `owner`, `admin`, `seller`, `cashier`, `stock`, `purchases`, `accountant`, `viewer` — **cerrado y global**, sin RBAC dinámico por tenant (V3 §5).
- Pivot `account_member_roles` (`member_id`, `role`, `assigned_by`, `assigned_at`, `expires_at`) con unicidad `(member_id, role)`; `expires_at IS NULL` = permanente.
- El pivot pasa a ser la **fuente de verdad**; `account_members.role` se conserva como **espejo mantenido por trigger** en el vocabulario legacy — el mismo patrón legacy/nuevo que ya se usó en `productos-categorias-sku`. Los tres RPCs de membresía existentes (`rpc_change_member_role`, `rpc_remove_member`, `rpc_accept_invitation`) escriben a través del pivot conservando firma, contrato `{ok}|{error}` y validaciones, para que exista **un solo camino de escritura** y no dos fuentes divergiendo.
- Invariante **la cuenta nunca queda sin `owner` activo**, hecho cumplir por trigger en el pivot (punto de paso obligado), no sólo dentro de un RPC.
- Auditoría de asignación/revocación en `audit_logs` (`entity_type = 'account_member_role'`), molde de `trg_audit_branch_lifecycle`.
- Backfill idempotente: las 39 filas `owner` → una asignación `owner` en el pivot con `assigned_at = created_at`.
- **Sin superficie frontend** (declarado): los datos existen, nada los lee todavía.

### Parte B — Enforcement (CRÍTICO)

- El hook de auth emite un claim **nuevo** `account_roles` (array de roles activos, excluyendo vencidos) y **conserva** `account_role` singular como valor derivado de compatibilidad — contrato ya fijado por `authz-token-claims`, no una decisión nueva.
- `require_account_role` pasa a evaluar el conjunto de roles; `AuthContext` gana `account_roles`. Guard nuevo de grano fino por capacidad para las superficies de dinero/stock/catálogo/configuración.
- `is_account_writer` **conserva su firma y sus 48 policies intactas**: se reescribe sólo el cuerpo de la función para leer el pivot. `current_account_ids()` **no se toca** (resuelve tenencia, no rol — verificado).
- `document_status_transitions.allowed_role` deja de ser inerte: pasa de `text` a conjunto de roles, se puebla la matriz rol × transición de las 19 filas (RN-A4) y `record_status_transition` la valida contra el actor. Las transiciones de sistema (relay CAE, expiración por cron) quedan exentas por `allowed_role` nulo. **BREAKING de dominio declarado**: desde el día del apply, una transición con rol insuficiente se rechaza.
- Expiración: evaluada al emitir claims y en cada guard; barrido diario `pg_cron` que audita los vencimientos ocurridos.
- **Sin superficie frontend propia**: las ~40 pantallas que ya leen `accountRole`/`isWriter` deben seguir funcionando sin romperse — requisito de compatibilidad, no pantalla nueva.

### Parte C — Superficie de administración

- `/organizacion/roles` **se extiende en el lugar** (misma ruta y navegación; no se rompen los enlaces desde `/organizacion/invitar` ni desde `/configuracion` → `TeamSection`): lista de miembros con sus roles y vencimientos, asignar/quitar rol, asignar con vencimiento, quitar miembro.
- `/organizacion/invitar` invita con múltiples roles.
- Endpoints FastAPI en 3 capas (routers → services → repositories) con errores RFC 7807, y `OrgRole` del frontend migrado al catálogo de 8 roles conservando el derivado singular y la semántica *fail-open* de `isWriter`.
- **BREAKING de producto**: se retira el gate comercial "el rol `admin` requiere plan `pro`" (sign-off del PO: todos los roles en todos los planes; el gating comercial es sólo por cantidad de usuarios vía `plan_limits.max_users`, que ya existe).

## Capabilities

### New Capabilities
- `account-membership-roles`: el pivot multi-rol de la membresía — catálogo cerrado y global, asignación con autoría y vencimiento, invariante de owner único, auditoría, y las operaciones de asignación/revocación con su superficie de administración.

### Modified Capabilities
- `org-roles`: la matriz de permisos deja de estar definida por un rol singular y pasa a evaluarse sobre el conjunto de roles activos; se retira el requirement que hace del rol `admin` una exclusividad del plan `pro`; el guard de UI pasa a derivar de un conjunto.
- `multi-tenant`: la membresía deja de declarar un rol único con valores `('owner','admin','member')` y deja de condicionar `admin` al plan `pro`.
- `authz-token-claims`: se realiza el contrato de evolución ya declarado — se emite el claim nuevo con el conjunto de roles activos y el claim singular se conserva como derivado de compatibilidad.
- `backend-auth`: el contexto de autenticación transporta el conjunto de roles de tenant y el guard de rol lo evalúa, con respaldo en la base cuando el claim no viaja.
- `document-status-history`: la dimensión de rol del catálogo de transiciones deja de ser inerte — admite un conjunto de roles por transición y el registro de transición la hace cumplir, con exención explícita para las transiciones de sistema.

## Impact

**Base de datos**: tabla de catálogo de roles (nueva) + `account_member_roles` (nueva) + trigger de espejo y trigger de invariante de owner sobre el pivot + `ALTER` de `document_status_transitions.allowed_role` a conjunto + reescritura de `is_account_writer`, `record_status_transition`, `custom_access_token_hook`, `rpc_change_member_role`, `rpc_remove_member`, `rpc_invite_member`, `rpc_accept_invitation`, `rpc_my_account_role` (todas desde su cuerpo **vivo** de prod, con checkpoint de `md5`) + RPCs nuevas de asignación/revocación + barrido `pg_cron` de vencimientos. Tres migraciones, una por parte.

**Backend Python**: `backend/core/auth.py` (`AuthContext`), `backend/core/guards.py` (`require_account_role` + guard de capacidad), y los 4 services que hoy consumen `require_account_role` (`cost_centers`, `payment_methods`, `product_categories`, `account_charges` — 15 llamadas). Router/service/repository nuevos para la administración de miembros. **Los 59 `require_role(auth, ["user","admin"])` NO se tocan**: son rol de **plataforma** (`profiles.role`), otro espacio de nombres — verificado por grep, y es una reducción real del alcance que el explore estimaba en "65+4 call sites".

**Frontend**: `frontend/lib/types.ts` (`OrgRole`), `frontend/hooks/useOrgRole.ts`, `frontend/app/(dashboard)/organizacion/roles/page.tsx`, `frontend/app/(dashboard)/organizacion/invitar/page.tsx`, `frontend/components/settings/TeamSection.tsx` y los archivos que consumen `accountRole`/`isWriter`.

**Documentación**: `knowledge-base/03_actores_y_roles.md` (la tabla comercial promete "Roles internos: Básicos/Avanzados" por plan — la decisión del PO la deroga) y `CHANGES.md`. `CLAUDE.md`/`AGENTS.md` no se tocan.

**Riesgo residual declarado, no oculto**: `is_account_writer` sigue siendo **grueso** (escritor sí/no, no por dominio), así que la separación fina entre `cashier` y `stock` la hace cumplir el backend, no la RLS. Se defiere a un change propio porque migrar las 48 policies multiplicaría el radio de impacto de la parte más riesgosa; se apoya en que el navegador **no** escribe ninguna de las 20 tablas involucradas por PostgREST (medido: los únicos `insert`/`update`/`delete` directos del frontend son sobre tablas de comunidad y analítica).
