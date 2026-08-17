## Why

El fix de `captcha-token-freshness` (PRs #400/#401) eliminó el error `timeout-or-duplicate` tras días de inactividad: al volver la pestaña a visible con un token rancio, el widget lo descarta y re-lanza el challenge solo. El núcleo funciona — el error no reapareció. Pero la renovación es **muda**: el formulario limpia el token, el botón queda `disabled={isLoading || !captchaToken}` sin texto que lo explique, y el click del usuario cae en el vacío. El PO reportó que su login tras días de idle le costó **3 intentos**, y que en el segundo "no pasó nada". El sistema hace lo correcto y el usuario no tiene forma de saberlo.

## What Changes

- **Estado visible de renovación**: mientras el widget está renovando el token (auto-renovación por visibilidad, expiración de Turnstile, error del widget o reset posterior a un submit rechazado), el botón de submit muestra un rótulo compartido tipo "Renovando verificación…" en lugar de quedar mudo. El estado se distingue del arranque en frío (nunca hubo token) — ahí el botón conserva el `disabled` real de hoy.
- **Click encolado**: durante la renovación el botón queda semánticamente deshabilitado (`aria-disabled`) pero clickeable, de modo que la intención del usuario se **encola** y el formulario se envía **una sola vez** apenas llega el token fresco, atravesando `submitWithFreshCaptcha` (la política de frescura + reintento único se conserva intacta). La cola guarda a lo sumo una intención, expira con el timeout de refresco ya existente (`CAPTCHA_REFRESH_TIMEOUT_MS`, 10 s) y no puede disparar un doble submit.
- **Accesibilidad**: el cambio de estado se anuncia por una región `role="status" aria-live="polite"` compartida, porque el cambio de rótulo dentro de un botón no enfocado no se anuncia solo.
- **Una sola implementación, cuatro superficies**: la lógica vive en la capa canónica (extensión de `frontend/lib/captcha-freshness.ts` + un hook de auth que la consume) y la usan las 4 pantallas que montan `CaptchaWidget`: login, registro, recuperación de contraseña y `MagicLinkForm`. Ninguna pantalla reimplementa el ciclo.
- **Stub local de Playwright intacto (D5)**: sin renovación no hay estados nuevos ni cola; la suite E2E ve exactamente el comportamiento de hoy.
- **Sin superficie frontend nueva**: no se agregan pantallas, rutas ni entradas de menú. El change cambia el *feedback* de 4 pantallas ya existentes; la verificación visual va sobre esas mismas pantallas (desktop + mobile, tema claro + oscuro).

Fuera de alcance (congelado por el PO): `auth-context`, middleware, flujo de idle-logout, configuración server-side de Turnstile y cualquier otra pantalla.

## Capabilities

### New Capabilities

Ninguna. El cambio es una extensión de la capability existente.

### Modified Capabilities

- `auth-captcha`: se agregan dos requirements (estado visible de renovación; submit encolado durante la renovación) y se modifican dos existentes — la política compartida entre entry points (ahora cubre también feedback y cola) y la exención del stub local de QA (ahora también exenta de estados de renovación y de cola).

## Impact

- `frontend/lib/captcha-freshness.ts` — capa canónica: rótulo compartido de renovación y la máquina de estados pura de la cola (sin React, testeable en aislamiento). `submitWithFreshCaptcha`, `isTokenStale`, `isCaptchaError` y las constantes quedan sin cambios de comportamiento.
- `frontend/hooks/auth/use-captcha-gate.ts` (nuevo) — hook que ata token, estado de renovación, cola de submit y `submitWithFreshCaptcha`; es el único punto que las 4 pantallas consumen.
- `frontend/components/auth/CaptchaRenewalStatus.tsx` (nuevo, ~10 líneas) — región `aria-live` compartida.
- `frontend/app/auth/login/page.tsx`, `frontend/app/auth/register/page.tsx`, `frontend/app/auth/forgot-password/page.tsx`, `frontend/components/auth/MagicLinkForm.tsx` — pasan a consumir el hook; su lógica de captcha propia se reemplaza, no se duplica.
- `frontend/components/auth/CaptchaWidget.tsx` — **sin props nuevas**: el estado de renovación se deriva de los callbacks `onVerify`/`onExpire`/`onError` que las pantallas ya cablean.
- Tests afectados (safety net): `frontend/__tests__/captcha-freshness.test.ts`, `CaptchaWidget.test.tsx`, `LoginPage.test.tsx`, `RegisterPage.test.tsx`, `ForgotPasswordPage.test.tsx`, `MagicLinkForm.test.tsx`.
- Sin migraciones, sin cambios de backend, sin cambios de CSP.
- Verificación del flujo idle real en producción: **pendiente del PO** (no se automatiza; prohibido abrir el Browser pane contra `/auth/login` de producción).
