# 10 — Preguntas Abiertas

## Prioridad: Alta

### ~~PA-01 — Planes futuros y sus restricciones~~ ✅ RESUELTA
**Resuelto**: Incorporado desde `tabla_resumen_planes_aliadata.docx` el 2026-06-04.  
**Ver**: `05_reglas_de_negocio.md` RN-03 a RN-07, `03_actores_y_roles.md` tabla de planes.  
**Resumen**: 4 planes comerciales (Gratis / Inicial / Avanzado ⭐ / PRO) con límites por recurso y features exclusivas por tier. Multi-usuario en planes de pago (2/5/10 usuarios) implica arquitectura de tenant no implementada aún.

### PA-02 — Lógica del período de gracia de 60 días
**Pregunta**: ¿Cómo funciona exactamente el período de gracia de 60 días?  
- ¿Los 60 días cuentan desde el registro o desde la primera operación?
- Al vencer: ¿se bloquea totalmente la cuenta o se degradan features específicas?
- ¿Hay una notificación pre-vencimiento (7 días antes, 1 día antes)?
- ¿Qué ve el usuario al intentar usar una feature bloqueada?  
**Impacto**: Diseño del flujo de UI de upgrade + lógica del cron job de downgrade.

### ~~PA-03 — Rol de comunidad: ¿qué features son exactamente "solo lectura" para free?~~ ✅ RESUELTA (C-09)
**Resuelto**: 2026-06-04 — community-bug-fixes.  
**Respuesta canónica:**
- Usuarios `free`: pueden **leer** todos los posts y replies (SELECT sin restricción de plan — RN-60).
- Usuarios `free`: **no pueden crear posts ni responder** — bloqueado tanto en UI (guard `isPro`) como en DB (RLS WITH CHECK verifica `plan = 'pro'`).
- Usuarios `free`: **pueden dar like** a posts (la acción de like no tiene restricción de plan — es engagement, no contenido).
- **CTA visible**: al intentar postear o responder, los usuarios free ven un banner inline con link a `/planes` (no un tooltip que requiere hover).
- Cursos básicos: se definen por `courses.is_pro = false` — sin criterio adicional (RN-70).

### PA-04 — Bugs conocidos en módulo comunidad
**Pregunta**: ¿Cuáles son los bugs específicos en el módulo de comunidad?  
**Contexto**: En las respuestas al onboarding se marcó el módulo comunidad como "con bugs". Sin detalles, no se puede priorizar el fix.  
**Acción pendiente**: Listar los bugs conocidos para incluirlos en el roadmap.

---

## Prioridad: Media

### PA-05 — Período de reset de contadores IA ✅ RESUELTO (C-04)
**Resolución**: Reset mensual — el primer día de cada mes a las 00:00 UTC, via pg_cron `reset-ai-counters`.  
El cron actualiza `ai_queries_used = 0`, `ai_advice_used = 0`, `usage_reset_at = now()` en todos los perfiles.  
Campo canónico: `usage_reset_at` (renombrado de `insights_reset_at` en C-01).

### PA-06 — Roles futuros adicionales
**Pregunta**: ¿Qué roles están planificados para el futuro?  
**Contexto**: El usuario mencionó que habrá más roles además de free/pro/admin. ¿Hay un rol de "moderador de comunidad", "soporte", "partner"?

### PA-07 — ¿Cómo se mide el "active user" para retención a 30 días?
**Pregunta**: Para el KPI de retención a 30 días: ¿un usuario "activo" es el que:
- Inicia sesión
- Registra ≥ 1 operación
- Genera ≥ 1 insight
- Otra acción?  
**Contexto**: Los `analytics_events` registran acciones pero no hay una definición canónica de "usuario activo" para los dashboards admin.

### PA-08 — Estado del módulo de seguros (`/seguros`)
**Pregunta**: ¿Qué hace exactamente el módulo de seguros? ¿Es un marketplace de alianzas, un formulario de contacto, o algo más?  
**Contexto**: Existe la ruta `/seguros` y `/admin/seguros` pero no fue explorado en detalle. Es posiblemente un módulo de partnerships o contenido estático.

### PA-09 — Estrategia de OCR para facturas sin CUIT
**Pregunta**: ¿Qué hace la app cuando una factura no tiene CUIT identificable (ej: ticket de caja)?  
**Contexto**: La deduplicación se basa en `(user_id, supplier_cuit, invoice_number)`. Sin CUIT, ¿se permite guardar igual? ¿Se requiere CUIT mínimo?

### PA-10 — Configuración del Webhook de Supabase para `send-email`
**Pregunta**: ¿El webhook de Supabase que dispara `send-email` está configurado manualmente en el Dashboard o está documentado en código/config?  
**Contexto**: Los webhooks de Supabase no se configuran via migraciones SQL — son configuración manual en el Dashboard. Si el proyecto se migra o regenera, este webhook podría perderse.  
**Recomendación**: Documentar los webhooks configurados en un `INFRA.md` o en este archivo.

---

## Prioridad: Baja (Técnica / Deuda)

### PA-11 — Test coverage
**Pregunta**: ¿Hay tests unitarios, de integración o E2E? Solo se detectó `supabase/tests/` en la exploración.  
**Contexto**: No hay evidencia de tests en el frontend o las Edge Functions. El CI parece hacer solo `tsc` y `lint`.

### PA-12 — Variables de entorno faltantes en CI
**Pregunta**: ¿Las migrations de CI tienen stubs porque no hay acceso a Supabase desde CI?  
**Contexto**: `20260517000000_ci_compat_stubs.sql` sugiere que hay constraints o funciones que no se pueden aplicar en el entorno de CI. ¿Cuál es la estrategia de testing de migrations?

### PA-13 — `pnpm-workspace.yaml` — ¿hay workspaces?
**Pregunta**: El archivo `pnpm-workspace.yaml` existe en el root, pero el proyecto parece monorepo single-package. ¿Se planea un workspace multi-paquete?  
**Contexto**: La presencia de este archivo sin contenido sustancial sugiere que es un artefacto del setup inicial.

### PA-14 — Política de borrado de datos de usuario (GDPR/privacidad)
**Pregunta**: ¿Hay un flujo de eliminación de cuenta? Si un usuario pide borrar sus datos, ¿qué tablas se limpian y en qué orden?  
**Contexto**: Con usuarios reales en producción, esto es legalmente relevante, especialmente si se expande fuera de Argentina.

### PA-15 — ¿Se usa `pg_cron` para el reset de insights?
**Pregunta**: Supabase tiene `pg_cron` disponible. ¿Se planea usarlo para resetear `profiles.insights_used` en períodos fijos?

---

## Inconsistencias Detectadas

### INC-01 — `plan` default: 'free' vs 'pro'
El schema de `profiles` tiene `plan DEFAULT 'free'`, pero la migration `20260424000001_beta_all_users_pro.sql` lo cambia a 'pro' para todos. Nuevos registros: ¿heredan 'free' (schema default) y luego hay un trigger que lo sube a 'pro'? O ¿se cambió el DEFAULT a 'pro' también?  
**Recomendación**: Verificar que nuevos usuarios creados post-migration tienen `plan = 'pro'`.

### INC-02 — `client_id` puede ser NULL en sales
La tabla `sales` tiene `client_id NULLABLE`, lo cual es correcto. Pero los tipos TypeScript en `lib/types.ts` incluyen `clientId` como requerido en la interfaz `Sale`. Puede causar errores de tipado.

### INC-03 — Email sender vs nombre de la app
El sender de emails es `"ALIADATA Emprendedores <onboarding@resend.dev>"` pero el producto se llama **EmprendeSmart**. ¿"ALIADATA" es la marca superior/corporativa? ¿"EmprendeSmart" es el nombre del producto dentro de ALIADATA?

### INC-04 — `create-sale` y `create-purchase` Edge Functions vs RPCs
Existen Edge Functions `create-sale/index.ts` y `create-purchase/index.ts` Y también las RPCs `rpc_create_operation_aggregate`. ¿Cuál se usa actualmente? ¿Las Edge Functions son legacy reemplazadas por las RPCs? ¿Hay duplicación de lógica?

---

## Preguntas del Modelo V2 (exploración 2026-06-09)

> Surgidas al validar `modelo-dominio-aliadata-v2.md` contra la DB real (`openspec/explore/2026-06-09-modelo-dominio-v2.md`). Bloquean decisiones de diseño de los changes V2.0/V2.1.

### ~~PA-16 — Refactor del backend Python: ¿dentro de `v20-tenancy-cleanup` o change separado?~~ ✅ RESUELTA
**Resuelto:** 2026-06-09 — PO confirmó scope **atómico dentro de `v20-tenancy-cleanup`**.  
El refactor del backend Python (118 ocurrencias `user_id` en 7 repositorios) + las 11 Edge Functions van en el mismo change. No hay sub-change paralelo ni feature flag.

### ~~PA-17 — ¿Ventana de mantenimiento o zero-downtime estricto?~~ ✅ RESUELTA
**Resuelto:** 2026-06-09 — PO confirmó **zero-downtime estricto**.  
Estrategia: patrón Strangler Fig (columna nueva → backfill → migrar lecturas → drop viejo). Vistas de compatibilidad temporales requeridas en los pasos de backfill.

### ~~PA-18 — Las 6 filas de `companies` (+5 de `company_users`)~~ ✅ RESUELTA
**Resuelto:** 2026-06-09 — PO confirmó que son **organizaciones reales** de una versión anterior.  
El paso 1 de §7 debe mapear esas filas a `accounts` antes de hacer el drop de `company_id`.

### ~~PA-19 — Las 6 filas de `warehouses`~~ ✅ RESUELTA
**Resuelto:** 2026-06-10 — PO confirmó **migrar el stock y descartar los depósitos**.  
Auditoría en DB real: los 6 `warehouses` se llaman "Main Warehouse", creados el mismo día (2026-03-11, auto-generados por el sistema viejo de companies); solo 2 tienen stock (15 + 4 = 19 filas de `inventory_stock`). En C-21: las 19 filas migran a `branch_stock` de la sucursal "Casa Central" de cada cuenta; los warehouses NO se convierten en branches y se descartan con el drop de la tabla.

### ~~PA-20 — Variantes en el backfill de `sale_items`~~ ✅ RESUELTA
**Resuelto:** 2026-06-10 — PO confirmó **`variant_id = NULL`** en el backfill.  
Contrato definitivo de `sale_items`: producto obligatorio, variante opcional (`variant_id` nullable). Las 128 ventas legacy quedan sin variante; no se crean variantes default por producto.

### ~~PA-21 — Scope del outbox en V2.0~~ ✅ RESUELTA
**Resuelto:** 2026-06-10 — PO confirmó **AuditLog + EmailNotification**.  
Consumers V2.0: entrada en `audit_logs` por cada evento + emails para `sale_created` / `stock_adjusted` / `plan_changed`. Consumers de IA/reporting quedan para V2.1. (Misma fecha: PO decidió **Opción A** para C-24 — renombrar `ai_insights` → `insights`.)

### PA-22 — AFIP V2.1: ¿homologación o producción?
Si es producción con facturas reales: certificado digital + alta de punto de venta AFIP están en el camino crítico y no son bloqueables por código.

### PA-23 — Naming y reposicionamiento
El doc V2 habla de "Aliadata" y "PyMEs argentinas"; la KB habla de "EmprendeSmart" y "microemprendedores de Mendoza" (relacionado: INC-03). ¿El reposicionamiento reemplaza o amplía el segmento original? ¿Cuál es el nombre canónico del producto?
