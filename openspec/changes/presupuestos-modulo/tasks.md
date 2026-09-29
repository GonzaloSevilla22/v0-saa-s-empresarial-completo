> **Governance MEDIA con un tramo ALTO.**
> - La **tanda A** (grupos 1–5: numeración, escritura por RPC, edición, vencimiento, PDF, WhatsApp, pantallas) no toca dinero.
> - La **tanda B** (grupo 6: conversión a venta) escribe stock, caja, banco, cuenta corriente y outbox a través del núcleo del POS. Lleva checkpoint de integridad de función, gate con matriz de evasión y revisión adversarial antes del merge.
>
> **Dos PRs**, A y luego B, cada uno con su CI verde (incluido `validate-kpis`).
>
> **TDD estricto**: cada grupo abre con su RED (un test que falla por la razón correcta) antes de escribir producción, con evidencia en la tabla del final.
>
> **Reglas de trabajo**:
> - Todo commit va vía PR; nunca a `main`.
> - Toda RPC se reescribe desde su `pg_get_functiondef` **vivo**, conservando el `COMMENT`.
> - `DROP`+`CREATE` resetea las ACLs: se re-declaran en el mismo archivo.
> - Todo repositorio filtra por `account_id` de forma explícita.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [ ] 0.1 **[PO]** Sign-off de OQ-P1..OQ-P15 (`design.md` §Open Questions). Registrar la respuesta textual en `design.md` §"Sign-off del PO" antes de escribir producción. Si no hay respuesta, el apply adopta la recomendación de cada OQ (default declarado). Si el PO elige una alternativa, actualizar en el mismo PR la decisión afectada, las specs y estas tareas.
- [ ] 0.2 Confirmar que `20261067000001` y `20261068000001` siguen libres (`ls supabase/migrations`, `gh pr list --state open`, `MAX(version)` de prod). Renumerar si no.
- [ ] 0.3 Releer de prod, **inmediatamente antes** de escribir la tanda B:
  - `pg_get_functiondef('public.rpc_accept_quote(uuid)'::regprocedure)`, su `obj_description` y su ACL;
  - `pg_get_functiondef` de `_c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid)` (sólo para verificar que no cambió: este change no lo toca).
  
  Compararlos por líneas, sin `\r` (gotcha CRLF), contra `20261045000001:1677` y `20261062000001:1118`. Si difieren, partir del vivo y anotar el desvío acá.
- [ ] 0.4 Grep de **todos** los escritores de `quotes`/`quote_items` en `backend/`, `frontend/`, `supabase/functions/`, `supabase/tests/` y `supabase/migrations/` (los bloques `DO` de gate dentro de migraciones). Listar cada uno con la decisión: migrar a RPC, o no le afecta porque corre como `postgres`/`session_replication_role`. Anotar la lista acá antes de retirar las políticas (D2).
- [ ] 0.5 Confirmar en prod (SELECT) el punto de partida:
  - 0 `quotes`;
  - políticas vivas de `quotes`/`quote_items`;
  - disparadores vivos sobre `quotes` (`quotes_record_status_creation`, `quotes_enforce_status_transition`);
  - filas de `document_status_transitions` para `quote` con sus `allowed_role`;
  - cuentas con `fiscal_profiles.nombre_fantasia`/`razon_social`;
  - jobs de `cron.job`.
- [ ] 0.6 SAFETY NET — correr y registrar el baseline de:
  - `backend/tests/test_c29_quote_salesorder.py`, `test_operacion_party_guard.py`, `test_pos_catalogo_pagos.py`, `test_sales_orders_payment_method_contract.py`, `outbox/test_producers.py`, `test_factura_fiscal_read_models.py` y los tests de `receipts`/`invoice_pdf`;
  - `frontend/__tests__` de `sale-receipt-button*`, `fiscal-invoice*`, `use-sales-orders*`, `sale-form-*`, `pos-*`, `configuracion*`, `app-sidebar*`, `breadcrumb*`, `sale-operations-list*`;
  - gates SQL que existen como archivo y tocan este dominio: `test_document_status_transition_role_matrix.sql`, `test_operacion_party_guard.sql`, `test_ventas_unidades_conversion.sql` (+ su `_race.sh`), `test_function_acl_gate.sql` y `test_accounts_privilege_columns.sql`. (`test_c29*`, `test_document_status_history*` y `test_v3_soft_delete*` no existen en `supabase/tests/`: son bloques `DO` de migraciones viejas; lo que se necesita de ellos se re-verifica en 1.1(l).)
  
  Una falla previa se reporta como preexistente y no se corrige acá.

## 1. DB tanda A: `20261067000001_presupuestos_modulo.sql` + gate

- [ ] 1.1 RED — gate nuevo `supabase/tests/test_presupuestos_modulo.sql`, con fixtures propios (dos cuentas; usuarios owner, seller y cashier reales con roles en `account_roles`; cliente vivo, cliente dado de baja, productos simple / padre con variantes / de otra cuenta; unidades) y cleanup asertado. Bloques:
  - (a) numeración correlativa por cuenta e independiente entre cuentas; un alta que falla no consume número; número explícito duplicado → `unique_violation`; un número explícito mayor avanza la secuencia (el alta siguiente recibe ese + 1); un `INSERT` sin `valid_until` sale con el default de la cuenta;
  - (b) alta: sin cliente → `P0400`; cliente ajeno o dado de baja → `P0404 client_not_found`; producto ajeno → `P0404 product_not_found` y **ningún** snapshot con datos ajenos; padre con variantes → `P0400 product_is_parent`; unidad incompatible → error de RN-24; unidad de otra cuenta en una línea de servicio → `P0404`; línea de servicio sin descripción → `P0400`; total calculado en el servidor; `valid_until` por defecto = hoy ART + validez; `valid_until` pasado → `P0400`;
  - (c) crear y editar **no** tocan `branch_stock`, `cash_movements`, `customer_account_movements` ni `bank_movements`;
  - (d) edición en `draft` y `sent`: reemplazo de líneas, snapshots re-tomados, `updated_at`/`updated_by`, estado intacto; sin `valid_until` → `P0400 quote_valid_until_required`; en `expired` y en `rejected` la edición lo **reabre** a `draft` con la transición en el historial (con el editor como actor); en `accepted` → `P0423 quote_locked_converted`; ampliación de validez de un abierto vencido; atomicidad (una línea inválida no deja cambios);
  - (e) `rpc_transition_quote`: `draft→sent` fija `sent_at` y registra historial; `sent→sent` es no-op sin historial nuevo; `→rejected` con motivo; `→accepted` y `→expired` → `P0400`;
  - (f) `rpc_delete_quote`: `draft` nunca enviado se borra; `sent` → `P0409 quote_not_deletable`; `draft` reabierto con `sent_at` → `P0409 quote_not_deletable`;
  - (g) roles: el cashier no crea, no edita ni borra (`P0403 insufficient_role`, verificado por la RPC antes de escribir); un usuario sin rol de escritura → `P0401`; el seller sí;
  - (h) `SET ROLE authenticated` + claims: `INSERT`/`UPDATE` directo sobre `quotes`/`quote_items` rechazado;
  - (i) `_expire_overdue_quotes` **ejecutado**: vence `draft`/`sent` con `valid_until < hoy`, historial con `performed_by` = uuid cero y motivo, idempotente, no toca `accepted` (si la inserción del historial abortara con `23502`, el gate falla);
  - (j) `rpc_set_default_quote_validity`: 0 y 366 → `P0400`; seller → `P0403 insufficient_role`; owner → OK;
  - (k) ACLs: helpers internos sin `EXECUTE` para `authenticated`/`anon`; RPCs públicas sin `anon`.
  - (l) regresiones que antes se citaban con gates inexistentes: la baja de un producto que está en un presupuesto `draft` sigue rechazándose con `P0B04` (`fn_guard_product_soft_delete`); el alta registra `NULL → draft` en el historial con el creador.
- [ ] 1.2 GREEN — verificación defensiva y columnas: `quotes.number`/`notes` (`CHECK` de largo)/`sent_at`/`updated_at`/`updated_by`, `UNIQUE (account_id, number)` e `accounts.default_quote_validity_days` (`NOT NULL DEFAULT 15`, `CHECK 1..365`). Todo `IF NOT EXISTS` / con guarda. Confirmar que el gate `test_accounts_privilege_columns.sql` la deja sin `UPDATE` para `authenticated`.
- [ ] 1.3 GREEN — `internal_document_sequences` (PK, `CHECK (document_type IN ('quote'))`, RLS `SELECT` para miembros, `REVOKE ALL … FROM anon`) + `_next_internal_document_number` (UPDATE-then-INSERT con reintento ante `unique_violation`, `SECURITY DEFINER`, `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`) + disparador `trg_quote_assign_number` (`BEFORE INSERT`: si `NEW.number IS NULL` asigna el siguiente; si viene explícito, `last_number = GREATEST(last_number, NEW.number)`; si `NEW.valid_until IS NULL`, lo completa con la validez por defecto de la cuenta). `COMMENT`s.
- [ ] 1.4 GREEN — `rpc_create_quote`, `rpc_update_quote`, `rpc_transition_quote`, `rpc_delete_quote` y `rpc_set_default_quote_validity` (D2, D5, D7, D11), y las dos filas nuevas de `document_status_transitions` (`quote: expired → draft`, `rejected → draft`, `allowed_role = {seller, admin, owner}`, D4). Detalles obligatorios:
  - el `INSERT … SELECT` de snapshots filtra `products.account_id`;
  - crear, editar y borrar verifican el rol con el mismo predicado del helper de transiciones (roles activos no vencidos) **antes** de escribir → `P0403 insufficient_role`;
  - toda línea con `unit_id` (también la de servicio) exige unidad del sistema o de la cuenta;
  - la edición exige `p_valid_until` (`P0400 quote_valid_until_required`) y reabre `expired|rejected` a `draft` vía `record_status_transition`;
  - `REVOKE ALL … FROM PUBLIC, anon` + `GRANT EXECUTE … TO authenticated`;
  - `COMMENT`s.
- [ ] 1.5 GREEN — `DROP POLICY IF EXISTS` de `quotes_insert`, `quotes_update`, `quote_items_insert` y `quote_items_update`. Antes, migrar cada escritor listado en 0.4 que dependa de ellas.
- [ ] 1.6 GREEN — `_expire_overdue_quotes()` (`FOR UPDATE SKIP LOCKED`, `record_status_transition` con actor = uuid cero `'00000000-0000-0000-0000-000000000000'` —`performed_by` es `NOT NULL`— y motivo "vencimiento automático", sin `EXECUTE` para roles de aplicación) + `cron.unschedule`/`cron.schedule('quotes-expire-sweep', '5 3 * * *', …)` (molde de `cobranzas-overdue-digest-sweep`).
- [ ] 1.7 Bloque `DO` de introspección al final (sólo catálogo): columnas, `UNIQUE`, disparador, tabla de secuencias con RLS, las 4 políticas de escritura ausentes, las 2 filas nuevas del catálogo, ACLs, job de cron presente y una sola definición de cada función nueva.
- [ ] 1.8 RED/GREEN — `supabase/tests/test_internal_document_numbering_race.sh` (molde `test_ventas_unidades_conversion_race.sh`): N sesiones crean a la vez el primer presupuesto de una cuenta sin fila de secuencia → números 1..N sin huecos ni repetidos. Cablear este script y el gate de 1.1 en `.github/workflows/KPI_Validation.yml`, en el orden real del workflow, y sumar `20261067000001` **al final** de la cadena de reaplicación de idempotencia.
- [ ] 1.9 TRIANGULATE — `supabase/tests/test_document_status_transition_role_matrix.sql` actualizado: `v_expected_callers` suma `rpc_update_quote`, `rpc_transition_quote` y `_expire_overdue_quotes`; `v_expected_triples` suma `quote:draft->sent`, `quote:draft->rejected`, `quote:sent->rejected`, `quote:draft->expired`, `quote:sent->expired`, `quote:expired->draft` y `quote:rejected->draft`. Siguen verdes `test_function_acl_gate.sql` (las funciones nuevas quedan clasificadas por la convención `_*`; si el chequeo (4) necesita una entrada, se agrega con justificación), `test_accounts_privilege_columns.sql`, `test_operacion_party_guard.sql` y `test_ventas_unidades_conversion.sql` (usa `quote_items` y `SET LOCAL ROLE authenticated`).

## 2. Backend tanda A: presupuestos sobre RPC (3 capas)

- [ ] 2.1 RED — `backend/tests/test_quotes_module.py`:
  - **schemas**: cliente obligatorio; `description` obligatoria sin producto; `notes` ≤ 2000; `action ∈ {send, reject}`; `QuoteUpdateIn` con `valid_until` requerido y no nulo.
  - **service**:
    - `require_account_role(CAN_QUOTE)` en crear, editar, transicionar y borrar; el cashier recibe 403 sin llamar a la RPC;
    - mapeo de `P0400/P0401/P0403/P0404/P0409/P0422/P0423` a RFC 7807, con `code` = literal estable (`quote_locked_converted`, `quote_not_deletable`, `insufficient_role`, …) y sin `HTTPException` crudo.
  - **repositorio**: todo por RPC o `SELECT` con `account_id` explícito; `get_quote` devuelve las líneas y el historial.
  - **listado**: paginado `{items,total,page,pages}`; filtros `status`, `client_id` y `q` (nombre o número en los tres formatos); `is_expired` derivado con el día ART.
- [ ] 2.2 GREEN — `core/rbac.py`: `CAN_QUOTE = frozenset({"owner","admin","seller"})` con un comentario que lo ate al catálogo de la FSM. Un test verifica que coincide con los `allowed_role` de `quote` en el seed (lectura de la migración, como los tests de contrato existentes).
- [ ] 2.3 GREEN — `schemas/quotes.py`, `repositories/quote_repository.py`, `services/quotes.py` y `routers/quotes.py`:
  - `GET /quotes` (paginado);
  - `POST /quotes`;
  - `GET /quotes/{id}`;
  - `PUT /quotes/{id}`;
  - `DELETE /quotes/{id}`;
  - `POST /quotes/{id}/transition`;
  - se **retira** `POST /quotes/{id}/accept` (sin consumidores; D12). La RPC `rpc_accept_quote` sigue viva.
  
  Se retira `_VALID_TRANSITIONS` (la política vive en el catálogo) y `require_role(["user","admin"])`.
- [ ] 2.4 GREEN — `GET/PATCH /settings/quotes` (molde `/settings/collections`, `CAN_CONFIGURE`; `PATCH` con 1..365 validado en el schema → 422 antes de la DB).
- [ ] 2.5 GREEN — `backend/services/commercial_documents/numbering.py` (`format_internal_document_number`) + fixture compartido `backend/tests/fixtures/internal_document_number_cases.json` (con test pytest que lo recorre).
- [ ] 2.6 TRIANGULATE — `backend/tests/test_c29_quote_salesorder.py` migrado al contrato nuevo, sin perder casos de tenencia y estado; los casos del endpoint `accept` se retiran con él (su regresión pasa a la de `rpc_accept_quote` en el gate 6.1) y un test verifica que `POST /quotes/{id}/accept` responde 404/405. `test_operacion_party_guard.py` verde. Un `client_id` ajeno sigue respondiendo `client_not_found`, ahora desde la RPC.

## 3. PDF del documento comercial (tanda A)

- [ ] 3.1 RED — `backend/tests/test_commercial_document_pdf.py`:
  - `build_quote_view` (puro): número, sellos por estado incluido `is_expired`, símbolo de unidad, leyenda con y sin `valid_until`;
  - `resolve_commercial_issuer`: fantasía → razón social → `business_name` del dueño → "Mi Negocio", sin bloquear;
  - `build_commercial_document_pdf`, leído con `pypdf`: "PRESUPUESTO", número, cliente, líneas, total, leyenda "no válido como factura", sello, paginado con 80 líneas y cabecera repetida, emoji sustituido, precio sub-centavo;
  - endpoint `GET /quotes/{id}/pdf`: 200 inline por defecto; `attachment` con `presupuesto-P-00000012.pdf`; 404 cross-tenant idéntico al inexistente; 422 con `disposition` inválido; 401 sin sesión.
- [ ] 3.2 GREEN — `backend/services/commercial_documents/{__init__,view,issuer,pdf}.py`. Reutiliza `_latin1`, `_format_amount` y `_format_unit_price` de `services/receipts.py` por import (no copia) y la paleta de `receipts.py`. El repositorio del emisor filtra por `account_id`.
- [ ] 3.3 GREEN — ruta `GET /quotes/{id}/pdf` en `routers/quotes.py` (router sin lógica; service `get_quote_pdf`).
- [ ] 3.4 TRIANGULATE — los tests existentes de `build_sales_receipt_pdf` y de la Factura C siguen verdes sin cambios.

## 4. Frontend tanda A: datos, helpers y hooks

- [ ] 4.1 RED — tests de los helpers extraídos (`lib/document-share.ts`: `downloadBlob`, `sharePdf` —compartido → `"shared"`, cancelado → `"cancelled"`, no soportado o falla → `"unsupported"`—, `openWhatsAppText` con y sin número válido; `lib/api/document-pdf.ts`: 200 → Blob, 401 → `null` con navegación, RFC 7807 → `DocumentPdfError` con `code`). `sale-receipt-button*` y `fiscal-invoice*` siguen verdes **sin tocar sus tests** (safety net de la extracción).
- [ ] 4.2 GREEN — extraer los helpers de `components/ventas/sale-receipt-button.tsx` y de `lib/api/fiscal-invoice.ts` a `lib/document-share.ts` y `lib/api/document-pdf.ts`, y hacer que los dos consumidores los importen. Sin cambio de comportamiento: `sale-receipt-button` trata `"cancelled"` como hoy trata `"shared"`.
- [ ] 4.3 RED/GREEN — `lib/internal-document-number.ts` (`formatInternalDocumentNumber`, `parseInternalDocumentNumberQuery`) contra el **mismo** fixture `internal_document_number_cases.json` que usa pytest (2.5).
- [ ] 4.4 RED/GREEN — `lib/quote-share.ts` (`buildQuoteShareText`: con y sin nombre, total formateado, validez) y las funciones puras de carrito extraídas de `sale-form.tsx` a `lib/cart-utils.ts` (D12):
  - `addManualLineToCart(cart, staged, ctx, {enforceStock})`: `false` → no rechaza por stock; `true` → mismo resultado que el chequeo acumulativo `exceedsStock`; fusión sólo sobre líneas sin `source`;
  - `applyScanToCart(cart, scanResult, ctx, {enforceStock})`: producto por unidades, medible (foco en cantidad), etiqueta de balanza y chequeo de stock en las dos ramas, con y sin `enforceStock`;
  - reductores `updateLineQuantity`, `updateLineSubtotal` y `removeLine`;
  - `lib/quote-lines.ts`: líneas de servicio (`QuoteServiceLine`: alta, edición, validación de descripción) y armado del payload `p_items` que une productos y servicios con `price` = precio unitario efectivo.
  
  GREEN incluye **migrar `sale-form.tsx`** a esas funciones, con sus tests existentes (`sale-form-*`) verdes sin cambios como safety net. El POS no se migra (candidato).
  - `false` → no rechaza por stock;
  - `true` → mismo resultado que el chequeo acumulativo `exceedsStock`;
  - fusión sólo sobre líneas sin `source`.
- [ ] 4.5 RED/GREEN — `lib/query-invalidation.ts` `invalidateAfterSale(queryClient)`: la unión `salesOrders`, `sales`, `branchStock`, `products`, `customerAccounts`, `receivables`, `cashSessions`, `cashMovements` y `bankAccounts`, con un test que verifica cada clave. Reemplaza las dos listas de `hooks/data/use-sales-orders.ts:240-253` y `:320-329` (que hoy no invalidan caja, banco ni productos: se corrige de paso) y los tests existentes de `use-sales-orders*` siguen verdes.
- [ ] 4.6 RED/GREEN — `hooks/data/use-quotes.ts` reescrito sobre el contrato nuevo (tipos explícitos, sin `any`): `useQuotes(filters)` paginado, `useQuote`, `useCreateQuote`, `useUpdateQuote`, `useTransitionQuote`, `useDeleteQuote`, `useQuoteSettings`, `useUpdateQuoteSettings` y `fetchQuotePdf`. Sin `useAcceptQuote` (el endpoint se retira). Claves en `lib/query-keys.ts` (`quotes.*`, `quoteSettings.*`). Invalidaciones verificadas por test.
- [ ] 4.7 GREEN — `lib/operation-errors.ts`: traducciones accionables de `quote_locked_converted`, `quote_expired`, `quote_invalid_state`, `quote_product_unavailable`, `quote_client_unavailable`, `quote_not_deletable`, `quote_valid_until_in_past`, `quote_valid_until_required`, `product_not_found`, `product_is_parent`, `insufficient_role` / 403 ("Tu rol no permite …"), `cash_requires_session`, `idempotency_key_conflict` y `payment_method_required`, con test por literal.
- [ ] 4.8 RED/GREEN — `frontend/lib/rbac-capabilities.ts`: `CAN_QUOTE = ["owner","admin","seller"]` y `hasCapability(roles, cap)` (fail-open mientras `roles` no resolvió, como `isWriter`). Test atado al conjunto de `backend/core/rbac.py` (lee el archivo, como los tests de contrato existentes) y casos: sólo `seller` → sí; sólo `cashier` → no.

## 5. Pantallas tanda A

- [ ] 5.1 RED — `components/shared/DocumentShareMenu` (vitest + Testing Library):
  - "Ver" abre la pestaña en el gesto y no llama a `onShared`;
  - "Descargar" llama a `onShared`;
  - el PDF se precarga al abrir el menú y el share nativo se invoca en el mismo toque con el blob listo; sin blob, "Preparando…";
  - share cancelado → **no** llama a `onShared`; sin `onShared` (rol sin permiso) la descarga funciona igual;
  - WhatsApp: con share de archivos comparte el `File`; sin share, descarga y abre `wa.me/<549…>`; sin teléfono, abre `wa.me/?text=` con aviso;
  - 401 → sin toast de error.
- [ ] 5.2 GREEN — `components/shared/DocumentShareMenu.tsx` (componentes base, tokens semánticos, `aria-label`s, avisos con `aria-live="polite"`).
- [ ] 5.3 RED — `components/quotes/QuoteForm`:
  - cliente obligatorio y alta en el lugar con `ClientForm` en `ResponsiveModal`, que preselecciona al crear (`ClientForm.onSuccess(client?)`, con su test propio y el caller existente de `/clientes` sin cambios de comportamiento);
  - aviso de cliente sin teléfono;
  - alta de producto con unidad y descuento;
  - línea de servicio con descripción;
  - lector de códigos y etiqueta de balanza (misma `resolveScan`);
  - stock insuficiente **no** bloquea (sólo muestra el disponible);
  - validez con el default de la cuenta;
  - notas;
  - `?cliente=` preselecciona;
  - `?duplicar=` precarga con precios de hoy y aviso de cambio;
  - edición precarga las líneas persistidas con el precio efectivo y descuento 0; una línea cuyo producto ya no está vivo se marca "Producto no disponible" y bloquea el guardado;
  - edición de un `expired`/`rejected` avisa que se reabre como borrador y exige validez ≥ hoy;
  - envío con el payload esperado.
- [ ] 5.4 GREEN — `components/quotes/QuoteForm.tsx` sobre `ProductPicker`, `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput`, `resolveScan`, `useScaleSettings`, `useUnitsOfMeasure`, `compatibleUnits`/`convertUnitPrice`/`roundUnitPrice`, `SearchableSelect`, `BranchSelect`, `addManualLineToCart`, `applyScanToCart`, los reductores de línea y `lib/quote-lines.ts`. Sin lógica de carrito propia fuera de `lib/`.
- [ ] 5.5 RED/GREEN — `components/quotes/QuoteStatusBadge.tsx` (5 estados + "Vencido" derivado, con tokens semánticos y contraste AA vía el gate `token-contrast-aa`).
- [ ] 5.6 RED/GREEN — `app/(dashboard)/presupuestos/page.tsx` (listado):
  - pestañas de estado, búsqueda, paginación;
  - tabla en desktop y tarjetas en móvil;
  - estado vacío con CTA;
  - CTA oculto sin `CAN_QUOTE` (`hasCapability(roles, CAN_QUOTE)` sobre el conjunto `roles` de `useOrgRole`): test con un usuario sólo `seller` (lo ve) y uno sólo `cashier` (no lo ve);
  - aviso "Validez por defecto: N días · Cambiar".
- [ ] 5.7 RED/GREEN — `app/(dashboard)/presupuestos/nuevo/page.tsx` y `app/(dashboard)/presupuestos/[id]/editar/page.tsx`. La edición de un presupuesto convertido muestra el motivo (`P0423` traducido) y un enlace al detalle; la de un `expired`/`rejected` abre el editor con el aviso de reapertura.
- [ ] 5.8 RED/GREEN — `app/(dashboard)/presupuestos/[id]/page.tsx` (detalle):
  - acciones por estado y rol según la tabla de D10 ("Editar" en todo estado salvo `accepted`; "Eliminar" sólo en `draft` nunca enviado), decididas con `hasCapability`;
  - `DocumentShareMenu` con `onShared` → `rpc_transition_quote('sent')` **sólo** si el usuario tiene `CAN_QUOTE` y el presupuesto está en `draft`; su falla no muestra error; test: un cajero descarga y el estado no cambia;
  - "Marcar como enviado";
  - "Rechazar" con motivo opcional (`ResponsiveModal`);
  - "Duplicar";
  - "Eliminar" con confirmación sólo en `draft`;
  - "Modificado después de enviado";
  - historial;
  - precio de catálogo actual informativo en las líneas que difieren;
  - "Venta" presente en la tanda A sólo como acción deshabilitada u oculta (decisión del apply, D14);
  - accesibilidad: modales de rechazo y borrado con foco inicial y retorno de foco, avisos con `aria-live`.
- [ ] 5.9 GREEN — sidebar: "Presupuestos" en *Operaciones*, entre "POS — Venta Rápida" y "Compras", ícono `FileText`. Breadcrumb con el mecanismo real de `breadcrumb-nav.tsx`: `/presupuestos` y `/presupuestos/nuevo` en `PAGE_NAMES`; `/presupuestos/<id>` ("Detalle de presupuesto") y `/presupuestos/<id>/editar` ("Editar presupuesto") resueltos antes de `nameFromLastSegment`. Tests del sidebar y del breadcrumb, este último con un uuid real (no debe mostrar el uuid) y con `/presupuestos/nuevo`.
- [ ] 5.10 RED/GREEN — ficha del cliente: botón "Nuevo presupuesto" → `/presupuestos/nuevo?cliente=<id>` en `components/clientes/ClientDetailHeader.tsx`, visible en todas las pestañas, y pestaña nueva "Presupuestos" (`app/(dashboard)/clientes/[id]/presupuestos/page.tsx`) con sus últimos 5 presupuestos (`useQuotes({clientId, pageSize: 5})`) y enlace al listado filtrado. La pestaña activa de `ClientDetailHeader` pasa de `isHistorialActive = !isCuentaActive` a una comparación por ruta de cada pestaña, con test de las tres.
- [ ] 5.11 RED/GREEN — `components/quotes/QuoteSettingsCard.tsx` en la pestaña **Cobranzas** de `/configuracion` (debajo del plazo de pago): validez por defecto 1–365, guardado con `useUpdateQuoteSettings` y visible sólo para owner/admin (los demás la ven en sólo lectura). Test de `ConfiguracionPage` actualizado.

## 6. Tanda B: conversión atómica a venta

- [ ] 6.1 RED — gate `supabase/tests/test_presupuesto_a_venta.sql` (fixtures propios, cleanup asertado), con la matriz de D14:
  - feliz `cash`: stock −, caja, `SaleConfirmed`, quote `accepted`, orden `confirmed` con `source_quote_id` y `sale_operation_id`, historial de los dos documentos;
  - `credit`: cargo con vencimiento por cascada, sin caja;
  - `transfer` con cuenta bancaria: `bank_movements`;
  - precio del presupuesto con el catálogo remarcado;
  - stock insuficiente → `P0409` y **cero** efectos (conteos antes/después de `sales_orders`, `sales`, `stock_movements`, `cash_movements`, `customer_account_movements`, `bank_movements`, `events`, historial, estado del quote);
  - vencido → `P0409 quote_expired`;
  - producto dado de baja → `P0404 quote_product_unavailable`;
  - quote ajeno → `P0404`;
  - caja de otra cuenta → `P0422`;
  - sin `payment_method_id` → `P0400`;
  - replay con la misma clave → `replayed = true` sin efectos;
  - clave reutilizada contra otro quote → `P0409 idempotency_key_conflict`;
  - segunda conversión con otra clave → `P0409 quote_invalid_state`;
  - cashier → `P0403`;
  - `cash` sin sesión de caja → `P0400 cash_requires_session` y cero efectos;
  - cliente dado de baja después de cotizar → `P0404 quote_client_unavailable`, sin cargo en `customer_account_movements`;
  - producto al que se le agregaron variantes → `P0400 product_is_parent`;
  - presupuesto con una línea de servicio: se convierte; la orden conserva la descripción en `sales_order_items.name_snapshot`;
  - snapshots: precio del presupuesto en `sales`/`sale_items`, `unit_cost_snapshot` = costo vigente al convertir, `sales_order_items` con los snapshots del presupuesto;
  - regresión: `rpc_accept_quote` sigue creando la orden `draft` con las mismas columnas y el mismo historial que antes.
- [ ] 6.2 RED — `supabase/tests/test_presupuesto_a_venta_race.sh` (molde `test_ventas_unidades_conversion_race.sh`):
  - dos sesiones convierten el mismo presupuesto a la vez → exactamente una venta, un `accepted` y un `QuoteAccepted`;
  - dos sesiones convierten **presupuestos distintos con la misma clave** a la vez → una venta, un `P0409 idempotency_key_conflict`, el otro presupuesto en su estado y 0 órdenes `draft`.
- [ ] 6.3 GREEN — `20261068000001_presupuestos_conversion_venta.sql`:
  - `_quote_accept_core(p_quote_id, p_branch_id)` desde el cuerpo **vivo** de 0.3, con **sólo** los dos cambios de D6 (`FOR UPDATE` y el parámetro de sucursal validado);
  - `rpc_accept_quote` como wrapper (`CREATE OR REPLACE`, misma firma, `COMMENT` vivo re-declarado, ACLs verificadas);
  - `rpc_convert_quote_to_sale` (D6, pasos 1-7), incluidos los guards de cliente vivo y producto no padre (paso 4) y el `RAISE 'idempotency_key_conflict'` cuando el núcleo devuelve `replayed = true` (paso 6);
  - `REVOKE`/`GRANT`;
  - bloque `DO` de introspección: una sola definición de cada función, el wrapper delega, el núcleo sin `authenticated` y la RPC sin `anon`.
  
  Anotar acá el diff del núcleo contra el cuerpo vivo, que debe limitarse a esos dos cambios.
- [ ] 6.3b Adaptar gates existentes a la tanda B:
  - `test_operacion_party_guard.sql` bloque (7): el candado de cuerpo pasa de `rpc_accept_quote(uuid)` a `_quote_accept_core(uuid, uuid)` (`client_not_found` antes de `INSERT INTO public.sales_orders`) y se suma un assert de que `rpc_accept_quote` delega en el núcleo;
  - `test_document_status_transition_role_matrix.sql`: `v_expected_callers` cambia `rpc_accept_quote` por `_quote_accept_core` (más `rpc_convert_quote_to_sale` si llama directo al helper);
  - anotar las dos adaptaciones en la entrada de `CHANGES.md`.
- [ ] 6.4 Cablear los dos gates en `KPI_Validation.yml` y sumar `20261068000001` al final de la cadena de reaplicación de idempotencia.
- [ ] 6.5 RED/GREEN — backend:
  - `QuoteConvertIn/Out`;
  - `QuoteRepository.convert_to_sale`;
  - `services.quotes.convert_quote` (`CAN_QUOTE`, mapeo `P0409` de stock/estado/conflicto a 409 con `code`);
  - `POST /quotes/{id}/convert` con `require_idempotency_key(request, payload.idempotency_key)`;
  - tests con header y con fallback al body; sin clave → 422 `idempotency_key_required` (`require_idempotency_key`, spec `api-standards`).
- [ ] 6.6 RED/GREEN — read models de ventas y órdenes: `source_quote_id` y `source_quote_number`, derivados de `sales_orders.source_quote_id → quotes`, sin columnas nuevas. Además, la fila de una línea de servicio (sin producto) muestra su descripción desde `sales_order_items.name_snapshot` de la misma orden, emparejando por precio, cantidad, subtotal y unidad (D6, OQ-P15). Tests de `test_factura_fiscal_read_models.py` y del listado de ventas extendidos, incluido el caso de la línea de servicio.
- [ ] 6.7 RED/GREEN — `useConvertQuote` (invalida `quotes.*` + `invalidateAfterSale`). La clave la maneja el diálogo con `useIdempotencyKey("quote-convert:" + quoteId)` y se resetea tras cada éxito, incluido el replay. Test: respuesta perdida en la conversión de A seguida de la conversión de B → sin conflicto.
- [ ] 6.8 RED — `components/quotes/ConvertQuoteDialog`:
  - resumen en sólo lectura;
  - `BranchSelect` con el default;
  - `PaymentMethodSelect` + `BankAccountDestinationSelect` cuando corresponde;
  - caja con la semántica del POS: con `kind = cash` se envía siempre la sesión abierta de la sucursal elegida, sin checkbox; sin sesión, "Venta" deshabilitada con el motivo y un enlace a `/caja`;
  - saldo del cliente con `credit`;
  - éxito (también con `replayed: true`) → "Venta registrada" + `EmitInvoiceButton` + "Ver en Ventas", con el foco en el título;
  - `P0409` de stock → mensaje con el producto, sin cerrar, en una región `role="alert"`;
  - `quote_product_unavailable` → "editá el presupuesto";
  - doble clic → una sola request efectiva.
- [ ] 6.9 GREEN — `components/ventas/SaleCheckoutFields.tsx` y `components/ventas/SaleCheckoutSuccess.tsx` (campos de cierre y panel de éxito, sin conocimiento del presupuesto, reutilizables por `remitos-venta`), `components/quotes/ConvertQuoteDialog.tsx` que los compone, y el botón **"Venta"** en el detalle, habilitado según el estado, `is_expired` y `hasCapability(roles, CAN_QUOTE)`.
- [ ] 6.10 RED/GREEN — `/ventas`: badge "Desde presupuesto P-…" con enlace en `sale-operations-list.tsx`. En el detalle del presupuesto convertido: "Venta generada" con enlace a `/ventas/ordenes/<id>` y el estado del comprobante; "La venta generada fue eliminada" si la orden está `canceled` (OQ-P12).
- [ ] 6.11 Revisión adversarial de la tanda B **antes del merge** (seguridad + correctitud):
  - tenencia de cada id del payload (quote, sucursal, forma de pago, cuenta bancaria, caja);
  - idempotencia contra otro documento;
  - orden de locks;
  - rollback total ante un fallo en cada paso;
  - ACLs;
  - que ningún parámetro público permita saltear el stock.
  
  Registrar los hallazgos y su resolución en las notas de este archivo.

## 7. Verificación

- [ ] 7.1 Suites completas:
  - backend `python -m pytest backend/tests -m "not integration" --cov=backend --cov-fail-under=87`, **desde la raíz** del worktree;
  - frontend `pnpm vitest run` de los archivos del change + su safety net;
  - `pnpm tsc --noEmit` sin errores nuevos (comparar contra el baseline de 0.6).
- [ ] 7.2 Gates SQL re-ejecutados contra un `supabase db reset` limpio del worktree: los nuevos + los de 1.9 + `test_function_acl_gate.sql`, en el orden del workflow.
- [ ] 7.3 Pasada visual real (stack local: uvicorn + `pnpm dev` + usuario sembrado + Playwright) en **4 combinaciones** (desktop 1280 / móvil 375 × claro / oscuro) sobre:
  - `/presupuestos` (con datos y vacío);
  - `/presupuestos/nuevo`;
  - `/presupuestos/[id]` en `draft`, `sent` vencido, `rejected` y `accepted`;
  - `/presupuestos/[id]/editar` (también la de un convertido, con el motivo de bloqueo, y la de un rechazado, con el aviso de reapertura);
  - `/presupuestos/nuevo?duplicar=` con el aviso de precios;
  - los modales de rechazo y de borrado;
  - el diálogo de conversión (formulario y éxito);
  - el menú de compartir;
  - la ficha del cliente;
  - la tarjeta de validez en Cobranzas;
  - el badge en `/ventas`.
  
  Sin desborde horizontal a 375 px y con el CTA visible en móvil. Chequeo de teclado y foco (diálogos, menú de compartir) en las 4 combinaciones. Capturas en el PR.
- [ ] 7.4 Humo local de punta a punta: crear → descargar (queda `sent`) → editar → PDF con la leyenda y el número → WhatsApp en escritorio (descarga + `wa.me` con el número del cliente) → Venta en efectivo con caja abierta → la venta aparece en `/ventas` con el badge → Facturar → comprobante en trámite. Repetir la conversión con stock insuficiente y confirmar que no queda nada; intentar efectivo con la caja cerrada ("Venta" deshabilitada); convertir un presupuesto con una línea de servicio y ver su descripción en `/ventas`; rechazar uno y reabrirlo editándolo.
- [ ] 7.5 Red-team de la tanda A, ítem por ítem:
  - producto ajeno en el alta (snapshot);
  - escritura directa por PostgREST;
  - PDF de otra cuenta;
  - numeración concurrente (además del script de 1.8);
  - edición de un `accepted`;
  - cashier contra cada endpoint de escritura.

## 8. Documentación

- [ ] 8.1 `CHANGES.md`: entrada de `presupuestos-modulo` (alcance, migraciones, decisiones clave, OQs y su resolución) y el orden de locks de la conversión (`quotes` → productos → inserciones de venta) documentado junto a la regla global. Candidatos que deja:
  - migrar el comprobante interno de venta a `build_commercial_document_pdf`;
  - migrar el POS a los helpers de carrito extraídos (`sale-form` ya se migra en este change);
  - link público y aceptación online;
  - OQ-P10 si queda abierta;
  - el hallazgo de invalidación del POS (caja, banco y productos) queda cerrado por `invalidateAfterSale`: anotarlo.
  
  **No** tocar `CLAUDE.md` ni `AGENTS.md` en este change.
- [ ] 8.2 `knowledge-base/05_reglas_de_negocio.md`: corregir RN-A2 (línea 300: "el INSERT es directo vía RLS, sin RPC" deja de ser cierto; la creación va por `rpc_create_quote` y el disparador sigue registrando el historial) y sumar las reglas nuevas del presupuesto:
  - editable hasta convertirse (editar un vencido o rechazado lo reabre a `draft`), `P0423` después;
  - no mueve stock;
  - conversión atómica al precio del presupuesto;
  - vencimiento diario, con el actor de sistema (uuid cero);
  - numeración interna por cuenta.
  
  `knowledge-base/06_funcionalidades.md`: módulo de presupuestos.
- [ ] 8.3 Docstrings de los módulos nuevos (propósito, decisiones D-n que implementan) y `COMMENT ON` de cada objeto SQL nuevo.

## 9. Post-merge (por tanda)

- [ ] 9.1 Tanda A, verificación en prod (sólo lectura):
  - `MAX(version) = 20261067000001`;
  - columnas, `UNIQUE` y disparador;
  - las 4 políticas de escritura ausentes;
  - ACLs de las funciones nuevas;
  - `cron.job` con `quotes-expire-sweep`;
  - `default_quote_validity_days = 15` en todas las cuentas;
  - las filas `quote: expired → draft` y `rejected → draft` en `document_status_transitions`.
  
  Verificar el deploy de Render (`GET /deploys`) y dispararlo si no corrió.
- [ ] 9.2 **[PO]** Humo de la tanda A en prod: crear un presupuesto para un cliente real con teléfono → descargarlo → enviarlo por WhatsApp desde el celular, en Android y en iPhone (llega el PDF adjunto) → editarlo → rechazar uno y reabrirlo editándolo → duplicar → eliminar un borrador.
- [ ] 9.3 Tanda B, verificación en prod (sólo lectura):
  - `MAX(version) = 20261068000001`;
  - una sola definición de `rpc_accept_quote`, que delega en el núcleo;
  - `_quote_accept_core` sin `authenticated`;
  - `rpc_convert_quote_to_sale` sin `anon`;
  - `COMMENT` de `rpc_accept_quote` conservado.
- [ ] 9.4 **[PO]** Humo de la tanda B en prod: presupuesto → **Venta** en efectivo con caja abierta (el stock baja y aparece en caja, y `/caja` se actualiza sin recargar) → la venta aparece en `/ventas` con "Desde presupuesto" → **Facturar** → comprobante autorizado. Otra conversión a crédito (cargo en la cuenta corriente del cliente).
- [ ] 9.5 Al día siguiente del merge de A, confirmar en `cron.job_run_details` que `quotes-expire-sweep` corrió sin error.
- [ ] 9.6 Archivar el change (`/opsx:archive`) cuando 9.1–9.5 estén cerrados. Verificar en **HEAD** que los requirements se sincronizaron a `openspec/specs/{quote,sales-order,internal-document-numbering,commercial-document-pdf}` (gotchas de archive: diffear, no contar). Después, editar a mano la sección "Implementation Notes" de `openspec/specs/quote/spec.md`, que no forma parte de ningún delta y sigue diciendo "INSERT/UPDATE directo … con is_account_writer": pasa a escritura sólo por RPC, sin políticas de escritura, sin endpoint `accept`.

---

### TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| | | | | | | | |
