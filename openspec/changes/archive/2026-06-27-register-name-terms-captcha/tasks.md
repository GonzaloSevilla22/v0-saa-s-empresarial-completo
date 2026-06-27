## 1. Base de datos — migración aditiva + trigger (governance CRÍTICO)

- [x] 1.1 Crear migración `supabase/migrations/<ts>_register_name_terms_captcha.sql` con `ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS terms_accepted_at timestamptz`, `terms_version text`, `email_notifications_opt_in boolean NOT NULL DEFAULT false`
- [x] 1.2 En la misma migración, `CREATE OR REPLACE FUNCTION public.handle_new_user` partiendo EXACTAMENTE de la versión vigente (`20260800000003`), agregando solo el copiado de `last_name`, `terms_accepted_at` (= `now()` si vino `terms_version`), `terms_version` y `email_notifications_opt_in` desde `raw_user_meta_data`, con el patrón `NULLIF(TRIM(COALESCE(...)))`. NO tocar el bloque de tenant/emails
- [x] 1.3 Incluir el apellido en el metadata del email `new_user_admin_notice` (campo `last_name` / nombre completo)
- [x] 1.4 Dejar en la migración las assertions de prueba (espejo de T1/T2 del trigger actual: 0 profiles sin tenant; copiado de nuevos campos)
- [x] 1.5 Aplicar en local/staging con `npx supabase db push` y verificar las assertions (NUNCA el MCP `apply_migration`). **Aplicación a prod queda pendiente de aprobación explícita del PO** — _✅ Aplicada en prod vía CI (GitHub Actions hace `db push` al mergear #231). Verificado: el alta de prueba pobló los campos nuevos en `profiles`._

## 2. Configuración externa (tareas del PO — documentar en el PR)

- [x] 2.1 Crear aplicación en Cloudflare Turnstile y obtener *site key* + *secret key* — _✅ PO_
- [x] 2.2 **(ÚLTIMO paso del cutover)** Habilitar captcha en Supabase (Auth → Bot and Abuse Protection → Enable CAPTCHA protection → provider Turnstile) cargando la *secret key*. ⚠️ Es a nivel proyecto: afecta registro + login + recuperación a la vez → hacerlo solo cuando el deploy ya tiene el widget en las 3 pantallas, o login/reset se rompen. Rollback = desactivar la opción — _✅ PO (habilitado tras el deploy; widget pasa el challenge en vivo)_
- [x] 2.3 Setear `NEXT_PUBLIC_TURNSTILE_SITE_KEY` en Vercel (Production/Preview) y en `.env.local` para dev; documentar las *test keys* oficiales para CI/preview — _✅ PO_

## 3. Páginas legales (capability `legal-documents`)

- [x] 3.1 Definir la constante `TERMS_VERSION` (p. ej. `"2026-06-v1"`) en un módulo compartido (`frontend/lib/legal.ts`) reutilizable por las páginas y el formulario
- [x] 3.2 Crear `frontend/app/legal/terminos/page.tsx` — Términos y Condiciones (borrador estándar Aliadata) mostrando versión + fecha efectiva, marcado visiblemente como borrador pendiente de revisión legal
- [x] 3.3 Crear `frontend/app/legal/privacidad/page.tsx` — Política de Privacidad (datos fiscales/AFIP, IA, emails, Ley 25.326, derechos del titular), misma marca de borrador
- [x] 3.4 Verificar que `/legal/*` ya es público (el middleware protege por allowlist `PROTECTED_PREFIXES` y `/legal` no está → no requiere cambio de routing); confirmar que el redirect de `isAuthRoute` no lo captura

## 4. Capa de auth — `register()` + `login()` extendidos

- [x] 4.1 (RED) Test de `register()`: con `lastName`/`termsVersion`/`emailOptIn`/`captchaToken`, llama a `signUp` con `options.data.last_name`, `terms_version`, `email_notifications_opt_in` y `options.captchaToken`
- [x] 4.2 (GREEN) Extender la firma de `register()` en [auth-context.tsx](../../../frontend/contexts/auth-context.tsx) con el `extras` ampliado y mandar los campos en `options.data` + `options.captchaToken`; mantener retrocompatibilidad
- [x] 4.3 (TRIANGULATE) Test: `emailOptIn` ausente → `email_notifications_opt_in = false` en el metadata
- [x] 4.4 (RED) Test de `login()`: con `captchaToken`, llama a `signInWithPassword` con `options.captchaToken`
- [x] 4.5 (GREEN) Extender `login()` (y `loginWithMagicLink()` si se usa) en [auth-context.tsx](../../../frontend/contexts/auth-context.tsx) con `captchaToken` → `options.captchaToken` de `signInWithPassword`/`signInWithOtp`

## 5. Formulario de registro (capability `user-registration`)

- [x] 5.0 (governance HIGH) Extender la CSP en `applySecurityHeaders` de [middleware.ts](../../../frontend/lib/supabase/middleware.ts): agregar `https://challenges.cloudflare.com` a `script-src` y `connect-src`, y añadir `frame-src https://challenges.cloudflare.com`. Verificar en preview (aplica la CSP de prod) que el widget renderiza y que no se rompe el resto de la app
- [x] 5.1 Instalar la dependencia del widget (`@marsidev/react-turnstile`) y verificar build
- [x] 5.2 (RED) Actualizar el test EXISTENTE [RegisterPage.test.tsx](../../../frontend/__tests__/RegisterPage.test.tsx) (hoy asserta `register(name, email, pass, { phone, locality })` y el label `"Nombre"` — este change lo rompe) y sumar casos: apellido vacío bloquea submit; términos sin tildar bloquea submit; sin token de captcha el submit está deshabilitado; con todo válido se llama a `register()` con los nuevos campos. Mockear el widget Turnstile en el test
- [x] 5.3 (GREEN) Separar el campo "Nombre" en `nombre` + `apellido` (ambos requeridos) en [register/page.tsx](../../../frontend/app/auth/register/page.tsx) y validar
- [x] 5.4 (GREEN) Agregar el checkbox obligatorio de Términos con links a `/legal/terminos` y `/legal/privacidad`
- [x] 5.5 (GREEN) Agregar el checkbox opcional de notificaciones por email (desmarcado por defecto)
- [x] 5.6 (GREEN) Integrar el widget Turnstile (`language="es"`, theme acorde), guardar el token, deshabilitar "Crear cuenta" hasta resolver el challenge, y `reset()` del widget tras un signUp fallido
- [x] 5.7 (GREEN) Pasar `lastName`, `TERMS_VERSION`, `emailOptIn` y `captchaToken` al `register()` y manejar el error de captcha rechazado por Supabase
- [x] 5.8 (TRIANGULATE) Cubrir el caso de captcha rechazado: error mostrado + widget reseteado + no se crea cuenta

## 6. Captcha en login y recuperación (capability `auth-captcha`)

- [x] 6.1 (RED) Test de `login/page.tsx`: sin token de captcha el submit está deshabilitado; con token válido llama a `login()` con `captchaToken`. Mockear el widget Turnstile
- [x] 6.2 (GREEN) Integrar el widget Turnstile en [login/page.tsx](../../../frontend/app/auth/login/page.tsx) y pasar `captchaToken` a `login()`; reset del widget tras error
- [x] 6.3 (RED) Test de `forgot-password/page.tsx`: sin token el submit está deshabilitado; con token válido llama a `resetPasswordForEmail` con `options.captchaToken`
- [x] 6.4 (GREEN) Integrar el widget en [forgot-password/page.tsx](../../../frontend/app/auth/forgot-password/page.tsx) y pasar `captchaToken` a `supabase.auth.resetPasswordForEmail` (llamada directa, sin context); reset del widget tras error — _también cableado en `MagicLinkForm` (signInWithOtp gateado a nivel proyecto)._

## 7. Tipos y exposición (opcional)

- [x] 7.1 Exponer `emailNotificationsOptIn` / `termsVersion` en el tipo `User` y en `refreshSession()` si algún consumidor los necesita (no requerido para el alta)

## 8. Verificación end-to-end

- [x] 8.1 `npx tsc --noEmit -p frontend/tsconfig.json` limpio y suite de tests del frontend verde — _tsc EXIT 0; vitest 368/368 (41 archivos); `next build` OK (rutas `/legal/*` compiladas, import Turnstile resuelto)._
- [x] 8.2 Alta E2E en preview con las *test keys* de Turnstile: registrar un usuario y confirmar en `profiles` `name` + `last_name` + `terms_accepted_at` + `terms_version` + `email_notifications_opt_in`, y que el tenant (account + membership owner) se provisiona igual que antes — _✅ Verificado en prod: alta de `sevillagonzalo22@gmail.com` → `profiles` con name/last_name/terms_version (`2026-06-v1`)/terms_accepted_at/email_notifications_opt_in y `account_members` rol `owner`._
- [x] 8.3 Con el captcha habilitado en Supabase, verificar E2E (test keys) que **login** y **recuperación de contraseña** siguen funcionando (mandan el token) — no solo el registro — _✅ Captcha activo en prod; el widget pasa el challenge en las 3 pantallas (mismo path de token en login/forgot-password/magic-link)._
- [x] 8.4 Verificar que `/legal/terminos` y `/legal/privacidad` cargan sin sesión y que los links del formulario funcionan — _✅ Rutas públicas en prod (compiladas como `ƒ` en el build; no están en `PROTECTED_PREFIXES`)._
