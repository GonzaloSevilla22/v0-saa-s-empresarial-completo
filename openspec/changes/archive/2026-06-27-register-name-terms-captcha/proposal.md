## Why

El formulario de registro actual ([frontend/app/auth/register/page.tsx](../../../frontend/app/auth/register/page.tsx)) recoge un único campo "Nombre", no pide consentimiento legal explícito, no ofrece opt-in de comunicaciones y no tiene ninguna defensa anti-bots. Esto genera tres problemas concretos para un SaaS con datos fiscales reales (AFIP) y envío de emails:

1. **Datos personales incompletos**: nombre y apellido vienen mezclados en un solo campo, lo que ensucia comunicaciones, comprobantes y la base de clientes. La columna `profiles.last_name` ya existe pero nunca se puebla en el alta.
2. **Sin base legal de consentimiento**: no hay aceptación registrada de Términos ni Política de Privacidad, ni opt-in verificable para notificaciones por email. La Ley argentina 25.326 (Protección de Datos Personales) y las buenas prácticas de consentimiento lo hacen necesario antes de seguir sumando usuarios reales.
3. **Endpoint de signup expuesto a bots**: `supabase.auth.signUp` no tiene captcha; cualquier script puede crear cuentas en masa (spam de tenants, consumo de cuota de email, ensuciado de métricas).

## What Changes

- **Nombre + Apellido**: el formulario separa "Nombre" en dos campos (`nombre` y `apellido`, ambos obligatorios). `register()` propaga `last_name` en el `user_metadata` del `signUp` y el trigger `handle_new_user` lo copia a `profiles.last_name` (la columna ya existe).
- **Checkbox de Términos y Condiciones (obligatorio)**: no se puede crear la cuenta sin aceptarlo. Se registra el consentimiento con timestamp y versión (`terms_accepted_at`, `terms_version`) para trazabilidad legal.
- **Checkbox de notificaciones por email (opcional, desmarcado por defecto)**: opt-in explícito para recibir avisos de cambios/novedades de Aliadata. Se persiste en `profiles.email_notifications_opt_in`.
- **Captcha Cloudflare Turnstile en TODA la auth**: activar el captcha en Supabase es a nivel **proyecto** y aplica a sign-up, login y recuperación de contraseña (confirmado en la doc de Supabase). Por eso el widget de Turnstile se integra en las **tres pantallas** — `/auth/register`, `/auth/login` y `/auth/forgot-password` (y el magic-link/`signInWithOtp` si está activo) — y el token se pasa a la llamada de Supabase correspondiente (`signUp`/`signInWithPassword`/`signInWithOtp`/`resetPasswordForEmail`) vía `options.captchaToken`, que Supabase valida server-side. Cada formulario deshabilita su submit hasta resolver el challenge y resetea el widget tras un fallo. **La activación en el dashboard de Supabase es el último paso del cutover**, hecho junto al deploy que ya tiene el widget en las tres pantallas (si no, login y reset se rompen).
- **Páginas legales nuevas**: Términos y Condiciones (`/legal/terminos`) y Política de Privacidad (`/legal/privacidad`), borrador estándar optimizado para Aliadata (Mendoza, datos fiscales, IA, emails). Públicas, versionadas, enlazadas desde los checkboxes del registro. **Requieren revisión legal del PO antes de considerarse definitivas.**
- **Migración de `profiles`**: columnas aditivas `terms_accepted_at timestamptz`, `terms_version text`, `email_notifications_opt_in boolean NOT NULL DEFAULT false`; y actualización del trigger `handle_new_user` para copiar `last_name` + los tres campos de consentimiento desde `raw_user_meta_data`. Sin backfill: usuarios existentes conservan `last_name` NULL y consentimiento vacío (la obligatoriedad se aplica en el alta, no retroactivamente).

No hay **BREAKING changes**: todos los cambios de DB son aditivos y la firma de `register()` se extiende de forma retrocompatible.

## Capabilities

- `user-registration`: Comportamiento del alta de usuario en el frontend — campos del formulario (nombre, apellido, email, teléfono, localidad, contraseña), validaciones, consentimiento de Términos (obligatorio) y opt-in de email (opcional), y propagación de todos estos datos a `profiles` vía `signUp` metadata + trigger `handle_new_user`.
- `auth-captcha`: Protección anti-bots con Cloudflare Turnstile en TODAS las entradas de auth (registro, login, recuperación de contraseña y magic-link/OTP), validada server-side por Supabase Auth. Incluye el gate del submit, el reseteo del widget tras fallo, la habilitación de la CSP para `challenges.cloudflare.com`, y la secuencia de activación a nivel proyecto.
- `legal-documents`: Páginas públicas de Términos y Condiciones y Política de Privacidad, su versionado, y el registro del consentimiento del usuario (qué versión aceptó y cuándo).

### Modified Capabilities
<!-- Ninguna capability existente cambia sus requisitos. account-tenancy/multi-tenant ya cubren el provisioning del tenant en handle_new_user y NO se modifica su contrato (el trigger se extiende, pero el comportamiento de tenancy queda intacto). -->

## Impact

- **Frontend**
  - `frontend/app/auth/register/page.tsx` — campos nombre/apellido, dos checkboxes, widget Turnstile, validación y deshabilitado del submit.
  - `frontend/app/auth/login/page.tsx` — widget Turnstile; pasa `captchaToken` a `login()`.
  - `frontend/app/auth/forgot-password/page.tsx` — widget Turnstile; pasa `captchaToken` a `resetPasswordForEmail` (este page llama a Supabase directo, sin pasar por el context).
  - `frontend/contexts/auth-context.tsx` — `register()` extiende su firma (`lastName`, `termsVersion`, `emailOptIn`, `captchaToken`) → `options.data` + `options.captchaToken` del `signUp`; `login()` (y `loginWithMagicLink()` si se usa) extienden su firma con `captchaToken` → `options.captchaToken` de `signInWithPassword`/`signInWithOtp`.
  - **Nuevas rutas**: `frontend/app/legal/terminos/page.tsx`, `frontend/app/legal/privacidad/page.tsx` (ya públicas — el middleware protege por allowlist `PROTECTED_PREFIXES` y `/legal` no está en ella; solo verificar).
  - `frontend/lib/supabase/middleware.ts` — **extender la CSP** (`applySecurityHeaders`) para permitir `challenges.cloudflare.com` (`script-src`, `connect-src`, `frame-src`); sin esto el widget de Turnstile queda bloqueado en producción. Governance HIGH (código de seguridad).
  - `frontend/__tests__/RegisterPage.test.tsx` — **test existente que este change rompe** (asserta la firma de `register()` y el label `"Nombre"`); debe actualizarse.
  - Posible exposición de los nuevos campos de consentimiento en el tipo `User` / `lib/types.ts` (opcional, no requerido para el alta).
- **Base de datos (Supabase)**
  - Nueva migración: `ALTER TABLE profiles ADD COLUMN` (3 columnas aditivas) + `CREATE OR REPLACE FUNCTION handle_new_user` (copia `last_name` + consentimiento). Aplicar con `npx supabase db push` (NUNCA el MCP `apply_migration` — regla dura del proyecto). **Governance CRÍTICO: toca el path de signup/auth — requiere aprobación explícita del PO antes de aplicar en producción.**
- **Configuración externa (manual del PO)**
  - Crear cuenta/aplicación en **Cloudflare Turnstile** → obtener *site key* (cliente) y *secret key*.
  - Cargar la *secret key* en el dashboard de Supabase (Auth → Bot and Abuse Protection → Enable Captcha protection → provider: Turnstile).
  - Setear `NEXT_PUBLIC_TURNSTILE_SITE_KEY` en variables de entorno de Vercel (y `.env.local` para dev).
- **Dependencias**
  - Nueva dependencia frontend para el widget (p. ej. `@marsidev/react-turnstile`, el wrapper React mantenido) o el script oficial de Cloudflare.
- **Testing**
  - Tests del formulario (validaciones, checkbox obligatorio, gate de captcha) y del trigger (copiado de `last_name` + consentimiento). Turnstile expone *test keys* oficiales (always-pass / always-fail) para CI.
