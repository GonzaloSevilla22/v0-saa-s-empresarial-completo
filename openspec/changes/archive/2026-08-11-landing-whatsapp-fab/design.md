## Context

La home pública (`/`) la sirve `frontend/app/page.tsx`, un **Server Component** con `export const dynamic = "force-dynamic"` que lee las secciones editables de la DB y renderiza `<LandingPageFull sections={...} />`. `LandingPageFull` sí es `"use client"` (tiene el menú mobile con `useState`) y contiene toda la landing: Navbar (`fixed top-0 … z-50`), Hero (con `HeroSceneMount` 3D), Stats, Features, Tutoriales, HowItWorks, IA, Pricing, Testimonios, Soporte, CTA final y Footer.

Restricciones y activos que condicionan el diseño:

- **Ya existe lógica canónica de WhatsApp**: `frontend/lib/phone-utils.ts` expone `normalizeWhatsAppPhone()` (formatos AR → `549…`) y `buildWhatsAppUrl(phone, text)` (arma `https://wa.me/<n>?text=…`), usadas hoy por el envío de comprobantes de venta. La regla PO de reutilización obliga a consumirlas, no a reescribirlas.
- **Número confirmado por el PO**: `+54 9 2617 63-5174` → `normalizeWhatsAppPhone` lo resuelve a `5492617635174` (13 dígitos, ya viene con prefijo `549`, camino directo de la línea 43 de `phone-utils.ts`). Verificado contra el código real, no asumido.
- **La landing es de tema oscuro fijo**: `bg-slate-950` y paleta `slate/emerald` hardcodeadas en `LandingPageFull`, previo al design system de tokens. No es dual light/dark.
- **CSP**: `default-src 'self'` con allowlist acotada (`frame-src` solo Turnstile + youtube-nocookie). No hay directiva `navigate-to`.
- **Tokens de motion disponibles**: utilities Tailwind `duration-fast|base|slow` y `ease-standard|emphasized` mapeadas a CSS vars (`tailwind.config.ts` líneas 88-96), más `shadow-elevation-*`.

## Goals / Non-Goals

**Goals:**

- Un punto de contacto por WhatsApp **siempre alcanzable** mientras el visitante recorre la home, sin importar en qué sección esté.
- **Alcance quirúrgico**: la home y nada más. Cero riesgo de que el botón se filtre al dashboard, a auth o a `/landing`.
- **Costo cero cuando no hay número**: si la configuración falta o es inválida, la landing queda exactamente como está hoy.
- **Costo cero de JavaScript**: el botón no debe engordar el bundle de una landing que ya carga una escena 3D.
- Accesible por teclado y lector de pantalla, y usable con el pulgar en mobile.

**Non-Goals:**

- **No** es un widget de chat embebido (WhatsApp Business API, burbuja con conversación dentro del sitio). Es un deep link.
- **No** hay tracking de clics ni analítica del botón en este change.
- **No** se arregla el link "Contacto" muerto del footer ni el resto de `href="#"` de la landing (ver Open Questions).
- **No** se toca `/landing`, ni auth, ni ninguna pantalla del dashboard.
- **No** se rediseña la landing a tokens del design system; el FAB convive con la estética `slate/emerald` existente.
- **No** hay horario de atención, estado "en línea", ni mensajes distintos por sección.

## Decisions

### D1 — Componente propio, sin dependencia de terceros

Se escribe `frontend/components/landing/WhatsAppFab.tsx` a mano.

*Alternativa considerada*: paquetes tipo `react-floating-whatsapp`. **Descartada**: agrega una dependencia de runtime, su propio CSS y su propio JS para lo que aquí es un `<a>` con `position: fixed`; además históricamente arrastran assets externos (avatares, fuentes) que chocarían con `default-src 'self'`. El proyecto ya pagó ese precio con `@next/third-parties` en `tutorial-videos`, donde el CSP bloqueó el embed y hubo que escribir un facade propio.

### D2 — Server Component puro, con variable de entorno **de servidor**

El botón es un **Server Component sin `"use client"`**, montado en `frontend/app/page.tsx` como hermano de `<LandingPageFull />` — no dentro de él.

```tsx
// app/page.tsx (Server Component, ya force-dynamic)
<>
  <LandingPageFull sections={sections} />
  <WhatsAppFab phone={process.env.ALIADATA_WHATSAPP_PHONE} />
</>
```

Rationale:

1. El botón **no necesita JavaScript**: "siempre visible durante el scroll" es `position: fixed` puro, y el hover/press son transiciones CSS. Montarlo dentro de `LandingPageFull` (que es `"use client"`) lo arrastraría al bundle del cliente sin ninguna ganancia.
2. Montarlo en `app/page.tsx` hace el **alcance estructuralmente exclusivo de la home**: no existe forma de que `/landing`, auth o el dashboard lo rendericen por accidente, porque no está en ningún componente compartido.
3. Al leerse en el servidor, la variable **no necesita el prefijo `NEXT_PUBLIC_`** y no queda inlineada en el bundle JS del cliente.

**Desvío declarado respecto de la elección del PO**: el PO eligió "variable de entorno", y la opción proponía el nombre `NEXT_PUBLIC_ALIADATA_WHATSAPP`. Se implementa como **`ALIADATA_WHATSAPP_PHONE`** (sin `NEXT_PUBLIC_`). Es la misma decisión — una variable que se edita en Vercel sin PR — pero mejor ejecutada. Cambiarlo de vuelta a `NEXT_PUBLIC_*` es trivial si el PO lo prefiere por consistencia de nombres.

**Matiz honesto sobre "sin redeploy"**: en Vercel, editar una variable de entorno **no afecta a los deploys ya existentes**. El cambio toma efecto con un *Redeploy* (un click en el dashboard, sin PR ni build de código nuevo). Esto vale tanto para `NEXT_PUBLIC_*` (inlineada en build) como para variables de servidor. La ventaja frente a hardcodear sigue en pie: no hay PR, review ni cambio de código.

*Alternativa considerada*: guardar el número en la tabla de secciones de landing y editarlo desde `/admin/landing`. **Descartada por el PO** en la consulta previa: exige migración + UI de admin para un dato que cambia una vez cada nunca.

### D3 — Validación en el borde y degradación silenciosa

El componente pasa el valor crudo por `normalizeWhatsAppPhone()`. Si devuelve `null` (variable ausente, vacía o número no normalizable) **retorna `null` y no renderiza nada**.

Rationale: `buildWhatsAppUrl()` tiene un fallback deliberado — con teléfono inválido devuelve `https://wa.me/?text=…`, que abre el **selector de contactos** de WhatsApp. Ese fallback es correcto para su uso original (mandarle el comprobante a un cliente cuyo teléfono no cargamos), pero sería un bug de cara al público acá: el visitante tocaría "escribinos a ALIADATA" y WhatsApp le pediría elegir a quién escribirle. Por eso la validación va **antes** de armar la URL, y `buildWhatsAppUrl` se invoca solo con un número ya normalizado.

### D4 — Glifo oficial de WhatsApp como SVG inline

`lucide-react` (el set de íconos del proyecto) **no incluye marcas comerciales**. Se embebe el path oficial del glifo como SVG inline, con `aria-hidden="true"` y `focusable="false"`.

*Alternativa considerada*: reusar `MessageCircle` de lucide, que ya está importado en `LandingPageFull`. **Descartada**: un globo de chat genérico no comunica "esto abre WhatsApp", y la promesa de reconocimiento instantáneo es justamente el valor del canal. *Alternativa considerada*: `<img src="…">` desde `/public`. **Descartada**: request extra y un flash sin ícono; el SVG inline no toca `img-src` ni la red.

Uso nominativo de la marca: el glifo se usa sin alterar forma ni color oficial (`#25D366`), únicamente para señalar el destino del enlace.

### D5 — Color de marca fijo, no token semántico

El fondo del botón es el verde oficial de WhatsApp (`#25D366`), declarado como constante en el componente. **Excepción consciente** a la regla "usar tokens semánticos": el color corporativo de un tercero no puede ser un token del design system propio — semánticamente no es "primary" ni "success", es "WhatsApp". El resto del estilado (radio, elevación, anillo de foco, duraciones) **sí** usa utilities/tokens del proyecto (`shadow-elevation-*`, `duration-fast`, `ease-standard`).

Este es también el motivo por el que la verificación de tema claro/oscuro **no aplica**: la landing es dark-fijo y el verde de marca es invariante. Se declara acá para que la omisión frente a la regla PO sea una decisión y no un olvido.

### D6 — Posición, z-index y jerarquía

`fixed bottom-5 right-5 sm:bottom-6 sm:right-6`, `z-40`, target de **56 × 56 px** (`h-14 w-14`).

- **`z-40`, no `z-50`**: el Navbar de la landing es `fixed … z-50`, y los overlays de shadcn (`dialog`, `sheet`, `drawer`) también viven en `z-50`. Con `z-40` el FAB nunca se superpone a un modal ni compite con la barra superior, y aun así queda por encima de todas las secciones de contenido.
- **56 px** supera el mínimo táctil de 44 px con margen, y es el tamaño estándar de un FAB.
- Esquina inferior derecha: zona del pulgar en mobile y convención universal para este patrón.

### D7 — Accesibilidad del enlace saliente

- `aria-label="Escribinos por WhatsApp (se abre en una pestaña nueva)"` — el destino y el hecho de que abre fuera del sitio se anuncian, no se infieren del ícono.
- `target="_blank"` + **`rel="noopener noreferrer"`** — obligatorio: sin `noopener`, la pestaña destino recibe `window.opener` y puede redirigir la nuestra (*tabnabbing*).
- `focus-visible:ring-2 ring-offset-2` sobre el fondo oscuro de la landing, para que el foco de teclado sea visible.
- El SVG es decorativo (`aria-hidden`); el nombre accesible viene del `aria-label` del `<a>`.

### D8 — Micro-interacción en CSS puro, con respeto por `prefers-reduced-motion`

Hover/focus: `scale-105` + cambio de elevación, con `transition-transform duration-fast ease-standard` (tokens del proyecto). Se degrada con las variantes `motion-reduce:` de Tailwind (`motion-reduce:transition-none`, `motion-reduce:hover:scale-100`).

*Alternativa considerada*: Framer Motion, como en `components/motion/*`. **Descartada**: obligaría a `"use client"` y a cargar la librería, contradiciendo D2, para una transición que CSS resuelve en dos clases. El hook `usePrefersReducedMotion` existente es para animaciones JS; acá alcanza la variante CSS.

### D9 — Mensaje pre-cargado

Constante en el componente: `"Hola ALIADATA 👋 Quiero saber más sobre la plataforma."` — `buildWhatsAppUrl()` ya se encarga del `encodeURIComponent`.

Rationale: la conversación arranca con contexto ("viene de la web") y al visitante le baja la fricción de tener que redactar el primer mensaje.

## Risks / Trade-offs

- **El FAB tapa contenido en mobile** (el CTA final "Empezar Gratis" y el footer son los candidatos) → Tamaño contenido (56 px) y offsets chicos; verificación visual obligatoria a 375 px de ancho recorriendo hasta el final de la página antes del merge (task de QA explícita).
- **La degradación silenciosa esconde un error de configuración**: si el PO escribe mal el número en Vercel, el botón simplemente no aparece y nadie se entera → Es el trade-off elegido a conciencia (mejor invisible que roto). Se mitiga con un test que fija el contrato de normalización con el número real y con una verificación post-deploy en producción listada en `tasks.md`.
- **El número queda expuesto en el HTML público** y es scrapeable por bots de spam → Riesgo aceptado y explícito: es un número comercial de atención, equivalente a publicarlo en el footer o en redes. No es un dato personal del PO ni un secreto.
- **Un cambio de número no toma efecto hasta el Redeploy** → Documentado en D2 y en `.env.example`; es un click en Vercel, sin PR.
- **Uso de marca de terceros** (glifo y color de WhatsApp) → Uso nominativo, sin alterar el glifo, únicamente para identificar el destino del enlace. Es el uso estándar del patrón.
- **Superposición futura con otro elemento flotante** (un widget de cookies, un chat de soporte) → `z-40` y la esquina inferior derecha quedan documentados en `surface-matrix.md` para que el próximo flotante se ubique sabiendo que este existe.

## Migration Plan

Sin migraciones de datos ni de schema. Sin cambios de backend.

**Deploy**
1. Cargar `ALIADATA_WHATSAPP_PHONE = +54 9 2617 63-5174` en Vercel (Production y Preview). Puede hacerse antes del merge: sin el código, la variable no hace nada.
2. Merge del PR a `main` → GitHub Actions dispara build + deploy de Vercel (pipeline existente).
3. Verificación en producción: el botón aparece, el link abre WhatsApp con el número y el mensaje correctos.

**Rollback**
- *Suave, sin tocar código*: borrar la variable en Vercel + Redeploy → el botón desaparece por la degradación de D3, la landing queda idéntica a hoy.
- *Completo*: revertir el PR. La superficie afectada son dos archivos de frontend y no hay estado persistido, así que no hay nada que deshacer más allá del render.

## Open Questions

- **OQ1 — Texto del mensaje pre-cargado**: se propone `"Hola ALIADATA 👋 Quiero saber más sobre la plataforma."`. Si el PO prefiere otro (o ninguno), es cambiar una constante. No bloquea el apply.
- **OQ2 — Nombre de la variable**: `ALIADATA_WHATSAPP_PHONE` (D2) en lugar del `NEXT_PUBLIC_ALIADATA_WHATSAPP` que figuraba en la opción elegida. Si el PO quiere el nombre original, el cambio es de una línea. No bloquea el apply.
- **OQ3 — Links muertos del footer**: la landing tiene ~12 `href="#"` sin destino, incluido "Contacto". Apuntar "Contacto" a este mismo WhatsApp sería coherente, pero es un change aparte — se deja anotado como follow-up, fuera de alcance.
