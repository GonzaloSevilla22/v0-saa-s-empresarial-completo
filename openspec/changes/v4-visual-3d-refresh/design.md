## Context

El frontend de ALIADATA (Next.js 16 App Router, React 19, TS 5.7, Tailwind + shadcn/ui + Radix) tiene una base sólida pero una ejecución visual inconsistente (auditoría UX/UI: "Mejorable"). Estado actual relevante:

- **Tokens**: `frontend/app/globals.css` define tokens HSL en `:root` y `.dark` (primary verde `142 71% 45%`, radius `0.75rem`, `--success`/`--warning` presentes). Existe `frontend/styles/globals.css` **muerto** (0 importadores). `tailwind.config.ts` **no** registra `success`/`warning`. Hay **883 clases de color hardcodeadas + 43 hex** fuera de `ui/`. La consolidación de tokens base es de `v4-frontend-01`.
- **Dark mode**: ya existe vía `next-themes` (clase `.dark`, `mode-toggle`). El refresh debe cubrir ambos temas.
- **Motion**: no hay librería de animación; `framer-motion` no está instalado. Los estados de carga usan dos spinners distintos.
- **3D**: no existe nada. `next/dynamic` no se usa en ningún lado (auditoría performance P2). No hay `next/image` (11 `<img>` crudos, LCP de landing sin optimizar).
- **CSP** (`frontend/lib/supabase/middleware.ts`): `default-src 'self'`; `script-src 'self' 'unsafe-inline' 'unsafe-eval' …`; `img-src 'self' data: blob: https:`; `worker-src` **no declarado** → hereda `default-src 'self'`. El CSP de prod ya bloqueó embeds de terceros (regla de memoria: verificar todo asset externo contra el CSP).
- **Público objetivo**: microemprendedores de Mendoza, **mobile-first**, celulares de gama media/baja, conectividad intermitente, backend en Render free tier (cold start ~50s). La auditoría de performance marca el bundle/mobile como riesgo.

Este change es la capa visual+3D encima de la Pista 2 de V4. **Constraint dura**: no reimplementar `v4-frontend-01` (tokens base), `v4-frontend-02` (`any`), `v4-frontend-04` (WCAG/axe), `v4-frontend-07` (bundle budget/code-splitting). Reglas de proyecto: **NUNCA `any`**, **PascalCase** en componentes.

## Goals / Non-Goals

**Goals:**
- Elevar la percepción de calidad del producto con un lenguaje visual coherente y con carácter, sin tocar lógica de negocio.
- Introducir 3D decorativo idiomático (R3F) solo en superficies de alto impacto, con guardrails de performance y a11y que sean **requisito de aceptación**, no opcionales.
- Dejar la infraestructura de motion (2D) y 3D reutilizable y tokenizada, para que futuras superficies la adopten sin reinventarla.
- Entregar por fases incrementales: valor visible desde la Fase A (refresh 2D) sin esperar al 3D.

**Non-Goals:**
- 3D en pantallas operativas densas (POS, tablas, listados).
- Rediseño de marca corporativa (logo/identidad) — Open Question del PO.
- Branding por tenant (M-UX-14, otro change).
- Reescribir el registro de tokens base, el gate de `any`, el gate de axe o el bundle budget (viven en `v4-frontend-01/02/04/07`).
- PWA/offline (es `v4-frontend-08`).

## Decisions

### D1 — Tecnología 3D: React Three Fiber + drei (self-hosted)
**Elegido**: `@react-three/fiber` + `@react-three/drei` sobre Three.js.
**Por qué**: idiomático con React 19 / App Router (escenas declarativas como componentes), tree-shakeable, code-splitting trivial con `next/dynamic`, ecosistema `drei` cubre loaders glTF/Draco, `AdaptiveDpr`, `Bounds`, `Environment`, `useGLTF` con caché. Todo el JS es self-hosted (no viola el CSP de scripts de terceros).
**Alternativas**: (a) Three.js imperativo puro → más verboso, peor integración con el ciclo de vida React; (b) `<canvas>` 2D / Lottie → no da profundidad 3D real; (c) Spline / embeds hosteados → viola el CSP y la regla "assets self-hosted"; (d) CSS 3D transforms → insuficiente para escenas ricas. Se descartan.

### D2 — Patrón de carga: nunca en el critical path
El `<Canvas>` de R3F es client-only. Todas las escenas se cargan así:
- `const HeroScene = dynamic(() => import('@/components/three/HeroScene'), { ssr: false, loading: () => <HeroPoster /> })` — **`ssr:false` obligatorio** (WebGL no existe en el server; evita hydration mismatch).
- **Gate de montaje por viewport**: un wrapper `Lazy3DCanvas` usa `IntersectionObserver` y solo monta el `<Canvas>` cuando la superficie entra en viewport; lo desmonta / pausa (`frameloop="demand"` o pausa del render loop) cuando sale, para no gastar GPU/batería fuera de foco.
- `<Suspense>` alrededor de los assets con un **fallback estático** (poster/gradiente) mientras carga el glTF.
- El fallback estático es también el estado final en dispositivos que no califican para 3D (ver D5) — misma imagen, sin costo de WebGL.

### D3 — Estrategia de design system / tokens
- **Fuente única**: extender `app/globals.css` (`v4-frontend-01` ya borra el `styles/globals.css` muerto y registra `success`/`warning` en `tailwind.config.ts`). Este change **añade tokens semánticos de segundo nivel** sobre esa base: escala tipográfica, spacing/ritmo, elevación (sombras), y **tokens de motion** (`--motion-duration-fast/base/slow`, `--motion-ease-standard/emphasized`) en CSS variables, expuestos en `tailwind.config.ts` `theme.extend`.
- **Migración de las 883 clases hardcodeadas**: se hace como parte del refresh visual, superficie por superficie (por fase), mapeando `emerald-*`/`green-*` → `primary`/`success`, `amber-*` → `warning`, `red-*` → `destructive`, `slate-*`/`zinc-*` → `muted`/`foreground`. El gate anti-regresión (lint de color) lo aporta `v4-frontend-01`; este change consume ese lint para no reintroducir hex.
- **Componentes shadcn**: unificar variantes a la API `cva` existente en `components/ui/*`, sin bifurcar componentes. El refresh estiliza vía tokens, no reescribe la librería.

### D4 — Motion: dos motores, un contrato
- **2D**: `framer-motion` para micro-animaciones (entrada de listas/cards con stagger, feedback de estado, hover/press, skeletons, transiciones de página suaves). Envolturas reutilizables en `components/motion/*` (`MotionList`, `FadeIn`, `Celebrate`).
- **3D**: R3F (con `@react-three/drei`; si hace falta animación de cámara/props, `react-spring`/`drei` easing) solo dentro de las escenas.
- **Contrato compartido**: ambos leen los mismos tokens de motion (duraciones/curvas) y ambos respetan `prefers-reduced-motion` a través de un único hook `usePrefersReducedMotion` (SSR-safe). Con reduced-motion: Framer degrada a fundido/nada, y las escenas 3D **no se montan** (se muestra el poster estático).

### D5 — Guardrails de performance y a11y (requisito de aceptación)
Toda superficie 3D debe pasar un **gate de capacidad** antes de montar el `<Canvas>`:
1. `prefers-reduced-motion: reduce` → poster estático, sin 3D.
2. **Mobile / gama baja** → poster estático. Heurística: `matchMedia` de viewport + señales de `navigator.hardwareConcurrency` / `deviceMemory` (con fallback conservador cuando no existan) + `matchMedia('(pointer: coarse)')`. Umbrales documentados en el spec.
3. **Sin WebGL** (detección de contexto `webgl2`/`webgl`) → poster estático.
4. **Save-Data** (`navigator.connection.saveData`) o conexión lenta → poster estático.
- **Presupuesto de bundle**: el chunk 3D (R3F + drei + escena) va 100% detrás de `next/dynamic`; **nunca** entra al first-load JS de rutas no-3D (verificado con el analyzer de `v4-frontend-07`). Presupuesto objetivo: chunk 3D lazy ≤ ~180 KB gz por escena compartida; assets glTF/Draco ≤ ~300 KB por escena.
- **Métricas objetivo**: LCP de landing/auth **no** regresiona respecto de la baseline 2D (el 3D carga después del LCP, detrás del poster que sí puede ser el elemento LCP optimizado con `next/image`); FPS objetivo ≥ 30 en gama media, con `AdaptiveDpr`/`AdaptiveEvents` de drei para degradar resolución antes que frame-rate.
- **Accesibilidad**: la superficie 3D es decorativa → contenedor con `aria-hidden="true"` y sin foco de teclado; toda la información y las acciones existen en el DOM accesible fuera del canvas. El gate de axe (`v4-frontend-04`) debe seguir en 0 violaciones con o sin 3D.

### D6 — Estrategia de assets 3D
- **Formato**: glTF 2.0 con geometría comprimida **Draco** (y texturas **KTX2/Basis** si aplica), self-hosted en `frontend/public/3d/`.
- **Decoders self-hosted**: los decoders de Draco/KTX2 se sirven desde el propio origen (`/public`), no desde el CDN de gstatic por defecto de drei — para respetar `default-src 'self'` del CSP.
- **Posters de fallback**: cada escena tiene un poster estático (WebP/AVIF vía `next/image`) que es a la vez el `loading` de Suspense y el fallback de los dispositivos no aptos.
- **Peso**: modelos low-poly, presupuesto por escena (D5). Preferir geometría procedural/sprites cuando alcance, para evitar descargas.

### D7 — CSP del middleware
Los decoders Draco/KTX2 de R3F usan **Web Workers** instanciados desde blob URLs. El CSP actual no declara `worker-src` → hereda `default-src 'self'`, que **bloquea `blob:` workers**. Ajuste requerido en `frontend/lib/supabase/middleware.ts`:
- Añadir `worker-src 'self' blob:`.
- `img-src` ya incluye `data: blob:` (ok para texturas/canvas). `connect-src 'self'` cubre el fetch de glTF del propio origen (ok).
- No se añade ningún host de terceros. Si en el futuro se decide usar decoders de CDN, sería una decisión de CSP aparte (no en este change).

### D8 — Matriz de clasificación de superficies
Cada pantalla se clasifica y la clasificación vive en el spec:
| Superficie | Clase | Tratamiento |
|---|---|---|
| Landing / hero | `3d` | Escena 3D hero + refresh + micro-animaciones |
| Login / registro | `3d` | Escena 3D de acompañamiento (lateral/fondo) + refresh |
| Onboarding | `3d` | Ilustración 3D por paso + refresh |
| Empty states destacados (dashboard, primeras cargas) | `3d` (ligero) | Objeto 3D pequeño o `2d-motion` según peso |
| Celebración: "venta cerrada" / "meta alcanzada" | `3d` (efímero) | Escena/burst 3D breve, montada on-demand, auto-desmontada |
| POS / venta rápida | `2d-motion` | **Sin 3D**. Refresh + micro-animaciones de feedback |
| Tablas de datos / listados | `refresh-only` / `2d-motion` | **Sin 3D**. Tokens + skeleton animado; animación mínima |
| Formularios densos (venta/compra/gasto/producto/cliente) | `2d-motion` | **Sin 3D**. Refresh + feedback inline (la migración RHF/Zod es `v4-frontend-05`) |
| Reportes / gráficos | `refresh-only` | **Sin 3D**. Tokens; charts siguen `v4-frontend-07` |

Regla: ante duda, degradar a la clase de menor costo. Ninguna pantalla operativa densa sube a `3d`.

### D9 — Tema claro/oscuro
El refresh cubre light y dark (ya soportado por `next-themes`). Las escenas 3D leen el tema activo (`useTheme` de next-themes) para ajustar luces/fondo/materiales, o usan un poster por tema. Contraste de todos los tokens semánticos ≥ WCAG AA (auditoría de contraste la corre `v4-frontend-04`; este change no introduce tokens que la rompan).

## Risks / Trade-offs

- [El bundle 3D infla el first-load y degrada LCP mobile] → `next/dynamic({ssr:false})` + gate de viewport + gate de capacidad (D2/D5); el 3D nunca entra al critical path; verificación con el analyzer/budget de `v4-frontend-07`.
- [WebGL agota batería/GPU en gama baja] → gate de capacidad que sirve poster estático en mobile/gama-baja/sin-WebGL/save-data; `frameloop="demand"`, `AdaptiveDpr`, pausa fuera de viewport.
- [CSP bloquea los workers de Draco en prod (como ya pasó con embeds)] → D7 añade `worker-src 'self' blob:` y self-hostea decoders; se verifica en preview antes de mergear (regla de memoria: probar todo asset contra el CSP).
- [El 3D rompe accesibilidad] → `aria-hidden`, sin foco, experiencia 100% usable sin canvas; gate axe de `v4-frontend-04` debe seguir verde.
- [Migrar 883 clases de color introduce regresiones visuales] → migración por fase/superficie con revisión visual; el lint de color de `v4-frontend-01` evita reintroducción; no se hace en un big-bang.
- [Scope grande sin entregar valor temprano] → plan por fases (A→D); la Fase A (refresh 2D) ya entrega valor sin 3D.
- [`framer-motion` + R3F suman peso de dependencias] → framer es tree-shakeable y liviano para micro-animaciones; R3F va 100% lazy. Bundle budget de `v4-frontend-07` como control.

## Migration Plan

- **Incremental, sin big-bang.** Se despliega por fases (ver tasks.md): A (tokens de motion + refresh base 2D + fundaciones sin 3D), B (infra R3F + guardrails + una escena piloto), C (escenas por superficie de alto impacto), D (pulido/a11y/perf).
- **Feature-safe**: cada superficie 3D degrada a su poster estático; si una escena falla (error boundary de R3F), cae al poster — la app nunca queda en pantalla en blanco.
- **Rollback**: al ser aditivo y detrás de dynamic import + gate, revertir una escena = quitar su import/montaje (o forzar el poster vía flag). El refresh de tokens es CSS/config; rollback por revert del commit.
- **Coordinación**: el CSP (D7) se mergea junto con la primera escena que use Draco, no antes. Los tokens base (`v4-frontend-01`) idealmente aterrizan antes o junto a la Fase A.

## Open Questions

> **Resueltas — sign-off del PO 2026-07-29.** Las 5 quedan cerradas con decisión vinculante; se ejecutan las Fases B→C→D seguidas, sin checkpoint intermedio.

1. **Profundidad del rediseño de marca** — ✅ **RESUELTA (2026-07-29)**: **solo sistema visual**. El logo/identidad de ALIADATA NO se tocan en este change.
2. **Modo oscuro en este change o después** — ✅ **RESUELTA (2026-07-29)**: se **garantizan AMBOS temas** (claro y oscuro) en todo lo que se construya, incluida cada escena 3D (cada escena lee el tema activo — task 3.7). No se difiere el dark mode.
3. **Presupuesto de esfuerzo por fase** — ✅ **RESUELTA (2026-07-29)**: se ejecutan las **4 fases seguidas (B→C→D)**, sin checkpoint de evaluación intermedio entre fases.
4. **La landing 3D, ¿reemplaza la actual?** — ✅ **RESUELTA (2026-07-29)**: el hero 3D es un **bloque sobre la estructura editable existente** (`LandingPageFull`/`HeroSection`); el editor `LandingManager` sigue funcionando intacto. No reemplaza ni convive como variante separada.
5. **Inventario y origen de assets 3D** — ✅ **RESUELTA (2026-07-29)**: **solo geometría procedural/low-poly propia generada por código**. Nada de descargar modelos de librerías externas ni encargos de diseño. Esto simplifica D6: no hay glTF/Draco reales en este change (no hay nada que decodificar); `worker-src 'self' blob:` (D7) se añade igual de forma defensiva/futura-proof porque el guardrail de infraestructura (task 2.7) lo pide explícitamente para cuando existan assets comprimidos, pero no se self-hostean decoders Draco/KTX2 porque no hay geometría comprimida que decodificar todavía.
