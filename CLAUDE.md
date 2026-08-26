# EmprendeSmart (EIE) — Instrucciones para Agentes

> SaaS para microemprendedores de Mendoza: gestión financiera (ventas/compras/gastos/stock) + IA accionable.  
> MVP en producción con usuarios reales — Junio 2026.
>
> ⚠️ **Este archivo se mantiene idéntico en `CLAUDE.md` y `AGENTS.md`.** `CLAUDE.md` es la fuente de verdad (Claude Code lo inyecta solo en su contexto); `AGENTS.md` es la copia que leen los demás agentes. Editá `CLAUDE.md` y corré `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** — el gate `Docs Sync` lo verifica en cada PR. (Se agregó porque `AGENTS.md` estuvo dos meses congelado anunciando `C-21` como próximo change.)

---

## Stack Tecnológico

> Verificado contra los manifiestos el **2026-08-26** (`frontend/package.json`, `backend/requirements.txt`, `backend/pyproject.toml`, `.github/workflows/`, `vercel.json`).
> Si tu change sube o baja una versión, actualizá esta tabla en el mismo PR — se desactualizó una vez y nadie lo notó por meses.

### Frontend — `frontend/package.json`

| Capa | Tecnología | Versión |
|------|------------|---------|
| **Framework** | Next.js (App Router; Turbopack en `dev`) | 16.1.6 |
| **UI** | React + React DOM | 19.2.3 |
| **Lenguaje** | TypeScript | 5.7.3 |
| **Estilos** | Tailwind CSS + PostCSS + `tailwindcss-animate` | 3.4.17 |
| **Componentes** | shadcn/ui sobre Radix UI (28 primitivas) + `class-variance-authority` + `clsx` + `tailwind-merge` | — |
| **Iconos** | `lucide-react` | 0.544 |
| **Estado global** | Zustand | 5.0.13 |
| **Server state / cache** | TanStack React Query (+ devtools) | 5.100.14 |
| **Formularios** | React Hook Form + Zod + `@hookform/resolvers` | 7.54 / 3.24 |
| **Gráficos** | Recharts + D3.js | 2.15 / 7.9 |
| **3D** | `three` + `@react-three/fiber` + `@react-three/drei` (v4 visual, con `capabilityGate`) | 0.185 / 9.6 / 10.7 |
| **Animación** | `framer-motion` | 12.43 |
| **Temas** | `next-themes` (claro/oscuro — ambos obligatorios en toda UI nueva) | 0.4.6 |
| **Cliente Supabase** | `@supabase/supabase-js` + `@supabase/ssr` | 2.98 / 0.8 |
| **Pagos (cliente)** | `mercadopago` | 2.4 |
| **Anti-bot** | Cloudflare Turnstile (`@marsidev/react-turnstile`) — usar siempre `submitWithFreshCaptcha` | 1.5 |
| **Otros** | `date-fns` 4.1, `sonner`, `cmdk`, `vaul`, `embla-carousel-react`, `react-day-picker`, `input-otp`, `react-resizable-panels` | — |
| **Unit tests** | Vitest + Testing Library (react/dom/jest-dom/user-event) + jsdom | 4.1 / 29 |
| **E2E** | Playwright | 1.61 |
| **Package manager** | pnpm (monorepo, `pnpm-workspace.yaml`) | 10.33.4 |

### Backend Python — `backend/` (EN PRODUCCIÓN — Fase 5 ✅, ya no es "planificado")

> **Modelo híbrido**: el frontend consume FastAPI para datos (mutaciones + lecturas) y sigue hablando directo con Supabase para Auth y Storage. Realtime: Supabase (DEC-16) **+** WebSocket propio del backend (`routers/ws.py` + `core/ws_manager.py`). Ver `knowledge-base/08_arquitectura_propuesta.md` §"Evolución Arquitectónica: Backend Python/FastAPI".
>
> **Superficie real**: 26 routers / 26 services / 30 repositories + `core/` (`auth`, `client_activity`, `config`, `database`, `deps`, `errors`, `guards`, `idempotency`, `redis_client`, `ws_manager`).

| Capa | Tecnología | Notas |
|------|------------|-------|
| **Runtime** | Python 3.12 (CI) | `pyproject` declara `requires-python >=3.11` |
| **Framework API** | FastAPI ≥0.111 + Uvicorn[standard] ≥0.29 | Arquitectura 3 capas: routers → services → repositories |
| **Validación** | Pydantic v2 + `pydantic-settings` ≥2.2 | Nada de payloads sin schema |
| **DB driver** | asyncpg ≥0.29 | Pool con JWT-passthrough (RLS org-based activa como red, NO como guard único) |
| **Auth** | `PyJWT[crypto]` ≥2.8 (`PyJWKClient`) | Los tests usan `python-jose` — ver nota ⚠️ abajo |
| **Cache / rate-limit / idempotencia** | Redis ≥5.0 (Upstash free) | Instancia por env var; no declarada en el repo |
| **Reintentos** | `tenacity` ≥8.2 | — |
| **HTTP client** | `httpx` ≥0.27 | — |
| **PDFs** | `fpdf2` ≥2.7 | Comprobantes y recibos |
| **SOAP AFIP/ARCA** | `zeep` ≥4.2,<5 | Facturación electrónica (C-27) |
| **SDK Supabase** | `supabase-py` ≥2.0 | — |
| **Testing** | pytest ≥8 + pytest-asyncio (`asyncio_mode=auto`) + httpx + asyncpg-stubs | Coverage ≥87% en CI; `omit` de `tests/` y `.venv/` |
| **Deploy backend** | Render (free tier) | Cold start ~50s; el workflow `keep-backend-warm` pingea `/health` cada 10 min para que el webhook de MP no dé 502 |

> ⚠️ **Divergencia conocida de manifiestos**: `pyproject.toml` declara `python-jose` y NO `PyJWT`; `requirements.txt` declara `PyJWT[crypto]` y NO `python-jose`. El código de app importa **PyJWT** (`core/auth.py`), los tests importan **jose** (`tests/conftest.py`). Hoy funciona porque CI instala ambos caminos; si tocás dependencias, no "limpies" uno de los dos sin verificar quién lo importa.

### Datos e infraestructura

| Capa | Tecnología | Notas |
|------|------------|-------|
| **BaaS** | Supabase (Auth, DB, Edge Functions, Storage, Realtime) | Proyecto real: `gxdhpxvdjjkmxhdkkwyb` |
| **DB** | PostgreSQL vía Supabase, con RLS org-based | 263 migraciones; última `20261014000001_sucursal_guard_vaciado_auditoria` |
| **Extensiones PG** | `pg_cron` (grace period, relay outbox) · `pg_net` / DB webhooks (email, outbox, relay CAE) | — |
| **Edge Functions** | Deno (Supabase) — 11 funciones | `ai-insights`, `ai-resumen`, `ai-precio`, `ai-rentabilidad`, `ai-comparativo`, `ai-prediccion`, `ai-simulador`, `fair-advisor`, `invoice-ocr`, `generate-export`, `send-email` |
| **IA** | OpenAI API | `gpt-4o-mini` en las 9 funciones de IA; **`gpt-4o`** (visión) en `invoice-ocr` |
| **Email** | Resend (via Edge Function + DB Webhook) | — |
| **Pagos** | MercadoPago | Webhook en el backend Python: `POST /payments/webhook` (governance CRÍTICO) |
| **Deploy frontend** | Vercel | `vercel.json`: build `cd frontend && pnpm run build`, output `frontend/.next` |
| **CI/CD** | GitHub Actions × 6 | `deploy.yml` (build Next + `supabase db push --include-all` + `functions deploy`), `Backend_Tests`, `Frontend_Tests`, `E2E_Tests`, `KPI_Validation`, `keep-backend-warm`. Node 20 / Python 3.12 |

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
9. ~~**`compras-proveedor-cuenta-corriente`**~~ ✅ **COMPLETADA 2026-08-23** (apply PR #452 `2819772` + fix post-demo PR #455 + archive; demo real del PO en prod, saldo compensado verificado en DB) (`openspec/changes/compras-proveedor-cuenta-corriente/`, governance MEDIUM): ABM de proveedores (`/proveedores` + entrada de sidebar en Catálogo, backend 3 capas extendiendo el `SupplierRepository` huérfano), identidad fiscal espejo de `clients` (RN-96), selector de proveedor con alta inline en el form de compra, y cargo real en `supplier_accounts` vía `_pay_register_party_charge(..., 'supplier', ...)` cuando la forma de pago es `kind='credit'` (deroga OQ-3/B de C-30 — BREAKING de dominio declarado). Cero lógica nueva de cuenta corriente; activa y cubre con tests tres piezas ya escritas y nunca ejercitadas (guard `P0423` de compra, compensación `P0425`, rama `2100 Proveedores`). Migración `20261009000001` (4 commits `ba0f3b4`/`c0c2790`/`5132e2d`/`caef30a`, rama `opsx/compras-proveedor-cuenta-corriente-apply`). Las 6 OQs se resolvieron todas por su opción recomendada (el PO no respondió) — detalle en `CHANGES.md` (entrada propia). Hallazgos reales: (1) el `pg_get_functiondef` vivo de `rpc_create_purchase_operation` había divergido del último archivo de migración por una reescritura in-place del G3 de `20261003000001` (atrapado por el checkpoint 1.4 antes de escribir SQL); (2) `suppliers.company_id` seguía `NOT NULL` legacy, corregido con `DROP NOT NULL` guardado. La KB (04 y modelo V2) **sí tenía razón** en que `suppliers` ya tenía `tax_id` — corregido en task 15.1, el error estaba en el `design.md` de este mismo change, no en la KB. Verificación (fase D, 2026-08-23): backend 1570/1570, frontend 1331/1332 (1 pre-existente ajeno), tsc sin nuevos errores, a11y con 2 gaps reales corregidos (`supplier-form.tsx`/`searchable-select.tsx`). 14.3/14.5/14.6 se cerraron con la demo real del PO en prod (2026-08-23). El ítem 10 (`cuenta-corriente-party-guard`) ya se aplicó y archivó el mismo día.
10. ~~**`cuenta-corriente-party-guard`**~~ ✅ **COMPLETADA 2026-08-23** (propose PRs #448/#450 · apply PR **#457** `21dbe38` · archive el mismo día; archivada en `openspec/changes/archive/2026-08-23-cuenta-corriente-party-guard/`, governance MEDIUM con un tramo de severidad alta). Cerró el hueco de tenencia de las 3 RPCs de cuenta corriente que mueven dinero (`rpc_register_payment_received`/`_made`/`rpc_register_supplier_charge`): resolvían el tenant desde la sesión pero **no validaban que la parte le perteneciera**, y `c30_get_or_create_*` insertaba igual (el FK a `clients`/`suppliers` no está scopeado) → saldo, cobros y asiento contra una entidad invisible en las listas del tenant. **Diseño opción B**: guard en el choke point `c30_get_or_create_*` (cubre todos los caminos presentes y futuros) + guard explícito en las 3 RPCs como defensa en profundidad, `P0404` → 404 RFC 7807. **OQ-2 se resolvió como hotfix #454**, fuera del change: `_pay_register_party_charge` y `_journal_post_from_event` eran `SECURITY DEFINER` con el tenant por parámetro y `GRANT` a `authenticated` = escritura cross-tenant real; el apply se reconcilió sin REVOKE duplicado. El gate de ACLs sumó el **chequeo (4)** (barrido por convención de nombre) conviviendo con el **(3)** angosto de #454; allowlist del (4) con una sola entrada, `_c29_confirm_order_core`. Migración final **`20261011000001`** (doble renumerado: reservó `20261008000001`, #452 tomó `20261009000001` forzando `20261010000001`, y el hotfix #454 tomó ése). Sin superficie frontend (declarado). **Verificación post-merge en prod** ✅ (`MAX(version)`, ACLs de las 7 funciones, cuerpo vivo con el guard, 3→1 helpers expuestos) y **auditoría de daño histórico 0/9** → no hay reparación pendiente, OQ-5 cerrada por ausencia de datos y del PO sólo resta darse por enterado. Backend 1604/0/3.
11. ~~**`tenancy-guard-caja-outbox`**~~ ✅ **COMPLETADA 2026-08-24** (propose PR **#459** `6191631` · h2 hotfix PR **#460** `5ce75cf` · h1 apply PR **#461** `d41838c` · archive el mismo día; archivada en `openspec/changes/archive/2026-08-24-tenancy-guard-caja-outbox/`, governance CRÍTICO con sign-off del PO firmado el 2026-08-24). Cerró juntos **h1 + h2**, los dos hallazgos laterales de severidad **alta** y **reproducidos** que dejó `cuenta-corriente-party-guard`. **h1**: el POS aceptaba un `p_cash_session_id` de otro tenant y le escribía en la caja — cerrado con guard en dos capas: sucursal en `_c29_confirm_order_core` (`P0422`, predicado copiado del formulario) + backstop de tenant en `c28_register_cash_movement` (`P0401`, resolución por FKs, sin cambiar la firma). **h2 + h2 bis** salieron como hotfix separado (PR #460, por decisión del PO en OQ-1): `REVOKE` de `rpc_process_outbox_batch`/`rpc_mark_event_processed` de los tres roles de aplicación + `REVOKE` a nivel tabla sobre `public.events` + el endpoint del outbox pasó a `get_service_conn` + `require_platform_admin` + `rpc_process_outbox_dispatch`, y se retiró `OutboxRelayService` (los dos relays competían por el mismo flag `processed_at`; ganar el relay Python perdía el asiento contable para siempre). Gates nuevos permanentes: chequeo **(5)** del gate de ACLs (lista curada de funciones que leen/actualizan `public.events`) y `test_outbox_single_dispatcher.sql`. Migraciones `20261012000001_revoke_outbox_cross_tenant.sql` (h2) y `20261013000001_tenancy_guard_caja_sesion.sql` (h1 — el número que preveía el propose se lo llevó el hotfix de h2). **Sin superficie frontend** (declarado y verificado). **Auditoría de daño histórico: 0 en los cuatro conteos** re-medidos en prod (movimientos de caja cross-tenant, eventos procesados sin asiento/sin notificación) — OQ-5 cerrada por ausencia de datos. **Verificación post-merge en prod** ✅ (`MAX(version) = 20261013000001`, 262 migraciones; ACLs y cuerpos vivos con los guards; `events` sin `SELECT`/`INSERT` para `anon`). Dos rondas de revisión adversarial corrigieron, antes del merge: un guard de capa 1 que no era autosuficiente (delegaba en un chequeo posterior evadible declarando también la sucursal ajena), la elección de `P0401` sobre `P0001` para no abortar `db reset`, y dos regresiones propias del detector del chequeo (5). Detalle completo en `CHANGES.md`. **Quedan como chequeo de rutina, no bloqueante**: confirmar el pg_cron `relay-process-outbox` y la demo en vivo al PO.
12. ~~**`sucursal-guard-vaciado-auditoria`**~~ ✅ **COMPLETADA 2026-08-25** (propose + apply PR **#465** `043017a` squash · archive el mismo día; archivada en `openspec/changes/archive/2026-08-25-sucursal-guard-vaciado-auditoria/`, governance MEDIO). Ad-hoc, pedido directo del PO tras el incidente del 22→24-08: una sucursal con 518 productos/585 unidades se desactivó sin ninguna verificación, dejando el negocio invendible dos días. **G1**: disparador `BEFORE UPDATE OR DELETE` sobre `public.branches` (`trg_guard_branch_decommission`, punto de paso obligado que cubre los cuatro caminos de baja) rechaza con `P0428` si hay existencias (`branch_stock <> 0`), sesión de caja abierta o transferencias sin completar; el borrado físico queda prohibido incondicionalmente. `rpc_close_branch` se unificó de `P0409` a `P0428` conservando el token de texto para no romper la traducción del cliente. **G2**: autoría (`created_by`/`deactivated_at`/`deactivated_by`, sin backfill, sin FK dura) + ciclo de vida completo en `audit_logs` vía `trg_audit_branch_lifecycle` (sin notificaciones). **G3**: transferencia entre sucursales descubrible desde `/stock` (acción por fila, reutiliza `TransferStockModal`) y camino directo desde el error de venta por falta de stock. Hallazgo no previsto: 15 gates SQL preexistentes limpiaban con `DELETE FROM branches` en cascada — CI encontró una tercera ronda que el apply local no vio (bloque de cleanup "intruso" separado); 41 wraps `session_replication_role=replica` sobre 20 archivos en total. **Verificación post-merge en prod** ✅ (`MAX(version) = 20261014000001`; 2 triggers vivos; 3 columnas de auditoría; auditoría de daño histórico re-medida en **0** sobre 40 sucursales; humo real: `UPDATE is_active=false` sobre Showroom con 531 productos bloqueado con `P0428`). Specs sincronizadas (`branch-decommission-guard` nueva; `branches` + `branch-stock` modificadas). Detalle completo en `CHANGES.md`.

> **Pendientes externos del PO (no bloquean código)**: trámite ARCA homologación (C-27 5.2 / v22 9.1) y config de verificación de email en Supabase. **`v3-rbac-multirole` es CRÍTICO** — análisis solamente hasta sign-off explícito del PO (consume matriz de transiciones de `v3-document-status-history`).

### Candidatos para el próximo `/opsx:propose` (sin change activo todavía)

`sucursal-guard-vaciado-auditoria` (ítem 12) no dejó ningún change propio recomendado como "siguiente" — el gating real sigue siendo `v3-rbac-multirole` (ítem 4, CRÍTICO, bloqueado a sign-off del PO). Lo que sí quedó documentado y sin resolver:

Heredado de `cuenta-corriente-party-guard` (ver `openspec/changes/archive/2026-08-23-cuenta-corriente-party-guard/design.md` §"Hallazgos laterales de la revisión de seguridad" y `CHANGES.md` §"Candidatos dados de alta por `cuenta-corriente-party-guard`"):

- **`operacion-party-guard`** (OQ-4 de `cuenta-corriente-party-guard`) — la venta/compra **al contado** con `client_id`/`supplier_id` ajeno sigue sin guard (no crea saldo ni asiento contra un tercero, pero deja una fila mala en `sales`/`purchases`). Guard natural en `rpc_create_sale_operation(_v2)`, `_c29_confirm_order_core` y `rpc_create_purchase_operation`.
- **Endurecimiento de `c30_register_customer_account_movement` / `c30_register_supplier_account_movement`** (h3) — `SECURITY INVOKER` con `EXECUTE` para `anon` en prod; hoy lo frena sólo la ausencia de policies de escritura en esas tablas (defensa de segundo orden, no un incidente).
- **`get_account_ids_for_user(uuid)`** (h4) — devuelve la membresía de cualquier `user_id` sin comparar contra `auth.uid()` (fuga menor: hace falta conocer el `user_id` ajeno).

Heredado de `sucursal-guard-vaciado-auditoria` (ítem 12, ver `CHANGES.md` para el detalle completo):

- **OQ-5** — `/stock` sigue mostrando el agregado del catálogo, no el desglose por sucursal; es la mitad de por qué el incidente del 22-08 fue invisible. G3 sólo agrega el desglose bajo demanda (al transferir), no en la columna principal del listado.
- **OQ-6** — `c26_default_branch` (resolución de la sucursal por defecto) debería avisar cuando el criterio cambia de sucursal; un aviso más caritativo habría amortiguado el incidente aunque el guard no existiera.
- **El "mostrador"/POS sin wirear** (`/ventas/pos`) — usa su propio `friendlyError`, no conectado a `operation-errors.ts`; el camino directo a transferir stock de G3 no llega ahí.
- **OQ-7 (lateral, misma familia que h3 arriba)** — `anon` tiene permisos de escritura y borrado a nivel tabla sobre `branches`; hoy sólo lo frena que las RLS exigen membresía de cuenta.

Ninguno de los siete es urgente por sí solo; quedan para que el PO decida si ameritan un change propio (posiblemente combinados, como se hizo con h1+h2 en `tenancy-guard-caja-outbox`).

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
