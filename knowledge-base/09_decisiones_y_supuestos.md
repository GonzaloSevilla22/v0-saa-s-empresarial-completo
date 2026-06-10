# 09 — Decisiones y Supuestos

## Decisiones de Diseño Documentadas

### DEC-01 — Supabase como BaaS completo (sin backend propio)
**Decisión**: Delegar todo el backend (Auth, DB, RLS, Edge Functions, Storage, Realtime) en Supabase.  
**Justificación**: Reduce drásticamente el time-to-market. No construir infraestructura antes de validar el negocio.  
**Trade-off aceptado**: vendor lock-in en Supabase. Si escala, requerirá esfuerzo de migración.  
**Plan de monitoreo**: Exportación periódica de schemas + documentación técnica completa en Git.  
**Estado**: En producción. Decisión revisada en "cuando el volumen requiera separación OLTP/OLAP".

### DEC-02 — Frontend generado con V0 (Vercel) antes del backend formal
**Decisión**: UI generada con IA generativa (V0) antes de definir la arquitectura backend.  
**Justificación**: Validar la experiencia de usuario y la narrativa del producto antes de invertir en lógica compleja.  
**Trade-off aceptado**: Deuda estética/estructural en el código de UI generado.  
**Estado**: Refactorización progresiva posible sin romper backend.

### DEC-03 — OpenAI gpt-4o-mini para todas las funciones de IA
**Decisión**: Usar `gpt-4o-mini` en todas las Edge Functions de IA (insights, predicciones, simulador, OCR, fair advisor).  
**Justificación**: Balance costo/velocidad/calidad adecuado para MVP. gpt-4o (full) sería 10x más caro.  
**Trade-off aceptado**: Menor profundidad de razonamiento vs gpt-4o full o Claude Opus.  
**Revisión**: Considerar upgrade si los usuarios reportan insights genéricos o imprecisos.

### DEC-04 — Freemium sin billing real en MVP (60 días gracia pro)
**Decisión**: El plan freemium se define en código pero no tiene pasarela de pago integrada. Todos los usuarios beta tienen plan `pro` automáticamente.  
**Justificación**: Priorizar validación de activación profunda (UMV) antes de monetización. Billing real agrega complejidad fiscal y técnica prematura.  
**Trade-off aceptado**: No hay revenue real durante la beta. Alta deuda técnica: deberá migrar a Stripe/MercadoPago con lógica de suscripciones robusta.  
**Revisión**: Cuando tasa de conversión free→pro supere umbral consistente por 2-3 meses.

### DEC-05 — IA heurística + LLM (no ML entrenado propio)
**Decisión**: Los insights se generan calculando métricas locales (en código) y luego enviando el resultado al LLM. No hay modelos de ML entrenados con datos propios.  
**Justificación**: Permite validar la percepción de valor IA sin inversión en ciencia de datos.  
**Trade-off aceptado**: Los insights no mejoran con el tiempo (no hay aprendizaje). Limitación competitiva a largo plazo.  
**Revisión**: Cuando se necesite ventaja competitiva real basada en datos propios del usuario.

### DEC-06 — Idempotencia en operaciones financieras (idempotency_key)
**Decisión**: Toda operación de carrito (venta/compra) genera un `idempotency_key` UUID en el cliente. La RPC verifica antes de escribir. Si la misma clave ya existe, devuelve la operación previa.  
**Justificación**: Prevenir duplicados por doble-click, problemas de red, o reenvío del formulario.  
**Implementación**: Tabla `operation_idempotency` con UNIQUE(user_id, idempotency_key).

### DEC-07 — Stock ledger inmutable
**Decisión**: `stock_movements` es solo-inserción. Ningún movimiento puede editarse o borrarse. Las correcciones se hacen con ajustes compensatorios.  
**Justificación**: Integridad contable y trazabilidad fiscal. El `movement_number` secuencial permite detectar huecos.  
**Trade-off aceptado**: No se pueden borrar errores de tipeo — deben compensarse con otro movimiento.

### DEC-08 — RLS como capa de autorización principal
**Decisión**: Toda la autorización de usuario vive en PostgreSQL RLS, no en una API propia.  
**Justificación**: Elimina la necesidad de una API layer. El cliente puede conectarse directamente a Supabase con la clave anónima; RLS garantiza que solo ve sus datos.  
**Trade-off aceptado**: RLS puede ser costoso en queries complejas (initplan problem). Mitigado con índices en `user_id`.

### DEC-09 — Email via evento en DB (patrón webhook)
**Decisión**: Los emails no se envían directamente desde el código de negocio. Se inserta en `email_logs` → Supabase Webhook → Edge Function → Resend.  
**Justificación**: Desacoplar el envío de email del flujo principal. Permite reintentos, deduplicación, logging y auditoría.  
**Trade-off aceptado**: Latencia adicional (webhook → edge function). No es síncrono con la acción del usuario.

### DEC-10 — Desarrollo evolutivo desacoplado (V0 → GitHub → Supabase)
**Decisión**: El proyecto no nació full-stack planificado. Evolucionó por etapas: UI generada → backend añadido → migraciones incrementales.  
**Justificación**: Evitar sobrearquitectura temprana. Iteración incremental Lean.  
**Deuda**: La falta de planeación inicial genera inconsistencias entre módulos (ej: módulo comunidad con bugs, variaciones de patrón entre services).

### DEC-11 — Unidades de medida fraccionarias (NUMERIC 15,4)
**Decisión**: El stock se almacena como `NUMERIC(15,4)` para soportar fracciones (gramos, litros, metros).  
**Justificación**: Los emprendedores de Mendoza venden en ferias con productos a granel (ej: 250g de queso, 1.5L de aceite).  
**Migración**: `20260509210816` convirtió el tipo de INTEGER a NUMERIC, con backfill de datos existentes.

### DEC-12 — Adoptar backend Python/FastAPI (modelo híbrido)
**Decisión**: Introducir un backend Python/FastAPI que centraliza la lógica de negocio y el acceso a datos (mutaciones + lecturas). El frontend mantiene conexión directa a Supabase para Realtime, Auth y Storage (ver DEC-16).
**Justificación**: Con el multi-tenant ya implementado (orgs, roles, sucursales), la autorización es compleja y hoy está dispersa entre el `DataContext` (God Object en el cliente), los RPCs y las Edge Functions. Un service layer real la centraliza, la saca del browser y la hace testeable.
**Trade-off aceptado**: El frontend pasa a depender de dos backends (FastAPI + Supabase); un salto de red adicional en las operaciones de datos.
**Estado**: **Scaffolding YA implementado y archivado** (change `fastapi-backend-monorepo`, 2026-06-06): monorepo, FastAPI, auth JWT, WebSocket, tests. **Pendiente** (CHANGES.md FASE 5): capa de datos (asyncpg + repositories), migración de la API, pagos, migración de realtime y desacople del DataContext. Vía Strangler Fig con feature flags.

### DEC-13 — JWT-passthrough en el backend (NUNCA service_role)
**Decisión**: El backend Python recibe el JWT del usuario e inyecta los claims en la conexión `asyncpg`, manteniendo la RLS org-based activa. No se usa `service_role` salvo en jobs administrativos aislados.
**Justificación**: Preserva el hardening de seguridad existente (RLS, `WITH CHECK`, triggers anti-escalación, RPCs con `auth.uid()`) como red de seguridad. Usar `service_role` obligaría a reimplementar toda la autorización en Python, tirando ese activo.
**Trade-off aceptado**: La autorización se valida en tres capas (FastAPI dependency → service guards → RLS), con algo de redundancia deliberada (defense-in-depth).
**Reemplaza parcialmente a**: DEC-08 (RLS como capa principal) — la RLS deja de ser la *única* capa y pasa a ser la *última línea*; sigue siendo obligatoria.

### DEC-14 — Infra del backend en tier gratis (Render + Upstash)
**Decisión**: Desplegar FastAPI en Render (free web service) y usar Upstash Redis (free) para cache/rate-limit. Supabase sigue en su free tier.
**Justificación**: Restricción de presupuesto = $0. Render es el free tier más usable para FastAPI con deploy desde GitHub.
**Trade-off aceptado**: Render free spinea down tras ~15 min de inactividad → cold start ~50s en la primera request. Mitigable con un cron gratis que pinguea `/health`, o upgrade a Render $7/mo cuando haya tráfico.

### DEC-15 — IA/OCR permanecen en Edge Functions (workers Python pospuestos)
**Decisión**: Los servicios de IA y OCR se mantienen como Supabase Edge Functions; los workers async en Python (ARQ) se posponen.
**Justificación**: El free tier de Render no corre workers persistentes bien, y las Edge Functions ya funcionan y son gratis dentro de límites. Reduce el alcance de la migración para mantener costo cero.
**Revisión**: Cuando haya presupuesto (Render paid) y/o el volumen de IA justifique mover los workers a Python para mejor orquestación (LangChain, etc.).

### DEC-16 — Realtime se mantiene en Supabase Realtime (WebSocket Python reservado)
**Decisión**: El tiempo real sigue 100% en Supabase Realtime. El frontend conserva sus suscripciones `supabase.channel(...).on('postgres_changes')`. El WebSocket del backend Python (`core/ws_manager.py`, `/ws/{room_id}`), aunque ya scaffoldeado, NO se usa en producción — queda como infra lista para el futuro.
**Justificación**: Supabase Realtime es gratis, aplica filtrado RLS automático (crítico en una app financiera multi-tenant) y sobrevive los cold starts de Render porque es independiente del backend. El "server-push" (insight de IA listo, OCR terminado, alerta de stock) ya se resuelve con el patrón **tabla→Realtime** que el proyecto YA usa: el backend inserta en una tabla y Supabase emite al cliente suscrito. No hay necesidad actual que Supabase no cubra.
**Descartado**: migrar todo a WebSocket Python — exigiría un proceso always-on (Render paid $7/mo), reimplementar el filtrado por room (riesgo de fuga cross-tenant) y mucho código nuevo, todo para cero beneficio incremental hoy. Decisión del usuario el 2026-06-07 (revierte la propuesta inicial de migrar a WS).
**Revisión**: Reconsiderar la mezcla (Supabase + WS Python) solo si aparece una necesidad real que Supabase no cubra: presencia/"está escribiendo", mensajes efímeros que no deben tocar la DB, o latencia sub-segundo.

### DEC-17 — Adoptar el modelo de dominio V2 (monolito modular, deuda primero)
**Decisión**: Adoptar `modelo-dominio-aliadata-v2.md` como modelo de dominio objetivo: 8 módulos en un monolito modular, ERP operativo como core domain, roadmap V2.0 (retirada de deuda H1–H7) → V2.1 (operación) → V2.5 (finanzas) → V3 (inteligencia). La retirada de deuda es prerequisito de toda construcción nueva.
**Justificación**: El esquema real acumula tres generaciones de modelo sin retirar las anteriores (triple tenancy, doble ledger de inventario, venta plana + ítems). Cada feature nueva debe decidir contra qué generación escribir — congela velocidad.
**Trade-off aceptado**: ~16–20 días de trabajo de migración antes de features nuevas visibles.
**Fecha**: 2026-06-09. Validado contra la DB real en `openspec/explore/2026-06-09-modelo-dominio-v2.md`.

### DEC-18 — Customer/Supplier separados (no Party)
**Decisión**: Agregados `Customer` y `Supplier` independientes, con `FiscalIdentity` como Value Object compartido (Shared Kernel) y `counterpartRef` para el caso dual "me compra y me vende".
**Justificación**: Party castiga el 100% de queries, formularios, permisos y reportes para optimizar un caso minoritario (solapamiento real medido ~0%: 1.101 clientes, proveedores de un dígito). ERPNext usa el mismo diseño.
**Revisión**: si el solapamiento supera ~20% de terceros activos, evaluar extracción de `FiscalIdentity` a tabla común.

### DEC-19 — Branch como Aggregate Root; stock por (product, branch)
**Decisión**: `Branch` es root de primer nivel; todo documento operativo lleva `branch_id` obligatorio (Branch "Casa Central" en onboarding, oculta si hay una sola); el stock vive en `branch_stock` por `(product, branch)` como única fuente de verdad; `products.stock` se retira (total = Σ, como vista).
**Justificación**: El hack del dual-ledger (H4) existe porque el modelo no le dio a la sucursal el lugar que la operación exige. De paso elimina el hot-row de `products.stock` a escala.

### DEC-20 — Consistencia transaccional en el hot path; outbox para el resto
**Decisión**: Venta+stock+caja+numeración fiscal en la misma transacción; contabilidad/reporting/audit/IA/email vía outbox (tabla `events`). Sin event sourcing, sin broker, sin microservicios.
**Justificación**: "No vender lo que no hay" es invariante de negocio, no UX optimista. La coreografía asíncrona entre Sales e Inventory en un monolito es complejidad sin beneficio con costo real (stock fantasma).
**Reemplaza**: la propuesta v1 de eventos asíncronos entre Sales e Inventory.

### DEC-21 — IA degradada a Supporting Domain
**Decisión**: El modelo V1 de IA queda reducido a `AIConversation` (con discriminador `conversation_kind`), `Insight` unificado y `DocumentExtraction` (OCR existente). Se eliminan de V1/V2: `AIAgent` configurable, `AICreditWallet`, `KnowledgeBase`/`Embedding`. `AIAgent` nace en V3 cuando tenga invariantes reales.
**Justificación**: Test de supervivencia (sin IA hay producto; sin ERP no), test de cheque (la PyME paga por facturar/stock/cobrar; renueva por insights), y el uso real ya votó (lo usado es IA de soporte a procesos ERP).
**Complementa**: DEC-15 (IA/OCR siguen en Edge Functions).

### DEC-22 — AFIP va en V2.1 (no postergable)
**Decisión**: `FiscalProfile` + `FiscalDocument` + `DocumentSequence` + adaptador WSFE entran en V2.1. CAE asíncrono (`pending_cae` con reintento) para no atar el hot path al uptime de AFIP.
**Justificación**: En Argentina la facturación electrónica es condición de existencia del producto: sin comprobante válido la PyME usaría Aliadata *además de* su facturador, no *en lugar de*.
**Revierte**: la postergación "post-validación" de la tabla de decisiones postergadas.
**Governance**: CRÍTICO (facturación real).

### DEC-23 — V2.0 incluye el refactor de tenancy del backend Python y las Edge Functions
**Decisión**: `v20-tenancy-cleanup` incluye en su scope el refactor del backend FastAPI (118 ocurrencias de `user_id` en 7 repositories) y de las 11 Edge Functions que filtran por `user_id`, además de las migraciones de DB.
**Justificación**: La Fase 5 (C-15→C-18) ya está completada y en producción — el documento V2 asumía un codebase sin backend Python. Si V2.0 dropea las columnas legacy sin refactorizar el backend primero, el backend se rompe en producción. La deuda de código es tan real como la de esquema.
**Pendiente**: decidir si va como change atómico o sub-change paralelo con feature flag (PA-16).

---

## Supuestos Documentados

### SUP-01 — Simplicidad > Sofisticación técnica
**Suposición**: Los emprendedores de Mendoza priorizan herramientas simples sobre funciones avanzadas.  
**Implicancia si es falso**: El producto puede percibirse como básico y perder retención.  
**Señal de revisión**: Retención a 30 días baja + feedback pidiendo funciones avanzadas.

### SUP-02 — Freemium viable en Mendoza
**Suposición**: El modelo freemium con conversión a `pro` es económicamente viable para el público target.  
**Implicancia si es falso**: La conversión no cubre costos de infraestructura.  
**Señal de revisión**: Tasa de upgrade < 3% sostenida + baja disposición a pagar en entrevistas.

### SUP-03 — IA genera percepción de valor suficiente
**Suposición**: Los insights de IA son percibidos como valiosos para la decisión de continuar usando la app.  
**Implicancia si es falso**: La IA no influye en activación ni retención.  
**Señal de revisión**: Baja interacción con insights generados + bajo porcentaje de UMV alcanzado.

### SUP-04 — WhatsApp como canal primario del usuario
**Suposición**: El usuario target usa WhatsApp diariamente y no usa herramientas de gestión financiera.  
**Implicancia**: La app debe ser tan simple como un mensaje de WhatsApp. UI compleja genera abandono.

### SUP-05 — Supabase escala para el volumen del MVP
**Suposición**: El plan de Supabase actual soporta el volumen de usuarios y queries del MVP sin degradación de performance.  
**Señal de revisión**: Latency spikes en horas pico, warnings de Supabase sobre límites de plan.

### SUP-06 — gpt-4o-mini es suficiente para insights accionables
**Suposición**: El modelo gpt-4o-mini genera insights de calidad suficiente para el segmento target (emprendedores sin formación financiera avanzada).  
**Señal de revisión**: Usuarios reportan insights obvios, genéricos o incorrectos consistentemente.

### SUP-07 — Los planes futuros tienen estructura ya definida
**Suposición**: El usuario (Gonzalo) tiene documentados los límites de los planes futuros (además de free/pro) en un Word externo. **Esta información aún no está incorporada a la KB.**  
**Acción**: Incorporar ese documento cuando esté disponible para completar `05_reglas_de_negocio.md` y `03_actores_y_roles.md`.

---

## Decisiones Postergadas Conscientemente

| Decisión | Por qué no ahora | Cuándo revisarla |
|---|---|---|
| Pasarela de pagos real (Stripe/MercadoPago) | Priorizar validar UMV y retención antes de monetización formal | Cuando conversión free→pro supere umbral consistente 2-3 meses |
| Data Warehouse / OLAP separado | Volumen no justifica separación OLTP/OLAP | Cuando volumen afecte performance o se requieran cohortes multi-anuales complejas |
| App mobile nativa (iOS/Android) | Web responsive es suficiente para MVP | Cuando tracción y feedback lo justifiquen |
| ~~Facturación electrónica AFIP~~ → **adelantada a V2.1** | Revertido por DEC-22: sin comprobante válido no hay producto para PyMEs | Va en V2.1 con CAE asíncrono |
| OAuth (Google login) | Aumenta complejidad de auth | Cuando tasa de abandono en registro sea > 30% |
| Sistema de roles avanzado (moderador, soporte) | El equipo actual es pequeño, admin cubre todo | Cuando el equipo de soporte crezca |
