## Context

`analytics_events` es la única fuente de la telemetría de producto. Schema vigente (`20250101000003_create_tables.sql:102-108`, sin cambios desde entonces):

```
analytics_events (
  id         uuid PK default gen_random_uuid(),
  user_id    uuid REFERENCES auth.users(id) ON DELETE CASCADE,   -- NULLABLE
  event_name text NOT NULL,
  event_data jsonb,
  created_at timestamptz NOT NULL default now()
)
```

Índices existentes: `(user_id)`, `(event_name)`, `(created_at)`, `(event_name, created_at)` (`20260227000100`), GIN sobre `event_data` (`20260228000100`). **No hay `account_id` ni `branch_id`.**

RLS (`20250101000004` + endurecido en `20260425000001` MEDIUM-1): INSERT sólo `auth.uid() = user_id` (se removió la excepción `user_id IS NULL`); SELECT sólo admins vía `is_admin()`.

Estado del path de escritura, verificado 2026-08-11:

| Operación | Ruta viva | ¿Emite telemetría? |
|---|---|---|
| Gasto | `use-expenses-query.ts` → `POST /expenses` → `expense_repository.py:22-37` (INSERT directo asyncpg) | **NO** |
| Venta | `sales_repository.py:218` → `rpc_create_sale_operation(...)` | **NO** |
| Compra | RPC de compras (C-19+) | **NO** |
| Gasto (legacy) | `frontend/lib/supabase/services.ts:70-93` | Sí — pero la UI ya no lo usa |
| Insight | `rpc_create_insight` (`20260629000001:133`) | Sí (`insight_generated` + `umv_reached`) |

Las RPCs que históricamente emitían (`20260228000101`, `20260228000102`, `20260228000302`, `20260424000004`) siguen existiendo en la base pero quedaron fuera del path vivo tras C-29 / C-19. Es decir: **hay emisores muertos y consumidores vivos**, exactamente el patrón que la regla "reutilización antes que repetición" busca evitar — cada ruta nueva de escritura tenía que acordarse de re-implementar la telemetría, y ninguna lo hizo.

Consumidores vivos: `rpc_admin_kpi_overview`, `rpc_admin_business_kpis` (activación = `COUNT(DISTINCT user_id) WHERE event_name='first_operation'`; MAU = `COUNT(DISTINCT user_id)` con cualquier evento en 30d), `rpc_admin_retention_30d` (cohortes por `first_operation`, retención = `operation_created` en la ventana `[+30d, +37d)`), `rpc_admin_weekly_usage_distribution` (días activos por semana vía `operation_created`), y la detección de UMV en `rpc_create_insight` (exige `EXISTS(operation_created)`).

Definición de producto (`knowledge-base/01_vision_y_objetivos.md:~47`): **activación** = registrar una venta, compra o gasto; **UMV** = una operación + un insight.

## Goals / Non-Goals

**Goals:**
- Que toda operación de negocio (venta, compra, gasto) emita `operation_created`, sin importar por qué ruta se escribió, hoy y en el futuro.
- Que la primera operación de cada usuario emita `first_operation` exactamente una vez, sin carreras.
- Que la telemetría nunca pueda tumbar una operación de negocio.
- Que el evento sea atribuible por tenant (`account_id`), no sólo por usuario.
- Dejar la decisión de backfill (OQ-2) aislada, de modo que la emisión sea aplicable sin esperar sign-off.

**Non-Goals:**
- Rediseñar el esquema de eventos (no se introduce un `event_type` enum, ni versionado de payload, ni tabla de catálogo). Es un revival, no una plataforma de analytics.
- Emitir eventos para otras entidades (clientes, productos, sesiones de caja, transferencias). Sólo las tres operaciones que definen activación.
- Corregir las definiciones de los KPIs admin (MRR fantasma `pro × 15`, "Usuarios Comunidad" que suma activos diarios, ventana de retención 30-37d) — eso es C-KPI-5 `admin-kpi-refresh` y depende de OQ-3/OQ-4.
- Superficie frontend: **no hay**. Es infraestructura de telemetría; los paneles admin que la consumen ya existen y no cambian de contrato.
- Realtime / streaming de eventos. `analytics_events` sigue siendo una tabla de append consultada por RPCs admin.

## Decisions

### D1 — Choke point: trigger de DB, no capa de aplicación

**Decisión**: una única función `public.analytics_emit_operation_event()` con triggers `AFTER INSERT FOR EACH ROW` en `sales`, `purchases` y `expenses`.

**Por qué**: el bug es estructural — cada nueva ruta de escritura tenía que recordar emitir. Cualquier solución en capa de aplicación (helper en `backend/services/`, decorator, middleware) sólo cubre las rutas que pasan por FastAPI, y hoy conviven cuatro: FastAPI, RPCs `SECURITY DEFINER`, el legacy de Supabase JS y SQL directo en migraciones/backfills. El trigger es el único punto por el que pasan todas por construcción.

**Alternativas consideradas**:
- *Helper en `backend/services/`*: no cubre `rpc_create_sale_operation` (la venta, la operación más importante, no pasa por Python para su escritura — el repo llama la RPC). Descartada.
- *Emitir dentro de cada RPC*: es re-duplicar la lógica en N lugares, precisamente lo que ya falló. Descartada.
- *Outbox / consumer asíncrono* (existe infra: `transactional-outbox`, Consumer 1..4): correcto para efectos con destino externo (email, journal entries), pero acá el destino es una tabla de la misma base y la latencia extra no compra nada; además el outbox introduce un modo de fallo nuevo (evento pendiente para siempre) sobre una métrica que necesita ser confiable. Descartada; se anota como camino de evolución si el volumen algún día lo justifica.

### D2 — `SECURITY DEFINER` + payload derivado de `NEW`, nunca de `auth.uid()`

La función es `SECURITY DEFINER` con `SET search_path = public`, y toma `user_id` de `NEW.user_id` (columna `NOT NULL` en las tres tablas desde `20250101000003`), **no** de `auth.uid()`.

**Por qué**:
- `auth.uid()` no es confiable en todas las rutas: el backend Python usa JWT-passthrough con `SET LOCAL ROLE authenticated` + claims (paso 1 de `v31-tenancy-pool-rls` ya aplicado, paso 2 pendiente de palanca), y los backfills/migraciones corren sin claims. `NEW.user_id` siempre está.
- `SECURITY DEFINER` es necesario para escribir en `analytics_events` bajo su política de INSERT (`auth.uid() = user_id`): un empleado que registra una venta cuyo `user_id` coincide pasaría, pero una RPC `SECURITY DEFINER` que crea la venta a nombre de otro usuario, o un job sin claims, no. Como `DEFINER` corre como owner de la tabla, la RLS no aplica y el emisor es uniforme.

**Riesgo de ACL**: la función es *trigger-only* — nunca se invoca como RPC. Se le aplica `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated` **en el mismo archivo** que la crea (gotcha del proyecto: `DROP`+`CREATE` resetea ACLs). PostgreSQL verifica `EXECUTE` sobre la función de trigger en el `CREATE TRIGGER`, no en cada disparo, así que revocarla después no rompe la emisión — pero eso es exactamente el tipo de suposición que hay que probar, no razonar: hay un gate que inserta un gasto con `SET LOCAL ROLE authenticated` y asserta que el evento igual se emite. Esto además la mantiene fuera del backlog de advisors 0028 (`test_function_acl_gate.sql`).

### D3 — degrade-don't-fail, obligatorio

Todo el cuerpo del emisor va dentro de `BEGIN … EXCEPTION WHEN OTHERS THEN RAISE WARNING 'analytics_emit_operation_event: %', SQLERRM; END;` y la función retorna `NEW` siempre.

**Por qué**: una venta perdida es un incidente de negocio; un evento perdido es un punto faltante en un gráfico. La asimetría es total y el precedente del proyecto es explícito — el seed de `handle_new_user` (`20260812000001`) envuelve el sub-bloque de provisioning igual, para que un fallo del seed nunca aborte el signup. Se replica ese patrón exacto.

**Trade-off aceptado**: un bug silencioso en el emisor degrada a "sin telemetría" en vez de fallar ruidosamente. Se compensa con `RAISE WARNING` (visible en los logs de Postgres) y con los gates de comportamiento que corren en cada PR.

### D4 — Deduplicación estructural, no por `EXISTS`

Dos índices únicos parciales:

```sql
CREATE UNIQUE INDEX CONCURRENTLY? NO -- dentro de migración transaccional: índice normal
  ux_analytics_first_operation_user ON analytics_events (user_id)
  WHERE event_name = 'first_operation';

  ux_analytics_operation_entity ON analytics_events (event_name, (event_data->>'entity_id'))
  WHERE event_name = 'operation_created' AND event_data ? 'entity_id';
```

y el emisor usa `ON CONFLICT DO NOTHING`.

**Por qué**: el patrón vigente en el código legacy y en `rpc_create_insight` es `IF NOT EXISTS (…) THEN INSERT`, que **corre carrera**: dos INSERTs concurrentes del mismo usuario (venta en el POS + gasto en otra pestaña, o dos requests del backend en el mismo instante) ven ambos "no existe" y emiten dos `first_operation`. Eso rompe la activación (`COUNT(DISTINCT user_id)` lo tolera) pero sobre todo rompe la retención: `rpc_admin_retention_30d` construye cohortes con **una fila por evento `first_operation`**, sin `DISTINCT` sobre `user_id` en `user_cohorts` — un usuario duplicado infla `cohort_size` y baja artificialmente la tasa de retención. El motor es el único árbitro sin carreras.

El segundo índice (por `entity_id`) hace idempotente el evento por operación: si una RPC legacy también emite, o si el trigger se dispara de nuevo tras un backfill, no hay doble conteo. Nota: las filas legacy usan las claves `expense_id`/`sale_id`/`purchase_id` y **no** `entity_id`, así que quedan fuera del índice parcial (no colisionan, no bloquean la creación); el emisor nuevo escribe siempre `entity_id`, además de conservar la clave específica por compatibilidad con lo que ya está en la tabla.

**Precondición**: prod puede ya tener `first_operation` duplicados (el path legacy usaba `EXISTS`). La migración limpia primero, de forma idempotente — conservar el `created_at` más antiguo por `user_id`, borrar el resto — y recién después crea el índice único. Si la limpieza no es posible, la creación del índice falla y aborta la migración: por eso van en ese orden y en la misma transacción.

**Alternativa considerada**: `pg_advisory_xact_lock(hashtext(user_id))` alrededor del `EXISTS`. Serializa correctamente pero no repara el histórico ni protege de escrituras que no pasen por el emisor. El índice sí. Descartada.

### D5 — Tenancy del evento: `account_id` como columna, no dentro de `event_data`

Se agrega `account_id uuid REFERENCES accounts(id) ON DELETE CASCADE` (nullable) más `CREATE INDEX (account_id, created_at)`. El trigger lo puebla desde `NEW.account_id` (presente en las tres tablas desde `20260606000003_account_id_columns.sql`).

**Por qué columna y no jsonb**: todo el sistema es multi-tenant por `account_id` y C-KPI-5 va a querer KPIs por cuenta (MAU por tenant, activación por cuenta, no por persona). Una columna indexada cuesta un `ALTER TABLE ADD COLUMN` nullable (instantáneo, sin reescritura de tabla en PG 11+) y evita tener que volver a tocar el schema. `event_data->>'account_id'` sería consultable vía el índice GIN existente, pero con peor plan para agregaciones por rango de fecha y sin integridad referencial.

**Por qué nullable y sin backfill obligatorio**: las filas históricas no tienen de dónde derivar la cuenta de forma confiable (el usuario pudo haber cambiado de membership), y ningún consumidor actual la lee. Es aditivo puro.

**No se agrega `branch_id`**: la sucursal es dimensión de negocio (la cubre `rpc_dashboard_kpi_summary` y C-KPI-3), no de telemetría de producto. Si aparece la necesidad, va en `event_data` sin migración.

### D6 — Granularidad: un evento por fila, también en cargas masivas

El trigger es `FOR EACH ROW`. Un INSERT de N filas emite N `operation_created` y a lo sumo un `first_operation`.

**Por qué**: `operation_created` mide **volumen de actividad** — es lo que consumen `rpc_admin_weekly_usage_distribution` (días activos) y la ventana de retención. Colapsar una carga a un solo evento subcontaría la actividad; emitir por fila la representa fielmente.

**Contexto verificado**: hoy **no existe** ningún importador masivo de ventas/compras/gastos. El único importador CSV del proyecto (`frontend/lib/import/`) carga **productos** (padre/variante/standalone) — no operaciones. Así que la decisión no tiene impacto inmediato; se toma ahora para que la semántica esté definida antes de que aparezca uno.

**Salvaguarda para el futuro**: el emisor incluye `event_data->>'source'` (`'trigger'` por defecto, `'backfill'` en el backfill). Si algún día se agrega un importador masivo y se quiere distinguir "50 gastos cargados de una" de "50 días de uso", el discriminador correcto es una marca de origen en `event_data` puesta por el importador vía GUC de sesión — **no** cambiar la granularidad. Se documenta como camino, no se implementa (YAGNI: no hay importador).

### D7 — El emisor legacy de `services.ts` se retira

`frontend/lib/supabase/services.ts:70-93` deja de emitir. Queda `createExpense` haciendo sólo el INSERT.

**Por qué**: dos emisores para el mismo hecho es la duplicación que originó el problema. El índice por `entity_id` no lo desduplicaría (usa clave `expense_id`), así que dejarlo produciría doble conteo en cualquier ruta que aún lo invoque. Retirarlo es una línea y consolida la responsabilidad en la DB.

### D8 — Los gates prueban comportamiento, no existencia

Los gates viven en `supabase/tests/test_analytics_events.sql`, siguiendo el patrón de `test_kpis.sql`: acumular fallos en `text[]` y un único `RAISE EXCEPTION` al final, corriendo con `-v ON_ERROR_STOP=1` desde `KPI_Validation.yml`.

Cinco comportamientos, con anchors sintéticos limpiados hijo→padre al final (patrón de `20260806000002` / `20260804000008`), degradando con `RAISE NOTICE` si el contexto no lo permite:

1. INSERT de gasto → existe `operation_created` con `entity_id` = id del gasto, `account_id` poblado.
2. Primer INSERT del usuario → existe `first_operation`; segundo INSERT → sigue habiendo exactamente uno.
3. Transacción abortada (`ROLLBACK` / savepoint) → cero eventos huérfanos. Prueba la atomicidad que da el `AFTER INSERT` en la misma transacción.
4. Emisor forzado a fallar → la operación sobrevive. Simulación determinística: `ALTER TABLE analytics_events ADD CONSTRAINT tmp_analytics_force_fail CHECK (event_name <> 'operation_created') NOT VALID` (un `CHECK NOT VALID` **sí** se aplica a filas nuevas), insertar la operación, verificar que existe y que no hay evento, y `DROP CONSTRAINT` en el mismo bloque.
5. INSERT ejecutado con `SET LOCAL ROLE authenticated` → el evento se emite igual (prueba que el `REVOKE` de D2 no rompe el trigger, y que la RLS de `analytics_events` no bloquea al `DEFINER`).

### D9 — La UMV se arregla sola, pero se explicita en el spec

`rpc_create_insight` ya emite `umv_reached` cuando existe un `operation_created` previo. Con el choke point vivo, la condición vuelve a cumplirse sin tocar esa función. Se registra como requirement MODIFICADO en la capability `insights` para que la dependencia quede escrita: la UMV **depende de un emisor de operaciones que esté vivo**, que es justamente lo que nadie notó cuando se migraron las rutas de escritura.

`umv_reached` conserva su dedupe por `EXISTS`, con la misma carrera teórica de D4. No se toca en este change: requiere dos insights concurrentes del mismo usuario en el mismo instante, con `rpc_create_insight` serializado además por el contador de plan (`UPDATE profiles SET insights_used = insights_used + 1`, que toma lock de fila). Se anota como deuda menor; el índice único parcial equivalente es de una línea si el PO lo quiere en el mismo paquete.

### D10 — Emisión y backfill se despliegan por separado

La migración de emisión (schema + función + triggers + dedupe + gates) es autónoma y no depende de OQ-2. El backfill vive en una **segunda migración**, con sus propias tasks marcadas como condicionales al sign-off del PO.

**Por qué**: la emisión es reparación de un defecto verificado y no admite discusión de producto; el backfill sí (¿son "reales" unas métricas históricas sintetizadas?). Acoplarlas dejaría la reparación esperando una decisión.

## Risks / Trade-offs

- **[El INSERT extra entra al hot path de la venta]** → Es 1-2 INSERTs a una tabla de append con índices ya existentes, en la misma transacción que ya escribe `sales` + `sale_items` + `branch_stock` + outbox. El `first_operation` sólo se intenta cuando el usuario no tiene ninguno (chequeo por índice único, no scan). Volumen real: decenas de operaciones por día en ~29 cuentas — irrelevante. Mitigación estructural: si algún día molesta, el camino es mover a outbox (D1, alternativa ya evaluada), no quitar el trigger.
- **[La creación del índice único falla porque prod ya tiene `first_operation` duplicados]** → La limpieza previa idempotente corre en la misma transacción y en el orden correcto. Si aun así falla, la migración aborta entera (no deja estado a medias) y el fallo es visible en Actions.
- **[Doble emisión desde las RPCs legacy que aún emiten]** → Cubierto por el índice `ux_analytics_operation_entity` sólo si esas RPCs escriben `entity_id`, que no lo hacen. Mitigación real: esas RPCs están fuera del path vivo (verificado); el riesgo se materializa sólo si alguien las vuelve a llamar. Se anota en el spec que el payload canónico incluye `entity_id` y que cualquier emisor debe usarlo.
- **[`SECURITY DEFINER` nuevo = superficie de seguridad]** → Es trigger-only, no toma parámetros del caller (todo sale de `NEW`), no devuelve datos, tiene `search_path` fijo y ACLs revocadas. No hay vector de inyección ni de IDOR: no lee nada que el caller no esté escribiendo él mismo.
- **[La telemetría falla en silencio por el `EXCEPTION` handler]** → Aceptado por diseño (D3). Compensado con `RAISE WARNING` y cinco gates de comportamiento en cada PR. La alternativa (fallar ruidoso) pone la telemetría en el camino crítico de la facturación de un comercio: inaceptable.
- **[Los paneles admin van a "saltar" el día del deploy]** → Sin backfill, activación/MAU/retención cambian de pendiente bruscamente y el histórico previo queda vacío. Es exactamente el contenido de OQ-2; se documenta para que el PO decida con el efecto a la vista, no a posteriori.
- **[La integración GitHub de Supabase auto-aplica antes del `db push` de Actions]** → Migración idempotente obligatoria: `ADD COLUMN IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`, limpieza de duplicados con `NOT EXISTS`. Un Actions rojo no significa migración no aplicada.

## Migration Plan

1. **`supabase/migrations/20260914000001_analytics_events_revival.sql`** (timestamp posterior a `20260913000001_critical_stock_by_branch.sql`), en este orden:
   1. `ALTER TABLE analytics_events ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id) ON DELETE CASCADE` + índice `(account_id, created_at)`.
   2. Limpieza idempotente de `first_operation` duplicados (conservar el más antiguo por `user_id`).
   3. Los dos índices únicos parciales de D4.
   4. `CREATE OR REPLACE FUNCTION public.analytics_emit_operation_event()` + `REVOKE ALL … FROM PUBLIC, anon, authenticated` en el mismo archivo.
   5. `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER` sobre `sales`, `purchases`, `expenses`.
   6. Bloque de gate auto-limpiante `DO $$ … $$` (patrón `20260812000001` Parte C) que degrada con `RAISE NOTICE` si el contexto no lo permite.
2. `supabase/tests/test_analytics_events.sql` + su paso en `.github/workflows/KPI_Validation.yml`.
3. Retiro de la emisión legacy en `frontend/lib/supabase/services.ts`.
4. **Sólo con sign-off de OQ-2**: `supabase/migrations/20260915000001_analytics_events_backfill.sql`.
5. Deploy por el pipeline normal (merge a main → Actions: build + Vercel + `db push`). **Nunca** con el MCP `apply_migration`.

**Rollback**: `DROP TRIGGER` en las tres tablas (la función y los índices son inertes sin triggers y pueden quedar). La columna `account_id` y los eventos ya emitidos **no** se revierten: son datos legítimos y borrarlos destruiría telemetría real. Si se llegó a correr el backfill, sus filas son identificables y borrables por `event_data->>'source' = 'backfill'`.

## Open Questions

- **OQ-2 (decisión del PO — bloquea SÓLO el backfill, no la emisión)**: ¿backfill histórico derivado de `sales`/`purchases`/`expenses`, o corte desde el deploy?

  - **Opción A — Backfill.** Se sintetiza un `operation_created` por cada operación histórica (`created_at` = el de la operación) y un `first_operation` por usuario en su operación más antigua, marcados `source: 'backfill'` y deduplicados contra los eventos legacy existentes (por `expense_id`/`sale_id`/`purchase_id`, además de `entity_id`).
    - *Beneficio*: `rpc_admin_retention_30d` recupera cohortes desde el origen — hoy no tiene ninguna cohorte de las rutas modernas, o sea que la retención es literalmente incalculable hasta 37 días después del deploy. Activación deja de mostrar cerca de cero para usuarios que sí operan. Los paneles de C-KPI-5 nacen con serie histórica.
    - *Costo*: bajo. ~29 cuentas, volumen de operaciones acorde a un MVP; es un `INSERT … SELECT` con `ON CONFLICT DO NOTHING`.
    - *Riesgo*: los eventos sintéticos **no son observaciones**, son derivaciones. Para `operation_created` la derivación es exacta (la operación existe, con su fecha). Para MAU introduce un sesgo conocido: los usuarios que sólo navegaron sin operar no aparecen — pero hoy tampoco aparecen, así que no empeora nada.

  - **Opción B — Corte desde el deploy.** Cero riesgo, cero trabajo. Costo: activación y retención quedan ciegas para toda la base existente; retención no produce un solo número útil hasta ~37 días después; y los usuarios actuales nunca van a tener `first_operation`, con lo cual quedan permanentemente fuera de toda cohorte — el agujero no se cierra con el tiempo, se congela.

  - **Recomendación: Opción A (backfill), con la marca `source: 'backfill'`.** La derivación es exacta y verificable contra las tablas operativas, el volumen es trivial, la marca deja separar observado de derivado en cualquier análisis futuro, y el borrado selectivo es una línea. El argumento decisivo es el de la Opción B: sin backfill, los usuarios actuales quedan fuera de las cohortes de retención **para siempre**, no sólo durante el período de transición.

- **OQ-3 (menor, no bloquea)**: ¿se agrega también el índice único parcial para `umv_reached` (D9), cerrando la misma clase de carrera en `rpc_create_insight`? Es una línea de migración y ningún cambio de lógica. Recomendación: sí, salvo que se prefiera mantener el change quirúrgicamente acotado a las tres operaciones.
