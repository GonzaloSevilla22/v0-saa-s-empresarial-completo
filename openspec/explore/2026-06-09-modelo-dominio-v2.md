# Exploración: Modelo de Dominio Aliadata V2 — Validación contra código y esquema real

> **Tipo:** Exploración (modo thinking — sin implementación)
> **Fecha:** 2026-06-09
> **Proyecto:** EmprendeSmart (EIE) — Supabase project `gxdhpxvdjjkmxhdkkwyb`
> **Fuente primaria:** `modelo-dominio-aliadata-v2.md` (raíz del repo)
> **Scope:** Validar hallazgos H1–H8 contra DB real, mapear dependencias de código, sizing §7, interacción con Fase 5, decomposición en changes.

---

## 1. Veredicto por hallazgo H1–H8

### H1 — Triple clave de tenancy
**Veredicto: CONFIRMADO con matiz importante**

Evidencia SQL:

| Tabla | has_user_id | has_company_id | has_account_id |
|---|---|---|---|
| `sales` | ✅ | ✅ | ✅ |
| `purchases` | ✅ | ✅ | ✅ |
| `products` | ✅ | ✅ | ✅ |
| `expenses` | ✅ | ✅ | ✅ |
| `clients` | ✅ | ✅ | ✅ |
| `stock_movements` | ✅ | ❌ | ✅ |
| `suppliers` | ❌ | ✅ | ❌ |
| `branch_stock` | ❌ | ❌ | ✅ |
| `inventory_movements` | ❌ | ✅ | ❌ |

**Matiz respecto al documento:** El documento afirma que `companies`/`company_users` están **vacías** (legacy muerto). En realidad tienen **6 filas y 5 filas** respectivamente — son casi vacías pero no del todo. Las políticas RLS activas ya usan `account_id` exclusivamente (`current_account_ids()`, `is_account_writer(account_id)`): la migración funcional hacia `accounts` ya ocurrió, pero los campos `user_id` y `company_id` siguen presentes en las tablas ERP como columnas legacy sin eliminar.

Adicionalmente, `suppliers` carece de `account_id` — usa solo `company_id` para tenancy — lo cual es un hueco de seguridad no mencionado en el documento.

**Carga real de §7 paso 1:** Backfill solo en tablas donde `account_id` ya existe (completar NULLs). La tabla `suppliers` requiere agregar la columna primero. El drop de `company_id` y `user_id` de las tablas ERP es la tarea real.

---

### H2 — Doble ledger de inventario
**Veredicto: CONFIRMADO con números ligeramente diferentes**

| Sistema | Tabla | Filas reales |
|---|---|---|
| Sistema A (activo) | `stock_movements` | 492 |
| Sistema A (activo) | `branch_stock` | 2.249 |
| Sistema B (semi-muerto) | `inventory_stock` | **19** (doc dice 18) |
| Sistema B (semi-muerto) | `inventory_movements` | **22** (doc dice 21) |
| Sistema B (semi-muerto) | `warehouses` | **6** (doc dice 0) |
| Sistema B (semi-muerto) | `product_variants` | 56 |

`products.stock` existe como columna (confirmado: `information_schema` devuelve 1 fila). `inventory_stock` tiene estructura `(variant_id, warehouse_id, quantity)` — solo tres columnas, sin `account_id`, confirma que es generación anterior.

**Sorpresa:** `warehouses` tiene **6 filas** (el documento decía 0). No son "vacíos" — hay datos reales en el sistema B. Esto eleva el riesgo de migración del paso 3.

---

### H3 — Venta plana + venta con ítems
**Veredicto: CONFIRMADO con detalle nuevo**

- `sales`: 128 de 129 filas tienen `product_id` NOT NULL (flat). Solo 1 sin producto.
- `sale_items`: 23 filas (doc decía 20) — todas vinculadas a ventas que **también tienen product_id** en el header. Es decir, el sistema dual existe y la nueva generación no reemplazó a la vieja: hay ventas con ambos esquemas activos simultáneamente.
- `purchases`: 181 de 184 con `product_id`. `purchase_items`: 18 filas (doc dice 16, actualizado).
- `sale_items` y `purchase_items` referencian `variant_id` (no `product_id`), lo cual indica que son de la generación de variantes — diferente al header flat que tiene `product_id`.

---

### H4 — Dual-ledger por sucursal documentado como hack
**Veredicto: CONFIRMADO**

El comentario en `branch_stock` es literal en el schema: *"Dual-ledger: when a sale or purchase has branch_id, this table is updated instead of products.stock"*. Esto es evidencia directa del hack. El stock total por producto no tiene fuente única.

---

### H5 — Cliente sin identidad fiscal
**Veredicto: CONFIRMADO**

`clients` columnas: `id`, `user_id`, `name`, `email`, `phone`, `created_at`, `status`, `category`, `company_id`, `deleted_at`, `account_id`. Sin `tax_id` ni ningún campo de CUIT/DNI.

`suppliers` sí tiene `tax_id TEXT`. La asimetría es real y bloquea facturación electrónica a clientes.

**Adicionalmente:** `suppliers` tiene `company_id` pero no `account_id` — herencia de la generación anterior, completamente desconectado del modelo de tenancy activo.

---

### H6 — Scope creep fuera del ERP
**Veredicto: CONFIRMADO**

Tablas no-ERP conviviendo en el esquema `public`:

| Tabla | Filas | Dominio |
|---|---|---|
| `courses` | 6 | Comunidad |
| `course_modules` | 0 | Comunidad |
| `course_lessons` | 0 | Comunidad |
| `course_enrollments` | 4 | Comunidad |
| `lesson_progress` | 0 | Comunidad |
| `posts` | 5 | Comunidad |
| `replies` | 4 | Comunidad |
| `post_likes` | 0 | Comunidad |
| `meetings` | 0 | Comunidad |
| `seguros` | 0 | Vertical seguros |
| `purchase_pools` | 0 | Compras grupales |
| `landing_sections` | 4 | Marketing |
| `fair_recommendations` | 3 | Feria/events |
| `fair_ai_tools` | 0 | Feria/events |

La mayoría son funcionalidades que no pertenecen al ERP operativo. La migración al esquema `community` es de bajo riesgo (casi sin datos) excepto `courses` con 6 filas y `course_enrollments` con 4.

---

### H7 — Insights duplicados
**Veredicto: CONFIRMADO**

- `insights`: 427 filas — estructura: `(id, user_id, type, content, actionable, created_at)`. Sin `account_id`.
- `ai_insights`: 726 filas — estructura: `(id, user_id, type, priority, message, created_at, account_id)`.
- Modelos distintos: `insights` usa `content` + `actionable`; `ai_insights` usa `message` + `priority`. La unificación requiere mapeo de campos y decisión sobre cuál schema es canónico.

---

### H8 — Cosas bien hechas
**Veredicto: CONFIRMADO Y AMPLIADO**

| Elemento | Estado | Notas |
|---|---|---|
| `operation_idempotency` | ✅ Activo, 23 filas | Idempotencia atómica en las RPCs |
| `plan_limits` | ✅ Activo, 4 filas | Un plan por tier |
| `billing_events` | ✅ Activo, 52 filas | Audit trail de pagos |
| `events` (outbox) | ✅ Existe, **0 filas** | Infraestructura lista pero SIN usar aún |
| `audit_logs` | ✅ Existe, **0 filas** | Ídem — sin consumidores activos |
| RLS en todas las tablas | ✅ `rowsecurity = true` en 100% | Confirmado en todas las tablas clave |
| Políticas RLS activas | ✅ Ya usan `account_id` | `current_account_ids()` + `is_account_writer()` |
| `stock_movements` | ✅ Ledger completo | `quantity_before`, `quantity_after`, `movement_number` (bigint), `operation_group_id` |

**Observación importante:** La tabla `events` (outbox) existe y tiene RLS habilitado pero **0 filas**. El §7 paso 7 del plan (activar el outbox) es una tarea de wiring (relay + consumers), no de creación de infraestructura — la tabla ya está.

---

## 2. Mapa de dependencias del código sobre estructuras en retirada

### 2.1 `products.stock` (columna a retirar en favor de `branch_stock`)

**Archivos frontend afectados: 15**

| Archivo | Tipo de uso |
|---|---|
| `frontend/hooks/data/use-products.ts` | Lee `.stock` en el mapper; lo expone como `stock: Number(p.stock)` |
| `frontend/app/(dashboard)/stock/page.tsx` | 10+ referencias — toda la UI de stock usa `row.stock` |
| `frontend/components/products/product-catalog.tsx` | Muestra stock, calcula totales por grupo |
| `frontend/components/forms/sale-form.tsx` | Valida stock disponible antes de vender (`selectedProduct.stock`) |
| `frontend/components/stock/stock-adjustment-modal.tsx` | Muestra y opera sobre `product.stock` |
| `frontend/components/stock/low-stock-alert.tsx` | Compara `product.stock` con `minStock` |
| `frontend/components/shared/product-picker.tsx` | Muestra stock en picker |
| `frontend/components/dashboard/ai-summary-card.tsx` | Filtra productos con stock bajo |
| `frontend/lib/ai/buildBusinessSnapshot.ts` | Incluye stock en snapshots de IA |
| `frontend/lib/services/aiCopilotService.ts` | Filtra `p.stock <= p.min_stock` |
| `frontend/lib/import/validator.ts` | Valida campo stock en CSV |
| `frontend/lib/import/importer.ts` | Escribe `stock` al importar productos |
| `frontend/lib/unit-utils.ts` | Comentarios de documentación |
| `frontend/app/(dashboard)/dashboard/page.tsx` | Filtro de stock bajo |
| `backend/repositories/stock_repository.py` | `SELECT stock FROM products WHERE id = $1 AND user_id = $2` |

**Backend FastAPI (`backend/repositories/stock_repository.py`):** usa directamente `SELECT stock FROM products` con `user_id` como filtro — dos problemas en uno (columna legacy + tenancy legacy).

**Riesgo:** El frontend tiene docenas de referencias. Migrar a `branch_stock` como fuente de verdad requiere: (a) cambiar el hook `use-products` para obtener stock de `branch_stock` en lugar de `products.stock`; (b) actualizar todos los componentes que leen `row.stock`; (c) actualizar el backend `StockRepository`.

---

### 2.2 `company_id` como filtro de tenancy

**Archivos afectados: 1 archivo activo relevante** (`frontend/lib/database.types.ts` — tipos generados). El código activo ya migró a `account_id` en las queries (confirmado por las políticas RLS). El `company_id` persiste en los tipos TypeScript generados y en los campos de la DB.

`inventory_movements` y `suppliers` todavía usan `company_id` como única clave de tenancy en el esquema — no tienen RLS activa basada en `account_id`.

---

### 2.3 Campos planos en ventas (`sale.amount`, `sale.product_id`, `sale.quantity`)

**Archivos frontend afectados: ~3 directos**

| Archivo | Uso |
|---|---|
| `frontend/hooks/data/use-sales.ts` | Lee `s.product_id`, `s.quantity`, `s.amount` directamente en el mapper y en mutaciones |
| `supabase/functions/ai-insights/index.ts` | Usa `sale.product_id` y `sale.amount` |
| `supabase/functions/ai-precio/index.ts` | Consulta ventas por `product_id` |

**Backend FastAPI (`backend/repositories/sales_repository.py`):** la query paginada hace `SELECT s.product_id, s.quantity, s.amount` directamente del header — ambas generaciones mezcladas.

El `rpc_create_sale_operation` (RPC en Supabase) seguramente maneja la escritura — no es código de app pero es una dependencia crítica a validar al migrar a sale_items puro.

---

### 2.4 `user_id` como filtro de tenancy (en lugar de `account_id`)

**Backend: 7 archivos de repositorios con 118 ocurrencias de `user_id`** — todos los repositorios del backend Python usan `user_id` como filtro de tenancy en sus queries SQL:
- `sales_repository.py`: `WHERE user_id = $1`
- `purchase_repository.py`, `product_repository.py`, `expense_repository.py`, `client_repository.py`, `branch_repository.py`, `stock_repository.py`

**Edge Functions (Supabase): 11 funciones** usan `user_id` como filtro primario: `ai-insights`, `ai-resumen`, `ai-comparativo`, `ai-simulador`, `ai-prediccion`, `ai-precio`, `ai-rentabilidad`, `fair-advisor`, `invoice-ocr`, `generate-export`, `ai-quota.ts`.

**Frontend hooks: 4 archivos** tienen `user_id` como clave de query (`use-products`, `use-posts`, `use-clients`, `use-expenses-query`).

Este es el cambio de mayor alcance: afecta la totalidad del backend Python recién construido y todas las Edge Functions de IA.

---

### 2.5 `inventory_stock` / `inventory_movements` / `warehouses`

**Afectación en código activo: solo en `database.types.ts`** (tipos generados). No hay consumidores activos de estas tablas en el código de la app. La migración de los datos (19/22 filas) es la tarea, no el refactor de código.

---

## 3. Interacción con Fase 5 (C-15→C-18)

**Estado actual de la Fase 5:** Todos los changes están marcados como `[x]` completados en CHANGES.md. Los archives confirman fechas 2026-06-07. El backend FastAPI está construido y en producción/Render.

**Impacto del V2 debt-retirement sobre la Fase 5 ya implementada:**

| Change Fase 5 | Impacto de V2 |
|---|---|
| `C-15 backend-data-layer` (completado) | La capa de datos usa `user_id` como filtro en todos los repositorios. El §7 paso 1 (tenancy única) invalida la interfaz actual de los repositorios. Requiere refactor masivo del backend. |
| `C-16 backend-data-api-migration` (completado) | Los endpoints de ventas leen `product_id/amount/quantity` del header flat. El §7 paso 2 (migrar a sale_items) rompe estos endpoints. |
| `C-17 backend-payments-migration` (completado) | Sin impacto directo — opera sobre `billing_events` y `accounts`, que están en el modelo V2 target. |
| `C-18 frontend-decouple-datacontext` (completado) | Los hooks migrados leen `products.stock`. El §7 paso 3 (unificar inventario) requiere actualizar todos estos hooks. |

**Consecuencia del reordenamiento (V2.0 primero, Fase 5 después):**

El PO decidió que V2.0 va primero. Dado que la Fase 5 está **ya completada**, el reordenamiento implica que:

1. El backend Python construido en C-15/C-16/C-18 funcionará correctamente mientras use las tablas legacy (como hoy), pero deberá ser refactorizado durante V2.0.
2. La deuda de `user_id`-como-tenancy en el backend no es hipotética — está en producción con 118 ocurrencias en los repositorios.
3. **Riesgo concreto:** Si V2.0 hace el backfill y drop de columnas legacy (`company_id`, `user_id`) sin refactorizar el backend primero, el backend Python se romperá en producción.
4. **Solución recomendada:** El change V2.0-tenancy-cleanup debe incluir el refactor del backend Python como parte de su scope, o tener un sub-change dedicado que corra en paralelo.

El §7 del documento asume implícitamente un codebase sin backend Python — esa asunción es incorrecta hoy. La deuda de código es tan real como la deuda de esquema.

---

## 4. Sizing y riesgos por paso del §7

| Paso | Acción | Tamaño | Riesgo principal | Notas |
|---|---|---|---|---|
| **1** | Backfill `account_id` en todas las tablas ERP; drop `company_id`, `user_id` tenancy; migrar `suppliers` | **L** | Downtime en producción si se hace mal; rompe backend Python (118 ocurrencias `user_id`) y Edge Functions (11 funciones). Necesita refactor masivo de backend + EF en el mismo change. | `companies` tiene 6 filas — requiere decisión sobre esos registros. `suppliers` no tiene `account_id` — requiere columna nueva + backfill. |
| **2** | Migrar ventas/compras planas a `sale_items`/`purchase_items`; drop `product_id/amount/quantity` del header | **M** | Las 128 ventas con `product_id` en header necesitan row en `sale_items` — backfill de datos. El RPC `rpc_create_sale_operation` escribe en ambos formatos — requiere nueva versión. Frontend hook `use-sales` y Edge Functions de IA leen campos del header. | `sale_items` referencia `variant_id`, no `product_id` — el backfill requiere resolver variante por defecto para cada venta legacy (join con `product_variants`). |
| **3** | Unificar inventario: migrar `inventory_stock`/`inventory_movements` al ledger `branch_stock`; crear Branch "Casa Central"; drop `products.stock`; drop `warehouses` | **L** | `warehouses` tiene **6 filas** reales (no estaba vacío). 15 archivos frontend usan `products.stock` directamente. Backend `StockRepository` hace `SELECT stock FROM products`. Riesgo de stock equivocado durante la transición (vista de compatibilidad necesaria). | La vista de compatibilidad `products.stock = SUM(branch_stock.quantity)` es la mitigación clave. El rename conceptual de `account_id` → `organization_id` es opcional en V2.0. |
| **4** | Agregar `FiscalIdentity` a `clients` (CUIT/DNI, condición IVA) | **S** | Bajo. Solo agrega columnas nullable. Migración de datos sin datos previos que perder. | `suppliers` ya tiene `tax_id`. El V2 propone un VO compartido `FiscalIdentity` — en la DB basta con las columnas. |
| **5** | Mover tablas community/vertical a esquema `community` separado | **M** | Cambio de schema en Postgres requiere recrear tablas (no hay `ALTER TABLE SET SCHEMA` sin recrear en Supabase). Las RLS policies y referencias FK deben recrearse. Pocos datos (< 20 filas entre todas). | Mitigación: hacer en ventana de mantenimiento breve o mantener vistas de compatibilidad. |
| **6** | Unificar `insights` + `ai_insights` | **S** | 427 + 726 filas = 1.153 filas a unificar. Schemas distintos (`content/actionable` vs `message/priority`). Requiere mapeo de campos. Edge Functions escriben en `ai_insights`; frontend lee de `insights` (verificar). | Decisión de diseño: ¿qué columnas va el schema unificado? `insights` carece de `account_id` — agregar en el backfill. |
| **7** | Activar el outbox sobre la tabla `events` (ya existe, 0 filas) con relay e idempotencia | **M** | Sin downtime. Riesgo de at-least-once delivery mal implementado. Pero la tabla ya tiene RLS y structure. | El relay puede ser una Edge Function o el backend Python. La idempotencia puede reusar `operation_idempotency`. |

**Tabla de sizing resumida:**

| Paso | S/M/L | Estimación días | Bloquea |
|---|---|---|---|
| 1 — Tenancy única | L | 4–6 días | Todo lo demás |
| 2 — Sale items | M | 2–3 días | V2.1 Sales |
| 3 — Inventario unificado | L | 4–5 días | V2.1 Inventory |
| 4 — FiscalIdentity clients | S | 0.5 días | V2.1 AFIP |
| 5 — Esquema community | M | 1.5–2 días | — |
| 6 — Insights unificados | S | 1 día | — |
| 7 — Outbox activo | M | 2–3 días | V2.1 Finance |

**Total V2.0:** ~16–20 días de trabajo, en serie parcial (pasos 4–7 paralelizables, paso 1 bloquea 2 y 3).

---

## 5. Descomposición recomendada en changes (V2.0 y V2.1)

### Fase V2.0 — Retirada de deuda (prerrequisito de todo)

**Regla de ejecución:** los changes marcados [CRÍTICO] no pueden correr en paralelo con producción activa sin su rama de compatibilidad. Usar Strangler Fig: nueva columna → backfill → migrar lecturas → drop vieja.

#### `v20-tenancy-cleanup` [CRÍTICO, L]
**Scope:**
- Backfill `account_id` en tablas que lo tienen pero con NULLs
- Agregar `account_id` a `suppliers` + backfill via `company_id` → `accounts` join
- Actualizar RLS de `suppliers` para usar `account_id` (align con `current_account_ids()`)
- Refactorizar backend Python: reemplazar `user_id` por `account_id` en todos los repositorios (7 archivos, 118 ocurrencias) y en `core/auth.py` / `core/deps.py`
- Actualizar Edge Functions de IA (11 funciones): `user_id` → `account_id` como filtro
- Actualizar hooks frontend que usan `user_id` como clave de query (4 archivos)
- Drop `company_id` de tablas ERP (después de verificar 0 usos activos)
- Drop `user_id` de tablas ERP donde no sea `auth.users` (después de verificar)
- Resolver las 6 filas de `companies` — auditar si son organizaciones activas o datos de prueba
- **Dependencias:** ninguna (cambio en paralelo a producción, con feature flag en backend)
- **Governance:** CRÍTICO

#### `v20-sale-items-migration` [ALTO, M]
**Scope:**
- Backfill: para cada venta legacy con `product_id NOT NULL`, crear 1 fila en `sale_items` (usando variante principal o `null` si no hay variante)
- Versionar el RPC `rpc_create_sale_operation` para escribir solo en `sale_items`
- Actualizar `backend/repositories/sales_repository.py`: query paginada que lee de `sale_items` en lugar de header flat
- Actualizar `frontend/hooks/data/use-sales.ts`: mapper que lee de `sale_items` join
- Actualizar Edge Functions de IA que leen `sale.product_id/amount/quantity`
- Vista de compatibilidad temporal en `sales` para no romper otras queries durante la transición
- Drop de `product_id`, `amount`, `quantity`, `total` del header `sales` (último paso, tras validar)
- Simétrico para `purchases`/`purchase_items`
- **Dependencias:** `v20-tenancy-cleanup` (necesita `account_id` limpio primero)
- **Governance:** ALTO

#### `v20-inventory-unification` [CRÍTICO, L]
**Scope:**
- Crear Branch "Casa Central" para cada `account_id` sin branches (o con branch NULL)
- Migrar datos de `inventory_stock` (19 filas) y `inventory_movements` (22 filas) a `branch_stock` + `stock_movements` con `branch_id = casa_central_id`
- Investigar las 6 filas de `warehouses` y migrarlas o descartarlas
- Vista de compatibilidad `products.stock` como `SELECT SUM(quantity) FROM branch_stock WHERE product_id = ?`
- Actualizar backend `StockRepository`: `SELECT stock FROM products` → query sobre `branch_stock`
- Actualizar 15 archivos frontend: cambiar source de `.stock` desde `products` a `branch_stock` sum (o confiar en la vista)
- Actualizar `StockOut` schema en backend
- Eliminar `products.stock` columna (último paso, tras validar vista)
- **Dependencias:** `v20-tenancy-cleanup`
- **Governance:** CRÍTICO

#### `v20-fiscal-identity-clients` [BAJO, S]
**Scope:**
- Migración SQL: agregar `tax_id TEXT`, `iva_condition TEXT`, `legal_name TEXT` a `clients` (nullable)
- UI: formulario de cliente con campos opcionales de identidad fiscal
- Validación de CUIT formato en frontend (regex + dígito verificador)
- **Dependencias:** ninguna (paralela a otros V2.0)
- **Governance:** BAJO

#### `v20-community-schema-split` [MEDIO, M]
**Scope:**
- Crear schema `community` en Postgres
- Migrar tablas: `courses`, `course_modules`, `course_lessons`, `course_enrollments`, `lesson_progress`, `posts`, `replies`, `post_likes`, `meetings`, `seguros`, `purchase_pools`, `landing_sections`, `fair_recommendations`, `fair_ai_tools`, `copilot_prompts`
- Recrear RLS policies en el nuevo schema
- Actualizar referencias en el código (query paths)
- **Dependencias:** ninguna (paralela)
- **Governance:** MEDIO

#### `v20-insights-unification` [BAJO, S]
**Scope:**
- Definir schema canónico unificado (decisión: `message` + `priority` + `type` + `account_id` — el de `ai_insights` es más completo)
- Migrar 427 filas de `insights` al schema unificado (`content` → `message`, agregar `account_id` via join por `user_id`)
- Crear tabla unificada `unified_insights` o renombrar `ai_insights` y migrar `insights`
- Actualizar frontend y Edge Functions
- Drop `insights` tabla legacy
- **Dependencias:** `v20-tenancy-cleanup` (para tener `account_id` limpio)
- **Governance:** BAJO

#### `v20-outbox-activation` [MEDIO, M]
**Scope:**
- Implementar relay: función que lee `events` periódicamente y dispatcha a consumers
- Consumers iniciales: `AuditLog` (INSERT en `audit_logs`), `EmailNotification`
- Producir eventos desde las mutaciones principales: `SaleCreated`, `PurchaseCreated`, `StockAdjusted`
- Idempotencia de consumers via `operation_idempotency` reutilizado
- **Dependencias:** `v20-tenancy-cleanup` (para que los eventos tengan `account_id`)
- **Governance:** MEDIO

---

### Fase V2.1 — Operación (construir lo nuevo sobre deuda saldada)

#### `v21-branch-as-root` [ALTO, M]
**Scope:**
- Promover `Branch` a Aggregate Root real: `open()`/`close()` commands, lifecycle completo
- `BranchStock` reemplaza `branch_stock` con invariantes (`onHand >= 0`)
- `StockTransfer` como entidad de primer nivel (hoy existe como RPC, convertirlo en dominio)
- **Dependencias:** `v20-inventory-unification`

#### `v21-fiscal-profile` [CRÍTICO, M]
**Scope:**
- `FiscalProfile` como entidad dentro de `Organization`/`Account`: CUIT, condición IVA, config AFIP
- `DocumentSequence` para numeración AFIP sin gaps
- Adaptador WSFE (AFIP) detrás de ACL
- **Dependencias:** `v20-fiscal-identity-clients`, `v21-branch-as-root`
- **Governance:** CRÍTICO (facturación real)

#### `v21-cash-session` [MEDIO, M]
**Scope:**
- `Cashbox` + `CashSession` con apertura/cierre/arqueo
- `CashMovement` append-only
- **Dependencias:** `v21-branch-as-root`

#### `v21-quote-salesorder` [MEDIO, M]
**Scope:**
- `Quote` con `accept()`/`expire()`
- `SalesOrder` con `confirm()` transaccional (stock + caja en el mismo commit)
- Comando `quickSale()` para POS
- **Dependencias:** `v20-sale-items-migration`, `v21-branch-as-root`

#### `v21-customer-supplier-accounts` [MEDIO, M]
**Scope:**
- `CustomerAccount` con ledger append-only (`AccountMovement` con `balance_after`)
- `SupplierAccount` simétrico
- Integración con `SalesOrder.confirm()` y `PurchaseOrder.receive()`
- **Dependencias:** `v21-quote-salesorder`

---

### Orden de dependencias resumido

```
v20-tenancy-cleanup (L, CRÍTICO)
  └── v20-sale-items-migration (M)
  └── v20-inventory-unification (L, CRÍTICO)
  └── v20-insights-unification (S)
  └── v20-outbox-activation (M)
v20-fiscal-identity-clients (S) ── independiente
v20-community-schema-split (M) ── independiente

  ↓ V2.0 completo

v21-branch-as-root (M) ← v20-inventory-unification
v21-fiscal-profile (M, CRÍTICO) ← v20-fiscal-identity-clients, v21-branch-as-root
v21-cash-session (M) ← v21-branch-as-root
v21-quote-salesorder (M) ← v20-sale-items-migration, v21-branch-as-root
v21-customer-supplier-accounts (M) ← v21-quote-salesorder
```

---

## 6. Dudas abiertas para el product owner

**D1 — Fase 5 ya completada vs. V2.0 primero:**
El backend Python (C-15/C-16/C-17/C-18) está en producción con `user_id` como filtro de tenancy en 118 lugares. V2.0 `tenancy-cleanup` lo romperá. ¿El refactor del backend va dentro de `v20-tenancy-cleanup` (scope más grande pero atómico) o como change separado que corre en paralelo con feature flag?

**D2 — Compatibilidad hacia atrás durante la migración:**
Con 26 cuentas activas y usuarios reales, ¿hay ventana de mantenimiento disponible, o se requiere migración zero-downtime estricta? Esto condiciona significativamente la estrategia de las vistas de compatibilidad en pasos 2 y 3.

**D3 — Las 6 filas de `companies`:**
El documento asumía `companies` vacío. Hay 6 filas. ¿Son organizaciones de usuarios reales que probaron una versión anterior, o datos de prueba descartables? Si son reales, el paso 1 necesita una migración cuidadosa hacia `accounts`.

**D4 — `warehouses` con 6 filas:**
El documento asumía `warehouses` vacío. Hay 6 filas. ¿Representan depósitos reales de algún tenant? ¿O son datos de prueba? Esto determina si la migración del paso 3 necesita preservar esos datos o simplemente descartarlos.

**D5 — Variantes en la migración de sale_items:**
Las 128 ventas legacy tienen `product_id` en el header pero `sale_items` referencia `variant_id`. Al hacer el backfill ¿se crea una variante por defecto por producto, o se acepta `null` en `variant_id`? Esto define el contrato de la tabla `sale_items` definitiva.

**D6 — Scope del outbox en V2.0:**
¿El outbox (paso 7) activa solo `AuditLog` en V2.0, o también los consumers de reporting? Activar los consumers de IA en V2.0 agrega carga pero entrega valor de inmediato; dejarlo para V2.1 reduce el scope pero el outbox queda a mitad.

**D7 — AFIP en V2.1 (confirmado) — nivel de fidelidad:**
¿El adaptador AFIP de V2.1 cubre solo homologación (testing), o va a producción con facturas reales? Si es a producción, la revisión legal del certificado digital y el proceso de alta de punto de venta AFIP están en el camino crítico y no son bloqueables por código.

---

## Resumen ejecutivo de la exploración

Los hallazgos H1–H8 del documento se confirman en su totalidad, con tres matices importantes respecto a los datos asumidos:
- `companies` tiene 6 filas (no 0)
- `warehouses` tiene 6 filas (no 0)
- `insights` y `ai_insights` tienen esquemas distintos que requieren mapeo

El riesgo dominante no detectado en el documento es que la **Fase 5 (backend Python) ya está completa** y usa `user_id`-como-tenancy en producción — esto convierte `v20-tenancy-cleanup` en el change de mayor alcance del proyecto, con refactor obligatorio del backend Python y 11 Edge Functions en su scope.

El roadmap V2.0 → V2.1 → V2.5 → V3 es correcto. La deuda de tenancy (paso 1) es el cuello de botella real: bloquea los pasos 2, 3, 6 y 7, y requiere coordinación entre DB migrations, backend Python y Edge Functions en un solo change atómico.
