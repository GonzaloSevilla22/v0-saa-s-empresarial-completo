## Context

El pedido del PO y la brecha contra lo que existe están en `proposal.md` y en el explore copiado en `research/explore-presupuestos-remitos.md` (fuente de verdad del contexto; mapea todo lo existente con rutas y líneas). Este change cubre **sólo** `presupuestos-modulo`, el primero del split `presupuestos-modulo` → `remitos-venta` → `remitos-compra` (explore §4). Deja listas, en su capa canónica, las tres piezas que los remitos van a reutilizar: la numeración interna, el constructor de PDF comercial y el menú de compartir.

### Lo que ya existe (verificado en `main` `4f6041b6`, 2026-09-29)

| Pieza | Dónde | Estado relevante para este change |
|---|---|---|
| `quotes` / `quote_items` | `20260702000001_c29_quote_salesorder.sql:82-163` | Sin número, sin notas, `valid_until` opcional, `client_id` opcional. RLS con políticas `quotes_insert`/`quotes_update`/`quote_items_insert`/`quote_items_update` para `is_account_writer` (escritura directa del repo, "D3" de C-29). Sin política de `DELETE`. |
| Snapshots | `20260806000001_v3_snapshot_pattern.sql:91` | `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot`, `iva_rate_snapshot`, `snapshot_backfilled`. `quote_items.price` es `NUMERIC` sin escala desde `ventas-unidades-conversion` (D-F′, RN-24-bis). |
| Historial de creación | `20260807000001_v3_document_status_history.sql:395-425` | Disparador `quotes_record_status_creation` (`AFTER INSERT`): registra `NULL → status` con `created_by` como actor y **valida el rol** vía `record_status_transition`. |
| FSM | seed `20260807000001:177-184` + roles `20261048000001:403-408` + disparador `quotes_enforce_status_transition` (`20260816000001:158`) | `NULL→draft`, `draft→sent`, `draft\|sent→accepted`, `draft\|sent→rejected` (roles `seller, admin, owner`); `draft\|sent→expired` sin roles (sistema). `accepted`, `expired` y `rejected` son terminales. El disparador rechaza cualquier `UPDATE` de estado no catalogado, venga de donde venga. |
| `rpc_accept_quote` | viva: `20261045000001_operacion_party_guard.sql:1677-1820` | Valida tenencia, cliente, estado `draft\|sent` y vencimiento (día ART). Crea una `sales_orders` en `draft`, copia las líneas con sus snapshots, registra el historial de los dos documentos y emite `QuoteAccepted`. **No toma `FOR UPDATE`** sobre el presupuesto. |
| `_c29_confirm_order_core` | viva: `20261062000001_ventas_unidades_conversion.sql:1118-1583` | Núcleo de la venta: guards de pago, caja y cliente; idempotencia `operation_idempotency (user, 'sale', key)`; stock por sucursal normalizado (RN-24) con `P0409`; `sales`/`sale_items`/`stock_movements`; caja, cuenta corriente y banco; `SaleConfirmed`; historial `draft→confirmed`. `GRANT EXECUTE` a `authenticated` (entrada del allowlist del chequeo (4) del gate de ACLs). **Este change no lo toca.** |
| Backend | `backend/routers/quotes.py`, `services/quotes.py`, `repositories/quote_repository.py`, `schemas/quotes.py` | Alta por `INSERT` directo. El `INSERT … SELECT` de snapshots hace `LEFT JOIN products p ON p.id = …` **sin** `account_id`, así que copia nombre, SKU y costo de un producto de otra cuenta. Transiciones por `UPDATE` directo: sin historial y validadas contra un dict en Python que contradice el catálogo (no admite `draft→rejected`). `require_role(auth, ["user","admin"])` legacy. Listado sin paginar. `GET /quotes/{id}` devuelve el presupuesto **sin** líneas. |
| Frontend | `frontend/hooks/data/use-quotes.ts` | Hooks completos y huérfanos. No hay rutas. |
| PDF | `backend/services/receipts.py:189-264` (`build_sales_receipt_pdf`, stateless, datos del cliente) y `backend/services/fiscal/invoice_pdf.py` + `GET /fiscal/documents/{id}/pdf` | El segundo es el molde "documento persistido → PDF por id con tenencia". |
| Compartir | `frontend/components/ventas/sale-receipt-button.tsx:66-96` (`downloadBlob`, `sharePdf`), `:271-308` (WhatsApp); `frontend/lib/phone-utils.ts:34-106` (`normalizeWhatsAppPhone`, `buildWhatsAppUrl`); `frontend/lib/api/fiscal-invoice.ts` (fetch binario + RFC 7807) | Helpers embebidos en un componente de pantalla. |
| Configuración comercial | `accounts.default_payment_terms_days` + `GET/PATCH /settings/collections` + `rpc_set_default_payment_terms` + pestaña Cobranzas de `/configuracion` | Molde exacto para la validez por defecto. |
| Barrido diario | `cobranzas-overdue-digest-sweep` (`20261022000001:2219-2227`) | Molde de `cron.schedule` idempotente (`unschedule` + `schedule`). |

**Medido en prod (2026-09-29, sólo lectura):** 0 `quotes`, 0 `quote_items`, 0 órdenes con `source_quote_id`; `MAX(version) = 20261066000001`; 1.166 de 1.186 clientes con teléfono; 1 de 41 cuentas con `domicilio_comercial` en el perfil fiscal. `accounts` **no tiene** nombre propio: el nombre del negocio vive en `profiles.business_name` (dueño: `accounts.owner_user_id`) o en `fiscal_profiles`.

### Requisitos firmados por el PO (textuales)

1. «se crea un presupuesto para un cliente y se descarga para enviárselo o se envía por WhatsApp si está el número»
2. «si éste acepta el presupuesto que haya un botón que sea venta que si se toca se envía a venta automáticamente con todos los productos que tiene»
3. «cuando se crea el presupuesto no [baja stock]»
4. «quiero que tanto el remito como los presupuestos se puedan modificar». El presupuesto es **editable** (líneas, cliente, validez, notas) mientras no esté convertido en venta; una vez convertido es inmutable. Es un requisito, no una Open Question.

## Goals / Non-Goals

**Goals:**
- Circuito completo de presupuesto en la UI: crear → descargar o enviar por WhatsApp → editar → convertir en venta con un toque.
- Una conversión **atómica** que produzca una venta indistinguible de una del POS (stock, caja, banco, cuenta corriente, outbox, facturable).
- Escritura del presupuesto sólo por RPC, con tenencia, historial y numeración en el mismo camino para cualquier escritor.
- Tres piezas reutilizables en capa canónica, listas para los remitos: `internal_document_sequences`, `build_commercial_document_pdf` y `DocumentShareMenu`.
- Validez por defecto y vencimiento automático.

**Non-Goals:**
- Remitos de venta y de compra (changes propios; no se diseñan acá).
- Link público, aceptación online por el cliente, email.
- Pantalla propia de pedidos (`sales_orders`): el pedido intermedio es un detalle interno de la conversión.
- Reservar stock al presupuestar; alertas de stock que bloqueen.
- Precio de lista / listas de precios múltiples; IVA discriminado en el presupuesto (Aliadata emite Factura C).
- Migrar el comprobante interno de venta (`build_sales_receipt_pdf`, `SaleReceiptButton`) al constructor y al menú nuevos, y migrar el POS y `sale-form` al helper de alta de línea. Quedan como candidatos: tocarlos ensancha el diff sobre el hot path de venta sin que el pedido lo necesite.
- Conversión parcial (vender algunas líneas) o varias ventas desde un presupuesto.
- Vencimiento editable de la cuenta corriente desde el diálogo de conversión (la venta a crédito usa la cascada, como el POS; OQ-P11).
- Notificaciones de presupuesto aceptado o vencido (el evento `QuoteAccepted` ya existe; el consumidor no se toca).

## Decisions

### D1 — Modelo de datos: columnas nuevas en `quotes`, sin tabla nueva

Columnas aditivas en `quotes`:

| Columna | Tipo | Regla |
|---|---|---|
| `number` | `bigint NULL` + `UNIQUE (account_id, number)` | La asigna el disparador de D3. Nullable a nivel columna para no romper a los escritores históricos: en prod hay 0 filas y los gates insertan sin número. El disparador garantiza que ninguna fila nueva nazca sin número. |
| `notes` | `text NULL` | Condiciones, forma de entrega. Tope de 2.000 caracteres (`CHECK`). |
| `sent_at` | `timestamptz NULL` | Primera vez que pasó a `sent`. |
| `updated_at` / `updated_by` | `timestamptz NULL` / `uuid NULL` | Última edición. La UI avisa "modificado después de enviado" cuando `updated_at > sent_at`. |

`accounts.default_quote_validity_days integer NOT NULL DEFAULT 15 CHECK (BETWEEN 1 AND 365)`. Es una columna de privilegio en el sentido del gate `test_accounts_privilege_columns.sql`: nace sin `UPDATE` por PostgREST y se escribe sólo por `rpc_set_default_quote_validity` (D10).

- **Sin snapshot del teléfono ni del nombre del cliente.** El envío ocurre "ahora", con el teléfono vigente, y el PDF muestra los datos vigentes del cliente. El snapshot fiscal del receptor (`FiscalIdentitySnapshot`) es del comprobante fiscal, no del presupuesto.
- **Sin estado nuevo `converted`.** `accepted` pasa a significar "convertido en venta": desde este change, la UI sólo llega a `accepted` a través de la conversión (D6). El puente es `sales_orders.source_quote_id`, que ya existe.
  - *Rechazado*: agregar `converted` al `CHECK`, al catálogo de transiciones y a la FSM. Duplicaría el significado de `accepted` y obligaría a reescribir `rpc_accept_quote`, el enforcement y el seed.
- *Rechazado*: una tabla `quote_versions` para guardar cada edición. El PO pidió poder modificar, no versionar. El historial de estados más `updated_at`/`updated_by` alcanza. Si hace falta, queda como candidato.

### D2 — Escritura sólo por RPC; se retiran las políticas de escritura directa

Cuatro RPCs `SECURITY DEFINER` (`SET search_path = public`, `REVOKE … FROM PUBLIC, anon`, `GRANT EXECUTE … TO authenticated`):

- **`rpc_create_quote(p_client_id uuid, p_branch_id uuid, p_valid_until date, p_notes text, p_items jsonb) → jsonb`**
  - Resuelve la cuenta con `current_account_ids()`, igual que `rpc_quick_sale`.
  - Exige `is_account_writer`.
  - Cliente obligatorio y **vivo** de la cuenta (`P0404 client_not_found`, mismo literal que el guard de `operacion-party-guard`).
  - Sucursal opcional; si viene, debe ser de la cuenta y no estar cerrada (`P0404`/`P0422`).
  - `p_valid_until` NULL → `reporting_local_today() + default_quote_validity_days`. Si viene, debe ser ≥ hoy (ART) (`P0400 quote_valid_until_in_past`).
  - Por cada línea valida:
    - `product_id` NULL (línea de servicio) → exige una descripción (`description`, que se guarda en `name_snapshot`);
    - si hay producto: vivo, de la cuenta, y no padre con variantes (`P0404 product_not_found` / `P0400 product_is_parent`);
    - la unidad pasa por `_uom_normalize_quantity(product_id, unit_id, quantity)`, sólo para validar la compatibilidad (RN-24 (a)(b)(c)(f)); el resultado se descarta;
    - `quantity > 0`, `price ≥ 0`, `0 ≤ subtotal`.
  - `total = round(Σ subtotal, 2)`, calculado en el servidor (RN-24-bis). El total que manda el cliente se ignora.
  - Inserta `quotes` (el disparador asigna el número y registra `NULL→draft`, validando el rol) y `quote_items` con los snapshots en el **mismo** `INSERT … SELECT` desde `products` **filtrado por `account_id`**.
  - Devuelve el presupuesto con sus líneas.
- **`rpc_update_quote(p_quote_id uuid, p_client_id uuid, p_branch_id uuid, p_valid_until date, p_notes text, p_items jsonb) → jsonb`**
  - Reemplazo completo (D5).
  - Toma `SELECT … FOR UPDATE` sobre el presupuesto.
  - Guards: tenencia (`P0404`, idéntico para inexistente y ajeno), rol (D11), estado (D5).
- **`rpc_transition_quote(p_quote_id uuid, p_to_status text, p_reason text) → jsonb`**
  - Destinos admitidos desde la API: `sent` y `rejected`. `accepted` va sólo por la conversión y `expired` sólo por el barrido (`P0400 quote_transition_not_allowed`).
  - `FOR UPDATE`, `record_status_transition` (valida el catálogo y el rol, exige motivo si el catálogo lo pide) y `UPDATE`.
  - `sent` sobre un presupuesto que ya está en `sent` es un **no-op idempotente** (200, sin historial duplicado): lo usa el menú de compartir, que marca como enviado en cada descarga o envío.
  - El primer `sent` fija `sent_at`.
- **`rpc_delete_quote(p_quote_id uuid) → void`**
  - Sólo en `draft` (política de borrado por categoría, KB 05 §borrado, ítem 4: los borradores admiten hard delete). En otro estado: `P0409 quote_not_deletable`.
  - Borra `quote_items` (CASCADE) y `quotes`. El historial de estados queda como está, porque es append-only por estructura.

Se hace `DROP POLICY` de `quotes_insert`, `quotes_update`, `quote_items_insert` y `quote_items_update`. Quedan sólo las políticas de `SELECT`, que es el patrón de `sales_orders` (D2 de C-29).

- **Por qué**: los cuatro problemas de hoy tienen la misma causa, que la escritura es directa:
  - sin numeración;
  - snapshot cross-tenant del producto;
  - transiciones sin historial;
  - una política de transición duplicada en Python y distinta del catálogo.
  
  Pasar a RPC los cierra en un solo lugar, para cualquier escritor (FastAPI, PostgREST o una función futura).
- *Rechazado*: mantener las escrituras directas y corregir cada problema en el repositorio. El número y el guard de producto quedarían evadibles por PostgREST.
- **Checkpoint 0.4**: grep de escritores de `quotes`/`quote_items` en `backend/`, `frontend/`, `supabase/functions/` y `supabase/tests/`. Los gates que insertan con `session_replication_role` o como `postgres` no se ven afectados por RLS. Cualquier otro escritor se migra en el mismo PR.

**Payload de línea** (`p_items`, jsonb array): `{product_id, unit_id, quantity, price, subtotal, description}`. `description` es obligatoria sólo cuando `product_id` es NULL. El mismo esquema se valida en Pydantic (D12) y la RPC lo vuelve a validar (defensa en profundidad, igual que `rpc_quick_sale`).

### D3 — Numeración interna: `internal_document_sequences` + disparador

Capability nueva `internal-document-numbering`.

- **Tabla** `internal_document_sequences(account_id uuid, document_type text, last_number bigint NOT NULL DEFAULT 0, PRIMARY KEY (account_id, document_type))`.
  - `CHECK (document_type IN ('quote'))`. El remito lo amplía de forma aditiva: no se siembra un tipo que ninguna operación usa (misma regla que el seed de la FSM).
  - RLS: `SELECT` para los miembros; ninguna política de escritura; `REVOKE ALL … FROM anon`.
- **Helper** `_next_internal_document_number(p_account_id uuid, p_document_type text) → bigint`.
  - `SECURITY DEFINER`, sin `EXECUTE` para `authenticated`. Convención `_*`, cubierta por el chequeo (4) del gate de ACLs.
  - Implementación: `UPDATE … SET last_number = last_number + 1 … RETURNING`; si no hay fila, `INSERT … RETURNING 1`. Ese `INSERT` puede chocar con otro concurrente (`unique_violation`), y en ese caso se reintenta el `UPDATE` una vez.
  - Es el mismo patrón UPDATE-then-INSERT de `rpc_next_document_number` (spec `document-sequence`). Nunca un `INSERT … ON CONFLICT DO UPDATE`: el gotcha de validación de `CHECK` del proyecto.
- **Disparador** `BEFORE INSERT ON quotes`, `trg_quote_assign_number`: si `NEW.number IS NULL`, asigna `_next_internal_document_number(NEW.account_id, 'quote')`.
  - Es el paso obligado para cualquier escritor (RPC, gate o backfill), el mismo principio que `trg_guard_branch_decommission`.
  - Un número explícito se respeta, para las fixtures; el `UNIQUE` lo protege.
- **Sin huecos**: el lock de la fila de secuencia se toma dentro de la transacción de alta y se libera al commit. Un alta que falla revierte el incremento. Serializa las altas de presupuestos **de una misma cuenta**, que duran milisegundos y no tocan stock.
  - A diferencia de la numeración fiscal, el lock largo no es un riesgo: la de ARCA exige lock corto porque la transacción de venta es larga.
- **Formato visible**: `P-` + número con relleno a 8 dígitos (`P-00000012`). Una sola definición por lenguaje: `frontend/lib/internal-document-number.ts` (`formatInternalDocumentNumber('quote', n)`) y `backend/services/commercial_documents/numbering.py`, con un **fixture de casos compartido** (`backend/tests/fixtures/internal_document_number_cases.json`) que leen pytest y vitest, como el de `scale_layout_cases.json`. Sin prefijo por sucursal (OQ-P2).
- *Rechazado*: reutilizar `document_sequences`. Es fiscal: su clave es punto de venta + tipo de comprobante y sólo se incrementa vía `rpc_next_document_number` con guard de perfil fiscal. Mezclar un presupuesto con la numeración de ARCA es un error de dominio.
- *Rechazado*: una `SEQUENCE` de Postgres por cuenta. No es transaccional (deja huecos al revertir) y crearía N objetos de catálogo.

### D4 — FSM: la del catálogo, sin filas nuevas; el requirement de la spec se corrige

El catálogo ya tiene todo lo que este change ejecuta:

| Transición | Quién la ejecuta en este change |
|---|---|
| `NULL → draft` | `rpc_create_quote`, vía el disparador de creación |
| `draft → sent` | `rpc_transition_quote('sent')`, desde "Marcar como enviado" o automáticamente al descargar o compartir |
| `draft\|sent → accepted` | `_quote_accept_core`, dentro de la conversión |
| `draft\|sent → rejected` | `rpc_transition_quote('rejected', motivo opcional)` |
| `draft\|sent → expired` | `_expire_overdue_quotes` (sistema, actor NULL) |

No se agregan filas ni se cambian roles. El requirement "Agregado Quote con ciclo de vida" de la spec `quote` dice `sent → accepted | rejected | expired, draft → expired`, que contradice el seed (`draft → accepted` y `draft → rejected` existen y tienen roles). Se **modifica** para describir el catálogo vigente. Es un error de la spec, no un cambio de comportamiento.

- **Editar no cambia el estado.** Un `sent` editado sigue `sent`. La UI muestra "Modificado después de enviado — reenvialo" (`updated_at > sent_at`).
  - *Rechazado*: volver a `draft` al editar. No hay transición `sent → draft` en el catálogo, y agregarla haría el estado menos útil, porque perdería que el cliente ya lo vio.

### D5 — Edición: reemplazo atómico en `draft|sent`; `P0423` en los estados terminales

`rpc_update_quote`:

1. `SELECT … FROM quotes WHERE id = $1 AND account_id IN (SELECT current_account_ids()) FOR UPDATE`. Si no hay fila: `P0404 quote_not_found`.
2. Estado: `accepted` → `P0423 quote_locked_converted` ("el presupuesto ya se convirtió en la venta …; los cambios se hacen sobre la venta"). `expired` → `P0423 quote_locked_expired` ("duplicalo para cotizar de nuevo"). `rejected` → `P0423 quote_locked_rejected`. Es el mismo `P0423` "inmutable" que la venta con comprobante o dinero posteado (`operation-edit-context`), con un literal propio para que `operation-errors.ts` lo traduzca de forma accionable.
3. Si el presupuesto está en `draft|sent` pero su `valid_until` ya pasó (el barrido todavía no corrió), la edición se admite **sólo si** el `p_valid_until` nuevo es ≥ hoy. Es la vía para "ampliar la validez" (OQ-P5). Si no lo es: `P0400 quote_valid_until_in_past`.
4. Mismos guards de cliente, sucursal y línea que el alta (D2).
5. `DELETE FROM quote_items WHERE quote_id = $1` + `INSERT` de las líneas nuevas con snapshots **re-tomados** del maestro filtrado por cuenta. Luego `UPDATE quotes SET client_id, branch_id, valid_until, notes, total, updated_at = now(), updated_by = auth.uid()`.

- **Snapshots re-tomados**: la edición es un nuevo momento de cotización. El snapshot congela lo que se le prometió al cliente **en la última versión que se le mostró**.
  - *Rechazado*: conservar el snapshot de las líneas que no cambiaron. Obliga a emparejar líneas viejas con nuevas sin un id estable del carrito, y el beneficio es nulo: nombre, SKU y costo del maestro no son promesas al cliente, el precio sí, y el precio viene del payload.
- *Rechazado*: un `PATCH` parcial por línea. La UI edita el carrito completo (el mismo `QuoteForm` del alta), así que el reemplazo es el contrato natural. Con un solo camino de escritura se evitan divergencias.
- La spec `document-snapshots` ("Política de snapshot al editar una línea de operación") habla de operaciones confirmadas. El presupuesto no está confirmado, así que no aplica RN-100. No hay contradicción; se declara en el delta de `quote`.

### D6 — Conversión atómica: `rpc_convert_quote_to_sale`

**Refactor previo, sin cambio de comportamiento.** El cuerpo de `rpc_accept_quote` se mueve a un núcleo interno `_quote_accept_core(p_quote_id uuid, p_branch_id uuid) → jsonb`:

- `SECURITY DEFINER`, sin `EXECUTE` para `authenticated`; la convención `_*` lo mete en el chequeo (4) del gate de ACLs.
- Se parte del `pg_get_functiondef` **vivo** (checkpoint 0.3; comparar por líneas sin `\r`, por el gotcha CRLF).
- Dos cambios, y sólo esos:
  1. `SELECT … FOR UPDATE` en la lectura del presupuesto, para cerrar la carrera de doble aceptación;
  2. la sucursal pasa a ser `COALESCE(p_branch_id, v_quote.branch_id, c26_default_branch(...))`, con `p_branch_id` validado contra la cuenta y no cerrada (`P0404`/`P0422`).
- `rpc_accept_quote(p_quote_id)` queda como wrapper de una línea, `RETURN _quote_accept_core(p_quote_id, NULL)`, con la **misma firma** (`CREATE OR REPLACE`, así que las ACLs no se resetean), el mismo `COMMENT` vivo (regla: conservar el COMMENT al reescribir) y el mismo resultado.

**RPC nueva**:

```
rpc_convert_quote_to_sale(
  p_idempotency_key   text,
  p_quote_id          uuid,
  p_payment_method_id uuid,
  p_branch_id         uuid DEFAULT NULL,
  p_cash_session_id   uuid DEFAULT NULL,
  p_bank_account_id   uuid DEFAULT NULL,
  p_canal             text DEFAULT NULL
) RETURNS jsonb   -- {quote_id, quote_number, sales_order_id, operation_id, total, replayed}
```

Orden de ejecución (todo en una transacción):

1. `auth.uid()` no nulo. `p_idempotency_key` no vacía (`P0400`). `p_payment_method_id` obligatorio (`P0400 payment_method_required`): la conversión no usa el camino legacy por texto.
2. **Lock del documento de origen primero**: `SELECT … FROM quotes WHERE id = p_quote_id AND account_id IN (SELECT current_account_ids()) FOR UPDATE`. Sin fila: `P0404 quote_not_found` (inexistente y ajeno indistinguibles). `is_account_writer` → `P0401`.
3. **Idempotencia, después del lock**:
   - Si existe `operation_idempotency(user = auth.uid(), kind = 'sale', key)`, se busca la orden con `sale_operation_id =` esa operación **y** `source_quote_id = p_quote_id`.
   - Si existe, devuelve `{…, replayed: true}` sin escribir.
   - Si la clave existe pero pertenece a otra operación, `P0409 idempotency_key_conflict`: una clave reutilizada contra otro presupuesto no devuelve la venta de otro documento.
   - Leer la clave **después** del lock serializa el doble clic con la misma clave: el segundo espera, ve la clave y hace replay en vez de tropezar con `quote_invalid_state`.
4. **Líneas convertibles**: cada `quote_items.product_id` no nulo debe existir, pertenecer a la cuenta y estar vivo (`deleted_at IS NULL`). Si no, `P0404 quote_product_unavailable: <nombre del snapshot>` antes de escribir nada.
   - El núcleo de venta no filtra `deleted_at`: sin este guard, un producto dado de baja se vendería.
   - La UI lo traduce a "editá el presupuesto y quitá o reemplazá «X»".
5. `PERFORM`/`SELECT _quote_accept_core(p_quote_id, p_branch_id)`. Hace lo siguiente:
   - valida el estado `draft|sent` (`P0409 quote_invalid_state`) y el vencimiento (`P0409 quote_expired`);
   - valida el cliente;
   - crea la `sales_orders` en `draft` con `source_quote_id` y registra su historial `NULL→draft`;
   - copia las líneas con snapshots y **precio del presupuesto** (OQ-P3);
   - registra `quote draft|sent → accepted` y emite `QuoteAccepted`.
6. `SELECT _c29_confirm_order_core(p_idempotency_key, v_sales_order_id, NULL, p_cash_session_id, NULL, NULL, p_canal, p_payment_method_id, p_bank_account_id)`. Hace todo lo de una venta del POS:
   - guards de forma de pago, caja de la sucursal y crédito con cliente;
   - stock por sucursal normalizado, con `P0409`;
   - `sales`/`sale_items`/`stock_movements`;
   - caja, cuenta corriente (con vencimiento por cascada) y banco;
   - `SaleConfirmed`;
   - historial `draft→confirmed`.
   
   Tipo de comprobante NULL: la facturación es una acción posterior explícita (requirement vigente de `sales-order`).
7. Devuelve `{quote_id, quote_number, sales_order_id, operation_id, total, replayed: false}`.

Consecuencias:

- **Cualquier fallo revierte todo.** El presupuesto queda en su estado anterior (no queda `accepted` sin venta) y no queda ninguna orden `draft`. Stock insuficiente → `P0409` del núcleo, con el mismo literal que la UI ya traduce (`stock_insuficiente para producto <id>`).
- **La venta es facturable sin cambios.** Es una `sales_orders` `confirmed` con `sale_operation_id`, el mismo estado que deja el POS, así que `EmitInvoiceButton`/`POST /sales-orders/{id}/emit-invoice` y "Facturar" desde `/ventas` funcionan tal cual. Borrarla o editarla sigue las reglas vigentes de la venta del POS (`operation-delete-compensation`: cancela la orden). El presupuesto **queda `accepted`**, que es terminal: una venta borrada no "reabre" el presupuesto. Para volver a vender, se duplica (OQ-P12).
- **Orden de locks**: `quotes` (FOR UPDATE) → `products` (FOR UPDATE, dentro del núcleo, en orden de `sales_order_items.id`) → inserciones de `sales`/`sales_orders`. `quotes` no participa de ningún otro camino que tome los locks de venta, así que tomarla primero no invierte el orden global `sales → sales_orders → fiscal_documents` (la conversión crea filas, no bloquea filas existentes de `sales`). Se documenta junto a la regla global en `CHANGES.md`. `CLAUDE.md` no se toca en este change.
- **Roles**: la transición `quote → accepted` exige `seller|admin|owner`, y `sales_order draft→confirmed` admite además `cashier`. La intersección efectiva es `seller|admin|owner`, que es `CAN_QUOTE` (D11). Un cajero no convierte presupuestos: sí vende en el POS, pero la conversión compromete una cotización.
- **Grants**: `REVOKE ALL … FROM PUBLIC, anon`; `GRANT EXECUTE … TO authenticated`. `_c29_confirm_order_core` ya es invocable por `authenticated` (allowlist del chequeo (4)); llamarlo desde otra RPC definer no cambia su superficie.
- *Rechazado A2* (dos requests, `accept` + `confirm`): si el segundo falla (por ejemplo `P0409`), queda un presupuesto `accepted` con una orden `draft` invisible y sin reintento limpio.
- *Rechazado A3* (precargar el formulario `/ventas` y crear con `rpc_create_sale_operation_v2`): pierde el vínculo presupuesto→venta, rompe el requirement de `accept` (crea un `SalesOrder`) y duplica el camino. Si el cliente pidió cambios, se edita el presupuesto (D5) y después se convierte.
- *Rechazado*: modificar `_c29_confirm_order_core` para que acepte un `quote_id`. Es el hot path del POS y no hace falta tocarlo.

### D7 — Vencimiento: barrido diario + derivación al leer; validez por defecto por cuenta

- **Función** `_expire_overdue_quotes() → integer`:
  - `SECURITY DEFINER`, sin `EXECUTE` para ningún rol de aplicación.
  - Recorre `quotes WHERE status IN ('draft','sent') AND valid_until < reporting_local_today()`, en orden de `id`, con `FOR UPDATE SKIP LOCKED`.
  - Para cada uno, `record_status_transition(account_id, 'quote', id, status, 'expired', NULL, 'vencimiento automático')` (actor NULL: transición de sistema exenta de rol, que la spec `document-status-history` ya prevé en su escenario "Un proceso programado transiciona sin actor") y `UPDATE status = 'expired'`.
  - Idempotente: una segunda corrida no encuentra filas. Devuelve la cantidad vencida.
  - `SKIP LOCKED` evita esperar a una conversión en curso sobre el mismo presupuesto: si la conversión gana, el presupuesto queda `accepted` y el barrido no lo toca al día siguiente.
- **Cron**: `cron.unschedule` + `cron.schedule('quotes-expire-sweep', '5 3 * * *', …)`. Corre a las 03:05 UTC (00:05 ART), así que un presupuesto "válido hasta ayer" amanece vencido. Es el molde de `cobranzas-overdue-digest-sweep`.
- **Derivación al leer**: el read model devuelve `is_expired = status IN ('draft','sent') AND valid_until < reporting_local_today()`. La UI lo muestra como "Vencido" aunque el barrido todavía no haya corrido, y deshabilita "Venta" con la explicación. La conversión igual lo rechaza (`quote_expired`), como hoy.
- **Validez por defecto**: `accounts.default_quote_validity_days` (15) + `rpc_set_default_quote_validity(p_days integer)`:
  - `SECURITY DEFINER`;
  - guard **owner/admin** (`CAN_CONFIGURE`: es configuración de la cuenta, igual que las formas de pago);
  - rango 1..365 (`P0400`).
  
  Endpoints `GET/PATCH /settings/quotes`, que es el molde exacto de `/settings/collections`.
  - *Rechazado*: una tabla `quote_settings`. Es un solo valor y la Regla de Tres no se alcanza. La columna sigue el precedente de `default_payment_terms_days`.
- **Dónde se configura en la UI**: una tarjeta **"Presupuestos — validez por defecto"** dentro de la pestaña **Cobranzas** de `/configuracion`, debajo del plazo de pago. `/presupuestos` muestra "Validez por defecto: 15 días · Cambiar" con un enlace a `/configuracion?tab=cobranzas`.
  - Justificación: la pestaña ya reúne las **condiciones comerciales hacia el cliente** (plazo de pago); la validez de la cotización es de la misma familia.
  - La barra ya tiene 12 pestañas (`balanza-etiquetas-pos` sumó la 11ª, con una deuda de medición visual declarada). Una 13ª pestaña para un solo número es desproporcionada.
  - No se renombra la pestaña: `?tab=cobranzas` está enlazada desde otras pantallas.
  - OQ-P9 deja abierta la alternativa.

### D8 — PDF: `build_commercial_document_pdf` + `GET /quotes/{id}/pdf`

Capability nueva `commercial-document-pdf`. El módulo nuevo `backend/services/commercial_documents/` separa lo mismo que separa `factura-fiscal-imprimible`:

1. **Vista pura** `CommercialDocumentView` (dataclass): `kind` (`'quote'`; los remitos sumarán `'delivery_note'`), `title` ("PRESUPUESTO"), `number_label`, `issued_on`, `valid_until` (opcional), `status_stamp` (opcional: "VENCIDO", "RECHAZADO", "ACEPTADO"), `issuer` (`CommercialIssuer`), `recipient` (nombre, CUIT/DNI si existe, teléfono, domicilio si existe), `lines` (descripción, cantidad con símbolo de unidad, precio unitario, subtotal), `show_prices` (siempre `True` para el presupuesto; es la opción que el remito necesita, OQ-R2 del explore), `total`, `notes` y `legend`.
2. **Construcción** `build_quote_view(quote, lines, client, issuer, today)`: función pura. Resuelve la etiqueta del número (D3), el sello por estado (incluido `is_expired`) y el símbolo de la unidad de cada línea.
3. **Render** `build_commercial_document_pdf(view) → bytes`:
   - `fpdf2`, fuentes core, latin-1 (reutiliza `_latin1`, `_format_amount` y `_format_unit_price` de `services/receipts.py`, sin copiarlas);
   - misma paleta (`SLATE`/`EMERALD`/`GRAY`) y misma diagramación de tabla que `build_sales_receipt_pdf`;
   - salto de página con la cabecera de la tabla repetida;
   - leyenda al pie.
   
   Sin lógica de negocio.

- **Emisor** (`resolve_commercial_issuer(account_id)`, repositorio con filtro por cuenta):
  - nombre: `fiscal_profiles.nombre_fantasia` → `fiscal_profiles.razon_social` → `profiles.business_name` del `accounts.owner_user_id` → "Mi Negocio";
  - razón social y CUIT si hay perfil fiscal;
  - domicilio comercial si está cargado;
  - teléfono y email del perfil del dueño.
  
  **Nunca bloquea**: un presupuesto no es un comprobante fiscal, y en prod sólo 1 de 41 cuentas tiene domicilio. Lo que falta, se omite.
  - *Rechazado*: exigir los datos fiscales como la Factura C (`issuer_data_incomplete`). El 97 % de las cuentas no podría presupuestar.
- **Leyenda**: "Presupuesto — documento no válido como factura. Precios válidos hasta el dd/mm/aaaa." La segunda oración va sólo si hay `valid_until`.
- **Endpoint** `GET /quotes/{id}/pdf?disposition=inline|attachment`:
  - router sin lógica; service con las reglas; repositorio con `account_id` explícito además de la RLS (regla dura desde el incidente #446).
  - 200 `application/pdf` para **cualquier estado**. Un presupuesto rechazado o vencido se puede volver a descargar, con su sello.
  - Otra cuenta o inexistente → 404 `quote_not_found`, mismo cuerpo RFC 7807.
  - `disposition` inválido → 422. Sin sesión → 401.
  - Nombre de archivo: `presupuesto-P-00000012.pdf`.
  - Lectura para cualquier miembro de la cuenta (el listado ya es de lectura libre).
- *Rechazado*: generalizar `build_sales_receipt_pdf` y migrarle el comprobante interno de venta. Es candidato. Hoy el comprobante de venta se arma en el cliente (payload stateless) y mezclarlo ensancha el diff sin necesidad.
- *Rechazado*: HTML + `window.print()`. No produce un archivo para adjuntar en WhatsApp.

### D9 — Compartir: `DocumentShareMenu` + helpers extraídos

Estado actual:

- `sale-receipt-button.tsx` tiene embebidos `downloadBlob` y `sharePdf`.
- `lib/api/fiscal-invoice.ts` tiene embebido el fetch binario con manejo de 401 y RFC 7807.

Se extraen a la capa canónica **sin cambiar su comportamiento**:

- `frontend/lib/document-share.ts`: `downloadBlob(blob, fileName)`, `sharePdf(file, text, title)` y `openWhatsAppText(phone, text)` (envuelve `buildWhatsAppUrl` y devuelve si había número válido).
- `frontend/lib/api/document-pdf.ts`: `fetchDocumentPdf(path, params) → Blob | null` (encabezados de `getAuthHeaders`; `null` si `redirectedOnUnauthorized`; `DocumentPdfError(code, message)` desde el RFC 7807).
- `sale-receipt-button.tsx` y `fiscal-invoice.ts` pasan a importarlos. Sus tests existentes son el safety net y deben seguir verdes sin cambios.

**Componente** `frontend/components/shared/DocumentShareMenu.tsx`. Props: `fetchPdf(disposition)`, `fileName`, `shareText`, `shareTitle`, `clientPhone`, `onShared?()`. Tres acciones:

- **Ver / Imprimir**: abre la pestaña **dentro del gesto** del usuario (Safari iOS) y le carga el blob `application/pdf` cuando llega. Si el navegador la bloquea, descarga. Mismo flujo que "Ver / imprimir factura".
- **Descargar PDF**.
- **Enviar por WhatsApp**:
  - en el celular, share nativo con el **archivo**;
  - en escritorio, descarga del PDF + `wa.me/<teléfono>?text=` con un texto corto y un toast "Adjuntalo en el chat que se abrió";
  - sin número válido, `wa.me/?text=` con el aviso "no hay número de WhatsApp registrado para este cliente". Es el mismo texto del comprobante de venta.

Descargar y WhatsApp (no "Ver") llaman a `onShared`. En el presupuesto, `onShared` dispara `rpc_transition_quote('sent')` si el presupuesto está en `draft` (no-op idempotente si ya está `sent`) e invalida la query.

- *Por qué "Ver" no marca enviado*: mirar el PDF propio antes de mandarlo es el uso más común, y marcarlo mentiría el estado.

**Texto corto de WhatsApp**: "Hola {nombre}, te envío el presupuesto P-00000012 por $ 12.345,00, válido hasta el 14/10/2026. {negocio}". Función pura `buildQuoteShareText` en `lib/quote-share.ts`. Si falta el nombre, sin saludo personalizado.

- *Rechazado*: link público firmado. Es una capability nueva con governance ALTA (ruta pública, token, revocación, exposición de datos del cliente) y queda para un change posterior (OQ-P6).

### D10 — UI de `/presupuestos`

- **Sidebar**: `{ title: "Presupuestos", href: "/presupuestos", icon: FileText }` (ícono de `lucide-react`; `FileText` ya se usa en el repo) en *Operaciones*, entre "POS — Venta Rápida" y "Compras". Sin gate de plan (D13). Breadcrumb en `breadcrumb-nav.tsx`: `"/presupuestos": "Presupuestos"`, `nuevo`: "Nuevo", `editar`: "Editar". La ruta queda protegida por defecto (`lib/auth/route-access.ts` protege todo `app/(dashboard)` por exclusión).
- **`/presupuestos`** (listado):
  - `GET /quotes?status=&q=&page=&page_size=` paginado `{items,total,page,pages}` (estándar `api-standards`).
  - Filtros: pestañas de estado (Todos, Borradores, Enviados, Aceptados, Vencidos, Rechazados) y búsqueda por nombre de cliente o número (acepta "P-12", "12" o "00000012").
  - Columnas: número, cliente, fecha, válido hasta (con "Vencido" en rojo si `is_expired`), total y estado (`QuoteStatusBadge` con tokens semánticos). En móvil, tarjetas.
  - CTA "Nuevo presupuesto" (visible con `CAN_QUOTE`), estado vacío con explicación y CTA, y el aviso de validez por defecto (D7).
- **`/presupuestos/nuevo`** (acepta `?cliente=<id>` y `?duplicar=<id>`) y **`/presupuestos/[id]/editar`**: `QuoteForm` (D12).
- **`/presupuestos/[id]`** (detalle):
  - Cabecera: número, estado, cliente (enlace a la ficha), teléfono, fechas y "Modificado después de enviado" si corresponde.
  - Líneas en sólo lectura, total, notas.
  - Si está `accepted`: "Venta generada" con enlace a `/ventas/ordenes/<sales_order_id>` (ruta existente) y el estado de su comprobante fiscal.
  - Historial de estados (lectura de `document_status_history`, que ya tiene RLS de lectura; el endpoint de detalle lo incluye).
  - Acciones según estado y rol:

| Estado | Acciones |
|---|---|
| `draft` | Editar · Compartir (`DocumentShareMenu`) · **Venta** · Rechazar · Duplicar · Eliminar |
| `sent` | Editar · Compartir · **Venta** · Rechazar · Duplicar |
| `draft\|sent` vencido | Editar (para ampliar la validez) · Compartir · Duplicar · Rechazar. "Venta" deshabilitada con "Vencido el …: ampliá la validez o duplicalo" |
| `accepted` | Compartir · Duplicar · Ver venta |
| `expired` / `rejected` | Compartir · Duplicar |

- **Ficha del cliente** (`/clientes/[id]`): botón "Nuevo presupuesto" → `/presupuestos/nuevo?cliente=<id>` y una sección "Presupuestos" con los últimos 5 del cliente (`GET /quotes?client_id=`) y enlace al listado filtrado (OQ-P7).
- **`/ventas`**: la operación nacida de un presupuesto muestra el badge "Desde presupuesto P-00000012", con enlace. El read model de ventas y órdenes gana `source_quote_id` y `source_quote_number` derivados de `sales_orders.source_quote_id → quotes`, sin columnas denormalizadas.
- **Errores**: `lib/operation-errors.ts` gana las traducciones de `quote_locked_converted|expired|rejected`, `quote_expired`, `quote_invalid_state`, `quote_product_unavailable`, `quote_not_deletable`, `quote_valid_until_in_past`, `idempotency_key_conflict` y `payment_method_required`. `stock_insuficiente` ya existe y se reutiliza.
- **Design system**: tokens semánticos, componentes base con `cva`, `ResponsiveModal` para los diálogos, verificación en desktop y 375 px × claro y oscuro (regla del PO).

### D11 — Permisos: capacidad `CAN_QUOTE` que espeja la FSM

`backend/core/rbac.py` suma `CAN_QUOTE = frozenset({"owner", "admin", "seller"})`, el mismo conjunto que el catálogo declara para las transiciones de `quote`. Aplica así:

| Operación | Guard en el service | Guard en la base |
|---|---|---|
| Listar, ver, PDF | miembro de la cuenta | RLS `SELECT` |
| Crear, editar, enviar, rechazar, eliminar, convertir | `require_account_role(conn, auth, CAN_QUOTE)` | `is_account_writer` + rol vía `record_status_transition` |
| Validez por defecto | `CAN_CONFIGURE` | guard owner/admin en `rpc_set_default_quote_validity` |

- `rpc_update_quote` no cambia de estado, así que `record_status_transition` no lo protege. Verifica el rol por sí misma con el mismo predicado que usa el helper de transiciones (roles activos no vencidos del actor en la cuenta ∩ `{seller, admin, owner}`) → `P0401`. Lo mismo `rpc_delete_quote`.
- Se retira `require_role(auth, ["user","admin"])` (legacy) de `services/quotes.py`.
- El frontend oculta las acciones sin permiso con `useOrgRole` (patrón existente) y el backend es la fuente de verdad.

### D12 — Backend 3 capas y `QuoteForm` en el frontend

**Backend**:

- `schemas/quotes.py`:
  - `QuoteItemIn` suma `description: str | None` (obligatoria si no hay `product_id`, `max_length=200`).
  - `QuoteIn`: `client_id: UUID` (**obligatorio**), `notes` (`max_length=2000`) y `valid_until`.
  - Se retira `subtotal` como fuente del total: se sigue enviando por línea (lleva el descuento), pero el total lo calcula la RPC.
  - `QuoteUpdateIn`, `QuoteOut` (`number`, `number_label`, `notes`, `sent_at`, `updated_at`, `is_expired`, `client_name`, `client_phone`, `sales_order_id`, `items`, `history`), `QuoteListItemOut`, `QuoteConvertIn` (`payment_method_id`, `branch_id?`, `cash_session_id?`, `bank_account_id?`, `canal?`, `idempotency_key?` como fallback del header), `QuoteConvertOut` y `QuoteSettingsIn/Out`.
  - `QuoteTransitionIn.action` pasa a `{"send","reject"}` + `reason` opcional.
- `repositories/quote_repository.py`: todo por RPC o por `SELECT` con `account_id` explícito. El listado hace `JOIN clients` para nombre y teléfono y deriva `is_expired`.
- `services/quotes.py`: guards (D11), mapeo de errores a RFC 7807 con `ProblemHTTPException` (`code` estable = literal del error SQL), sin `HTTPException` crudo.
- `routers/quotes.py`: `POST /quotes/{id}/convert` usa `require_idempotency_key(request, payload.idempotency_key)`, como `/sales-orders/quick-sale`.
- `POST /quotes/{id}/accept` **se conserva**: no tiene consumidores, pero retirarlo no aporta y el requirement de `accept()` sigue vigente. Pasa a `CAN_QUOTE`. La UI no lo usa.

**Frontend**:

- `hooks/data/use-quotes.ts` se reescribe sobre el contrato nuevo: `useQuotes(filters)` paginado, `useQuote(id)`, `useCreateQuote`, `useUpdateQuote`, `useTransitionQuote`, `useDeleteQuote`, `useConvertQuote` (con `useIdempotencyKey`), `useQuoteSettings` y `useUpdateQuoteSettings`.
- `useConvertQuote` invalida `quotes.*` más **la misma lista que invalida la venta rápida del POS** (`salesOrders`, `sales`, `branchStock`, `customerAccounts`, `receivables`, … en `hooks/data/use-sales-orders.ts:240-253` y `:320-329`, hoy repetida dos veces en ese archivo). Esa lista se extrae a un helper `invalidateAfterSale(queryClient)` en `lib/query-invalidation.ts`: lo consumen las dos mutaciones existentes y la de conversión, y no se copia por cuarta vez.
- **`components/quotes/QuoteForm.tsx`**: el editor de líneas se arma con las piezas compartidas que ya usa el formulario de venta:
  - `ProductPicker`, `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput` + `resolveScan` (incluye etiquetas de balanza), `useScaleSettings`, `useUnitsOfMeasure`, `compatibleUnits`, `convertUnitPrice` y `roundUnitPrice`;
  - `SaleCartItem`, `calcSaleSubtotal`, `unitPriceFromSubtotal`, `calcCartTotal` y `addScannedProductLine` de `lib/cart-utils`.
  
  La lógica de "alta manual de la línea preparada" hoy vive embebida en `sale-form.tsx` (`handleAddToCart`). Se extrae a una función pura `addManualLineToCart(cart, staged, ctx)` en `lib/cart-utils.ts` (nace en capa canónica), con un parámetro `enforceStock: boolean`: el presupuesto pasa `false` y sólo muestra el disponible; la venta seguiría pasando `true`. **Esta tanda no migra `sale-form` ni el POS a esa función** (Non-Goal, candidato): se evita tocar el hot path de la venta sin necesidad.
  - **Línea de servicio** (sin producto): "Agregar concepto" con descripción, cantidad y precio (el requirement "línea de servicio sin producto" ya existe en la spec).
  - **Cliente**: `SearchableSelect` de clientes vivos + "Nuevo cliente", que abre `ClientForm` (`components/forms/client-form.tsx`) en un `ResponsiveModal` y lo preselecciona al crearlo. Muestra el teléfono y avisa si falta ("sin teléfono: WhatsApp abrirá el selector de contactos").
  - **Validez**: fecha con el default de la cuenta; notas; sucursal opcional (`BranchSelect`).
  - **Duplicar** (`?duplicar=<id>`): precarga cliente, notas y líneas. Las líneas con producto toman el **precio de hoy** del catálogo, reexpresado a la unidad de la línea con `convertUnitPrice`; las de servicio conservan el suyo. Muestra un aviso con las líneas cuyo precio cambió y la validez se recalcula desde hoy.
  - Envío con `useCreateQuote`/`useUpdateQuote`. Al guardar navega al detalle.
- **`components/quotes/ConvertQuoteDialog.tsx`**:
  - resumen de líneas y total en sólo lectura;
  - `BranchSelect` (default: sucursal del presupuesto o la de la cuenta);
  - `PaymentMethodSelect` (contexto `sale`) + `BankAccountDestinationSelect` cuando el `kind` lo requiere;
  - opt-in de caja con `useCashOptin({kind, branchId, requiresDate: false, document: "venta"})` (la venta nace hoy, como en el POS);
  - si la forma de pago es `credit`, el saldo actual del cliente (`useCustomerAccount`).
  
  Al confirmar llama a `useConvertQuote`. En éxito, el diálogo pasa a un estado final: "Venta registrada" + `EmitInvoiceButton` (el mismo que usa el POS) + "Ver en Ventas" + "Cerrar". En error, el mensaje de `humanizeOperationError`, y el presupuesto sigue abierto.

### D13 — Sin gating de plan

Presupuestos, PDF, WhatsApp y conversión quedan disponibles en todos los tiers, igual que ventas, compras y cobranzas (OQ-P8). No se agrega entrada a `PLAN_LIMITS` ni `PlanGate`.

### D14 — Migraciones, gates y dos tandas de apply

- **Tanda A** — `20261067000001_presupuestos_modulo.sql` (idempotente por el auto-apply de Supabase GitHub):
  - verificación defensiva previa (0 filas con número duplicado);
  - columnas; `internal_document_sequences`, helper y disparador; `accounts.default_quote_validity_days`;
  - las 5 RPCs de D2/D7 (`CREATE OR REPLACE` con firmas nuevas; no hay overload previo, así que no hay riesgo de `42725`);
  - `DROP POLICY IF EXISTS` de las 4 políticas de escritura;
  - barrido y cron;
  - bloque `DO` de introspección al final: columnas, `UNIQUE`, disparador, que las 4 políticas no existan, ACLs sin `anon`, helper sin `authenticated`, job de cron presente.
- **Tanda B** — `20261068000001_presupuestos_conversion_venta.sql`:
  - `_quote_accept_core` desde el cuerpo vivo (checkpoint);
  - `rpc_accept_quote` como wrapper (`CREATE OR REPLACE`, misma firma; `COMMENT` vivo re-declarado);
  - `rpc_convert_quote_to_sale`;
  - introspección: una sola definición de cada función, el cuerpo de `rpc_accept_quote` delega, el núcleo sin `authenticated` y la RPC nueva sin `anon`.
- **Gates** (se ejecutan de verdad; regla del proyecto: "toda RPC que otras invocan necesita un gate que la EJECUTE"):
  - `supabase/tests/test_presupuestos_modulo.sql` (A):
    - dos cuentas, owner, seller y cashier reales, fixtures propios y cleanup asertado;
    - numeración correlativa por cuenta, independiente entre cuentas; un alta que falla no consume número;
    - alta sin cliente, con cliente ajeno o dado de baja, con producto ajeno, padre con variantes o unidad incompatible → cada uno con su código;
    - snapshot del producto propio y nunca del ajeno;
    - total calculado en el servidor;
    - crear no toca `branch_stock` ni caja;
    - edición en `draft` y `sent` re-toma snapshots; edición en `accepted|expired|rejected` → `P0423`;
    - `sent` idempotente; `rejected` con historial;
    - el cashier no crea (`P0401`); PostgREST (`SET ROLE authenticated`) no puede `INSERT`/`UPDATE` directo;
    - borrado sólo en `draft`;
    - `_expire_overdue_quotes`: vence, registra historial con actor NULL, es idempotente y no toca `accepted`;
    - `rpc_set_default_quote_validity`: rango y rol.
  - `supabase/tests/test_presupuesto_a_venta.sql` (B), con **matriz de evasión**:
    - conversión feliz con `cash` (stock −, `cash_movements`, `SaleConfirmed`, quote `accepted`, orden `confirmed` con `source_quote_id`, historial de los dos documentos);
    - `credit` (cargo en cuenta corriente con vencimiento por cascada, sin caja);
    - `transfer` con cuenta bancaria (`bank_movements`);
    - precio del presupuesto aunque el catálogo haya cambiado;
    - stock insuficiente → `P0409` y **cero** efectos (presupuesto en su estado, 0 órdenes nuevas, stock intacto, 0 eventos);
    - vencido → `P0409 quote_expired`;
    - producto dado de baja → `P0404 quote_product_unavailable`;
    - presupuesto ajeno → `P0404`;
    - caja de otra cuenta → `P0422` (heredado del núcleo);
    - replay con la misma clave → `replayed = true`, sin efectos nuevos;
    - la misma clave contra otro presupuesto → `P0409 idempotency_key_conflict`;
    - segunda conversión con otra clave → `P0409 quote_invalid_state`;
    - `rpc_accept_quote` sigue creando una orden `draft` idéntica a la de antes (regresión);
    - cashier → rechazado.
  - `supabase/tests/test_presupuesto_a_venta_race.sh`: dos sesiones `psql` convierten el mismo presupuesto a la vez. Exactamente una venta y un `accepted`; la otra recibe `quote_invalid_state` o replay. Molde: `test_ventas_unidades_conversion_race.sh`.
  - `test_function_acl_gate.sql`: sin cambios de código si los nombres siguen la convención. Se verifica que las funciones nuevas quedan clasificadas.
  - Todos cableados en `KPI_Validation.yml`, en el orden real del workflow, y las dos migraciones sumadas al final de la cadena de reaplicación de idempotencia.
- **Apply en dos PRs** (A, luego B), cada uno con su CI verde. La tanda A ya entrega valor por sí sola: crear, editar, descargar y mandar por WhatsApp. El botón "Venta" aparece recién con B; en A, el detalle muestra la acción deshabilitada con la leyenda "Próximamente", o se oculta (decisión del apply, sin impacto en specs).

## Risks / Trade-offs

- **[Doble conversión concurrente]** → `FOR UPDATE` sobre `quotes` antes de todo, idempotencia leída después del lock, gate de carrera con dos sesiones reales.
- **[Clave de idempotencia reutilizada contra otro presupuesto]** devolvería la venta de otro documento → `P0409 idempotency_key_conflict`, con assert en el gate.
- **[Reescribir `rpc_accept_quote` desde un cuerpo que no es el vivo]**, que es cómo se perdió el bloque `credit` en julio → checkpoint 0.3 con el `pg_get_functiondef` de prod comparado por líneas sin `\r` contra `20261045000001`; el diff del núcleo contra el cuerpo vivo tiene que ser exactamente los dos cambios de D6; `COMMENT` conservado.
- **[Retirar las políticas de escritura rompe a un escritor no listado]** → checkpoint 0.4 (grep en las cuatro raíces + los gates SQL que insertan en `quotes`), gates existentes re-ejecutados (`test_v3_soft_delete*`, `test_document_status_history*`, `test_operacion_party_guard.sql`, `test_c29*`) y `backend/tests/test_c29_quote_salesorder.py` migrado.
- **[Producto dado de baja entre el presupuesto y la venta]** → guard propio antes de escribir (D6.4) y mensaje accionable. El guard de baja de producto (`fn_guard_product_soft_delete`) sólo mira presupuestos en `draft` (OQ-P10).
- **[Stock insuficiente al convertir]** → rollback total con el mensaje que ya traduce la UI. El diálogo lo muestra y el presupuesto sigue abierto para editar o esperar reposición.
- **[El precio del presupuesto ya no es el del catálogo]** → es el comportamiento pedido (OQ-P3). El detalle muestra "precio de catálogo actual" junto a las líneas cuyo precio difiere, sólo como información.
- **[Presupuesto vencido que el barrido todavía no marcó]** → `is_expired` derivado en el read model y el mismo chequeo en la conversión.
- **[Venta borrada deja el presupuesto `accepted` sin venta viva]** → es terminal por diseño (OQ-P12). El detalle muestra "La venta generada fue eliminada" si la orden está `canceled`, con "Duplicar" como salida.
- **[Serialización de altas por cuenta por el lock de la secuencia]** → sólo entre altas de presupuestos de la misma cuenta, milisegundos, sin stock. Aceptado.
- **[Extraer helpers de `sale-receipt-button` y `fiscal-invoice` rompe el comprobante de venta o la factura]** → extracción sin cambio de comportamiento, con sus tests actuales como safety net y un test nuevo por helper.
- **[Pestaña Cobranzas con una tarjeta de otro dominio]** → justificado en D7; OQ-P9 deja abierta la alternativa.
- **[Teléfonos mal cargados]** → `normalizeWhatsAppPhone` ya decide. Sin número válido se abre el selector de contacto con un aviso.

## Migration Plan

1. **Tanda A**:
   - merge → CI/CD aplica `20261067000001` y despliega frontend (Vercel) y backend (Render; verificar `GET /deploys`, porque el auto-deploy no siempre dispara);
   - sin backfill: 0 presupuestos en prod;
   - verificación post-merge (sólo lectura): `MAX(version)`, columnas, `UNIQUE`, disparador, políticas de escritura ausentes, ACLs, `cron.job` con `quotes-expire-sweep`, `default_quote_validity_days = 15` en las 41 cuentas;
   - humo del PO: crear, editar, descargar, WhatsApp desde el celular, rechazar, duplicar y eliminar.
2. **Tanda B**:
   - merge → `20261068000001`;
   - verificación post-merge: una sola definición de `rpc_accept_quote` que delega; `_quote_accept_core` sin `authenticated`; `rpc_convert_quote_to_sale` sin `anon`;
   - humo del PO: presupuesto → Venta (efectivo con caja abierta y a crédito) → aparece en `/ventas` → Facturar → comprobante autorizado.
3. **Rollback**:
   - A: revertir el PR de frontend y backend deja las columnas y la tabla sin uso. Si hiciera falta volver a escritura directa, una migración nueva recrea las 4 políticas desde `20260702000001`.
   - B: re-aplicar el cuerpo anterior de `rpc_accept_quote` (el vivo capturado en 0.3) en una migración nueva y `DROP FUNCTION rpc_convert_quote_to_sale`. Las ventas ya generadas son ventas normales del POS y no necesitan reparación.

## Sign-off del PO

**Requisitos firmados (2026-09-29, textuales)**: los cuatro de §Context. Son requisitos, no Open Questions. En particular, **la edición del presupuesto mientras no esté convertido está firmada** y es la base de D5.

**Open Questions**: pendientes de sign-off. **Mientras el PO no responda, el apply adopta la recomendación de cada una** (default declarado, mismo criterio que los changes anteriores). Si el PO elige una alternativa, se actualizan en el mismo PR la decisión afectada, las specs y las tareas. Registrar acá la respuesta textual del PO antes de escribir producción (tarea 0.1).

## Open Questions

- **OQ-P1 — ¿El cliente es obligatorio?**
  - *Recomendado*: **sí**. El pedido dice "para un cliente" y sin cliente no hay teléfono para WhatsApp. Se puede dar de alta en el lugar (D12).
  - *Alternativa*: permitir "Consumidor final" sin cliente, sin WhatsApp directo.
- **OQ-P2 — Numeración.**
  - *Recomendado*: `P-00000001`, correlativa **por cuenta**, única para todas las sucursales (D3).
  - *Alternativa*: prefijo por sucursal (`P-0002-00000001`).
- **OQ-P3 — Precio al convertir.**
  - *Recomendado*: **el del presupuesto**, que es lo prometido. Si el precio cambió y el comercio quiere cobrar el nuevo, edita el presupuesto antes de convertir, o duplica.
  - *Alternativa*: re-cotizar al precio del catálogo al convertir. Rompe la promesa al cliente y exige decidir qué pasa con el descuento por línea.
- **OQ-P4 — Validez por defecto.**
  - *Recomendado*: **15 días**, configurable por cuenta (1–365) y editable en cada presupuesto (D7).
- **OQ-P5 — ¿Se puede vender un presupuesto vencido?**
  - *Recomendado*: **no directamente**. Mientras el barrido no lo marcó `expired`, se **amplía la validez** editándolo (D5.3). Ya `expired`, se **duplica** con los precios de hoy.
  - *Alternativa*: permitir convertir vencidos con una confirmación explícita.
- **OQ-P6 — Canales de envío v1.**
  - *Recomendado*: **sólo descarga/impresión y WhatsApp** (D9). El link público, la aceptación online y el email van en un change posterior con governance ALTA.
- **OQ-P7 — Presupuestos desde la ficha del cliente.**
  - *Recomendado*: **sí**. Botón "Nuevo presupuesto" y sección con los últimos 5 (D10). Es barato y es donde el comercio mira al cliente.
- **OQ-P8 — Plan.**
  - *Recomendado*: **sin gate**, todos los tiers (D13).
- **OQ-P9 — Dónde se configura la validez por defecto.**
  - *Recomendado*: tarjeta en la pestaña **Cobranzas** (condiciones comerciales hacia el cliente) + enlace desde `/presupuestos` (D7).
  - *Alternativas*: una 13ª pestaña "Presupuestos", o un control dentro de `/presupuestos`.
- **OQ-P10 — Baja de un producto que está en un presupuesto enviado.**
  - Hoy el guard de baja sólo bloquea si el producto está en un presupuesto **`draft`**.
  - *Recomendado*: **no ampliarlo** en este change. La conversión lo detecta (`quote_product_unavailable`) y pide editar el presupuesto. Ampliar el guard a `sent` bloquearía bajas de catálogo por cotizaciones que quizás nunca se acepten.
  - *Alternativa*: incluir `sent` en el predicado del guard (reescritura de `fn_guard_product_soft_delete` desde su cuerpo vivo).
- **OQ-P11 — Vencimiento de la cuenta corriente en una conversión a crédito.**
  - *Recomendado*: **cascada**, como el POS (plazo del cliente → de la cuenta → sin vencimiento), sin campo en el diálogo.
  - *Alternativa*: mostrar el vencimiento editable, como el formulario de venta. Exige un parámetro nuevo en el núcleo, que no se toca en este change.
- **OQ-P12 — ¿Qué pasa con el presupuesto si se borra la venta que generó?**
  - *Recomendado*: **queda `accepted`** (terminal; el historial muestra la conversión). El detalle avisa que la venta fue eliminada y ofrece "Duplicar".
  - *Alternativa*: volver el presupuesto a `sent`. Exige una transición nueva `accepted → sent` y tocar `rpc_delete_sale_operation` (hot path de borrado con compensación).
- **OQ-P13 — "Ver / Imprimir" y el estado enviado.**
  - *Recomendado*: sólo **Descargar** y **WhatsApp** marcan el presupuesto como enviado; "Ver / Imprimir" no (D9). Hay además un botón explícito "Marcar como enviado".
  - *Alternativa*: que cualquier acción del menú lo marque.
