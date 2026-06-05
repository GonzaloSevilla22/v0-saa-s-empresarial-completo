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
| 09 | [knowledge-base/09_decisiones_y_supuestos.md](knowledge-base/09_decisiones_y_supuestos.md) | 11 decisiones + 7 supuestos — leer antes de proponer. |
| 10 | [knowledge-base/10_preguntas_abiertas.md](knowledge-base/10_preguntas_abiertas.md) | Inconsistencias conocidas — revisá antes de implementar. |

---

## Skills Disponibles

Los compact rules de cada skill los resuelve el orquestador desde `.atl/skill-registry.md` (generado por `skill-registry`; no versionado — no está en el repo).

| Agente / Rol | Skills que carga |
|---|---|
| **Backend / DB** (migraciones, RLS, RPCs, Supabase) | `supabase`, `supabase-postgres-best-practices` |
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

---

## Roadmap de Changes

> Fuente: [CHANGES.md](CHANGES.md) — 14 changes en 4 fases.

### Camino crítico
```
C-01 billing-schema-migration  →  C-02 plan-gating-engine  →  C-03 grace-period-logic
                                                            →  C-05 multi-user-tenant-architecture (BLOQUEO MAYOR)
                                                            →  C-10 subscription-ui-upgrade-flow
```

### Primer change recomendado
**`C-01 billing-schema-migration`** — Migrar el enum `profiles.plan` de `free/pro` a los 4 planes reales (`gratis/inicial/avanzado/pro`) y agregar columnas de billing. Es el prerequisito de todo lo demás.

También puede arrancarse en paralelo: **`C-09 community-bug-fixes`** (sin dependencias de billing).

### Fases
| Fase | Changes | Descripción |
|---|---|---|
| 1 — Billing | C-01, C-02, C-03, C-09 | Schema + gating engine + grace period + community bug fixes |
| 2 — IA | C-04, C-11, C-12, C-13 | Contadores IA split + rentabilidad + reportes comparativos + sugerencia precios |
| 3 — Multi-tenant | C-05, C-06, C-07, C-08 | Arquitectura multi-usuario + roles + sucursales + stock multisucursal |
| 4 — Upgrade UX | C-10, C-14 | UI de upgrade de plan + módulo de exportaciones |

---

## Reglas Duras (específicas del proyecto)

> Reglas globales ya definidas en `~/.claude/CLAUDE.md` (orquestador OPSX, governance CRITICAL/HIGH/MEDIUM/LOW, TDD, engram, model assignments): el proyecto las hereda. Acá viven solo las reglas **específicas de este proyecto**.

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
