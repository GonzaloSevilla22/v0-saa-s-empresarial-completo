## Context

El alta vive enteramente en el frontend Next.js + Supabase Auth (no pasa por el backend Python):

- [register/page.tsx](../../../frontend/app/auth/register/page.tsx) → `useAuth().register(name, email, password, { phone, locality })` → `supabase.auth.signUp({ options: { data, emailRedirectTo } })`.
- El trigger `handle_new_user` (última versión: [20260800000003_fix_new_user_account_provisioning.sql](../../../supabase/migrations/20260800000003_fix_new_user_account_provisioning.sql), governance CRÍTICO) corre en cada signup: crea el `profiles`, provisiona el tenant (`accounts` + `account_members` como `owner`) y encola los emails de bienvenida y aviso al admin.
- `profiles.last_name` **ya existe** (migración [20260510000001_extend_profiles.sql](../../../supabase/migrations/20260510000001_extend_profiles.sql)); lo leen [auth-context.tsx](../../../frontend/contexts/auth-context.tsx) (`user.lastName`) y `updateProfile`. Solo falta poblarlo en el alta.

Constraint duro del proyecto: las migraciones se aplican con `npx supabase db push` (NUNCA el MCP `apply_migration`), siempre al proyecto real `gxdhpxvdjjkmxhdkkwyb`.

## Goals / Non-Goals

**Goals:**
- Capturar y persistir nombre + apellido por separado en el alta.
- Registrar consentimiento legal auditable (versión + timestamp) de Términos, y un opt-in explícito de email.
- Bloquear bots en todas las entradas de auth (registro, login, recuperación) con un captcha moderno y validado server-side.
- Publicar Términos y Política de Privacidad como páginas públicas, versionadas y enlazadas desde el registro.
- Mantener intacto el comportamiento crítico del trigger (tenant + emails).

**Non-Goals:**
- No se migra el alta al backend Python (sigue siendo Supabase Auth directo — DEC del proyecto).
- No se hace backfill de `last_name` ni de consentimiento para usuarios existentes.
- El captcha cubre TODAS las entradas de auth gateadas por Supabase (registro, login, recuperación de contraseña y magic-link/OTP), porque la activación en Supabase es a nivel proyecto. NO se agrega captcha a flujos no gateados por Supabase (p. ej. un eventual OAuth/Google, que hoy no existe).
- No se construye un sistema de versionado de documentos legales en DB; la versión es un identificador de texto (constante) acordado.
- El texto legal es un **borrador estándar**; la redacción jurídica final es responsabilidad del PO/su asesor.

## Decisions

### D1 — Captcha: Cloudflare Turnstile, validado por Supabase Auth (nativo)
Supabase Auth soporta captcha de forma nativa: se habilita en el dashboard (Auth → Bot and Abuse Protection) con un provider y su *secret key*, y el cliente pasa `options.captchaToken` en `signUp`/`signInWithPassword`. Elegimos **Turnstile** sobre las alternativas:
- **Turnstile (elegido)**: privacy-first, gratis e ilimitado, sin puzzles, soportado nativamente por Supabase. *Site key* pública en el front, *secret key* en el dashboard de Supabase.
- *hCaptcha*: también nativo, pero más fricción visual y menos moderno.
- *reCAPTCHA v3*: NO es nativo en Supabase → exigiría validar el token manualmente en un endpoint propio (más superficie, más mantenimiento). Descartado.

Widget en React: usar `@marsidev/react-turnstile` (wrapper mantenido, SSR-safe) en vez de inyectar el script a mano. El componente expone `onSuccess(token)`, `onError`, `onExpire` y un `ref.reset()` para re-challenge tras un signUp fallido.

### D2 — Consentimiento: columnas en `profiles`, propagadas por el trigger
Persistimos el consentimiento en `profiles`, no en una tabla aparte: es 1:1 con el usuario, simple y consistente con cómo ya se guardan `phone`/`locality`. Columnas aditivas:
- `terms_accepted_at timestamptz` — momento de aceptación (lo setea el trigger con la hora del signup).
- `terms_version text` — versión aceptada (la manda el front en el metadata; constante `TERMS_VERSION`).
- `email_notifications_opt_in boolean NOT NULL DEFAULT false` — opt-in explícito; el default `false` garantiza que un usuario sin dato nunca quede "suscripto" por accidente.

El front manda estos valores en `options.data` del `signUp` y el trigger los copia con el mismo patrón `NULLIF(TRIM(COALESCE(...)))` que ya usa para `name`/`phone`/`locality`. **El trigger se extiende preservando 100% el resto** (tenant + emails): el bloque crítico de provisioning no se toca.

### D3 — Páginas legales: rutas estáticas públicas bajo `/legal`
Dos páginas server-rendered en `frontend/app/legal/terminos/page.tsx` y `frontend/app/legal/privacidad/page.tsx`, contenido como markup estático (sin DB). **Verificado en código**: el middleware ([lib/supabase/middleware.ts](../../../frontend/lib/supabase/middleware.ts)) protege por *allowlist* (`PROTECTED_PREFIXES`), no por denylist — como `/legal` NO está en esa lista (ni en `AUTH_ROUTES`), **ya es público por defecto y no requiere cambio de routing en el middleware**. Solo hay que confirmar que el redirect de `isAuthRoute` (usuario logueado → dashboard) no aplica a `/legal` (no aplica: `/legal` no matchea `AUTH_ROUTES`). La versión mostrada en la página debe coincidir con la constante `TERMS_VERSION` que se guarda en el consentimiento.

### D4 — `register()` retrocompatible
Se extiende el objeto `extras` de `register()` con `lastName`, `termsVersion`, `emailOptIn`, `captchaToken` (campos opcionales en el tipo, obligatorios de hecho en el formulario). Así no rompe a ningún otro caller y mantiene `register` como operación de auth pura (la navegación la sigue manejando la página). **Nota**: el test existente [RegisterPage.test.tsx](../../../frontend/__tests__/RegisterPage.test.tsx) asserta la firma exacta de 4 args (`register("Susana", email, pass, { phone, locality })`) y selecciona el label `"Nombre"`; este change LO ROMPE, así que hay que actualizarlo (no es test nuevo desde cero).

### D5 — CSP del middleware debe permitir Turnstile (gap de seguridad encontrado)
El middleware setea una CSP estricta en `applySecurityHeaders` (líneas ~23-34): `script-src 'self' 'unsafe-inline' 'unsafe-eval'`, sin directiva `frame-src` (cae a `default-src 'self'`), y `connect-src` con Supabase/backend/Resend pero **sin** Cloudflare. El widget de Turnstile carga `https://challenges.cloudflare.com/turnstile/v0/api.js` y **renderiza el challenge dentro de un iframe** de ese dominio, además de hacer fetch a Cloudflare. Con la CSP actual, en producción el script y/o el iframe quedan **bloqueados** y el captcha no aparece. **Fix**: agregar `https://challenges.cloudflare.com` a `script-src`, `connect-src`, y añadir `frame-src https://challenges.cloudflare.com`. Es un cambio en código de seguridad → tratarlo con cuidado (governance HIGH) y verificar que no rompa el resto de la app.

### D6 — Captcha cubre todas las entradas de auth (decisión PO, alcance ampliado)
La opción "Enable CAPTCHA protection" de Supabase es **a nivel proyecto**: una vez activa, exige `captchaToken` en `signUp`, `signInWithPassword`, `signInWithOtp` y `resetPasswordForEmail` (confirmado en la doc). No hay toggle por-endpoint. Por eso el PO decidió (2026-06-26) ampliar el alcance: el widget va en `/auth/register`, `/auth/login` y `/auth/forgot-password`. Implicaciones de implementación:
- `register()` y `login()` (en [auth-context.tsx](../../../frontend/contexts/auth-context.tsx)) extienden su firma con `captchaToken`.
- `/auth/forgot-password` llama a `supabase.auth.resetPasswordForEmail` **directo** (no pasa por el context) → se le agrega el `captchaToken` ahí mismo.
- **Orden de cutover crítico**: activar el captcha en el dashboard de Supabase es el ÚLTIMO paso, junto al deploy que ya tiene el widget en las tres pantallas. Si se activa antes, login y recuperación quedan rotos (envían sin token). Rollback inmediato = desactivar la opción en el dashboard.

## Risks / Trade-offs

- **[CRÍTICO] El trigger toca el path de signup**: un error en `handle_new_user` rompe TODOS los registros (incluido el provisioning del tenant). → Mitigación: el change SOLO agrega copiado de columnas nuevas; el bloque de tenant/emails se deja byte-por-byte igual a la versión vigente. Probar en local/staging y dejar las assertions de prueba (T1/T2 del trigger actual) antes del `db push`. Aprobación explícita del PO antes de aplicar en prod.
- **Config externa fuera del código**: si Turnstile no se habilita en el dashboard de Supabase, o falta `NEXT_PUBLIC_TURNSTILE_SITE_KEY`, el signUp puede romperse o el widget no renderiza. → Mitigación: documentar el setup como tarea explícita del PO; usar las *test keys* oficiales de Turnstile en CI/preview; degradar con mensaje claro si falta la env var.
- **[Encontrado en re-review] CSP bloquea el widget en prod**: la CSP del middleware no permite `challenges.cloudflare.com` (sin `frame-src`, sin Cloudflare en `script-src`/`connect-src`). En dev puede "funcionar" si el navegador es laxo, pero en prod el iframe del challenge se bloquea silenciosamente. → Mitigación: ver D5; probar en preview (que sí aplica la CSP de producción), no solo en local.
- **Texto legal sin valor jurídico hasta revisión**: publicar T&C/Privacidad genéricos puede dar falsa sensación de cobertura. → Mitigación: marcar visiblemente "borrador" en el artefacto/PR y bloquear el merge a prod hasta el OK del PO; el versionado permite actualizar sin perder consentimientos previos.
- **Fricción en el alta**: más campos + captcha pueden bajar la conversión. → Trade-off aceptado: apellido y consentimiento son requisitos de negocio/legales; Turnstile es de baja fricción (normalmente invisible).
- **Localización del widget**: Turnstile debe renderizar en es-AR y respetar el tema (dark/light) del registro. → Mitigación: pasar `language="es"` y `theme` al widget.

## Migration Plan

1. **DB (staging primero)**: nueva migración aditiva — `ALTER TABLE profiles ADD COLUMN IF NOT EXISTS` (3 columnas) + `CREATE OR REPLACE FUNCTION handle_new_user` (versión vigente + copiado de los 4 campos). Aplicar con `npx supabase db push`. Correr las assertions T1/T2 del trigger.
2. **Config externa (PO)**: crear app Turnstile, cargar *secret key* en Supabase (Auth → Captcha → Turnstile), setear `NEXT_PUBLIC_TURNSTILE_SITE_KEY` en Vercel + `.env.local`.
3. **Frontend**: dependencia del widget, formulario (nombre/apellido + 2 checkboxes + Turnstile), `register()` extendido, páginas legales, ajuste de middleware para `/legal/*` público.
4. **Verificación**: tests de formulario y de trigger; alta E2E de prueba en preview con las test keys; confirmar perfil con `last_name` + consentimiento y tenant provisto.
5. **Prod**: aprobación del PO (governance CRÍTICO) → `db push` a `gxdhpxvdjjkmxhdkkwyb` → deploy Vercel.

**Rollback**: la migración es aditiva; restaurar `handle_new_user` a la versión de `20260800000003` revierte el comportamiento del trigger sin tocar datos. Las columnas nuevas pueden quedar (inertes) o dropearse aparte. El frontend se revierte con el deploy anterior.

## Open Questions

- **Versión de términos**: ¿qué identificador usamos para `TERMS_VERSION` (p. ej. `"2026-06-v1"` o `"1.0"`)? Propuesta: fecha + número de revisión.
- **Email del opt-in**: ¿qué sistema consume `email_notifications_opt_in` para mandar las novedades? Hoy existe `email_logs` + webhook Resend; definir si las novedades reusan ese pipeline o uno nuevo (probablemente fuera de alcance de este change).
- **¿Aviso al admin incluye apellido?**: el `new_user_admin_notice` actual manda `name`; conviene incluir el apellido en el metadata del email (decisión menor, se resuelve en apply).
