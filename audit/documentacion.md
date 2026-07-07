# Auditoría Técnica Pre-Producción — Dimensión DOCUMENTACIÓN
Proyecto: ALIADATA / EmprendeSmart (EIE) · Consultora de software · Rol: Technical Documentation Auditor
Alcance: coherencia knowledge-base ↔ código/DB real, vigencia modelo V2/V3, exactitud CHANGES.md, calidad de openspec/specs, README/AGENTS/CLAUDE, UML/diagramas, docs/, preguntas abiertas.
Modo: SOLO LECTURA. Verificación cruzada contra DB de PRODUCCIÓN (`gxdhpxvdjjkmxhdkkwyb`) vía MCP, `openspec validate --specs --strict`, y estructura real del repo.

---

## 0. Método y evidencia recolectada

- **DB real (prod)**: 68 tablas en `public` (verificado por `information_schema.tables`). KB 04 admite documentar un "subconjunto principal" y cita "55 tablas"; el número real es 68 y el README de la KB dice "23+ tablas".
- **RBAC real**: `account_members.role` CHECK = `('owner','admin','member')` (verificado). Sin roles funcionales (SELLER/CASHIER/...). Confirma K9.
- **RPCs hot path**: `rpc_create_sale_operation` escribe `sale_items` = TRUE; `rpc_create_purchase_operation` escribe `purchase_items` = FALSE (verificado con `pg_get_functiondef`). Confirma K8 (compras siguen flat).
- **profiles real**: columnas `plan` (tipo USER-DEFINED = ENUM), `billing_plan`, `trial_plan`, `ai_queries_used`, `ai_advice_used`, `usage_reset_at`, `insights_used`, `insights_reset_at` coexisten. KB 03/04 solo documentan `plan TEXT free|pro` + `insights_used`.
- **openspec strict**: 15/62 specs fallan (`ai-price-suggestion, ai-usage-counters, backend-auth, client-fiscal-identity, community-schema, data-api-endpoints, data-export, idle-session-server-enforcement, idle-session-timeout, insights, payment-webhook, plan-gating, python-backend, realtime-websocket, sales-channel`). Causa: falta `## Purpose` / `## Requirements` (formato legacy). Confirma K6 exacto (15).
- **Estructura repo**: monorepo real `frontend/` + `backend/`. `app/`, `components/`, `lib/`, `hooks/`, `contexts/` YA NO están en la raíz (movidos a `frontend/`).
- **Edge Functions**: 11 funciones + `_shared` en `supabase/functions/` (ai-comparativo, ai-insights, ai-precio, ai-prediccion, ai-rentabilidad, ai-resumen, ai-simulador, fair-advisor, generate-export, invoice-ocr, send-email). KB 02 dice "10 Edge Functions".
- **Migraciones**: 204 archivos en `supabase/migrations/`. KB 02 dice "~60+ migraciones".
- **Decisiones**: KB 09 tiene DEC-01..24 (24). AGENTS.md dice "15 decisiones", KB README dice "11 decisiones".
- **Reglas de negocio**: 50 códigos RN únicos, numeración hasta RN-100. CLAUDE.md/AGENTS.md/KB-README dicen "33 reglas".
- **Backend payments**: `backend/routers/payments.py` + `backend/services/payments.py` existen (MercadoPago). README dice "No implementar pasarela de pagos en el MVP".

---

## 1. Dictamen por documento de la Knowledge Base

| Doc | Dictamen | Evidencia principal |
|---|---|---|
| 01_vision_y_objetivos | **VIGENTE** | Visión/UMV/KPIs estables. Resuelve el naming (EmprendeSmart=producto, ALIADATA=branding email) — bien. |
| 02_descripcion_general | **PARCIALMENTE DESACTUALIZADO (grave)** | (a) Diagrama de arquitectura (l.60-77) muestra SOLO el modelo Supabase-directo, sin la capa FastAPI que está en prod. (b) "Realtime (Supabase): No usado en MVP actual" (l.33) — falso desde 2026-07-04 (`useNotifications`/`NotificationBell`). (c) Estructura de directorios (l.128-170) con `app/`,`components/`,`lib/` en raíz — ya migrado a `frontend/`. (d) "10 Edge Functions" (real 11). (e) "~60+ migraciones" (real 204). |
| 03_actores_y_roles | **PARCIALMENTE DESACTUALIZADO** | `plan TEXT free|pro` (l.59-62) — hoy `plan` es ENUM y hay `billing_plan`/`trial_plan`. RBAC real por `account_members(owner/admin/member)` no está reflejado (la tabla de la KB es free/pro/admin). RLS "Resumen por tabla" documenta ~19 tablas de 68; no menciona accounts, branches, cash, bancos, fiscales. Roles funcionales V3 (§5) inexistentes en DB (K9). |
| 04_modelo_de_datos | **PARCIALMENTE DESACTUALIZADO (grave)** | Documenta ~25 tablas de 68; el propio doc cita "55 tablas". Bloque `profiles` (l.66-79) sin `billing_plan/trial_plan/ai_queries_used/ai_advice_used/usage_reset_at`. `sales`/`purchases` documentadas planas como estructura vigente (aunque hay notas de retirada). ERD (l.469-514) es ASCII rooteado en `auth.users`/`user_id` = modelo de tenancy RETIRADO; no refleja `accounts` como raíz. Mérito: incluye tablas nuevas (client_addresses, units_of_measure) con detalle correcto y notas de deprecación (min_stock, stock). |
| 05_reglas_de_negocio | **PARCIALMENTE DESACTUALIZADO** | RN-05 (l.49-54) habla en futuro de "separar insights_used en ai_queries_used/ai_advice_used" — ya hecho (columnas existen). Buenas notas de estado ("previa a las Fases..."). RN-97 real (bloque 90s). Numeración RN sube a RN-100 (no "33"). |
| 06_funcionalidades | **VIGENTE con disclaimers** | Tabla "Estado por Módulo" (l.200-220) es pre-Fases 1-5 pero lo dice explícitamente (l.220) — buena práctica. Épica 3 mantiene "estado activo/inactivo/perdido" que KB04 marca como no-confirmado en DB. |
| 07_flujos_principales | **VIGENTE (base)** | 9 flujos E2E en ASCII (18 code blocks). Sin diagramas mermaid de secuencia; los flujos no incorporan el paso FastAPI ni la FSM/outbox V3, pero describen el comportamiento de negocio correctamente. |
| 08_arquitectura_propuesta | **PARCIALMENTE DESACTUALIZADO** | Sección "Evolución Arquitectónica: Backend Python/FastAPI" (l.236+) es BUENA y documenta el modelo híbrido y DEC-16. PERO la etiqueta "parcialmente implementado / Lo pendiente (FASE 5): capa de datos, migración de API, pagos" contradice a CHANGES.md, que marca C-15..C-18 (Fase 5) ✅ y el backend está en prod con 24 routers/33 services/27 repos. El patrón de cabecera sigue siendo "BaaS + Edge-First". |
| 09_decisiones_y_supuestos | **VIGENTE** | DEC-01..24 presentes (incluye DEC-16 realtime, DEC-24 UoW). Actualizado 2026-07-06. Es el doc mejor mantenido de la KB. |
| 10_preguntas_abiertas | **PARCIALMENTE DESACTUALIZADO** | PA-23/INC-03 (naming ALIADATA vs EmprendeSmart) listada como abierta, pero KB 01 ya la resuelve → inconsistencia interna. INC-01 (plan default) obsoleta (plan es ENUM). PA-11 "¿hay tests?" obsoleta (1023 backend + 443 frontend). PA-06 roles resuelto conceptualmente en V3 §5. |
| README (de la KB) | **OBSOLETO** | "23+ tablas" (68), "Roles user/admin, planes free/pro" (4 planes + enum), "11 decisiones" (24), "15 preguntas abiertas" (23). Es el índice meta más desactualizado. |

---

## 2. Vigencia del modelo de dominio V2/V3 y % de retrofit

- **V2 (`modelo-dominio-aliadata-v2.md`)**: VIGENTE como fuente de la Fase 6-7. 6 diagramas mermaid. Bien referenciado desde CLAUDE.md.
- **V3 (`modelo-dominio-aliadata-v3.md`)**: VIGENTE y de alta calidad (18 decisiones tabuladas, adopta/adapta/rechaza explícitamente, 5 mermaid). Retrofit real muy avanzado — capabilities presentes en `openspec/specs/`:
  - §1 Snapshots → `document-snapshots` ✅
  - §2 FSM+historial → `document-status-history` ✅
  - §3 Notificaciones realtime → `in-app-notifications` + `realtime-websocket` ✅
  - §4 Soft delete → `soft-delete-policy` ✅
  - §7.3 Direcciones → `client-addresses` ✅
  - §7.1 UoM tipada → `units-of-measure` ✅
  - §8 Reporting RN-D → `reporting-invariants` ✅
  - §9 Estándares API → `api-standards` ✅
  - Estimación: ~8/10 patrones adoptables ya retrofiteados (≈80%). Pendientes: §5 RBAC multi-rol (`v3-rbac-multirole` CRÍTICO, sin empezar — DB sigue owner/admin/member, K9), §7.2 composición/BOM (V3.5).
- **DIVERGENCIA V3**: §7.4 "Imágenes de producto" está listada como decisión #12 **✅ Adoptar vía Supabase Storage** y en el roadmap V2.5 (§11), pero el PO DESCARTÓ `producto-imagenes` el 2026-07-04 (memoria de sesión: "no volver a proponerlo"). El doc V3 conserva un patrón adoptado que fue posteriormente rechazado → riesgo de que un agente lo re-proponga.

---

## 3. Exactitud de CHANGES.md

- **ALTA en general**: C-01..C-30 correctamente marcados; el roadmap V3 post-roadmap refleja el estado real (snapshots, FSM, notifs, soft-delete, provisioning, catalog-masters, reporting-invariants, api-standards ✅).
- **Riesgo de precisión K8**: CHANGES.md/CLAUDE.md afirman que `v3-snapshot-pattern` "Desbloquea C-20 Grupo 10 (línea de servicio)" y que ventas escriben snapshots, pero `rpc_create_purchase_operation` NO escribe `purchase_items` (verificado) y hay un feature flag `sale_items_rpc_v2` sin activar en 3/29 cuentas (K4). El header plano de compras (RN-97) sigue vivo. La doc no advierte claramente que COMPRAS quedó atrás respecto a VENTAS.

---

## 4. README raíz — NO sirve para onboarding

`README.md` (fechado Apr 25, pre-todo) es un **entregable académico** ("Entrega Final: Documentación del Producto", modelo AARRR, checklist de consigna), no un README de repo:
- Cero instrucciones de setup/install/run, variables de entorno, cómo levantar `frontend/` o `backend/`, cómo correr tests o migraciones.
- Afirma "Freemium con gating server-side **sin billing real**" y "Decisión: **No implementar pasarela de pagos en el MVP**" — contradice `backend/routers/payments.py` + `backend/services/payments.py` (MercadoPago) y C-17 backend-payments-migration ✅.
- No menciona el backend Python, el monorepo, ni el modelo V2/V3.
- Un dev nuevo no puede arrancar el proyecto con este README. **Es el hallazgo de mayor impacto operativo de la dimensión.**

---

## 5. AGENTS.md vs CLAUDE.md — dos fuentes divergentes

Coexisten dos ficheros de instrucciones de agente que ya NO coinciden:
- **CLAUDE.md** (Jul 6): CURRENTE — V3 completo, DEC-24, v3-* changes, backend en prod.
- **AGENTS.md** (Jun 12): STALE ~4 semanas — se detiene en Fase 6 V2; NO menciona el modelo V3; l.149 "Backend Python / FastAPI (Fase 5 — planificado)" (Fase 5 ✅ en prod); l.95 "Fases 1-5 completadas... Fase 6 es el trabajo activo"; referencia solo `modelo-dominio-aliadata-v2.md`, no v3; "15 decisiones" (24). Riesgo: un agente/herramienta que lea AGENTS.md (convención estándar) opera con un mapa mental obsoleto.

---

## 6. Diagramas / UML

- KB 04: SIN ERD mermaid; solo ASCII rooteado en el modelo de tenancy RETIRADO (`auth.users`/`user_id`). No hay ERD de `accounts`/branches/finanzas/fiscales.
- KB 07: flujos en ASCII, sin diagramas de secuencia mermaid; no incorporan FastAPI/outbox/FSM.
- V2/V3: 6 + 5 mermaid class diagrams de buena calidad (único lugar con UML real).
- Recomendación: un ERD mermaid actualizado (accounts como raíz, módulos financieros) elevaría KB 04 de "parcial" a "vigente".

---

## 7. Verificación de known issues (área documentación)

| ID | Estado | Nota |
|---|---|---|
| K6 | CONFIRMADO | Exactamente 15/62 specs fallan strict (falta `## Purpose`/`## Requirements`). |
| K8 | CONFIRMADO | `rpc_create_purchase_operation` NO escribe `purchase_items` (flat); `rpc_create_sale_operation` sí escribe `sale_items`. Header plano RN-97 vivo. |
| K9 | CONFIRMADO | `account_members.role` CHECK = owner/admin/member; sin roles funcionales; V3 §5 documenta roles inexistentes en DB. |
| K11 | CONFIRMADO (doc) | KB 04 (l.203,217) documenta el enum real `unit|weight|volume|length|custom` y marca OQ1 (rename V3 peso|volumen|contable no ejecutado). Doc coherente con la divergencia. |
| K7 | CONFIRMADO (doc) | KB 04 (l.93) marca `products.min_stock` DEPRECATED y apunta a `branch_stock.min_stock`. Bien documentado. |
| K4 | NO_EVALUADO (impacto doc) | Flag `sale_items_rpc_v2` sin activar en 3/29 — la doc de CHANGES no lo advierte al lado de la afirmación "ventas escriben snapshots". |
| K1,K2,K3,K5,K10,K12-K20 | NO_EVALUADO | Fuera del foco de la dimensión documentación (código/DB/infra). |

---

## 8. Anomalía de repo-higiene

- Directorio `undefined/` versionado (untracked) en la raíz, conteniendo `undefined/audit/`. Es el resultado de un placeholder de path (`${var}` no resuelto → literal "undefined"), el mismo patrón que aparece en el propio prompt de esta auditoría (`undefined/audit/documentacion.md`, fecha "undefined"). Debe consolidarse el destino de outputs de auditoría en `audit/` (que ya existe) y removerse `undefined/`.

---

## 9. Fortalezas (reconocimiento)

1. **KB 09 (decisiones)** y **modelo V3**: documentación de arquitectura de calidad profesional — decisiones trazables, adopciones/rechazos explícitos, referencias cruzadas, mermaid.
2. **openspec/specs como fuente de verdad**: 62 capabilities, 47 en formato estricto correcto; cobertura de comportamiento amplia y sincronizada con archives.
3. **docs/ejemplos/README.md**: ejemplar — consciente de seguridad (PII, .gitignore), referencia el archivo real (`frontend/lib/receipt.ts`), datos ficticios.
4. **Disciplina de disclaimers de estado**: KB 05 y KB 06 marcan explícitamente qué tablas están "en transición" o "previas a las Fases X" en lugar de mentir en silencio — mitiga el riesgo de las secciones stale.
5. **CLAUDE.md**: instrucciones de agente muy completas, reglas duras específicas del proyecto, routing de skills, roadmap sincronizado al día.
6. **Trazabilidad de preguntas abiertas**: PA-16..22 resueltas con fecha y decisión del PO documentada.

---

## 10. Clasificación del área

**BUENA.** La documentación de decisiones/arquitectura-objetivo (V2/V3, DEC, specs, CLAUDE.md) es de calidad alta y está viva. Pero la capa "descriptiva del sistema actual" (KB 02/03/04 + su README + README raíz + AGENTS.md) arrastra un desfase estructural respecto a la realidad de prod (68 tablas vs 23-55 documentadas, plan enum vs free/pro, monorepo vs app-en-raíz, backend en prod descrito como "planificado", Realtime "no usado" ya en uso). No hay errores que pongan plata/datos en riesgo directo desde la doc, pero el onboarding real está roto (README raíz) y hay dos fuentes de instrucción divergentes (AGENTS vs CLAUDE) que pueden inducir a agentes a operar sobre supuestos obsoletos. Con una pasada de actualización de KB 02/03/04 + reescritura del README raíz + unificación AGENTS/CLAUDE, el área pasa a "Muy buena".
