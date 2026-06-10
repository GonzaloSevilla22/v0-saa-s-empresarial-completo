## ADDED Requirements

### Requirement: Tablas de comunidad viven en el schema `community`
Las 16 tablas del dominio no-ERP (`courses`, `course_modules`, `course_lessons`, `course_enrollments`, `course_progress`, `lesson_progress`, `posts`, `replies`, `post_likes`, `meetings`, `seguros`, `purchase_pools`, `landing_sections`, `fair_recommendations`, `fair_ai_tools`, `copilot_prompts`) SHALL residir en el schema Postgres `community`, no en `public`. La migraciÃ³n MUST usar `ALTER TABLE ... SET SCHEMA` preservando datos, FKs, Ã­ndices, triggers y polÃ­ticas RLS.

#### Scenario: Datos preservados tras la migraciÃ³n
- **WHEN** se ejecuta la migraciÃ³n de movimiento
- **THEN** cada tabla movida conserva exactamente sus filas previas (p. ej. `community.posts` = 4 filas, `community.courses` = 4 filas) y `public.<tabla>` ya no existe

#### Scenario: RLS sigue activa en el schema nuevo
- **WHEN** un usuario autenticado consulta `community.posts` vÃ­a la Data API
- **THEN** las polÃ­ticas RLS preexistentes se aplican igual que cuando la tabla estaba en `public`

#### Scenario: FKs cross-schema intactas
- **WHEN** se consulta `pg_constraint` tras la migraciÃ³n
- **THEN** las FKs `community.posts â†’ public.profiles`, `community.course_enrollments â†’ auth.users` y `community.fair_recommendations â†’ public.accounts` siguen definidas y vÃ¡lidas

### Requirement: Schema `community` expuesto en la Data API
El schema `community` SHALL estar configurado en los Exposed schemas de PostgREST con grants de `USAGE` para `anon`, `authenticated` y `service_role`, y privilegios por defecto equivalentes a `public` para tablas futuras.

#### Scenario: Query vÃ­a supabase-js con schema explÃ­cito
- **WHEN** el frontend ejecuta `supabase.schema("community").from("posts").select("*")`
- **THEN** PostgREST responde con las filas permitidas por RLS (no 404/406 de schema no expuesto)

#### Scenario: Embedding cross-schema funciona
- **WHEN** se consulta `posts` con `select("*, profiles(name), post_likes(user_id)")` vÃ­a `.schema("community")`
- **THEN** la respuesta embebe el nombre del autor desde `public.profiles` y los likes desde `community.post_likes`

### Requirement: Frontend y Edge Functions acceden vÃ­a `.schema("community")`
Todo acceso de cÃ³digo a las tablas movidas SHALL usar `.schema("community")` del cliente supabase-js. El insert de `analytics_events` (tabla ERP de `public`) en `use-posts` MUST permanecer sin schema explÃ­cito.

#### Scenario: Cero referencias residuales a public
- **WHEN** se busca `from("<tabla movida>")` sin `.schema("community")` en `frontend/` y `supabase/functions/`
- **THEN** no hay ocurrencias (las 10 ubicaciones frontend + `fair-advisor` migradas)

#### Scenario: Flujo de posts end-to-end
- **WHEN** un usuario crea un post, le da like y responde
- **THEN** las filas se insertan en `community.posts`, `community.post_likes` y `community.replies` y el feed se actualiza

### Requirement: El ERP no se acopla al schema community
Ninguna tabla del ERP (`sales`, `purchases`, `products`, `clients`, `expenses`, `branches`, etc.) SHALL tener FK hacia tablas del schema `community`, y el backend Python MUST seguir sin referenciar tablas movidas.

#### Scenario: VerificaciÃ³n de desacoplamiento
- **WHEN** se consulta `pg_constraint` buscando FKs desde tablas ERP hacia `community.*`
- **THEN** el resultado es vacÃ­o y la suite del backend Python pasa sin cambios
