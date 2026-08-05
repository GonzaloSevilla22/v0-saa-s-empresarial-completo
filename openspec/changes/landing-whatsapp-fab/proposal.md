## Why

La landing pública (`/`) vende 24/7 pero **no tiene ningún canal de contacto real**: la sección "Soporte" promete "chat instantáneo, respondemos en menos de 5 minutos", y el único link de "Contacto" del footer apunta a `href="#"` (muerto). Un visitante con una duda antes de registrarse no tiene cómo escribirnos, y se va.

WhatsApp es el canal donde ya está el microemprendedor argentino: no requiere instalar nada, no requiere cuenta en ALIADATA, y convierte una duda en una conversación en un toque. Un botón flotante que acompaña todo el scroll es el patrón esperado en este segmento.

## What Changes

- **Nuevo componente `WhatsAppFab`** — botón de acción flotante (FAB), fijo abajo a la derecha, **visible desde el primer píxel y durante todo el scroll** de la landing.
- **Se monta SOLO en la home `/`** (`LandingPageFull`). No aparece en `/landing`, ni en auth, ni en ninguna pantalla del dashboard.
- Al tocarlo abre `https://wa.me/<numero>?text=<mensaje inicial>` en pestaña nueva (`target="_blank"` + `rel="noopener noreferrer"`), con un mensaje pre-cargado del tipo *"Hola ALIADATA, quiero saber más sobre la plataforma"* para que la conversación arranque con contexto.
- **El número vive en una variable de entorno** (decisión PO), no hardcodeado: se cambia editándola en Vercel + Redeploy, sin PR ni cambio de código. Nombre elegido en `design.md` D2: **`ALIADATA_WHATSAPP_PHONE`** (variable de servidor, sin prefijo `NEXT_PUBLIC_`).
- **Degradación silenciosa**: si la variable falta o el número no normaliza a un móvil argentino válido, el botón **no se renderiza**. Nunca se publica un link roto ni un `wa.me/` sin destino.
- **Reutiliza `buildWhatsAppUrl()` / `normalizeWhatsAppPhone()` de `frontend/lib/phone-utils.ts`** — el proyecto ya resuelve normalización AR (549…) y armado de deep link para el envío de comprobantes. No se escribe lógica nueva de teléfonos (regla PO "reutilización antes que repetición").
- **Accesible y responsive**: `aria-label` explícito, target táctil ≥ 44×44 px, foco visible por teclado, sin tapar el CTA final ni el footer en mobile, y respeta `prefers-reduced-motion` en el hover/press.
- Sin cambios de backend, sin migraciones, sin cambios de CSP. **No BREAKING.**

## Capabilities

### New Capabilities
- `landing-whatsapp-contact`: canal de contacto directo por WhatsApp desde la landing pública — visibilidad y alcance del botón flotante, origen y validación del número de destino, comportamiento de degradación cuando no hay número configurado, y garantías de accesibilidad y seguridad del enlace saliente.

### Modified Capabilities
_(ninguna — no cambian requerimientos de specs existentes; `visual-design-system` e `immersive-3d-surfaces` no se tocan)_

## Impact

**Código afectado**
- `frontend/components/landing/WhatsAppFab.tsx` — **nuevo** (Server Component, sin JS de cliente — ver `design.md` D2).
- `frontend/app/page.tsx` — monta `<WhatsAppFab />` junto a `<LandingPageFull />`. Es la **única** superficie que lo renderiza: al no vivir en un componente compartido, no puede filtrarse a otras rutas.
- `frontend/lib/phone-utils.ts` — **reutilizado sin modificar** (`buildWhatsAppUrl`, `normalizeWhatsAppPhone`).
- `frontend/__tests__/components/WhatsAppFab.test.tsx` — **nuevo** (TDD).
- `frontend/.env.example` — documenta `NEXT_PUBLIC_ALIADATA_WHATSAPP`.
- `frontend/docs/surface-matrix.md` — nota en la fila `/` de que la home lleva el FAB de contacto.

**Configuración / operación**
- Nueva env var `ALIADATA_WHATSAPP_PHONE` a cargar en Vercel (Production + Preview). Número confirmado por el PO: **+54 9 2617 63-5174** (normaliza a `5492617635174`). Sin la variable el sitio funciona igual, solo que sin botón.
- El número queda **visible en el HTML público** (es el `href` del enlace). Es información comercial pública —el mismo número que se publicaría en el footer o en redes—, no un secreto: se declara explícitamente para que la exposición sea una decisión y no un descuido.

**Sin impacto en**
- Backend Python, Supabase (sin migraciones, sin RLS, sin RPCs).
- CSP: un `<a>` a `https://wa.me/...` es una navegación top-level, no un `fetch` ni un `iframe`; `default-src 'self'` no la bloquea y no hay `navigate-to` declarada. Igual se verifica en browser real antes del merge (lección de `tutorial-videos`).
- Analítica / IA / billing.

**Superficie frontend** (regla PO 2026-08-02): este change **es** superficie de cara al usuario. Puerta de entrada = la propia home `/`, sin ruta nueva ni entrada de menú. Se verifica en desktop y mobile antes del merge. La landing es de tema oscuro fijo (`bg-slate-950` hardcodeado en `LandingPageFull`), así que la verificación de tema claro/oscuro no aplica a esta superficie — se documenta como excepción consciente en `design.md`.
