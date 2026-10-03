# 07 — Flujos Principales

## Flujo 1: Registro y Onboarding

```
Usuario → /auth/register
    │
    ├── Ingresa email + contraseña
    │
    ├── Supabase Auth → crea usuario en auth.users
    │
    ├── Trigger DB → crea perfil en profiles
    │   └── role='user', plan='pro' (beta), currency='ARS', language='es'
    │
    ├── Supabase Auth → envía email de verificación
    │
    ├── Usuario hace click en link → /auth/verify-email
    │
    ├── Supabase → INSERT en email_logs (event_type='welcome', status='pending')
    │
    ├── Webhook → Edge Function send-email
    │   └── Resend → envía "¡Bienvenido a ALIADATA!" con link al dashboard
    │
    └── Usuario redirigido al dashboard
```

## Flujo 2: Autenticación (Login)

```
Usuario → /auth/login
    │
    ├── Ingresa credenciales
    │
    ├── Supabase Auth → valida + devuelve JWT
    │
    ├── @supabase/ssr → guarda sesión en cookie HttpOnly
    │
    ├── middleware.ts → updateSession() en cada request
    │
    └── Usuario en /dashboard
```

## Flujo 3: Registro de Venta (UMV — Unidad Mínima de Valor)

```
Usuario → /ventas → "Nueva Venta"
    │
    ├── 1. Agrega productos al carrito
    │   ├── Busca producto por nombre/barcode/SKU
    │   ├── Define cantidad + unidad de medida
    │   └── Define precio de venta unitario
    │
    ├── 2. Asocia cliente (opcional)
    │
    ├── 3. Define fecha de la venta
    │
    ├── 4. Confirma la venta
    │   ├── Frontend genera idempotency_key (UUID)
    │   ├── Llama a RPC rpc_create_operation_aggregate con:
    │   │   └── {items[], client_id, date, idempotency_key, kind:'sale'}
    │   │
    │   ├── RPC verifica idempotencia (operation_idempotency)
    │   │   ├── Si ya existe → retorna operation_id existente (no duplica)
    │   │   └── Si no existe → INSERT en operation_idempotency
    │   │
    │   ├── RPC valida amounts > 0 (rpc_amount_guard)
    │   │
    │   ├── RPC INSERT en sales (N filas con mismo operation_id)
    │   │
    │   ├── RPC actualiza stock en products (decremento por cantidad vendida)
    │   │   └── Solo si stock_control_type = 'tracked'
    │   │
    │   └── RPC INSERT en stock_movements (una por producto vendido)
    │       └── type='sale', quantity_delta negativo
    │
    ├── 5. Check de stock bajo (trigger check_low_stock)
    │   └── Si stock ≤ min_stock → INSERT en email_logs → Webhook → Resend
    │
    └── 6. Usuario ve confirmación + dashboard actualizado
```

## Flujo 4: Generación de Insight IA (post-UMV)

```
Usuario → /insights → "Generar Insights"
    │
    ├── Frontend verifica plan (insights_used vs maxInsights)
    │   └── Si free y ≥ 5 → mostrar CTA upgrade
    │
    ├── POST a Edge Function /ai-insights con auth JWT
    │
    ├── Edge Function:
    │   ├── Consulta Supabase: ventas últimos 30 días
    │   ├── Consulta Supabase: ventas últimos 60 días (comparación)
    │   ├── Consulta Supabase: productos (costo, precio, stock, min_stock)
    │   ├── Consulta Supabase: gastos por categoría
    │   ├── Consulta Supabase: fechas de última venta por producto (rotación)
    │   │
    │   ├── Calcula métricas localmente:
    │   │   ├── total_ventas, margen_promedio, crecimiento YoY
    │   │   ├── top 5 productos por monto
    │   │   ├── productos sin rotación (sin venta en 30 días)
    │   │   ├── productos con stock crítico (stock < min_stock)
    │   │   └── productos con margen < umbral mínimo
    │   │
    │   ├── OpenAI gpt-4o-mini (timeout 25s):
    │   │   ├── Prompt: "consultor de negocios hispanohablante"
    │   │   ├── Input: JSON con métricas calculadas
    │   │   └── Output: JSON [{type, priority, message, data_point}] — máx 4
    │   │
    │   ├── Si timeout → retorna {ok: true, fallback: true}
    │   │
    │   ├── INSERT en ai_insights (4 filas)
    │   └── UPDATE profiles: insights_used += 1
    │
    └── Frontend muestra los 4 insights con prioridad y acción recomendada
```

## Flujo 5: OCR de Factura

```
Usuario → /compras → "Subir Factura"
    │
    ├── 1. Sube imagen/PDF → Supabase Storage bucket 'invoices'
    │   └── path: invoices/{user_id}/{uuid}.{ext}
    │
    ├── 2. INSERT en invoice_documents (status='pending')
    │
    ├── 3. Edge Function invoice-ocr procesa:
    │   ├── status → 'processing'
    │   ├── Descarga el archivo desde Storage
    │   ├── Llama a OpenAI gpt-4o-mini con la imagen
    │   │   └── Output: proveedor, CUIT, nro factura, fecha, ítems, total
    │   ├── Verifica deduplicación (user_id, supplier_cuit, invoice_number)
    │   │   └── Si existe → error 409
    │   ├── Calcula ai_confidence (0-1)
    │   ├── Busca matches en product_aliases y products
    │   └── UPDATE invoice_documents: status='completed', parsed_items, confidence
    │
    ├── 4. Usuario revisa resultado:
    │   ├── Ve ítems extraídos con matches sugeridos
    │   ├── Edita matches incorrectos
    │   └── Aprueba aliases para aprendizaje futuro (INSERT en product_aliases)
    │
    ├── 5. Usuario confirma la factura:
    │   ├── Crea compra via flujo estándar (Flujo carrito de compras)
    │   └── UPDATE invoice_documents: purchase_operation_id = nuevo operation_id
    │
    └── 6. Proveedor se agrega a invoice_suppliers si es nuevo
```

## Flujo 6: Fair Advisor (Recomendaciones para Feria)

```
Usuario → /ferias/ia → "Obtener Recomendaciones"
    │
    ├── POST a Edge Function /fair-advisor
    │
    ├── Edge Function:
    │   ├── Consulta todos los productos del usuario
    │   ├── Consulta historial de ventas (últimos 200 registros)
    │   ├── Calcula score local por producto:
    │   │   └── score = units_sold + (margin/10) + (has_stock ? 5 : 0)
    │   ├── Selecciona top 15 por score
    │   ├── Verifica payload < 1 MB (si no → HTTP 202, no llama a LLM)
    │   ├── OpenAI gpt-4o-mini:
    │   │   └── Output: {recommendations: [{product, reason, recommendedUnits, suggestedPrice}]}
    │   └── INSERT en fair_recommendations
    │
    └── Frontend muestra 3-5 recomendaciones con razón y precio sugerido
```

## Flujo 7: Email Transaccional (genérico)

```
Sistema (trigger DB o acción admin)
    │
    ├── INSERT en email_logs (status='pending', event_type=X, recipient=Y)
    │
    ├── Supabase Webhook detecta INSERT
    │
    ├── Llama a Edge Function send-email
    │   ├── Valida: solo INSERT, solo status='pending'
    │   ├── Determina destinatarios:
    │   │   ├── recipient = 'all_users' → fetch todos los emails de auth.users
    │   │   └── recipient = email → solo ese destinatario
    │   ├── Construye HTML según event_type
    │   ├── Resend.send({from, to, subject, html})
    │   └── UPDATE email_logs: status='sent'|'failed'|'partial', sent_at, provider_id
    │
    └── Log en email_logs para trazabilidad
```

## Flujo 8: Simulador de Escenarios IA

```
Usuario → /simulador → ingresa escenario en texto libre
    │
    ├── Ej: "¿Qué pasa si subo todos los precios un 20% y reduzco stock de productos lentos?"
    │
    ├── POST a Edge Function /ai-simulador
    │   ├── Consulta ventas y gastos del mes actual
    │   ├── OpenAI gpt-4o-mini (temperature=0.7):
    │   │   ├── Input: escenario + datos actuales del negocio
    │   │   └── Output: análisis narrativo del impacto estimado
    │   └── INSERT en ai_insights (type='simulation')
    │
    └── Frontend muestra análisis con impacto estimado del escenario
```

## Flujo 9: Ajuste Manual de Stock

```
Usuario → /stock → producto → "Ajustar Stock"
    │
    ├── Define cantidad de ajuste (positivo o negativo)
    ├── Define tipo: adjustment | physical_count | loss | damage | expiry
    ├── Agrega razón y notas
    │
    ├── Via RPC (SECURITY DEFINER):
    │   ├── UPDATE products.stock
    │   ├── INSERT en stock_movements:
    │   │   ├── type = 'adjustment' (u otro tipo elegido)
    │   │   ├── quantity_before, quantity_delta, quantity_after
    │   │   └── movement_number = siguiente secuencial global
    │   └── Check de stock bajo (trigger)
    │
    └── Usuario ve historial actualizado en ledger
```

## Flujo 10: Presupuesto a Venta (`presupuestos-modulo`, tanda B)

```
Usuario (owner/admin/seller) → /presupuestos/[id] → "Venta"
    │
    ├── Diálogo: forma de pago (catálogo), cuenta bancaria o caja según el kind,
    │   sucursal, vencimiento (crédito); precios del presupuesto, no del catálogo
    │
    ├── POST /quotes/{id}/convert  (header Idempotency-Key)
    │   └── RPC rpc_convert_quote_to_sale — UNA transacción:
    │       ├── FOR UPDATE del presupuesto; idempotencia leída bajo el lock
    │       ├── Guards: estado draft/sent, no vencido, versión confirmada
    │       │   (quote_changed), producto/cliente vivos
    │       ├── FOR UPDATE de los productos por id ascendente
    │       └── Núcleo de venta del POS (_c29_confirm_order_core, sin cambios):
    │           stock por sucursal, caja, banco, cuenta corriente con vencimiento
    │       └── Presupuesto → accepted (terminal), enlazado a la venta
    │
    └── Éxito: "Venta generada", badge "Desde presupuesto" en /ventas, "Facturar" opcional
        Error (stock, caja cerrada, versión vieja): no queda ningún efecto parcial
```

---

## Flujo 11: Remito de venta (`remitos-venta`, tanda A)

```
Usuario (seller/stock/admin/owner) → /remitos/nuevo
    │   cliente + sucursal de origen + líneas (sólo producto); domicilio opcional
    │
    ├── POST /delivery-notes  (header Idempotency-Key)
    │       └── RPC rpc_create_sale_delivery_note — UNA transacción:
    │           ├── Guards: producto vivo de la cuenta, unidad compatible, faltante por sucursal (P0409)
    │           ├── Número R-00000001 por cuenta y sentido; historial NULL → issued
    │           └── Stock: un movimiento sale/delivery_note por par producto-sucursal
    │
    ├── PUT /delivery-notes/{id}  (revision esperada; sólo issued)
    │       └── Espejo REVERSE+APPLY únicamente en los pares cuyo neto cambia;
    │           faltante controlado sobre el neto; versión vieja → delivery_note_changed
    │
    ├── GET /delivery-notes/{id}/pdf?show_prices=  → descarga o WhatsApp (sin precios por defecto)
    │
    └── POST /delivery-notes/{id}/cancel  (admin/owner, motivo)
            └── Repone lo retenido (delivery_note_reversal); estado terminal canceled
```

## Flujo 12: Remito a venta (`remitos-venta`, tanda B)

```
Usuario (seller/cashier/admin/owner) → /remitos/{id} → "Venta"  (remito issued, cliente vivo)
    │   forma de pago (efectivo / transferencia / crédito / …); sin selector de sucursal
    │
    ├── POST /delivery-notes/{id}/convert  (header Idempotency-Key, revision esperada)
    │       └── RPC rpc_convert_delivery_note_to_sale — UNA transacción:
    │           ├── Lock del remito primero; idempotencia bajo el lock; estado, versión,
    │           │   cliente vivo, sucursal activa y no cerrada
    │           ├── Orden + líneas copiadas del remito (precios y snapshots del remito),
    │           │   con source_delivery_note_id
    │           ├── _c29_confirm_order_core: revalida remito y líneas (P0409) y NO mueve stock;
    │           │   caja / cuenta corriente / banco / fiscal / outbox como cualquier venta
    │           └── Remito issued → converted (historial)
    │
    ├── Facturar (opcional): como cualquier venta
    │
    └── Borrar la venta (admin/owner)
            └── Compensa caja, cuenta corriente, banco y comprobante pendiente; NO repone stock;
                el remito vuelve a issued y se puede reconvertir
```
Editar la venta nacida de un remito está bloqueado (`delivery_note_sale_locked`); un remito convertido no se anula ni se edita.

## Flujo 13: Remito de compra (`remitos-compra`, tanda A)

```
Usuario (stock/admin/owner) → /remitos/nuevo?tipo=compra
    │   proveedor + sucursal de destino + líneas (sólo producto); N° del remito del proveedor opcional
    │
    ├── POST /delivery-notes  (direction = 'purchase', header Idempotency-Key)
    │       └── RPC rpc_create_purchase_delivery_note — UNA transacción:
    │           ├── Guards: proveedor y producto vivos de la cuenta, unidad compatible, sucursal activa
    │           ├── Número RC-00000001 por cuenta; historial NULL → issued
    │           └── Stock: un movimiento purchase/delivery_note por par producto-sucursal (SUMA)
    │
    ├── PUT /delivery-notes/{id}  (revision esperada; sólo issued)
    │       └── Espejo sólo en los pares cuyo neto cambia; las patas que suman van primero;
    │           bajar lo ya vendido → P0409 con el producto nombrado, sin efectos
    │
    ├── GET /delivery-notes/{id}/pdf?show_prices=  → descarga o WhatsApp al proveedor
    │
    └── POST /delivery-notes/{id}/cancel  (admin/owner, motivo)
            └── Resta lo retenido (purchase_return); si ya se consumió → P0409
                delivery_note_stock_consumed; estado terminal canceled
```
La conversión del remito en compra (sin volver a sumar stock) es la tanda B de `remitos-compra`.
