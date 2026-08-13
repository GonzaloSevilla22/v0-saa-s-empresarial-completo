## Why

Tras el cierre de sesión por inactividad el login falla con `captcha protection: request disallowed (timeout-or-duplicate)` y el usuario debe apretar "Iniciar sesión" dos o tres veces. El idle-logout redirige a `/auth/login?reason=idle` con la pestaña normalmente en segundo plano: el widget Turnstile se monta, resuelve solo y emite el token; los tokens de Turnstile son de un solo uso y vencen a los ~300s, pero con la pestaña suspendida los timers no corren, `onExpire` nunca dispara y el formulario queda reteniendo un token muerto con el botón habilitado (`frontend/app/auth/login/page.tsx:133-142`). Cuando el usuario vuelve y envía, Cloudflare rechaza el token por vencido/duplicado. El `catch` actual resetea el widget, por eso el 2º o 3er intento entra — pero el usuario ya vio un error que no cometió. En el login normal no ocurre porque el token siempre es fresco.

## What Changes

- **Frescura por visibilidad (dentro de `CaptchaWidget`)**: el widget registra el instante de emisión (`mintedAt`) de cada token y, al volver la página a `visible`, si el token supera la antigüedad máxima (~2 min) se auto-resetea y notifica al consumidor para que limpie el token viejo. El challenge se re-resuelve mientras el usuario lee la pantalla, de modo que ya hay un token fresco esperando el submit.
- **Guarda de edad al enviar + reintento único**: `CaptchaWidgetHandle` expone la edad/frescura del token y una forma de obtener uno nuevo. Si al enviar el token está viejo se renueva antes de llamar a Supabase; si Supabase igual responde con un error de captcha, se reintenta **una sola vez** con token fresco. Cualquier otro error, o el fallo del reintento, se propaga como error normal.
- **Lógica compartida, no repetida**: la mecánica "renovar si está viejo + un reintento ante error de captcha" vive en un helper único de `frontend/lib/`, consumido por las 4 superficies (regla de reutilización del proyecto). Ninguna pantalla reimplementa el ciclo.
- **Aplica a las 4 superficies que usan `CaptchaWidget`**: login, registro, recuperación de contraseña y `MagicLinkForm`.
- Sin cambios de contrato de API, sin backend, sin migraciones. No se toca `auth-context`, middleware, el flujo de idle-logout ni la configuración server-side de Supabase/Turnstile.

## Capabilities

### New Capabilities
<!-- Ninguna: el comportamiento pertenece a la capability de captcha ya existente. -->

### Modified Capabilities
- `auth-captcha`: se agregan requisitos de **frescura del token** (renovación automática al recuperar visibilidad y guarda de edad al enviar) y se extiende el requisito de reset ante token rechazado con un **reintento automático único** acotado a errores de captcha.

## Impact

- **Código afectado (frontend, cliente)**:
  - `frontend/components/auth/CaptchaWidget.tsx` — registro de `mintedAt`, auto-reset por `visibilitychange`, ampliación de `CaptchaWidgetHandle`.
  - `frontend/lib/` — helper nuevo con la política de frescura y el reintento único (puro y testeable).
  - `frontend/app/auth/login/page.tsx`, `frontend/app/auth/register/page.tsx`, `frontend/app/auth/forgot-password/page.tsx`, `frontend/components/auth/MagicLinkForm.tsx` — pasan a enviar a través del helper.
- **Superficie frontend**: **no se agrega pantalla, ruta ni entrada de menú**. El change modifica el comportamiento de pantallas existentes (`/auth/login`, `/auth/register`, `/auth/forgot-password` y el modo enlace mágico dentro de login); no hay UI nueva que montar, y el único cambio visible es que el botón de envío se deshabilita unos instantes mientras se renueva el challenge.
- **Compatibilidad**: el stub local de Playwright (`NEXT_PUBLIC_PLAYWRIGHT_LOCAL`, `CaptchaWidget.tsx:39-50`) debe seguir comportándose igual (resolver sin red y no bloquear jamás), y la degradación sin `NEXT_PUBLIC_TURNSTILE_SITE_KEY` se mantiene.
- **Tests existentes a preservar**: `frontend/__tests__/CaptchaWidget.test.tsx`, `LoginPage.test.tsx`, `RegisterPage.test.tsx`, `ForgotPasswordPage.test.tsx` (suite base 905 verde).
- **Fuera de alcance / riesgo residual**: la verificación E2E del flujo real de idle-logout contra producción queda como tarea manual del PO (prohibido abrir el navegador contra `/auth/login` de producción — regla dura del proyecto).
