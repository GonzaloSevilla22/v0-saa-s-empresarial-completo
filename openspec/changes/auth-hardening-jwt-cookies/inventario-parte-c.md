# Inventario congelado — Parte C (tasks 17.2 y 17.2b)

> Medido el **2026-09-16** sobre `6101d621` (Parte B ya mergeada), rama
> `opsx/auth-hardening-jwt-cookies-apply-c`. Es el inventario **cerrado** que
> exigen las tasks 17.2 / 17.2b: cada entrada lleva su destino, y los candados
> programáticos de 19.7 / 19.7b lo recorren.
>
> **Corrección de conteo respecto del propose.** El propose anunciaba "43
> archivos con `supabase.auth.*` en el navegador". La medición de hoy da **41
> archivos** con al menos una llamada (**32** de navegador + **9** que ya corren
> en el servidor). La diferencia no es un error del propose: es la Parte B, que
> centralizó el armado de encabezados en `lib/api/auth-headers.ts` (D21) y con
> eso retiró el `getSession()` propio de tres archivos que el propose sí contaba
> — `lib/api/python-client.ts`, `lib/api/subscriptions-client.ts` y
> `components/ventas/sale-receipt-button.tsx`. 41 + esos 3 = 44 sitios en el
> árbol previo; el propose midió 43. Se usa la medición de hoy, no el número
> heredado.

Comando de la medición (sin `.venv`/`node_modules`):

```
grep -rn "auth\.\(getUser\|getSession\|signOut\|updateUser\|onAuthStateChange\|signUp\|\
signInWithPassword\|signInWithOtp\|resetPasswordForEmail\|resend\|refreshSession\|\
exchangeCodeForSession\)" --include=*.ts --include=*.tsx app components hooks lib contexts
```

Reparto por operación (55 llamadas): `getUser` ×30, `getSession` ×14,
`signOut` ×5, `updateUser` ×3, `onAuthStateChange` ×2, y ×1 cada uno de
`signUp`, `signInWithPassword`, `signInWithOtp`, `resetPasswordForEmail`,
`resend`, `refreshSession`, `exchangeCodeForSession`.

---

## A. Los 9 que YA corren en el servidor (fuera del alcance de la migración)

Construyen cliente con `@/lib/supabase/server` o con `@supabase/ssr` directo, así
que siguen teniendo `supabase.auth` después de la Parte C. Los candados de 19.7 /
19.7b **no** deben marcarlos.

| Archivo | Llamadas | Destino |
|---|---|---|
| `app/(dashboard)/facturacion/page.tsx` | `getUser` | sin cambios |
| `app/(dashboard)/planes/page.tsx` | `getUser` | sin cambios |
| `app/(dashboard)/planes/success/page.tsx` | `getUser` | sin cambios |
| `app/(dashboard)/ventas/ordenes/[id]/page.tsx` | `getUser` | sin cambios |
| `app/api/ai/copilot/route.ts` | `getUser` | sin cambios |
| `app/api/billing/cancel/route.ts` | `getUser` | sin cambios |
| `app/api/billing/preferences/route.ts` | `getUser` | sin cambios |
| `app/auth/callback/route.ts` | `exchangeCodeForSession` | **18.7**: opciones de cookie compartidas + `resolveSafeRedirect` (ya puesto por la Parte B) |
| `lib/supabase/middleware.ts` | `getUser`, `signOut` | sin cambios (es el refresh server-side gateado por idle) |

## B. Los 32 de navegador, con su destino

### B.1 — Operaciones que crean/modifican/destruyen la sesión → **grupo 18** (este agente)

| Archivo | Llamadas | Destino |
|---|---|---|
| `contexts/auth-context.tsx` | `signInWithPassword`, `signInWithOtp`, `signUp`, `signOut`×2 (`local` y `global`), `updateUser`×2 (contraseña y email) | Server Actions de `app/auth/actions.ts`; la API de `useAuth()` no cambia, así que `/auth/login`, `MagicLinkForm`, `/auth/register` y `components/settings/AccountForm.tsx` conservan su UI |
| `app/auth/forgot-password/page.tsx` | `resetPasswordForEmail` | `requestPasswordResetAction`, dentro del mismo `captchaGate.submit` |
| `app/auth/reset-password/page.tsx` | `updateUser` (contraseña) | `updatePasswordAction` |
| `app/auth/verify-email/page.tsx` | `resend` | `resendVerificationAction` (conserva el cooldown de 30 s en el cliente) |
| `lib/auth/idle-logout.ts` | `signOut` (`local`) | `signOutAction({ scope: "local" })` |

Las cuatro llamadas restantes de `verify-email` (`refreshSession`, `getSession`×2,
`onAuthStateChange`) **no** son del grupo 18: van a `GET /api/auth/status`
(19.4b) y al bus de sesión (20.3).

### B.2 — Identidad (`getUser`) → **grupo 19** (contexto de sesión de la app)

| Archivo | Llamadas | Destino |
|---|---|---|
| `contexts/auth-context.tsx` | `getUser` (`refreshSession()`) | 19.8a |
| `app/(dashboard)/admin/analytics/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/ai/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/clientes/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/compras/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/comunidad/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/cursos/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/gastos/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/simulador/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/stock/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/metricas/ventas/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/pagos/page.tsx` | `getUser` | 19.8d |
| `app/(dashboard)/admin/pagos/ambiguas/page.tsx` | `getUser` | 19.8d |
| `lib/supabase/services.ts` | `getUser`×2 | 19.8b |
| `lib/services/aiCopilotService.ts` | `getUser`×2 | 19.8b |
| `lib/services/fairAdvisorService.ts` | `getUser` | 19.8b |
| `lib/services/invoiceOcrService.ts` | `getUser` | 19.8b |
| `lib/ai/buildBusinessSnapshot.ts` | `getUser` | 19.8b |
| `hooks/data/use-posts.ts` | `getUser` (+ `getSession`×3) | 19.8c — **ojo**: deriva `session.user.id` y lo escribe como columna |

### B.3 — Token (`getSession`) → **grupo 19** (`getAccessToken()` / `getAuthHeaders()`)

| Archivo | Llamadas | Destino |
|---|---|---|
| `lib/api/auth-headers.ts` | `getSession` (en `probeSession()`) | **el punto único** que 19.6/19.8f cambian a `getAccessToken()`; la Parte B ya dejó la nota en el módulo |
| `app/(dashboard)/exportaciones/page.tsx` | `getSession` | 19.8d |
| `app/(dashboard)/rentabilidad/page.tsx` | `getSession` | 19.8d |
| `app/(dashboard)/reportes/comparativo/page.tsx` | `getSession` | 19.8d |
| `app/(dashboard)/simulador/page.tsx` | `getSession` | 19.8d / 19.11 |
| `components/ai/PriceSuggestionModal.tsx` | `getSession` | 19.8d / 19.11 |
| `components/export/ExportButton.tsx` | `getSession` | 19.8d |
| `hooks/data/use-statistics-ai.ts` | `getSession` | 19.8c / 19.11 |
| `hooks/data/use-posts.ts` | `getSession`×3 | 19.8c |

---

## C. 17.2b — los 47 archivos de test que mockean `@/lib/supabase/client`

Medición: `grep -rl "vi.mock(\"@/lib/supabase/client\"" __tests__/` → **47**
archivos (el propose decía 43, misma clase de desfasaje que arriba). De ésos,
**24** exponen `auth` en el doble, y son los únicos que el candado de 19.7b va a
marcar; los otros 23 mockean sólo `from()`/`rpc()`/`channel()` y no codifican
nada del contrato que desaparece.

### C.1 — Los 5 que este grupo 18 migra (su doble cubre una operación que se movió)

| Archivo de test | Ops en el doble | Destino |
|---|---|---|
| `__tests__/auth-context.test.tsx` | `signInWithPassword`, `signInWithOtp`, `signUp`, `getUser`, `onAuthStateChange` | mockea `@/app/auth/actions`; conserva `getUser`/`onAuthStateChange` hasta 19.8a/20.3 |
| `__tests__/lib/auth-context-signout.test.tsx` | `signOut`, `getUser`, `onAuthStateChange` | mockea `signOutAction`; la aserción de alcance (`local` vs `global`) se mantiene, ahora sobre el argumento de la acción |
| `__tests__/ForgotPasswordPage.test.tsx` | `resetPasswordForEmail` | mockea `requestPasswordResetAction` |
| `__tests__/idle-logout.test.ts` | `signOut` | mockea `signOutAction` |
| `__tests__/lib/relogin-after-idle.test.ts` | `signOut` | mockea `signOutAction` |

### C.2 — Los 19 restantes con `auth` en el doble → **grupo 19**

`auth-context-membership.test.tsx` (`getUser`, `onAuthStateChange`) ·
`ComparativoPage.test.tsx` · `ExportacionesPage.test.tsx` ·
`export-button.test.tsx` · `export-button-sonner.test.tsx` ·
`hooks/use-clients-purchases-branches-stock-orgs.test.ts` ·
`hooks/use-courses-community-schema.test.ts` ·
`hooks/use-posts-community-schema.test.ts` · `lib/auth-headers.test.ts` ·
`lib/python-client.test.ts` · `lib/subscriptions-client-auth.test.ts` ·
`pages/report-charts-series-colors.test.tsx` ·
`PriceSuggestionModal.test.tsx` · `RentabilidadPage.test.tsx` ·
`SimuladorPage.test.tsx` · `SucursalReportPage.test.tsx` ·
`SuscripcionesAmbiguasPage.test.tsx` · `use-statistics-ai.test.tsx` ·
`__tests__/pages/reportes-charts-canonicos.test.tsx` (sin `auth`, entra por
cercanía con los otros de reportes — verificar al migrar).

### C.3 — Los 23 sin `auth` en el doble (sólo datos; ningún cambio esperado)

`AdminSegurosPage` · `AdvisorProfilePage` · `AiSummaryCard` ·
`components/stock-import-adjustment-dialog` · `copilotPromptsService` ·
`DashboardCriticalStockCard` · `DashboardReceivablesKpi` · `export-trigger` ·
`fairAiToolsService` · `hooks/use-channel-margin` · `hooks/use-critical-stock` ·
`hooks/use-dashboard-kpi-summary` · `hooks/use-notifications` ·
`hooks/use-org-role` · `hooks/use-paginated-query-extra-filters` ·
`hooks/use-role-catalog` · `hooks/use-team-members` · `insuranceService` ·
`NotificationBell` · `seguros-advisor-profile` · `seguros-click-tracking` ·
`seguros-contact-tracking` · `SegurosIndexPage`.

---

## D. 17.3 — capacidades confirmadas en `node_modules` (no re-derivar)

Versiones instaladas: `@supabase/supabase-js` **2.104.1**,
`@supabase/realtime-js` **2.104.1**, `@supabase/ssr` **0.8.0**, `next`
**16.1.6**, `next-themes` **0.4.6**. Coinciden con lo que asume el design, así
que **no** hay corrección de design pendiente.

Leído en `node_modules/.pnpm/@supabase+supabase-js@2.104.1/.../dist/index.mjs`:

- `applySettingDefaults` conserva `result.accessToken` **sólo** si
  `options.accessToken` está presente (`if (options.accessToken) … else delete
  result.accessToken`).
- Con `accessToken` configurado, `this.auth` es un `Proxy` cuyo `get` **lanza**
  (`accessing supabase.auth.<prop> is not possible`) y `_listenForAuthEvents()`
  **no** se instala. Es la prueba de 19.7 y de por qué `onAuthStateChange`
  desaparece.
- `fetchWithAuth(supabaseKey, this._getAccessToken.bind(this), …)` alimenta
  REST/Storage/Functions y hace `(await getAccessToken()) ?? supabaseKey`: si el
  callback resuelve a vacío, la llamada sale con la anon key. Es la prueba de
  19.5b (el callback **resuelve**, no lanza).
- Realtime recibe `{ accessToken: this._getAccessToken.bind(this) }` **y**
  además un `this.realtime.setAuth(token)` de inicialización con token
  explícito: el pin de 19.9 es real y la renovación debe llamar `setAuth()`
  **sin argumentos**.

## E. 17.4 — sin obstáculos para el nonce

- `grep -rn "next/script\|<Script" app components lib hooks` → **0 hits**.
- `grep -rn "dangerouslySetInnerHTML" app components lib hooks` → **1 hit**,
  `components/ui/chart.tsx:81`, y es un `<style>` (verificado leyendo el JSX):
  cae en `style-src`, no en `script-src`.
