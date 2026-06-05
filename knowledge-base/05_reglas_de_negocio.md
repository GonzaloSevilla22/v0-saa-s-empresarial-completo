# 05 — Reglas de Negocio

## Dominio: Planes y Billing

> Fuente: `tabla_resumen_planes_aliadata.docx` — Fase 1, Preparación comercial definitiva (junio 2026).

### RN-01 — Beta: todos los usuarios en plan Pro
Durante la beta (junio 2026), la migration `20260424000001_beta_all_users_pro.sql` eleva todos los perfiles a `plan = 'pro'`. No hay restricciones activas por plan. **El campo `plan` en el schema actual solo tiene los valores `'free'` y `'pro'` — deberá migrarse a los 4 planes reales cuando se implemente el billing.**

### RN-02 — Trial de 30 días del plan Avanzado para usuarios nuevos
**Pendiente de implementación**: Los usuarios nuevos reciben `billing_plan = 'gratis'` como plan permanente, más un `trial_plan = 'avanzado'` de **30 días** (`trial_expires_at = now() + 30d`). Durante el trial acceden a los límites del plan Avanzado. Al vencer, quedan en los límites de `gratis`. Los usuarios beta existentes reciben `billing_plan = 'avanzado'` directamente (sin trial). La lógica de vencimiento y downgrade es C-03 (`grace-period-logic`).

### RN-03 — Estructura de planes comerciales (4 planes)

| Funcionalidad | Emprendedor Gratis | Emprendedor Inicial | Emprendedor Avanzado ⭐ | Emprendedor PRO |
|---|---|---|---|---|
| **Precio mensual** | $0 | $24.900 + IVA | $34.900 + IVA | $69.900 + IVA |
| **Usuarios** | 1 | 2 | 5 | 10 |
| **Sucursales (límite)** | 1 | 1 | 1 | 3 |
| **Clientes** | 50 | 250 | 1.000 | 3.000 |
| **Productos** | 100 | 500 | 1.500 | 5.000 |
| **Proveedores** | 20 | 100 | 300 | 1.000 |
| **Operaciones mensuales** | 100 | 500 | 2.000 | 6.000 |
| **Historial** | 30 días | 12 meses | 24 meses | 5 años / completo |
| **Exportaciones** | 0 | 3/mes | 15/mes | 50/mes |
| **Consultas IA** | 5/mes | 30/mes | 120/mes | 300/mes |
| **Consejos IA** | 3/mes | 15/mes | 60/mes | 150/mes |
| **Rentabilidad por producto** | ❌ | ❌ | ✅ | ✅ |
| **Sugerencia de precios** | ❌ | ❌ | ✅ | ✅ |
| **Reportes comparativos** | ❌ | ❌ | ✅ | ✅ |
| **Roles y permisos** | ❌ | ❌ | Básicos | Avanzados |
| **Sucursales (módulo)** | ❌ | ❌ | ❌ | ✅ |
| **Sesión mensual de análisis** | ❌ | ❌ | ❌ | ✅ |
| **Stock avanzado multisucursal** | ❌ | ❌ | ❌ | En desarrollo (sept 2026) |

> ⭐ El plan **Avanzado** es el plan recomendado en la propuesta comercial.

### RN-04 — Mapeo planes actuales → planes comerciales

El schema actual de `profiles.plan` tiene solo `'free'` y `'pro'`. Al implementar billing:

| Valor DB actual | Plan comercial equivalente |
|---|---|
| `'free'` | Emprendedor Gratis |
| `'pro'` | (beta temporal) |

Los valores del enum deberán migrarse a: `'gratis'`, `'inicial'`, `'avanzado'`, `'pro'` (o nombres equivalentes en inglés para consistencia del schema).

### RN-05 — Tracking de uso IA (consultas + consejos)
Los campos `profiles.insights_used` e `insights_reset_at` rastrean el uso de insights por período. Al implementar billing:
- **Consultas IA** = llamadas a `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador`, `copiloto-ia`
- **Consejos IA** = respuestas del fair-advisor y recomendaciones proactivas
- El período de reset es **mensual** (deducido de los límites "X/mes" de la tabla)
- Se necesita separar `insights_used` en dos contadores: `ai_queries_used` y `ai_advice_used`

### RN-06 — Features exclusivas por plan

**Solo Avanzado y PRO**:
- Rentabilidad por producto (margen por SKU individual)
- Sugerencia de precios (IA recomienda precio óptimo)
- Reportes comparativos (período vs período)
- Roles y permisos internos (usuarios múltiples con roles diferenciados)

**Solo PRO**:
- Módulo de sucursales (gestión multi-punto de venta)
- Sesión mensual de análisis (consultoría incluida)
- Stock avanzado multisucursal (en desarrollo — septiembre 2026)

### RN-07 — Multi-usuario (Inicial, Avanzado, PRO)
Los planes de pago permiten más de 1 usuario por cuenta (2, 5 y 10 respectivamente). Esto implica que el modelo de datos deberá soportar un concepto de "organización" o "tenant" con múltiples miembros. **Actualmente no implementado** — cada `user_id` en Supabase es independiente.

---

## Dominio: Operaciones Financieras

### RN-10 — Operación atómica con idempotencia
Toda venta o compra multi-producto (carrito) se agrupa bajo un único `operation_id` (UUID generado en el cliente). Antes de registrar, el sistema verifica en `operation_idempotency` que el `(user_id, idempotency_key)` no exista. Si existe, retorna la operación ya creada (idempotente). Si no existe, crea la operación completa de forma atómica via RPC.

### RN-11 — Guardia de monto (amount guard)
Ninguna operación puede registrarse con monto ≤ 0. La RPC `rpc_amount_guard` valida antes de escribir en `sales` o `purchases`. Aplica a cada ítem individual del carrito.

### RN-12 — Longitud mínima de idempotency_key
La clave de idempotencia debe tener al menos N caracteres (definido en migration `20260531232331_idempotency_key_length.sql`). Claves vacías o demasiado cortas son rechazadas.

### RN-13 — Producto eliminado no borra historial
Al eliminar un producto (`DELETE FROM products`), las referencias en `sales` y `purchases` se establecen en `NULL` (`ON DELETE SET NULL`), no se eliminan las operaciones. El historial financiero siempre es íntegro aunque el producto ya no exista.

### RN-14 — Carrito mixto (ventas y compras)
Un `operation_id` no mezcla ventas y compras. Cada operación de carrito es 100% de tipo `sale` o 100% de tipo `purchase`.

---

## Dominio: Stock e Inventario

### RN-20 — Tipos de control de stock
| Tipo | Comportamiento |
|---|---|
| `tracked` | Stock se decrementa en cada venta y se incrementa en cada compra. Mínimo stock activable. |
| `untracked` | Productos de servicio o digitales. El stock nunca cambia automáticamente. |
| `variant_only` | Producto padre (catálogo). El stock real está en las variantes hijo. El padre no tiene stock propio. |

### RN-21 — Ledger inmutable de stock
`stock_movements` es una tabla de solo-inserción. Ningún registro puede ser modificado ni eliminado por usuarios. Las correcciones se realizan mediante un movimiento de tipo `adjustment`. Las escrituras solo ocurren via RPCs con `SECURITY DEFINER`.

### RN-22 — Movement number secuencial
Cada movimiento de stock recibe un `movement_number` entero secuencial global (por usuario). Permite detectar huecos en el historial para cumplimiento fiscal y auditoría.

### RN-23 — Alerta de stock bajo
Se dispara automáticamente cuando `products.stock ≤ products.min_stock`. El trigger `check_low_stock` inserta una fila en `email_logs` con `event_type = 'low_stock_alert'`. La deduplicación garantiza máximo 1 alerta por producto por 24 horas.

### RN-24 — Stock fraccionario
El campo `products.stock` es `NUMERIC(15,4)`, soportando cantidades como `0.5 kg`, `2.350 litros`, etc. Las unidades de medida (`units_of_measure`) definen el factor de conversión a la unidad base.

### RN-25 — Variantes y padre
Un producto padre con `stock_control_type = 'variant_only'` no puede tener stock propio. Las variantes (`is_variant = true`, `parent_id != null`) son los únicos con stock rastreado cuando el padre es `variant_only`. Los atributos de la variante (color, talle, etc.) se almacenan en `product_attributes`.

---

## Dominio: IA / Insights

### RN-30 — Insights con datos reales obligatorios
Los prompts de OpenAI instruyen explícitamente: "MUST cite real numbers from the data provided". Los insights genéricos sin respaldo de datos propios del usuario son rechazados en el diseño del prompt. El LLM devuelve máximo 4 insights por llamada.

### RN-31 — Timeout con fallback gracioso
Todas las Edge Functions de IA tienen timeout de 25 segundos (margen antes del límite de 60s de Supabase). Si OpenAI no responde en ese tiempo, se retorna `{ok: true, fallback: true}` y el frontend muestra un mensaje gracioso al usuario sin romper la experiencia.

### RN-32 — Modelo LLM: gpt-4o-mini
Todas las funciones de IA usan `gpt-4o-mini` de OpenAI. Este es un dato de implementación crítico para costos y velocidad. Temperature default: 0 (determinístico); ai-simulador usa 0.7 (más creativo).

### RN-33 — Scoring del Fair Advisor
Antes de llamar al LLM, el fair advisor calcula un score local:
```
score = units_sold + (margin / 10) + (has_stock ? 5 : 0)
```
Se seleccionan los top 15 productos por score. El LLM elige 3-5 con `reason`, `recommendedUnits` y `suggestedPrice`. Payload máximo: 1 MB (si excede, retorna HTTP 202 y no llama al LLM).

### RN-34 — Insights guardados en DB
Cada insight generado se guarda en `ai_insights` con `type` y `priority`. Los tipos válidos son: `ventas`, `stock`, `margen`, `rotacion`, `oportunidad`, `prediction`, `general`, `simulation`. Las prioridades son: `alta`, `media`, `baja`.

---

## Dominio: Email / Notificaciones

### RN-40 — Patrón: DB → Webhook → Edge Function
El sistema de email usa el patrón "event sourcing via DB": el emisor inserta en `email_logs` con `status = 'pending'`. Supabase Webhook detecta el INSERT y llama a la Edge Function `send-email`, que procesa y envía via Resend.

### RN-41 — Deduplicación de emails
La constraint `UNIQUE(user_id, event_type, metadata) NULLS DISTINCT` en `email_logs` impide insertar el mismo evento dos veces. Para alertas de stock, se verifica además que no exista un registro de las últimas 24 horas para el mismo producto.

### RN-42 — Envío masivo
Si `email_logs.recipient = 'all_users'`, el sistema recupera todos los emails de `auth.users` y envía en batch con `Promise.allSettled()`. Si solo hay un email de destino: envío simple. El status del log queda `sent`, `failed`, o `partial` (si algunos destinatarios fallaron).

### RN-43 — Sender fijo
Todos los emails salen de `"ALIADATA Emprendedores <onboarding@resend.dev>"`.

---

## Dominio: OCR de Facturas

### RN-50 — Deduplicación de facturas
Un documento es considerado duplicado si `(user_id, supplier_cuit, invoice_number)` ya existe en `invoice_documents`. Se rechaza la inserción duplicada.

### RN-51 — Pipeline de estados
```
pending → processing → completed
                     → failed
```
El campo `ai_confidence` (0-1) y `ai_warnings[]` acompañan el resultado. La app debe mostrar advertencias si la confianza es baja.

### RN-52 — Aprendizaje de alias
Cuando el usuario confirma el match OCR → producto, el alias se guarda en `product_aliases` con `source = 'auto'`. Los alias manuales tienen `source = 'manual'`. Esto mejora la precisión del OCR en facturas futuras del mismo proveedor.

### RN-53 — Conversión a compra
Una factura OCR completada puede convertirse en una compra (`purchase_operation_id`) siguiendo el mismo flujo atómico del carrito (RN-10). Esta acción es irreversible una vez que `purchase_operation_id` está setteado.

---

## Dominio: Comunidad

### RN-60 — Posts: lectura pública, escritura pro
Los posts y replies son legibles por cualquier usuario autenticado (incluso free). Solo usuarios con plan `pro` pueden crear posts o respuestas. Usuarios `free` ven el contenido pero tienen CTA para actualizar a pro.

### RN-61 — Moderación de contenido
Los posts y replies pueden ser borrados por su autor o por el `admin`. No hay otros roles de moderación en el MVP.

---

## Dominio: Cursos

### RN-70 — Acceso a cursos por plan
- Plan `free`: solo cursos con `courses.is_pro = false` (nivel básico)
- Plan `pro`: todos los cursos (`is_pro` true o false)

### RN-71 — Progreso de curso
La tabla `course_progress` tiene `UNIQUE(course_id, user_id)`, lo que garantiza que cada usuario tiene un único registro de progreso por curso. El campo `completed` es booleano (no hay % parcial en MVP).

---

## Dominio: Seguridad

### RN-80 — RLS como capa de seguridad principal
La autorización se implementa a nivel de base de datos via RLS. Ninguna tabla de usuario es accesible sin autenticación válida (JWT de Supabase). Las RPCs críticas usan `SECURITY DEFINER` para operaciones que requieren privilegios elevados manteniendo la integridad.

### RN-81 — Exposición de API key
La `SUPABASE_SERVICE_ROLE_KEY` y `OPENAI_API_KEY` nunca se exponen al cliente. Solo están disponibles en Edge Functions (servidor).

### RN-82 — Búsqueda segura en `search_path`
Todas las funciones PostgreSQL critican de SQL injection via `SET search_path = public` (ver migration `20260517000002_fix_function_search_path.sql`).

### RN-83 — Índices de performance en RLS
Los patrones de RLS con `auth.uid()` tienen índices en `(user_id)` en todas las tablas principales para evitar el problema de `initplan` de RLS (ver migration `20260517000003_fix_rls_initplan_and_indexes.sql`).
