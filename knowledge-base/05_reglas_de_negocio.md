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

### RN-23 — Alerta de stock bajo (actualizada — `branch-min-stock-realign`, 2026-07-04)
Se dispara automáticamente cuando `branch_stock.quantity ≤ branch_stock.min_stock`, evaluado **por sucursal** (no contra el stock global del producto). El trigger `check_branch_low_stock` (`AFTER UPDATE ON branch_stock`) inserta una fila en `email_logs` con `event_type = 'low_branch_stock_alert'` y emite el evento `StockBelowMinimum` a la outbox transaccional (notificación in-app post-commit). La deduplicación garantiza máximo 1 alerta por `(product_id, branch_id)` por 24 horas. El trigger legacy `check_low_stock` (sobre `products.stock`/`products.min_stock`) fue retirado en C-21 checkpoint #2.

`branch_stock.min_stock` es la **única fuente de verdad** del umbral de alerta. El campo "Stock Mínimo" del formulario de productos escribe `products.min_stock` (columna DEPRECATED, ver RN-23-bis) y se **propaga** vía `rpc_set_product_min_stock` a `branch_stock.min_stock` de **todas** las sucursales donde el producto tiene filas, en la misma transacción de creación/edición. La edición fina de `min_stock` por sucursal individual está fuera de alcance (follow-up).

### RN-23-bis — Deprecación de `products.min_stock`
`products.min_stock` queda **deprecada** (`branch-min-stock-realign`, 2026-07-04): ya no es la fuente de verdad de ningún umbral de alerta — esa responsabilidad es exclusiva de `branch_stock.min_stock` (RN-23). La columna se conserva únicamente porque el dual-write del importador (`rpc_bulk_upsert_products`) todavía la escribe; su `DROP` queda diferido a un change destructivo posterior, igual que ocurrió con su hermana `products.stock` (C-21 checkpoint #2). La vista `v_products_with_stock` expone una columna `min_stock` (mismo nombre, para no romper frontend) mediante `COALESCE(MAX(branch_stock.min_stock), 0)` — ya NO lee `products.min_stock`.

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

---

## Dominio: Modelo V2 (reglas objetivo — adoptadas 2026-06-09)

> Fuente: `modelo-dominio-aliadata-v2.md` (§3, §5.9, §6) + exploración validada. Rigen el diseño de todo change V2. Las reglas RN-10..RN-25 (idempotencia, amount guard, ledger inmutable) se conservan en el modelo V2.

### RN-90 — Consistencia transaccional en el hot path de venta
Venta → descuento de stock → movimiento de caja → numeración fiscal ocurren en **la misma transacción** (commands síncronos entre módulos). "Vendí pero el stock no bajó" es un bug inaceptable, no consistencia eventual. Contabilidad, reporting, audit, insights y emails van **asíncronos vía outbox** (tabla `events` + consumers idempotentes). Sin event sourcing, sin broker, sin microservicios.

### RN-91 — Tenancy única
`account_id` (conceptualmente `organization_id`) es LA clave de tenancy en toda tabla del tenant. `user_id`-como-tenancy y `company_id` quedan prohibidos en código nuevo y se retiran en V2.0. Todo índice de tabla transaccional empieza por `(account_id, ...)`.

### RN-92 — Stock: única fuente de verdad por sucursal
El stock vive por `(product/variant, branch)` en `branch_stock`. El total por producto es Σ branch_stock (vista), nunca una columna mutable. Invariante `onHand ≥ 0` configurable por organización (permitir negativo con advertencia es pedido frecuente en retail). `products.stock` queda en retirada.

### RN-93 — BranchId obligatorio en documentos operativos
Toda venta, compra, gasto y movimiento de caja lleva `branch_id`. La organización con un solo local tiene una Branch "Casa Central" creada en onboarding; la UI la oculta si hay una sola. Transferencias entre sucursales = dos movimientos atómicos (out/in) con `transfer_id` común.

### RN-94 — Numeración fiscal sin huecos
La numeración por punto de venta AFIP vive en el agregado `DocumentSequence` con lock corto, jamás dentro de la transacción larga de la venta completa. El CAE se obtiene asíncrono (estado `pending_cae` con reintento) para que el hot path no dependa del uptime de AFIP.

### RN-95 — Sesión de caja (arqueo)
Una sola `CashSession` abierta por Cashbox; todo movimiento de efectivo exige sesión abierta; la diferencia de cierre (declarado vs esperado) queda registrada como señal antifraude. El cierre Z diario sale de acá.

### RN-96 — Cliente y proveedor con identidad fiscal
`FiscalIdentity` (CUIT/DNI, razón social, condición IVA) es un Value Object compartido entre Customer y Supplier (misma validación de dígito verificador, cero duplicación). El caso "me compra y me vende" se resuelve con `counterpartRef`, no con Party. Trigger de revisión: solapamiento real > 20% de terceros activos.

### RN-97 — Ninguna feature nueva sobre tablas en retirada
Mientras dure V2.0, ningún change puede construir sobre: tenancy `user_id`/`company_id`, ventas/compras planas, `products.stock`, sistema B de inventario (`inventory_*`, `warehouses`), `insights` legacy. Ver tabla de retirada en `04_modelo_de_datos.md`.

### RN-98 — IA nunca escribe en el ERP
AI Assist consume eventos del outbox y genera insights/conversaciones; jamás escribe en agregados del ERP. Si algún día lo hace, pasa por los mismos comandos y permisos que un humano. Gating por `plan_limits` (consultas IA/mes) — sin wallet de créditos.

### RN-99 — Ledgers append-only con saldo materializado
Stock, caja y cuentas corrientes usan el patrón contable: movimientos append-only con `balance_after` por fila (como ya hace `stock_movements`). Se consultan por SQL directo — NO es event sourcing, no se "reproducen" eventos.

## Dominio: Modelo V3 (retrofit — adoptado 2026-07-02)

> Fuente: `modelo-dominio-aliadata-v3.md` (§1, §8 RN-D) + `openspec/changes/v3-snapshot-pattern/`. Extiende al V2, no lo reemplaza.

### RN-100 — Líneas de documento inmutables tras confirm()/emisión
Una vez que un documento pasa a estado confirmado/emitido (venta confirmada, compra registrada, comprobante con CAE), sus líneas (`sale_items`, `purchase_items`/`purchases`, `sales_order_items`) **no se editan nunca** — ni el precio, ni la cantidad, ni los snapshots (`name_snapshot`, `sku_snapshot`, `unit_cost_snapshot`, `iva_rate_snapshot`) congelados en el momento de la escritura. Cualquier corrección posterior es un **documento nuevo** (nota de crédito, ajuste, nueva compra), nunca un `UPDATE` sobre la línea original. Equivalente a RN-04 (mapeo de planes: los cambios son eventos nuevos, no mutaciones del pasado) aplicado a documentos de venta/compra. Ver RN-D2 (`modelo-dominio-aliadata-v3.md`): el reporting de márgenes lee el snapshot congelado, jamás el maestro (`products`) actual — remarcar un producto no debe (ni puede, por esta regla) alterar el costo histórico de una línea ya escrita.

### RN-A1 — Todo cambio de estado registra historial en la misma transacción
Cada transición de estado de un documento (quote, sales_order, fiscal_document, cash_session, reconciliation_session, stock_transfer) inserta una fila en `document_status_history` **dentro de la misma transacción** que la operación de negocio, vía el helper `record_status_transition` (`SECURITY DEFINER`, invocado con `PERFORM` desde cada RPC de transición). Si el registro falla, la transición completa se revierte. El relay del CAE (backend Python) usa `rpc_record_fiscal_transition` en la misma transacción que el `UPDATE` de `fiscal_documents.status`. Implementado en `v3-document-status-history` (Modelo V3 §2).

### RN-A2 — La creación de un documento registra la primera entrada con `from_status = NULL`
El alta de un documento en su estado inicial (quote en `draft`, sales_order en `draft`, cash_session en `open`, reconciliation_session en `open`, fiscal_document en `pending_cae`, stock_transfer en `completed`) inserta la primera fila del historial con `from_status = NULL` y `to_status` = estado inicial. Las creaciones no se validan contra el catálogo de transiciones (no son transiciones). La creación del quote se registra vía trigger `AFTER INSERT` (el INSERT es directo vía RLS, sin RPC).

### RN-A3 — El historial de estados es append-only por estructura, no por convención
`document_status_history` tiene RLS con **una sola policy: SELECT** por `account_id` (`current_account_ids()`); no existe policy de INSERT/UPDATE/DELETE y además `UPDATE`/`DELETE` están **revocados por grants** para `authenticated`/`anon`. La escritura ocurre exclusivamente desde funciones `SECURITY DEFINER` (`record_status_transition`, revocada de los roles de aplicación). Nadie edita ni borra el pasado.

### RN-A4 — La política de transiciones es datos, con la dimensión rol estructurada
Las transiciones válidas viven en el catálogo `document_status_transitions` (`document_type`, `from_status`, `to_status`, `is_terminal_to`, `requires_reason`, `allowed_role`) — no en `if`s dispersos. `record_status_transition` rechaza con `P0409` toda transición no catalogada. El catálogo refleja las FSMs **reales** de los CHECKs vigentes (no las ideales del roadmap): las transiciones sin operación que las ejecute (ej. `sales_order → canceled`) no se siembran hasta que exista su RPC. La columna `allowed_role` queda **permisiva (`NULL` = cualquier rol) e inerte**: `v3-rbac-multirole` la poblará y activará el enforcement por rol sin migración disruptiva.

### RN-A5 — Las transiciones destructivas exigen un motivo
Cuando el catálogo marca `requires_reason = true` para el estado destino, `record_status_transition` rechaza con `P0400` todo registro sin `reason` no vacío. Casos vigentes gestionados por el RPC llamador: el cierre de caja con diferencia de arqueo ≠ 0 registra el detalle de la diferencia como `reason` (el catálogo no lo exige estático para no romper cierres sin diferencia — D7); el cierre de conciliación con diferencia exige `close_reason` (`P0431`) y lo propaga al historial. Futuras transiciones destructivas (anulación, cancelación, ajuste) deben sembrarse con `requires_reason = true`.

### RN-B1 — Filtro de soft delete centralizado, una sola vez
Toda lectura de listado o por id de un maestro excluye las filas con `deleted_at IS NOT NULL` de forma **centralizada** (`BaseRepository.not_deleted_clause()`), no repitiendo el predicado a mano en cada query. Incluir filas borradas es un **opt-in explícito** (`include_deleted=True`, casos de auditoría), nunca el default. Fuente: Modelo V3 §4; implementado en `v3-soft-delete-policy`.

### RN-B2 — El borrado de un maestro registra autor y momento
El borrado de todo maestro (`clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`) es un **soft delete**: `UPDATE ... SET deleted_at = now(), deleted_by = <usuario autenticado>` vía `BaseRepository.soft_delete()` (allowlist cerrada de tablas, anti-inyección; `cashboxes` usa la variante `soft_delete_cashbox` porque su scope de cuenta es indirecto vía `branch_id → branches.account_id`). Nunca `DELETE` físico: las referencias históricas (ventas, compras, movimientos) se preservan y siguen siendo legibles por JOIN. `deleted_at` **convive** con `is_active` donde existe (`cost_centers`, `bank_accounts`): `is_active=false` es baja lógica *reversible*; `deleted_at IS NOT NULL` es borrado (fuera de toda lectura por defecto).

### RN-B3 — Unicidad de claves naturales solo entre filas activas
Las claves naturales de maestros se protegen con índices únicos **parciales** condicionados a `WHERE deleted_at IS NULL` (además de las condiciones preexistentes): `idx_products_sku_user`, `idx_products_barcode_unique`, `cost_centers_account_name_lower_idx`. Un SKU/código/nombre borrado **se puede recrear** (la fila borrada no ocupa la clave); dos maestros *activos* jamás comparten la clave. Solo aplica donde ya existía unicidad — no se inventan claves naturales nuevas (clients/suppliers/bank_accounts/cashboxes no declaran ninguna todavía).

### RN-B4 — No se borra un maestro con referencia activa
Un producto **no se puede soft-deletear** si tiene stock ≠ 0 (Σ `branch_stock.quantity`) o aparece como línea de un documento en estado `draft` (`quote_items`→`quotes`, `sales_order_items`→`sales_orders` — unión verificada contra los CHECKs vigentes). El enforcement vive en la **DB** (`fn_guard_product_soft_delete()`, trigger `BEFORE UPDATE` sobre `products`, `ERRCODE P0B04`) para que sea imposible violarlo desde cualquier capa; el service lo traduce a HTTP 409 con mensaje de UX en español. Para el resto de los maestros no hay guard (sus referencias históricas se preservan por diseño del soft delete); extenderlo es incremental si el PO lo pide.

### Política de borrado por categoría de entidad (referencia — Modelo V3 §4)
Cinco categorías, cada una con su política:
1. **Maestros** (`clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`) → soft delete `deleted_at` + `deleted_by` (RN-B1..RN-B4). **Excepción: `branches` se desactiva (`is_active=false` + su FSM `status`/`opened_at`/`closed_at`), no se soft-deletea** — tiene movimientos referenciándola y guards propios. `categories`/`price_lists` no existen aún como tablas; si se crean, nacen con el patrón.
2. **Documentos confirmados** (ventas, compras, comprobantes fiscales, sesiones de caja) → nunca se borran; se **anulan por transición de estado con motivo** (RN-A1..RN-A5, `document-status-history`).
3. **Ledgers append-only** (stock, caja, banco, cuentas corrientes, journal) → nunca se borran ni se editan; se corrigen con **contra-asiento** (RN-99).
4. **Borradores** (quote/sales_order en `draft`, carritos) → **hard delete permitido** (sin valor probatorio).
5. **Plataforma** → `Membership` se **revoca por estado**; `UserAccount` con documentos se **anonimiza** (derecho de supresión), jamás se elimina físicamente. Declarado como política; su implementación tiene su propio ciclo.

### RN-D1 — Documentos cancelados jamás suman; las notas de crédito restan
Ningún read-model financiero (`rpc_dashboard_kpi_summary`, `rpc_period_comparison`, `rpc_product_profitability`, `rpc_branch_report`) incluye documentos cancelados/anulados en ingresos, costos ni cantidades. Las ventas legacy se anulan por `DELETE` físico con reposición de stock (quedan fuera por construcción); las `sales_orders` en estado `canceled` nunca escriben filas en `sales`. Las notas de crédito (`customer_account_movements.movement_type = 'credit_note'`) **restan** del revenue del período en el que fueron **emitidas** (`created_at`, no la fecha de la venta original) en `rpc_dashboard_kpi_summary` y `rpc_period_comparison`. Excepción documentada: `rpc_dashboard_channel_margin` no resta NC hasta que exista una regla de atribución por canal (las NC no tienen canal). Fuente: Modelo V3 §8; implementado en `v3-reporting-invariants`.

### RN-D3 — Ingresos percibidos y devengados como métricas separadas
`rpc_dashboard_kpi_summary` distingue **devengado** (`invoiced_revenue`) = Σ `COALESCE(total, amount)` de ventas del período − Σ NC del período, de **percibido** (`collected_revenue`) = devengado − Σ cargos a cuenta corriente del período (`customer_account_movements.movement_type = 'charge'`) + Σ cobros del período (`payments_received.created_at` en el período). Semántica de caja: un cobro suma al percibido del período en que se **registra**, aunque la venta sea de un período anterior. La UI (tarjeta Ganancia Neta) muestra la línea secundaria "Cobrado: $X" únicamente cuando `collected_revenue ≠ invoiced_revenue` — el 100% de las cuentas sin cuenta corriente no la ven. La rama `mp_status = approved` del texto V3 es **N/A**: no existe pasarela de cobro MercadoPago a clientes finales (MP procesa solo el billing de suscripciones de la plataforma). Fuente: Modelo V3 §8; implementado en `v3-reporting-invariants`.

### RN-D5 — Bordes de período con semántica de fecha local del tenant
Todo filtro de período en read-models interpreta los bordes como días calendario completos en la fecha local del tenant (constante de plataforma `America/Argentina/Mendoza` mientras no exista `organizations.timezone` — el 100% de los tenants está en Argentina hoy). Los rangos con parámetros `DATE` incluyen el día final completo (`>= p_start::timestamptz AND < (p_end + 1)::timestamptz`, nunca `<= p_end` casteado a medianoche UTC). Las ventanas relativas ("últimos N días", `rpc_product_profitability`) se anclan a la fecha local vía el helper `reporting_local_today()`, no a `CURRENT_DATE` del servidor (UTC) — evita que la ventana corra un día antes entre las 21:00 y las 00:00 hora Argentina. Generaliza como regla escrita el fix de timezone del dashboard (2026-06-08, `frontend/lib/date-range.ts`). Fuente: Modelo V3 §8; implementado en `v3-reporting-invariants`. Ver también spec `reporting-invariants` (RN-D2 snapshots ya resuelto por `v3-snapshot-pattern`; RN-D4 NUMERIC ya vigente en todos los RPCs de reporting; revenue de línea = `COALESCE(total, amount)` — nunca `amount` solo — y conteo de operaciones unificado (`COUNT(DISTINCT COALESCE(operation_id, id))`) se formalizan como invariantes transversales en la misma spec).
