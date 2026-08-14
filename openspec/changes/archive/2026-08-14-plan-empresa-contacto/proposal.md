## Why

Hoy la oferta pública termina en Pro ($69.900/mes, 10 usuarios, 3 sucursales): una empresa que necesita el sistema adaptado a su operación (integraciones, más sucursales, procesos propios) no encuentra ninguna puerta de entrada y se va sin contactarnos. El PO pide un quinto tier **Empresa** que no venda un paquete cerrado sino que abra una conversación: "adaptamos el software a medida" y un CTA que lleve directo al WhatsApp de ALIADATA.

Es un tier de **contacto comercial**, no un plan de facturación: no tiene precio, no tiene checkout y no entra al motor de billing.

## What Changes

- **Card "Empresa"** en las dos superficies de precios: la sección `#pricing` de la landing pública (`/`) y la pantalla de upgrade `/planes` del dashboard. Copy de adaptación a medida + 4 bullets de capacidades enterprise + CTA "Hablemos".
- **CTA que abre WhatsApp** con el número comercial de ALIADATA y un mensaje prellenado específico del tier ("me interesa el plan Empresa"), reutilizando el helper canónico `frontend/lib/aliadata-contact.ts`. El número sigue viniendo de la env var de servidor `ALIADATA_WHATSAPP_PHONE` — nunca hardcodeado, nunca en el bundle de cliente.
- **Extensión del helper canónico** `aliadataWhatsAppUrl(phone, message?)`: mensaje opcional con el actual como default. Es la alternativa a duplicar el armado de la URL en una tercera superficie.
- **Un solo componente compartido** para las dos superficies, con dos variantes visuales (landing dark-only / app theme-aware con tokens semánticos).
- **Degradación explícita**: sin `ALIADATA_WHATSAPP_PHONE` válida, la card no se renderiza en ninguna superficie — mismo criterio que el FAB (un CTA de precios que no lleva a ningún lado es peor que no ofrecerlo).

**NO cambia** (límite duro del change):
- `PLAN_LIMITS` (`frontend/lib/constants.ts`), el tipo `Plan` (`"gratis" | "inicial" | "avanzado" | "pro"`) ni la tabla `plan_limits` de la DB.
- Ninguna migración, RPC, Edge Function ni gating (`get_effective_plan`, `usePlanLimits`, `plan-gating`).
- Ningún KPI de admin: `rpc_admin_business_kpis` deriva MRR de `plan_limits` y de las poblaciones por plan — un quinto plan en DB contaminaría el MRR con un precio inventado.
- El flujo de checkout de `PlanComparison` (MercadoPago, palanca `billing_subscriptions_enabled`) queda intacto: el tier Empresa se monta **al lado** de la grilla, no dentro de ella.

## Capabilities

### New Capabilities
- `enterprise-contact-tier`: el tier Empresa como oferta de contacto directo — presencia y contenido de la card en las superficies de precios, CTA a WhatsApp con mensaje prellenado propio, degradación sin número configurado, y la frontera con el motor de billing (no es un `Plan`, no participa de gating, checkout ni MRR).

### Modified Capabilities
- `landing-whatsapp-contact`: el canal de WhatsApp deja de tener un único mensaje inicial fijo — el helper canónico admite un mensaje por superficie (default = el actual), y la landing suma un tercer consumidor del canal (FAB, link "Contacto" del footer, CTA de la card Empresa).
- `billing-ui`: `/planes` suma una superficie de contacto no comprable debajo del comparativo de 4 planes; se especifica que ese bloque no altera el comparativo, no aparece como "plan actual" y no dispara ningún flujo de pago.

## Impact

**Código afectado (100% frontend, sin backend ni DB):**
- `frontend/lib/aliadata-contact.ts` — parámetro `message` opcional + constante del mensaje del tier Empresa.
- `frontend/components/shared/EnterprisePlanCard.tsx` — **nuevo**, componente compartido con variantes `landing` | `app`.
- `frontend/components/landing/LandingPageFull.tsx` — la sección `Pricing` recibe la URL y monta la card; `LandingPageFull` ya recibe `contactWhatsAppUrl` desde `app/page.tsx`.
- `frontend/app/(dashboard)/planes/page.tsx` — Server Component: lee la env var y monta la card debajo de `PlanComparison`.
- Tests: `frontend/__tests__/lib/aliadata-contact.test.ts` (extendido), `frontend/__tests__/PlanComparison.test.tsx` (safety net, sin cambios esperados), tests nuevos del componente y de ambas superficies.

**No afectado y verificado como tal:** `frontend/lib/constants.ts`, `frontend/lib/types.ts` (`Plan`), `frontend/components/billing/PlanCard.tsx`, `frontend/components/billing/PlanComparison.tsx`, `supabase/migrations/**`, `backend/**`.

**Operativo:** requiere `ALIADATA_WHATSAPP_PHONE` configurada en Vercel (ya lo está para el FAB de producción — a verificar antes del merge, es la misma variable).

**Governance:** MEDIUM — UI adyacente a billing, sin lógica de billing.
