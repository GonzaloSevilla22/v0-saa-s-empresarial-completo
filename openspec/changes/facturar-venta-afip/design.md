## Context

El pipeline de emisión de comprobantes AFIP por venta **ya está construido y en producción**. C-27 (`v21-fiscal-profile`) trajo el perfil fiscal, multi punto de venta, `rpc_emit_pending_cae`, `rpc_next_document_number`, el `WSFEAdapter` real y el `CAERelayProcessor` con `pg_cron`. C-29 (`v21-quote-salesorder`) agregó la FK `sales_orders.fiscal_document_id` y el helper transaccional `_c29_confirm_order_core`, que ya llama a `rpc_emit_pending_cae` dentro del commit **cuando `p_comprobante_type IS NOT NULL`**. El relay `fiscal-receptor-iva-relay` extendió `rpc_emit_pending_cae` con receptor (`DocTipo/DocNro`) y desglose de IVA (todos opcionales, `DEFAULT NULL`), y el `WSFEAdapter` ya resuelve el receptor (`_resolve_receptor_doc`: 80=CUIT, 96=DNI, 99=consumidor final) y aplica el guard de umbral de identificación obligatoria (`afip_consumidor_final_threshold`, RG 5824/2026).

**Estado actual roto (verificado):** la única vía de emisión es la opción opt-in del POS al confirmar la venta, y el POS hardcodea `comprobante_type: "factura_c"` en `frontend/app/(dashboard)/ventas/pos/page.tsx` L383, con el comentario falso "backend resuelve el tipo real por condición IVA". El backend **no resuelve**: `services/sales_orders.py` pasa el `comprobante_type` recibido tal cual al RPC, que lo persiste literal. `_c29_confirm_order_core` llama a `rpc_emit_pending_cae` con solo 4 argumentos posicionales (no pasa receptor ni neto/IVA aunque la RPC ya los acepta). La función pura `resolve_invoice_type()` existe (`backend/services/fiscal/invoice_type_resolver.py`) pero **no se invoca** en ningún camino de venta.

**Gobernanza: FISCAL = CRÍTICO.** Dinero real, comprobantes con valor legal ante AFIP/ARCA. Este documento es planning; el apply requiere sign-off explícito del PO antes de escribir código.

## Goals / Non-Goals

**Goals:**
- Un **único** flujo de emisión: botón "Facturar" sobre una `sales_order` confirmada con `fiscal_document_id IS NULL`. Cubre venta recién confirmada y venta vieja con el mismo camino (posterior = retroactivo).
- Endpoint dedicado `POST /sales-orders/{id}/emit-invoice` que **resuelve el tipo en el backend** (capa service, vía `resolve_invoice_type`) y arma el receptor desde la identidad fiscal del cliente (C-22).
- Emisión **asíncrona** vía el pipeline existente (`pending_cae` → relay → `pg_cron`), sin bloquear el request esperando el CAE.
- **Idempotencia fiscal:** 409 si la orden ya tiene `fiscal_document_id`.
- POS deja de emitir inline (quita el hardcode `factura_c`).
- UI: botón + `FiscalDocumentBadge` con Realtime (pending → CAE + nº + PV). Sin PDF/ticket.

**Non-Goals:**
- **Factura A/B (Responsable Inscripto)** — fuera de alcance MVP. Ver "Deuda diferida".
- Generación de PDF / ticket del comprobante (change separado).
- Tocar el relay, el `CAERelayProcessor`, `claim_pending`, el `pg_cron` o el `WSFEAdapter` (reutilizados tal cual).
- Migrar la emisión por **suscripciones** (`rpc_emit_subscription_payment_cae`, `EmitirSuscripcionDialog`) — es un camino independiente que NO se reutiliza ni se toca.
- Cambiar el comportamiento del RPC de confirmación de venta (`rpc_confirm_sales_order` / `_c29_confirm_order_core`): sigue aceptando `p_comprobante_type` opcional para retrocompat; simplemente el POS deja de usarlo.

## Decisions

### D1 — Endpoint dedicado de emisión posterior, NO un parámetro en confirm
`POST /sales-orders/{id}/emit-invoice` (ruta nueva en el router `sales_orders` existente; ubicar **antes** de `/{id}` no aplica porque el sufijo `/emit-invoice` desambigua del UUID, igual que `/confirm`). La emisión se separa del momento de confirmar.
- **Por qué:** unifica "facturar al instante" y "facturar después" en un solo camino; elimina la rama opt-in del POS (origen del bug); permite facturar ventas históricas sin reabrir su transacción de confirmación. La confirmación de venta ya no nace con comprobante.
- **Alternativa descartada:** seguir emitiendo dentro de `confirm()` arreglando el hardcode. Rechazada: no resuelve el caso retroactivo, mantiene dos caminos (POS opt-in + posterior) y deja la emisión acoplada al hot path de la venta.

### D2 — RPC nueva `rpc_emit_sale_invoice(p_sales_order_id, p_point_of_sale_id)` que envuelve `rpc_emit_pending_cae`
La validación (orden existe, pertenece a la cuenta, `status='confirmed'`, `fiscal_document_id IS NULL`), la resolución del tipo y el set de la FK deben ser **atómicos** respecto de la emisión para no dejar la orden facturada parcialmente. Se hace en una RPC `SECURITY DEFINER` propia que:
1. Carga la orden con lock (`SELECT … FOR UPDATE`) y valida cuenta + `status='confirmed'` + `fiscal_document_id IS NULL` (sino `P0404` / `P0409`).
2. Lee `fiscal_profiles.iva_condition` (emisor) y, si hay `client_id`, `clients.iva_condition` (receptor).
3. Resuelve el tipo. En el MVP, el emisor es monotributista ⇒ `factura_c` (la resolución vive además en el service como `resolve_invoice_type` para testeo puro; ver D3).
4. Deriva el receptor: `clients.tax_id` + `clients.iva_condition` → `(receptor_doc_tipo, receptor_doc_nro)`. Sin `client_id` o sin `tax_id` → `NULL/NULL` (el adapter lo resuelve a 99/0, consumidor final).
5. Llama a `rpc_emit_pending_cae(p_comprobante_type, p_total, p_client_id, p_point_of_sale_id, p_receptor_doc_tipo, p_receptor_doc_nro, NULL, NULL, NULL)` — neto/IVA en `NULL` porque Factura C no discrimina IVA.
6. `UPDATE sales_orders SET fiscal_document_id = <nuevo> WHERE id = p_sales_order_id` dentro del mismo commit.
- **Por qué una RPC nueva y no llamar `rpc_emit_pending_cae` desde el backend asyncpg directo:** `rpc_emit_pending_cae` NO setea `sales_orders.fiscal_document_id` (eso lo hace su caller). Hacer la validación de idempotencia + el INSERT del comprobante + el UPDATE de la FK en dos llamadas separadas abre una ventana de doble-emisión. Una RPC envolvente lo cierra en un commit, igual que `_c29_confirm_order_core`.
- **Reutiliza:** `rpc_emit_pending_cae` (numeración + PV + INSERT pending_cae), `is_account_writer` (guard ya dentro de `rpc_emit_pending_cae`), el relay y el `pg_cron` toman el `pending_cae` resultante sin cambios.

### D3 — El tipo se resuelve en el service con `resolve_invoice_type`, espejado en la RPC
La fuente de verdad de la resolución A/B/C es la función pura `resolve_invoice_type(emisor_iva_condition, receptor_iva_condition)`. El service la invoca para validar/loguear el tipo y para los tests unitarios. La RPC también lo computa (no puede importar Python) — en el MVP el resultado es trivialmente `factura_c` para monotributista. El service **nunca** acepta el tipo desde el cliente.
- **Por qué:** mantiene la regla fiscal en un único lugar testeable y elimina la posibilidad de que el cliente fuerce un tipo ilegal (causa raíz del bug actual).

### D4 — Emisión asíncrona, request no espera el CAE
El endpoint responde `202 Accepted` (o `200` con el `fiscal_document_id` y `status='pending_cae'`) ni bien la RPC reserva el número e inserta el `pending_cae`. El CAE lo obtiene el relay vía `pg_cron`. El front muestra `FiscalDocumentBadge` con Realtime que transiciona pending → autorizado.
- **Por qué:** RN-94 — el hot path no depende del uptime de AFIP. Ya es el comportamiento del pipeline; lo respetamos.

### D5 — Receptor desde C-22, consumidor final como default válido
Columnas reales verificadas (migración `20260614000000_clients_fiscal_identity.sql`): `clients.tax_id TEXT`, `clients.legal_name TEXT`, `clients.iva_condition TEXT` con CHECK `('responsable_inscripto','monotributista','exento','consumidor_final')`. Derivación del receptor: `iva_condition='responsable_inscripto'` (con `tax_id`) → CUIT (DocTipo 80); DNI → DocTipo 96; sin `client_id` o sin `tax_id` → DocTipo 99 / DocNro 0 (consumidor final, válido). El guard de umbral del `WSFEAdapter` (`afip_consumidor_final_threshold`, RG 5824/2026) se respeta tal cual: por encima del umbral exige receptor identificado y falla explícito si no lo hay.

### D6 — Idempotencia fiscal vía la FK `sales_orders.fiscal_document_id`
Contrato: si la orden ya tiene `fiscal_document_id IS NOT NULL`, el endpoint rechaza con **409 Conflict** (mapeado desde `P0409` en `_map_postgres_error`). El front deshabilita el botón "Facturar" cuando la orden ya está facturada o tiene una emisión `pending_cae`. El `SELECT … FOR UPDATE` de D2 serializa requests concurrentes sobre la misma orden.
- **Por qué:** doble-CAE = doble comprobante legal ante AFIP. La FK es el único guard necesario (no hace falta `operation_idempotency`: la unicidad la da el estado de la orden).

### D7 — Reused vs New (inventario)

**Reutilizado tal cual (NO se toca):**
- `backend/services/fiscal/invoice_type_resolver.py` — `resolve_invoice_type()`.
- `backend/services/fiscal/wsfe_adapter.py` — `_resolve_receptor_doc`, array `AlicIva`, threshold guard, `CondicionIVAReceptorId`.
- `backend/services/fiscal/cae_relay_processor.py` — `CAERelayProcessor`.
- `backend/repositories/fiscal_document_repository.py` — `claim_pending` (anti doble-CAE), relay backstop.
- RPC `rpc_emit_pending_cae` (firma extendida del relay), `rpc_next_document_number`, multi-PV (C-27), `pg_cron`.
- `FiscalDocumentBadge` + Realtime, FK `sales_orders.fiscal_document_id`.

**Nuevo (lo agrega el apply):**
- DB: RPC `rpc_emit_sale_invoice(p_sales_order_id, p_point_of_sale_id)` (1 migración mínima). Sin columnas nuevas.
- Backend: ruta `POST /sales-orders/{id}/emit-invoice` (router), método `emit_invoice` en `services/sales_orders.py` (validación + `resolve_invoice_type` + DI), repo method que invoca la RPC, schema de respuesta Pydantic v2 (`EmitInvoiceOut`).
- Frontend: botón "Facturar" + hook TanStack Query (`useEmitInvoice`), badge en detalle/listado de ventas, y la **eliminación del hardcode** `comprobante_type:"factura_c"` en el POS (deja de pasar el campo).

**NO reutilizado (camino de suscripciones, intacto):** `rpc_emit_subscription_payment_cae`, `EmitirSuscripcionDialog`, `/fiscal/documents/emit-subscription-payment`.

### D8 — Deuda diferida: Factura A/B (Responsable Inscripto)
Fuera de alcance MVP. Para soportar A/B faltan (gaps 3+4 de la exploración):
1. Columna `fiscal_documents.receptor_iva_condition` — hoy el relay hace `doc.get("receptor_iva_condition") → None`, lo que para A/B haría fallar el adapter (Code 10246 / falta `CondicionIVAReceptorId`).
2. Alícuota de IVA por línea en `sales_order_items` — sin ella no se puede armar el array `AlicIva` (neto + IVA discriminado por alícuota) que A/B exige.

**Comportamiento MVP aceptado:** si por configuración del emisor llegara a resolverse una Factura A/B sin desglose, el guard del `WSFEAdapter` **falla explícito** (no emite un comprobante inválido). Para el segmento monotributista de Mendoza (Factura C) esto nunca se dispara. Cuando entre RI, un change posterior agrega ambas columnas + la resolución automática del tipo en la RPC.

## Risks / Trade-offs

- **[Doble emisión por requests concurrentes sobre la misma orden]** → `SELECT … FOR UPDATE` sobre `sales_orders` en la RPC + chequeo `fiscal_document_id IS NULL` dentro del lock; segundo request recibe 409. Front deshabilita el botón en `pending`/facturado.
- **[El emisor configura RI y se intenta facturar una venta]** → la RPC resolvería A/B; sin desglose de IVA el `WSFEAdapter` falla explícito (sin comprobante inválido). Mitigación: documentado como deuda (D8); el MVP asume emisor monotributista. **El apply debe validar que el `fiscal_profile` activo es monotributista antes de habilitar el botón, o devolver un error claro si es RI** (decidir en sign-off — ver Open Questions).
- **[Venta sin cliente identificado por encima del umbral RG 5824]** → el guard del adapter rechaza la emisión por falta de receptor; el badge mostraría el error. Comportamiento correcto y esperado; el front debe surfacear el `last_error` del `fiscal_document`.
- **[Quitar el hardcode del POS rompe el opt-in actual]** → es el objetivo. Verificar que ninguna otra ruta dependa de que `quick_sale`/`confirm` emitan inline (los tests de C-29 que pasan `comprobante_type` siguen válidos para el RPC, solo el POS deja de pasarlo).
- **[Gobernanza CRÍTICO]** → no se escribe código sin sign-off del PO; el apply incluye tests por capa y la E2E de homologación AFIP queda como `@pytest.mark.integration` manual, fuera del gate de CI.

## Migration Plan

- 1 migración nueva: `rpc_emit_sale_invoice`. Aplicar con `npx supabase db push` (NUNCA el MCP `apply_migration` — regla dura del proyecto). Sin cambios de esquema (no rewrite de tablas).
- Rollback: la RPC es aditiva; `DROP FUNCTION rpc_emit_sale_invoice`. La eliminación del hardcode del POS es un cambio de front reversible por revert del commit. Ninguna columna/dato se altera.
- Orden de deploy: migración (RPC) → backend (Render redeploya al pushear a main) → frontend. El botón es inerte hasta que el endpoint exista, así que el orden front-last es seguro.

## Open Questions

- **OQ-1 (para el PO):** ¿el botón "Facturar" debe **ocultarse/bloquearse** cuando el `fiscal_profile` activo no es monotributista (emisor RI), o intentar y mostrar el error del guard? Recomendación: bloquear con mensaje claro ("Facturación A/B no disponible aún") mientras A/B sea deuda.
- **OQ-2 (para el PO):** ¿el endpoint vive como `POST /sales-orders/{id}/emit-invoice` (router de ventas, recomendado por cohesión con la orden) o bajo el prefijo `/fiscal/...` (cohesión con el resto de lo fiscal)? Recomendación: en el router de ventas — la acción es sobre la `sales_order`, espeja `/confirm`.
- **OQ-3 (menor):** código HTTP de éxito — `202 Accepted` (semánticamente correcto: emisión async) vs `200` con `status='pending_cae'`. Recomendación: `200` con el `fiscal_document_id` + `status`, consistente con `ConfirmOut.fiscal_doc_id` que ya devuelve el flujo de confirmación.
