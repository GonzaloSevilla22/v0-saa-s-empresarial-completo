## Why

El backend Python decide autorización leyendo `auth["role"]` — un valor que **hoy nunca viene del JWT**. El `custom_access_token_hook` existe en la base (`supabase/migrations/20260800000004_auth_jwt_role_hook.sql`, aplicado) pero está **deshabilitado en el Dashboard de Supabase Auth de producción**, así que `get_current_user` cae siempre al fallback `"user"`. Resultado verificado en prod (`gxdhpxvdjjkmxhdkkwyb`, 2026-07-31): **0 de 34 usuarios** con claim de rol. Esto es H-07 de la auditoría 2026-07-07, confirmado sin remediar por la exploración del 2026-07-30.

Las consecuencias no son teóricas y se miden hoy:

- **`cost_centers` da 403 a todo el mundo.** Sus 3 guards piden `require_role(auth, ["owner","admin"])`; el valor efectivo es `"user"`, que no está en la lista. La tabla tiene **0 filas en prod** — nadie pudo crear un centro de costo nunca. Es el criterio de aceptación (a) de la ficha de `v3-rbac-multirole`.
- **El gating por plan es fail-open.** `get_current_user` usa `payload.app_metadata.plan` con default `"pro"`; sin claim, **las 34 cuentas se tratan como PRO**. En prod hay **8 cuentas `gratis`** (límite 100 productos) que reciben el límite PRO (999.999), y una de ellas ya tiene **123 productos**. Es el criterio (b) de la misma ficha.
- **`require_role` es efectivamente un no-op** en los otros 62 call sites, porque el fallback `"user"` está en la lista permitida de 56 de ellos. La capa 2 de autorización que la KB documenta (DEC-13 / KB-08) no existe en runtime.

Y es un **prerequisito duro** de `v3-rbac-multirole`: migrar el pivot de roles y reescribir `require_role` para leerlo **no cambia nada observable en prod** mientras el rol no llegue al token.

El hallazgo que reordena el diseño y que ninguna ficha previa registra: **hay dos espacios de nombres de rol distintos, mezclados en el mismo guard**. `profiles.role` es el rol de **plataforma** (`user` | `admin`; en prod 33 + 1) y `account_members.role` es el rol de **tenant** (`owner` | `admin` | `member`; en prod 34/34 `owner`). Los 56 call sites de `require_role(auth, ["user","admin"])` hablan el primero; los 3 de `cost_centers` (`["owner","admin"]`) hablan el segundo. **Inyectar el rol de tenant en el claim `role`, como sugería el plan original, pondría `"owner"` donde 56 guards esperan `"user"` — un 403 masivo en casi todo el backend, para las 34 cuentas, en el momento de activar el toggle.** Este change existe para habilitar el hook **sin** ese resultado.

## What Changes

- **El hook pasa a emitir tres claims bajo `app_metadata`, con espacios de nombres separados**:
  - `role` — rol de **plataforma**, desde `profiles.role`. Es lo que el hook ya hacía; se conserva sin cambio semántico, porque es exactamente lo que esperan los 56 guards existentes y `require_platform_admin`.
  - `account_role` — **claim nuevo**, rol de **tenant** desde `account_members.role` para la cuenta activa del usuario. Nunca pisa `role`.
  - `plan` — **claim nuevo**, plan **efectivo** de la cuenta activa, obtenido llamando a `public.get_effective_plan(account_id)` — la definición canónica que introduce el change **`billing-pro-trial`** (exención → `pro`; trial vigente → `trial_plan`; si no → `billing_plan`; sin información → `gratis`). El hook **no** reimplementa la regla: sería su tercera copia, en el punto más difícil de testear del sistema.
- **Migración idempotente** que reemplaza la definición del hook: agrega las dos lecturas nuevas, fija `search_path` (hoy mutable — advisor `function_search_path_mutable` abierto sobre la función auth-crítica más sensible del proyecto), conserva el blindaje `EXCEPTION WHEN OTHERS → claims intactos` y agrega los `GRANT SELECT` + policies de lectura para `supabase_auth_admin` sobre `account_members` y `accounts` (verificado: hoy **no tiene ninguno** sobre esas dos tablas; solo sobre `profiles`).
- **Resolución determinística de la cuenta activa**: el hook y `backend/core/deps.py::get_account_id` pasan a usar el **mismo criterio ordenado** de selección de membresía. Hoy `get_account_id` hace `LIMIT 1` sin `ORDER BY`; con multi-membresía el claim y el resolver podrían discrepar (bug latente: 0 usuarios con 2+ cuentas hoy, pero el pivot de `v3-rbac-multirole` lo vuelve alcanzable).
- **Backend: leer el claim con fallback de transición**. `AuthContext` gana `account_role`. Se agrega un guard `require_account_role(conn, auth, allowed)` que prefiere el claim y, si está ausente (token viejo aún vigente), lo resuelve contra la base — el mismo patrón que ya usa `require_platform_admin`. Los 3 guards de `cost_centers` migran a él. **Los 56 call sites de `require_role(["user","admin"])` NO se tocan**: siguen leyendo el rol de plataforma, que es lo que siempre quisieron decir.
- **Habilitación en producción = tarea MANUAL del PO**, con instrucciones exactas. El toggle vive en el Dashboard de Supabase Auth (`config.toml` solo aplica a `supabase start` local — el `enabled = true` del repo **no** es evidencia de nada en prod). Se documenta también la alternativa por Management API para que la ejecute el PO; el agente no manipula tokens de administración.
- **Verificación de aceptación sin fabricar credenciales**: endpoint de diagnóstico `GET /auth/claims-status` que devuelve, para el usuario ya autenticado, **solo booleanos de presencia** de cada claim más el rol/plan efectivos — nunca el token ni su payload crudo. El PO lo consulta desde su sesión real tras re-loguearse. (Nota que la migración anterior no registra: el hook **no** escribe `auth.users.raw_app_meta_data`; la query `raw_app_meta_data ? 'role'` seguirá dando 0 con el hook activo y **no** sirve como verificación.)
- **Estrategia de transición documentada**: los JWT ya emitidos conservan el estado viejo hasta su refresh (~1 h) o hasta re-login. Durante esa ventana conviven tokens con y sin claims; el backend tolera ambos por diseño (fallback), sin comunicación forzada a usuarios.
- **Forward-compat explícita hacia `v3-rbac-multirole`**: `account_role` es **singular** porque `account_members.role` es singular hoy. Cuando exista el pivot `account_member_roles`, el hook emitirá `account_roles` (array de roles activos, respetando `expires_at`) y `account_role` quedará como compat. Ese cambio pertenece a `v3-rbac-multirole`, no a este change; acá solo se deja el contrato escrito para que no se re-litigue.
- **Rollback sin migración destructiva**: desactivar el toggle en el Dashboard devuelve el statu quo (JWT sin claims + fallback del backend). Nada queda roto; solo se pierde la mejora.

**BREAKING (de comportamiento, no de contrato HTTP)** — al activar el toggle, y **solo entonces**:
- El límite de plan pasa a ser real. **Desactivado como riesgo de corte por el sign-off del 2026-07-31**: con los 30 días de trial PRO que otorga `billing-pro-trial`, en el instante de la activación las 34 cuentas resuelven a `pro` y ninguna ve un límite reducido; el enforcement empieza al vencer el trial, con excedente tolerado y aviso.
- `cost_centers` deja de dar 403 a los `owner` (efecto deseado, criterio (a)).

## Capabilities

### New Capabilities

- `authz-token-claims`: el contrato de los claims de autorización que el hook de Supabase Auth inyecta en el JWT — qué claims existen, de qué tabla sale cada uno, cómo se resuelve la cuenta activa, qué pasa ante error (degradar sin romper el login), en qué superficie se habilita/deshabilita en producción y cómo se verifica sin exponer el token.

### Modified Capabilities

- `backend-auth`: el contexto de autenticación incorpora el rol de tenant (`account_role`) como clave del contrato, se establece que el rol de plataforma y el de tenant **no comparten espacio de nombres**, y se define el comportamiento de transición cuando un claim todavía no viaja en el token (resolución contra la base, nunca degradación silenciosa a un valor permisivo).
- `plan-gating`: el plan efectivo que usa el enforcement del backend Python pasa a derivarse del claim del token (plan de la cuenta, con trial vigente con precedencia) en lugar de un valor por defecto optimista; se establece que la ausencia de información de plan NOT SHALL resolverse concediendo el plan más alto.

## Impact

- **Base de datos**: una migración idempotente que redefine `public.custom_access_token_hook(jsonb)` (`CREATE OR REPLACE`, misma firma — sin riesgo de overload duplicado) + `GRANT SELECT` y policy de lectura para `supabase_auth_admin` sobre `account_members`, y `GRANT EXECUTE` sobre `public.get_effective_plan` (que es `SECURITY DEFINER`, así que **no** hace falta abrir `accounts`). Sin DDL de tablas, sin backfill, sin borrado de datos.
- **Código backend**: `backend/core/auth.py` (`AuthContext` + lectura de `account_role`), `backend/core/guards.py` (`require_account_role`), `backend/core/deps.py` (orden determinístico), `backend/services/cost_centers.py` (3 guards), un router de diagnóstico, tests.
- **API**: endpoint nuevo `GET /auth/claims-status` (solo diagnóstico, sin datos sensibles). Ningún endpoint existente cambia de forma; `cost_centers` deja de responder 403 a los `owner`.
- **Frontend**: **ninguno**. Barrido verificado: el frontend no lee `app_metadata` en ningún archivo.
- **Configuración de producción**: un toggle en Supabase Auth → Hooks → Customize Access Token. **Fuera del repo**, fuera de CI/CD, fuera del alcance del agente → tarea manual del PO.
- **Governance**: **CRÍTICO** — toca la emisión de tokens de 34 usuarios reales. Análisis, migración y código se preparan y testean; **la activación en producción requiere acción y sign-off explícitos del PO**.
- **Cluster**: prerequisito duro de `v3-rbac-multirole`. **Depende de `billing-pro-trial`** (el claim `plan` consume su `get_effective_plan`) — ese change se mergea primero. Corre en paralelo lógico con `v31-tenancy-pool-rls`; ambos deben cerrar antes del pivot. Depende de `v31-fix-auth-shape-500` ✅ (el contrato `AuthContext` que este change extiende).
