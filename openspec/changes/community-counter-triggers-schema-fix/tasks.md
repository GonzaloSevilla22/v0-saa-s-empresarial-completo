## 1. Gate de regresión (RED primero)

- [ ] 1.1 Crear `supabase/tests/test_community_interactions.sql` con la cabecera de contexto del proyecto (qué verifica, por qué existe, patrón `text[]` + un solo `RAISE EXCEPTION` final, criterio de falsos positivos del assert de catálogo según design D5) y el setup de anchors sintéticos vía `handle_new_user` (usuario + post de prueba en `community.posts`).
- [ ] 1.2 Assert de comportamiento — replies: INSERT en `community.replies` no lanza excepción, la fila queda persistida y `community.posts.replies_count` del post ancla incrementa **exactamente** en 1; DELETE de esa reply decrementa **exactamente** en 1.
- [ ] 1.3 Assert de comportamiento — likes: INSERT en `community.post_likes` no lanza, la fila queda persistida y `likes_count` sube **exactamente** 1; DELETE lo devuelve **exactamente** al valor previo.
- [ ] 1.4 Assert de catálogo generalizado: recorrer `pg_proc` en los schemas `public` y `community` y verificar que ningún `prosrc` referencia `public.<tabla>` para ninguna de las 16 tablas movidas por C-23 (lista literal en el gate: `courses`, `course_modules`, `course_lessons`, `course_enrollments`, `course_progress`, `lesson_progress`, `posts`, `replies`, `post_likes`, `meetings`, `seguros`, `purchase_pools`, `landing_sections`, `fair_recommendations`, `fair_ai_tools`, `copilot_prompts`). Regex acotada con límite de palabra a ambos lados (`\mpublic\.<tabla>\M`) para no matchear `posts_count` ni `public.postscript`; el mensaje de fallo debe nombrar la función y la tabla concretas.
- [ ] 1.5 Assert de superficie: exactamente 1 definición por `proname` para `update_post_replies_count` / `update_post_likes_count` (anti-42725); ambos triggers (`on_post_reply_change` sobre `community.replies`, `on_post_like_change` sobre `community.post_likes`) existen, habilitados y apuntando a esas funciones; ni `anon` ni `authenticated` tienen `EXECUTE` sobre ellas.
- [ ] 1.6 Cleanup hijo→padre al final (likes → replies → posts → account_members/branches/cashboxes/accounts → profiles → auth.users), degradando con `RAISE NOTICE` si el contexto no lo permite, y bloque `EXCEPTION` de rescate best-effort. Seguir el patrón de `test_admin_kpis.sql`.
- [ ] 1.7 Verificar que el gate **falla en RED** contra el schema actual (sin la migración de la task 2): correr `psql -v ON_ERROR_STOP=1 ... -f supabase/tests/test_community_interactions.sql` y confirmar salida distinta de cero por 42P01 en el assert de replies/likes y por el assert de catálogo.

## 2. Migración de corrección

- [ ] 2.1 Crear `supabase/migrations/20260918000001_community_counter_triggers_schema_fix.sql` con cabecera que documente el bug (C-23 movió las tablas, `SET SCHEMA` preservó los triggers pero no reescribió las funciones), la evidencia de prod (`community.post_likes` = 0 filas con 13.082 index scans) y el rollback.
- [ ] 2.2 `CREATE OR REPLACE FUNCTION public.update_post_replies_count()` — misma firma (sin parámetros, sin `DROP` previo), `LANGUAGE plpgsql SECURITY DEFINER SET search_path = public`, con `UPDATE community.posts SET replies_count = replies_count ± 1` calificado (design D1/D2).
- [ ] 2.3 `CREATE OR REPLACE FUNCTION public.update_post_likes_count()` — idéntico tratamiento sobre `likes_count`.
- [ ] 2.4 Envolver el `UPDATE` de ambas funciones en `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ... END` (degrade-don't-fail, design D3), con un mensaje de warning que identifique la función, el `post_id` y el `SQLERRM`. Precedente: `analytics_emit_operation_event` (`20260914000001`).
- [ ] 2.5 Recompute idempotente: alinear `community.posts.replies_count` y `likes_count` con el `COUNT(*)` real de `community.replies` / `community.post_likes` (valor absoluto, no delta — design D7).
- [ ] 2.6 Re-afirmar ACLs de forma idempotente al final: `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon, authenticated` para ambas, con guard `CONTINUE WHEN to_regprocedure(...) IS NULL` (patrón drift-tolerante de `20260822000001`).
- [ ] 2.7 Gate inline en la propia migración (patrón `20260822000001`): tras aplicar, verificar que ambas funciones existen con 1 sola definición, que sus triggers siguen habilitados y que ningún `prosrc` de las dos referencia `public.posts`; `RAISE EXCEPTION` si no.

## 3. Verificación local y retiro del workaround

- [ ] 3.1 Resetear la base local (`npx supabase db reset` o equivalente del proyecto) aplicando toda la cadena de migraciones y confirmar que `20260918000001` se aplica sin error.
- [ ] 3.2 Correr `test_community_interactions.sql` contra la base local reseteada y confirmar que pasa **en verde** (transición RED→GREEN respecto de la task 1.7).
- [ ] 3.3 Retirar el workaround de `supabase/tests/test_admin_kpis.sql` (design D6): eliminar los tres pares `ALTER TABLE community.replies DISABLE/ENABLE TRIGGER on_post_reply_change` (seed, cleanup y bloque de rescate) y actualizar el comentario de las líneas ~163-168 para que registre que el bug quedó cerrado por este change en vez de declararlo "fuera de alcance".
- [ ] 3.4 Correr `test_admin_kpis.sql` contra la base local y confirmar que sigue pasando con el trigger habilitado (sus asserts de comunidad cuentan filas, no contadores).
- [ ] 3.5 Correr el resto de gates SQL del workflow (`test_kpis.sql`, `test_analytics_events.sql`, `test_function_acl_gate.sql`, `test_idempotency.sql`) para descartar efectos colaterales, en particular que el ACL gate siga verde tras la redefinición.

## 4. Cableado en CI

- [ ] 4.1 Agregar el paso `Run community interactions gates` en `.github/workflows/KPI_Validation.yml`, después del paso de `test_admin_kpis.sql`, con `psql -v ON_ERROR_STOP=1 ... -f supabase/tests/test_community_interactions.sql` y el comentario de contexto que usa el resto del workflow (por qué existe el gate y qué familia de bugs cubre).
- [ ] 4.2 Verificar en el PR que el job `validate-kpis` corre el paso nuevo y queda verde.

## 5. Verificación post-deploy (producción)

- [ ] 5.1 Tras el merge (la integración GitHub de Supabase auto-aplica la migración, y luego el `db push` de Actions la re-aplica como no-op): verificar en prod por lectura de catálogo que ambas funciones referencian `community.posts`, que hay 1 sola definición de cada una y que los dos triggers siguen habilitados.
- [ ] 5.2 Verificar en prod que `anon` y `authenticated` siguen sin `EXECUTE` sobre ambas funciones.
- [ ] 5.3 Verificar en prod que `replies_count` / `likes_count` de los posts existentes coinciden con el `COUNT(*)` de sus filas hijas (efecto del recompute).
- [ ] 5.4 Verificación funcional manual en la pantalla de comunidad (`frontend/app/(dashboard)/comunidad/page.tsx`, hook `frontend/hooks/data/use-posts.ts`): responder un post persiste la reply y el contador de respuestas sube; dar like persiste la fila y el contador sube; sacar el like lo revierte. **Sin superficie frontend nueva** — se verifica que la superficie existente vuelve a funcionar, en desktop y mobile.
- [ ] 5.5 Dejar registrada la línea base de actividad para poder distinguir "arreglado" de "sigue sin usarse": hoy `pg_stat_all_tables` da `n_tup_ins = 0` en `community.post_likes` (contador que incluye inserts abortados → cero intentos) y `pg_stat_statements` muestra 9 llamadas al listado contra `community.posts` desde el corte. Tras el fix, un `n_tup_ins` que crece con `n_live_tup` acompañándolo confirma escrituras exitosas; un `n_tup_ins` que crece con `n_dead_tup` acompañándolo indicaría que algo las sigue abortando.
