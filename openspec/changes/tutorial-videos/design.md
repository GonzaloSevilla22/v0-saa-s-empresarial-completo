## Context

ALIADATA es un SaaS de gestión para microemprendedores de Mendoza. Hoy no existe **ningún** componente de video en el frontend (grep de `<video>`/embed = 0). El PO grabó con OBS tutoriales cortos de los 5 módulos operativos (Ventas, Compras, Productos, Stock, Gastos) y quiere publicarlos en dos superficies: la **landing pública** (`/`, servida por `LandingPageFull`, `force-dynamic`) y el **dashboard** (ayuda contextual por módulo).

Restricciones duras de esta fase 1 (decisión PO 2026-07-10):
- **Solo frontend.** Sin migraciones de DB, sin backend, sin nuevas queries. La landing `/` no debe sumar llamadas a la base — la sección es estática, como `HowItWorks`/`Pricing`.
- **Hosting: YouTube unlisted + facade.** Los `.mp4` se suben a un canal de YouTube del PO como *unlisted* y se embeben con `YouTubeEmbed` de `@next/third-parties/google` (usa `lite-youtube-embed` por debajo; `youtube-nocookie.com`; solo miniatura hasta el click). Siempre `params="rel=0"`.
- **Reglas del proyecto**: TypeScript sin `any`; componentes React en PascalCase; gobernanza BAJO (UI pura, sin dinero/DB/auth); Strict TDD en el apply (vitest instalado, tests en `frontend/__tests__/`).

Estado actual verificado del código que se toca:
- `frontend/app/page.tsx` renderiza `LandingPageFull` (la landing REAL). Existe una landing legacy en `/landing` (`LandingRenderer` + `*Section.tsx`) que NO se toca.
- `LandingPageFull.tsx`: el array de links de la Navbar está en `Navbar()` (~líneas 14-19) y el menú mobile itera el mismo array; el patrón de sección/cards está en `Features` (grilla `grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3`, cards `rounded-2xl border border-slate-800 bg-slate-900`).
- `breadcrumb-nav.tsx`: client component con `usePathname()` y un mapa `PAGE_NAMES` (pathname→nombre); el header ya tiene un contenedor `ml-auto` a la derecha con `NotificationBell`.
- `frontend/components/shared/responsive-modal.tsx`: Dialog (desktop, `sm:max-w-xl` fijo) / Sheet (mobile). **No** acepta hoy override de ancho.
- `frontend/components/ui/aspect-ratio.tsx` ya está instalado (Radix).
- `@next/third-parties` NO está en `frontend/package.json` — hay que agregarlo con pnpm.

## Goals / Non-Goals

**Goals:**
- Publicar los tutoriales en landing y dashboard con mínima superficie de cambio y cero deuda de datos.
- Abstraer el hosting detrás de un mapa tipado (`lib/tutorials.ts`) para poder migrar a R2 después cambiando solo datos + la implementación del player.
- Tolerar que los videos aún no existan: el diseño no se rompe con `youtubeVideoId: null` (no renderiza card/botón).
- No degradar el LCP de la landing (facade: solo miniatura hasta el click).
- Un único componente de player (`TutorialVideo`) reutilizado en ambas superficies.

**Non-Goals (fase 2 / futuro):**
- Watch pages `/tutoriales/[modulo]` con schema `VideoObject` (SEO de video).
- Integración con el módulo Cursos existente (`community.course_lessons.content_url` — su player es un stub que imprime la URL como texto).
- Hosting propio (Cloudflare R2). La abstracción del mapa lo deja listo, pero no se implementa acá.
- Tour interactivo de primer login — eso es `v4-producto-calidad-04` (change distinto y complementario).
- Cualquier cambio en la landing legacy `/landing` o en `community.landing_sections`.

## Decisions

### D1 — Fuente de datos: mapa estático tipado en `lib/tutorials.ts`
Un `Record`/array de solo lectura, tipado explícitamente (sin `any`), es la única fuente de verdad. Forma de cada entrada (**ampliado a 10 tutoriales por el PO 2026-07-29**; el orden del array es el orden de la landing, Onboarding primero):
```ts
export type TutorialModuleKey =
  | "onboarding" | "dashboard" | "ventas" | "compras" | "productos"
  | "stock" | "gastos" | "clientes" | "insights" | "simulador"
export interface Tutorial {
  moduleKey: TutorialModuleKey
  title: string
  description: string
  durationLabel: string        // p. ej. "3 min"
  youtubeVideoId: string | null // null = video aún no subido
  pathname: string | null       // ruta del dashboard donde es contextual (p. ej. "/ventas");
                                // null = tutorial general (onboarding): landing sí, botón contextual no
}
```
Mapeo de rutas (claves reales de `PAGE_NAMES` en `breadcrumb-nav.tsx`): Tablero → `/dashboard`, Clientes → `/clientes`, Consejos IA → `/insights`, Simulador de Precios → `/simulador`; los 5 originales conservan su ruta. `getTutorialByPathname` excluye las entradas con `pathname: null`.
Helpers puros (fáciles de testear en TDD): `hasTutorialVideo(t)`, `getAvailableTutorials()`, `getTutorialByPathname(pathname)`.
- **Por qué**: desacopla las superficies del hosting; migrar a R2 = cambiar datos + player, no consumidores. Testeable sin DOM.
- **Alternativas descartadas**: (a) leer de `community.landing_sections`/DB — rechazado por la restricción "sin DB / sin queries"; (b) hardcodear IDs en cada componente — rompe la fuente única y dificulta la migración de hosting.

### D2 — Hosting: YouTube unlisted vía `@next/third-parties` (`YouTubeEmbed`), patrón facade
`YouTubeEmbed` usa `lite-youtube-embed`: renderiza solo la miniatura hasta el click, sirve desde `youtube-nocookie.com` y evita cargar el player pesado en el primer paint. Siempre `params="rel=0"`.
- **Por qué**: cero costo de storage/CDN, transcodificación y calidades adaptativas gratis de YouTube, y el facade protege el LCP de la landing (la sección va below-the-fold).
- **Alternativas descartadas**: (a) `<iframe>` de YouTube plano — carga el player pesado siempre, penaliza LCP; (b) hosting propio (R2 + `<video>`) — más control y sin marca YouTube, pero implica storage, transcodificación y ancho de banda; se pospone (Non-Goal), la abstracción D1 lo habilita.
- **Nota de privacidad**: unlisted no es privado-privado (cualquiera con el link ve el video); es aceptable para material de ayuda de producto. Documentado como riesgo.

### D3 — Componente de player compartido `TutorialVideo`
`frontend/components/shared/TutorialVideo.tsx` (PascalCase). Props mínimas: `{ youtubeVideoId: string; title?: string }`. Envuelve `YouTubeEmbed` en un contenedor 16:9 (`AspectRatio` ya instalado, o `aspect-video`). Es un client component (el embed corre en cliente). Se usa en la card de landing y dentro del modal del dashboard.
- **Por qué**: un solo lugar que conoce `@next/third-parties`; las superficies solo pasan un id. Si mañana es R2, se cambia acá.
- El componente asume `youtubeVideoId` no nulo; la decisión de mostrar/ocultar (null) vive en el consumidor vía los helpers de D1.

### D4 — Landing: sección hardcodeada `<section id="tutoriales">` + link en Navbar
Se agrega una función de sección dentro de `LandingPageFull.tsx` siguiendo el patrón de `Features` (shell `py-24 sm:py-32`, `container mx-auto px-4`, header centrado con eyebrow emerald + h2 + p, grilla `grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3`, cards `rounded-2xl border border-slate-800 bg-slate-900` con thumbnail en `aspect-video`). Se renderiza en el árbol de `LandingPageFull` (ubicación sugerida: después de `Features` o `HowItWorks`). Al array de links de la Navbar se agrega `{ label: "Aprendé a usar ALIADATA", href: "#tutoriales" }` (el menú mobile itera el mismo array, así que aparece en ambos).
- **Extracción**: si la sección crece, extraerla a `frontend/components/landing/TutorialsSection.tsx` (PascalCase) e importarla en `LandingPageFull`. La sección consume `getAvailableTutorials()`: si está vacía, no renderiza cards (degrada a solo header o se oculta).
- **Alternativa descartada**: sección editable desde DB (`community.landing_sections`) — fuera de scope (sin DB).

### D5 — Dashboard: botón contextual en `breadcrumb-nav.tsx` + `ResponsiveModal`
`breadcrumb-nav.tsx` ya tiene `usePathname()`. Se agrega un lookup `getTutorialByPathname(pathname)`; si hay tutorial con video, se renderiza a la derecha (junto a `NotificationBell`, dentro del `ml-auto`) un `Button variant="outline" size="sm"` con ícono lucide (`GraduationCap`/`PlayCircle`, `h-4 w-4`) y label `hidden sm:inline` = "Ver tutorial". El click abre estado local `open` → `ResponsiveModal` con `<TutorialVideo youtubeVideoId=... />`.
- **Ancho del modal 16:9**: `ResponsiveModal` hoy fija `sm:max-w-xl`. Decisión: **extenderlo de forma retrocompatible** agregando una prop opcional `contentClassName?: string` (o `size?: "default" | "lg"`) que se mergea en el `DialogContent` (default mantiene `sm:max-w-xl`; el modal de video pasa `sm:max-w-3xl`). No cambia el comportamiento de los usos existentes.
- **Por qué el header global y no cada page**: un solo punto de enganche cubre todas las rutas; el mapa decide dónde aparece. Evita tocar 5 páginas.
- **Alternativas descartadas**: (a) botón por página — 5 ediciones duplicadas; (b) modal nuevo ad-hoc — se prefiere reutilizar `ResponsiveModal` (ya resuelve desktop/mobile).

### D6 — Dependencia `@next/third-parties`
Se agrega a `frontend/` con pnpm (`pnpm add @next/third-parties` dentro de `frontend/`). Compatible con Next 16 / App Router. Es la vía oficial de Next para embeds de YouTube con lazy-facade.

### D7 — Estrategia de tests (Strict TDD en el apply)
- **`lib/tutorials.ts`** (lógica pura, ideal para RED→GREEN→TRIANGULATE): tests en `frontend/__tests__/lib/tutorials.test.ts` para `hasTutorialVideo`, `getAvailableTutorials`, `getTutorialByPathname` (ruta con video / ruta inexistente / ruta con `null`).
- **`TutorialVideo`**: test de render (`@testing-library/react`) que verifica que con un id se renderiza el embed y que el contenedor es 16:9; se puede mockear `@next/third-parties/google` para asertar que recibe `params="rel=0"`.
- **Botón contextual** (opcional pero recomendado): test de `breadcrumb-nav` que, con un pathname con tutorial, muestra el botón, y con uno sin tutorial, no.

## Risks / Trade-offs

- **[Videos aún no existen — `youtubeVideoId: null`]** → El diseño tolera null por contrato (helpers + scenarios): sin video, sin card y sin botón. El feature puede mergearse antes de que el PO suba los videos; la sección/botón aparecen recién cuando se completan los IDs.
- **[Tarea manual del PO bloquea la visibilidad real]** → Crear canal + subir 5 `.mp4` unlisted + pasar IDs es trabajo del PO, no de código. Se documenta como task explícita en `tasks.md`; no bloquea el merge del andamiaje.
- **[Unlisted no es privado]** → Cualquiera con el link puede ver el video. Aceptable para ayuda de producto; si se requiere privacidad real, migrar a R2 con signed URLs (Non-Goal).
- **[LCP de la landing]** → Mitigado por el facade (solo miniatura hasta el click) y por ubicar la sección below-the-fold. Verificar que no se importe el player pesado en el primer paint.
- **[Editar `ResponsiveModal` afecta otros usos]** → Mitigado haciendo el cambio retrocompatible (prop opcional; el default preserva `sm:max-w-xl`). Cubrir con el test existente/nuevo que los usos previos no cambian de ancho.
- **[Dependencia nueva `@next/third-parties`]** → Paquete oficial de Vercel/Next, bajo riesgo; se instala solo en `frontend/`. Verificar que el build de Next 16 lo resuelva.
- **[CSP / dominios de YouTube]** → El embed carga de `youtube-nocookie.com` y `ytimg.com`. Si hubiese una CSP estricta, habría que permitir esos orígenes. Verificar en el build/preview (hoy no se detecta CSP que lo bloquee, pero conviene chequear en QA).

## Migration Plan

No hay migración de datos (sin DB). Despliegue estándar por PR → merge → Vercel. Pasos:
1. `pnpm add @next/third-parties` en `frontend/`.
2. Crear `lib/tutorials.ts` con las 5 entradas y `youtubeVideoId: null` (placeholders) hasta que el PO entregue los IDs.
3. Implementar `TutorialVideo`, la sección de landing + link, y el botón del dashboard (con TDD).
4. **PO (manual, en paralelo o después)**: crear canal YouTube, subir los 5 `.mp4` unlisted, pasar los `youtubeVideoId`; se completan en `lib/tutorials.ts` (cambio de datos, sin tocar UI).
5. Verificación: `pnpm test` (vitest) verde + `pnpm build` OK.

**Rollback**: revertir el PR. Al ser aditivo (nueva sección, nuevo botón condicional, nueva dep), el rollback es limpio y no afecta datos.

## Open Questions

- **OQ1 — IDs de video**: los 5 `youtubeVideoId` no existen todavía. ¿El PO sube los 5 antes del merge, o se mergea con `null` y se completan luego? (El diseño soporta ambas; recomendación: mergear el andamiaje con `null` y completar IDs cuando estén.)
- **OQ2 — Orden/copys de la sección de landing**: título "Aprendé a usar ALIADATA" confirmado; falta el subtítulo/eyebrow y el orden exacto de los 5 tutoriales y sus `description`/`durationLabel`. Se puede resolver con copys razonables en el apply y ajustar con el PO.
- **OQ3 — Ícono del botón del dashboard**: `GraduationCap`, `PlayCircle` o `Video` (lucide). Elegir uno en el apply.
- **OQ4 — Extensión de `ResponsiveModal`**: ¿prop `contentClassName` genérica o `size` acotado? Recomendación: `contentClassName` opcional (más flexible, menos API nueva).
