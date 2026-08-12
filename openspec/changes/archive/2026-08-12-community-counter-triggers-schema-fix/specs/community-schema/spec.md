## ADDED Requirements

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
