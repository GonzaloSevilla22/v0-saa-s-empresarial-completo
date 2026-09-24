## Context

Governance **CRÍTICO** (dominio fiscal: toca la RPC de emisión y las dos RPCs que anulan comprobantes), con tramos MEDIOS en el frontend. El PO aprobó el pedido el 2026-09-23 ("ok").

Estado de partida, re-medido en prod (sólo `SELECT`) el 2026-09-23 y otra vez el 2026-09-24:

| Hecho | Valor |
|---|---|
| Migraciones | 307, `max(version) = 20261060000001` → `20261061000001` libre |
| Agregado `min(uuid)` | no existe (`pg_aggregate`) → la promoción aborta con `42883` en su primer statement, antes incluso del short-circuit de idempotencia |
| md5(prosrc sin CR) vivos | promote `8c94b2a1…` (`20261003000001`) · emit `01862c30…` · edit `a657c54b…` · delete `c287c1b4…` (los tres de `20261060000001`) · helper #582 `975a60de…` |
| `sales_orders` | 127 = 124 `confirmed` (todas con `sale_operation_id`) + 3 `canceled`; **0** con comprobante; **0** desincronizadas de su venta (total a 2 decimales, cliente, cuenta) |
| Operaciones heterogéneas (cuenta / sucursal / cliente) | 0 / 0 / 0 |
| H2 — `sale_items` duplicados | 23 filas `sales` en 2 operaciones: la fórmula viva `Σ COALESCE(si.subtotal, s.total)` sobre `LEFT JOIN sale_items` las facturaría al doble |
| `sales.total` con más de 2 decimales | 52 filas → se compara y guarda a 2 decimales |
| Escritores de `sales` sobre operaciones EXISTENTES | sólo edición, borrado y `rpc_safe_delete_product` (sólo `product_id := NULL`); `_c29_confirm_order_core` y `rpc_create_sale_operation*` crean operaciones nuevas (`gen_random_uuid()`) |
| Relay del CAE | sólo toca `fiscal_documents` |

Tres defectos enlazados:
- **N2** — "Facturar" sobre una venta cargada a mano devolvía 500 desde PR #242 (2026-06-27): `MIN(uuid)`. Nadie lo vio porque ningún gate SQL ejecutaba la RPC y el test de backend mockeaba asyncpg.
- **N1** — arreglar N2 reabre la carrera que dejó declarada `venta-editable-sin-cae` (#582): la edición/borrado resuelven "¿hay orden que anular?" sin lock mientras la promoción crea la orden en OTRA transacción (el frontend hace dos requests: promover y emitir).
- **N3** — la edición re-apunta la orden al `operation_id` nuevo sin recalcular total, cliente ni líneas: "Volver a facturar" (#582 D5) y el "Facturar" de una venta del POS editada emiten por el importe VIEJO. Con N1 cerrado sólo por locks, el interleaving "promoción primero, edición después" reproduce exactamente este daño, así que N3 es parte del cierre de N1.

## Goals / Non-Goals

**Goals:**
- Que la promoción ejecute, sea determinística, idempotente, respete tenencia (`P0404`) y permisos (`P0401`), rechace filas heterogéneas (`P0422`) y siga siendo side-effect-free (stock, caja, cuenta corriente, banco, outbox).
- Que ningún interleaving de promoción, edición, borrado y emisión deje un `pending_cae` con importes viejos o sobre una operación sin filas, ni termine en `40P01`.
- Que la orden refleje siempre su venta (total, cliente, sucursal, líneas) y que la emisión se niegue a facturar una que no la refleja.
- Superficie `/ventas` de punta a punta: Facturar → Emitir comprobante → En trámite → Autorizado, con mensajes rioplatenses y sin texto crudo de Postgres.

**Non-Goals:**
- Unificar promoción y emisión en una sola RPC (ver D5).
- Registrar la creación de la orden promovida en `document_status_history` (preexistente, exige catálogo + matriz de roles).
- Limpiar los `sale_items` duplicados legacy o las 18 filas `sales` sin `operation_id` (candidatos aparte).
- Resolver la cuenta multi-tenant de la emisión (`current_account_ids() LIMIT 1`, preexistente).

## Decisions

### D1 — Cabecera por primera fila + homogeneidad, nunca agregado a ciegas (N2)
La promoción toma `account_id/branch_id/client_id` de la primera fila por `id` (`ORDER BY s.id LIMIT 1`) y un helper valida sobre TODAS las filas: alguna fila de otra cuenta → `P0404` (fail-closed, sin revelar existencia); más de un cliente o mezcla cliente/`NULL` → `P0422 operation_inconsistent`; ídem sucursal. *Alternativa descartada:* `(array_agg(x))[1]` o un agregado `min(uuid)` propio — ambos eligen un cliente arbitrario de una operación mezclada y facturarían a quien no corresponde.

### D2 — Importe canónico = la cabecera de `sales` (H2)
`total = round(Σ COALESCE(s.total, s.amount × s.quantity), 2)`, una línea de `sales_order_items` por fila de `sales` (`subtotal = total de la fila`), y de `sale_items` sólo producto/unidad/snapshots de UNA fila por venta (la del producto de la fila, `LATERAL … LIMIT 1`). Así `Σ líneas = total` siempre y las 2 operaciones con `sale_items` duplicados no se facturan al doble.

### D3 — Ancla de exclusión = las filas de `sales` de la operación (N1)
Lo único que existe ANTES de la orden son las filas de `sales`. Promoción, edición y borrado las toman **primero**, `FOR UPDATE`, en orden ascendente de `id`. Orden global único: `sales (id asc) → sales_orders → fiscal_documents → resto`. La emisión **no** toma `sales` (sólo lee): tomarla después de `sales_orders` invertiría el orden y abriría un deadlock real con la edición; tampoco hace falta, porque con la orden tomada ninguna edición/borrado de esa operación puede commitear (ambos pasan por el helper #582, que toma la orden).
*Alternativa descartada:* `pg_advisory_xact_lock` por `operation_id`. Un lock de fila lo respeta CUALQUIER DML sobre esas filas (también caminos que no conocen el protocolo); un advisory sólo excluye a quien se acuerda de pedirlo. Además la edición CAMBIA de `operation_id` (¿qué clave toma cada lado?) y #582 ya usa locks de fila, así que el orden global se describe con una sola regla.
Ausencia de deadlock, arista por arista: sólo promoción/edición/borrado esperan en C1 y sólo en su primer statement (sin nada tomado todavía) y en orden de `id`; en C2 el tenedor es la emisión (que nunca pide C1) o una ruta de la MISMA operación (excluida en C1); en C3 el helper #582 usa `NOWAIT` y el relay sólo tiene C3; en C4 lo único que se reordena es `sales` antes de `branch_stock`/`events` en edición y borrado, y ningún camino toma `branch_stock`/`products` y después filas EXISTENTES de `sales`.

### D4 — Un solo helper "la orden refleja su operación" (N3)
`_sales_order_sync_from_operation(orden, operación, cuenta)`, `SECURITY INVOKER`, cerrado a `anon`/`authenticated`: tenencia de la orden y de TODAS las filas, allow-list de comprobante (sin comprobante, `rejected`, `voided`; cualquier otro estado → `P0409 sales_order_has_live_invoice`), homogeneidad, total/cliente/sucursal/líneas. Lo usan la promoción (creación y replay) y la edición (al re-apuntar). Dos copias divergirían: es exactamente cómo la edición terminó re-apuntando con el total viejo.

### D5 — Unificar promoción + emisión: descartado
La RPC unificada igual necesita el lock de C1 contra edición/borrado, y el resync de la edición igual hace falta (las órdenes del POS y la re-emisión tras anular no pasan por la promoción). Rompe el flujo de dos pasos (preparar → emitir con punto de venta) y obliga a migrar `sale-operations-list.tsx`, `use-promote-to-order.ts`, `EmitInvoiceButton.tsx` (compartido con `/ventas/ordenes`), router/service/repository de promote y de emit, sus tests y dos specs. Suma superficie sin quitar ningún mecanismo.

### D6 — Guard fail-closed en la emisión + resync en el replay
`rpc_emit_sale_invoice` rechaza con `P0409 sales_order_out_of_sync` una orden sin `sale_operation_id`, sin filas, con otro total (a 2 decimales) u otro cliente — antes de numerar. Es el punto donde el daño se vuelve real; el resync lo mantienen dos caminos y cualquier camino futuro que desincronice una orden queda bloqueado en vez de facturar mal. La salida del usuario: tocar "Facturar" de nuevo → la promoción en replay resincroniza (si no hay comprobante vivo).

### D7 — Firmas, ACLs, COMMENT y ERRCODEs intactos
`CREATE OR REPLACE` con firmas idénticas (sin `DROP`, sin overload `42725`), ACLs re-emitidas idénticas, COMMENT vivos conservados (el gate asserta su md5). Ningún ERRCODE nuevo: `P0400/P0404/P0409/P0422` con tokens nuevos (`operation_inconsistent`, `operation_empty`, `sales_order_out_of_sync`, `sales_order_has_live_invoice`, `sales_order_sync_invalid_args`). Los hunks sobre los cuerpos vivos cuidan los candados de texto de gates existentes (`test_operacion_party_guard` 7-update-orden, matriz de roles 5b, `test_venta_editable_sin_cae` (1)).

### D8 — Borde del backend y del frontend
`operation_id: uuid.UUID` en el router (422 sin tocar la base). Un sqlstate sin mapear se re-lanza a `asyncpg_error_handler` (500 problem+json `internal_error`, sin texto del motor). En `/ventas` el segundo paso se llama "Emitir comprobante" (`EmitInvoiceButton.label`, default "Facturar" para `/ventas/ordenes`); `useEmitInvoice` invalida también `sales` para que la fila pase sola a "En trámite"; `FiscalDocumentBadge.onStatusChange` (en un `useRef`, para no re-suscribir el canal) refresca la fila al autorizar; si la emisión falla la fila vuelve a "Facturar". `translatePromoteError` deja de tratar cualquier "Conflicto" como "sin sucursal".

### D9 — Evidencia por ejecución, no por mock
Gate SQL que EJECUTA la promoción (`test_facturar_venta_manual.sql`), arnés de dos conexiones con 7 interleavings × 20 que asserta que la víctima ESPERÓ sobre la tabla correcta y bloqueada por la sesión correcta (`test_facturar_venta_manual_race.sh`), test de integración real del repositorio (`-m integration`), e2e hasta "Autorizado" con el stub en homologación, y 10 mutantes que los gates deben matar.

## Risks / Trade-offs

- [Contención: promoción, edición y borrado de la MISMA operación se serializan] → operaciones distintas no se tocan; cada request tiene `statement_timeout`.
- [Invariante `orden.total = Σ sales.total`: un descuento futuro a nivel orden en el POS lo rompería] → el guard lo frena fail-closed; revisar D6 antes de introducir descuentos de orden.
- [Edición parcial (subconjunto de `p_sale_ids`)] → preexistente; la orden sigue al subconjunto editado; el listado siempre manda la operación entera.
- [Líneas de servicio del POS se reconstruyen sin `name_snapshot`] → hoy 0 líneas de servicio en `sales_order_items` en prod.
- [Datos legacy: `sale_items` duplicados siguen dobles para los reportes que leen `sale_items`; 18 filas sin `operation_id` no facturables] → candidatos en `CHANGES.md`.
- [Edición con `items = []` sobre una operación con orden ahora aborta `P0400 operation_empty`] → antes dejaba una orden confirmada sobre una operación vacía (contra "Ausencia de órdenes confirmadas sin venta viva"); candidato `min_length=1` en el schema.
- [Realtime: el paso a "Autorizado" en pantalla depende de su entrega] → el refetch por `onStatusChange` y la recarga cubren la verdad del servidor.
- [Escritores futuros que creen órdenes para operaciones existentes sin tomar C1] → el guard D6 los detecta si desincronizan importe/cliente; el COMMENT del helper y el gate (0) nombran el contrato.

## Migration Plan

- Una migración, `20261061000001_venta_editable_vs_promocion_legacy.sql`: helper nuevo + 4 `CREATE OR REPLACE` sobre los cuerpos vivos + REVOKE/GRANT idénticos + un `DO` de introspección. Idempotente y segura en base vacía; sin backfill (0/124 órdenes desincronizadas, 0 comprobantes de venta). No se agrega a la cadena de reaplicación de `KPI_Validation.yml` (precedente `20261052`…`20261060`); su idempotencia se prueba aplicándola dos veces más con md5/ACL/COMMENT idénticos.
- Deploy: merge → `supabase db push` (nunca MCP `apply_migration`). Verificación post-merge sólo lectura (md5 de los 5 cuerpos = los del PR, helper INVOKER cerrado, 0 órdenes desincronizadas, promote sin `min(`) y humo del PO (venta a mano → Facturar → Emitir → Autorizado; y una edición de una venta preparada antes de emitir).
- Rollback: migración nueva que re-crea los 4 cuerpos previos (md5 de Context) y `DROP FUNCTION IF EXISTS public._sales_order_sync_from_operation(uuid, uuid, uuid)`, quitando la entrada del gate de ACLs y los pasos de CI en el mismo PR. Estado resultante: la promoción vuelve a estar rota (`42883`), estado seguro conocido (N1 inerte). Frontend/backend: `git revert` (aditivos; `/ventas/ordenes` no depende de ellos).

## Open Questions

Ninguna bloqueante. Quedan como candidatos (no decisiones de este change): historial de estado de la orden promovida, `sale_items` duplicados legacy, filas sin `operation_id`, `min_length=1` en la edición y la tabla de líneas de `/ventas` en 375 px (ver `CHANGES.md`).
