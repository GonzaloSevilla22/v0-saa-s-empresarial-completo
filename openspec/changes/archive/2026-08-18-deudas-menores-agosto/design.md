# Design — deudas-menores-agosto

> Governance: **MEDIUM**. G1 toca la ruta de escritura de ventas/compras en producción, pero con sign-off explícito del PO (2026-08-18) y rollback de una línea. G2/G3/G5 son cambios de superficie y de código muerto. G4 es limpieza de datos acotada y re-derivada.

## Context

Cinco deudas independientes, agrupadas en un solo change porque ninguna justifica su propio ciclo. El único grupo con riesgo real es G1; el resto acompaña.

### Estado verificado en producción (`gxdhpxvdjjkmxhdkkwyb`, sólo SELECT, 2026-08-18)

| Hecho | Valor |
|---|---|
| `MAX(version)` en `supabase_migrations.schema_migrations` | `20260923000001` |
| Cuentas (`public.accounts`) | 35 |
| Filas en `account_feature_flags` | 26, **todas** `flag_key='sale_items_rpc_v2'`, **todas** `enabled=true`, **todas** creadas el 2026-06-10 |
| Cuentas sin fila de flag | **9** (camino legacy) |
| Ventas de agosto sin fila en `sale_items` | 58 (42 en cuentas sin flag, 16 en una cuenta **con** flag) |
| Todas esas ventas tienen `product_id NOT NULL` | sí (0 líneas de servicio) |
| `operation_created` huérfanos | **58** (41 `purchase`, 12 `sale`, 5 `expense`; todos del emisor legacy, mar–may 2026) |
| `operation_created` duplicados por clave de entidad | **0** hoy |
| `sale_items` con `account_id IS NULL` | 23 |
| `purchase_items` con `account_id IS NULL` | 18 |

### Mecanismo real del gating (G1)

```
rpc_create_sale_operation(...)          rpc_create_purchase_operation(...)
        │                                          │
        │  SELECT COALESCE(enabled,false) INTO v_flag_on
        │  FROM public.account_feature_flags
        │  WHERE account_id = current_account_ids() AND flag_key = 'sale_items_rpc_v2'
        │                                          │
   v_flag_on ──true──► rpc_create_sale_operation_v2 ──► header + sale_items + snapshots
        │              rpc_create_purchase_operation_v2 ──► header + purchase_items
        └──false──► cuerpo legacy inline ──► sólo header plano
```

- **Un único flag gobierna ventas y compras** — decisión explícita de la migración `20260616000003` ("un solo flag para ambos, simplicidad operacional"). Confirmado: `rpc_create_purchase_operation` lee el mismo `flag_key`.
- Definición vigente de ambos wrappers: `20260806000001_v3_snapshot_pattern.sql` (el `CREATE OR REPLACE` más reciente).
- Rutas que **no** dependen del flag: `rpc_quick_sale` / `rpc_confirm_sales_order` escriben `sale_items` siempre desde `20260721000001` (vía `_c29_confirm_order_core`).

## Goals / Non-Goals

**Goals:**

- G1: que **toda** cuenta —incluidas las que se creen mañana— escriba líneas y snapshots al registrar una venta o una compra, con rollback trivial.
- G2: que el estado de cliente que se ve y se edita sea uno solo, el calculado.
- G3: que `/clientes` abra mostrando primero a quien compró más recientemente.
- G4: que `analytics_events` no contenga eventos que apunten a operaciones inexistentes, y que las líneas legacy tengan su `account_id`.
- G5: que `adminAnalytics.ts` no exponga wrappers que nadie llama.

**Non-Goals:**

- **No** se dropea `clients.status` ni ninguna columna.
- **No** se agrega `NOT NULL` a `sale_items.account_id` / `purchase_items.account_id`.
- **No** se dropean las RPCs `get_admin_*` de la base.
- **No** se backfillean las 58 ventas históricas sin `sale_items` (ver OQ-2).
- **No** se arregla el hueco de la ruta de **edición** de operaciones (ver OQ-1).
- **No** se retira el header plano de `sales`/`purchases` (C-20 Grupo 10 sigue siendo otro change).

## Decisions

### D1 — El flag pasa de opt-in a opt-out: el default de ausencia es `true`

Activar las 9 cuentas faltantes con un `INSERT` resuelve el presente y **no** el futuro: toda cuenta creada después de la migración nacería sin fila y volvería al camino legacy, reabriendo la deuda en silencio. "Activar para todas las cuentas" sólo es cierto si el default cambia.

**Implementación** — dos pasos en la misma migración:

1. `CREATE OR REPLACE` de `rpc_create_sale_operation` y `rpc_create_purchase_operation` reproduciendo **byte a byte** el cuerpo vigente (`20260806000001`) salvo la resolución del flag, que pasa de "ausente ⇒ false" a "ausente ⇒ true":

   ```sql
   SELECT enabled INTO v_flag_on
   FROM   public.account_feature_flags
   WHERE  account_id = v_account_id AND flag_key = 'sale_items_rpc_v2'
   LIMIT  1;
   v_flag_on := COALESCE(v_flag_on, true);   -- ausencia = v2 (antes: legacy)
   ```

   Ojo: `SELECT ... INTO` sin fila deja la variable en `NULL`, no en `false`. El `COALESCE` va **después** del `SELECT`, no dentro — dentro seguiría devolviendo `NULL` porque no hay fila que coalescer. Éste es exactamente el bug que el código actual evita por accidente (`COALESCE(enabled,false)` dentro del `SELECT` no ejecuta nada cuando no hay filas, y `v_flag_on` queda `NULL`, que en el `IF` se comporta como falso).

2. UPSERT idempotente de una fila `enabled = true` por **cada** cuenta existente:

   ```sql
   INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
   SELECT a.id, 'sale_items_rpc_v2', true FROM public.accounts a
   ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = true;
   ```

El paso 2 no es redundante con el paso 1: materializa el estado para que sea auditable con un `SELECT` y, sobre todo, **mantiene el rollback en una línea** (si no existieran filas, apagar exigiría insertarlas).

*Alternativa descartada*: sólo el paso 2 (INSERT para las 9 cuentas, default sigue en `false`). Más chico, pero deja la trampa para cuentas futuras. *Alternativa descartada*: retirar el flag y llamar `_v2` directo. Elimina el kill-switch justo en el change que enciende el camino nuevo para 9 cuentas que nunca lo ejercitaron.

### D2 — Activación total con verificación estagiada por observación, no por lotes

El PO aprobó "todas las cuentas". Lo estagiado es la **verificación**, no la activación:

- **T0 (merge)** — la migración corre; se registra el conteo de cuentas con flag efectivo = 35/35.
- **T0 + 24 h** — consulta de solo lectura: de las ventas y compras **creadas después de la migración**, cuántas tienen `product_id NOT NULL` y **no** tienen fila de línea. Esperado: **0**.
- **Criterio de rollback**: cualquier venta o compra nueva sin su línea, o cualquier error de escritura atribuible a `_v2`, dispara el apagado.
- **Rollback (una línea, sin redeploy)**: `UPDATE public.account_feature_flags SET enabled = false WHERE flag_key = 'sale_items_rpc_v2';`. El `CREATE OR REPLACE` del paso 1 no necesita revertirse: con filas explícitas en `false` para las 35 cuentas, el default de ausencia deja de aplicar.

*Alternativa descartada*: activar primero la cuenta del PO. El mecanismo lo hace trivial (un `INSERT`), pero **9 de 9 cuentas legacy son de terceros** — la del PO ya está en el grupo de 26 desde junio. Un canario que ya está encendido no prueba nada.

### D3 — G1 va como migración, no como tarea manual post-merge

El UPDATE de datos es inseparable del `CREATE OR REPLACE` que lo acompaña (D1 paso 1); separarlos deja una ventana en la que el default nuevo aplica sin las filas explícitas que sostienen el rollback. Además el repo ya trata los cutovers de datos así, y la integración GitHub de Supabase auto-aplica: **la migración debe ser idempotente y reejecutable** (`ON CONFLICT DO UPDATE`, `CREATE OR REPLACE`).

### D4 — G4a define "huérfano" por re-derivación, nunca por lista de ids

Definición canónica, que la migración evalúa en el momento de correr:

> Un `analytics_events` con `event_name = 'operation_created'` es **huérfano** cuando su clave de entidad —`COALESCE(event_data->>'entity_id', event_data->>'sale_id', event_data->>'purchase_id', event_data->>'expense_id')`— no tiene fila en `sales`, `purchases` ni `expenses`.

El `COALESCE` es obligatorio porque conviven **dos formas de payload**: la moderna (`entity_id`, `entity_type`, `source`; 1060 filas) y la legacy del emisor retirado (`sale_id`/`purchase_id`/`expense_id` + `type`; 218 filas). Una definición que sólo mire `entity_id` no ve ningún huérfano.

Nota: `NOT EXISTS` contra las tablas cubre también el soft delete —una fila soft-deleted **existe**— así que sólo se borran eventos de operaciones borradas en duro. Es lo correcto: el evento de una operación soft-deleted sigue siendo un hecho ocurrido.

Duplicados: misma clave de entidad, más de una fila; se conserva la de `created_at` más antiguo. **Hoy ese paso es no-op (0 duplicados verificados)** y se incluye igual, porque el emisor legacy pudo producirlos y la migración debe ser correcta contra el estado real, no contra el estado observado el 18 de agosto. Ambos pasos loguean con `RAISE NOTICE '... % filas', v_n`.

La migración **no** hardcodea ni ids ni el conteo esperado (58): re-deriva. Los conteos exactos viven en el gate SQL, que los recalcula, no en la migración.

### D5 — G4b: `account_id` se hereda del padre, y la herencia es su propia prueba

```sql
UPDATE public.sale_items si SET account_id = s.account_id
FROM public.sales s WHERE s.id = si.sale_id AND si.account_id IS NULL AND s.account_id IS NOT NULL;
```

Idéntico para `purchase_items` ← `purchases`. Determinístico, idempotente por construcción (`IS NULL` en el `WHERE` hace que la segunda corrida afecte 0 filas). Sin `NOT NULL` (fuera de alcance): si alguna línea tuviera un padre con `account_id` nulo, quedaría nula y la migración no falla.

### D6 — G2: se quita la superficie, no el dato

`clients.status` desaparece de la UI en cuatro puntos, todos ya localizados:

| Archivo | Qué se saca |
|---|---|
| `frontend/components/forms/client-form.tsx` | el estado `status` (l. 36), su envío en `clientData` (l. 69) y el bloque `<Select>` "Estado" (l. ~246-261) |
| `frontend/app/(dashboard)/clientes/page.tsx` | `status: "activo"` de `toFormInitialData` (l. 40) |
| `frontend/hooks/data/use-clients.ts` | `status: "activo"` (l. 29) |
| `frontend/lib/types.ts` | `Client.status` pasa a opcional y queda marcado como legacy (l. ~416) |

El backend Python **ya no persiste** el campo (comentado en `page.tsx` l. 31-33), así que dejar de enviarlo no cambia ningún dato. La lista de `/clientes` ya muestra `ClientActivityBadge` con el estado calculado — no hay hueco visual que llenar.

*Por qué opcional y no eliminado del tipo*: `Client` lo consumen rutas que aún leen el registro crudo; volverlo opcional es el paso reversible, dropear el campo del tipo obliga a tocar consumidores fuera del alcance de este change.

### D7 — G3: el default cambia en el servidor, en los tres puntos que lo declaran

`ClientRepository.list_activity_page` **ya** soporta el orden y **ya** aplica `NULLS LAST` para `last_purchase_date` (l. ~206-207). Con `DESC`, Postgres pone los `NULL` primero por defecto, así que ese `NULLS LAST` explícito es justo lo que hace correcto el requisito — no se toca.

Cambian sólo los defaults: `backend/routers/clients.py` (`Query("name")` → `Query("last_purchase")`, `Query("asc")` → `Query("desc")`) y el default del parámetro homónimo en el repository. En el frontend, `use-client-activity.ts` (l. 159-160) inicializa el estado local con los mismos valores para que el control de orden refleje lo que el servidor devuelve; el orden lo sigue resolviendo la base. El desempate `, id ASC` ya existente mantiene la paginación estable.

*Alternativa descartada*: ordenar en el cliente. Rompe la paginación server-side.

### D8 — G5: se remueve el wrapper, se conserva la RPC

Cuatro exports sin ningún consumidor (verificado por grep en todo `frontend/`, excluyendo el propio archivo): `fetchActivationRate`, `fetchUmvRate`, `fetchPaidConversionRate`, `fetchInsightsBreakdown`, más la interfaz `AdminInsightsBreakdownEntry` que sólo el último usa. Las RPCs `get_admin_activation_rate`, `get_admin_umv_rate`, `get_admin_paid_conversion_rate`, `get_admin_insights_breakdown` **quedan en la base**: dropearlas es un riesgo distinto (ACLs, dependencias) y se anota como deuda aparte.

## Risks / Trade-offs

- **[El `CREATE OR REPLACE` de los wrappers reintroduce un bug al re-tipear un cuerpo de ~200 líneas]** → Se copia el bloque vigente desde `20260806000001_v3_snapshot_pattern.sql` y se cambian **sólo** las líneas del `SELECT ... INTO` + el `COALESCE`. La migración declara en comentario "cuerpo preservado byte a byte salvo la resolución del flag", igual que `20260907000001`. El gate de comportamiento (venta con flag efectivo escribe línea) corre en CI antes del merge.
- **[`DROP`/`CREATE` de función resetea ACLs]** → Se usa `CREATE OR REPLACE`, que las conserva. No se usa `DROP FUNCTION`. Si aun así cambiara la firma (no debería), `test_function_acl_gate.sql` lo detecta.
- **[9 cuentas nunca ejercitaron `_v2` en producción]** → `_v2` corre desde junio en 26 cuentas y tiene gate embebido; el riesgo real es de datos raros en esas cuentas (productos sin costo, unidades faltantes). Mitigación: la verificación T0+24h y el rollback de una línea.
- **[La integración GitHub de Supabase auto-aplica antes del `db push` de Actions]** → Ambas migraciones idempotentes y reejecutables. Un Actions en rojo no implica migración no aplicada: verificar `MAX(version)` en prod antes de concluir.
- **[G4a borra un evento que no era huérfano]** → El `DELETE` se acota a `event_name = 'operation_created'` y a claves sin fila en ninguna de las tres tablas. No toca `insight_generated`, `first_operation`, `umv_reached` ni `post_created`. Los KPIs que dependen de conteos (`operation_created` alimenta uso semanal y retención) bajan en 58 filas de mar–may 2026 — es la corrección buscada, no un efecto lateral.
- **[G3 cambia lo que el usuario ve al abrir `/clientes` sin que lo haya pedido]** → Es la decisión firmada del PO; el control de orden sigue disponible y el filtro por estado no se toca.
- **[El PR toca cinco áreas sin relación]** → Cada grupo es independiente y verificable por separado; el orden de tasks permite abortar G1 sin desarmar el resto.

## Migration Plan

Dos migraciones, `MAX(version)` real en prod verificado = `20260923000001`:

1. **`20260924000001_activate_sale_items_rpc_v2.sql`** — D1 paso 1 (`CREATE OR REPLACE` de ambos wrappers) + D1 paso 2 (UPSERT por cuenta). Rollback documentado en la cabecera del archivo.
2. **`20260925000001_cleanup_analytics_and_line_account_id.sql`** — D4 (huérfanos + duplicados, con `RAISE NOTICE`) y D5 (backfill de `account_id`).

Verificación post-merge (solo lectura, MCP): `MAX(version)` = `20260925000001`; 35/35 cuentas con flag efectivo; 0 `operation_created` huérfanos; 0 líneas con `account_id` nulo; y a las 24 h, 0 ventas/compras **nuevas** con producto y sin línea.

## Open Questions

- **OQ-1 (importante, fuera de alcance)** — `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` **no tocan `sale_items` / `purchase_items`** (verificado sobre `pg_get_functiondef` en prod). Editar una operación deja sus líneas ausentes o desactualizadas, **con el flag encendido o apagado**. Esto explica las 16 ventas sin línea de agosto en una cuenta que tiene el flag activo desde junio, y significa que G1 **no cierra por sí solo** la invariante `sale-line-items` §"toda venta con producto tiene su fila en sale_items". Por eso la verificación de D2 se limita a operaciones **creadas** después del cutover. ¿Se abre un change propio para la ruta de edición? Recomendación: sí, y con prioridad — es un hueco mayor que el que este change cierra.
- **OQ-2 (menor)** — las 58 ventas históricas de agosto sin `sale_items` seguirán sin líneas después de G1 (el flag sólo gobierna escrituras nuevas). La spec `sale-line-items` ya exige un backfill idempotente y existe el precedente de `20260721000001`. ¿Se backfillean en este change o en el de OQ-1? Recomendación: en el de OQ-1, junto con el arreglo que evita que se vuelvan a generar — backfillear sin tapar la fuente es limpiar con la canilla abierta.
- **OQ-3 (menor)** — las cuatro RPCs `get_admin_*` sin consumidor quedan en la base tras G5. ¿Se dropean en un change posterior o se cablean a algún panel? Sigue abierta desde la OQ-6 de `admin-kpi-refresh`.
- **OQ-4 (informativa)** — el paso de deduplicación de G4a es no-op hoy (0 duplicados). Se conserva por corrección; si el PO prefiere una migración mínima, puede retirarse.
