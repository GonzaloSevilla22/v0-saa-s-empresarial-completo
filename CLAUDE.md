# EmprendeSmart (EIE) — Instrucciones para Agentes

> SaaS para microemprendedores de Mendoza: gestión financiera (ventas/compras/gastos/stock) + IA accionable.  
> MVP en producción con usuarios reales — Junio 2026.

---

## Stack Tecnológico

| Capa | Tecnología | Versión |
|------|------------|---------|
| **Framework** | Next.js (App Router) | 16.1.6 |
| **UI** | React + TypeScript | 19.2.3 / 5.7.3 |
| **Estilos** | Tailwind CSS + shadcn/ui + Radix UI | 3.4.x |
| **Estado global** | Zustand | 5.x |
| **Server state / cache** | TanStack React Query | 5.x |
| **Formularios** | React Hook Form + Zod | — |
| **Gráficos** | Recharts + D3.js | — |
| **BaaS** | Supabase (Auth, DB, Edge Functions, Storage) | — |
| **DB** | PostgreSQL (via Supabase) con RLS | — |
| **Edge Functions** | Deno (Supabase) | — |
| **IA** | OpenAI API (`gpt-4o-mini`) | — |
| **Email** | Resend (via Edge Function + DB Webhook) | — |
| **Deploy** | Vercel (frontend) | — |
| **Package manager** | pnpm | 10.33.4 |

### Backend Python (NUEVO — planificado, CHANGES.md C-15+)

> Backend que convive con el frontend Next.js en un **modelo híbrido**: el frontend consume FastAPI para datos (mutaciones + lecturas) y sigue hablando directo con Supabase para Realtime, Auth y Storage. Ver `knowledge-base/08_arquitectura_propuesta.md` §"Evolución Arquitectónica: Backend Python/FastAPI".

| Capa | Tecnología | Notas |
|------|------------|-------|
| **Framework API** | FastAPI + Pydantic v2 | Arquitectura 3 capas: routers → services → repositories |
| **DB driver** | asyncpg | Pool con JWT-passthrough (RLS org-based activa) |
| **Cache / rate-limit** | Redis (Upstash free) | — |
| **Testing** | pytest + pytest-asyncio | Coverage mínimo en CI |
| **Deploy backend** | Render (free tier) | Cold start ~50s; mitigable con ping a `/health` |

---

## Base de Conocimiento

Leé estos archivos antes de cualquier change. Son la fuente de verdad del sistema.

| # | Archivo | Cuándo leerlo |
|---|---------|---------------|
| 01 | [knowledge-base/01_vision_y_objetivos.md](knowledge-base/01_vision_y_objetivos.md) | Al empezar. Define UMV, KPIs, alcance. |
| 02 | [knowledge-base/02_descripcion_general.md](knowledge-base/02_descripcion_general.md) | Stack completo, módulos, integraciones. |
| 03 | [knowledge-base/03_actores_y_roles.md](knowledge-base/03_actores_y_roles.md) | Roles, planes (4 tiers), RBAC, RLS. |
| 04 | [knowledge-base/04_modelo_de_datos.md](knowledge-base/04_modelo_de_datos.md) | 23+ tablas, tipos, triggers, ERD. |
| 05 | [knowledge-base/05_reglas_de_negocio.md](knowledge-base/05_reglas_de_negocio.md) | 33 reglas por dominio — leer SIEMPRE antes de tocar lógica. |
| 06 | [knowledge-base/06_funcionalidades.md](knowledge-base/06_funcionalidades.md) | 10 épicas + estado por módulo. |
| 07 | [knowledge-base/07_flujos_principales.md](knowledge-base/07_flujos_principales.md) | 9 flujos E2E (venta, insight, OCR, etc.). |
| 08 | [knowledge-base/08_arquitectura_propuesta.md](knowledge-base/08_arquitectura_propuesta.md) | BaaS pattern, Server/Client, seguridad. |
| 09 | [knowledge-base/09_decisiones_y_supuestos.md](knowledge-base/09_decisiones_y_supuestos.md) | 15 decisiones + 7 supuestos (incl. DEC-12..15 backend Python) — leer antes de proponer. |
| 10 | [knowledge-base/10_preguntas_abiertas.md](knowledge-base/10_preguntas_abiertas.md) | Inconsistencias conocidas — revisá antes de implementar. |
| — | [modelo-dominio-aliadata-v2.md](modelo-dominio-aliadata-v2.md) | Modelo de dominio V2 adoptado (2026-06-09). Leer antes de cualquier change V2 (C-19+), junto a `openspec/explore/2026-06-09-modelo-dominio-v2.md`. |
| — | [modelo-dominio-aliadata-v3.md](modelo-dominio-aliadata-v3.md) | **Modelo V3 adoptado (2026-07-02)** — extensión del V2 (NO lo reemplaza): snapshots, FSM+historial, notificaciones post-commit, soft delete, RBAC multi-rol, estándares de plataforma. Leer junto al V2 para todo change V2.5+/V3; los changes derivados viven en `CHANGES.md` §"Roadmap Modelo V3". |

---

## Skills Disponibles

Los compact rules de cada skill los resuelve el orquestador desde `.atl/skill-registry.md` (generado por `skill-registry`; no versionado — no está en el repo).

| Agente / Rol | Skills que carga |
|---|---|
| **Backend / DB** (migraciones, RLS, RPCs, Supabase) | `supabase`, `supabase-postgres-best-practices` |
| **Backend Python** (FastAPI, capas, Pydantic, async) | `fastapi-templates`, `python-design-patterns`, `python-testing-patterns`, `pytest-coverage` |
| **Frontend / React** (componentes, App Router, SSR, data fetching) | `vercel-react-best-practices`, `nextjs-app-router-patterns` |
| **Auth** (Supabase Auth + Next.js sessions, middleware, OAuth) | `nextjs-supabase-auth` |
| **UI / Design** (accesibilidad, Tailwind, shadcn/ui) | `web-design-guidelines` |
| **QA / Testing** (Playwright, browser testing, screenshots) | `webapp-testing` |
| **Orquestación** (OPSX, KB, roadmap, skills) | `kb-creator`, `roadmap-generator`, `find-skill`, `skill-registry`, `agent-instruction` |

### Routing de skills (cuándo activarlas)

| Situación | Skill |
|---|---|
| SQL queries, schema design, indexes, RLS | `supabase-postgres-best-practices` |
| Auth, Edge Functions, Storage, migraciones | `supabase` |
| Componentes React, Next.js pages, data fetching | `vercel-react-best-practices` |
| App Router, Server Components, Server Actions | `nextjs-app-router-patterns` |
| Sesiones Supabase, middleware, OAuth | `nextjs-supabase-auth` |
| Revisión de UI / accesibilidad / UX | `web-design-guidelines` |
| Testing local del frontend con Playwright | `webapp-testing` |
| Endpoints FastAPI, schemas Pydantic v2, `Depends` | `fastapi-templates` |
| Diseñar capas routers/services/repositories, refactor | `python-design-patterns` |
| Tests pytest, fixtures, mocking asyncpg, async | `python-testing-patterns` |
| Coverage, umbrales en CI, reportes | `pytest-coverage` |

---

## Roadmap de Changes

> Fuente: [CHANGES.md](CHANGES.md) — **roadmap numerado C-01→C-30 COMPLETO** (C-30 archivado 2026-06-20; Fases 1-7 ✅). El trabajo activo es post-roadmap: **Fase V2.5 Finanzas** (cost-center ✅, journal-entry-outbox ✅, **BankReconciliation COMPLETA: C1 ✅ + C2 ✅ + C3 ✅** 2026-07-02) + **modelo de dominio V3** adoptado 2026-07-02 (`modelo-dominio-aliadata-v3.md`, extiende al V2). **RN-97 sigue vigente** para las columnas legacy aún no dropeadas (header plano de `sales`/`purchases` hasta C-20 Grupo 10).

### Próximo change recomendado (activo)
1. ~~**`v3-snapshot-pattern`**~~ ✅ **COMPLETADA 2026-07-02** (PR #255): snapshots de nombre/SKU/costo/IVA en líneas de documentos + `FiscalIdentitySnapshot` del receptor. **Desbloquea C-20 Grupo 10** (línea de servicio = `product_id NULL` + `name_snapshot`). Specs sincronizadas a main; change archivado.
2. ~~**`v3-document-status-history`**~~ ✅ **COMPLETADA 2026-07-03** (PRs #258/#259): tabla append-only `document_status_history`, catálogo `document_status_transitions`, helpers `record_status_transition`, `allowed_role` RBAC-ready. Specs (1 nueva + 5 modificadas) sincronizadas; change archivado.
3. ~~**`v3-notifications-realtime`**~~ ✅ **COMPLETADA 2026-07-04** (PR #262) · ~~**`v3-soft-delete-policy`**~~ ✅ 2026-07-06 · ~~**`v3-provisioning-seed`**~~ ✅ 2026-07-06 (PR #279) · ~~**`v3-catalog-masters`**~~ ✅ 2026-07-06 (PR #282) · ~~**`v3-reporting-invariants`**~~ ✅ 2026-07-07 (PRs #284/#285) · ~~**`v3-api-standards`**~~ ✅ **COMPLETADA 2026-07-07** (PR #287): RFC 7807 uniforme, paginación estándar `{items,total,page,pages}`, `Idempotency-Key` por header (incl. cierre de caja), DEC-24 (UoW = RPCs `SECURITY DEFINER`). Specs (`api-standards` nueva + `base-repositories` modificada) sincronizadas; change archivado.
4. **`v3-rbac-multirole`** [CRÍTICO — solo análisis hasta sign-off PO] → después: percepciones (V2.5, depende del snapshot fiscal ya completo).
5. ~~**`metodos-pago-operaciones`**~~ ✅ **COMPLETADA 2026-08-19** (PRs #419/#420, ad-hoc — pedido directo del PO, fuera de la secuencia `v3-*`): catálogo `payment_methods` (espejo de `cost_centers` + `kind` cerrado + `sort_order` + soft delete) sembrado por cuenta, imputación opcional en ventas/compras (alta y edición con preservación por `model_fields_set`), `rpc_payment_method_report`, superficies completas (selectores, manager en Configuración, badges/filtros, `/reportes/formas-pago`). Backfill de las 120 ventas del POS ejecutado (218 filas, idempotente). Specs sincronizadas (`payment-method` nueva); change archivado.
6. ~~**`pos-catalogo-pagos`**~~ ✅ **COMPLETADA 2026-08-19/20** (PRs #421/#422): unificó el POS al catálogo (grilla reemplaza los 2 botones hardcodeados), `credit` exige cliente + muestra saldo, caja condicionada al camino (no a la etiqueta), CHECK de `sales_orders.payment_method` ampliado a los 7 `kind`. Hallazgo no previsto: el bloque `credit` de C-30 estaba borrado en silencio desde una regresión de julio — restaurado desde la definición viva de prod. Specs sincronizadas; change archivado.
7. ~~**`edicion-preserva-contexto`**~~ ✅ **COMPLETADA 2026-08-20** (PR #423/#424): `branch_id`/`canal`/`unit_id`/`supplier_id`/`cost_center_id` dejan de perderse al editar una operación (quedaban `NULL` en silencio); venta con comprobante fiscal emitido pasa a inmutable (`P0423`); `quantity` acepta decimales en la edición. Specs sincronizadas (`operation-edit-context` nueva); change archivado.
8. ~~**`pagos-cableados-restantes`**~~ ✅ **COMPLETADA 2026-08-20** (PR #425/#426 — cierra OQ-B parcial, OQ-C, OQ-D y OQ-E parcial de `pos-catalogo-pagos`): helper compartido `_pay_register_party_charge` (capability nueva `party-account-charge`) despachado por POS y formulario de venta por igual; el formulario de venta a crédito ya postea el cargo en cuenta corriente (241 operaciones históricas que no lo hacían); opt-in de caja en el formulario con las tres condiciones verificadas en servidor; `rpc_create_purchase_operation` ya no hardcodea `'credit'` en el evento (afectaba el 100% de las 38 compras históricas); `wallet` rutea a `1110 Banco` en el consumidor contable; operación con cargo/movimiento posteado pasa a inmutable (`P0423`, mismo patrón que el bloqueo fiscal). Specs sincronizadas (`party-account-charge` nueva; `cash-session`/`customer-account`/`journal-entry`/`operation-edit-context`/`payment-method` modificadas); change archivado. **Los tres candidatos que dejó registrados ya tienen destino**: `pos-banco-movimientos` ✅ 2026-08-20 (PRs #427/#428, cierra OQ-A), `asiento-venta-formulario` ✅ 2026-08-20 (PRs #431-#435), `compras-proveedor-cuenta-corriente` ✅ 2026-08-23 (#452/#455, ítem 9). Después: `delete-guard-ledgers` ✅ 2026-08-22 (#438/#439) y `banco-caja-historial-ajustes` ✅ 2026-08-22 (#440/#441); fixes ad-hoc #442/#443 (`validate_sign_coherence` + `sale_reversal`).
9. ~~**`compras-proveedor-cuenta-corriente`**~~ ✅ **COMPLETADA 2026-08-23** (apply PR #452 `2819772` + fix post-demo PR #455 + archive; demo real del PO en prod, saldo compensado verificado en DB) (`openspec/changes/compras-proveedor-cuenta-corriente/`, governance MEDIUM): ABM de proveedores (`/proveedores` + entrada de sidebar en Catálogo, backend 3 capas extendiendo el `SupplierRepository` huérfano), identidad fiscal espejo de `clients` (RN-96), selector de proveedor con alta inline en el form de compra, y cargo real en `supplier_accounts` vía `_pay_register_party_charge(..., 'supplier', ...)` cuando la forma de pago es `kind='credit'` (deroga OQ-3/B de C-30 — BREAKING de dominio declarado). Cero lógica nueva de cuenta corriente; activa y cubre con tests tres piezas ya escritas y nunca ejercitadas (guard `P0423` de compra, compensación `P0425`, rama `2100 Proveedores`). Migración `20261009000001` (4 commits `ba0f3b4`/`c0c2790`/`5132e2d`/`caef30a`, rama `opsx/compras-proveedor-cuenta-corriente-apply`). Las 6 OQs se resolvieron todas por su opción recomendada (el PO no respondió) — detalle en `CHANGES.md` (entrada propia). Hallazgos reales: (1) el `pg_get_functiondef` vivo de `rpc_create_purchase_operation` había divergido del último archivo de migración por una reescritura in-place del G3 de `20261003000001` (atrapado por el checkpoint 1.4 antes de escribir SQL); (2) `suppliers.company_id` seguía `NOT NULL` legacy, corregido con `DROP NOT NULL` guardado. La KB (04 y modelo V2) **sí tenía razón** en que `suppliers` ya tenía `tax_id` — corregido en task 15.1, el error estaba en el `design.md` de este mismo change, no en la KB. Verificación (fase D, 2026-08-23): backend 1570/1570, frontend 1331/1332 (1 pre-existente ajeno), tsc sin nuevos errores, a11y con 2 gaps reales corregidos (`supplier-form.tsx`/`searchable-select.tsx`). 14.3/14.5/14.6 se cerraron con la demo real del PO en prod (2026-08-23). **Próximo: `/opsx:apply cuenta-corriente-party-guard`** (ítem 10; su OQ-2 ya salió como hotfix #454).
10. **`cuenta-corriente-party-guard`** 🔨 **PROPUESTA 2026-08-22** (`openspec/changes/cuenta-corriente-party-guard/`, governance MEDIUM con un tramo de severidad alta) — **recomendado ANTES del ítem 9**: el guard tiene que existir antes de que las compras empiecen a postear cargos a proveedores reales (sin conflicto de archivos entre ambos). Hallazgo colateral de la auditoría de tenancy del hotfix #446: las 3 RPCs de cuenta corriente que mueven dinero (`rpc_register_payment_received`/`_made`/`rpc_register_supplier_charge`) resuelven el tenant desde la sesión pero **no validan que la parte le pertenezca**, y `c30_get_or_create_*` inserta igual (el FK a `clients`/`suppliers` no está scopeado) → saldo, cobros y asiento contra una entidad invisible en las listas del tenant. Las dos RPCs hermanas de C-30 sí validan con `P0404` — el guard existe y no se replicó. **Hallazgo nuevo del propose, más grave**: `_pay_register_party_charge` y `_journal_post_from_event` son `SECURITY DEFINER`, reciben el tenant por parámetro y están `GRANT`-eadas a `authenticated` → invocables por PostgREST con la cuenta de otro tenant = escritura cross-tenant real (`_journal_post_from_event` perdió su `REVOKE` en `20261001000001` L1914, por el patrón uniforme REVOKE+GRANT). El change: guard en el choke point + guard explícito en las 3 RPCs + `REVOKE` de los dos helpers + chequeo (3) permanente en `test_function_acl_gate.sql` (hoy solo mira `anon`, por eso pasó desapercibido) + auditoría read-only del daño histórico. Sin superficie frontend (declarado). 6 OQs con recomendación; **OQ-2 🛑** pregunta si el `REVOKE` entra acá o sale como hotfix inmediato al estilo #446. Baselines de prod **no capturados** en el propose (sin credenciales) → checkpoint 🛑 obligatorio en task 1.4. **Próximo: `/opsx:apply cuenta-corriente-party-guard`**.

> **Pendientes externos del PO (no bloquean código)**: trámite ARCA homologación (C-27 5.2 / v22 9.1) y config de verificación de email en Supabase. **`v3-rbac-multirole` es CRÍTICO** — análisis solamente hasta sign-off explícito del PO (consume matriz de transiciones de `v3-document-status-history`).

### Camino crítico (Fases 6-7)
```
C-19 tenancy-cleanup ─┬→ C-20 sale-items ────────→ C-29 quote-salesorder → C-30 ctas-corrientes
                      ├→ C-21 inventory-unif ────→ C-26 branch-as-root ─┬→ C-27 fiscal-profile (AFIP, CRÍTICO)
                      ├→ C-24 insights-unif                             └→ C-28 cash-session
                      └→ C-25 outbox-activation
C-22 fiscal-identity-clients · C-23 community-schema-split — paralelos e independientes
```

### Fases
| Fase | Changes | Estado | Descripción |
|---|---|---|---|
| 1 — Billing | C-01, C-02, C-03, C-09 | ✅ | Schema + gating engine + grace period + community bug fixes |
| 2 — IA | C-04, C-11, C-12, C-13 | ✅ | Contadores IA split + rentabilidad + reportes comparativos + sugerencia precios |
| 3 — Multi-tenant | C-05, C-06, C-07, C-08 | ✅ | Arquitectura multi-usuario + roles + sucursales + stock multisucursal |
| 4 — Upgrade UX | C-10, C-14 | ✅ | UI de upgrade de plan + módulo de exportaciones |
| 5 — Backend Python | C-15, C-16, C-17, C-18 | ✅ | Capa de datos + migración API + pagos + desacople DataContext (realtime queda en Supabase, DEC-16) |
| 6 — V2.0 Retirada de deuda | C-19 → C-25 | ✅ 7/7 | Tenancy única, sale_items (Group 10 DROP diferido — lo desbloquea `v3-snapshot-pattern`), ledger único de stock en branch_stock, FiscalIdentity en clientes, schema community, insights unificados, outbox activo (C-25 ✅ 2026-06-18; revivido en prod 2026-07-01, #248) |
| 7 — V2.1 Operación | C-26 → C-30 | ✅ 5/5 | Branch como root, FiscalProfile + AFIP CAE async (E2E homologación pendiente PO), CashSession con arqueo, Quote/SalesOrder + quickSale POS (C-29 ✅ 2026-06-17), cuentas corrientes cliente/proveedor (C-30 ✅ 2026-06-20) |
| V2.5 — Finanzas | post-roadmap | 🔨 en marcha | cost-center ✅ + journal-entry-outbox ✅ (partida doble async vía outbox) + **BankReconciliation COMPLETA (C1+C2+C3 ✅, 2026-07-02)** · falta: percepciones. AFIP delegación (v22 ✅) + facturar venta manual ✅ |
| Modelo V3 (retrofit) | `v3-*` | 🔨 en marcha | Snapshots ✅ (2026-07-02), FSM+DocumentStatusHistory ✅ (2026-07-03), notificaciones realtime ⭐, soft delete, RBAC multi-rol (CRÍTICO), provisioning seed, RN-D reporting, estándares API, maestros menores — ver `CHANGES.md` §"Roadmap Modelo V3" (producto-imagenes descartado por PO 2026-07-04) |
| V3 — Inteligencia | ⏳ | ⏳ | AIAgent, KnowledgeBase, automatizaciones, predicción + BOM ligera (`v3-product-composition`) |

---

## Reglas Duras (específicas del proyecto)

> Reglas globales ya definidas en `~/.claude/CLAUDE.md` (orquestador OPSX, governance CRITICAL/HIGH/MEDIUM/LOW, TDD, engram, model assignments): el proyecto las hereda. Acá viven solo las reglas **específicas de este proyecto**.

### Changes / Producto — superficie frontend obligatoria (regla PO 2026-08-02)
- **Todo change que produzca algo que un usuario o el admin deba ver u operar DEBE planificar su superficie frontend en el propose**: qué pantalla/sección lo expone, cómo se llega (ruta + entrada de menú/sidebar) y sus tasks correspondientes en tasks.md. Backend sin puerta de entrada = change incompleto. (Origen: `CostCenterManager` construido y jamás montado en ninguna página; cola de suscripciones ambiguas invisible hasta que el PO preguntó dónde estaba.)
- **La estética se planifica, no se improvisa**: la parte visual usa el design system del proyecto (tokens semánticos, componentes base vía cva) y se verifica en **desktop Y mobile** (responsive) y en **tema claro y oscuro** antes del merge.
- Excepción: changes puramente internos (infra, CI, migraciones sin efecto visible para nadie) — declarar explícitamente "sin superficie frontend" en el proposal, para que la omisión sea una decisión y no un olvido.

### Reutilización antes que repetición (regla PO 2026-08-02)
- **ANTES de escribir una función, componente, hook, query o RPC nueva: buscar si ya existe una que lo haga (o casi)** — grep por dominio/nombre en `lib/`, `hooks/`, `components/`, `backend/services/`, `backend/repositories/` y las RPCs de `supabase/migrations/`. Si existe: reutilizarla o extenderla; NUNCA duplicarla. La lógica repetida diverge y produce bugs silenciosos (casos reales: 3 Edge Functions calculando su propio "plan efectivo" contra una tabla muerta en vez de `get_effective_plan`; criticidad de stock rehecha en 5 lugares hasta canonizarla en `lib/product-stock.ts`).
- **Lo nuevo reusable nace en la capa canónica** (`lib/`, `hooks/`, componentes base, service/repository correspondiente), no embebido en una pantalla o endpoint puntual.
- Equilibrio: esto NO pide abstraer prematuramente (sigue vigente la Regla de Tres para crear abstracciones nuevas) — pide no REESCRIBIR lo que ya existe.

### TypeScript / React
- **NUNCA usar `any`** → usar tipos explícitos o `unknown`. Si un tipo es complejo, definirlo en `lib/types.ts`.
- **PascalCase en componentes React** → `ProductCard.tsx`, `SalesTable.tsx`. Archivos de componentes también en PascalCase.

### Supabase / Auth / Seguridad
- **SIEMPRE `supabase.auth.getUser()` en server-side** → NUNCA confiar en `getSession()` solo para decisiones de auth. `getSession()` no verifica el JWT.
- **NUNCA exponer `SUPABASE_SERVICE_ROLE_KEY` al cliente** → Solo en Edge Functions (servidor). La service_role bypasea toda RLS.
- **NUNCA usar el MCP `apply_migration` para aplicar migrations de producción** → Registra un timestamp diferente al del archivo local y desincroniza el historial. Siempre usar `npx supabase db push` via CLI. Si se usó el MCP accidentalmente, reparar con `npx supabase migration repair --status reverted <timestamp_mcp>` y luego `npx supabase db push`.
- **Dos proyectos Supabase en este proyecto**: `gxdhpxvdjjkmxhdkkwyb` = proyecto real con usuarios (CLI + MCP). `pudaxiwqhwsxuaofsqda` = proyecto del preview de Vercel (vacío, schema más avanzado). Las migrations se aplican siempre al primero vía CLI.

### TypeScript / Imports
- **NUNCA usar `as import("@/ruta").Tipo` en type assertions** → Sintaxis de inline dynamic import inusual que puede tener edge cases con SWC/Turbopack. Importar el tipo explícitamente en la cabecera del archivo y usar `as Tipo` directamente.

### Git / Commits
- **Conventional commits** → `feat(scope): mensaje`, `fix(scope): mensaje`, `chore(scope): mensaje`, `docs(scope): mensaje`. Scope = módulo afectado (ventas, auth, stock, ai, billing, etc.).
- **Co-autoría en commits del agente**:
  ```
  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  ```

### Backend Python / FastAPI (Fase 5 — planificado)
- **NUNCA usar `service_role` en el backend** → usar **JWT-passthrough**: inyectar los claims del JWT del usuario en la conexión `asyncpg` para que la RLS org-based siga activa como red de seguridad. Excepción única: jobs administrativos aislados.
- **NUNCA poner lógica de negocio en los routers** → arquitectura de 3 capas obligatoria: `routers` (validación + DI) → `services` (lógica + guards `require_role`/`require_plan`) → `repositories` (acceso a datos / RPCs).
- **SIEMPRE validar con Pydantic v2** en el endpoint antes de tocar la DB. Nada de payloads sin schema.
- **Webhook de pagos = governance CRÍTICO** → migrarlo corriendo en paralelo al webhook actual y comparando resultados antes de cortar. Requiere aprobación humana explícita antes de tocar (dinero real).
- **TDD con `pytest` + `pytest-asyncio`** → tests por cada router/service; coverage mínimo verificado en CI (`pytest-coverage`).
- **NUNCA migrar IA/OCR a Python sin presupuesto** (DEC-15) → los servicios de IA y OCR se quedan en Supabase Edge Functions por ahora; los workers Python (ARQ) están pospuestos.

---

## Skill Routing (cuándo invocar cada skill vía `/skill-name`)

Cuando el pedido del usuario coincide con una skill disponible, invocarla via el Skill tool.

| Pedido del usuario | Skill |
|---|---|
| Ideas de producto / brainstorming | `/office-hours` |
| Estrategia / alcance | `/plan-ceo-review` |
| Arquitectura | `/plan-eng-review` |
| Review de diseño / sistema de diseño | `/design-consultation` o `/plan-design-review` |
| Review completo (pipeline) | `/autoplan` |
| Bugs / errores | `/investigate` |
| QA / testear comportamiento del sitio | `/qa` o `/qa-only` |
| Code review / diff check | `/review` |
| Pulido visual | `/design-review` |
| Ship / deploy / PR | `/ship` o `/land-and-deploy` |
| Guardar progreso de contexto | `/context-save` |
| Restaurar contexto | `/context-restore` |
| Escribir spec / issue de backlog | `/spec` |

---

## Flujo de Trabajo

```
1. Leer CHANGES.md → identificar el change por código C-NN
2. Leer los archivos de KB relevantes para ese change
3. /opsx:propose <nombre-del-change>   → crea proposal + design + tasks
4. /opsx:apply <nombre-del-change>     → implementa las tasks
5. /opsx:archive <nombre-del-change>   → sincroniza specs + cierra el change
6. Marcar [x] en CHANGES.md
```

> Para explorar antes de proponer: `/opsx:explore <tema>`  
> Para skill routing adicional: consultá el CLAUDE.md raíz del proyecto.
