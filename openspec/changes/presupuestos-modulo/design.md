## Context

El pedido del PO y la brecha contra lo que existe están en `proposal.md` y en el explore copiado en `research/explore-presupuestos-remitos.md` (fuente de verdad del contexto; mapea todo lo existente con rutas y líneas). Este change cubre **sólo** `presupuestos-modulo`, el primero del split `presupuestos-modulo` → `remitos-venta` → `remitos-compra` (explore §4). Deja listas, en su capa canónica, las tres piezas que los remitos van a reutilizar: la numeración interna, el constructor de PDF comercial y el menú de compartir.

### Lo que ya existe (verificado en `main` `4f6041b6`, 2026-09-29)

| Pieza | Dónde | Estado relevante para este change |
|---|---|---|
| `quotes` / `quote_items` | `20260702000001_c29_quote_salesorder.sql:82-163` | Sin número, sin notas, `valid_until` opcional, `client_id` opcional. RLS con políticas `quotes_insert`/`quotes_update`/`quote_items_insert`/`quote_items_update` para `is_account_writer` (escritura directa del repo, "D3" de C-29). Sin política de `DELETE`. |
| Snapshots | `20260806000001_v3_snapshot_pattern.sql:91` | `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot`, `iva_rate_snapshot`, `snapshot_backfilled`. `quote_items.price` es `NUMERIC` sin escala desde `ventas-unidades-conversion` (D-F′, RN-24-bis). |
| Historial de creación | `20260807000001_v3_document_status_history.sql:395-425` | Disparador `quotes_record_status_creation` (`AFTER INSERT`): registra `NULL → status` con `created_by` como actor y **valida el rol** vía `record_status_transition`. |
| FSM | seed `20260807000001:177-184` + roles `20261048000001:403-408` + disparador `quotes_enforce_status_transition` (`20260816000001:158`) | `NULL→draft`, `draft→sent`, `draft\|sent→accepted`, `draft\|sent→rejected` (roles `seller, admin, owner`); `draft\|sent→expired` sin roles (sistema). Hoy `accepted`, `expired` y `rejected` son terminales (`is_terminal_to = true` en las filas que llegan a ellos); este change deja `accepted` como único terminal de `quote` (D4). El disparador rechaza cualquier `UPDATE` de estado no catalogado, venga de donde venga. |
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
- Migrar el comprobante interno de venta (`build_sales_receipt_pdf`, `SaleReceiptButton`) al constructor y al menú nuevos, y migrar el POS a los helpers de carrito extraídos (`sale-form` sí se migra en este change, porque es de donde salen; D12). Quedan como candidatos: tocarlos ensancha el diff sobre el hot path de venta sin que el pedido lo necesite.
- Conversión parcial (vender algunas líneas) o varias ventas desde un presupuesto.
- Vencimiento editable de la cuenta corriente desde el diálogo de conversión (la venta a crédito usa la cascada, como el POS; OQ-P11).
- Notificaciones de presupuesto aceptado o vencido (el evento `QuoteAccepted` ya existe; el consumidor no se toca).

## Decisions

### D1 — Modelo de datos: columnas nuevas en `quotes`, sin tabla nueva

Columnas aditivas en `quotes`:

| Columna | Tipo | Regla |
|---|---|---|
| `number` | `bigint NULL` + `UNIQUE (account_id, number)` | La asigna el disparador de D3. Nullable a nivel columna para no romper a los escritores históricos: en prod hay 0 filas y los gates insertan sin número. El disparador garantiza que ninguna fila nueva nazca sin número por un camino con disparadores activos (bajo `session_replication_role = replica`, que usan algunos gates, no corren; D3). |
| `notes` | `text NULL` | Condiciones, forma de entrega. Tope de 2.000 caracteres (`CHECK`). |
| `sent_at` | `timestamptz NULL` | Primera vez que pasó a `sent`. |
| `updated_at` / `updated_by` | `timestamptz NULL` / `uuid NULL` | Última edición. La UI avisa "modificado después de enviado" cuando `updated_at > sent_at`. |
| `revision` | `integer NOT NULL DEFAULT 1` | Versión del contenido. `rpc_update_quote` la incrementa en cada edición. La edición y la conversión reciben la versión que el usuario vio y rechazan con `P0409 quote_changed` si cambió (D5, D6). Las transiciones (`sent`, `rejected`, vencimiento) no la tocan: no cambian lo que se cobra. Es un entero y no `updated_at` para no depender de la precisión del timestamp en el viaje de ida y vuelta por JSON y por el `Date` de JavaScript. |

`accounts.default_quote_validity_days integer NOT NULL DEFAULT 15 CHECK (BETWEEN 1 AND 365)`. Es una columna de privilegio en el sentido del gate `test_accounts_privilege_columns.sql`: nace sin `UPDATE` por PostgREST y se escribe sólo por `rpc_set_default_quote_validity` (D10).

- **Sin snapshot del teléfono ni del nombre del cliente.** El envío ocurre "ahora", con el teléfono vigente, y el PDF muestra los datos vigentes del cliente. El snapshot fiscal del receptor (`FiscalIdentitySnapshot`) es del comprobante fiscal, no del presupuesto.
- **Sin estado nuevo `converted`.** `accepted` pasa a significar "convertido en venta": desde este change, la UI sólo llega a `accepted` a través de la conversión (D6). El puente es `sales_orders.source_quote_id`, que ya existe.
  - *Rechazado*: agregar `converted` al `CHECK`, al catálogo de transiciones y a la FSM. Duplicaría el significado de `accepted` y obligaría a reescribir `rpc_accept_quote`, el enforcement y el seed.
- *Rechazado*: una tabla `quote_versions` para guardar cada edición. El PO pidió poder modificar, no versionar. El historial de estados más `updated_at`/`updated_by` alcanza. Si hace falta, queda como candidato.

### D2 — Escritura sólo por RPC; se retiran las políticas de escritura directa

Cuatro RPCs `SECURITY DEFINER` (`SET search_path = public`, `REVOKE … FROM PUBLIC, anon`, `GRANT EXECUTE … TO authenticated`):

- **`rpc_create_quote(p_client_id uuid, p_branch_id uuid, p_valid_until date, p_notes text, p_items jsonb) → jsonb`**
  - Resuelve la cuenta con `current_account_ids()`, igual que `rpc_quick_sale`.
  - Exige `is_account_writer` (`P0401`) y un rol de `CAN_QUOTE` (`P0403 insufficient_role`, D11), verificados **antes** del `INSERT`.
  - Cliente obligatorio y **vivo** de la cuenta (`P0404 client_not_found`, mismo literal que el guard de `operacion-party-guard`).
  - Sucursal opcional; si viene, debe ser de la cuenta y no estar cerrada (`P0404`/`P0422`).
  - `p_valid_until` NULL → `reporting_local_today() + default_quote_validity_days`. Si viene, debe ser ≥ hoy (ART) (`P0400 quote_valid_until_in_past`).
  - Por cada línea valida:
    - `product_id` NULL (línea de servicio) → exige una descripción (`description`, que se guarda en `name_snapshot`);
    - si hay producto: vivo, de la cuenta, y no padre con variantes (`P0404 product_not_found` / `P0400 product_is_parent`);
    - la unidad pasa por `_uom_normalize_quantity(product_id, unit_id, quantity)`, sólo para validar la compatibilidad (RN-24 (a)(b)(c)(f)); el resultado se descarta;
    - toda línea con `unit_id`, **también la de servicio**, exige una unidad del sistema o de la cuenta (`P0404`, el mismo literal que el helper). `_uom_normalize_quantity` sale temprano cuando `product_id` es NULL, antes de su chequeo de tenencia de la unidad: sin este guard, una línea de servicio podría llevar una unidad de otra cuenta al PDF y a la venta;
    - `quantity > 0`, `price ≥ 0`, `0 ≤ subtotal`.
  - `total = round(Σ subtotal, 2)`, calculado en el servidor (RN-24-bis). El total que manda el cliente se ignora.
  - Inserta `quotes` (el disparador asigna el número y registra `NULL→draft`, validando el rol) y `quote_items` con los snapshots en el **mismo** `INSERT … SELECT` desde `products` **filtrado por `account_id`**.
  - Devuelve el presupuesto con sus líneas.
- **`rpc_update_quote(p_quote_id uuid, p_expected_revision integer, p_client_id uuid, p_branch_id uuid, p_valid_until date, p_notes text, p_items jsonb) → jsonb`**
  - Reemplazo completo (D5).
  - Toma `SELECT … FOR UPDATE` sobre el presupuesto.
  - `p_expected_revision` es obligatorio: si difiere de `quotes.revision` leída bajo el lock, `P0409 quote_changed` ("el presupuesto cambió mientras lo editabas: revisalo"). Con dos editores a la vez, el segundo en guardar recibe el error en vez de pisar al primero en silencio (el reemplazo es completo).
  - Guards: tenencia (`P0404`, idéntico para inexistente y ajeno), rol (D11), estado (D5).
  - `p_valid_until` es **obligatorio** (`P0400 quote_valid_until_required`): el reemplazo es completo, y un NULL dejaría el presupuesto sin vencimiento (el barrido y `is_expired` filtran `valid_until < hoy`). `p_branch_id` y `p_notes` NULL significan "sin sucursal" y "sin notas": la UI siempre manda el valor vigente de cada campo. `QuoteUpdateIn` declara los tres campos como requeridos, con `valid_until` no nulo.
- **`rpc_transition_quote(p_quote_id uuid, p_to_status text, p_reason text) → jsonb`**
  - Destinos admitidos desde la API: `sent` y `rejected`. `accepted` va sólo por la conversión y `expired` sólo por el barrido (`P0400 quote_transition_not_allowed`).
  - `FOR UPDATE`, `record_status_transition` (valida el catálogo y el rol, exige motivo si el catálogo lo pide) y `UPDATE`.
  - `sent` sobre un presupuesto que ya está en `sent` es un **no-op idempotente** (200, sin historial duplicado): lo usa el menú de compartir, que marca como enviado en cada descarga o envío.
  - El primer `sent` fija `sent_at`.
- **`rpc_delete_quote(p_quote_id uuid) → void`**
  - Sólo en `draft` **nunca enviado** (`sent_at IS NULL`; política de borrado por categoría, KB 05 §borrado, ítem 4: los borradores admiten hard delete). En otro caso: `P0409 quote_not_deletable`. Un `draft` reabierto por una edición (D5) que ya había llegado al cliente no se borra: se rechaza.
  - Rol `CAN_QUOTE` verificado por la propia RPC (`P0403`, D11).
  - **Bajo lock**, como la edición y las transiciones: `SELECT … FROM quotes WHERE id = $1 AND account_id IN (SELECT current_account_ids()) FOR UPDATE` (`P0404 quote_not_found` sin fila). El estado y `sent_at` se chequean sobre esa fila, y el borrado es `DELETE … WHERE id = $1 AND status = 'draft' AND sent_at IS NULL`, verificando `ROW_COUNT = 1`. Sin el lock, un borrado que leyó `draft` y una conversión que commitea en el medio (un `draft` es convertible) terminarían con el `DELETE` borrando un presupuesto ya `accepted`: en READ COMMITTED el `DELETE` sólo re-evalúa su propio `WHERE`, `quote_items` se iría por CASCADE y `sales_orders.source_quote_id` quedaría en NULL (`ON DELETE SET NULL`, `20260702000001:174`), con la venta sin origen.
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
- **Helper de asignación** `_assign_internal_document_number(p_account_id uuid, p_document_type text, p_explicit bigint) → bigint`, interno y con el mismo régimen de ACL que el anterior. Con `p_explicit` NULL devuelve `_next_internal_document_number(...)`. Con un número explícito lo respeta y **avanza la secuencia**: `last_number = GREATEST(last_number, p_explicit)` (creando la fila si falta, con el mismo UPDATE-then-INSERT), para que un alta posterior no choque con ese número. Toda la regla de la capability vive en los dos helpers, no en el disparador de una tabla.
- **Disparador genérico** `trg_assign_internal_document_number()`: función de trigger `BEFORE INSERT` parametrizada por `TG_ARGV[0]` (el `document_type`), con el precedente de `trg_enforce_status_transition` (`20260816000001`). Hace `NEW.number := _assign_internal_document_number(NEW.account_id, TG_ARGV[0], NEW.number)`. Sobre `quotes` se engancha como `quotes_assign_number … EXECUTE FUNCTION trg_assign_internal_document_number('quote')`. `remitos-venta` sólo suma su `CREATE TRIGGER` con `'delivery_note'` y amplía el `CHECK`, sin copiar lógica.
  - Es el paso obligado para cualquier escritor (RPC, gate o backfill), el mismo principio que `trg_guard_branch_decommission`.
  - Un número explícito se respeta (fixtures) y avanza la secuencia (helper de asignación). El `UNIQUE` protege el duplicado explícito.
- **Disparador propio del presupuesto** `quotes_default_valid_until` (`BEFORE INSERT`, función `trg_quote_default_valid_until()`): completa un `valid_until` NULL con `reporting_local_today() + accounts.default_quote_validity_days` (D7), así ningún presupuesto nace sin vencimiento, venga de la RPC o de una fixture. Es lógica del presupuesto y no vive en la pieza compartida.
  - Bajo `session_replication_role = replica` los disparadores no corren. La garantía es "todo camino con disparadores activos", y la spec lo dice así. `number` sigue nullable: declararlo `NOT NULL` rompería los gates que insertan presupuestos en modo réplica (en prod hay 0 filas).
- **Sin huecos**: el lock de la fila de secuencia se toma dentro de la transacción de alta y se libera al commit. Un alta que falla revierte el incremento. Serializa las altas de presupuestos **de una misma cuenta**, que duran milisegundos y no tocan stock.
  - A diferencia de la numeración fiscal, el lock largo no es un riesgo: la de ARCA exige lock corto porque la transacción de venta es larga.
- **Formato visible**: `P-` + número con relleno a 8 dígitos (`P-00000012`). Una sola definición por lenguaje: `frontend/lib/internal-document-number.ts` (`formatInternalDocumentNumber('quote', n)`) y `backend/services/commercial_documents/numbering.py`, con un **fixture de casos compartido** (`backend/tests/fixtures/internal_document_number_cases.json`) que leen pytest y vitest, como el de `scale_layout_cases.json`. Sin prefijo por sucursal (OQ-P2).
- *Rechazado*: reutilizar `document_sequences`. Es fiscal: su clave es punto de venta + tipo de comprobante y sólo se incrementa vía `rpc_next_document_number` con guard de perfil fiscal. Mezclar un presupuesto con la numeración de ARCA es un error de dominio.
- *Rechazado*: una `SEQUENCE` de Postgres por cuenta. No es transaccional (deja huecos al revertir) y crearía N objetos de catálogo.

### D4 — FSM: la del catálogo más la reapertura; `accepted` queda como único terminal; el requirement de la spec se corrige

El catálogo ya tiene todo lo que este change ejecuta, salvo la reapertura:

| Transición | Quién la ejecuta en este change |
|---|---|
| `NULL → draft` | `rpc_create_quote`, vía el disparador de creación |
| `draft → sent` | `rpc_transition_quote('sent')`, desde "Marcar como enviado" o automáticamente al descargar o compartir |
| `draft\|sent → accepted` | `_quote_accept_core`, dentro de la conversión |
| `draft\|sent → rejected` | `rpc_transition_quote('rejected', motivo opcional)` |
| `draft\|sent → expired` | `_expire_overdue_quotes` (sistema, actor = uuid cero, D7) |
| `expired → draft`, `rejected → draft` | `rpc_update_quote`, al editar un presupuesto vencido o rechazado (reapertura, D5). **Filas nuevas** del catálogo |

Se agregan **dos filas** al catálogo: `quote: expired → draft` y `quote: rejected → draft`, con `allowed_role = {seller, admin, owner}` y sin motivo obligatorio. Son las que hacen cumplir el requisito 4 del PO (editable mientras no esté convertido en venta). No cambian los roles de las filas existentes.

**`expired` y `rejected` dejan de ser terminales.** El seed marcó `is_terminal_to = true` en `quote: draft|sent → expired|rejected` (`20260807000001:179-182`). Con las dos filas nuevas saliendo de esos estados se violaría el invariante del seed, "ningún estado terminal tiene transición saliente" (gate (e) de `20260807000001:1773-1784` y el `COMMENT` de `is_terminal_status`), y la spec `document-status-history` quedaría falsa. La misma migración hace `UPDATE document_status_transitions SET is_terminal_to = false` en esas cuatro filas (idempotente), así `accepted` queda como el único terminal de `quote`. El seed de `20260807000001` usa `ON CONFLICT DO NOTHING`, así que reaplicarlo no revierte el cambio. Se agrega un delta MODIFIED del requirement "Seed del catálogo refleja las máquinas de estado vigentes" de `document-status-history`, y `test_presupuestos_modulo.sql` asserta que `is_terminal_status('quote','expired')` y `('quote','rejected')` son falsos, que `('quote','accepted')` es verdadero y que el invariante vale sobre todo el catálogo. El requirement "Agregado Quote con ciclo de vida" de la spec `quote` dice `sent → accepted | rejected | expired, draft → expired`, que contradice el seed (`draft → accepted` y `draft → rejected` existen y tienen roles). Se **modifica** para describir el catálogo vigente. Es un error de la spec, no un cambio de comportamiento; el requirement modificado suma además la reapertura por edición, que sí es comportamiento nuevo.

- **Editar no cambia el estado.** Un `sent` editado sigue `sent`. La UI muestra "Modificado después de enviado — reenvialo" (`updated_at > sent_at`).
  - *Rechazado*: volver a `draft` al editar. No hay transición `sent → draft` en el catálogo, y agregarla haría el estado menos útil, porque perdería que el cliente ya lo vio.

### D5 — Edición: reemplazo atómico en todo estado salvo `accepted`; editar un vencido o rechazado lo reabre

`rpc_update_quote`:

1. `SELECT … FROM quotes WHERE id = $1 AND account_id IN (SELECT current_account_ids()) FOR UPDATE`. Si no hay fila: `P0404 quote_not_found`. Si `p_expected_revision <> revision`: `P0409 quote_changed` (D1).
2. Estado:
   - `accepted` → `P0423 quote_locked_converted` ("el presupuesto ya se convirtió en la venta …; los cambios se hacen sobre la venta"). Es el mismo `P0423` "inmutable" que la venta con comprobante o dinero posteado (`operation-edit-context`), con un literal propio para que `operation-errors.ts` lo traduzca de forma accionable. Es el **único** estado que no se edita.
   - `expired` o `rejected` → la edición **reabre** el presupuesto: `record_status_transition(…, status, 'draft', auth.uid(), NULL)` y el `UPDATE` deja `status = 'draft'`, en la misma transacción. El `p_valid_until` nuevo debe ser ≥ hoy (ART) (`P0400 quote_valid_until_in_past`).
3. Si el presupuesto está en `draft|sent` pero su `valid_until` ya pasó (el barrido todavía no corrió), la edición se admite **sólo si** el `p_valid_until` nuevo es ≥ hoy. Es la vía para "ampliar la validez" (OQ-P5). Si no lo es: `P0400 quote_valid_until_in_past`.
4. Mismos guards de cliente, sucursal y línea que el alta (D2).
5. `DELETE FROM quote_items WHERE quote_id = $1` + `INSERT` de las líneas nuevas con snapshots **re-tomados** del maestro filtrado por cuenta. Luego `UPDATE quotes SET client_id, branch_id, valid_until, notes, total, updated_at = now(), updated_by = auth.uid(), revision = revision + 1`.

- **Por qué reabrir a `draft`**: es el requisito 4 del PO ("editable mientras no esté convertido en venta"). La versión editada todavía no se mandó, así que es un borrador; la próxima descarga o envío la pasa a `sent`. El historial conserva el vencimiento o el rechazo anterior.
  - Un presupuesto vencido que el barrido todavía no marcó sigue en `sent` al editarlo (con "Modificado después de enviado"); uno ya marcado vuelve a `draft`. En los dos casos la UI ofrece "Editar" y exige ampliar la validez, así que para el usuario el comportamiento no depende de la hora del barrido (OQ-P14).
  - *Rechazado*: dejar `expired` y `rejected` inmutables con `P0423`. Contradice el requisito firmado y obligaría a duplicar el presupuesto para corregir una fecha.
- **Snapshots re-tomados**: la edición es un nuevo momento de cotización. El snapshot congela lo que se le prometió al cliente **en la última versión que se le mostró**.
  - *Rechazado*: aplicar la política canónica de `document-snapshots` (conservar el snapshot de la línea cuyo producto no cambió, emparejando por `product_id`). Es implementable, porque la edición de ventas ya empareja así, pero protege algo que el presupuesto no tiene: el costo histórico de una operación **confirmada**, es decir, el margen de una venta ya hecha. Un presupuesto no confirmado no tiene historia que proteger: nombre, SKU y costo del maestro no son promesas al cliente; el precio sí, y el precio viene del payload. Además, el costo que cuenta para la venta lo congela el núcleo al convertir (D6), no el snapshot del presupuesto.
- *Rechazado*: un `PATCH` parcial por línea. La UI edita el carrito completo (el mismo `QuoteForm` del alta), así que el reemplazo es el contrato natural. Con un solo camino de escritura se evitan divergencias.
- **Excepción explícita a `document-snapshots`.** Su requirement "Política de snapshot al editar una línea de operación" no distingue hoy entre operaciones confirmadas y documentos abiertos, y `quote_items` está entre las tablas con snapshot. Para que no queden dos reglas contradictorias, este change hace dos cosas:
  - suma al requirement "Edición del presupuesto mientras no esté convertido" de `quote` la cláusula y el escenario del re-congelado;
  - agrega un delta MODIFIED de ese requirement de `document-snapshots`, que acota su alcance a las operaciones de venta y compra y remite la excepción del presupuesto a la spec `quote`.

### D6 — Conversión atómica: `rpc_convert_quote_to_sale`

**Refactor previo, sin cambio de comportamiento.** El cuerpo de `rpc_accept_quote` se mueve a un núcleo interno `_quote_accept_core(p_quote_id uuid, p_branch_id uuid) → jsonb`:

- `SECURITY DEFINER`, sin `EXECUTE` para `authenticated`; la convención `_*` lo mete en el chequeo (4) del gate de ACLs.
- Se parte del `pg_get_functiondef` **vivo** (checkpoint 0.3; comparar por líneas sin `\r`, por el gotcha CRLF).
- Dos cambios, y sólo esos:
  1. `SELECT … FOR UPDATE` en la lectura del presupuesto, para cerrar la carrera de doble aceptación;
  2. la sucursal pasa a ser `COALESCE(p_branch_id, v_quote.branch_id, c26_default_branch(...))`, con `p_branch_id` validado contra la cuenta y no cerrada (`P0404`/`P0422`).
- `rpc_accept_quote(p_quote_id)` queda como wrapper de una línea, `RETURN _quote_accept_core(p_quote_id, NULL)`, con la **misma firma** (`CREATE OR REPLACE`), el mismo `COMMENT` vivo (regla: conservar el COMMENT al reescribir) y el mismo resultado.
- **Sus ACLs sí cambian, a propósito**: `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated` explícito, porque el `CREATE OR REPLACE` conservaría el `GRANT` de C-29 (`20260702000001:334-335`). Con `EXECUTE` para `authenticated`, PostgREST (`/rest/v1/rpc/rpc_accept_quote`) seguiría siendo un camino a `accepted` fuera de la conversión:
  - sin nada más, deja un presupuesto "convertido" con una orden `draft` invisible (el hueco por el que se rechazó A2);
  - encadenado con `POST /sales-orders/{id}/confirm` o `rpc_confirm_sales_order` (los dos para `authenticated`), produce una venta que se saltea los guards del paso 4: producto o cliente dados de baja, padre con variantes.
  
  No tiene consumidores: el endpoint se retira (D12) y los gates la llaman como `postgres` con claims (`test_operacion_party_guard.sql:322`). Efectos en los gates:
  - el bloque (8) de `test_operacion_party_guard.sql` asserta hoy que `authenticated` **sí** la ejecuta; se invierte para esta función;
  - se suma al chequeo (3) de `test_function_acl_gate.sql` (lista cerrada, sin allowlist), con candado de firma en `test_presupuesto_a_venta.sql`.

**RPC nueva**:

```
rpc_convert_quote_to_sale(
  p_idempotency_key   text,
  p_quote_id          uuid,
  p_expected_revision integer,
  p_payment_method_id uuid,
  p_branch_id         uuid DEFAULT NULL,
  p_cash_session_id   uuid DEFAULT NULL,
  p_bank_account_id   uuid DEFAULT NULL,
  p_canal             text DEFAULT NULL
) RETURNS jsonb   -- {quote_id, quote_number, sales_order_id, operation_id, total, replayed}
```

Orden de ejecución (todo en una transacción):

1. `auth.uid()` no nulo. `p_idempotency_key` no vacía (`P0400`). `p_payment_method_id` obligatorio (`P0400 payment_method_required`): la conversión no usa el camino legacy por texto.
2. **Lock del documento de origen primero**: `SELECT … FROM quotes WHERE id = p_quote_id AND account_id IN (SELECT current_account_ids()) FOR UPDATE`. Sin fila: `P0404 quote_not_found` (inexistente y ajeno indistinguibles). `is_account_writer` → `P0401`; rol `CAN_QUOTE` → `P0403` (D11).
3. **Idempotencia, después del lock**:
   - Si existe `operation_idempotency(user = auth.uid(), kind = 'sale', key)`, se busca la orden con `sale_operation_id =` esa operación **y** `source_quote_id = p_quote_id`.
   - Si existe, devuelve `{…, replayed: true}` sin escribir.
   - Si la clave existe pero pertenece a otra operación, `P0409 idempotency_key_conflict`: una clave reutilizada contra otro presupuesto no devuelve la venta de otro documento.
   - Leer la clave **después** del lock serializa el doble clic con la misma clave **sobre el mismo presupuesto**: el segundo espera, ve la clave y hace replay en vez de tropezar con `quote_invalid_state`. El caso de la misma clave sobre dos presupuestos distintos en paralelo lo cierra el paso 6.

   **3b. Estado, vencimiento y versión sobre la fila bloqueada**, antes de cualquier otro guard:
   - `status` fuera de `draft|sent` → `P0409 quote_invalid_state`. Un presupuesto ya convertido, rechazado o vencido responde por su estado y no por un producto dado de baja después: sobre un `accepted`, el mensaje de `quote_product_unavailable` ("editá el presupuesto") no tendría salida, porque su edición es `P0423`;
   - `valid_until < reporting_local_today()` → `P0409 quote_expired`;
   - `p_expected_revision <> revision` → `P0409 quote_changed`. El diálogo manda la versión que mostró. Si otro usuario editó el presupuesto mientras tanto, la conversión no cobra un total que nadie confirmó (el arqueo quedaría descuadrado contra lo que se cobró de verdad), y la UI recarga el presupuesto.
   
   `_quote_accept_core` vuelve a validar estado y vencimiento, sin cambios. Acá se adelantan para que el motivo del rechazo sea el correcto.
4. **Guards de convertibilidad**, antes de escribir nada:
   - cada `quote_items.product_id` no nulo debe existir, pertenecer a la cuenta, estar vivo (`deleted_at IS NULL`) y no ser un padre con variantes. Si no, `P0404 quote_product_unavailable: <nombre del snapshot>` (o `P0400 product_is_parent`, si al producto se le agregaron variantes después de cotizar);
   - el cliente del presupuesto debe seguir vivo (`clients.deleted_at IS NULL`). Si no, `P0404 quote_client_unavailable` ("el cliente fue dado de baja: editá el presupuesto y elegí un cliente vigente"). El alta y la edición exigen un cliente vivo, pero `_quote_accept_core` y el núcleo de venta sólo comparan `account_id`, y no existe un guard de baja de clientes: sin este chequeo, una conversión a crédito postearía deuda contra un cliente que el panel de cobranzas y el digest de vencidos excluyen (`c.deleted_at IS NULL`).
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

   Con `kind = 'cash'` el núcleo **exige** la sesión de caja (`P0400 cash_requires_session`, `20261062000001:1250`): es la semántica del POS, no el opt-in del formulario de venta. El diálogo (D12) resuelve la sesión y la envía siempre.

   Después de la llamada se lee su resultado: si vuelve `replayed = true`, `RAISE 'idempotency_key_conflict' USING ERRCODE = 'P0409'`. Ese caso es una conversión concurrente con la **misma clave** sobre **otro** presupuesto: las dos vieron la clave libre en el paso 3 (cada una bloquea su propio presupuesto), y ésta esperó en el `ON CONFLICT DO NOTHING` del núcleo hasta que la otra commiteó. El núcleo devuelve entonces la operación ajena sin confirmar la orden recién creada (`20261062000001:1352-1375`); sin este chequeo quedaría un presupuesto `accepted` con una orden `draft` huérfana, apuntando a la venta de otro documento. El `RAISE` revierte la aceptación y la orden.
7. Devuelve `{quote_id, quote_number, sales_order_id, operation_id, total, replayed: false}`.

Consecuencias:

- **Cualquier fallo revierte todo.** El presupuesto queda en su estado anterior (no queda `accepted` sin venta) y no queda ninguna orden `draft`. Stock insuficiente → `P0409` del núcleo, con el mismo literal que la UI ya traduce (`stock_insuficiente para producto <id>`).
- **La venta es facturable sin cambios.** Es una `sales_orders` `confirmed` con `sale_operation_id`, el mismo estado que deja el POS, así que `EmitInvoiceButton`/`POST /sales-orders/{id}/emit-invoice` y "Facturar" desde `/ventas` funcionan tal cual. Borrarla o editarla sigue las reglas vigentes de la venta del POS (`operation-delete-compensation`: cancela la orden), salvo que tenga líneas de servicio: ésa no se edita desde `/ventas` (ver "Líneas de servicio", OQ-P16). El presupuesto **queda `accepted`**, que es terminal: una venta borrada no "reabre" el presupuesto. Para volver a vender, se duplica (OQ-P12).
- **Snapshots de la venta**: producto, cantidad, unidad, precio y subtotal vienen del presupuesto, y las `sales_order_items` heredan sus snapshots sin re-leer el maestro. Las filas legacy `sales`/`sale_items` y el costo de `stock_movements` los congela el núcleo al confirmar desde el maestro vigente (`20261062000001:1437-1447`), igual que en una venta del POS: el costo de la venta es el del día de la venta. No se toca el núcleo para cambiarlo.
- **Líneas de servicio**: se convierten. El núcleo inserta su fila legacy de `sales` sin producto ni descripción y sin `sale_items` (`20261062000001:1462-1476`); la descripción queda en `sales_order_items.name_snapshot`, que es lo que usa la factura. El read model de `/ventas` (tarea 6.6) resuelve la descripción de esas filas desde las líneas sin producto de la misma orden, emparejando por precio, cantidad, subtotal y unidad. Si dos líneas de servicio de la misma venta coinciden en esos cuatro valores, las dos muestran la misma descripción (límite declarado, OQ-P15). Hasta este change ningún camino de venta generaba líneas de servicio, así que el hueco es nuevo y se cierra acá.
  - **Edición de esa venta**: el editor de `/ventas` (`sale-form.tsx:135-150`) rehidrata cada fila como `SaleCartItem`, cuyo `productId` es obligatorio. `SaleOperationUpdateItemIn.product_id` también lo es, y la descripción vive sólo en `sales_order_items.name_snapshot`. En este change la acción "Editar" de `/ventas` se **deshabilita** para una operación con alguna fila sin producto, con el motivo "Incluye conceptos sin producto de un presupuesto: no se edita desde acá. Para corregirla, eliminala y volvé a venderla desde el presupuesto duplicado". El read model de ventas expone `has_service_lines` (derivado, sin columna).
    - Del lado del servidor no queda un invariante roto: un request armado a mano con `product_id` nulo lo rechaza el schema (422), y uno que omite la línea de servicio es una edición legítima (quitar una línea) que `rpc_atomic_update_sale_operation` ya soporta.
    - El borrado funciona: la reversa de stock recorre los `stock_movements` de la operación, y las filas sin producto no tienen.
    - Soportar la línea de servicio en `sale-form` queda como candidato (OQ-P16).
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
  - Para cada uno, `record_status_transition(account_id, 'quote', id, status, 'expired', '00000000-0000-0000-0000-000000000000'::uuid, 'vencimiento automático')` y `UPDATE status = 'expired'`. El actor es el **uuid cero**, la convención de "sistema" del proyecto (`20261060000001:311`, igual que `rpc_record_fiscal_transition`): `document_status_history.performed_by` es `NOT NULL` (`20260807000001:91`), así que un actor NULL abortaría cada corrida con `23502` y ningún presupuesto vencería nunca. La fila `draft|sent → expired` tiene `allowed_role` NULL (exención 2 del helper), así que el uuid cero no necesita rol.
  - Idempotente: una segunda corrida no encuentra filas. Devuelve la cantidad vencida.
  - `SKIP LOCKED` evita esperar a una conversión en curso sobre el mismo presupuesto: si la conversión gana, el presupuesto queda `accepted` y el barrido no lo toca al día siguiente.
- **Cron**: `cron.unschedule` + `cron.schedule('quotes-expire-sweep', '5 3 * * *', …)`. Corre a las 03:05 UTC (00:05 ART), así que un presupuesto "válido hasta ayer" amanece vencido. Es el molde de `cobranzas-overdue-digest-sweep`.
- **Derivación al leer**: el read model devuelve `is_expired = status IN ('draft','sent') AND valid_until < reporting_local_today()`. La UI lo muestra como "Vencido" aunque el barrido todavía no haya corrido, y deshabilita "Venta" con la explicación. La conversión igual lo rechaza (`quote_expired`), como hoy.
- **Validez por defecto**: `accounts.default_quote_validity_days` (15) + `rpc_set_default_quote_validity(p_days integer)`:
  - `SECURITY DEFINER`;
  - guard **owner/admin** (`CAN_CONFIGURE`: es configuración de la cuenta, igual que las formas de pago) → `P0403 insufficient_role`;
  - rango 1..365 (`P0400`).
  
  Endpoints `GET/PATCH /settings/quotes`, que es el molde exacto de `/settings/collections`.
  - *Rechazado*: una tabla `quote_settings`. Es un solo valor y la Regla de Tres no se alcanza. La columna sigue el precedente de `default_payment_terms_days`.
- **Dónde se configura en la UI**: una tarjeta **"Presupuestos — validez por defecto"** dentro de la pestaña **Cobranzas** de `/configuracion`, debajo del plazo de pago. `/presupuestos` muestra "Validez por defecto: 15 días · Cambiar" con un enlace a `/configuracion?tab=cobranzas`.
  - Justificación: la pestaña ya reúne las **condiciones comerciales hacia el cliente** (plazo de pago); la validez de la cotización es de la misma familia.
  - La barra tiene 11 pestañas (`balanza-etiquetas-pos` sumó la 11ª, con una deuda de medición visual declarada). Una 12ª pestaña para un solo número es desproporcionada.
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

- **Emisor** (`resolve_commercial_issuer(account_id)` en el service, función pura sobre lo que devuelve la RPC `rpc_commercial_issuer(p_account_id uuid) → jsonb`):
  - nombre: `fiscal_profiles.nombre_fantasia` → `fiscal_profiles.razon_social` → `profiles.business_name` del `accounts.owner_user_id` → "Mi Negocio";
  - razón social y CUIT si hay perfil fiscal;
  - domicilio comercial si está cargado;
  - teléfono del perfil del dueño (`profiles.phone`). **Sin email**: `profiles` no tiene columna de email, y tomar el de `auth.users` imprimiría el email de acceso del dueño en un documento para terceros.
  - **Por qué una RPC `SECURITY DEFINER`**: el endpoint corre con la conexión del request, que en prod adopta `authenticated` (tenancy Paso 2). La única política de lectura de `profiles` para un no administrador es `auth.uid() = id` (`20260517000003:354-356`). Leído por la conexión de usuario, el perfil del dueño vuelve vacío cuando descarga un vendedor, un administrador o un cajero que no es el dueño, y el PDF sale en silencio con "Mi Negocio" y sin teléfono. La RPC:
    - es `STABLE` con `SET search_path = public`;
    - exige `p_account_id IN (SELECT current_account_ids())` → `P0404 account_not_found` (quien no es miembro no lee el emisor de otra cuenta);
    - devuelve **sólo** `nombre_fantasia`, `razon_social`, `cuit` y `domicilio_comercial` del perfil fiscal, y `business_name` y `phone` del perfil del dueño; ningún otro dato de `profiles`;
    - lleva `REVOKE ALL … FROM PUBLIC, anon` + `GRANT EXECUTE … TO authenticated`.
    
    La cascada del nombre la resuelve el service en Python (pura, testeable). El gate la ejecuta como un vendedor que no es el dueño y verifica que recibe el `business_name` del dueño.
  - *Rechazado*: reutilizar `_issuer` de `services/fiscal/invoice_pdf.py`. Completa campo por campo una foto fiscal persistida en el comprobante; no resuelve un emisor comercial desde la cuenta. Tampoco hay en el backend un repositorio que lea el `profiles` de otro usuario para un miembro (sólo los de administración, con service conn), así que no hay lectura que reutilizar: nace la RPC.
  
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

- `frontend/lib/document-share.ts`: `downloadBlob(blob, fileName)`, `sharePdf(file, text, title)` y `openWhatsAppText(phone, text)` (envuelve `buildWhatsAppUrl` y devuelve si había número válido). Único cambio de contrato: `sharePdf` devuelve `"shared" | "cancelled" | "unsupported"`, porque hoy la cancelación del usuario vuelve como `"shared"` (`sale-receipt-button.tsx:93`). `sale-receipt-button.tsx` trata `"cancelled"` igual que hoy trata `"shared"`, así que su comportamiento no cambia; el menú nuevo lo necesita para no marcar como enviado un presupuesto que el usuario no mandó.
- `frontend/lib/api/document-pdf.ts`: `fetchDocumentPdf(path, params) → Blob | null` (encabezados de `getAuthHeaders`; `null` si `redirectedOnUnauthorized`; `DocumentPdfError(code, message)` desde el RFC 7807).
- `sale-receipt-button.tsx` y `fiscal-invoice.ts` pasan a importarlos. Sus tests existentes son el safety net y deben seguir verdes sin cambios.

**Componente** `frontend/components/shared/DocumentShareMenu.tsx`. Props: `fetchPdf(disposition)`, `fileName`, `shareText`, `shareTitle`, `clientPhone`, `onShared?()`. Tres acciones:

- **Ver / Imprimir**: abre la pestaña **dentro del gesto** del usuario (Safari iOS) y le carga el blob `application/pdf` cuando llega. Si el navegador la bloquea, descarga. Mismo flujo que "Ver / imprimir factura".
- **Descargar PDF**.
- **Enviar por WhatsApp**:
  - en el celular, share nativo con el **archivo**;
    el share nativo exige la activación del gesto del usuario, que en Safari iOS expira después de los `await` del fetch. Por eso el menú **precarga** el PDF al abrirse y llama a `sharePdf` sincrónicamente dentro del toque cuando el blob ya está; si todavía no llegó, muestra "Preparando…" y pide un segundo toque;
  - en escritorio, descarga del PDF + `wa.me/<teléfono>?text=` con un texto corto y un toast "Adjuntalo en el chat que se abrió";
  - sin número válido, `wa.me/?text=` con el aviso "no hay número de WhatsApp registrado para este cliente". Es el mismo texto del comprobante de venta.

Descargar (cuando la descarga ocurrió) y WhatsApp (con `"shared"` o con el fallback de descarga + `wa.me`, nunca con `"cancelled"`) llaman a `onShared`; "Ver" no. En el detalle del presupuesto, `onShared` se pasa **sólo** si el usuario tiene `CAN_QUOTE` (espejo de D11) y el presupuesto está en `draft`: un cajero descarga el PDF sin cambiar el estado. `onShared` dispara `rpc_transition_quote('sent')` e invalida la query; si falla, no muestra error (la descarga ya funcionó) y el estado se corrige en la próxima lectura.

- *Por qué "Ver" no marca enviado*: mirar el PDF propio antes de mandarlo es el uso más común, y marcarlo mentiría el estado.

**Texto corto de WhatsApp**: "Hola {nombre}, te envío el presupuesto P-00000012 por $ 12.345,00, válido hasta el 14/10/2026. {negocio}". Función pura `buildQuoteShareText` en `lib/quote-share.ts`. Si falta el nombre, sin saludo personalizado.

- *Rechazado*: link público firmado. Es una capability nueva con governance ALTA (ruta pública, token, revocación, exposición de datos del cliente) y queda para un change posterior (OQ-P6).

### D10 — UI de `/presupuestos`

- **Sidebar**: `{ title: "Presupuestos", href: "/presupuestos", icon: FileText }` (ícono de `lucide-react`; `FileText` ya se usa en el repo) en *Operaciones*, entre "POS — Venta Rápida" y "Compras". Sin gate de plan (D13). La ruta queda protegida por defecto (`lib/auth/route-access.ts` protege todo `app/(dashboard)` por exclusión).
- **Breadcrumb** (`breadcrumb-nav.tsx`), con su mecanismo real: `PAGE_NAMES` por ruta completa, `PAGE_PREFIX_NAMES` por prefijo y `nameFromLastSegment` como respaldo. `/presupuestos` → "Presupuestos" y `/presupuestos/nuevo` → "Nuevo presupuesto" en `PAGE_NAMES`; `/presupuestos/<id>/editar` → "Editar presupuesto" y `/presupuestos/<id>` → "Detalle de presupuesto" se resuelven antes del respaldo, que mostraría el uuid capitalizado. "nuevo" nunca cae en la regla del detalle porque la ruta completa gana.
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
| `draft` | Editar · Compartir (`DocumentShareMenu`) · **Venta** · Rechazar · Duplicar · Eliminar (sólo si nunca se envió) |
| `sent` | Editar · Compartir · **Venta** · Rechazar · Duplicar |
| `draft\|sent` vencido | Editar (para ampliar la validez) · Compartir · Duplicar · Rechazar. "Venta" deshabilitada con "Vencido el …: ampliá la validez o duplicalo" |
| `accepted` | Compartir · Duplicar · Ver venta |
| `expired` / `rejected` | Editar (reabre a `draft`, D5; exige validez ≥ hoy) · Compartir · Duplicar |

Un vencido derivado (`is_expired`, el barrido todavía no corrió) y uno ya marcado `expired` muestran el mismo aviso ("Vencido el …: editalo para ampliar la validez o duplicalo") y la misma acción "Editar".

- **Ficha del cliente** (`/clientes/[id]`): botón "Nuevo presupuesto" → `/presupuestos/nuevo?cliente=<id>` en `ClientDetailHeader`, visible en todas las pestañas, y una **pestaña nueva** "Presupuestos" (`/clientes/[id]/presupuestos`) con los últimos 5 del cliente (`GET /quotes?client_id=`) y enlace al listado filtrado (OQ-P7). La pestaña activa de `ClientDetailHeader` hoy se deriva como `isHistorialActive = !isCuentaActive`; con tres pestañas pasa a compararse por la ruta de cada una.
- **`/ventas`**: la operación nacida de un presupuesto muestra el badge "Desde presupuesto P-00000012", con enlace. El read model de ventas y órdenes gana `source_quote_id` y `source_quote_number` derivados de `sales_orders.source_quote_id → quotes`, sin columnas denormalizadas, y `has_service_lines`. Con `has_service_lines`, "Editar" queda deshabilitado con su motivo (D6, OQ-P16).
- **Errores**: `lib/operation-errors.ts` gana las traducciones accionables de `quote_locked_converted`, `quote_expired`, `quote_invalid_state`, `quote_product_unavailable`, `quote_client_unavailable`, `quote_not_deletable`, `quote_valid_until_in_past`, `quote_valid_until_required`, `quote_changed` ("El presupuesto cambió mientras lo tenías abierto: revisalo y volvé a intentar"), `product_not_found`, `product_is_parent`, `insufficient_role` (403 / `P0403`: "Tu rol no permite …"), `cash_requires_session`, `idempotency_key_conflict` y `payment_method_required`. `stock_insuficiente` ya existe y se reutiliza.
- **Design system**: tokens semánticos, componentes base con `cva`, `ResponsiveModal` para los diálogos, verificación en desktop y 375 px × claro y oscuro (regla del PO).

### D11 — Permisos: capacidad `CAN_QUOTE` que espeja la FSM

`backend/core/rbac.py` suma `CAN_QUOTE = frozenset({"owner", "admin", "seller"})`, el mismo conjunto que el catálogo declara para las transiciones de `quote`. Aplica así:

| Operación | Guard en el service | Guard en la base |
|---|---|---|
| Listar, ver, PDF | miembro de la cuenta | RLS `SELECT` |
| Crear, editar, enviar, rechazar, eliminar, convertir | `require_account_role(conn, auth, CAN_QUOTE)` | `is_account_writer` (`P0401`) + rol `CAN_QUOTE` (`P0403`): verificado por la RPC en crear, editar y borrar, y por `record_status_transition` en las transiciones |
| Validez por defecto | `CAN_CONFIGURE` | guard owner/admin en `rpc_set_default_quote_validity` |

- `rpc_create_quote`, `rpc_update_quote` y `rpc_delete_quote` verifican el rol por sí mismas **antes** de escribir, con el mismo predicado que usa el helper de transiciones (roles activos no vencidos del actor en la cuenta ∩ `{seller, admin, owner}`) → `P0403 insufficient_role`. Es el mismo código que devuelve `record_status_transition` (y que `backend/core/errors.py` ya mapea a 403): todo rechazo por rol es `P0403`, y `P0401` queda sólo para quien no es escritor de la cuenta. En el alta, el disparador de creación lo volvería a validar, pero el chequeo explícito primero evita depender de un efecto lateral.
- Se retira `require_role(auth, ["user","admin"])` (legacy) de `services/quotes.py`.
- El frontend decide con un espejo canónico, `frontend/lib/rbac-capabilities.ts` (`CAN_QUOTE`, `hasCapability(roles, cap, rolesResolved)`), atado por test al conjunto de `backend/core/rbac.py`, y evaluado sobre el **conjunto** `roles` de `useOrgRole`, no sobre el `role` singular: ese colapsa a `member` a un usuario que sólo es vendedor (`hooks/useOrgRole.ts:48-53`) y le ocultaría el módulo al usuario principal.
  - **Fail-open mientras carga, con un indicador real.** `useOrgRole` hoy no expone si el conjunto resolvió: mientras carga, `roles` vale `[role]`, que para un vendedor es `["member"]` (`hooks/useOrgRole.ts:89-90`). Decidir sobre eso sería fail-closed: el vendedor no vería "Nuevo presupuesto" y una descarga en ese intervalo no marcaría `sent`. El hook suma `rolesResolved: boolean` (el `isSuccess` de la consulta del conjunto) y `hasCapability(roles, cap, rolesResolved)` responde `true` mientras no resolvió (fail-open, como `isWriter`) y decide sobre el conjunto cuando resolvió.
  - El backend es la fuente de verdad. Lo usan el listado, el detalle, la ficha del cliente y el `onShared` de D9.

### D12 — Backend 3 capas y `QuoteForm` en el frontend

**Backend**:

- `schemas/quotes.py`:
  - `QuoteItemIn` suma `description: str | None` (obligatoria si no hay `product_id`, `max_length=200`).
  - `QuoteIn`: `client_id: UUID` (**obligatorio**), `notes` (`max_length=2000`) y `valid_until`.
  - Se retira `subtotal` como fuente del total: se sigue enviando por línea (lleva el descuento), pero el total lo calcula la RPC.
  - `QuoteUpdateIn` (con `revision`, la versión que se editó), `QuoteOut` (`number`, `number_label`, `revision`, `notes`, `sent_at`, `updated_at`, `is_expired`, `client_name`, `client_phone`, `sales_order_id`, `items`, `history`), `QuoteListItemOut`, `QuoteConvertIn` (`expected_revision`, `payment_method_id`, `branch_id?`, `cash_session_id?`, `bank_account_id?`, `canal?`, `idempotency_key?` como fallback del header), `QuoteConvertOut` y `QuoteSettingsIn/Out`.
  - `QuoteTransitionIn.action` pasa a `{"send","reject"}` + `reason` opcional.
- `repositories/quote_repository.py`: todo por RPC o por `SELECT` con `account_id` explícito. El listado hace `JOIN clients` para nombre y teléfono y deriva `is_expired`.
- `services/quotes.py`: guards (D11), mapeo de errores a RFC 7807 con `ProblemHTTPException` (`code` estable = literal del error SQL), sin `HTTPException` crudo. Se retira el pre-chequeo Python `client_belongs_to_account` de `create_quote`, y el método del repositorio: la tenencia del cliente la resuelve la RPC con `P0404 client_not_found`, que el service mapea a 404. Los bloques 5 y 6 de `backend/tests/test_operacion_party_guard.py`, que prueban ese pre-chequeo y `accept_quote`, se reescriben sobre el contrato nuevo (tarea 2.6).
- `routers/quotes.py`: `POST /quotes/{id}/convert` usa `require_idempotency_key(request, payload.idempotency_key)`, como `/sales-orders/quick-sale`.
- `POST /quotes/{id}/accept` **se retira**. No tiene consumidores y dejaría un presupuesto `accepted` (que en la UI significa "convertido en venta", D1) con una orden `draft` que ninguna pantalla muestra: el mismo hueco por el que se rechazó A2. La RPC `rpc_accept_quote` se conserva como wrapper del núcleo (D6), para su regresión SQL y sin `EXECUTE` para los roles de aplicación; `useAcceptQuote` desaparece con la reescritura de `use-quotes.ts`.

**Frontend**:

- `hooks/data/use-quotes.ts` se reescribe sobre el contrato nuevo: `useQuotes(filters)` paginado, `useQuote(id)`, `useCreateQuote`, `useUpdateQuote`, `useTransitionQuote`, `useDeleteQuote`, `useConvertQuote` (con `useIdempotencyKey`), `useQuoteSettings` y `useUpdateQuoteSettings`.
- `useConvertQuote` invalida `quotes.*` más `invalidateAfterSale(queryClient)`, un helper nuevo en `lib/query-invalidation.ts` que es la **unión** de lo que toca una venta: `salesOrders`, `sales`, `branchStock`, `products` (el stock del catálogo que muestran `ProductPicker` y `QuoteForm`), `customerAccounts`, `receivables`, `cashSessions`, `cashMovements` y `bankAccounts`. Lo consumen también las dos mutaciones de `hooks/data/use-sales-orders.ts` (`:240-253` y `:320-329`), que hoy repiten una lista sin caja, banco ni productos: después de vender, el POS deja `/caja`, `/banco` y el stock del catálogo desactualizados (hallazgo; se corrige de paso).
- La clave de idempotencia de la conversión la maneja el diálogo con `useIdempotencyKey("quote-convert:" + quoteId)`, y se resetea tras cada éxito, incluido el replay. Así una respuesta perdida de la conversión del presupuesto A no contamina la del B (un scope global devolvería `idempotency_key_conflict` en el botón "Venta").
- **`components/quotes/QuoteForm.tsx`**: el editor de líneas se arma con las piezas compartidas que ya usa el formulario de venta:
  - `ProductPicker`, `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput` + `resolveScan` (incluye etiquetas de balanza), `useScaleSettings`, `useUnitsOfMeasure`, `compatibleUnits`, `convertUnitPrice` y `roundUnitPrice`;
  - `SaleCartItem`, `calcSaleSubtotal`, `unitPriceFromSubtotal`, `calcCartTotal` y `addScannedProductLine` de `lib/cart-utils`.
  
  La lógica de carrito que hoy vive embebida en `sale-form.tsx` se extrae a funciones puras de `lib/cart-utils.ts`, y **`sale-form` se migra a ellas en el mismo PR** (sus tests son el safety net), para que haya una sola definición con dos consumidores:
  - `addManualLineToCart(cart, staged, ctx, {enforceStock})` (hoy `handleAddToCart`);
  - `applyScanToCart(cart, scanResult, ctx, {enforceStock})` (el despacho de `handleScan`: producto por unidades, medible con foco en la cantidad, etiqueta de balanza y chequeo acumulativo de stock), que devuelve las líneas o el feedback;
  - los reductores de edición de línea (`updateLineQuantity`, `updateLineSubtotal`, `removeLine`; hoy `handleUpdateQty`/`handleUpdateSubtotal`).
  
  El presupuesto pasa `enforceStock: false` y sólo muestra el disponible. El POS conserva su copia de `handleScan` (duplicación preexistente); migrarlo queda como candidato (Non-Goal).
  - **Línea de servicio** (sin producto): "Agregar concepto" con descripción, cantidad y precio (el requirement "línea de servicio sin producto" ya existe en la spec). No entra en `SaleCartItem`: su `productId` es obligatorio, y `exceedsStock` y la fusión se indexan por producto. Vive en un estado propio `QuoteServiceLine[]`, con sus helpers puros en `lib/quote-lines.ts` (alta, edición y el armado del payload `p_items`, que une las dos listas en el orden de carga).
  - **Cliente**: `SearchableSelect` de clientes vivos + "Nuevo cliente", que abre `ClientForm` (`components/forms/client-form.tsx`) en un `ResponsiveModal` y lo preselecciona al crearlo. Para eso `ClientForm.onSuccess` pasa a `(client?: Client) => void` (retrocompatible: el caller existente, `app/(dashboard)/clientes/page.tsx`, ignora el argumento) y le entrega el cliente que devuelve `addClient`, que hoy descarta. Muestra el teléfono y avisa si falta ("sin teléfono: WhatsApp abrirá el selector de contactos").
  - **Validez**: fecha con el default de la cuenta; notas; sucursal opcional (`BranchSelect`).
  - **Precio y descuento**: igual que la venta, la línea persiste el precio unitario **efectivo** (`price = unitPriceFromSubtotal(subtotal, cantidad)`, sin redondear, RN-24-bis) y su `subtotal`; el descuento no se guarda aparte. Al editar, las líneas se rehidratan con ese precio y descuento 0, como `sale-form` (`sale-form.tsx:133-143`). Así precio × cantidad = subtotal en el PDF. La comparación "precio de catálogo actual" del detalle se hace contra el precio efectivo, así que una línea con descuento aparece como distinta, con la etiqueta "precio de lista hoy", sólo informativa.
  - **Productos que ya no están**: al rehidratar (edición o duplicado), una línea cuyo producto ya no está en el catálogo vivo se marca "Producto no disponible — quitalo o reemplazalo" y bloquea el guardado con ese mensaje antes de llamar a la API. Sin esto, guardar sin tocar la línea fallaría con `product_not_found` y el mensaje de la conversión ("editá el presupuesto") no tendría salida.
  - **Duplicar** (`?duplicar=<id>`): precarga cliente, notas y líneas. Las líneas con producto toman el **precio de hoy** del catálogo, reexpresado a la unidad de la línea con `convertUnitPrice`; las de servicio conservan el suyo. Muestra un aviso con las líneas cuyo precio cambió respecto del cotizado (el precio efectivo, así que incluye las que tenían descuento: el aviso dice que los descuentos no se copian). La validez se recalcula desde hoy.
  - Envío con `useCreateQuote`/`useUpdateQuote`. Al guardar navega al detalle. La edición manda la `revision` que cargó; ante `quote_changed`, el formulario avisa "otro usuario modificó este presupuesto" y ofrece recargarlo, sin pisar los cambios ajenos.
- **`components/quotes/ConvertQuoteDialog.tsx`**:
  - resumen de líneas y total en sólo lectura;
  - `BranchSelect` (default: sucursal del presupuesto o la de la cuenta);
  - `PaymentMethodSelect` (contexto `sale`) + `BankAccountDestinationSelect` cuando el `kind` lo requiere;
  - **caja con la semántica del POS, no con el opt-in del formulario de venta**: con `kind = 'cash'` el núcleo exige la sesión (`P0400 cash_requires_session`, D6). El diálogo resuelve la sesión abierta de la sucursal elegida con la misma consulta que usa el POS y la envía siempre, sin checkbox. Si no hay sesión abierta, "Venta" queda deshabilitada con "Abrí la caja de esta sucursal para cobrar en efectivo, o elegí otra forma de pago" y un enlace a `/caja` (el mismo bloqueo que el POS, `ventas/pos/page.tsx:351-362`);
  - si la forma de pago es `credit`, el saldo actual del cliente (`useCustomerAccount`);
  - manda `expected_revision` = la `revision` del presupuesto que muestra el resumen. Ante `quote_changed`, invalida el detalle, recarga el resumen y muestra el aviso sin cerrar: el usuario confirma de nuevo sobre el total vigente.
  
  Al confirmar llama a `useConvertQuote`. En éxito (también con `replayed: true`, que se muestra igual), el diálogo pasa a un estado final: "Venta registrada" + `EmitInvoiceButton` (el de `/ventas/ordenes` y del listado de ventas; el POS no lo usa, muestra un enlace a `/ventas/ordenes`) + "Ver en Ventas" + "Cerrar". En error, el mensaje de `humanizeOperationError` dentro del diálogo, con `role="alert"`, y el presupuesto sigue abierto.
  - **Accesibilidad**: el paso a éxito mueve el foco al título "Venta registrada"; los avisos de estado (cliente sin teléfono, marcado como enviado) usan `aria-live="polite"`; los diálogos se operan con teclado.
  - **Composición pensando en los remitos**: los campos de cierre (sucursal, forma de pago, cuenta bancaria, caja, saldo del cliente) y el panel de éxito nacen en `components/ventas/SaleCheckoutFields.tsx` y `components/ventas/SaleCheckoutSuccess.tsx`, sin conocimiento del presupuesto; `ConvertQuoteDialog` sólo los compone con el resumen y `useConvertQuote`. No es un diálogo genérico (hay un solo consumidor, Regla de Tres), pero `remitos-venta` los reutiliza sin refactor.

### D13 — Sin gating de plan

Presupuestos, PDF, WhatsApp y conversión quedan disponibles en todos los tiers, igual que ventas, compras y cobranzas (OQ-P8). No se agrega entrada a `PLAN_LIMITS` ni `PlanGate`.

### D14 — Migraciones, gates y dos tandas de apply

- **Tanda A** — `20261067000001_presupuestos_modulo.sql` (idempotente por el auto-apply de Supabase GitHub):
  - columnas (incluida `revision`); `internal_document_sequences`, los dos helpers, el disparador genérico de numeración y el de validez; `accounts.default_quote_validity_days`;
  - **backfill defensivo** de las filas previas, después de crear los disparadores. El disparador sólo actúa en `INSERT`, y `POST /quotes` (escritura directa) sigue vivo hasta el deploy de A. En prod había 0 presupuestos al medir, pero un presupuesto creado entre la medición y el deploy quedaría sin número y sin vencimiento: el barrido nunca lo tocaría, porque `NULL < hoy` no es verdadero. Por eso:
    - número para cada fila con `number` NULL, con un bucle en orden de `(account_id, created_at, id)` que asigna `_assign_internal_document_number(account_id, 'quote', NULL)` (un `UPDATE` masivo no garantiza el orden);
    - `valid_until = (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date + default_quote_validity_days` donde sea NULL (`created_at` es un instante, así que el `AT TIME ZONE` es el correcto);
    - idempotente por los `WHERE … IS NULL`.
    
    Un `client_id` NULL no se puede completar: el read model lo muestra como "Sin cliente" y la edición exige elegir uno. Sólo pasa en filas anteriores a A;
  - las dos filas nuevas del catálogo de transiciones (`quote: expired → draft`, `rejected → draft`) y `is_terminal_to = false` en `quote: draft|sent → expired|rejected` (D4);
  - las 6 RPCs de D2, D7 y D8 (incluida `rpc_commercial_issuer`), con `CREATE OR REPLACE` y firmas nuevas: no hay overload previo, así que no hay riesgo de `42725`;
  - `DROP POLICY IF EXISTS` de las 4 políticas de escritura;
  - barrido y cron;
  - bloque `DO` de introspección al final: columnas, `UNIQUE`, los dos disparadores, que las 4 políticas no existan, los `is_terminal_to` de `quote` (sólo `accepted` terminal), 0 filas con `number` o `valid_until` NULL, ACLs sin `anon`, helpers sin `authenticated` y job de cron presente.
- **Tanda B** — `20261068000001_presupuestos_conversion_venta.sql`:
  - `_quote_accept_core` desde el cuerpo vivo (checkpoint);
  - `rpc_accept_quote` como wrapper (`CREATE OR REPLACE`, misma firma; `COMMENT` vivo re-declarado) + `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated` (D6);
  - `rpc_convert_quote_to_sale`;
  - introspección: una sola definición de cada función, el cuerpo de `rpc_accept_quote` delega, el núcleo y `rpc_accept_quote` sin `authenticated`, y la RPC nueva sin `anon`.
- **Gates** (se ejecutan de verdad; regla del proyecto: "toda RPC que otras invocan necesita un gate que la EJECUTE"):
  - `supabase/tests/test_presupuestos_modulo.sql` (A):
    - dos cuentas; owner, seller y cashier reales (membresía en `account_members` y roles en `account_member_roles`, el molde de `test_document_status_transition_role_matrix.sql`); fixtures propios y cleanup asertado;
    - numeración correlativa por cuenta, independiente entre cuentas; un alta que falla no consume número; un número explícito avanza la secuencia; `valid_until` NULL completado por el disparador;
    - alta sin cliente, con cliente ajeno o dado de baja, con producto ajeno, padre con variantes, unidad incompatible o unidad de otra cuenta en una línea de servicio → cada uno con su código;
    - snapshot del producto propio y nunca del ajeno;
    - total calculado en el servidor;
    - crear no toca `branch_stock` ni caja;
    - edición en `draft` y `sent` re-toma snapshots y exige `valid_until` (`P0400 quote_valid_until_required`); edición de `expired` o `rejected` lo reabre a `draft` con historial; edición de `accepted` → `P0423 quote_locked_converted`;
    - `sent` idempotente; `rejected` con historial;
    - el cashier no crea, no edita ni borra (`P0403 insufficient_role`); un no escritor → `P0401`; PostgREST (`SET ROLE authenticated`) no puede `INSERT`/`UPDATE` directo;
    - borrado sólo en `draft` nunca enviado;
    - regresiones que antes se daban por cubiertas con gates inexistentes: el guard de baja de producto sigue rechazando con `P0B04` si el producto está en un presupuesto `draft`, y el alta registra el historial `NULL → draft` con el creador;
    - `_expire_overdue_quotes` ejecutado de verdad: vence, registra el historial con el actor uuid cero y el motivo (si la inserción del historial abortara, el gate falla), es idempotente y no toca `accepted`;
    - `rpc_set_default_quote_validity`: rango y rol;
    - catálogo: `is_terminal_status('quote','expired')` y `('quote','rejected')` falsos, `('quote','accepted')` verdadero, y ninguna transición del catálogo sale de un estado terminal;
    - versión: la edición incrementa `revision`; una edición con una versión vieja → `P0409 quote_changed` y el presupuesto no cambia; `sent` y `rejected` no la tocan;
    - borrado bajo lock: el `DELETE` lleva el predicado de estado (un borrado sobre una fila que dejó de ser `draft` nunca enviado no borra nada);
    - `rpc_commercial_issuer` ejecutado con `SET ROLE authenticated` como un vendedor que **no** es el dueño: devuelve el `business_name` y el teléfono del dueño; como usuario de otra cuenta → `P0404`.
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
    - cashier → `P0403`;
    - `cash` sin sesión de caja → `P0400 cash_requires_session` y cero efectos;
    - cliente dado de baja después de cotizar → `P0404 quote_client_unavailable`, sin cargo en `customer_account_movements`;
    - producto al que se le agregaron variantes → `P0400 product_is_parent`;
    - presupuesto con una línea de servicio: se convierte y la orden conserva la descripción en `sales_order_items.name_snapshot`;
    - snapshots: precio del presupuesto en la venta, `unit_cost_snapshot` = costo vigente al convertir y `sales_order_items` con los snapshots del presupuesto;
    - `SET ROLE authenticated` + claims → `rpc_accept_quote` rechazada por permisos (`42501`), sin orden nueva: PostgREST no llega a `accepted` fuera de la conversión;
    - versión vieja (el presupuesto se editó después de abrir el diálogo) → `P0409 quote_changed` y cero efectos;
    - presupuesto ya `accepted` con un producto dado de baja después, convertido con otra clave → `P0409 quote_invalid_state` (el estado se valida antes que los guards de convertibilidad).
  - `supabase/tests/test_presupuesto_a_venta_race.sh` (molde: `test_ventas_unidades_conversion_race.sh`):
    - dos sesiones `psql` convierten el mismo presupuesto a la vez → exactamente una venta y un `accepted`; la otra recibe `quote_invalid_state` o replay;
    - la **misma clave** sobre **dos presupuestos distintos** en paralelo → una venta, un `P0409 idempotency_key_conflict`, el otro presupuesto intacto y 0 órdenes `draft`;
    - **borrado contra conversión** del mismo `draft` nunca enviado → gana uno: o queda la venta con el presupuesto `accepted` y su `source_quote_id` intacto (el borrado recibe `quote_not_deletable`), o el presupuesto se borra y la conversión recibe `quote_not_found`. Nunca una venta con `source_quote_id` NULL.
  - `supabase/tests/test_internal_document_numbering_race.sh`: N sesiones crean a la vez el primer presupuesto de una cuenta sin fila de secuencia (ejercita el `INSERT` concurrente y el reintento) → números 1..N sin huecos ni repetidos.
  - `test_function_acl_gate.sql`: en la tanda A, sin cambios de código si los nombres siguen la convención; se verifica que las funciones nuevas quedan clasificadas. En la tanda B, `rpc_accept_quote(uuid)` entra al chequeo (3) (D6).
  - `test_document_status_transition_role_matrix.sql` **se actualiza en cada tanda**: exige el tamaño exacto del catálogo (bloque 1: hoy 20 filas, 14 con rol), el conjunto exacto de llamadores de `record_status_transition` (bloque 5b) y el de pares producidos (bloque 5). Tanda A: el bloque (1) pasa a 22 filas / 16 con rol (el conjunto de las 6 filas NULL no cambia, porque las dos nuevas no son de sistema), con su comentario y su NOTICE; además suma `rpc_update_quote`, `rpc_transition_quote` y `_expire_overdue_quotes`, y los pares `quote:draft->sent`, `draft/sent->rejected`, `draft/sent->expired`, `expired->draft` y `rejected->draft`. Tanda B: `rpc_accept_quote` deja de ser llamador y entra `_quote_accept_core`.
  - `test_operacion_party_guard.sql`, bloque (7), **se adapta en la tanda B**: su candado de cuerpo busca `client_not_found` antes de `INSERT INTO public.sales_orders` en `rpc_accept_quote`, que pasa a ser un wrapper sin ninguna de las dos cadenas. Se redirige a `_quote_accept_core(uuid, uuid)` (el guard sigue antes del `INSERT`) y se suma un assert de que `rpc_accept_quote` delega en el núcleo. El bloque (8), que hoy exige `EXECUTE` de `authenticated` sobre `rpc_accept_quote`, se invierte para esa función: sin `anon` y sin `authenticated` (D6).
  - Todos cableados en `KPI_Validation.yml`, en el orden real del workflow, y las dos migraciones sumadas al final de la cadena de reaplicación de idempotencia.
- **Apply en dos PRs** (A, luego B), cada uno con su CI verde. La tanda A ya entrega valor por sí sola: crear, editar, descargar y mandar por WhatsApp. El botón "Venta" aparece recién con B; en A, el detalle muestra la acción deshabilitada con la leyenda "Próximamente", o se oculta (decisión del apply, sin impacto en specs).

## Risks / Trade-offs

- **[Doble conversión concurrente]** → `FOR UPDATE` sobre `quotes` antes de todo, idempotencia leída después del lock, gate de carrera con dos sesiones reales.
- **[Presupuesto editado mientras otro lo convierte o lo edita]** → versión (`revision`) esperada en la edición y en la conversión; `P0409 quote_changed` en vez de cobrar un total que nadie confirmó o de pisar una edición ajena (D1, D5, D6).
- **[Borrado concurrente con la conversión]** → `rpc_delete_quote` toma el lock y borra con el predicado de estado; caso en el gate de carrera (D2).
- **[`rpc_accept_quote` alcanzable por PostgREST]** → se revoca su `EXECUTE` de los roles de aplicación en la tanda B, con el bloque (8) de `test_operacion_party_guard.sql` invertido y el chequeo (3) del gate de ACLs (D6).
- **[Emisor vacío para quien no es el dueño]** → `rpc_commercial_issuer` `SECURITY DEFINER`, ejecutada en el gate como un vendedor no dueño (D8).
- **[Misma clave de idempotencia sobre dos presupuestos en paralelo]** → el núcleo devolvería `replayed` con la venta ajena; la RPC lo convierte en `P0409` (D6, paso 6) y el gate de carrera lo cubre.
- **[Barrido que aborta]** → el historial exige actor: el barrido usa el uuid cero (D7) y el gate lo ejecuta de verdad.
- **[Clave de idempotencia reutilizada contra otro presupuesto]** devolvería la venta de otro documento → `P0409 idempotency_key_conflict`, con assert en el gate.
- **[Reescribir `rpc_accept_quote` desde un cuerpo que no es el vivo]**, que es cómo se perdió el bloque `credit` en julio → checkpoint 0.3 con el `pg_get_functiondef` de prod comparado por líneas sin `\r` contra `20261045000001`; el diff del núcleo contra el cuerpo vivo tiene que ser exactamente los dos cambios de D6; `COMMENT` conservado.
- **[Retirar las políticas de escritura rompe a un escritor no listado]** → checkpoint 0.4 (grep en las cuatro raíces + los gates SQL y los bloques `DO` de migración que insertan en `quotes`), gates existentes re-ejecutados (`test_operacion_party_guard.sql`, `test_ventas_unidades_conversion.sql`, `test_document_status_transition_role_matrix.sql`, `test_function_acl_gate.sql`, `test_accounts_privilege_columns.sql`) y `backend/tests/test_c29_quote_salesorder.py` migrado. `test_c29*`, `test_document_status_history*` y `test_v3_soft_delete*` no existen como archivos (son bloques `DO` de migraciones viejas): lo que este change necesita de ellos (el guard `P0B04` y el historial de creación) se re-verifica en bloques propios de `test_presupuestos_modulo.sql`.
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
   - backfill defensivo de número y validez (D14): en prod había 0 presupuestos al medir, pero `POST /quotes` sigue vivo hasta el deploy;
   - verificación post-merge (sólo lectura): `MAX(version)`, columnas, `UNIQUE`, disparador, políticas de escritura ausentes, ACLs, `cron.job` con `quotes-expire-sweep`, `default_quote_validity_days = 15` en las 41 cuentas, 0 presupuestos con `number` o `valid_until` NULL, y sólo `accepted` terminal para `quote`;
   - humo del PO: crear, editar, descargar, WhatsApp desde el celular, rechazar, duplicar y eliminar.
2. **Tanda B**:
   - merge → `20261068000001`;
   - verificación post-merge: una sola definición de `rpc_accept_quote` que delega y sin `EXECUTE` para `authenticated`; `_quote_accept_core` sin `authenticated`; `rpc_convert_quote_to_sale` sin `anon`;
   - humo del PO: presupuesto → Venta (efectivo con caja abierta y a crédito) → aparece en `/ventas` → Facturar → comprobante autorizado.
3. **Rollback**:
   - A: revertir el PR de frontend y backend deja las columnas y la tabla sin uso. Si hiciera falta volver a escritura directa, una migración nueva recrea las 4 políticas desde `20260702000001`.
   - B: re-aplicar el cuerpo anterior de `rpc_accept_quote` (el vivo capturado en 0.3) en una migración nueva, con su `GRANT EXECUTE … TO authenticated`, y `DROP FUNCTION rpc_convert_quote_to_sale`. Las ventas ya generadas son ventas normales del POS y no necesitan reparación.

## Sign-off del PO

**Requisitos firmados (2026-09-29, textuales)**: los cuatro de §Context. Son requisitos, no Open Questions. En particular, **la edición del presupuesto mientras no esté convertido está firmada** y es la base de D5.

**Open Questions**: **firmadas por el PO el 2026-10-01** (tarea 0.1). Respuesta textual: «Anda con todo lo recomendado me parece bien».
- Cubre las OQ-P1..P8 del explore.
- OQ-P9..P16 se adoptan por su recomendación (default declarado, mismo criterio que los changes anteriores).
- El requisito textual «quiero que tanto el remito como los presupuestos se puedan modificar» ya está incorporado (D5).
- Ninguna alternativa fue elegida, así que no cambia ninguna decisión, spec ni tarea.

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
  - *Recomendado*: **no directamente**. Se **amplía la validez** editándolo (D5), esté o no marcado `expired` por el barrido (si lo estaba, la edición lo reabre a `draft`), o se **duplica** con los precios de hoy.
  - *Alternativa*: permitir convertir vencidos con una confirmación explícita.
- **OQ-P6 — Canales de envío v1.**
  - *Recomendado*: **sólo descarga/impresión y WhatsApp** (D9). El link público, la aceptación online y el email van en un change posterior con governance ALTA.
- **OQ-P7 — Presupuestos desde la ficha del cliente.**
  - *Recomendado*: **sí**. Botón "Nuevo presupuesto" y sección con los últimos 5 (D10). Es barato y es donde el comercio mira al cliente.
- **OQ-P8 — Plan.**
  - *Recomendado*: **sin gate**, todos los tiers (D13).
- **OQ-P9 — Dónde se configura la validez por defecto.**
  - *Recomendado*: tarjeta en la pestaña **Cobranzas** (condiciones comerciales hacia el cliente) + enlace desde `/presupuestos` (D7).
  - *Alternativas*: una 12ª pestaña "Presupuestos", o un control dentro de `/presupuestos`.
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
- **OQ-P14 — Estado al que reabre la edición de un vencido o rechazado.**
  - *Recomendado*: **`draft`** (D5). La versión editada todavía no se mandó; la próxima descarga o envío la pasa a `sent`.
  - *Alternativa*: volver al estado previo (`sent` si ya se había enviado). Exige dos filas más del catálogo (`expired|rejected → sent`) y deja un `sent` que el cliente todavía no vio.
- **OQ-P15 — Descripción de las líneas de servicio en `/ventas`.**
  - *Recomendado*: **convertirlas** y resolver su descripción en el read model desde `sales_order_items.name_snapshot`, emparejando por precio, cantidad, subtotal y unidad (D6). Si dos líneas de servicio de la misma venta coinciden en esos cuatro valores, las dos muestran la misma descripción; la factura no se ve afectada, porque usa `sales_order_items`.
  - *Alternativa*: rechazar la conversión de un presupuesto con líneas de servicio (literal propio). Es más simple, pero el presupuesto no se podría vender "con todos sus ítems".
- **OQ-P16 — Editar desde `/ventas` una venta nacida de un presupuesto con líneas de servicio.**
  - *Recomendado*: **no se edita** en este change. "Editar" queda deshabilitado con el motivo, y la corrección es eliminar la venta y volver a venderla desde el presupuesto duplicado (D6). El editor de ventas no modela líneas sin producto, y soportarlas toca el hot path de edición.
  - *Alternativa*: soportar la línea de servicio en `sale-form` y en la sincronización con `sales_order_items` (change propio).
