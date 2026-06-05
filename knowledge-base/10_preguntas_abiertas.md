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

### PA-05 — Período de reset de insights para plan free
**Pregunta**: El límite de 5 insights para plan free se resetea: ¿mensualmente? ¿semanalmente? ¿diariamente?  
**Contexto**: Los campos `insights_used` e `insights_reset_at` están en `profiles` pero la lógica de reset no está implementada.

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
