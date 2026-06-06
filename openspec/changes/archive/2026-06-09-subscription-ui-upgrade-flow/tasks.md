## 1. Base de datos — Migraciones

- [x] 1.1 Migración SQL: agregar `price_ars_monthly NUMERIC` y `price_ars_annual NUMERIC` a `plan_limits`; seed con precios de RN-03 (Gratis: 0, Inicial: 24900, Avanzado: 34900, PRO: 69900)
- [x] 1.2 Migración SQL: agregar `mercadopago_payment_id TEXT UNIQUE`, `mercadopago_preference_id TEXT`, `amount NUMERIC` a `billing_events`
- [x] 1.3 Migración SQL: agregar `plan_expires_at TIMESTAMPTZ` y `billing_status TEXT DEFAULT 'active'` a `organizations`
- [x] 1.4 Migración SQL: actualizar función de downgrade diario para incluir perfiles con `billing_status = 'cancelling'` y `plan_expires_at < NOW()`

## 2. Configuración y dependencias

- [x] 2.1 Instalar SDK de MercadoPago: `pnpm add mercadopago` (agregado a package.json; ejecutar `pnpm install` manualmente)
- [x] 2.2 Agregar variables de entorno al `.env.local` y documentarlas en `.env.example`: `MERCADOPAGO_ACCESS_TOKEN`, `MERCADOPAGO_WEBHOOK_SECRET`, `NEXT_PUBLIC_APP_URL`
- [x] 2.3 Crear `lib/mercadopago.ts` que inicializa el SDK con `MERCADOPAGO_ACCESS_TOKEN` (singleton server-side)

## 3. API Routes — Backend de billing

- [x] 3.1 Implementar `app/api/billing/preferences/route.ts`: POST recibe `{ plan }`, lee precio de `plan_limits`, crea preferencia en MP con `back_urls` y `notification_url`, retorna `{ preferenceId, initPoint }`
- [x] 3.2 Implementar `app/api/billing/webhook/route.ts`: POST verifica firma HMAC-SHA256, identifica tipo de evento, procesa pago aprobado (UPDATE `organizations.plan`, INSERT `billing_events`), maneja idempotencia por `mercadopago_payment_id`
- [x] 3.3 Implementar `app/api/billing/cancel/route.ts`: POST setea `organizations.plan_expires_at` al vencimiento del período actual, `billing_status = 'cancelling'`, INSERT `billing_events` con `event_type='cancellation_requested'`
- [x] 3.4 Agregar templates de email en Edge Function `send-email`: `plan_upgraded` (con nombre del plan, monto, fecha) y `plan_downgraded` (con motivo y link a `/planes`)
- [x] 3.5 Verificar que el webhook handler inserta en `email_logs` después de actualizar el plan (upgrade y downgrade)

## 4. Componentes UI — Billing

- [x] 4.1 Crear `components/billing/PlanCard.tsx`: recibe `plan`, `currentPlan`, `onSelect`; muestra precio, features principales, CTA dinámico según si es plan actual, superior, o inferior
- [x] 4.2 Crear `components/billing/PlanComparison.tsx`: tabla comparativa completa de los 4 planes; lee precios de `plan_limits` via Server Component; usa `PlanCard` por columna
- [x] 4.3 Crear `components/billing/BillingHistory.tsx`: tabla de `billing_events` con columnas fecha, evento, de→a, monto; vacío si no hay historial
- [x] 4.4 Crear `components/billing/CancelSubscriptionModal.tsx`: modal de confirmación con fecha de vencimiento calculada, botón de confirmar que llama a `/api/billing/cancel`

## 5. Pages — Planes y Facturación

- [x] 5.1 Implementar `app/(dashboard)/planes/page.tsx`: Server Component que lee `plan_limits` y el plan actual del usuario; renderiza `PlanComparison`; maneja el click de CTA (POST a `/api/billing/preferences` → redirect a `initPoint`)
- [x] 5.2 Implementar `app/(dashboard)/planes/success/page.tsx`: muestra confirmación de plan activado, refetch del perfil para mostrar el nuevo plan, botón "Ir al dashboard"
- [x] 5.3 Implementar `app/(dashboard)/planes/failure/page.tsx`: mensaje de error amigable, opción de reintentar, link de soporte por WhatsApp
- [x] 5.4 Implementar `app/(dashboard)/facturacion/page.tsx`: Server Component que lee `organizations` y `billing_events` del usuario; renderiza plan actual, `BillingHistory`, y botón de cancelar (si aplica)

## 6. Integración con CTAs de upgrade existentes

- [x] 6.1 Verificar que todos los `<PlanGateAlert />` existentes apuntan a `/planes` como destino del CTA (ya debería estar en C-02, solo confirmar)
- [x] 6.2 Agregar link a `/planes` en el sidebar (o en el avatar/menú de usuario) para acceso rápido
- [x] 6.3 Agregar link a `/facturacion` en el menú de configuración del usuario

## 7. Tests

- [x] 7.1 Test: webhook con firma válida y pago aprobado → `organizations.plan` actualizado, `billing_events` insertado, `mercadopago_payment_id` presente
- [x] 7.2 Test: webhook con firma inválida → retorna 401, plan sin cambios
- [x] 7.3 Test: webhook duplicado (mismo `mercadopago_payment_id`) → retorna 200 idempotente, sin segundo `billing_events`
- [x] 7.4 Test: cancelación → `billing_status = 'cancelling'`, `plan_expires_at` seteado, plan todavía activo
- [x] 7.5 Test: barrido diario con `plan_expires_at` vencido → plan degradado a `gratis`, `billing_events` insertado
