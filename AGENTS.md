# EmprendeSmart (EIE) — Instrucciones para Agentes

> SaaS para microemprendedores de Mendoza: gestión financiera (ventas/compras/gastos/stock) + IA accionable.  
> MVP en producción con usuarios reales — Junio 2026.

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

> Fuente: [CHANGES.md](CHANGES.md) — 30 changes en 7 fases. **Fases 1-5 (C-01→C-18) completadas** (backend Python en producción desde 2026-06-07). El PO adoptó el **modelo de dominio V2** (`modelo-dominio-aliadata-v2.md`, 2026-06-09; validado en `openspec/explore/2026-06-09-modelo-dominio-v2.md`): la Fase 6 (V2.0 retirada de deuda) es el trabajo activo. **Regla dura: ninguna feature nueva sobre tablas en retirada (RN-97, `knowledge-base/05`).**

### Próximo change recomendado (activo)
**`C-21 v20-inventory-unification`** [CRÍTICO, L] — Migrar 19 filas de stock de `inventory_stock` a `branch_stock` de Casa Central; descartar 6 warehouses auto-generados (PA-19 resuelta). Desbloquea la rama Branch → C-26 → C-27/C-28. Camino crítico del V2.1.

> **Fase 6: 4/7 ✅** — C-19 (2026-06-09), C-20/C-22/C-23 (2026-06-10) archivados. Las tablas community viven en el schema `community` (acceso vía `.schema("community")`; embedding a `profiles` vía vista puente). **Todas las preguntas abiertas de la fase están resueltas** (PA-19/PA-20/PA-21 + C-24 Opción A, `knowledge-base/10`): C-21, C-24 y C-25 también proposables. **C-20 Grupo 10 (DROP header plano) diferido** — bloqueado por representación de líneas de servicio.

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
| 6 — V2.0 Retirada de deuda | C-19 → C-25 | 🔨 C-19/C-20 ✅ | Tenancy única, sale_items (C-20 live en prod, Grupo 10 DROP diferido), ledger único de stock + Branch "Casa Central", FiscalIdentity en clientes, schema community, insights unificados, outbox activo |
| 7 — V2.1 Operación | C-26 → C-30 | ⏳ | Branch como root, FiscalProfile + AFIP (CAE async), CashSession con arqueo, Quote/SalesOrder + quickSale POS, cuentas corrientes |
| Futuras | V2.5 / V3 | ⏳ | Finanzas (BankReconciliation, JournalEntry, CostCenter UI, percepciones) / Inteligencia (AIAgent, KnowledgeBase, automatizaciones) |

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
