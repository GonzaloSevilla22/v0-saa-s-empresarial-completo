## ADDED Requirements

### Requirement: Catálogo estático tipado de tutoriales

El sistema SHALL exponer un catálogo de tutoriales en `frontend/lib/tutorials.ts` como estructura tipada de solo lectura, con 10 entradas (alcance PO 2026-07-29): Onboarding (video general de inicio) más una por cada módulo cubierto (Tablero, Ventas, Compras, Productos, Stock, Gastos, Clientes, Consejos IA, Simulador de Precios). Cada entrada MUST tener la forma `{ moduleKey, title, description, durationLabel, youtubeVideoId, pathname }`, donde `youtubeVideoId` es `string | null` y `pathname` es `string | null`: la ruta del dashboard donde ese tutorial es contextualmente relevante, o `null` para tutoriales generales sin ruta (Onboarding). El orden del catálogo ES el orden de las cards en la landing, con Onboarding primero. El catálogo MUST ser la única fuente de verdad del feature: ni la landing ni el dashboard pueden hardcodear IDs de video por fuera de él. El tipo NO debe usar `any`.

#### Scenario: Cada tutorial tiene su entrada tipada

- **WHEN** se importa el catálogo desde `frontend/lib/tutorials.ts`
- **THEN** existen exactamente 10 entradas — Onboarding, Tablero, Ventas, Compras, Productos, Stock, Gastos, Clientes, Consejos IA, Simulador de Precios — cada una con `moduleKey`, `title`, `description`, `durationLabel`, `youtubeVideoId` y `pathname` con los tipos declarados, con Onboarding en primer lugar

#### Scenario: Tutorial general sin ruta de dashboard

- **WHEN** una entrada del catálogo tiene `pathname: null` (tutorial general, p. ej. Onboarding)
- **THEN** la entrada participa de la landing como cualquier otra, pero ninguna ruta del dashboard la ofrece como tutorial contextual (el lookup por ruta nunca la devuelve)

#### Scenario: Tolerancia a video pendiente

- **WHEN** una entrada del catálogo tiene `youtubeVideoId: null` (tutorial aún no grabado/subido)
- **THEN** el helper de disponibilidad (p. ej. `hasTutorialVideo`) devuelve `false` para esa entrada, de modo que ni la landing ni el dashboard intentan renderizar su video

#### Scenario: Abstracción del hosting

- **WHEN** en el futuro se migra el hosting de video (p. ej. de YouTube unlisted a Cloudflare R2)
- **THEN** el cambio se limita a los datos y a la implementación del componente de player, sin modificar las superficies que consumen el catálogo (landing y dashboard)

### Requirement: Búsqueda de tutorial por ruta del dashboard

El sistema SHALL proveer una función pura de lookup (p. ej. `getTutorialByPathname(pathname)`) que, dada una ruta del dashboard, devuelva la entrada de tutorial cuyo `pathname` coincide, o `undefined` si no hay ninguna. Las entradas con `pathname: null` (tutoriales generales, p. ej. Onboarding) MUST quedar excluidas del lookup: ninguna ruta las devuelve. La función MUST devolver una entrada únicamente cuando la ruta tiene un tutorial cuyo video está disponible (`youtubeVideoId` no nulo), o exponer de forma clara la disponibilidad para que el consumidor decida.

#### Scenario: Ruta con tutorial disponible

- **WHEN** se invoca el lookup con una ruta que tiene una entrada con `youtubeVideoId` no nulo
- **THEN** devuelve esa entrada de tutorial

#### Scenario: Ruta sin tutorial

- **WHEN** se invoca el lookup con una ruta que no figura en el catálogo
- **THEN** devuelve `undefined`

#### Scenario: Tutorial general nunca se resuelve por ruta

- **WHEN** se invoca el lookup con cualquier ruta del dashboard
- **THEN** nunca devuelve una entrada cuyo `pathname` es `null` (p. ej. Onboarding), por lo que esas entradas no generan botón "Ver tutorial" en ninguna página

#### Scenario: Ruta con tutorial pendiente de video

- **WHEN** se invoca el lookup con una ruta cuya entrada tiene `youtubeVideoId: null`
- **THEN** el consumidor NO ofrece el botón "Ver tutorial" (no hay video que mostrar)

### Requirement: Componente de player de video compartido

El sistema SHALL proveer un componente React reutilizable `TutorialVideo` (PascalCase, en `frontend/components/shared/`) que reciba un `youtubeVideoId: string` y renderice el video mediante un **facade propio sin scripts externos** (decisión PO 2026-07-29, D8 — reemplaza el `YouTubeEmbed` de `@next/third-parties/google` inicial: su script se cargaba desde `cdn.jsdelivr.net`, bloqueado por la CSP del proyecto). El estado inicial MUST mostrar solo la miniatura (`https://i.ytimg.com/vi/{id}/hqdefault.jpg`) con un botón accesible; al click MUST montar un `<iframe>` de `https://www.youtube-nocookie.com/embed/{id}?autoplay=1&rel=0` con `allowFullScreen`, limitando las sugerencias al propio canal (`rel=0`). El componente MUST renderizar el video con relación de aspecto 16:9 y no debe depender de `@next/third-parties` (removido del proyecto).

#### Scenario: Render con video disponible

- **WHEN** se monta `TutorialVideo` con un `youtubeVideoId` válido
- **THEN** muestra la miniatura de `i.ytimg.com` con un botón accesible dentro de un contenedor de relación de aspecto 16:9, sin iframe hasta el click

#### Scenario: Click reproduce el video embebido

- **WHEN** el usuario hace click en el botón de reproducción
- **THEN** se monta un `<iframe>` de `youtube-nocookie.com/embed/{id}?autoplay=1&rel=0` con `allowFullScreen`, dentro del mismo contenedor 16:9

#### Scenario: Facade below-the-fold sin impacto en LCP

- **WHEN** la landing con la sección de tutoriales carga por primera vez
- **THEN** los players no descargan ningún script ni iframe de YouTube hasta que el usuario hace click (solo se muestra la miniatura estática), de modo que la sección no penaliza el LCP de la landing

### Requirement: Content Security Policy allows the YouTube facade iframe

The application's Content Security Policy SHALL permit the `TutorialVideo` facade's `youtube-nocookie.com` iframe to render. Specifically, `https://www.youtube-nocookie.com` MUST be allowed in `frame-src`. Because the facade uses no external scripts (D8), `script-src` MUST NOT be relaxed for this feature (e.g. no `cdn.jsdelivr.net`).

#### Scenario: Video iframe renders under production CSP

- **WHEN** a dashboard or landing page with `TutorialVideo` is served with the production security headers and the user clicks to play
- **THEN** the `youtube-nocookie.com` iframe loads without being blocked by the CSP

#### Scenario: script-src stays unchanged

- **WHEN** the CSP is inspected (`buildContentSecurityPolicy()`)
- **THEN** `frame-src` includes `https://www.youtube-nocookie.com` alongside the pre-existing `https://challenges.cloudflare.com`, and no other directive (`script-src`, `style-src`, etc.) is relaxed to add a third-party CDN for video

### Requirement: Sección de tutoriales en la landing pública

El sistema SHALL mostrar una sección `<section id="tutoriales">` en la landing real servida en `/` (`LandingPageFull`), titulada "Aprendé a usar ALIADATA", que liste como cards los tutoriales cuyo video está disponible. La sección MUST ser estática (hardcodeada, sin lecturas de base de datos) y seguir el patrón visual de la sección `Features` (grilla responsive de cards con thumbnail en contenedor `aspect-video`). La landing legacy de `/landing` NO debe modificarse.

#### Scenario: Se listan solo los tutoriales con video

- **WHEN** se renderiza la sección de tutoriales en `/`
- **THEN** aparece una card por cada tutorial con `youtubeVideoId` no nulo, y no aparece card para los tutoriales con `youtubeVideoId: null`

#### Scenario: Todos los tutoriales pendientes

- **WHEN** ningún tutorial del catálogo tiene video disponible todavía
- **THEN** la sección no muestra cards de video (puede ocultarse por completo o mostrar solo su encabezado), sin romper el render de la landing

#### Scenario: La landing no agrega queries

- **WHEN** se carga `/`
- **THEN** la sección de tutoriales no dispara ninguna consulta adicional a la base de datos (el contenido proviene del catálogo estático)

### Requirement: Enlace de navegación a la sección de tutoriales

El sistema SHALL incluir en la Navbar de `LandingPageFull` un enlace `{ label: "Aprendé a usar ALIADATA", href: "#tutoriales" }` que haga scroll a la sección. El enlace MUST aparecer tanto en el menú de escritorio como en el menú mobile (ambos derivan del mismo array de links).

#### Scenario: Enlace presente en desktop y mobile

- **WHEN** se renderiza la Navbar de la landing
- **THEN** el enlace "Aprendé a usar ALIADATA" con `href="#tutoriales"` está presente en el menú de escritorio y en el menú desplegable mobile

#### Scenario: Navegación por ancla

- **WHEN** el usuario hace click en "Aprendé a usar ALIADATA"
- **THEN** la vista hace scroll hasta la `<section id="tutoriales">`

### Requirement: Botón contextual "Ver tutorial" en el dashboard

El sistema SHALL mostrar en el header del dashboard (`breadcrumb-nav.tsx`) un botón "Ver tutorial" únicamente cuando la ruta actual tenga un tutorial con video disponible en el catálogo. El botón MUST seguir el patrón de los botones de header (`Button variant="outline" size="sm"`, ícono lucide `h-4 w-4`, label `hidden sm:inline`) y al accionarlo MUST abrir un modal (`ResponsiveModal`: Dialog en desktop / Sheet en mobile) con el componente `TutorialVideo` del módulo, en un ancho apto para 16:9.

#### Scenario: Ruta con tutorial disponible muestra el botón

- **WHEN** el usuario navega a una ruta del dashboard cuyo tutorial tiene `youtubeVideoId` no nulo
- **THEN** el header muestra el botón "Ver tutorial"

#### Scenario: Ruta sin tutorial oculta el botón

- **WHEN** el usuario está en una ruta sin tutorial en el catálogo, o cuyo tutorial tiene `youtubeVideoId: null`
- **THEN** el header no muestra el botón "Ver tutorial"

#### Scenario: El botón abre el modal con el video

- **WHEN** el usuario hace click en "Ver tutorial"
- **THEN** se abre el modal responsive con el `TutorialVideo` del módulo de la ruta actual, en un contenedor 16:9, y puede cerrarse
