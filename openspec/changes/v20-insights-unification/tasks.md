> **Nota de apply (2026-06-13):** el diagnóstico read-only en prod confirmó un **bug activo**: desde que C-19 puso la RLS account-based (~6 jun), los 4 EF que insertan directo SIN `account_id` fallan en silencio (`ai_insights` sin filas nuevas desde 5 jun); los insights del RPC van a la tabla legacy, invisibles. **Decisión de diseño:** un trigger `BEFORE INSERT` que deriva `account_id` arregla los EF rotos sin tocarlos, y la **vista de compatibilidad** mantiene el código viejo funcionando. → **Este PR es SOLO la migración** (arregla el bug + unifica con cero cambios de código). El repunte de EF/frontend + drop de la vista/backup van en el **PR de limpieza** posterior.

## 0. Red de seguridad y baseline

- [x] 0.1 Baseline prod (`gxdhpxvdjjkmxhdkkwyb`): `ai_insights`=726 (0 NULL, última 5-jun, 0 en 7d → roto), `insights` legacy=462 (+45/7d, última 14-jun → activo), legacy sin membership=7, sin triggers/default de `account_id`
- [x] 0.2 OQs resueltas con el PO: OQ1 `priority='media'`, OQ2 `account_id NULL` tolerado (corregido: RLS es account-based, no user_id), OQ3 limpieza en PR aparte
- [ ] 0.3 (PR limpieza) Confirmar suite frontend verde tras repuntar a `insights`

## 1. Migración de datos y esquema (SQL) — `20260629000001_unify_insights.sql`

- [x] 1.1 RED: aserciones pre-migración (sin backup, sin trigger, `insights` con col `content`) — verificadas en local
- [x] 1.2 Backfill `INSERT INTO ai_insights ... SELECT ... FROM insights` con mapeo (`content→message`, `account_id` por subquery a `account_members`, `priority='media'`, `id`/`created_at` preservados), `ON CONFLICT (id) DO NOTHING`
- [x] 1.3 `ALTER TABLE insights RENAME TO insights_legacy_backup` (guard de existencia)
- [x] 1.4 `ALTER TABLE ai_insights RENAME TO insights` + `GRANT` explícito a `authenticated` (el rename no preserva el ACL de forma confiable)
- [x] 1.5 `CREATE VIEW ai_insights WITH (security_invoker = true) AS SELECT * FROM insights` (compatibilidad; `security_invoker` p/que respete la RLS)
- [x] 1.6 GREEN: migración aplicada en local + aplica en cadena vía `supabase db reset` sin errores
- [x] 1.7 TRIANGULATE: conteo migrado == legacy, `id`/`user_id`/`created_at` preservados, `account_id NULL` = 1 (la fila del user sin membership, esperado)

## 2. Trigger + rewrite del RPC

- [x] 2.1 RED: test de que un insert sin `account_id` (camino de los 4 EF rotos) lo autorrellene — falla sin el trigger
- [x] 2.2 Trigger `trg_set_insight_account_id` BEFORE INSERT en `insights`: deriva `account_id` del membership cuando viene NULL (arregla los 4 EF + cubre RPC y futuros)
- [x] 2.3 Rewrite `rpc_atomic_log_ai_insight`: inserta en `insights` (esquema canónico), misma firma y forma de retorno; preserva lock de `profiles`, `insights_used`, telemetría y UMV
- [x] 2.4 GREEN/TRIANGULATE: RPC inserta canónico con `account_id` derivado + incrementa `insights_used` en exactamente 1 (verificado). Límite de plan free: lógica preservada byte-a-byte del RPC original (sin cambios)

## 3. Validación local (TDD)

- [x] 3.1 5/5 aserciones verdes: schema unificado · backfill con mapeo · trigger autorrellena `account_id` · RLS account-based + vista `security_invoker` honran scoping (u1 ve sus filas, NO la de u2 NULL) · RPC canónico + contador

## 4. Cierre de este PR (solo migración)

- [ ] 4.1 PR feature branch → `main` con la migración + artefactos OpenSpec; CI verde (`gh pr checks`)
- [ ] 4.2 **GATE PO**: aplicar a prod con `npx supabase db push` (NUNCA MCP `apply_migration`). Toca datos reales + contador → requiere OK explícito del PO
- [ ] 4.3 Post-push: validar en prod que `insights` recibe filas nuevas (los EF vuelven a funcionar) y conteos vs baseline 0.1

## 5. PR de limpieza (posterior, tras validar en prod — OQ3)

- [ ] 5.1 Repuntar `ai_insights → insights` en los 4 EF (`ai-insights`, `ai-precio`, `ai-rentabilidad`, `ai-comparativo`) y en frontend (`use-insights`, `aiInsightService`, páginas dashboard/insights/comparativo/rentabilidad)
- [ ] 5.2 Regenerar `frontend/lib/database.types.ts` + typecheck + suite frontend verde
- [ ] 5.3 Redeploy de las 7 Edge Functions; smoke test
- [ ] 5.4 Migración `<ts>_cleanup_insights_legacy.sql`: `DROP VIEW ai_insights` + `DROP TABLE insights_legacy_backup`
- [ ] 5.5 Grep final: 0 referencias a `ai_insights` en `frontend/` y `supabase/functions/`

## 6. Archive

- [ ] 6.1 `/opsx:archive v20-insights-unification` — sync spec `insights` a `openspec/specs/`, `[x]` C-24 en `CHANGES.md`, Fase 6 → 6/7
