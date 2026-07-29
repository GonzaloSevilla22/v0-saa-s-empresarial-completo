## 1. Dependencia y catálogo de datos

- [x] 1.1 Agregar `@next/third-parties` a `frontend/` con pnpm (`cd frontend && pnpm add @next/third-parties`); verificar que quede en `frontend/package.json` y que `pnpm install` resuelva el lockfile.
- [x] 1.2 (TDD RED) Escribir `frontend/__tests__/lib/tutorials.test.ts` con casos para `hasTutorialVideo`, `getAvailableTutorials` y `getTutorialByPathname` (ruta con video / ruta inexistente → `undefined` / ruta con `youtubeVideoId: null`).
- [x] 1.3 (TDD GREEN) Crear `frontend/lib/tutorials.ts`: tipos `TutorialModuleKey` y `Tutorial` (sin `any`), el catálogo readonly con las 5 entradas (Ventas `/ventas`, Compras `/compras`, Productos `/productos`, Stock `/stock`, Gastos `/gastos`) con `youtubeVideoId: null` (placeholders) y los helpers puros. Iterar hasta que 1.2 pase (TRIANGULATE con ≥2 casos por helper).
- [x] 1.4 Confirmar `moduleKey`, `title`, `description`, `durationLabel` y `pathname` de cada entrada; dejar `youtubeVideoId: null` hasta que el PO entregue los IDs reales (ver 5.1).

## 2. Componente de player compartido

- [x] 2.1 (TDD RED) Escribir test de `TutorialVideo` (`frontend/__tests__/` o `__tests__/components/`): con un `youtubeVideoId` renderiza el embed, el contenedor es 16:9, y se pasa `params="rel=0"` (mockear `@next/third-parties/google`).
- [x] 2.2 (TDD GREEN) Crear `frontend/components/shared/TutorialVideo.tsx` (PascalCase, client component): envuelve `YouTubeEmbed` de `@next/third-parties/google` con `params="rel=0"` dentro de un contenedor 16:9 (`AspectRatio` o `aspect-video`). Iterar hasta que 2.1 pase.

## 3. Sección de tutoriales en la landing

- [x] 3.1 Agregar el link `{ label: "Aprendé a usar ALIADATA", href: "#tutoriales" }` al array de links de la Navbar en `frontend/components/landing/LandingPageFull.tsx` (verificar que aparezca en desktop y en el menú mobile, que iteran el mismo array). Implementado condicional a `getAvailableTutorials().length > 0` para no dejar un anchor muerto mientras el catálogo esté en placeholders (consistente con OQ1: feature invisible hasta que haya videos).
- [x] 3.2 Implementar la `<section id="tutoriales">` "Aprendé a usar ALIADATA" siguiendo el patrón de `Features` (shell `py-24 sm:py-32`, `container mx-auto px-4`, header centrado eyebrow emerald + h2 + p, grilla `grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3`, cards `rounded-2xl border border-slate-800 bg-slate-900` con thumbnail `aspect-video`). Consumir `getAvailableTutorials()`: renderizar solo cards con video; si está vacío, no romper (solo header u ocultar). Extraída a `frontend/components/landing/TutorialsSection.tsx` (PascalCase) e importada en `LandingPageFull`. Decisión: sección retorna `null` por completo cuando no hay tutoriales disponibles (no solo header) — evita mostrar una sección vacía en prod hasta que el PO suba videos.
- [x] 3.3 Renderizar la sección en el árbol de `LandingPageFull` (tras `Features`, antes de `HowItWorks`). Confirmado: NO agrega queries a DB (contenido 100% desde el catálogo estático `lib/tutorials.ts`).
- [x] 3.4 Verificar que NO se tocó la landing legacy de `/landing` (`LandingRenderer`, `components/landing/*Section.tsx`). Confirmado por `git status`: solo se modificó `LandingPageFull.tsx` y se agregó `TutorialsSection.tsx` (nuevo).

## 4. Botón contextual "Ver tutorial" en el dashboard

- [x] 4.1 Extender `frontend/components/shared/responsive-modal.tsx` de forma retrocompatible: prop opcional `contentClassName?: string` que se mergea en `DialogContent` (default preserva `sm:max-w-xl`); el modal de video pasará `sm:max-w-3xl` para 16:9. No cambiar el comportamiento de los usos existentes.
- [x] 4.2 (TDD, recomendado) Test de `breadcrumb-nav`: con un pathname que tiene tutorial disponible muestra el botón "Ver tutorial"; con una ruta sin tutorial (o `youtubeVideoId: null`) no lo muestra.
- [x] 4.3 En `frontend/components/dashboard/breadcrumb-nav.tsx`: usar `getTutorialByPathname(pathname)`; cuando hay tutorial con video, renderizar en el `ml-auto` (junto a `NotificationBell`) un `Button variant="outline" size="sm"` con ícono lucide (`h-4 w-4`) + label `hidden sm:inline` = "Ver tutorial"; estado local `open` que abre `ResponsiveModal` (`contentClassName="sm:max-w-3xl"`) con `<TutorialVideo youtubeVideoId={...} />`.

## 5. Tarea manual del PO (fuera de código)

- [ ] 5.1 **PO**: crear el canal de YouTube, subir los **10** `.mp4` (grabados con OBS) como **unlisted** (no hace falta re-encodear antes; YouTube transcodifica), y pasar los 10 `youtubeVideoId`. (No bloquea el merge del andamiaje; sin IDs, cards/botón no se renderizan por diseño.) — **PENDIENTE, manual del PO, fuera de este apply.** *(Ampliado de 5 → 10 videos por el cambio de scope 2026-07-29.)*
- [ ] 5.2 Completar los `youtubeVideoId` reales en `frontend/lib/tutorials.ts` (cambio de datos, sin tocar UI) una vez que el PO entregue 5.1. — **PENDIENTE, bloqueado por 5.1.**

## 7. Extensión de scope 2026-07-29 — catálogo de 10 tutoriales (PO)

- [x] 7.1 (TDD RED) Actualizar `frontend/__tests__/lib/tutorials.test.ts`: catálogo de 10 en orden de landing (Onboarding primero), solo Onboarding con `pathname: null`, mapeo de rutas nuevas (`/dashboard`, `/clientes`, `/insights`, `/simulador`), y garantía de que el lookup por ruta nunca devuelve Onboarding.
- [x] 7.2 (TDD GREEN) Extender `frontend/lib/tutorials.ts`: `TutorialModuleKey` con las 10 claves, `pathname: string | null` (null = tutorial general sin botón contextual), catálogo de 10 entradas todas con `youtubeVideoId: null` (sigue invisible en prod), copys provisorios en voseo, `getTutorialByPathname` excluye `pathname: null`.
- [x] 7.3 Verificar que `TutorialsSection` y el botón de `breadcrumb-nav` no requieren cambios (data-driven): confirmado — la sección itera `getAvailableTutorials()` sin asumir cantidad y el lookup por ruta ya filtra los null; suites de ambos consumidores verdes sin tocar.
- [x] 7.4 Actualizar artefactos del change (proposal, design D1, spec delta: catálogo de 10 + scenario de tutorial general sin ruta + scenario de lookup que excluye null) y validar con `openspec validate tutorial-videos --strict`.

## 6. Verificación

- [x] 6.1 Correr `cd frontend && pnpm test` (vitest) — suite completa verde, incluidos los tests nuevos de `tutorials`, `TutorialVideo` y (si aplica) `breadcrumb-nav`. Resultado: 57 archivos / 481 tests verdes (baseline previo al change: 464 tests).
- [x] 6.2 Correr `cd frontend && pnpm build` — build de Next 16 OK (resuelve `@next/third-parties`, sin errores de tipos ni `any`). `✓ Compiled successfully`.
- [ ] 6.3 QA manual mínimo (idealmente con al menos un `youtubeVideoId` real): en `/` el link "Aprendé a usar ALIADATA" hace scroll a la sección y las cards con video reproducen tras el click (facade); en el dashboard, el botón "Ver tutorial" aparece solo en rutas con tutorial y abre el modal 16:9. Confirmar que la landing below-the-fold no penaliza el LCP. — **PENDIENTE, bloqueado por 5.1/5.2** (sin `youtubeVideoId` real la feature es invisible por diseño; el estado "todo null" — sección oculta, botón oculto, landing no rompe — está cubierto por los tests automáticos).
