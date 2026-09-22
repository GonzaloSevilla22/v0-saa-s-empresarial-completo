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
 */
import { test, expect, type Page } from '@playwright/test'

/** Piso para que el desborde horizontal en escritorio SE VEA con claridad. */
const DESKTOP_MIN_OVERHANG_PX = 120

/** Piso para que el desborde vertical en mobile sea un asome real, no subpíxel. */
const MOBILE_MIN_VERTICAL_PEEK_PX = 24

/** Tolerancia de centrado (redondeo subpíxel — el borde del Card mide 0,8 px). */
const CENTER_EPSILON_PX = 2

const SCREENS = ['/auth/login', '/auth/register'] as const

const DESKTOP_VIEWPORTS = [
  { width: 1366, height: 768 },
  { width: 1920, height: 1080 },
] as const

const MOBILE_VIEWPORT = { width: 375, height: 812 } as const

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

async function readBoxes(page: Page): Promise<{ scene: Box | null; card: Box | null; docScrollWidth: number }> {
  return page.evaluate(() => {
    const rect = (testId: string) => {
      const el = document.querySelector(`[data-testid="${testId}"]`)
      if (!el) return null
      const r = el.getBoundingClientRect()
      return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }
    }
    return {
      scene: rect('scene-decorative-box'),
      card: rect('auth-card'),
      docScrollWidth: document.documentElement.scrollWidth,
    }
  })
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

        const { scene, card } = await readBoxes(page)
        expect(scene, 'falta [data-testid="scene-decorative-box"]').not.toBeNull()
        expect(card, 'falta [data-testid="auth-card"]').not.toBeNull()

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

      const { scene, card, docScrollWidth } = await readBoxes(page)
      expect(scene, 'falta [data-testid="scene-decorative-box"]').not.toBeNull()
      expect(card, 'falta [data-testid="auth-card"]').not.toBeNull()

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
  })
}
