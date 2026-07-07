# Auditoría Técnica Pre-Producción — Código Frontend (React/Next.js)

**Proyecto**: ALIADATA / EmprendeSmart (EIE)
**Dimensión**: Código — Frontend Next.js 16 App Router + React 19 + TS 5.7
**Auditor**: Staff Frontend Engineer (rol consultora)
**Fecha**: 2026-07-06
**Scope**: `frontend/app` (72 archivos TS/TSX), `frontend/components` (161), `frontend/hooks` (74), `frontend/lib` (57), `frontend/contexts` (1), `frontend/providers` (1) — ~58.500 líneas totales (incluye 3.666 de `lib/database.types.ts` generado).

**Clasificación del área: MEJORABLE** — base moderna sólida (React Query + hooks de datos bien diseñados, middleware de auth ejemplar) conviviendo con: 1 defecto CRÍTICO verificado en prod en el flujo de pago de upgrade, violación sistemática de la regla dura "NUNCA any" (~150 ocurrencias), doble vía de lectura Supabase-directo vs FastAPI para las mismas entidades, 33 componentes >300 líneas y una capa entera de hooks genéricos muerta.

---

## 1. Metodología

- Inventario y medición por `find`/`wc`/`grep` sobre el working tree (solo lectura).
- Lectura a fondo de: `lib/api/python-client.ts`, `providers/query-provider.tsx`, `hooks/data/use-sales.ts`, `hooks/use-paginated-query.ts`, `lib/pagination-utils.ts`, `contexts/auth-context.tsx` (parcial), `middleware.ts` + `lib/supabase/middleware.ts`, `lib/supabase/server.ts`, `app/api/billing/webhook/route.ts`, `app/api/billing/preferences/route.ts`, `hooks/data/use-notifications.ts`, `app/(dashboard)/layout.tsx`, `lib/api/feature-flags.ts`, `lib/supabase/services.ts`, spot-checks de `sale-form`, `purchase-form`, POS, import dialogs, hooks de rol.
- Verificación contra prod (solo lectura, proyecto `gxdhpxvdjjkmxhdkkwyb`): `pg_policies` de `accounts`/`account_members`/`billing_events`/`plan_limits` y contenido agregado de `billing_events`.
- Cross-check con `backend/routers/payments.py`, `backend/services/payments.py` y `backend/core/errors.py` para validar contratos.

---

## 2. HALLAZGO CRÍTICO — Webhook de MercadoPago del flujo de upgrade roto (dinero real)

### Cadena verificada

1. La UI de upgrade (`components/billing/PlanComparison.tsx:34`) hace `POST /api/billing/preferences` (route handler de Next.js, NO el backend FastAPI).
2. `app/api/billing/preferences/route.ts:85` crea la preferencia de MP con:
   ```ts
   notification_url: `${appUrl}/api/billing/webhook`,
   ```
   → el webhook de ese pago apunta al route handler **legacy de Next.js**, no al backend Python.
3. `app/api/billing/webhook/route.ts:12,123` usa `createClient()` de `@/lib/supabase/server` — el cliente SSR **anon + cookies** (`lib/supabase/server.ts:6-8`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`). La llamada server-to-server de MercadoPago **no trae cookies de sesión** → el cliente opera como `anon` sin `auth.uid()`.
4. RLS verificada en prod (pg_policies, 2026-07-06):
   - `account_members` SELECT: `account_id IN (get_account_ids_for_user(auth.uid()))` → con `auth.uid()` NULL devuelve 0 filas → el webhook cae en el branch `"Cuenta no encontrada"` (404).
   - `accounts` UPDATE (`accounts_owner_update`): `owner_user_id = auth.uid()`, rol `authenticated` → el `UPDATE accounts SET billing_plan…` del webhook jamás puede impactar.
   - `billing_events` write (`billing_events_admin_write`): solo `authenticated` con `profiles.role='admin'` → el INSERT de auditoría tampoco puede impactar.
5. **Evidencia prod del daño**: `billing_events` contiene exactamente **un** evento `plan_upgraded`, con `reason`:
   > "Reconciliacion manual: pago aprobado en MercadoPago pero el webhook no impacto (notification_url / secret). Honrado por el PO 2026-06-13."
   Es decir: un usuario real pagó, el webhook no impactó y el PO tuvo que acreditar el plan a mano. Cero upgrades automáticos exitosos en toda la historia de la tabla.
6. El backend ya tiene el reemplazo correcto y probado: `backend/routers/payments.py:58` (`POST /payments/webhook`) + `backend/services/payments.py:115-177` (idempotencia por `mercadopago_payment_id`, `UPDATE accounts`, `INSERT billing_events` vía asyncpg con conexión apropiada). El corte de MP hacia ese endpoint (C-17) sigue pendiente, y **la creación de preferencias no existe en el backend** — solo en el route de Next.js, que sigue apuntando el `notification_url` al webhook roto.

### Impacto
Todo upgrade de plan pagado por Checkout Pro desde la UI actual depende de reconciliación manual del PO. Riesgo directo de plata (pagos aprobados sin contraprestación) y de churn en el objetivo comercial de junio 2026.

### Recomendación
Gobernanza CRÍTICA (billing) — solo análisis, sin tocar código sin aprobación humana:
- Opción mínima: en `preferences/route.ts` apuntar `notification_url` al endpoint del backend (`{BACKEND_URL}/payments/webhook`) y retirar el route handler `app/api/billing/webhook` (o dejarlo respondiendo 410).
- Opción completa: mover la creación de preferencias al backend (`/payments/preferences`) y que `PlanComparison` la consuma vía `pythonClient`, cerrando C-17.
- En cualquier caso: verificar el secret HMAC configurado en cada lado y agregar test E2E de flujo webhook→upgrade.

---

## 3. Regla dura "NUNCA any" — violación sistemática (ALTA)

Conteos fuera de `lib/database.types.ts` (generado):

| Patrón | Ocurrencias |
|---|---|
| `: any` | 119 |
| `as any` | 10 |
| `any[]` | 13 |
| `catch (x: any)` | 45 (subconjunto de `: any`) |

Hotspots:
- `lib/adminAnalytics.ts` — 10 (`client?: any` en TODAS las firmas exportadas + `row: any` en maps; líneas 5, 21, 37, 52, 71, 90, 103, 140, 156, 166).
- `app/(dashboard)/admin/cursos/page.tsx` — 8; `app/(dashboard)/admin/analytics/page.tsx` — 7.
- **Páginas core con genérico anulado**: `app/(dashboard)/clientes/page.tsx:53` y `app/(dashboard)/gastos/page.tsx:59` — `usePaginatedQuery<any>({ table: "clients"/"expenses" … })`: las listas principales de clientes y gastos operan sin tipo.
- **Mutaciones al backend casteadas**: `components/forms/client-form.tsx:78,81` — `updateClient({...} as any)` / `addClient(clientData as any)`: anula la validación de tipos justo en la frontera FastAPI.
- `components/forms/sale-form.tsx:399` y `components/forms/purchase-form.tsx:368,400` — `catch (err: any)` en los formularios de dinero (el POS en cambio usa `catch (err: unknown)` correctamente — `app/(dashboard)/ventas/pos/page.tsx:378`).
- `lib/pagination-utils.ts:49` — `type ApplyFilters = (query: any, …) => any` (tipo compartido por todo el sistema de paginación legacy).
- `hooks/use-paginated-query.ts:78` — `usePaginatedQuery<T = any>` con default `any`.
- `lib/supabase/services.ts:6` — `client?: any` (archivo muerto, ver §6).

Nota: `exportToCSV(clients as any[])` en clientes/gastos (`clientes/page.tsx:86`, `gastos/page.tsx:91`).

**Recomendación**: campaña incremental con ESLint `@typescript-eslint/no-explicit-any` en error (hoy no está bloqueando, evidentemente) + `useUnknownInCatchVariables`; empezar por formularios de dinero y `lib/` compartido.

---

## 4. Cliente HTTP y contrato RFC 7807 / paginación (ALTA)

### 4.1 `lib/api/python-client.ts` no consume el contrato RFC 7807

El backend emite problem+json completo (`backend/core/errors.py:23-46`: `type`, `title`, `status`, `detail`, `code` con sqlstates de negocio P04xx, `field` para validación). El cliente:

- `handleResponse` (líneas 25-42) lee **solo `body.detail`** y lanza `new Error(detail)` → **descarta `code`, `field`, `status`, `title`**. La UI no puede: mapear errores de negocio estables (P04xx) a mensajes/acciones, marcar el campo ofensor en formularios, ni distinguir 404/409/422 programáticamente. Los componentes terminan haciendo matching de strings sobre `err.message` (p.ej. `friendlyError` en POS).
- El retry de React Query también se decide por string: `providers/query-provider.tsx:18` — `error.message.includes("No autorizado")` — frágil ante cambio de copy.
- **Sin timeout ni `AbortSignal`**: con Render free tier (cold start ~50s, K10) un fetch puede colgar minutos sin feedback; no hay manejo de despertar del backend (ni ping a `/health` en todo el frontend — grep sin resultados), ni retry con backoff para el caso cold-start.
- Positivo: manejo correcto de 204 (líneas 38-40), header `Idempotency-Key` opcional (líneas 51-61), 401 sin signOut destructivo (líneas 26-31), fail-fast si falta `NEXT_PUBLIC_BACKEND_URL`.

**Recomendación**: clase `ApiError extends Error` con `{status, code, field, title}` parseando problem+json; timeout con `AbortSignal.timeout(…)`; retry/aviso específico para cold start; retry de queries por `status >= 500` en vez de match de string.

### 4.2 Envelope `{items,total,page,pages}` adoptado solo parcialmente

- Adoptado: `use-sales.ts:33-40` y `use-purchases.ts` (`SalesPageResponse`/`PurchasesPageResponse` con paginación server-side real).
- **No adoptado (fetch-all de arrays crudos)**: `use-clients.ts:50` (`ClientApiRow[]`), `use-products.ts:59` (`ProductApiRow[]`), `use-expenses-query.ts:45` (`ExpenseApiRow[]`), `use-quotes.ts:88` (`QuoteApiRow[]`), `use-sales-orders.ts:145` (`SalesOrderApiRow[]`), `use-bank-accounts`, `use-cashboxes`, `use-cost-centers`, etc.
- K13 confirmado: `use-customer-account.ts:114` y `use-supplier-account.ts:121` reciben objeto único sin envelope (decisión de scope explícita, documentada).

Riesgo: catálogos/tenants grandes degradan (transferencia + render completos por visita); dos shapes conviviendo complican la migración a paginación uniforme.

### 4.3 Doble vía de lectura para las mismas entidades

Las páginas de listado **leen directo de Supabase** con `hooks/use-paginated-query.ts` (estado manual `useState`/`useEffect`, fuera de React Query) mientras **mutan vía FastAPI** con hooks React Query:

- `app/(dashboard)/clientes/page.tsx:4,12,44,53` — lee `table: "clients"` directo + `deleteClient` de `useClients` (FastAPI).
- `app/(dashboard)/gastos/page.tsx:14,59` — lee `table: "expenses"` directo.
- `components/ventas/sale-operations-list.tsx:7,55` — la lista de ventas pagina directo de Supabase mientras `useSales` (FastAPI) invalida `queryKeys.sales.*` que esa lista **no escucha**.

Consecuencias: `invalidateQueries` no refresca las listas (coherencia depende de `refetch()` manual — bug latente cada vez que alguien olvide cablearlo), doble contrato de datos por entidad, y el "modelo híbrido" documentado (FastAPI para datos; Supabase solo Auth/Realtime/Storage) no se cumple en las lecturas de listado. Detalle menor de `use-paginated-query.ts:148-150`: el `AbortController` nunca se pasa a la query de Supabase (`.abortSignal()` ausente) — solo evita el setState, no cancela la request.

**Recomendación**: migrar los 3 consumidores de `usePaginatedQuery` a endpoints FastAPI paginados (el patrón ya existe en `use-sales`) y retirar el hook legacy.

---

## 5. Tamaño y complejidad de componentes (MEDIA)

**35 archivos .tsx superan 300 líneas** (33 excluyendo `components/ui/sidebar.tsx` 772 y `components/ui/chart.tsx` 365, vendored de shadcn) — ~14% de los ~230 .tsx del scope. Top:

| Archivo | Líneas | Nota |
|---|---|---|
| `components/products/product-catalog.tsx` | 1032 | agrupa DeleteDialog + helpers + grid + variantes |
| `components/forms/sale-form.tsx` | 785 | estado manual, sin RHF/Zod, carrito + cliente + barcode |
| `components/stock/stock-import-adjustment-dialog.tsx` | 780 | wizard import duplicado (ver §6) |
| `components/settings/FiscalSettings.tsx` | 737 | |
| `app/(dashboard)/ventas/pos/page.tsx` | 727 | hot path dinero; al menos usa catch unknown + idempotency |
| `components/forms/purchase-form.tsx` | 707 | |
| `components/gastos/expense-import-dialog.tsx` | 646 | |
| `components/clientes/client-import-dialog.tsx` | 622 | |
| `app/(dashboard)/admin/cursos/page.tsx` | 609 | + 8 `: any` |
| `components/stock/stock-adjustment-modal.tsx` | 592 | |

Resto >300: LandingPageFull 590, product-import-dialog 573, sale-operations-list 527, data-table 502, stock-movements-panel 471, ReconciliationBoard 468, reportes/comparativo 452, low-stock-alert 444, admin/seguros 424, auth/register 393, admin/feria-ia 383, EmitirSuscripcionDialog 367, purchase-operations-list 366, admin/pagos 363, app-sidebar 360, simulador 359, rentabilidad 350, admin/copilot-ia 349, TeamSection 324, verify-email 324, finanzas/conciliacion 321, gastos 315, product-form 305.

Los formularios de dinero (sale/purchase, 700-800 líneas con estado manual) son los de mayor riesgo de regresión y no tienen test propio (no existe `sale-form.test` ni `purchase-form.test` en `__tests__/`).

---

## 6. Duplicación y código muerto (MEDIA)

### 6.1 Wizards de importación copy-paste
A pesar de existir `lib/import/parser.ts` (usado SOLO por `product-import-dialog.tsx:173`):
- `parseCSVText` duplicado 3×: `client-import-dialog.tsx:74`, `expense-import-dialog.tsx:69`, `stock-import-adjustment-dialog.tsx:153`.
- `StatusBadge` duplicado 3×: `client-import-dialog.tsx:171`, `expense-import-dialog.tsx:197`, `stock-import-adjustment-dialog.tsx:294`.
- `StepIndicator` duplicado 4×: los tres anteriores + `product-import-dialog.tsx:69`.
Cuatro wizards de ~600-780 líneas cada uno con el mismo esqueleto de 3 pasos. Un bug de parsing CSV (comillas, separadores, BOM) hay que arreglarlo en 3 lugares.

### 6.2 Capa de hooks "enterprise" muerta (18 de 23 sin un solo importador)
`hooks/forms/*` (use-autosave, use-form-persist, use-unsaved-changes), `hooks/keyboard/use-command-palette`, `hooks/network/*` (use-online-status, use-polling, use-request-state), `hooks/overlays/*` (use-confirm-dialog, use-drawer, use-modal-stack), `hooks/persistence/use-cookie-state`, `use-session-storage`, `hooks/tables/*` (use-table-filters, use-table-preferences, use-table-selection), `hooks/ui/use-click-outside`, `use-media-query`, `use-mounted`, `use-previous`, `use-throttle`: **0 usos** cada uno. Solo viven: use-persistent-state (4), use-debounce (2), use-hotkeys (1).

### 6.3 Hook duplicado con semántica divergente
- `hooks/use-mobile.tsx` — `useIsMobile()` breakpoint **768** (1 importador).
- `hooks/use-is-mobile.ts` — `useIsMobile(breakpoint = 640)` (1 importador: responsive-modal).
Dos hooks con el mismo nombre exportado y breakpoints distintos → comportamiento responsive inconsistente según qué import se use; además `hooks/ui/use-media-query.ts` (muerto) cubre el mismo caso.

### 6.4 Archivo muerto con acceso legacy
`lib/supabase/services.ts` (102 líneas): **0 importadores**; contiene `createClient` a nivel módulo, `client?: any`, y un `createClient(client: any)` que inserta directo en `clients` bypaseando FastAPI. Debe eliminarse.

### 6.5 Dos sistemas de toast
sonner en 55 archivos vs shadcn `hooks/use-toast.ts` en 3 (`exportaciones/page.tsx`, `ExportButton.tsx`, `ui/toaster.tsx`). Consolidar en sonner.

---

## 7. Convenciones y consistencia (MEDIA)

- **PascalCase (regla del proyecto) incumplida en ~54%**: 87 componentes kebab-case (`product-catalog.tsx`, `sale-form.tsx`…) vs 74 PascalCase (`FiscalSettings.tsx`, `ReconciliationBoard.tsx`…). Los archivos nuevos (V2.5/V3) siguen la regla; el legacy no fue renombrado. Convivencia de estilos dentro del mismo directorio (`components/forms/` kebab vs `components/settings/` Pascal).
- **Stack declarado vs real**:
  - **Zustand 5.x**: declarado en CLAUDE.md/KB §02 y presente en `package.json:72` — **0 usos en el código** (grep sin resultados en app/components/hooks/lib/stores). Dependencia y documentación muertas: el estado global real es React Query + contexts (auth) + useState local.
  - **React Hook Form + Zod**: declarado como estándar de formularios — solo **8 componentes** usan `zodResolver` (BankAccountFormDialog, AdjustStockModal, BranchForm, TransferStockModal, RegisterPaymentForm, FiscalSettings, RegisterPaymentMadeForm…). Los formularios de mayor riesgo (sale-form, purchase-form, product-form, client-form) usan estado manual con validación ad-hoc por toast.
- `console.log` residuales: 17 (más 69 `console.error`, aceptables sin telemetría). No hay Sentry ni telemetría de errores del cliente: los errores de prod solo existen como toasts efímeros — los 500 intermitentes de compras (K5) no dejan traza client-side.
- 0 TODO/FIXME/HACK — higiene notable.

---

## 8. Server vs Client Components y performance (MEDIA/BAJA)

- **52 de 63 `page.tsx` son Client Components** (`"use client"`). El App Router se usa efectivamente como SPA: data fetching 100% client-side vía React Query. Defendible para un dashboard autenticado (y coherente con el modelo híbrido), pero se renuncia a RSC/streaming/prefetch server-side incluso en páginas de solo lectura (reportes). `app/(dashboard)/layout.tsx` sí es Server Component (lee cookie del sidebar para evitar flash — bien).
- **`next/image`: 0 usos; `<img>`: 11 archivos** (incl. `LandingPageFull.tsx` — LCP de la landing sin optimización, avatares sin lazy/resize).
- `providers/query-provider.tsx`: defaults sensatos (staleTime 2min, gcTime 5min, sin retry de mutaciones, singleton browser-safe). Correcto.
- `dangerouslySetInnerHTML` solo en `components/ui/chart.tsx:81` (shadcn vendored, CSS controlado) — sin superficie XSS relevante.

---

## 9. Fortalezas verificadas

1. **Middleware de auth ejemplar** (`lib/supabase/middleware.ts`): `getUser()` server-side con comentario explicando por qué nunca `getSession()` (línea 78-79 — cumple la regla dura), limpieza de cookies ante refresh token stale, gate de email verificado, **enforcement de idle server-side** con decisiones de diseño numeradas y loop-safety, guard de admin server-side por `profiles.role` (líneas 158-170), security headers aplicados a toda respuesta. `contexts/auth-context.tsx` replica la disciplina (getUser documentado línea 75-77, signOut global scope).
2. **Cero `SERVICE_ROLE` en el frontend** (grep sin resultados) — la regla dura se cumple.
3. **Capa de datos moderna bien construida** (`hooks/data/*`, 30 hooks): React Query + `lib/query-keys.ts` centralizado, mapeo snake_case→camelCase tipado por hook, invalidaciones consistentes (`onSettled`/`onSuccess`), tipos de fila API explícitos. `use-sales.ts` es un ejemplo de manual: envelope estándar, `Idempotency-Key` por header (v3-api-standards D4), invalidación cruzada sales+products.
4. **POS (hot path) con las prácticas correctas**: `useIdempotencyKey` per-tab estable a F5, `catch (err: unknown)` + `friendlyError`, gates de caja abierta y permiso de escritura, reset de key post-éxito.
5. **`use-notifications`**: primera suscripción Realtime bien diseñada — documenta que RLS es la garantía y el filter del canal solo optimización (D1), resync por invalidación en reconnect, límite de 20, cleanup con `removeChannel`.
6. **Testing frontend real**: 50 archivos (36 raíz + 13 hooks + 1 lib) cubriendo hooks de datos, auth pages, idle enforcement, billing, conciliación C3, fiscal v22. Faltan los formularios grandes (§5).
7. **Legacy retirado de verdad**: DataContext eliminado (solo 3 menciones en comentarios), feature flags C-18 limpiados (`lib/api/feature-flags.ts` vacío documentado).
8. **`useOrgRole` fail-open documentado** como gate informativo (el enforcement real es `require_role` del backend) — decisión consciente y explicada en el código.

---

## 10. Verificación de known issues (área frontend)

| ID | Estado | Nota |
|---|---|---|
| K4 | NO_EVALUADO | Flag vive en DB/backend. Verificado que el frontend no referencia `sale_items_rpc_v2` (0 hits) — la UI es agnóstica, como diseño. |
| K5 | NO_EVALUADO | Causa backend/Render fuera de scope. Ángulo frontend verificado: el error solo se muestra como toast genérico (`purchase-form.tsx:400-401`) y no hay telemetría client-side (sin Sentry) → los 500 intermitentes no dejan traza. |
| K7 | CONFIRMADO | Frontend consistente con el realign: `product-form.tsx:36,102` edita minStock y `use-products.ts:73,94` lo envía a FastAPI (propagación per-branch delegada al backend). |
| K9 | CONFIRMADO | Frontend usa solo owner/admin/member: `hooks/useOrgRole.ts` (rpc_my_account_role, `isWriter = role !== "member"`, fail-open documentado); `hooks/auth/use-permissions.ts` define permisos granulares pero mapeados a los 3 roles. |
| K10 | CONFIRMADO | Frontend sin mitigación: `python-client.ts` sin timeout/AbortSignal/retry; ningún ping a `/health` en el frontend; primer request tras cold start cuelga sin UX. |
| K13 | CONFIRMADO | `use-customer-account.ts:114` y `use-supplier-account.ts:121` consumen objeto único sin envelope, coherente con la decisión de scope. |
| K16 | CONFIRMADO | Frontend delega audiencia a RLS (`use-notifications.ts` filtra solo por account_id; doc D1 en el propio hook); `branch_id` nullable contemplado en el tipo. |
| K1, K2, K3, K6, K8, K11, K12, K14, K15, K17, K18, K19, K20 | NO_EVALUADO | Dominio DB/backend/CI/PO — fuera de la dimensión frontend. |

---

## 11. Hallazgos completos (ordenados por severidad)

| # | Sev | Título | Evidencia clave |
|---|---|---|---|
| 1 | CRÍTICA | Webhook MP del upgrade roto: preferencia apunta al route Next.js con cliente anon+cookies, RLS bloquea todo; pago real reconciliado a mano por el PO | §2; `preferences/route.ts:85`, `webhook/route.ts:123`, pg_policies prod, `billing_events` prod |
| 2 | ALTA | Regla "NUNCA any" violada ~150× (119 `: any`, 10 `as any`, 13 `any[]`, 45 `catch any`), incl. páginas core y payloads de mutación | §3 |
| 3 | ALTA | pythonClient descarta el contrato RFC 7807 (code/field/status) y no tiene timeout ni manejo de cold start; retry por match de string | §4.1 |
| 4 | ALTA | Doble vía de lectura (Supabase directo vía usePaginatedQuery manual) vs mutación FastAPI para clientes/gastos/ventas → coherencia de caché por refetch manual; envelope estándar solo en sales/purchases | §4.2-4.3 |
| 5 | MEDIA | 33 componentes de producto >300 líneas; formularios de dinero de 700-800 líneas con estado manual y sin tests propios | §5 |
| 6 | MEDIA | Wizards de importación copy-paste (parseCSVText 3×, StatusBadge 3×, StepIndicator 4×) pese a existir lib/import/parser.ts | §6.1 |
| 7 | MEDIA | 18 de 23 hooks genéricos muertos + useIsMobile duplicado con breakpoints 768 vs 640 + lib/supabase/services.ts muerto con acceso legacy | §6.2-6.4 |
| 8 | MEDIA | Convención PascalCase incumplida en 87/161 componentes (54%) | §7 |
| 9 | MEDIA | Stack declarado ≠ real: Zustand 0 usos (dep y doc muertas); RHF+Zod solo en 8 componentes; dos sistemas de toast | §7 |
| 10 | MEDIA | Sin telemetría de errores del cliente (0 Sentry/similar): errores de prod solo como toasts efímeros; agrava K5 | §7 |
| 11 | BAJA | Fetch-all sin paginación en /clients, /products, /expenses, /quotes, /sales-orders | §4.2 |
| 12 | BAJA | 52/63 páginas client-side, next/image 0 usos, `<img>` en 11 archivos (LCP landing); 17 console.log residuales | §8 |

## 12. Deuda técnica priorizada

1. Cortar el webhook MP al backend y retirar los routes de billing de Next.js (CRÍTICO, requiere sign-off PO — dominio billing).
2. `ApiError` tipado problem+json + timeout/cold-start UX en pythonClient.
3. Migrar clientes/gastos/sale-operations-list a endpoints FastAPI paginados y borrar usePaginatedQuery + pagination-utils `any`.
4. Extraer wizard de importación compartido sobre lib/import.
5. Barrido de `any` con lint bloqueante (empezar por forms de dinero y lib/).
6. Purga de hooks muertos + unificar useIsMobile + borrar lib/supabase/services.ts + decidir Zustand (adoptar o quitar de package.json y docs).
7. Descomponer sale-form/purchase-form (y llevarlos a RHF+Zod como los forms nuevos) con tests.
8. Renombrado progresivo a PascalCase (o formalizar excepción para legacy en CLAUDE.md).
9. Telemetría de errores del cliente (Sentry o similar) antes del lanzamiento comercial.
