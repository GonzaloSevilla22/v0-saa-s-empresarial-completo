## Context

C-15 entregó el pool asyncpg con JWT-passthrough, `get_db_conn`, `BaseRepository`, y `get_auth_context()` (org + rol + plan desde `organization_members`). El backend tiene scaffolding funcional pero ningún endpoint de datos real. Hoy toda la lógica de acceso a datos vive en `contexts/data-context.tsx` — un God Object de ~1000 líneas que mezcla estado React con llamadas directas a Supabase desde el browser. El objetivo de C-16 es exponer esa lógica como REST API en FastAPI, sin romper el frontend mientras la migración avanza. C-18 completará el desacople eliminando el `DataContext`.

**Entidades a migrar** (8 dominios en 3 sub-etapas ordenadas por riesgo):
- Sub-etapa 1 (LOW): `expenses`, `clients`
- Sub-etapa 2 (MEDIUM): `products`, `branches`, `stock`
- Sub-etapa 3 (MEDIUM-HIGH): `sales`, `purchases`, `organizations`

**Lo que NO se migra en C-16**: servicios IA/OCR (Edge Functions, DEC-15), Realtime (DEC-16), webhook de pagos (C-17).

## Goals / Non-Goals

**Goals:**
- Exponer los 8 dominios como API REST en FastAPI con Pydantic v2, services con guards, y repositories concretos
- Feature flag `NEXT_PUBLIC_USE_PYTHON_API` para rollout seguro por sub-etapa sin corte abrupto
- Tests por router: happy path, guards 403, paridad de latencia (p95 ≤ actual + 50ms)
- OpenAPI auto-generada en `/docs` y `/redoc`

**Non-Goals:**
- Migrar IA, OCR, o Realtime (se quedan en Supabase — DEC-15, DEC-16)
- Migrar el webhook de pagos (es C-17, governance CRITICO)
- Eliminar el `DataContext` o los hooks del frontend (es C-18)
- Agregar nueva funcionalidad de negocio — solo paridad de la API actual

## Decisions

### Decisión 1 — Strangler Fig con feature flag de entorno (no versioning de URL)

**Elegido**: variable de entorno `NEXT_PUBLIC_USE_PYTHON_API=true/false`. El `DataContext` revisa el flag en runtime y dirige cada llamada al endpoint FastAPI o al cliente Supabase original.

**Alternativa descartada**: versionado de URL (`/api/v2/...`). Requeriría mantener dos superficies de API indefinidamente y complicaría el rollback.

**Rationale**: el flag de entorno permite activar sub-etapas por entorno (staging primero, luego prod), hace el rollback trivial (apagar el flag), y no expone la dualidad al cliente.

---

### Decisión 2 — Un service por dominio con guards en la capa de servicio

**Elegido**: `backend/services/<domain>.py` con funciones que reciben `auth: AuthContext` y el payload validado. Los guards (`require_role`, `require_plan`) viven en el service, no en el router.

**Alternativa descartada**: guards como FastAPI `Depends` en el router. Mezcla autorización con routing y hace más difícil testear los guards de forma aislada.

**Rationale**: el router queda thin (solo validación Pydantic + inyección de dependencias), el service encapsula toda la lógica de autorización y negocio — fácil de testear unitariamente con mocks.

---

### Decisión 3 — Los RPCs PostgreSQL existentes NO se reescriben

**Elegido**: los repositories concretos llaman a los mismos RPCs atómicos (`rpc_create_operation_aggregate`, `rpc_transfer_stock`, etc.) que ya usa el frontend.

**Alternativa descartada**: reescribir las operaciones atómicas en Python con `asyncpg` transacciones. Introduce riesgo de regresión sin beneficio en C-16; puede hacerse en un change separado si la trazabilidad lo justifica.

**Rationale**: los RPCs son el activo más sólido del stack (atómicos, testeados en producción, con idempotencia integrada). Envolverlos en Python es suficiente para C-16.

---

### Decisión 4 — Sub-etapas ordenadas por riesgo de datos

**Elegido**: `expenses`/`clients` primero (sin RPCs complejos), luego `products`/`branches`/`stock` (con `rpc_transfer_stock`), luego `sales`/`purchases` (con `rpc_create_operation_aggregate` y contadores de plan).

**Rationale**: si la sub-etapa 1 revela problemas de latencia o auth, se detiene antes de tocar los dominios financieros críticos. Cada sub-etapa se activa independientemente por el feature flag.

---

### Decisión 5 — `require_plan` verifica contra `plan_limits` en Redis

**Elegido**: el service llama a `get_auth_context()` (de C-15) que ya resuelve org + rol + plan. Para límites de plan, consulta `plan_limits` cacheado en Redis/Upstash.

**Rationale**: evita un round-trip a PostgreSQL por request en los guards de plan. `plan_limits` es una tabla de configuración estática — cache de 5 min es seguro.

## Risks / Trade-offs

| Riesgo | Mitigación |
|--------|-----------|
| Cold start Render (~50s) degrada UX en primera request | Cron gratuito que pinguea `/health` cada 10 min; flag desactivado en prod hasta que Render esté warm |
| Latencia p95 regresión por salto de red extra (browser → Next.js → FastAPI) | Benchmark por sub-etapa con `pytest-asyncio` + `httpx`; umbral: p95 ≤ actual + 50ms; si falla, revertir |
| Bug en guards → acceso cross-org | Defense-in-depth: FastAPI guard (org_id) + RLS PostgreSQL (última línea); prueba explícita cross-org en tests |
| Feature flag olvidado en `true` indefinidamente | Checklist de C-18 incluye apagar el flag y borrar el código legacy |
| asyncpg type mismatch en columnas NUMERIC(15,4) | Tests de integración con datos reales de stock fraccionario antes de activar sub-etapa 2 |

## Migration Plan

1. **Deploy backend C-15** con `NEXT_PUBLIC_USE_PYTHON_API=false` (flag desactivado) — sin impacto en prod
2. **Sub-etapa 1** (expenses + clients):
   - Implementar routers, services, repositories
   - Tests verdes; benchmark p95 OK
   - Activar flag en staging → validar 48h → activar en prod
3. **Sub-etapa 2** (products + branches + stock):
   - Mismo ciclo; validar idempotencia y stock fraccionario explícitamente
4. **Sub-etapa 3** (sales + purchases + organizations):
   - Mismo ciclo; validar counters de plan pre-insert y `idempotency_key`
   - Comparar respuestas del endpoint nuevo vs. antiguo con datos reales
5. **C-18** elimina el `DataContext`, los feature flags, y las Edge Functions de datos migradas

**Rollback**: setear `NEXT_PUBLIC_USE_PYTHON_API=false` en Vercel → redeploy (< 1 min).

## Open Questions

- ¿El `DataContext` puede consumir un `BACKEND_URL` de entorno directamente, o debe proxearse vía Next.js API Route para no exponer el backend Render al browser? (Recomendación: proxy en `/api/backend/[...path]` si el backend no tiene CORS configurado para el dominio de Vercel)
- ¿Los endpoints de `organizations` en sub-etapa 3 cubren solo lectura, o también la creación/edición de org (governance CRITICO, requiere confirmación explícita)?
