/**
 * fix/login-3d-visible.
 *
 * `v4-visual-3d-refresh` (D8: "lateral/fondo") puso la escena decorativa de
 * acompañamiento de `/auth/login` y `/auth/register` EXACTAMENTE centrada en
 * el mismo punto que el `Card` opaco del formulario (~448x700, `bg-card`):
 * quedaba tapada casi al 100% (lo poco que asomaba caía dentro del propio
 * margen transparente del dibujo). Decisión del PO: "que quede detrás y
 * sobresalga" — el `Card` no cambia de lugar ni de tamaño, la escena sigue
 * detrás (`z-0`) pero es lo bastante grande para asomar alrededor, sobre todo
 * a izquierda/derecha en escritorio (ahí sobra ancho). En mobile (375px) el
 * `Card` ocupa casi todo el ancho: alcanza con que asome en vertical, sin
 * generar scroll horizontal.
 *
 * Mide la caja de `[data-testid="scene-decorative-box"]` (el mismo nodo que
 * dimensiona tanto el póster como, si el gate califica, el `<canvas>` real —
 * ver `GatedSceneMount`) contra `[data-testid="auth-card"]`. Es geometría de
 * navegador real (`getBoundingClientRect`); jsdom no hace layout.
 *
 * Corre en el proyecto `harness` (frontend/playwright.config.ts): sin sesión
 * ni seeds — `/auth/login` y `/auth/register` son públicas.
 *
 * Revisión adversarial de este mismo change — 3 MAJOR corregidos acá:
 *  - MAJOR 1: medir solo la CAJA deja pasar una regresión que vuelve a clavar
 *    el póster a su tamaño intrínseco (revertir `fill` en `Poster`) — la caja
 *    crecería igual, pero el dibujo adentro quedaría chico y descentrado otra
 *    vez. `expectArtworkFillsBox` mide el `<img>` visible cuando el póster es
 *    lo que se renderiza (siempre, en este harness headless sin GPU forzada).
 *  - MAJOR 2: corregido en los propios SVG (viewBox recortado a la tinta
 *    real), no acá — sin eso, el piso de 120px de caja no garantizaba 120px
 *    de dibujo VISIBLE.
 *  - MAJOR 3: la banda 768–1024px (la caja pasa a 860 desde `md:` cuando el
 *    viewport todavía puede medir tan poco como 768) no tenía ningún test de
 *    scroll horizontal — el único freno ahí es el `overflow-hidden`
 *    preexistente del root, que nada fijaba.
 */
import { test, expect, type Page } from '@playwright/test'

/** Piso para que el desborde horizontal en escritorio SE VEA con claridad. */
const DESKTOP_MIN_OVERHANG_PX = 120

/**
 * Piso para que el desborde vertical en mobile sea un asome real, no
 * subpíxel. MINOR 1 de la revisión adversarial: 24px dejaba pasar una
 * reversión parcial (la mitad mobile del fix, `h-[360px]`/`items-start`) sin
 * fallar en AMBAS pantallas — con la caja vieja de 480px centrada, el
 * `topPeek` de `/auth/login` a 375px YA daba 42.5px, por encima de un piso de
 * 24. 120 (mismo piso que desktop) sigue muy por debajo de lo medido hoy
 * (208.5 / 164) pero ya no lo tapa la caja vieja.
 */
const MOBILE_MIN_VERTICAL_PEEK_PX = 120

/** Tolerancia de centrado (redondeo subpíxel — el borde del Card mide 0,8 px). */
const CENTER_EPSILON_PX = 2

const SCREENS = ['/auth/login', '/auth/register'] as const

const DESKTOP_VIEWPORTS = [
  { width: 1366, height: 768 },
  { width: 1920, height: 1080 },
] as const

const MOBILE_VIEWPORT = { width: 375, height: 812 } as const

/**
 * MAJOR 3: banda donde la caja desktop (860 desde `md:`, breakpoint 768px)
 * puede exceder el viewport (iPad Air 820, iPad Pro 11" 834, 1024px con zoom
 * 125% ≈ 819) — sin el `overflow-hidden` preexistente del root, desbordaría.
 * Nada lo fijaba: la mutación "sacale overflow-hidden" no hacía fallar ningún
 * test existente en ningún viewport que este spec visitaba.
 */
const TABLET_VIEWPORTS = [
  { width: 768, height: 1024 },
  { width: 820, height: 1180 },
] as const

interface Box {
  left: number
  right: number
  top: number
  bottom: number
}

/**
 * `auth-context.tsx` muestra "Loading..." (todo el árbol, Card incluido)
 * hasta resolver el chequeo inicial de sesión — en un boot en frío (primera
 * compilación de `/api/auth/token` por Turbopack) puede tardar varios
 * segundos. Sin esperar esto acá, `readBoxes` corre contra un DOM que aún no
 * montó ninguno de los dos testids — no es el bug de geometría, es una
 * carrera con el arranque del auth gate.
 */
async function waitForAuthGate(page: Page): Promise<void> {
  await page.getByTestId('auth-card').waitFor({ state: 'attached' })
  await page.getByTestId('scene-decorative-box').waitFor({ state: 'attached' })
}

async function readBoxes(
  page: Page,
): Promise<{ scene: Box | null; card: Box | null; docScrollWidth: number; artwork: Box | null }> {
  return page.evaluate(() => {
    const toBox = (el: Element | null) => {
      if (!el) return null
      const r = el.getBoundingClientRect()
      return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }
    }
    const byTestId = (testId: string) => document.querySelector(`[data-testid="${testId}"]`)
    const sceneEl = byTestId('scene-decorative-box')
    // El póster puede montar 1 <img> (sin variante oscura) o 2 (uno por tema,
    // alternados por CSS `dark:` — SIEMPRE ambos en el DOM, el oculto colapsa
    // a un rect 0x0 en vez de reportar su tamaño intrínseco). El <canvas> real
    // (cuando el gate califica) no tiene <img> — de ahí que este valor pueda
    // ser `null` legítimamente.
    const visibleImg = sceneEl
      ? (Array.from(sceneEl.querySelectorAll('img')).find((img) => img.getBoundingClientRect().width > 0) ?? null)
      : null
    return {
      scene: toBox(sceneEl),
      card: toBox(byTestId('auth-card')),
      docScrollWidth: document.documentElement.scrollWidth,
      artwork: toBox(visibleImg),
    }
  })
}

/**
 * MAJOR 1 de la revisión adversarial: sin esto, el spec sólo probaba que la
 * CAJA decorativa fuera grande — revertir `fill` en `Poster` (la mitad del
 * fix que hace que el póster LLENE su caja) dejaba el resto de este spec en
 * verde con el dibujo clavado a 400x400 y casi tan tapado como antes.
 */
function expectArtworkFillsBox(scene: Box, artwork: Box | null) {
  if (!artwork) return // <canvas> real montado en este caso — no hay <img> que medir.
  const boxWidth = scene.right - scene.left
  const boxHeight = scene.bottom - scene.top
  expect(
    artwork.right - artwork.left,
    `ancho del <img> del póster (${artwork.right - artwork.left}) vs. su caja (${boxWidth})`,
  ).toBeGreaterThanOrEqual(boxWidth - 2)
  expect(
    artwork.bottom - artwork.top,
    `alto del <img> del póster (${artwork.bottom - artwork.top}) vs. su caja (${boxHeight})`,
  ).toBeGreaterThanOrEqual(boxHeight - 2)
}

for (const path of SCREENS) {
  test.describe(`escena 3D decorativa — ${path}`, () => {
    for (const viewport of DESKTOP_VIEWPORTS) {
      test(`@ ${viewport.width}x${viewport.height}: excede el Card por >= ${DESKTOP_MIN_OVERHANG_PX}px a cada lado y queda centrada en X`, async ({
        page,
      }) => {
        await page.setViewportSize(viewport)
        await page.goto(path)
        await waitForAuthGate(page)

        const { scene, card, artwork } = await readBoxes(page)
        expect(scene, 'falta [data-testid="scene-decorative-box"]').not.toBeNull()
        expect(card, 'falta [data-testid="auth-card"]').not.toBeNull()
        expectArtworkFillsBox(scene!, artwork)

        const leftOverhang = card!.left - scene!.left
        const rightOverhang = scene!.right - card!.right
        expect(leftOverhang, `desborde izquierdo (scene.left=${scene!.left}, card.left=${card!.left})`).toBeGreaterThanOrEqual(
          DESKTOP_MIN_OVERHANG_PX,
        )
        expect(rightOverhang, `desborde derecho (scene.right=${scene!.right}, card.right=${card!.right})`).toBeGreaterThanOrEqual(
          DESKTOP_MIN_OVERHANG_PX,
        )

        const sceneCenterX = (scene!.left + scene!.right) / 2
        const cardCenterX = (card!.left + card!.right) / 2
        expect(Math.abs(sceneCenterX - cardCenterX), 'centro de la escena vs. centro del Card, en X').toBeLessThanOrEqual(
          CENTER_EPSILON_PX,
        )
      })
    }

    test(`@ ${MOBILE_VIEWPORT.width}x${MOBILE_VIEWPORT.height}: asoma en vertical, sin scroll horizontal, centrada en X`, async ({
      page,
    }) => {
      await page.setViewportSize(MOBILE_VIEWPORT)
      await page.goto(path)
      await waitForAuthGate(page)

      const { scene, card, docScrollWidth, artwork } = await readBoxes(page)
      expect(scene, 'falta [data-testid="scene-decorative-box"]').not.toBeNull()
      expect(card, 'falta [data-testid="auth-card"]').not.toBeNull()
      expectArtworkFillsBox(scene!, artwork)

      // Cero scroll horizontal en cualquier ancho (el shell ya sufrió desbordes en mobile).
      expect(docScrollWidth, `document.documentElement.scrollWidth=${docScrollWidth}`).toBeLessThanOrEqual(
        MOBILE_VIEWPORT.width,
      )

      const topPeek = card!.top - scene!.top
      const bottomPeek = scene!.bottom - card!.bottom
      expect(
        Math.max(topPeek, bottomPeek),
        `asome vertical (top=${topPeek}, bottom=${bottomPeek})`,
      ).toBeGreaterThanOrEqual(MOBILE_MIN_VERTICAL_PEEK_PX)

      const sceneCenterX = (scene!.left + scene!.right) / 2
      const cardCenterX = (card!.left + card!.right) / 2
      expect(Math.abs(sceneCenterX - cardCenterX), 'centro de la escena vs. centro del Card, en X').toBeLessThanOrEqual(
        CENTER_EPSILON_PX,
      )
    })

    // MAJOR 3: la banda 768–1024px no tenía ningún candado de scroll
    // horizontal — ahí la caja ya mide 860 (`md:`) mientras el viewport
    // todavía puede medir tan poco como 768/820px, y lo único que evita la
    // barra horizontal es el `overflow-hidden` preexistente del root.
    for (const viewport of TABLET_VIEWPORTS) {
      test(`@ ${viewport.width}x${viewport.height}: cero scroll horizontal (caja 860 puede exceder el viewport)`, async ({
        page,
      }) => {
        await page.setViewportSize(viewport)
        await page.goto(path)
        await waitForAuthGate(page)

        const { docScrollWidth } = await readBoxes(page)
        expect(docScrollWidth, `document.documentElement.scrollWidth=${docScrollWidth}`).toBeLessThanOrEqual(
          viewport.width,
        )
      })
    }
  })
}
