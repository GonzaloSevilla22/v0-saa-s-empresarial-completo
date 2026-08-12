## Context

`ALTER TABLE ... SET SCHEMA` mueve la tabla y **conserva los triggers colgados de ella**, pero no reescribe el cuerpo de las funciones que esos triggers ejecutan. C-23 (`20260615000001_community_schema_move.sql`) movió 16 tablas de `public` a `community` el 2026-06-15 y dejó dos funciones de contador apuntando a una tabla que dejó de existir.

Estado actual verificado en prod (`gxdhpxvdjjkmxhdkkwyb`, lectura de catálogo vía `supabase db dump` + `supabase inspect db table-stats`, 2026-08-12):

- `public.update_post_likes_count()` y `public.update_post_replies_count()` son `LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'` y ejecutan `UPDATE public.posts SET likes_count = likes_count ± 1 WHERE id = NEW/OLD.post_id` (idem `replies_count`). Definidas en `20260309000006_community_interactions.sql`, re-emitidas sin cambio de cuerpo por `20260517000002_fix_function_search_path.sql`.
- `public.posts`, `public.replies` y `public.post_likes` **no existen** en prod. `UPDATE public.posts` = 42P01 garantizado.
- Los triggers están vivos sobre las tablas ya movidas: `on_post_like_change AFTER INSERT OR DELETE ON community.post_likes` y `on_post_reply_change AFTER INSERT OR DELETE ON community.replies`. `20260822000001_revoke_trigger_only_fn_execute.sql` los verificó habilitados el 2026-08-01.
- Un trigger `AFTER` que lanza excepción aborta la transacción que lo disparó: la reply y el like **no se guardan**. Reproducido contra la base local de CI (`INSERT INTO community.replies` → 42P01).
- Confirmación directa por catálogo (`pg_proc` + `pg_trigger` vía SELECT, 2026-08-12): `prosrc` de ambas matchea `\mpublic\.posts\M` y **no** matchea `\mcommunity\.posts\M`; `proconfig = {search_path=public}`; `to_regclass('public.posts')` = `NULL`; ambos triggers con `tgenabled = 'O'`.

**Magnitud del daño consumado: baja — y la primera lectura fue equivocada.** Los estimados de `pg_class` (`inspect db table-stats`) están desactualizados (`last_analyze` y `last_autoanalyze` son `NULL` en las tres tablas) y sugerían `post_likes` = 0 filas. Los conteos exactos son `posts` = 5, `replies` = 4, `post_likes` = 2, con **cero filas creadas después del 2026-06-15** en las tres. Eso por sí solo no distingue "el bug las bloqueó" de "nadie las intentó", y el desempate es concluyente:

- `pg_stat_all_tables` da `n_tup_ins = 0` y `n_dead_tup = 0` para `community.post_likes`. Ese contador **incluye los inserts cuya transacción luego aborta** (la tupla se escribe físicamente y queda muerta), así que mide intentos. Cero intentos.
- La actividad se apagó **antes** del corte, no por él: último post 2026-05-08, última reply 2026-05-31, corte 2026-06-15. Los posts *no* dependen de estos triggers y también están en cero desde mayo.
- `pg_stat_statements`: la query de listado contra `"public"."posts"` (pre-corte) tiene 6.246 llamadas; su equivalente contra `"community"."posts"` tiene **9**. La pantalla de comunidad prácticamente no se abrió desde el movimiento de schema.
- Corolario: los 13.082 index scans sobre `post_likes_post_id_user_id_key` son lecturas de la era previa, no intentos de like fallidos.

Consecuencia para el encuadre del change: **no hay damnificados que recuperar**; sí hay una funcionalidad del plan PRO garantizadamente rota para el primer usuario que la use. Es un bug de corrección con gate de regresión, no un incidente de producción.

El universo del bug está cerrado por barrido sistemático del catálogo (139 funciones de `public` + schema `community`, contra las 16 tablas movidas): solo 4 funciones estaban rotas. `get_admin_community_interactions` y `rpc_admin_module_stats` ya quedaron corregidas por `20260917000001_admin_kpi_refresh.sql` (en main, commit `50ba7e5`, pendiente de aplicarse en prod). No hay vistas, políticas RLS ni otros objetos afectados.

Dato revelador del proceso: `supabase/tests/test_admin_kpis.sql` **ya conocía este bug** — hace `ALTER TABLE community.replies DISABLE TRIGGER on_post_reply_change` alrededor de su seed y su cleanup, con un comentario que lo declara "BUG DE PRODUCCIÓN preexistente y fuera de alcance de este change... reportado aparte". Este change es ese reporte, cerrado.

Restricciones: la integración GitHub de Supabase auto-aplica las migraciones al mergear, **antes** del `db push` de GitHub Actions → toda migración debe ser idempotente y drift-tolerante. Governance MEDIO.

## Goals / Non-Goals

**Goals:**
- Restituir responder-post y dar/sacar-like en producción (rotos desde 2026-06-15).
- Dejar afirmado el invariante de que `replies_count` / `likes_count` coinciden con el `COUNT(*)` real (hoy ya coinciden; el recompute es red de seguridad, no reparación).
- Que un fallo futuro de la desnormalización no vuelva a costarle al usuario su dato de negocio.
- Instalar una red de CI que atrape cualquier recaída de la **familia** del bug (referencias a `public.<tabla movida>` en el catálogo), no solo estas dos funciones.
- Retirar el workaround que `test_admin_kpis.sql` mantiene por este bug.

**Non-Goals:**
- Rediseñar el modelo de contadores (p. ej. reemplazar la desnormalización por una vista o un `COUNT(*)` en query). Fuera de alcance: el objetivo es reparar, no rearquitecturar.
- Cambiar el frontend. `frontend/hooks/data/use-posts.ts` ya usa `.schema("community")` correctamente en `addReply` y `toggleLike`, y documenta la dependencia del trigger. El bug es 100% del lado servidor.
- Tocar `get_admin_community_interactions` / `rpc_admin_module_stats` — ya corregidas por `20260917000001`.
- Auditar el resto de las 16 tablas movidas más allá del assert de catálogo automatizado (el barrido manual ya se hizo y dio limpio).
- Alterar los triggers, sus nombres o su wiring.

## Decisions

### D1 — `CREATE OR REPLACE` con schema calificado, sin `DROP FUNCTION` previo

Ambas funciones son `RETURNS trigger` **sin parámetros**, así que `CREATE OR REPLACE` no puede generar un segundo overload: no aplica el gotcha 42725 que obligó a un `DROP FUNCTION` explícito en `rpc_close_cash_session` (v3-api-standards). Se conserva la firma exacta, con lo cual los triggers siguen apuntando al mismo `oid` sin recrearse.

*Alternativa descartada*: `DROP FUNCTION ... CASCADE` + `CREATE` + recrear triggers. `CASCADE` borraría los triggers y obligaría a recrearlos, ampliando la superficie de error para cero beneficio; además resetea los ACLs (ver D4).

### D2 — Calificar `community.posts`, NO ampliar `search_path`

Se mantiene `SET search_path = public` y se escribe `UPDATE community.posts`. Lo que arregla el bug es la calificación explícita.

*Alternativa descartada*: `SET search_path = public, community`. Resolvería el nombre desnudo, pero por orden de schemas: la próxima vez que una tabla se mueva, el error volvería a ser invisible en el código y solo aparecería en runtime. Es exactamente el criterio D5 que `admin-kpi-refresh` ya fijó para las RPCs admin (`20260917000001`, líneas 349-352), y el assert de catálogo del gate (D5 de este change) presupone calificación explícita para poder detectar recaídas.

### D3 — Guard degrade-don't-fail alrededor del `UPDATE`

El `UPDATE` queda envuelto en `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ... END`.

Racional: `replies_count` / `likes_count` son una desnormalización cosmética; la fila de `community.replies` / `community.post_likes` es el hecho de negocio. La causa raíz del daño de estos dos meses no fue el error de schema en sí, sino que **un contador cosmético tenía poder de veto sobre la transacción del usuario**. Corregir solo el schema arregla el síntoma; el guard corrige la clase de fallo.

Precedentes del proyecto con este patrón exacto: `analytics_emit_operation_event` (`20260914000001`, telemetría) y el seed eager de `handle_new_user` (`20260812000001`, v3-provisioning-seed).

*Alternativa descartada*: solo calificar el schema, sin guard. Más minimal, pero deja la bomba armada: cualquier cambio futuro en `community.posts` (una constraint nueva, una policy, un rename) vuelve a poder tumbar la funcionalidad de comunidad entera.

*Riesgo aceptado y su mitigación*: ver R1.

### D4 — Re-afirmar los ACLs de forma idempotente

`CREATE OR REPLACE` **preserva** los ACLs (solo `DROP` + `CREATE` los resetea a `EXECUTE` para `PUBLIC` — el hallazgo sistémico documentado en `20260822000001`), así que los REVOKE de esa migración sobreviven. Aun así se re-aplica `REVOKE ALL ... FROM PUBLIC, anon, authenticated` al final, con guard `to_regprocedure(...) IS NULL → CONTINUE` para drift-tolerancia. Es un no-op barato y `test_function_acl_gate.sql` lo verifica en cada PR.

### D5 — Gate de regresión con assert de catálogo generalizado

Archivo nuevo `supabase/tests/test_community_interactions.sql` + paso en `.github/workflows/KPI_Validation.yml`, siguiendo el patrón del proyecto (`test_admin_kpis.sql`, `test_analytics_events.sql`): acumular fallos en `text[]`, un solo `RAISE EXCEPTION` al final para que `psql -v ON_ERROR_STOP=1` salga distinto de cero; anchors sintéticos vía `handle_new_user`; cleanup hijo→padre degradando con `RAISE NOTICE`.

Dos capas de aserción:

1. **Comportamiento** (camino feliz, conteos exactos): INSERT en `community.replies` no lanza y `replies_count` sube exactamente 1; DELETE lo baja exactamente 1; idem INSERT/DELETE en `community.post_likes` sobre `likes_count`. Los conteos exactos son lo que impide que el guard de D3 convierta una regresión futura en un no-op verde: si el contador deja de incrementar, el gate falla con un número incorrecto.
2. **Catálogo** (la red generalizada): ninguna función de `pg_proc` en `public` ni `community` referencia `public.<tabla>` para ninguna de las 16 tablas movidas por C-23.

Sobre falsos positivos del assert de catálogo: la regex se acota a `public.<tabla>` como referencia calificada con límite de palabra a ambos lados (`\mpublic\.<tabla>\M`), lo cual excluye nombres de columna (`posts_count`), sufijos (`public.postscript`) y prefijos. Los comentarios SQL dentro de `prosrc` **sí** cuentan como coincidencia; el criterio adoptado es deliberadamente estricto: si una función menciona `public.posts` aunque sea en un comentario, es documentación mentirosa y debe corregirse. Se documenta así en la cabecera del gate para que un futuro fallo por comentario no se lea como bug del gate.

*Alternativa descartada*: extender `scripts/ci/check_backend_table_refs.py` / `check_frontend_table_refs.py`. Esos gates escanean código fuente Python/TS; este bug vive en el catálogo de la DB, que ningún gate existente inspecciona. Es una cobertura complementaria, no duplicada.

### D6 — Retirar el `DISABLE TRIGGER` de `test_admin_kpis.sql`

Ese gate hoy deshabilita `on_post_reply_change` alrededor de su seed (líneas ~169-174), de su cleanup (~442-444) y de su bloque de rescate (~487-495) para no heredar esta rotura. Con el fix aplicado el workaround es innecesario, y mantenerlo enmascararía una regresión futura del mismo bug en la ruta que ese gate ejercita.

Verificado que es seguro: los asserts de `test_admin_kpis.sql` sobre comunidad (2.2, 2.6a, 2.6b, 2.6c) cuentan **filas** de `community.posts` / `community.replies` vía las RPCs admin, no leen `replies_count`. Habilitar el trigger no altera ninguno de esos números. El orden de migraciones lo garantiza: `20260918000001` se aplica antes de que corra cualquier test.

*Alternativa descartada*: dejar el workaround y solo actualizar su comentario. Barato, pero conserva un `DISABLE TRIGGER` que apagaría silenciosamente la detección de una recaída.

### D7 — Recompute idempotente en la misma migración

Tras redefinir las funciones, se recalcula `replies_count` / `likes_count` de `community.posts` desde el `COUNT(*)` real de sus hijos. Con 5 posts en prod el costo es nulo. Idempotente por construcción (asigna un valor absoluto derivado, no un delta), así que re-ejecutarla es inofensiva — requisito por la auto-aplicación de la integración GitHub de Supabase.

Aclaración de alcance: **hoy no hay drift que reparar**. Se verificó fila por fila en prod que los 5 posts tienen `replies_count` / `likes_count` iguales al `COUNT(*)` de sus hijos (3/3, 0/0, 0/0, 1/0, 0/0 replies y 2 likes en el primero). Es coherente con el hallazgo de que no hubo intentos de escritura post-corte: sin escrituras no hubo divergencia. El recompute se conserva igual porque es gratis y afirma el invariante en la misma migración que restituye el mecanismo que lo mantiene.

## Risks / Trade-offs

- **R1 — El guard degrade-don't-fail puede producir drift silencioso del contador** → Mitigado en dos frentes: (a) el gate de D5 asserta el camino feliz con conteos exactos, de modo que un contador que dejó de funcionar hace fallar CI con un número incorrecto en vez de pasar como no-op; (b) `RAISE WARNING` deja rastro en los logs de Postgres. El trade-off es deliberado: un contador desfasado es reparable con el recompute de D7; una reply perdida no es reparable.
- **R2 — El assert de catálogo puede fallar por una función legítima que menciona `public.<tabla>` en un comentario** → Criterio explícito (D5): se considera fallo real y se corrige el comentario. Documentado en la cabecera del gate para que el diagnóstico sea inmediato.
- **R3 — El recompute corre sobre datos de producción** → Es un `UPDATE` derivado de `COUNT(*)` sobre 5 filas, sin borrado ni pérdida posible. Además hoy es un no-op verificado: los contadores ya coinciden con el conteo real, así que no puede introducir un cambio de dato inesperado. Rollback trivial (volver a correr el recompute).
- **R4 — Al habilitar el trigger en `test_admin_kpis.sql` ese gate podría romperse por un efecto no previsto** → Se verificó que sus asserts de comunidad cuentan filas, no contadores. Si aun así fallara en CI, el diagnóstico es inmediato (el gate corre en el mismo PR) y la reversión es local a ese archivo.
- **R5 — Migración duplicada por la auto-aplicación de la integración GitHub de Supabase antes del `db push`** → Toda la migración es idempotente: `CREATE OR REPLACE`, `REVOKE` repetido es no-op, recompute a valor absoluto, guards `to_regprocedure` drift-tolerantes.
- **Trade-off asumido**: el fix no elimina la desnormalización, que seguirá exigiendo triggers correctos. Rearquitecturarla es explícitamente Non-Goal; el guard de D3 acota el daño de cualquier futuro fallo a "el número se ve mal" en lugar de "la funcionalidad no anda".

## Migration Plan

1. Se agrega `supabase/migrations/20260918000001_community_counter_triggers_schema_fix.sql`. Timestamp posterior al último local aplicado (`20260917000001_admin_kpi_refresh.sql`).
2. Al mergear el PR: la integración GitHub de Supabase auto-aplica la migración a prod, y después el `db push` de GitHub Actions la re-aplica (no-op por idempotencia). No se requiere migración ni deploy manual.
3. Verificación post-deploy (prod, lectura): las dos funciones referencian `community.posts`; exactamente una definición por `proname`; los dos triggers siguen habilitados; `anon` y `authenticated` sin `EXECUTE`; contadores de los 4 posts iguales al `COUNT(*)` de sus hijos.
4. Verificación funcional manual en la pantalla de comunidad (`frontend/app/(dashboard)/comunidad/page.tsx`): responder un post y dar/sacar like persisten y el contador se mueve. En desktop y mobile.
5. **Rollback**: re-aplicar el cuerpo previo de ambas funciones con `CREATE OR REPLACE` (restaura el estado roto — solo tiene sentido si el fix introdujera un problema peor, que no es previsible dado que hoy la ruta está 100% caída). Los contadores recomputados no requieren rollback: son el valor correcto bajo cualquiera de las dos versiones.

## Open Questions

Ninguna bloqueante. El alcance está cerrado por el barrido de catálogo, la corrección es de una sola migración y no hay dependencias externas ni decisiones pendientes del PO.
