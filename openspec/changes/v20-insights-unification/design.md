## Context

Los insights se generan en Supabase Edge Functions (DEC-15 — IA/OCR no migran a Python) y se persisten en **dos tablas divergentes**:

| | Tabla | Columnas relevantes | Writers | Reader frontend |
|---|---|---|---|---|
| Canónica | `ai_insights` | `id, user_id, account_id, type, priority(alta/media/baja), message, created_at` | EF directas: `ai-insights`, `ai-precio`, `ai-rentabilidad`, `ai-comparativo` | ✅ sí (`use-insights`, `aiInsightService`) |
| Legacy | `insights` | `id, user_id, type(general/prediction/simulation), content, actionable(text), created_at` | RPC `rpc_atomic_log_ai_insight`, llamado por `ai-prediccion`, `ai-resumen`, `ai-simulador` | ❌ no |

**Estado actual / bug**: el frontend lee solo `ai_insights`. Los insights escritos vía el RPC en `insights` legacy son invisibles para el usuario. La tabla legacy no tiene `account_id` (queda fuera del scoping multi-tenant de C-19). El modelo V2 (DEC-21) define un único `Insight`.

**Bug de producción CONFIRMADO (diagnóstico read-only 2026-06-13):** `ai_insights` tiene 726 filas pero **0 en los últimos 7 días** (última: 5-jun); `insights` legacy tiene 462 filas y **+45 en 7 días** (última: 14-jun). Causa: desde que C-19 puso la RLS account-based (~6-jun), los 4 EF que insertan directo SIN `account_id` fallan el `WITH CHECK (account_id IN current_account_ids())` y **tragan el error** → no se guarda nada en `ai_insights` desde el 6-jun. Los del RPC sí se guardan (en legacy) pero el frontend no los lee. **Neto: los usuarios no ven insights nuevos hace más de una semana.** C-24 corrige el incidente.

**Constraints**: RN-97 (ninguna feature nueva sobre tablas en retirada — este change solo retira deuda). Migraciones a producción siempre vía `npx supabase db push` (proyecto real `gxdhpxvdjjkmxhdkkwyb`), nunca MCP `apply_migration`. RLS org-based debe seguir activa.

## Goals / Non-Goals

**Goals:**
- Una sola tabla canónica de insights, escrita por los 7 caminos de IA y leída por el frontend.
- Migrar las filas legacy sin pérdida (preservar `user_id`, `created_at`, contenido).
- Que los insights de predicción/resumen/simulador pasen a ser visibles para el usuario.
- Nombre definitivo `insights` (alineado a V2), con `account_id` poblado.
- Migración idempotente y con camino de rollback para datos de producción.

**Non-Goals:**
- No se migra IA/OCR a Python (DEC-15) — los insights siguen en Edge Functions.
- No se crean nuevos tipos de insight, ni UI nueva, ni se rediseña el render.
- No se tocan otros dominios de IA (`AIConversation`, OCR) — solo `Insight` (alcance de DEC-21 para este change).
- No se cambia la lógica de gating de plan; solo se **preserva** el contador `profiles.insights_used`.

## Decisions

### D1 — Opción A: renombrar `ai_insights → insights` (no tabla transitoria)
Decisión del PO (2026-06-10). `ai_insights` es la base por tener el esquema más completo (`message`/`priority`/`account_id`). Se descarta mantener el nombre `ai_insights` porque el modelo V2 nombra el dominio `Insight`/`insights`.

### D2 — Dirección de migración: legacy → canónica, antes del rename
Se insertan las filas de `insights` legacy dentro de `ai_insights` con mapeo, **antes** de renombrar. Mapeo:

| Canónica (`ai_insights`) | Origen legacy (`insights`) |
|---|---|
| `id` | `id` (se preserva el uuid; `ON CONFLICT (id) DO NOTHING` para idempotencia) |
| `user_id` | `user_id` |
| `account_id` | derivado: `LEFT JOIN account_members ON user_id` → `account_id` |
| `type` | `type` tal cual (campo libre; sin pérdida) |
| `message` | `content` |
| `priority` | `'media'` (constante — ver D3) |
| `created_at` | `created_at` |

### D3 — `priority` de las filas migradas = `'media'`
El `actionable` legacy es `text` y el RPC siempre escribía la constante `'actionable_extracted_from_content'` (nunca un booleano), así que no hay señal real de prioridad. Mapear "actionable→alta" inundaría de `'alta'`. Se asigna `'media'` (vocabulario canónico `InsightPriority = alta|media|baja`). Alternativa descartada: derivar de `actionable` (señal no confiable).

### D4 — Rewrite del RPC `rpc_atomic_log_ai_insight`
Tras el rename, el RPC se reescribe para `INSERT INTO insights (user_id, account_id, type, message, priority)` con `message = p_content`, `priority = 'media'`, `account_id` derivado de `auth.uid()` vía `account_members`. **Preserva** el lock de `profiles`, el incremento de `insights_used`, la telemetría (`analytics_events`) y la detección de UMV, y devuelve la misma forma `jsonb` que consumen `ai-prediccion`/`ai-resumen`/`ai-simulador` (no cambia la firma ni el call site). Alternativa descartada: que esas 3 EF inserten directo — rompería la atomicidad gating+telemetría que hoy centraliza el RPC.

### D5 — `account_id` derivado por membership (la RLS es account-based)
**Corrección (descubierta en apply):** la tabla canónica NO tiene policy de SELECT por `user_id`. C-19 (`20260606000004_rls_tenant_scoping.sql`) reemplazó las policies por **account-based**: `SELECT USING (account_id IN (SELECT current_account_ids()))`. Por lo tanto una fila con `account_id NULL` es **invisible** para el usuario.

Implicancias:
- El `account_id` debe derivarse SIEMPRE (en la migración y en el RPC) vía el membership del usuario. Como se deriva de la propia cuenta del usuario, el `account_id` resultante está en `current_account_ids()` → la fila es visible.
- El INSERT del RPC es `SECURITY DEFINER` (corre como owner, bypassa RLS), así que el insert no falla con NULL — pero la fila resultante no sería SELECTable. Por eso el RPC también deriva `account_id`.
- Filas legacy de usuarios **sin** membership: se migran con `account_id NULL` y permanecen invisibles — esto **no es regresión** (ya eran invisibles en la tabla legacy) y, post-C-19, todo usuario activo tiene membership. El baseline (tarea 0.1) cuantifica cuántas filas caen en este caso; si es no-trivial, se revisa con el PO.

### D7 — Trigger `BEFORE INSERT` que deriva `account_id` (arregla el bug sin tocar los EF)
Se agrega un trigger en la tabla canónica que, cuando `account_id` viene NULL, lo deriva del membership del usuario (`account_members`). Esto **arregla los 4 EF rotos sin modificarlos** (siguen insertando sin `account_id`, el trigger lo completa → pasa el `WITH CHECK`), y cubre el RPC y futuros writers (DRY). Como el `account_id` derivado es del propio usuario, está en `current_account_ids()` → la fila queda visible. **Consecuencia clave:** combinado con la vista de compatibilidad (D6), **la migración SOLA arregla el bug y unifica con CERO cambios de código** → el PR principal es solo la migración; el repunte de EF/frontend se difiere al PR de limpieza. Alternativa descartada: editar los 4 EF para que seteen `account_id` (más superficie de cambio + redeploy de 7 EF en el PR principal).

### D6 — Seguridad de deploy: backup + vista de compatibilidad
- En vez de `DROP TABLE insights` directo, se renombra la legacy a `insights_legacy_backup` (libera el nombre y preserva datos para rollback). Su drop va en una **migración de limpieza posterior**, tras validar en prod.
- Tras `ALTER TABLE ai_insights RENAME TO insights`, se crea una **vista de compatibilidad** `ai_insights AS SELECT * FROM insights` (auto-actualizable, 1:1) para que cualquier Edge Function/cliente aún desplegado contra `ai_insights` siga funcionando hasta el redeploy. La vista se elimina en la migración de limpieza.

## Risks / Trade-offs

- **[Pérdida de datos al derivar `account_id`]** → `LEFT JOIN` + se conserva `user_id`; RLS funciona por `user_id`. Verificar `COUNT(*)` legacy == filas migradas y reportar NULLs.
- **[Edge Functions/clientes viejos rompen tras el rename]** → vista de compatibilidad `ai_insights`; redeploy de las 7 EF dentro del change; drop de la vista recién en la limpieza.
- **[Rollback de una tabla dropeada]** → no se dropea en el mismo PR; `insights_legacy_backup` permite revertir.
- **[Re-ejecución de la migración]** → `ON CONFLICT (id) DO NOTHING`, `IF EXISTS`/`IF NOT EXISTS`, rename condicionado a existencia → idempotente.
- **[Regresión del contador de plan]** → el rewrite del RPC mantiene `insights_used`; cubierto por test.
- **[`database.types.ts` desincronizado]** → regenerar tipos tras el rename; CI de tipos del frontend lo detecta.
- **[`priority='media'` para todo lo legacy]** → trade-off aceptado: las filas legacy no tenían prioridad real (D3).

## Migration Plan

Migración SQL principal (transaccional, idempotente), aplicada con `npx supabase db push`:
1. `INSERT INTO ai_insights (...)` `SELECT` con mapeo D2 desde `insights` legacy, `ON CONFLICT (id) DO NOTHING`.
2. `ALTER TABLE insights RENAME TO insights_legacy_backup` (libera el nombre, conserva datos).
3. `ALTER TABLE ai_insights RENAME TO insights` (RLS policies + índices viajan con el rename).
4. `CREATE OR REPLACE FUNCTION rpc_atomic_log_ai_insight(...)` apuntando a `insights` con esquema canónico (D4).
5. `CREATE VIEW ai_insights AS SELECT * FROM insights` (compatibilidad transitoria, D6).

Deploy de código (mismo change): repuntar las 7 EF + frontend a `insights`, regenerar `database.types.ts`, redeploy de Edge Functions.

Migración de limpieza (posterior, tras validar en prod): `DROP VIEW ai_insights`; `DROP TABLE insights_legacy_backup`.

**Rollback**: antes de la limpieza, revertir = restaurar desde `insights_legacy_backup` y volver el código al nombre `ai_insights` (la vista de compatibilidad ya lo cubre en runtime).

## Open Questions (RESUELTAS — PO 2026-06-13)

- **OQ1** — ✅ **RESUELTA**: `priority = 'media'` para las filas migradas (D3 confirmado).
- **OQ2** — ⚠️ **RE-RESUELTA (corrección durante apply)**: la premisa original ("NULL visible vía user_id") era falsa — la RLS canónica es account-based (D5). Decisión corregida: derivar `account_id` SIEMPRE; las filas de usuarios sin membership se migran con NULL pero quedan invisibles (sin regresión). La migración **no bloquea** pero **reporta** el conteo de NULLs; si es no-trivial, se revisa con el PO antes del push a producción.
- **OQ3** — ✅ **RESUELTA**: la limpieza (`DROP VIEW ai_insights` + `DROP TABLE insights_legacy_backup`) va en un **PR/migración aparte**, tras validar en producción (más seguro para datos reales). El grupo 6 de `tasks.md` queda fuera del PR principal de este change.
