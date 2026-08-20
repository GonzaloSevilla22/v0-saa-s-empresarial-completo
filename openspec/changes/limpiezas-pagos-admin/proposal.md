## Why

Tres deudas técnicas quedaron abiertas al cerrar la saga de pagos (#415–#428) y ninguna tiene dueño: (1) `sales_orders.payment_method` TEXT quedó como columna **derivada** del `kind` del catálogo desde `pagos-cableados-restantes` (#421) — una segunda fuente de verdad viva que ya produjo un JOIN latente con fan-out; (2) cuatro RPCs `get_admin_*` de `20260430*` quedaron en la base **sin ningún consumidor** después de que `deudas-menores-agosto` G5 removiera sus exports del frontend; (3) cinco funciones VIGENTES en prod todavía lanzan `RAISE ... USING ERRCODE` con códigos de **4 caracteres**, que Postgres rechaza en runtime (`42704 unrecognized exception condition`), perdiendo el mensaje original y degradando el error a un 500 genérico en el backend.

Las tres son limpiezas: retiran superficie muerta o duplicada sin agregar funcionalidad. Se agrupan en un solo change porque comparten migración, gates y ventana de riesgo, y porque dejarlas sueltas es garantía de que nadie las tome.

## What Changes

### G1 — Retiro de `sales_orders.payment_method` (OQ-F) — **BREAKING** (columna)

- **BREAKING**: se dropea la columna `sales_orders.payment_method` TEXT (y con ella el CHECK `sales_orders_payment_method_check`). La forma de pago de una orden pasa a leerse **exclusivamente** por `payment_method_id → payment_methods.kind`.
- El **payload** del evento `SaleConfirmed` NO cambia: la clave `payment_method` del JSONB sigue existiendo y sigue transportando el `kind` efectivo — ya lo deriva el emisor desde `payment_method_id` desde #421. `_journal_post_from_event` **no se toca** y los eventos históricos de `events` quedan intactos (no hay campo nuevo ni fallback que escribir).
- Se cierra el hueco del camino legacy: cuando el confirm recibe un `kind` por texto sin `payment_method_id`, `_c29_confirm_order_core` SHALL **resolver** la forma de pago del catálogo de esa cuenta y persistir su `payment_method_id`, en vez de dejar la orden sin imputar. Si el `kind` no es resoluble, la orden queda sin imputar (comportamiento actual), sin abortar.
- Migran los dos únicos consumidores de **lectura** de la columna: el JOIN `pos_pm.kind = so.payment_method` de `backend/repositories/sales_repository.py` (pasa a `pos_pm.id = so.payment_method_id`, eliminando de paso un fan-out latente) y la página `ventas/ordenes/[id]` del frontend (pasa a mostrar el **nombre** de la forma de pago en vez de un binario "Efectivo/Otro medio" que ya no describe los 7 `kind`).
- Dejan de escribir el texto los tres sitios de **escritura**: el UPDATE de `_c29_confirm_order_core` y los INSERT literales `'other'` de `rpc_accept_quote` y `rpc_promote_legacy_sale_to_order`.
- El parámetro `p_payment_method text` de `rpc_quick_sale` / `rpc_confirm_sales_order` / `_c29_confirm_order_core` **se conserva** — es contrato de entrada del POS y alimenta el guard `payment_method_mismatch`. Este change retira la columna, no el parámetro.

### G2 — Baja de las 4 RPCs `get_admin_*` huérfanas (OQ-3 admin)

- Se dropean `get_admin_activation_rate`, `get_admin_umv_rate`, `get_admin_paid_conversion_rate` y `get_admin_insights_breakdown` (firma `(timestamptz, timestamptz)`), verificado en prod que ninguna función de la base, cron job, endpoint del backend ni pantalla del frontend las llama.
- **`get_admin_community_interactions` NO se toca**: sigue viva y la invocan `rpc_admin_business_kpis` y `rpc_admin_kpi_overview`.
- Se limpian los gates que las enumeran (`supabase/tests/test_kpis.sql` §5/§7/§9 y `supabase/tests/test_kpis_edge_cases.sql`), que hoy exigen su existencia y fallarían el PR.

### G3 — Normalización de los ERRCODE de 4 caracteres restantes

- Se corrigen los códigos inválidos de 4 chars a la convención `P04xx` de 5 chars en las 5 funciones VIGENTES afectadas, reutilizando el mecanismo dinámico ya probado en `20260624000001_fix_invalid_errcodes_5char.sql` (`pg_get_functiondef` + `regexp_replace` + `CREATE OR REPLACE`, que preserva ACLs y atributos).
- Se agrega un **gate permanente de CI** (`supabase/tests/test_errcode_5char_gate.sql`) que falla el PR si cualquier función viva de `public`/`community` vuelve a introducir un ERRCODE de menos de 5 caracteres — la corrección de 2026-06-24 se perdió porque nada la sostenía.

## Capabilities

### New Capabilities
<!-- Ninguna. Las tres son limpiezas sobre capabilities existentes. -->

### Modified Capabilities
- `payment-method`: se retira el requirement que declaraba `sales_orders.payment_method` como columna derivada conservada ("no se dropea en este change") y el que apoyaba la derivación de lectura del POS en el texto legacy; ambos pasan a apoyarse en `payment_method_id`. El vocabulario único deja de ser "dos CHECK idénticos" y pasa a ser un CHECK único (`payment_methods_kind_check`).
- `sales-order`: el agregado `SalesOrder` deja de tener el atributo `payment_method`; `confirm()` deja de persistir el texto y pasa a resolver e imputar `payment_method_id` también en el camino legacy; `rpc_promote_legacy_sale_to_order` deja de escribir `payment_method = 'other'`.
- `api-standards`: se agrega el invariante de plataforma de que todo ERRCODE custom SHALL tener exactamente 5 caracteres, sostenido por un gate de CI.

<!-- `journal-entry` NO lleva delta: sus requirements hablan de la clave `payment_method` del PAYLOAD del evento, no de la columna, y el payload no cambia. -->
<!-- G2 no lleva delta: ninguna spec vigente menciona las 4 RPCs huérfanas. -->

## Impact

- **DB (migración `20261003000001`)**: DROP de `sales_orders.payment_method` + su CHECK; `CREATE OR REPLACE` de `_c29_confirm_order_core`, `rpc_accept_quote` y `rpc_promote_legacy_sale_to_order`; `DROP FUNCTION` de las 4 RPCs admin; reescritura dinámica de ERRCODEs en `rpc_create_purchase_operation`, `rpc_dashboard_kpi_summary`, `rpc_dashboard_channel_margin`, `rpc_issue_credit_note` y `rpc_product_profitability`.
- **Backend**: `backend/repositories/sales_repository.py` (JOIN del POS). Sin cambios de schema Pydantic — `payment_method_name`/`payment_method_kind` de `SaleOut` ya vienen del catálogo.
- **Frontend**: `frontend/app/(dashboard)/ventas/ordenes/[id]/page.tsx`. Sin superficie NUEVA: no se agregan pantallas, rutas ni entradas de menú; la única pantalla tocada es una existente cuyo renderizado del método de pago mejora (nombre real en vez de binario). Verificación responsive + ambos temas sobre esa página.
- **Gates de CI**: `supabase/tests/test_pos_payment_vocabulary.sql` se reescribe (hoy compara dos CHECK y hace backfill por `kind`); `test_kpis.sql` y `test_kpis_edge_cases.sql` se podan; se agrega `test_errcode_5char_gate.sql` al workflow `KPI_Validation.yml`.
- **Datos**: cero backfill. Prod tiene 120/120 `sales_orders` con `payment_method_id` poblado y 0 filas con texto no derivable.
- **Riesgo**: G1 toca el hot path del POS (`_c29_confirm_order_core`) → governance MEDIUM. G2 y G3 son LOW.
