## Why

ALIADATA funciona, pero **no se ve como un producto profesional**. La auditoría UX/UI lo clasificó "Mejorable": el design system se ejecuta de forma inconsistente a escala (883 clases de color hardcodeadas + 43 hex fuera de tokens, dos `globals.css` divergentes uno muerto, dos lenguajes de spinner, moneda formateada de tres formas), la accesibilidad es floja (59 botones-ícono, 2 con `aria-label`) y la identidad visual es genérica: shadcn "de fábrica" en verde, sin momento memorable en ninguna superficie. Para un SaaS que sale a captar clientes reales en junio 2026, la primera impresión (landing, registro, onboarding) y los momentos de gratificación (una venta cerrada, una meta alcanzada) son diferenciadores comerciales que hoy no existen. El PO decidió invertir en un **refresh visual completo + animaciones 3D en las superficies de alto impacto** para elevar la percepción de calidad sin tocar la lógica de negocio.

Este change es la **capa VISUAL + 3D encima** de la Pista 2 de la Fase V4 (frontend profesional). No reimplementa los cimientos que ya tienen change propio (`v4-frontend-01` design tokens, `v4-frontend-02` erradicación de `any`, `v4-frontend-04` WCAG AA, `v4-frontend-07` bundle/code-splitting): los **consume y extiende** hacia una identidad visual con carácter.

## What Changes

- **Refresh visual completo del design system en TODA la app** (2D): sobre el contrato de tokens que registra `v4-frontend-01`, definir el *lenguaje visual* — paleta extendida y semántica, escala tipográfica, ritmo de spacing, radios, elevación/sombras, y **tokens de motion** (duraciones, curvas de easing) — y aplicarlo de forma unificada a los componentes shadcn/Radix (cards, botones, inputs, tablas, badges, diálogos). Migrar las clases de color hardcodeadas a tokens semánticos como parte del refresh.
- **Micro-animaciones 2D con Framer Motion** en toda la app: transiciones de entrada de listas/cards, feedback de estados (éxito/error/carga), hover/press states, skeletons animados tokenizados. Respetan `prefers-reduced-motion`.
- **Escenas 3D (React Three Fiber + drei) en superficies de ALTO IMPACTO únicamente**: landing/hero, login/registro, onboarding, empty states destacados, y momentos de celebración ("venta cerrada", "meta alcanzada"). El 3D es **decorativo**.
- **Guardrails de performance y accesibilidad OBLIGATORIOS** para todo lo 3D (ver design.md): lazy-load / `next/dynamic({ ssr:false })` fuera del critical path, respeto de `prefers-reduced-motion`, **fallback estático** (imagen/gradiente) en mobile, gama baja y sin-WebGL, presupuesto de bundle explícito, `<Canvas>` montado solo cuando visible (IntersectionObserver) y pausado fuera de viewport, `aria-hidden` en la superficie 3D y experiencia 100% usable sin ella.
- **Assets 3D self-hosted** (glTF/Draco comprimido, sprites) servidos desde el propio origen, respetando/ajustando el CSP del middleware (que ya bloqueó embeds de terceros antes).
- **Matriz de superficies** que clasifica cada pantalla en: `3d` (alto impacto), `2d-motion` (refresh + micro-animaciones) o `refresh-only` (solo tokens, sin animación pesada). Las **pantallas operativas densas** (POS/venta rápida, tablas de datos, listados) quedan explícitamente en `2d-motion` / `refresh-only` — **NO llevan 3D**.

### Fuera de alcance (Non-Goals)

- **Sin 3D pesado en pantallas operativas densas** (POS, tablas, listados): ahí solo refresh 2D + micro-animaciones.
- **No reescribir lógica de negocio** ni hooks de datos, RPCs, auth, RLS, fiscal ni dinero.
- **No duplicar** el trabajo de `v4-frontend-01/02/04/07`: este change los referencia y construye encima (registro de tokens base, gate de `any`, gate de a11y/axe, bundle budget viven en esos changes).
- **No** rediseño de marca corporativa (logo/identidad) por defecto — queda como Open Question para el PO (ver design.md).
- **No** branding por tenant (eso es M-UX-14, otro change).

## Capabilities

### New Capabilities
- `visual-design-system`: lenguaje visual unificado de ALIADATA — tokens semánticos extendidos (color/tipografía/spacing/radio/elevación/motion) sobre shadcn/Tailwind, estilos de componente unificados, sistema de micro-animaciones 2D (Framer Motion) con respeto de `prefers-reduced-motion`, tema claro/oscuro coherente, y la **matriz de clasificación de superficies** (3d / 2d-motion / refresh-only).
- `immersive-3d-surfaces`: escenas 3D decorativas con React Three Fiber en superficies de alto impacto, gobernadas por **guardrails obligatorios** de performance (lazy-load, bundle budget, montaje por viewport, pausa fuera de foco) y accesibilidad (reduced-motion, fallback estático mobile/gama-baja/sin-WebGL, `aria-hidden`, usable sin 3D), con assets self-hosted compatibles con el CSP.

### Modified Capabilities
<!-- Ninguna: no existen capabilities de spec de design/motion/frontend-visual en openspec/specs/. Los cimientos relacionados (tokens, a11y, bundle) son changes v4-frontend-* aún no archivados como specs, referenciados como dependencias, no modificados aquí. -->

## Impact

- **Dependencias nuevas (frontend)**: `@react-three/fiber`, `@react-three/drei` (3D), `framer-motion` (micro-animaciones 2D). Todas tree-shakeables y cargadas vía code-splitting.
- **Código afectado**: `frontend/app/globals.css` y `frontend/tailwind.config.ts` (extensión del tema/tokens de motion), `frontend/next.config.mjs` (analyzer/budget coordinado con `v4-frontend-07`), `frontend/lib/supabase/middleware.ts` (CSP: `worker-src` para decoders Draco/KTX2 self-hosted), landing (`components/landing/*`, `HeroSection`/`LandingPageFull`), auth (`app/auth/login`, `app/auth/register`), onboarding, empty states y puntos de celebración del POS/dashboard. Componentes nuevos `components/three/*` y `components/motion/*` en PascalCase.
- **Assets nuevos**: `frontend/public/3d/*` (glTF/Draco), sprites/posters de fallback.
- **Performance (riesgo marcado por la auditoría)**: público mobile-first, free-tier, conectividad intermitente → los guardrails de bundle/lazy/fallback son requisito de aceptación, no opcionales. El bundle 3D nunca entra al first-load JS de rutas no-3D.
- **Governance**: MEDIO (frontend/UI puro; no toca auth, dinero, fiscal ni RLS).
- **Relación V4**: parte de la **Pista 2 — Frontend profesional**; consolida/ejecuta la capa visual de **M-UX-02** (design system) y aporta el criterio de motion/a11y de **M-UX-01/M-UX-04**; se coordina con `v4-frontend-01` (tokens), `v4-frontend-04` (WCAG/axe), `v4-frontend-07` (bundle/code-splitting) sin duplicarlos.
