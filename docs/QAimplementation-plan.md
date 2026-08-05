# Plan de implementación QA — Playwright

> Estado al preservar la base QA: **fundación E2E implementada; revalidación posterior al warm-up pendiente**.
> Este documento nunca debe contener contraseñas, tokens, cookies, JWT, claves ni sesiones.

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

Pendiente hasta completar la actualización de `main` y la revalidación.
