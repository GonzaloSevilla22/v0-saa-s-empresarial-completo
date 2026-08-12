# community-schema — Spec

## Purpose

Separación del dominio no-ERP (cursos, comunidad, seguros, compras colectivas, landing, IA copiloto) en un schema Postgres propio (`community`), desacoplado del ERP, expuesto vía Data API y accedido desde frontend/Edge Functions con schema explícito.

## Requirements

### Requirement: Tablas de comunidad viven en el schema `community`
Las 16 tablas del dominio no-ERP (`courses`, `course_modules`, `course_lessons`, `course_enrollments`, `course_progress`, `lesson_progress`, `posts`, `replies`, `post_likes`, `meetings`, `seguros`, `purchase_pools`, `landing_sections`, `fair_recommendations`, `fair_ai_tools`, `copilot_prompts`) SHALL residir en el schema Postgres `community`, no en `public`. La migración MUST usar `ALTER TABLE ... SET SCHEMA` preservando datos, FKs, índices, triggers y políticas RLS.

#### Scenario: Datos preservados tras la migración
- **WHEN** se ejecuta la migración de movimiento
- **THEN** cada tabla movida conserva exactamente sus filas previas (p. ej. `community.posts` = 4 filas, `community.courses` = 4 filas) y `public.<tabla>` ya no existe

#### Scenario: RLS sigue activa en el schema nuevo
- **WHEN** un usuario autenticado consulta `community.posts` vía la Data API
- **THEN** las políticas RLS preexistentes se aplican igual que cuando la tabla estaba en `public`

#### Scenario: FKs cross-schema intactas
- **WHEN** se consulta `pg_constraint` tras la migración
- **THEN** las FKs `community.posts → public.profiles`, `community.course_enrollments → auth.users` y `community.fair_recommendations → public.accounts` siguen definidas y válidas

### Requirement: Schema `community` expuesto en la Data API
El schema `community` SHALL estar configurado en los Exposed schemas de PostgREST con grants de `USAGE` para `anon`, `authenticated` y `service_role`, y privilegios por defecto equivalentes a `public` para tablas futuras.

#### Scenario: Query vía supabase-js con schema explícito
- **WHEN** el frontend ejecuta `supabase.schema("community").from("posts").select("*")`
- **THEN** PostgREST responde con las filas permitidas por RLS (no 404/406 de schema no expuesto)

#### Scenario: Embedding cross-schema funciona
- **WHEN** se consulta `posts` con `select("*, profiles(name), post_likes(user_id)")` vía `.schema("community")`
- **THEN** la respuesta embebe el nombre del autor desde `public.profiles` y los likes desde `community.post_likes`

### Requirement: Frontend y Edge Functions acceden vía `.schema("community")`
Todo acceso de código a las tablas movidas SHALL usar `.schema("community")` del cliente supabase-js. El insert de `analytics_events` (tabla ERP de `public`) en `use-posts` MUST permanecer sin schema explícito.

#### Scenario: Cero referencias residuales a public
- **WHEN** se busca `from("<tabla movida>")` sin `.schema("community")` en `frontend/` y `supabase/functions/`
- **THEN** no hay ocurrencias (las 10 ubicaciones frontend + `fair-advisor` migradas)

#### Scenario: Flujo de posts end-to-end
- **WHEN** un usuario crea un post, le da like y responde
- **THEN** las filas se insertan en `community.posts`, `community.post_likes` y `community.replies` y el feed se actualiza

### Requirement: El ERP no se acopla al schema community
Ninguna tabla del ERP (`sales`, `purchases`, `products`, `clients`, `expenses`, `branches`, etc.) SHALL tener FK hacia tablas del schema `community`, y el backend Python MUST seguir sin referenciar tablas movidas.

#### Scenario: Verificación de desacoplamiento
- **WHEN** se consulta `pg_constraint` buscando FKs desde tablas ERP hacia `community.*`
- **THEN** el resultado es vacío y la suite del backend Python pasa sin cambios

### Requirement: Los objetos SQL del servidor califican el schema de las tablas movidas
Toda función, vista o política del servidor que lea o escriba una de las 16 tablas movidas por C-23 SHALL referenciarla con el schema calificado `community.<tabla>`, nunca como `public.<tabla>` ni con nombre desnudo apoyado en `search_path`. Ampliar `search_path` para incluir `community` NO es una alternativa aceptable: resuelve por orden y vuelve invisible el próximo movimiento de tablas (criterio D5 de `admin-kpi-refresh`). Esta exigencia MUST cubrir en particular a las funciones de trigger, que `ALTER TABLE ... SET SCHEMA` preserva enganchadas pero no reescribe.

#### Scenario: Barrido de catálogo sin referencias residuales a public
- **WHEN** se recorre `pg_proc` en los schemas `public` y `community` buscando en `prosrc` referencias `public.<tabla>` para cada una de las 16 tablas movidas por C-23
- **THEN** no hay ninguna coincidencia

#### Scenario: Las funciones de contador escriben en el schema correcto
- **WHEN** se inspecciona el cuerpo de `public.update_post_replies_count()` y `public.update_post_likes_count()`
- **THEN** ambas actualizan `community.posts` con schema calificado, conservan `SECURITY DEFINER` y `SET search_path = public`, y existe exactamente una definición de cada `proname` (anti-42725)

#### Scenario: Los triggers siguen enganchados tras la corrección
- **WHEN** se consulta `pg_trigger` después de aplicar la migración
- **THEN** `on_post_reply_change` sobre `community.replies` y `on_post_like_change` sobre `community.post_likes` siguen existiendo, habilitados, y apuntando a las mismas funciones (la corrección usa `CREATE OR REPLACE`, sin recrear el trigger)

#### Scenario: Los ACLs restrictivos sobreviven a la redefinición
- **WHEN** se consulta `has_function_privilege` para `anon` y `authenticated` sobre ambas funciones de contador tras la migración
- **THEN** ninguno de los dos roles tiene `EXECUTE` (los REVOKE de `20260822000001` se conservan y se re-afirman de forma idempotente)

### Requirement: Los contadores de posts se mantienen consistentes sin abortar la operación de negocio
Los contadores desnormalizados `community.posts.replies_count` y `community.posts.likes_count` SHALL reflejar el conteo real de filas en `community.replies` y `community.post_likes`, y su actualización MUST degradar sin abortar: un fallo al escribir el contador emite `RAISE WARNING` y deja que la operación de negocio (la fila de reply o de like) se persista igual. La fila transaccional es el hecho de negocio; el contador es una desnormalización cosmética que nunca justifica perder el dato del usuario.

#### Scenario: Responder un post persiste la reply e incrementa el contador
- **WHEN** un usuario autenticado inserta una fila en `community.replies` para un post existente
- **THEN** la inserción no lanza excepción, la fila queda persistida y `community.posts.replies_count` de ese post incrementa exactamente en 1

#### Scenario: Borrar una reply decrementa el contador
- **WHEN** se borra esa fila de `community.replies`
- **THEN** el borrado no lanza excepción y `community.posts.replies_count` decrementa exactamente en 1

#### Scenario: Dar y sacar like actualiza el contador
- **WHEN** un usuario inserta una fila en `community.post_likes` y luego la borra
- **THEN** ninguna de las dos operaciones lanza excepción y `community.posts.likes_count` sube exactamente 1 y vuelve exactamente a su valor previo

#### Scenario: Un fallo del contador no tumba la operación del usuario
- **WHEN** la actualización del contador falla por una condición inesperada (p. ej. la tabla de posts es inalcanzable)
- **THEN** el trigger emite `RAISE WARNING` en los logs de Postgres, la transacción no aborta y la fila de `community.replies` o `community.post_likes` queda persistida

#### Scenario: Recompute deja los contadores alineados con los datos reales
- **WHEN** se aplica la migración de corrección sobre una base donde los contadores quedaron desfasados durante el período roto
- **THEN** `replies_count` y `likes_count` de cada fila de `community.posts` quedan iguales al `COUNT(*)` de sus filas hijas en `community.replies` y `community.post_likes`
