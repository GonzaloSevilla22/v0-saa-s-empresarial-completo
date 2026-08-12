## Why

Desde el corte de C-23 (`20260615000001_community_schema_move.sql`, 2026-06-15) **responder un post de comunidad o dar/sacar like falla en producción**. `SET SCHEMA` preservó los triggers `on_post_reply_change` y `on_post_like_change`, pero sus funciones (`public.update_post_replies_count()` / `public.update_post_likes_count()`) siguen escribiendo `UPDATE public.posts ...` sin calificar el schema nuevo. `public.posts` ya no existe → 42P01 → como son triggers `AFTER`, la excepción aborta la transacción que los disparó y **ni la reply ni el like se persisten**.

La evidencia contra prod (proyecto `gxdhpxvdjjkmxhdkkwyb`, lectura de catálogo al 2026-08-12) es concluyente: `community.post_likes` tiene **0 filas** pero acumula **13.082 index scans** sobre `post_likes_post_id_user_id_key` y 2.107 seq scans — los usuarios intentan dar like (el frontend consulta "¿existe mi like?" antes de insertar) y nunca persiste ninguno. `community.replies` tiene 2 filas residuales previas al corte, con `idx_replies_post_id` en 0 scans. Son ~2 meses de una funcionalidad de producto muerta en silencio.

El barrido sistemático del catálogo de prod (139 funciones de `public` + schema `community`, contra las 16 tablas movidas por C-23) cerró el universo del bug: solo 4 funciones estaban rotas por esta causa. Dos —`get_admin_community_interactions` y `rpc_admin_module_stats`— ya quedaron corregidas por `20260917000001_admin_kpi_refresh.sql` (PR #387, en main, pendiente de aplicarse en prod). Las **dos restantes son el alcance de este change**. No hay vistas, políticas RLS ni otros objetos referenciando `public.<tabla movida>`.

## What Changes

- **Corrección de las dos funciones de contador**: `CREATE OR REPLACE FUNCTION` con la misma firma (sin parámetros, así que no hay riesgo de segundo overload 42725 y no hace falta `DROP FUNCTION` previo) calificando `community.posts`. Se conserva `SECURITY DEFINER` y `SET search_path = public`: lo que arregla el bug es la calificación explícita, no el `search_path` — ampliarlo a dos schemas resolvería por orden y volvería a hacer invisible el próximo movimiento de tablas (mismo criterio D5 de `admin-kpi-refresh`).
- **Guard degrade-don't-fail**: el `UPDATE` del contador queda envuelto en `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ... END`, para que un fallo futuro de la desnormalización nunca vuelva a tumbar la operación de negocio del usuario. `replies_count`/`likes_count` son cosméticos; la fila de `replies`/`post_likes` es el hecho de negocio. Precedente exacto del proyecto: `analytics_emit_operation_event` (`20260914000001`) y el seed de `handle_new_user` (`20260812000001`).
- **Recompute idempotente** de `replies_count` y `likes_count` en `community.posts` desde `community.replies` / `community.post_likes` en la misma migración, para dejar los contadores consistentes con los datos reales tras el período roto (hoy 4 posts en prod — costo nulo).
- **Re-afirmación idempotente de los ACLs** (`REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`) al final de la migración. `CREATE OR REPLACE` preserva ACLs, pero re-aplicarlos es barato y `test_function_acl_gate.sql` los verifica en CI.
- **Gate de regresión nuevo** (`supabase/tests/test_community_interactions.sql`, cableado en `KPI_Validation.yml`) que cubre el camino feliz de ambos contadores (INSERT/DELETE de reply y de like) **y** un assert de catálogo generalizado: ninguna función de `pg_proc` en los schemas `public` y `community` referencia `public.<tabla>` para ninguna de las 16 tablas movidas por C-23. Esto convierte el hallazgo puntual en una red que atrapa cualquier recaída futura de la misma familia.
- **Retiro del workaround en `supabase/tests/test_admin_kpis.sql`**: ese gate hoy hace `ALTER TABLE community.replies DISABLE TRIGGER on_post_reply_change` alrededor de su seed y su cleanup, con un comentario que documenta este mismo bug como "preexistente y fuera de alcance". Con el fix aplicado el workaround deja de ser necesario y su permanencia enmascararía una regresión futura.
- **Sin cambios en el frontend**: el código de `frontend/hooks/data/use-posts.ts` ya es correcto (inserta en `supabase.schema("community").from("replies")` y `.from("post_likes")`, y documenta que "replies_count is updated by the DB trigger on_post_reply_change"). El bug es 100% del lado servidor.

## Capabilities

### New Capabilities

Ninguna. El fix cae dentro de una capability existente.

### Modified Capabilities

- `community-schema`: se agrega el requisito de que **los objetos SQL del servidor** (funciones de trigger, RPCs, vistas) referencien las tablas movidas con schema calificado `community.*` — hoy la capability solo exige eso del frontend y las Edge Functions, y da por buena la preservación de triggers de `SET SCHEMA` sin exigir que sus funciones sigan resolviendo. Se agrega además el contrato de los contadores desnormalizados `posts.replies_count` / `posts.likes_count` (se mantienen consistentes y nunca abortan la operación de negocio).

## Impact

- **Migración nueva**: `supabase/migrations/20260918000001_community_counter_triggers_schema_fix.sql` (timestamp posterior al último local aplicado, `20260917000001`). Idempotente y drift-tolerante: la integración GitHub de Supabase auto-aplica migraciones al mergear, **antes** del `db push` de Actions.
- **Objetos de DB tocados**: `public.update_post_replies_count()`, `public.update_post_likes_count()` (redefinidas, misma firma), filas de `community.posts` (recompute de contadores). Los triggers `on_post_reply_change` / `on_post_like_change` **no se tocan**: siguen apuntando a las mismas funciones.
- **CI**: `supabase/tests/test_community_interactions.sql` (nuevo) + un paso en `.github/workflows/KPI_Validation.yml`. `supabase/tests/test_admin_kpis.sql` pierde el `DISABLE TRIGGER` de workaround (2 ubicaciones en el camino feliz + 1 en el bloque de rescate).
- **Superficie frontend**: **sin superficie nueva**. La UI de comunidad (`frontend/app/(dashboard)/comunidad/page.tsx` + `frontend/hooks/data/use-posts.ts`) ya existe y es la beneficiaria directa: el fix restituye el funcionamiento de responder y dar like, que hoy están rotos. Queda una task de verificación manual post-deploy sobre esa pantalla (desktop y mobile) en lugar de trabajo de construcción.
- **Backend Python**: sin impacto — no referencia tablas del schema `community`.
- **Governance**: MEDIO. No toca billing, auth ni security. `SECURITY DEFINER` se conserva tal cual estaba (no se amplía privilegio) y los ACLs quedan igual de restrictivos que después de `20260822000001`.
- **Riesgo aceptado**: el guard degrade-don't-fail puede producir drift silencioso del contador si algo falla en el futuro. Mitigado porque (a) el gate de regresión asserta el camino feliz con conteos exactos —si el contador deja de incrementar, CI falla con un número incorrecto, no con un no-op verde— y (b) `RAISE WARNING` deja rastro en los logs de Postgres.
