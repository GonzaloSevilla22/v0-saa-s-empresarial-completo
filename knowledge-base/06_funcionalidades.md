# 06 — Funcionalidades

## Épica 1: Gestión Financiera Básica

### Ventas
- Registrar venta simple (un producto, cantidad, precio, cliente opcional)
- Registrar venta multi-producto (carrito) con `operation_id` compartido
- Seleccionar unidad de medida por ítem (ej: vender "2.5 kg" de arroz)
- Asociar venta a cliente existente o registrar como "sin cliente"
- Listar ventas con filtros por fecha, producto, cliente
- Editar/eliminar venta (elimina el carrito completo si tiene varios ítems)
- Ver total vendido por período (dashboard)

### Compras
- Registrar compra a proveedor (producto, cantidad, costo unitario)
- Registrar compra multi-producto con carrito
- Agregar descripción libre por ítem de compra
- Listar compras con filtros por fecha y producto
- Editar/eliminar compra

### Gastos
- Registrar gasto con categoría (Alquiler, Servicios, Marketing, Logística, Personal, Impuestos, Otros)
- Agregar descripción al gasto
- Listar gastos con filtros por fecha y categoría
- Ver gráfico de gastos por categoría (pie chart)

---

## Épica 2: Productos e Inventario

### Catálogo de Productos
- Crear producto con nombre, categoría, precio de venta, costo, stock inicial
- Asignar código de barras (barcode) y SKU únicos por usuario
- Definir tipo de control de stock: tracked / untracked / variant_only
- Asignar unidad de medida base (kg, litro, unidad, etc.)
- Establecer stock mínimo para alertas automáticas

### Variantes de Producto
- Crear producto padre (stock_control_type = 'variant_only')
- Agregar variantes hijo con atributos (color/talle/tamaño + valor)
- Cada variante tiene su propio precio, costo, stock y SKU
- Las variantes son invisibles al cliente como "padre" — solo se venden las variantes

### Unidades de Medida
- Usar unidades del sistema (Unidad, Kg, Litro, Metro, etc.)
- Crear unidades personalizadas por usuario
- Definir factor de conversión respecto a unidad base del grupo
- Asignar unidad base a cada producto (hereda a las ventas/compras)

### Stock
- Ver inventario actual de todos los productos
- Realizar ajuste de stock manual (con razón y notas)
- Ver historial completo de movimientos por producto (ledger inmutable)
- Recibir alerta automática por email cuando stock ≤ min_stock

---

## Épica 3: Clientes

- Crear cliente con nombre, email y teléfono
- Ver directorio de clientes con estado (activo/inactivo/perdido)
- Ver historial de compras por cliente (total gastado, última compra)
- Asociar ventas a clientes registrados
- Filtrar y buscar clientes

---

## Épica 4: IA / Insights

### Insights Automáticos (`ai-insights`)
- Analizar últimos 30 días de ventas, gastos y stock
- Generar hasta 4 insights accionables con datos reales del usuario
- Clasificar por tipo: ventas, stock, margen, rotación, oportunidad
- Clasificar por prioridad: alta, media, baja
- Guardar insights en historial (`ai_insights`)
- Respetar límite de uso por plan (5 para free, ilimitado para pro)

### Predicciones (`ai-prediccion`)
- Predecir tendencia de ventas para los próximos N días (default 7)
- Basado en historial de 30 días de ventas reales
- Devuelve análisis narrativo (no estructurado)

### Resumen Financiero (`ai-resumen`)
- Generar resumen del período: daily / weekly / monthly
- Calcula: total ventas, total gastos, balance
- Devuelve análisis narrativo profesional en español

### Simulador de Escenarios (`ai-simulador`)
- Recibir escenario en texto libre (ej: "¿Qué pasa si subo el precio un 20%?")
- Analizar contra datos del mes actual
- Devuelve análisis de impacto narrativo
- Acceso completo solo en plan pro

### Copiloto IA (`copiloto-ia`)
- Chat conversacional con asistente financiero
- Guarda historial de preguntas y respuestas en `ai_conversations`
- Responde en español con contexto del negocio del usuario

### Fair Advisor (`fair-advisor`)
- Recibir parámetros del evento (tipo de feria, fecha)
- Calcular score de productos: `units_sold + (margin/10) + (has_stock ? 5 : 0)`
- Seleccionar top 15 productos por score
- LLM recomienda 3-5 productos con razón, unidades sugeridas y precio
- Guardar recomendación en `fair_recommendations`

---

## Épica 5: OCR de Facturas

- Subir foto o PDF de factura de proveedor al storage
- Procesar con OpenAI: extraer proveedor, CUIT, número de factura, fecha, ítems
- Ver resultado con nivel de confianza y advertencias
- Hacer match OCR → producto del catálogo (manual o sugerido)
- Confirmar y convertir la factura en una compra registrada
- Aprender alias del OCR para el mismo proveedor en facturas futuras
- Deduplicar: rechazar si ya existe (user_id, supplier_cuit, invoice_number)
- Construir directorio de proveedores desde los encabezados de facturas

---

## Épica 6: Comunidad y Aprendizaje

### Foro Comunitario
- Ver posts públicos de todos los emprendedores
- Crear post con título y contenido (solo plan pro)
- Responder en un post (solo plan pro)
- Borrar propio post/respuesta (autor) o cualquier post (admin)
- Ver perfil del autor en cada post

### Cursos
- Listar cursos disponibles (con nivel, categoría, rating, alumnos)
- Ver todos los cursos en pro; solo básicos en free
- Iniciar y completar un curso
- Marcar curso como completado (no hay % parcial)
- Ver progreso en el perfil

### Reuniones y Eventos (Admin gestiona)
- Ver próximas reuniones con link de acceso
- Recibir email automático cuando se crea una nueva reunión

### Pools de Compra Grupal (Admin gestiona)
- Ver pools de compra activos con monto objetivo/actual y fecha de cierre
- Recibir email cuando se abre un pool nuevo

---

## Épica 7: Administración (Solo Admin)

### Métricas de la Plataforma (`/admin/metricas/*`)
- Dashboard AARRR: activación, retención, UMV, frecuencia semanal
- Métricas por módulo: ventas, compras, gastos, clientes, stock, IA, comunidad, cursos, simulador
- Visualizaciones con D3.js y Recharts

### Gestión de Contenido
- CRUD de cursos (crear, editar, publicar/despublicar)
- CRUD de reuniones y pools de compra
- Edición de landing page por secciones

### Analytics Avanzado
- Ver eventos de `analytics_events` en dashboard (`/admin/analytics`)
- Ver logs de emails enviados (`email_logs`)
- Monitorear uso de IA por usuario

---

## Épica 8: Configuración de Cuenta

- Editar perfil: nombre, apellido, nombre del negocio, bio, teléfono
- Cambiar avatar (upload a bucket `avatars`)
- Configurar moneda preferida (ARS, USD, EUR, BRL, CLP)
- Configurar zona horaria
- Configurar formato de fecha
- Cambiar idioma de la interfaz (español por defecto)

---

## Épica 9: Autenticación y Onboarding

- Registro de cuenta con email + contraseña
- Login con email + contraseña
- Verificación de email post-registro
- Recuperación de contraseña via email
- Email de bienvenida automático al confirmar cuenta
- Middleware de autenticación: redirigir a login si no hay sesión activa

---

## Épica 10: Sistema de Email Transaccional

- Bienvenida al confirmar cuenta (`welcome`)
- Alerta de stock bajo (`low_stock_alert`) — automática, max 1 por producto/24h
- Aviso de nueva reunión (`meeting_notice`) — automático en INSERT de meetings
- Aviso de nuevo pool de compra (`pool_notice`) — automático en INSERT de pools
- Alerta de margen bajo (`low_margin_alert`) — definida, no activada aún en MVP

---

## Estado por Módulo (Junio 2026)

| Módulo | Estado |
|---|---|
| Ventas / Compras / Gastos | ✅ Funcional (bugs menores en depuración) |
| Productos + Variantes | ✅ Funcional |
| Unidades de Medida | ✅ Funcional |
| Stock + Ledger | ✅ Funcional |
| Clientes | ✅ Funcional |
| IA Insights | ✅ Funcional con LLM real |
| IA Predicciones | ✅ Funcional |
| IA Resumen | ✅ Funcional |
| IA Simulador | ✅ Funcional |
| IA Copiloto | ✅ Funcional |
| Fair Advisor | ✅ Funcional |
| OCR Facturas | ✅ Funcional |
| Comunidad | ⚠️ Funcional con bugs conocidos |
| Cursos | ✅ Funcional (contenido admin) |
| Admin Métricas | ✅ Funcional |
| Billing / Planes | ❌ No implementado (beta all-pro) |
| Período de gracia 60d | ❌ No implementado |

> ⚠️ Tabla de estado previa a las Fases 1-5 de CHANGES.md: billing (Fase 1), IA split (Fase 2), multi-tenant/roles/sucursales (Fase 3), upgrade UX/exportaciones (Fase 4) y backend Python (Fase 5) ya están completados.

---

## Épicas V2 (planificadas — modelo de dominio V2, adoptado 2026-06-09)

> Fuente: `modelo-dominio-aliadata-v2.md` §10.4 + descomposición de la exploración `openspec/explore/2026-06-09-modelo-dominio-v2.md`.

| Fase | Contenido | Changes |
|---|---|---|
| **V2.0 — Retirada de deuda** | Tenancy única (incluye refactor del backend Python + 11 Edge Functions), `sale_items`/`purchase_items` como única fuente, ledger único de stock + Branch "Casa Central", FiscalIdentity en clientes, schema `community` separado, insights unificados, outbox activo | `v20-tenancy-cleanup`, `v20-sale-items-migration`, `v20-inventory-unification`, `v20-fiscal-identity-clients`, `v20-community-schema-split`, `v20-insights-unification`, `v20-outbox-activation` |
| **V2.1 — Operación** | Branch como Aggregate Root + transferencias, FiscalProfile + AFIP/FiscalDocument (CAE async), CashSession con arqueo, Quote → SalesOrder + `quickSale()` POS, cuentas corrientes cliente/proveedor | `v21-branch-as-root`, `v21-fiscal-profile`, `v21-cash-session`, `v21-quote-salesorder`, `v21-customer-supplier-accounts` |
| **V2.5 — Finanzas** | BankReconciliation, JournalEntry automático vía outbox, CostCenter con UI, percepciones/retenciones | (a definir) |
| **V3 — Inteligencia** | AIAgent con casos de uso reales, KnowledgeBase, automatizaciones, predicción | (a definir) |
