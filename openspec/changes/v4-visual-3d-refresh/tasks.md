# Tasks — v4-visual-3d-refresh

> Plan por fases incrementales (A→D). Cada fase entrega valor sin depender de la siguiente: la Fase A ya profesionaliza la app sin 3D; el 3D empieza en la Fase B con una escena piloto y se expande en la C.
> Prerequisito de coordinación: los tokens base los registra `v4-frontend-01`; el gate de `any`, `v4-frontend-02`; el gate de axe/contraste, `v4-frontend-04`; el bundle budget/analyzer, `v4-frontend-07`. Este change consume esos gates, no los reimplementa. Reglas de proyecto: NUNCA `any`; componentes en PascalCase.

## 1. Fase A — Fundaciones visuales y refresh 2D (sin 3D)

- [x] 1.1 Definir la matriz de clasificación de superficies (3d / 2d-motion / refresh-only) como documento vivo en `frontend/docs/surface-matrix.md`, con cada ruta del App Router clasificada; confirmar que POS, tablas y listados quedan en 2d-motion/refresh-only
- [x] 1.2 Añadir tokens de motion (`--motion-duration-fast/base/slow`, `--motion-ease-standard/emphasized`) en `app/globals.css` (`:root` y `.dark`) y exponerlos en `tailwind.config.ts theme.extend` (transitionDuration/transitionTimingFunction)
- [x] 1.3 Añadir tokens semánticos de elevación/sombra y escala tipográfica del refresh en `app/globals.css` + `tailwind.config.ts`, verificando que no dupliquen los base de `v4-frontend-01`
- [x] 1.4 Documentar el contrato de tokens del refresh (token → uso → tema claro/oscuro) en `frontend/docs/design-tokens.md` (extendiendo el de `v4-frontend-01` si ya existe)
- [x] 1.5 Instalar `framer-motion` y crear las envolturas reutilizables en `components/motion/` (`FadeIn.tsx`, `MotionList.tsx` con stagger, `Celebrate.tsx`), en PascalCase y sin `any`
- [x] 1.6 Crear el hook SSR-safe `hooks/ui/usePrefersReducedMotion.ts` y cablearlo en las envolturas de `components/motion/` para degradar a fundido mínimo/nulo
- [x] 1.7 Escribir tests (Vitest) de las envolturas de motion: animan con tokens cuando no hay reduced-motion, y degradan cuando `prefers-reduced-motion: reduce`
- [x] 1.8 Aplicar el refresh de tokens a los componentes base shadcn/Radix vía `cva` (Button, Card, Input, Badge, Dialog, Table) sin bifurcar componentes de `components/ui/`
- [x] 1.9 Migrar las clases de color hardcodeadas a tokens semánticos en las superficies `refresh-only`/`2d-motion` de mayor tráfico (dashboard, ventas/listados, productos), verificando que el lint de color de `v4-frontend-01` no reporte nuevas violaciones
- [ ] 1.10 Aplicar micro-animaciones 2D (entrada de listas/cards, feedback de estado, hover/press, skeleton animado tokenizado) en las superficies `2d-motion`, incluido el POS, sin tocar handlers/queries/mutaciones
- [ ] 1.11 Verificar tema claro y oscuro en las superficies refrescadas de la Fase A (toggle `next-themes` sin colores fuera de tema)

## 2. Fase B — Infraestructura 3D (R3F) + guardrails + escena piloto

- [ ] 2.1 Instalar `@react-three/fiber` y `@react-three/drei`; confirmar compatibilidad con React 19 / Next 16 App Router
- [ ] 2.2 Crear el gate de capacidad `lib/three/capabilityGate.ts` (reduced-motion, mobile/gama-baja por `hardwareConcurrency`/`deviceMemory`/`pointer:coarse`, detección WebGL, `saveData`/conexión lenta) con umbrales documentados y sin `any`
- [ ] 2.3 Escribir tests (Vitest) del gate de capacidad cubriendo cada condición de fallback (reduced-motion, sin WebGL, mobile, save-data) y el caso "califica"
- [ ] 2.4 Crear el wrapper `components/three/Lazy3DCanvas.tsx`: consume el gate, monta el `<Canvas>` por IntersectionObserver, pausa/desmonta el loop fuera de viewport (`frameloop="demand"`), envuelve en `<Suspense>` con poster de fallback
- [ ] 2.5 Crear el error boundary `components/three/SceneErrorBoundary.tsx` que degrada a poster estático ante fallo de render/contexto WebGL perdido
- [ ] 2.6 Configurar el patrón de carga `next/dynamic({ ssr:false, loading: Poster })` como helper/convención para las escenas y verificar con el analyzer de `v4-frontend-07` que el chunk 3D NO entra al first-load de rutas no-3D
- [ ] 2.7 Ajustar el CSP en `lib/supabase/middleware.ts` añadiendo `worker-src 'self' blob:`; self-hostear los decoders Draco/KTX2 en `frontend/public/`; verificar en preview de Vercel que los workers no quedan bloqueados por el CSP de prod
- [ ] 2.8 Definir el presupuesto de peso/bundle por escena (chunk lazy y assets glTF/Draco) y documentarlo en `frontend/docs/3d-budget.md`
- [ ] 2.9 Implementar la escena piloto (hero de landing o auth): componente `components/three/HeroScene.tsx` (low-poly/procedural), su `HeroPoster` estático (WebP/AVIF vía `next/image`), montada tras `Lazy3DCanvas` + `SceneErrorBoundary`
- [ ] 2.10 Verificar en la piloto los guardrails E2E: reduced-motion → poster; sin WebGL → poster; mobile → poster; `aria-hidden` en el contenedor; LCP no regresiona vs baseline 2D

## 3. Fase C — Escenas 3D por superficie de alto impacto

- [ ] 3.1 Landing/hero: integrar la escena hero sobre la estructura editable existente (`components/landing/*`, `LandingPageFull`/`HeroSection`) sin romper el editor de landing (`LandingManager`)
- [ ] 3.2 Login/registro: escena 3D de acompañamiento (lateral/fondo) en `app/auth/login` y `app/auth/register`, con su poster y gate; el formulario sigue 100% usable sin 3D
- [ ] 3.3 Onboarding: ilustración 3D por paso, con poster por paso y gate
- [ ] 3.4 Empty states destacados (dashboard/primeras cargas): objeto 3D ligero o degradar a `2d-motion` si excede el presupuesto de peso
- [ ] 3.5 Celebración "venta cerrada": burst/escena 3D efímera montada on-demand tras confirmación de venta en el POS y auto-desmontada; respeta reduced-motion (sin burst) y no bloquea el flujo de cobro
- [ ] 3.6 Celebración "meta alcanzada": escena/efecto efímero disparado por el hito, con las mismas garantías de la 3.5
- [ ] 3.7 Cada escena lee el tema activo (`useTheme`) para ajustar luces/fondo/materiales o usa poster por tema (claro/oscuro)
- [ ] 3.8 Confirmar por code-review + analyzer que ninguna superficie operativa densa (POS core, tablas, listados) carga el bundle 3D

## 4. Fase D — Pulido, accesibilidad y performance

- [ ] 4.1 Barrido final de migración de color: erradicar las clases hardcodeadas restantes en las superficies pendientes hacia tokens semánticos; lint de color en verde
- [ ] 4.2 Auditar accesibilidad de todas las superficies 3D: `aria-hidden` en contenedores, sin foco de teclado, contenido/acciones fuera del canvas; correr el gate axe de `v4-frontend-04` con y sin 3D (0 violaciones críticas/serias)
- [ ] 4.3 Medir performance en dispositivo/gama media: FPS ≥ objetivo con `AdaptiveDpr`/`AdaptiveEvents`; LCP de rutas 3D no regresiona; chunks 3D dentro de presupuesto (analyzer de `v4-frontend-07`)
- [ ] 4.4 Verificar degradación completa: forzar sin-WebGL, mobile, save-data y reduced-motion en las 6 superficies 3D y confirmar poster estático + funcionalidad intacta
- [ ] 4.5 QA visual claro/oscuro en todas las superficies refrescadas (2D y 3D)
- [ ] 4.6 Actualizar `frontend/docs/surface-matrix.md`, `design-tokens.md` y `3d-budget.md` con el estado final; registrar en engram las decisiones y umbrales del gate de capacidad
