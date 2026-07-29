## Why

Los microemprendedores que llegan a ALIADATA no siempre saben por dónde empezar: la curva de aprendizaje de un SaaS de gestión (ventas, compras, stock, productos, gastos) es una fricción real de activación y retención. El PO ya grabó con OBS videos tutoriales cortos de cada módulo; falta darles un lugar en el producto. Esta fase 1 los publica en dos superficies de alto impacto —la landing pública (para convencer antes de registrarse) y el dashboard (ayuda contextual dentro del flujo)— sin tocar base de datos ni backend, de forma que sea rápido de shippear y fácil de migrar de hosting más adelante.

## What Changes

- **Nuevo mapa de datos tipado** `frontend/lib/tutorials.ts`: fuente única de verdad de los tutoriales (**10 entradas, alcance ampliado por el PO 2026-07-29**: Onboarding — video general de inicio, sin ruta de dashboard — más Tablero, Ventas, Compras, Productos, Stock, Gastos, Clientes, Consejos IA y Simulador de Precios). Cada entrada es `{ moduleKey, title, description, durationLabel, youtubeVideoId | null, pathname | null }` (`pathname: null` = tutorial general: sale en la landing pero sin botón contextual). El hosting queda **abstraído detrás del mapa**: hoy YouTube unlisted, mañana Cloudflare R2 sin tocar UI. Los `youtubeVideoId` reales aún **no existen** — el mapa tolera `null` (tutorial pendiente ⇒ no se renderiza su card ni su botón).
- **Nuevo componente de player compartido** `TutorialVideo` (PascalCase, en `frontend/components/shared/`): recibe un `youtubeVideoId` y renderiza el video con el componente `YouTubeEmbed` de `@next/third-parties/google` (patrón *facade*: solo carga la miniatura hasta el click, usa `youtube-nocookie.com`, siempre `params="rel=0"`). Es el **primer** componente de video del frontend (hoy no hay ningún `<video>`/embed). Se reutiliza en landing y en el modal del dashboard.
- **Nueva sección de landing "Aprendé a usar ALIADATA"**: `<section id="tutoriales">` hardcodeada dentro de `LandingPageFull.tsx` (la landing REAL servida en `/`), siguiendo el patrón visual de `Features` (grilla de cards con thumbnail `aspect-video`). Se agrega el link `{ label: "Aprendé a usar ALIADATA", href: "#tutoriales" }` a la Navbar (desktop + menú mobile, que iteran el mismo array).
- **Nuevo botón "Ver tutorial" contextual en el dashboard**: en `breadcrumb-nav.tsx` (header global del dashboard), un botón que aparece SOLO cuando la ruta actual tiene un tutorial con video disponible, y abre un modal (`ResponsiveModal`) con el `TutorialVideo`.
- **Nueva dependencia** `@next/third-parties` (pnpm, en `frontend/`).

Sin migraciones de DB, sin backend, sin nuevas queries. La landing `/` sigue siendo estática en esta sección (no suma llamadas a la base).

## Capabilities

### New Capabilities
- `tutorial-videos`: publica videos tutoriales de uso de ALIADATA en la landing pública y como ayuda contextual en el dashboard, a partir de un catálogo estático tipado que abstrae el hosting del video y tolera tutoriales aún sin grabar.

### Modified Capabilities
<!-- Ninguna: no cambian requisitos de capabilities existentes; la sección de landing y el header del dashboard se extienden sin alterar su contrato de comportamiento actual. -->

## Impact

- **Código nuevo**: `frontend/lib/tutorials.ts`, `frontend/components/shared/TutorialVideo.tsx`, y (si la sección crece) un componente extraído para la sección de landing (p. ej. `frontend/components/landing/TutorialsSection.tsx`).
- **Código modificado**: `frontend/components/landing/LandingPageFull.tsx` (Navbar links + render de la nueva sección), `frontend/components/dashboard/breadcrumb-nav.tsx` (botón contextual + modal). Posible extensión mínima de `frontend/components/shared/responsive-modal.tsx` para permitir un ancho mayor (16:9).
- **Dependencias**: `+ @next/third-parties` (usa `lite-youtube-embed` por debajo). Package manager: pnpm.
- **Datos / DB / backend**: ninguno. No toca `community.landing_sections` (la sección es hardcodeada, como `HowItWorks`/`Pricing`). No toca la landing legacy de `/landing`.
- **Gobernanza**: BAJO (UI frontend pura, sin dinero, sin auth, sin DB). Strict TDD aplica en el apply (vitest ya instalado).
- **Tarea manual del PO (fuera de código, bloquea el "video visible" pero no el merge)**: crear el canal de YouTube, subir los 10 `.mp4` como *unlisted* y pasar los `youtubeVideoId`.
