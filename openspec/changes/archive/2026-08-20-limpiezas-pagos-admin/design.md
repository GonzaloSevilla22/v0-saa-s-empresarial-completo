## Context

Tres limpiezas independientes que comparten migración y ventana de riesgo. La base vigente es toda la saga #415–#428 mergeada; `MAX(version)` verificado en el repo y en prod = `20261002000001` (`pos_banco_movimientos`), por lo que esta migración es **`20261003000001`**.

### Estado real capturado (prod `gxdhpxvdjjkmxhdkkwyb`, solo SELECTs, 2026-08-20)

**G1 — `sales_orders.payment_method`**

| Hecho verificado | Valor |
|---|---|
| Columna | `text NOT NULL DEFAULT 'other'` |
| CHECK | `sales_orders_payment_method_check` = `{cash, transfer, card, check, wallet, credit, other}` |
| Índices / policies / vistas / matviews que la usan | **ninguno** |
| Filas totales / sin `payment_method_id` | **120 / 0** |
| Filas con texto ≠ `'other'` y sin `payment_method_id` | **0** |
| Funciones que **escriben** la columna | `_c29_confirm_order_core` (UPDATE `payment_method = v_kind`), `rpc_accept_quote` (INSERT literal `'other'`), `rpc_promote_legacy_sale_to_order` (INSERT literal `'other'`) |
| Funciones que **leen** la columna | **ninguna** |
| Consumidores de **lectura** en código | `backend/repositories/sales_repository.py:121` (`pos_pm.kind = so.payment_method`) y `frontend/app/(dashboard)/ventas/ordenes/[id]/page.tsx:26/56/102-104` |
| `_journal_post_from_event` | lee `v_payload->>'payment_method'` — **el payload del evento, NO la columna** |
| Emisor del payload | `_c29_confirm_order_core` ya emite `'payment_method', v_kind`, con `v_kind` derivado de `payment_method_id` desde #421 |

La consecuencia clave: **el consumidor del asiento no toca la columna en ningún momento**. La premisa del brief de que había que agregar un campo nuevo al payload y un fallback para eventos históricos **no aplica** — el desacople ya lo hizo #421. La clave `payment_method` del JSONB de `events` se conserva tal cual, los eventos históricos quedan intactos y `_journal_post_from_event` no se modifica.

**G2 — RPCs `get_admin_*`** (`pg_proc` + `prosrc` de todo `public`/`community`/`analytics`/`cron`):

| RPC | Callers en la DB | Veredicto |
|---|---|---|
| `get_admin_activation_rate(timestamptz, timestamptz)` | ninguno | **DROP** |
| `get_admin_umv_rate(timestamptz, timestamptz)` | ninguno | **DROP** |
| `get_admin_paid_conversion_rate(timestamptz, timestamptz)` | ninguno | **DROP** |
| `get_admin_insights_breakdown(timestamptz, timestamptz)` | ninguno | **DROP** |
| `get_admin_community_interactions(timestamptz, timestamptz)` | `rpc_admin_business_kpis`, `rpc_admin_kpi_overview` | **VIVA — no se toca** |

Las 4 tienen ACL `authenticated=X` (nunca `anon`), por lo que **no figuran en la allowlist de `test_function_acl_gate.sql`** (esa allowlist solo lista los 5 helpers de RLS) y ese gate no requiere edición. Los gates que sí las enumeran y hay que podar son `test_kpis.sql` (§5 "all five admin RPCs must exist", §7 SECURITY DEFINER, §9 firma de `paid_conversion_rate`) y `test_kpis_edge_cases.sql`. En el frontend vivo ya no quedan llamadas (`adminAnalytics.ts` conserva solo un comentario explicativo y la llamada viva a `community_interactions`); `database.types.ts` es generado.

**G3 — ERRCODEs de 4 caracteres en funciones VIGENTES** (query sobre `prosrc` de prod, no sobre archivos):

| Función (firma vigente) | Códigos viejos | Códigos nuevos |
|---|---|---|
| `rpc_create_purchase_operation(p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid, p_cost_center_id uuid, p_payment_method_id uuid, p_bank_account_id uuid)` | `P400`, `P403`, `P404`, `P422` | `P0400`, `P0403`, `P0404`, `P0422` |
| `rpc_dashboard_kpi_summary(p_from, p_to, p_prev_from, p_prev_to timestamptz, p_branch_id uuid)` | `P400`, `P403` | `P0400`, `P0403` |
| `rpc_issue_credit_note(p_idempotency_key text, p_sales_order_id uuid, p_amount numeric, p_fiscal_document_id uuid)` | `P400`, `P403`, `P404` | `P0400`, `P0403`, `P0404` |
| `rpc_dashboard_channel_margin(p_from, p_to, p_prev_from, p_prev_to timestamptz, p_branch_id uuid)` | `P403` | `P0403` |
| `rpc_product_profitability(p_period_days integer)` | `P403` | `P0403` |

Ninguna otra función viva de `public`/`community`/`analytics` tiene códigos de <5 chars. El mapeo destino ya existe en `backend/core/errors.py`: `P0400→400`, `P0403→403`, `P0404→404`, `P0409→409`, `P0422→422` (con el override documentado `P0400→422` acotado a `bank_accounts`). Hoy esos `RAISE` de 4 chars explotan como `42704 unrecognized exception condition`, el mensaje original se pierde y `_map_postgres_error` los degrada a 500 genérico.

## Goals / Non-Goals

**Goals:**
- G1: dejar `payment_method_id → payment_methods.kind` como **única** fuente de la forma de pago de una orden, sin segunda columna que pueda desincronizarse.
- G2: sacar de la base 4 funciones `SECURITY DEFINER` sin consumidor, y dejar los gates coherentes con la realidad.
- G3: que los 5 `RAISE` afectados lleguen al cliente con su status HTTP y su mensaje reales, y que la regresión no pueda repetirse en silencio.
- Migración **idempotente** y re-ejecutable; gate de integridad transitivo verde.

**Non-Goals:**
- **No** se retira el parámetro `p_payment_method text` de `rpc_quick_sale`/`rpc_confirm_sales_order`/`_c29_confirm_order_core` — es contrato de entrada vivo del POS y alimenta el guard `payment_method_mismatch`. Retirarlo es una firma nueva y un change aparte.
- **No** se toca `_journal_post_from_event` ni ningún evento ya escrito en `events`.
- **No** se toca `get_admin_community_interactions` ni ninguna RPC admin viva.
- **No** se corrigen los archivos de migración históricos que contienen los códigos de 4 chars (nunca se editan migraciones aplicadas): el gate nuevo es la red permanente.
- **No** se agregan pantallas, rutas ni entradas de menú nuevas.

## Decisions

### D1 — La columna se dropea; el payload del evento no cambia
La clave `payment_method` del JSONB de `SaleConfirmed`/`PurchaseCreated`/`PaymentReceived`/`PaymentMade` **se conserva con el mismo nombre y la misma semántica** (el `kind` efectivo). Ya la deriva el emisor desde `payment_method_id`; la columna era un espejo persistido de ese mismo valor.

*Alternativa descartada*: renombrar la clave del payload a `payment_method_kind` y darle fallback al consumidor. Habría obligado a versionar el payload, a mantener dos ramas de lectura en `_journal_post_from_event` para siempre, y no compra nada: la clave ya significa exactamente lo que dice. La regla de reutilización antes que repetición aplica: no se inventa un campo nuevo para un dato que ya viaja correcto.

### D2 — El camino legacy resuelve el catálogo en vez de dejar la orden sin imputar
Hoy, cuando `_c29_confirm_order_core` recibe `p_payment_method` (texto) sin `p_payment_method_id`, hace `v_kind := COALESCE(p_payment_method, 'other')` y deja `payment_method_id = NULL`: la información del `kind` vivía **solo** en la columna TEXT. Ése es el único vector real de pérdida de información al dropear.

Decisión: en la rama `ELSE`, resolver la forma de pago viva y activa de la cuenta con ese `kind` (desempate por `sort_order`, luego `id`) y persistir su `payment_method_id`. Es determinístico hoy: 0 cuentas con dos métodos vivos del mismo `kind`.

*Alternativa descartada*: hacer la resolución **obligatoria** (`RAISE P0404 payment_method_unresolvable` si no hay match). Se descarta porque el `kind` **`check` no está sembrado en ninguna de las 35 cuentas** (el seed de `20260928000001` trae 6 de los 7 `kind`: cash, transfer, card, wallet, credit, other) mientras el CHECK del vocabulario sí lo admite. Un `RAISE` obligatorio convertiría una venta con cheque en un error duro. Si no hay match, la orden queda **sin imputar** — exactamente el estado que el reporte ya representa como "Sin especificar" y que la spec de `payment-method` ya contempla. Ver OQ-1.

### D3 — El JOIN del POS pasa de `kind` a `payment_method_id` (y se cura un fan-out latente)
`sales_repository.py` deriva hoy la forma de pago del POS con:

```sql
LEFT JOIN payment_methods pos_pm
       ON pos_pm.account_id = s.account_id
      AND pos_pm.kind       = so.payment_method
      AND pos_pm.deleted_at IS NULL
```

`kind` **no es único por cuenta**: nada impide crear dos métodos `transfer` desde el manager de Configuración. El día que un usuario lo haga, este `LEFT JOIN` devuelve 2 filas por venta y **duplica la operación en el listado**. Hoy no ocurre (0 cuentas con `kind` duplicado), pero es un bug latente, no una hipótesis. La migración a `ON pos_pm.id = so.payment_method_id` lo elimina por construcción, además de ser lectura exacta en vez de aproximada. Se conserva la regla D5 de `metodos-pago-operaciones`: sigue siendo derivación **de lectura**, cero escritura.

### D4 — Reescritura dinámica para los ERRCODEs, no `CREATE OR REPLACE` a mano
Se reutiliza literalmente el mecanismo de `20260624000001_fix_invalid_errcodes_5char.sql`: recorrer `pg_proc` filtrando por `prosrc ~ 'ERRCODE\s*=\s*''P(400|403|404|409|422)'''`, tomar `pg_get_functiondef()` como fuente de verdad, aplicar `regexp_replace` y re-ejecutar el `CREATE OR REPLACE`.

Ventajas sobre transcribir las 5 definiciones: no hay riesgo de desincronizar ~50k caracteres de cuerpo respecto de prod, `CREATE OR REPLACE` **preserva ACLs, owner, `SECURITY DEFINER` y `search_path`** (no hay `DROP`, por lo tanto no hay re-`GRANT`/`REVOKE` que reponer), y es idempotente por construcción: en la segunda corrida el `WHERE` no matchea nada.

### D5 — Un gate permanente, no solo una corrección puntual
La corrección de 2026-06-24 se perdió porque nada la sostenía: cada migración posterior que escribió un RPC nuevo copió el patrón viejo. Se agrega `supabase/tests/test_errcode_5char_gate.sql` al workflow `KPI_Validation.yml`, que falla el PR si alguna función viva de `public`/`community` tiene un `ERRCODE` custom de <5 caracteres. Es el mismo patrón de red permanente que `test_function_acl_gate.sql`.

### D6 — `test_pos_payment_vocabulary.sql` se reescribe, no se borra
Ese gate hoy afirma dos cosas: (1) `sales_orders_payment_method_check` y `payment_methods_kind_check` enumeran el mismo conjunto, y (2) el backfill de `payment_method_id` por `kind` funciona. Con la columna fuera, (1) pierde sentido (queda un solo CHECK, que es justamente el invariante que se quería) y (2) ya no existe. El archivo se reescribe para gatear el invariante que **sí** queda vivo: `payment_methods_kind_check` enumera exactamente los 7 `kind` y `sales_orders` ya no tiene columna `payment_method`. Borrarlo dejaría el vocabulario sin gate.

### D7 — Los INSERT de draft dejan de escribir el literal, no lo reemplazan
`rpc_accept_quote` y `rpc_promote_legacy_sale_to_order` insertan hoy `payment_method = 'other'` hardcodeado. No se los reemplaza por una resolución del catálogo: una cotización aceptada es un **draft** cuya forma de pago se decide recién en el confirm, y `rpc_promote_legacy_sale_to_order` promueve una venta legacy cuya forma de pago genuinamente se desconoce. `payment_method_id = NULL` es el registro honesto de "no decidido / desconocido", que es lo que el `'other'` literal estaba enmascarando.

## Risks / Trade-offs

- **[G1 toca el hot path del POS: un error en `_c29_confirm_order_core` rompe todas las ventas]** → La única edición del cuerpo es quitar `payment_method = v_kind` del UPDATE y agregar la resolución del `ELSE` (D2), ambas fuera de la ruta de stock/caja/outbox. Gates obligatorios: `test_confirm_core_integrity.sql`, `test_pos_confirm_payment_method.sql`, `test_pos_rpc_signatures.sql`, `test_pos_banco_movimientos.sql` y `test_pagos_cableados_restantes.sql` verdes antes del merge, más un smoke E2E de venta POS con `cash` y con `transfer`.
- **[Un consumidor de la columna no inventariado revienta post-drop]** → El inventario se hizo sobre prod (`pg_proc`, `pg_views`, `pg_indexes`, `pg_policies`, `pg_constraint`) **y** sobre el árbol de código, no sobre supuestos. Además la migración corre el drop **al final**, después de que las 3 funciones dejaron de escribirla, de modo que cualquier fallo previo aborta antes de tocar el schema.
- **[La resolución del `ELSE` (D2) imputa un `payment_method_id` que el usuario no eligió]** → Es resolución por `kind` dentro de la misma cuenta, no invención: el usuario ya declaró el `kind`, y el catálogo tiene exactamente un método vivo por `kind`. Si hubiera más de uno, gana el de menor `sort_order` (el sembrado). Si no hay ninguno, no se imputa nada.
- **[El `kind` `check` no tiene método sembrado en ninguna cuenta]** → Con D2 no rompe (queda sin imputar), pero significa que una venta con cheque pierde el `kind` al dropear la columna. Riesgo real pero nulo en datos: 0 ventas con `check` en prod. Se registra como OQ-1.
- **[Dropear una función que alguien llame por REST fuera del repo]** → Las 4 RPCs solo tienen `EXECUTE` para `authenticated`; un llamador externo tendría que ser una sesión logueada del propio producto. El frontend vivo no las llama y el backend tampoco. Aceptado.
- **[Cambiar un ERRCODE cambia el status HTTP que ve el frontend]** → Es exactamente el objetivo: hoy esos casos devuelven **500 genérico** (el `42704` no matchea nada en `_map_postgres_error`). Pasan a 400/403/404/422 con el mensaje del RPC. Ningún handler del frontend puede depender del 500 previo porque era indistinguible de un error real de servidor. Se revisan igualmente los handlers por mensaje de `use-purchases`/`use-sales` y del POS.
- **[La reescritura dinámica altera una función que no queríamos tocar]** → El `WHERE` filtra por el patrón exacto y la lista esperada son las 5 funciones de la tabla de arriba. La migración compara el conjunto reescrito contra esa lista y aborta si aparece una función inesperada.

## Migration Plan

Migración única `20261003000001_limpiezas_pagos_admin.sql`, idempotente, en este orden (el DROP de la columna va **último**, después de que nada la escriba):

1. **G3** — bloque `DO` dinámico de reescritura de ERRCODEs + gate interno de residuo cero.
2. **G2** — `DROP FUNCTION IF EXISTS` de las 4 RPCs con firma explícita `(timestamptz, timestamptz)` + gate interno que verifica que `get_admin_community_interactions` sigue existiendo.
3. **G1a** — `CREATE OR REPLACE` de `rpc_accept_quote` y `rpc_promote_legacy_sale_to_order` sin la columna en el INSERT.
4. **G1b** — `CREATE OR REPLACE` de `_c29_confirm_order_core` sin la columna en el UPDATE y con la resolución D2 en el `ELSE`.
5. **G1c** — `ALTER TABLE public.sales_orders DROP COLUMN IF EXISTS payment_method` (el CHECK `sales_orders_payment_method_check` cae automáticamente con la columna; se agrega un gate que verifica que efectivamente ya no existe).
6. **Gates finales de la migración** — columna ausente, CHECK ausente, 0 funciones con ERRCODE <5 chars, 4 RPCs admin ausentes, `community_interactions` presente.

Todos los `CREATE OR REPLACE` preservan firma → **no hay `DROP`+re-`GRANT`** en G1/G3. El único `DROP FUNCTION` es G2 y allí no se re-crea nada, por lo que no hay ACL que reponer; el `REVOKE` explícito de `anon`/`authenticated` no aplica a funciones que dejan de existir. `test_function_acl_gate.sql` sigue verde sin editarse.

**Apply**: `npx supabase db push` (NUNCA MCP `apply_migration`). El merge a `main` dispara build + deploy + migración automáticos.

**Rollback**: G3 y G2 son irreversibles en la práctica (nadie quiere volver a códigos rotos ni resucitar RPCs muertas). G1 se revierte con `ALTER TABLE ... ADD COLUMN payment_method text NOT NULL DEFAULT 'other'` + el CHECK + un `UPDATE ... SET payment_method = pm.kind FROM payment_methods pm WHERE pm.id = so.payment_method_id`, que reconstruye el 100% del valor desde `payment_method_id` — que es, precisamente, la demostración de que la columna era redundante.

## Open Questions

- **OQ-1 — El `kind` `check` no está sembrado en ninguna cuenta (35/35).** El vocabulario del CHECK admite `check` y `_journal_post_from_event` lo trata como método bancario, pero el seed de `20260928000001` solo trae 6 de los 7 `kind`. ¿Se agrega "Cheque" al seed (y un backfill para las 35 cuentas existentes), o se retira `check` del vocabulario? Fuera de alcance de este change; se propone al PO. Mientras tanto D2 lo deja sin imputar, sin romper.
- **OQ-2 — `frontend/lib/database.types.ts` queda desactualizado** respecto de las 4 RPCs dropeadas y de la columna retirada. Es un archivo generado (`supabase gen types`). ¿Se regenera en este PR o se deja para una pasada de tipos aparte? Propuesta: regenerar solo si el gate de tipos del frontend lo exige; si no, dejarlo — las entradas sobrantes son declaraciones de tipo inertes.
- **OQ-3 — `backend/tests/test_frontend_table_refs_gate.py` usa `get_admin_activation_rate` como texto de fixture** del escáner de referencias. No llama a la RPC (es un string de ejemplo), así que no rompe. ¿Se cambia por un nombre neutro para que nadie lo lea como "esta RPC todavía existe"? Cosmético.
- **OQ-4 — La worktree stale `.claude/worktrees/festive-ptolemy-72131e/`** conserva la versión vieja de `adminAnalytics.ts` con las 4 llamadas. No es árbol vivo y no entra en el PR, pero conviene que el PO sepa que existe antes de que alguien la confunda con código actual.
