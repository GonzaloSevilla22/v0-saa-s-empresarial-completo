# Plan de implementación QA — Playwright

> Estado al preservar la base QA: **fundación E2E implementada; revalidación posterior al warm-up pendiente**.
> Este documento nunca debe contener contraseñas, tokens, cookies, JWT, claves ni sesiones.

> ⚠️ **Erratum (2026-08-11)**: dos diagnósticos de este registro quedaron
> refutados al verificarlos contra CI y producción — el "gap real en la
> secuencia de migraciones" (§Drift) era drift de la DB local de esta sesión,
> no de la cadena (CI corrió siempre verde con esos gates; prod ya tenía los
> grants), y la historia de H-1 (§5) era incorrecta (`operation_id` fue
> `NOT NULL` en `20260531230737` y se volvió nullable a propósito en
> `20260804000005` con sign-off del PO; la rama que se sugería revisar ya
> estaba mergeada como PR #247 y era la CAUSA del estado, no su fix). Detalle
> completo en el Erratum de [QA-informe-2026-08-05.md](QA-informe-2026-08-05.md).
> H-1 resuelto en PRs #362/#367/#369 corrigiendo el test, no el schema.

## Reglas de seguridad

- Ejecutar E2E únicamente contra servicios locales.
- Supabase: `http://127.0.0.1:54321`.
- Next.js: `http://localhost:3000`.
- FastAPI: `http://localhost:8000`.
- AFIP/ARCA: adaptador stub.
- Mercado Pago: sandbox, mock o deshabilitado.
- Resend y OpenAI: mock, stub o sin llamadas externas.
- No usar los proyectos Supabase reales o de preview.
- No versionar `.env.test.local`, `e2e/.auth/`, reportes, traces ni capturas.
- Los usuarios QA se documentan sólo como `<QA_TEST_USER>` y
  `<QA_LOGOUT_USER>`; sus credenciales viven únicamente en el entorno local.

## Alcance preservado

La Fase A incorporó:

- `@playwright/test` y scripts `test:e2e*`.
- Chromium como proyecto de navegador.
- Login real por UI en un proyecto `setup`.
- `storageState` local para los specs autenticados.
- Guardia que rechaza URLs no locales y patrones de producción.
- Warm-up best-effort de `/` y `/auth/login`.
- Timeouts para el primer compilado lazy de Turbopack.
- Selectores mínimos `data-testid` en login, logout y KPIs.
- Reporte HTML, trace y screenshot configurados para diagnóstico.

## Archivos de la fundación

- `frontend/playwright.config.ts`
- `frontend/e2e/auth.spec.ts`
- `frontend/e2e/dashboard.spec.ts`
- `frontend/e2e/fixtures/auth.setup.ts`
- `frontend/e2e/fixtures/env-guard.ts`
- `frontend/e2e/fixtures/global-setup.ts`
- `frontend/.env.test.example`
- `frontend/app/auth/login/page.tsx`
- `frontend/components/app-sidebar.tsx`
- `frontend/package.json`
- `pnpm-lock.yaml`
- `.gitignore`

`frontend/next-env.d.ts` fue identificado como generado por Next.js y se
excluyó del cambio QA.

## Cobertura E2E preservada

La colección contiene siete tests:

1. Setup de autenticación y generación de `storageState`.
2. La página inicial carga.
3. Login inválido muestra error.
4. Login válido redirige al dashboard.
5. Ruta protegida sin sesión redirige al login.
6. Logout cierra sesión usando un usuario QA dedicado.
7. Dashboard autenticado carga y muestra el bloque de KPIs.

No había E2E de ventas, compras, stock, clientes, gastos, pagos o facturación.
Playwright tampoco estaba integrado en CI.

## Evidencia histórica

### 16 de junio de 2026

- Entorno: WSL2, Node/pnpm nativos, Docker Desktop integrado.
- Supabase local fue actualizado mediante un `db reset` autorizado en esa
  sesión histórica. Esta acción no debe repetirse sin autorización.
- Resultado confirmado:

  ```text
  7 passed (1.6m)
  ```

- Se detectó que `signOut()` global revoca todas las sesiones del usuario.
  Por eso el test de logout usa `<QA_LOGOUT_USER>` y no el usuario compartido.

### 17 de junio de 2026

- Con servidor frío, `auth.setup.ts` agotó el timeout original de 30 segundos
  mientras Turbopack compilaba `/auth/login`.
- Evidencia preservada en el reporte ignorado: `page.goto` terminó con
  `net::ERR_ABORTED` después del timeout.
- Se elevaron los límites a:
  - test: 90 segundos;
  - navegación: 60 segundos;
  - acciones: 15 segundos;
  - web server: 120 segundos.
- Se agregó warm-up HTTP de `/` y `/auth/login`.
- La ejecución posterior fue interrumpida antes de terminar. Por lo tanto,
  esos ajustes no tenían resultado verde confirmado.

## Entorno requerido

Crear `frontend/.env.test.local` desde el ejemplo y completar localmente:

- `NEXT_PUBLIC_SUPABASE_URL_LOCAL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL`
- `NEXT_PUBLIC_BACKEND_URL_LOCAL`
- `PLAYWRIGHT_BASE_URL`
- `QA_TEST_USER_EMAIL`
- `QA_TEST_USER_PASSWORD`
- `QA_LOGOUT_USER_EMAIL`
- `QA_LOGOUT_USER_PASSWORD`

El archivo local debe permanecer ignorado. El `storageState` se regenera en
cada corrida mediante login UI; no debe reutilizarse una sesión histórica.

## Comandos

Desde `frontend/`:

```bash
pnpm test:e2e
pnpm test
pnpm exec tsc --noEmit
pnpm build
```

Las suites backend y SQL se ejecutan desde sus directorios y sólo después de
confirmar que toda dependencia apunta al stack local.

## Fallos y limitaciones conocidos al preservar

- Revalidación en frío del warm-up: pendiente.
- Los puertos 3000, 8000, 54321 y 54322 estaban cerrados al iniciar la
  preservación.
- El entorno local tenía variables QA requeridas, pero la configuración de
  AFIP stub debía volver a comprobarse antes de cualquier suite fiscal.
- El reporte y trace del 17/06 son artefactos sensibles ignorados; no se
  versionan.
- La documentación histórica del proyecto contiene descripciones desfasadas
  respecto del modelo V2; la auditoría debe distinguir documentación, código y
  runtime.

## Próximos pasos obligatorios

1. Preservar esta fundación en un commit exclusivamente QA.
2. Actualizar `main` por fast-forward desde `origin/main`.
3. Rebasar la rama QA sobre el `main` actualizado sin resolver conflictos de
   forma automática.
4. Revalidar las siete pruebas desde servidor frío.
5. Ejecutar Vitest, pytest, SQL, typecheck y build.
6. Agregar cobertura crítica por aislamiento, ventas, compras, stock, KPIs,
   pagos/fiscalidad con stubs y CI local.
7. Registrar comandos, duración, resultados y bloqueos reproducibles.

## Registro de ejecución actual

Actualizado 2026-08-05. Entorno: Supabase local (Docker, ahora al día con
`main`), `backend/.venv` (Python 3.12), Playwright/Vitest vía pnpm. Nada de
esto tocó producción — el proyecto Supabase real (`gxdhpxvdjjkmxhdkkwyb`) es
distinto del local y no fue consultado ni modificado.

### Drift de migraciones locales (resuelto en esta sesión)

Al recrear el stack Docker (detalle en "Infraestructura local" más abajo), la
última migración aplicada a esta base local era `20260630000001` (30 de junio)
mientras el repo tiene archivos hasta `20260831000001` — **67 migraciones
nunca se habían aplicado** a esta instancia (`stop`/`start` no las re-aplica;
solo `db reset` o `migration up` lo hacen, y el proyecto marca `db reset` como
"no repetir sin autorización" entre sesiones QA).

Con autorización explícita del PO se corrió `supabase migration up`. Encontró
**dos gaps reales en la secuencia de migraciones de `main`** (no drift de este
entorno — cualquier `db reset` fresco, incluido CI, pegaría contra el mismo
muro): dos funciones que dependían únicamente del fallback de `PUBLIC` para el
acceso de `authenticated` (nunca tuvieron un grant propio), y que las
migraciones que finalmente revocan `PUBLIC`/`anon` correctamente (cada una con
su propio gate de verificación) frenaron *antes* de romper el acceso
legítimo — el gate hizo exactamente lo que debía:

- `rpc_admin_business_kpis(timestamptz, timestamptz)` — detectado por el gate
  de `20260824000001_revoke_anon_rest_legit_fns.sql`. Causa raíz (lectura de
  migraciones, sin cambios de por sí): creada en
  [`20260228000400_admin_kpi_metrics.sql`](supabase/migrations/20260228000400_admin_kpi_metrics.sql:4)
  sin ningún `GRANT`/`REVOKE`;
  [`20260517000002_fix_function_search_path.sql:279`](supabase/migrations/20260517000002_fix_function_search_path.sql:279)
  intentó restringir el acceso revocándoselo a `anon` específicamente, pero el
  grant real vivía en `PUBLIC`, no en `anon` — ese revoke nunca tuvo efecto
  real. Auditadas las 26 funciones de esa misma migración vía
  `pg_proc.proacl`: **solo 5 tenían este gap**, todas `rpc_admin_*`
  (`rpc_admin_business_kpis`, `rpc_admin_kpi_overview`,
  `rpc_admin_module_stats`, `rpc_admin_retention_30d`,
  `rpc_admin_weekly_usage_distribution`). Las otras 21 — incluida
  `get_dashboard_financials`, la fuente canónica de KPIs del dashboard de
  cualquier usuario — ya tenían grant propio; nunca estuvieron en riesgo.
- `rpc_close_cash_session(uuid, numeric, text)` — mismo patrón exacto,
  detectado por el gate de `20260826000001_revoke_anon_analyze_bucket.sql`
  (que buscaba preservar `authenticated` en 8 funciones; las otras 7 ya tenían
  grant propio).

**Fix aplicado (autorizado explícitamente por el PO en esta sesión):** dos
migraciones nuevas, chicas y acotadas a otorgar el `GRANT EXECUTE` faltante a
`authenticated` en esas 2 funciones puntuales, posicionadas justo antes de la
migración que las necesitaba:
- [`supabase/migrations/20260823000002_grant_admin_kpi_fns_authenticated.sql`](supabase/migrations/20260823000002_grant_admin_kpi_fns_authenticated.sql)
- [`supabase/migrations/20260825000002_grant_close_cash_session_authenticated.sql`](supabase/migrations/20260825000002_grant_close_cash_session_authenticated.sql)

Con esos dos fixes, `migration up` completó las migraciones restantes sin más
bloqueos. El schema local está ahora al día (`20260831000001`, coincide con el
último archivo en disco).

**Sin verificar todavía (requiere a alguien con acceso a producción real):** si
`20260824000001` / `20260826000001` ya se desplegaron contra producción y
tuvieron el mismo fallo ahí, o si producción tiene estos grants por otra vía no
capturada en migraciones. Las 2 migraciones nuevas viven solo en este working
tree — no están commiteadas; quedan pendientes de decisión (rama separada del
change QA, per convención del proyecto de superficie/scope por change).

### SQL (`supabase/tests/*.sql`, contra Supabase local)

Corrido dos veces: primero contra el schema desactualizado (30/06), de nuevo
después de aplicar las migraciones pendientes. **2 de los 3 hallazgos
originales ya estaban arreglados en `main` — solo faltaba aplicarlos:**

| Archivo | Antes de `migration up` | Después |
|---|---|---|
| `test_kpis_edge_cases.sql` | PASS (7/7) | PASS (7/7) |
| `test_branch_stock.sql` | PASS (12/12) | PASS (12/12) |
| `test_kpis.sql` | FAIL (2 issues) | **PASS** |
| `test_function_acl_gate.sql` | FAIL (12 fns) | **PASS** |
| `test_idempotency.sql` | FAIL (guard `amount>0` faltante) | **FAIL** (hallazgo distinto, ver abajo) |

**Resueltos por `migration up` (ya estaban arreglados en `main`, solo faltaba
aplicarlos a esta base local — dejado en el historial para trazabilidad):**

1. ~~CRÍTICO — overload vulnerable de `get_dashboard_critical_stock(p_user_id uuid)`
   (IDOR sin chequeo de `auth.uid()`)~~. Había sido reintroducido por
   [`20260623000001_c21_checkpoint2_drop_products_stock.sql:98-116`](supabase/migrations/20260623000001_c21_checkpoint2_drop_products_stock.sql:98)
   tras haber sido eliminado por `20260430000007`. Confirmado que el overload
   **ya no existe** tras `migration up` — `test_kpis.sql` pasa
   ("no unexpected overloads") y auditoría directa de `pg_proc` lo confirma.
2. ~~`get_dashboard_critical_stock()` (firma segura) sin guard `min_stock > 0`~~.
   Restaurado — `test_kpis.sql` confirma "contains min_stock > 0 guard".
3. ~~`rpc_create_purchase_operation` sin guard `amount > 0`~~. Resuelto —
   ya no aparece en la salida de `test_idempotency.sql`.
4. ~~12 funciones trigger `SECURITY DEFINER` con EXECUTE expuesto a
   `anon`/`authenticated`~~. Resuelto — `test_function_acl_gate.sql` pasa
   ("sin triggers SECURITY DEFINER expuestos").
5. Gap de grants en `rpc_admin_business_kpis` + 4 hermanas y en
   `rpc_close_cash_session` — resuelto en esta sesión (ver "Drift de
   migraciones locales" arriba).

**Hallazgo restante — `operation_idempotency.operation_id` es nullable.**
`test_idempotency.sql` espera `NOT NULL` (si un replay lee la fila antes de
que se complete el `operation_id`, devolvería un resultado corrupto).
Investigación de solo lectura: la columna es nullable desde su creación
original
([`20260528161955_operation_idempotency.sql:43`](supabase/migrations/20260528161955_operation_idempotency.sql:43)),
sin `NOT NULL` agregado nunca — a diferencia de los otros hallazgos, no parece
una regresión de DROP+CREATE sino una característica original. El índice
parcial del mismo archivo (`WHERE operation_id IS NOT NULL`) sugiere que el
diseño anticipaba un patrón "reservar fila primero, completar `operation_id`
después"; si es así, el gap real sería si una fila puede quedar visible a un
replay *antes* de completarse, no la nullability en sí misma. No se investigó
más a fondo (fuera del alcance pedido esta sesión) — queda como hallazgo
abierto para que el equipo lo evalúe. No se tocó nada.

### Backend Python (pytest)

1261 passed, 3 deselected, 273 warnings (20.11s) — heredado de la sesión QA
anterior; no re-ejecutado en esta sesión.

### Vitest

Corrida completa anterior (8 workers): 92 archivos, 84 passed / 8 failed; 684
tests, 670 passed / 14 failed; 4 errores de arranque de worker. Re-verificado en
esta sesión, en serie (`--no-file-parallelism`), los 6 archivos marcados:
`idle-config.test.ts`, `product-stock.test.ts`, `PlanComparison.test.tsx` y
`c2-bank-payment-routing.test.ts` pasan limpio (eran ruido de paralelismo).
Quedan 2 fallos reales:
- `useCapabilityGate.test.ts`: el primer render devuelve `qualifies=true` en vez
  del default SSR-safe `false` antes de que el efecto resuelva.
- `product-catalog-search-collapse.test.tsx`: timeout de worker (`Failed to
  start forks worker`), coincide con lo ya sospechado (acumulación de DOM).

Falta correr el resto del suite completo en particiones para confirmar si los
otros ~8 fallos originales eran también ruido.

### Playwright

Bloqueado en el entorno del agente por un sandbox que deniega `node.exe`
dentro de `node_modules` (`EACCES` en `lstat`, confirmado con Vitest y con
`react`; PowerShell nativo y Python no están afectados) — el usuario ejecutó
los comandos directamente en su propia terminal (WSL).

Primer intento: timeout de 120s en `config.webServer` (servidor listo en 52s,
pero Turbopack compilando `/` no llegó a responder a tiempo — probable
penalización de I/O de WSL2 accediendo al filesystem de Windows vía `/mnt/c/`).
Se subió el timeout a 240s en `playwright.config.ts` (mismo patrón que la
Evidencia histórica del 17/06, que ya había subido 30s→120s por esto mismo).

Segundo intento, con 240s: el servidor arrancó y compiló bien, pero
`fixtures/auth.setup.ts` falló — el login nunca redirige a `/dashboard`, el
botón queda deshabilitado. Causa real: `POST /auth/v1/token?grant_type=password`
devolvía `500 unexpected_failure` — GoTrue no podía ejecutar el hook
`custom_access_token_hook` porque **la función no existía en la base local**
(drift de migraciones, ver arriba). No era un bug de la app ni del stub de
captcha (que funcionaba bien: el snapshot de fallo mostraba el stub renderizado
correctamente).

Tras resolver el drift, verificado directo contra GoTrue
(`POST /auth/v1/token?grant_type=password` con el usuario QA) →
`HTTP_STATUS:200`. El login por API ya funciona.

Tercer intento (E2E completo, con el timeout de `/dashboard` ya en 60s):
`auth.setup.ts` volvió a fallar, pero esta vez por el **timeout general del
test** (90s, `playwright.config.ts`), no por la aserción — `/auth/login` tardó
28.7s en compilar y no quedó margen para los 60s de espera de `/dashboard`
dentro del mismo test. El botón NO estaba deshabilitado esta vez (a diferencia
del segundo intento): el login se completó del lado del cliente y disparó
`router.push('/dashboard')`, solo que la compilación en frío de esa ruta no
llegó a tiempo.

Cuarto intento (tras `pnpm install --force` para reparar deps faltantes — ver
"Dependencias" abajo): 6/7. `auth.setup.ts` pasó (login → dashboard) con el
timeout de `/dashboard` ya en 150s y el general en 300s. El único fallo fue
`auth.spec.ts › login invalido muestra error`: `fill('login-email')` expiró a
los 15s (`actionTimeout` por defecto) porque el gate de arranque del
auth-context ([`contexts/auth-context.tsx:359`](frontend/contexts/auth-context.tsx:359),
muestra "Loading..." hasta resolver el chequeo inicial de sesión) tardó >15s en
el primer boot en frío del cliente. Su gemelo `login valido` pasó por correr
después, ya caliente. Se subió `actionTimeout: 15_000 → 45_000`.

Quinto intento: **7 passed (4.4m)**. ✅ Suite E2E completa verde desde servidor
frío. Los 7 tests (setup+auth, home, login inválido, login válido→dashboard,
ruta protegida→login, logout, dashboard con KPIs) pasan.

**Ajustes de timeout acumulados en esta sesión** (todos por lentitud del
entorno WSL2 + `/mnt/c/`, NO por bugs de la app):
- `playwright.config.ts`: `webServer.timeout` 120s→240s; `timeout` (general)
  90s→300s; `actionTimeout` 15s→45s.
- `e2e/fixtures/auth.setup.ts`: espera de `/dashboard` 15s→150s.
- `e2e/auth.spec.ts`: 2 esperas de `/dashboard` 15s→60s.

### Dependencias (hallazgo de esta sesión, resuelto)

Al retomar, el dev server falló con `Module not found: Can't resolve 'sonner'`
(importado en `app/layout.tsx`). El paquete estaba declarado
(`package.json:74`) y en el lockfile, pero su symlink en
`frontend/node_modules/` había quedado colgante — un `pnpm install` normal no lo
detectó ("Already up to date"). Se resolvió con `pnpm install --force` (536
paquetes re-verificados; los `ETIMEDOUT` del log eran todos de binarios
opcionales de otras plataformas — macOS/Windows/otras arqs — que este entorno
no necesita). Verificado desde WSL: `require.resolve('sonner')` resuelve al
store de la raíz. (Nota: inspeccionar estos symlinks desde PowerShell/Windows
da falsos negativos — pnpm los crea con semántica WSL sobre `/mnt/c/`; la
verificación válida es desde la propia terminal WSL.)

### typecheck / build

**typecheck: ✅ LIMPIO.** `pnpm -C frontend exec tsc --noEmit` volvió al prompt
sin output (cero errores de tipo en todo el frontend).

**build: ✅ VERDE.** `pnpm -C frontend build` completó tras restaurar la red de
WSL (un reinicio de Windows recompuso la capa NAT/HNS que el reinicio de
`winnat` había roto). Resultado: `✓ Compiled successfully in 54s`,
`✓ Finished TypeScript in 2.6min`, 64/64 páginas estáticas generadas, las 71
rutas de la app compiladas sin errores.

Nota sobre el bloqueo previo (resuelto): el build había fallado en
`next/font/google` al no poder descargar las fuentes Geist/Geist Mono de
`fonts.googleapis.com` — la red saliente de WSL quedó rota tras el reinicio de
`winnat`. Confirmado en su momento: Windows llegaba a Google Fonts (HTTP 200),
WSL no (`curl` vacío, `ping` 100% pérdida, aunque DNS sí resolvía);
`wsl --shutdown` no alcanzó, el daño estaba en la capa NAT de Windows. Un
reinicio de Windows lo resolvió. Nunca fue un defecto de código.

### Infraestructura local (hallazgo de esta sesión, resuelto)

Los contenedores de Supabase local no tenían ningún puerto publicado al host
Windows (`docker port` vacío para `supabase_db` y `supabase_kong`), por una
reserva dinámica de puertos de Windows (Hyper-V/WSL2) que se superponía
exactamente con el bloque 54320-54329. Se resolvió reiniciando el servicio
`winnat` (`net stop winnat` / `net start winnat`, PowerShell como administrador)
y recreando el stack (`supabase stop` + `supabase start`). Los datos persisten
(backup automático de `supabase stop`, no fue un `db reset`).

## Continuidad — pausado 2026-08-05, retomar cuando se pueda

**Estado de la rama**: `qa/playwright-setup`, sin commits nuevos esta sesión.
Nada se pusheó, ni PR, ni deploy. Producción no fue consultada.

**Cambios sin commitear en el working tree** (además del diff QA previo —
CaptchaWidget, env-guard, tests nuevos — que sigue esperando validación
completa antes de decidir el commit):
- `supabase/migrations/20260823000002_grant_admin_kpi_fns_authenticated.sql` (nuevo)
- `supabase/migrations/20260825000002_grant_close_cash_session_authenticated.sql` (nuevo)
- `frontend/playwright.config.ts` (timeouts: `webServer` 120s→240s; general 90s→300s; `actionTimeout` 15s→45s)
- `frontend/e2e/fixtures/auth.setup.ts` (espera `/dashboard` 15s→150s)
- `frontend/e2e/auth.spec.ts` (2 esperas `/dashboard` 15s→60s)
- `backend/.env` (nuevo, gitignorado — no debería commitearse igual)
- `docs/QAimplementation-plan.md` (este archivo)

**Entorno**: Supabase local corriendo, schema al día (`20260831000001`), deps
frontend reparadas (`pnpm install --force`). FastAPI corriendo en background del
lado del agente (puerto 8000) — puede necesitar re-levantarse en una sesión
nueva. Docker Desktop y el servicio `winnat` de Windows sanos.

**Estado de verificación**:
- ✅ SQL (5 tests, 4 pasan, 1 hallazgo abierto — ver arriba)
- ✅ Playwright E2E (7/7 desde servidor frío)
- ✅ Vitest (6 archivos marcados re-verificados; 2 fallos reales pendientes)
- ✅ typecheck (`tsc --noEmit` limpio)
- ✅ build (`next build` verde, 71 rutas, 64/64 páginas)
- ⏳ pytest (heredado de sesión previa: 1261 passed; no re-ejecutado esta sesión)

**Próximo paso**: decisión de commit (ver abajo). Toda la verificación
ejecutable está verde.

**Pendiente de decisión (no de ejecución)**:
1. Confirmar el commit del diff QA + las 2 migraciones de fix + los ajustes de
   timeout de Playwright, una vez que typecheck/build estén verdes. OJO:
   revisar si los timeouts tan altos (específicos de este entorno WSL2 lento)
   deben commitearse tal cual o condicionarse — en CI/Linux nativo son
   excesivos, aunque como techos no rompen nada.
2. Los 2 fallos reales de Vitest (`useCapabilityGate` SSR-safe default;
   `product-catalog-search-collapse` acumulación de DOM) — sin arreglar.
3. `operation_idempotency.operation_id` nullable — hallazgo abierto, sin tocar.
4. Si `20260824000001`/`20260826000001` ya se desplegaron a producción real y
   si tuvieron el mismo fallo de grants ahí (solo alguien con acceso a
   `gxdhpxvdjjkmxhdkkwyb` puede confirmarlo).
5. Correr el resto del suite de Vitest en particiones (92 archivos, solo se
   re-verificaron 6 esta sesión).
6. El informe integral final (falta typecheck/build confirmados).
