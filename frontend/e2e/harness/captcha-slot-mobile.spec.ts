/**
 * fix/captcha-widget-mobile-overflow.
 *
 * Turnstile en `size: "flexible"` exige 300 px. Las pantallas de auth comparten
 * la misma geometría (`p-4` de página + borde + `p-4` de tarjeta), que en un
 * teléfono de 360 px —el ancho de Android más común— deja una columna de
 * 294,4 px. La librería fuerza igual su contenedor a 300 px, alineado a la
 * IZQUIERDA: el widget sobresalía 5,6 px sólo por la derecha, fuera de línea
 * con el input y el botón de la misma tarjeta.
 *
 * Contrato (por pantalla × ancho):
 *  - el marco del captcha mide lo que Turnstile necesita (300 flexible / 150
 *    compact) — si no, el widget no entra;
 *  - queda CENTRADO sobre su columna: el desborde, si lo hay, es simétrico;
 *  - ese desborde por lado no pasa de `CAPTCHA_MAX_OVERHANG_PX`, o sea que vive
 *    dentro del padding de la tarjeta y nunca toca su borde;
 *  - a 320 px, donde ni así entraría, se elige `compact`;
 *  - el documento no gana scroll horizontal.
 *
 * Por qué acá y no en vitest: jsdom no hace layout (todo mide 0). Y por qué el
 * E2E de siempre no lo veía: con `NEXT_PUBLIC_PLAYWRIGHT_LOCAL=true` el widget
 * se reemplaza por un stub, que antes era un `sr-only` suelto — ciego al
 * layout. Ahora el stub ocupa el MISMO slot y marco que el widget real
 * (`CaptchaWidget.test.tsx` fija que las clases son idénticas), así que medir
 * el marco acá es medir el hueco real donde cae el iframe de Turnstile. No
 * hace falta red ni la site key de prueba de Cloudflare.
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds): son rutas públicas.
 * Cubre las CINCO superficies que montan `CaptchaWidget` — una pantalla nueva
 * con captcha suma su fila a SCREENS.
 */
import { test, expect, type Page } from '@playwright/test'

import {
  CAPTCHA_MAX_OVERHANG_PX,
  TURNSTILE_COMPACT_WIDTH_PX,
  TURNSTILE_FLEXIBLE_MIN_WIDTH_PX,
} from '../../lib/captcha-layout'

interface Screen {
  name: string
  path: string
  /** Pasos para llegar al formulario que monta el captcha, si no es el inicial. */
  open?: (page: Page) => Promise<void>
}

const SCREENS: Screen[] = [
  { name: 'login', path: '/auth/login' },
  {
    name: 'login → enlace mágico',
    path: '/auth/login',
    open: async (page) => {
      await page.getByRole('button', { name: 'Entrar con enlace mágico' }).click()
    },
  },
  { name: 'registro', path: '/auth/register' },
  { name: 'recuperar contraseña', path: '/auth/forgot-password' },
  // Donde se reportó el defecto. Con `?email=` como llega desde el registro:
  // la pantalla renderiza igual sin él, pero así se mide el estado real.
  { name: 'reenvío de verificación', path: '/auth/verify-email?email=qa.captcha@local.test' },
]

const VIEWPORTS = [
  { width: 375, height: 812, size: 'flexible', frameWidth: TURNSTILE_FLEXIBLE_MIN_WIDTH_PX },
  { width: 360, height: 800, size: 'flexible', frameWidth: TURNSTILE_FLEXIBLE_MIN_WIDTH_PX },
  { width: 320, height: 568, size: 'compact', frameWidth: TURNSTILE_COMPACT_WIDTH_PX },
] as const

/** Tolerancia de redondeo subpíxel (el borde de la tarjeta mide 0,8 px). */
const EPSILON_PX = 1

for (const viewport of VIEWPORTS) {
  test.describe(`captcha en móvil ${viewport.width}x${viewport.height}`, () => {
    test.use({
      viewport: { width: viewport.width, height: viewport.height },
      hasTouch: true,
      isMobile: true,
    })

    for (const screen of SCREENS) {
      test(`${screen.name}: el marco entra centrado en su columna`, async ({ page }) => {
        await page.goto(screen.path)
        await screen.open?.(page)

        const slot = page.getByTestId('captcha-slot')
        await expect(slot).toHaveAttribute('data-captcha-size', viewport.size)

        const box = await page.evaluate(() => {
          const rect = (testId: string) => {
            const r = document.querySelector(`[data-testid="${testId}"]`)!.getBoundingClientRect()
            return { left: r.left, right: r.right, width: r.width }
          }
          return {
            slot: rect('captcha-slot'),
            frame: rect('captcha-frame'),
            docScrollWidth: document.documentElement.scrollWidth,
          }
        })

        // El marco mide lo que Turnstile necesita.
        expect(box.frame.width).toBeGreaterThanOrEqual(viewport.frameWidth - EPSILON_PX)

        // Centrado: lo que sobra (o falta) se reparte igual a ambos lados.
        // Antes del fix era 0 a la izquierda y 5,6 a la derecha.
        const leftGap = box.frame.left - box.slot.left
        const rightGap = box.slot.right - box.frame.right
        expect(Math.abs(leftGap - rightGap)).toBeLessThanOrEqual(EPSILON_PX)

        // El desborde por lado vive dentro del padding de la tarjeta.
        expect(-leftGap).toBeLessThanOrEqual(CAPTCHA_MAX_OVERHANG_PX)
        expect(-rightGap).toBeLessThanOrEqual(CAPTCHA_MAX_OVERHANG_PX)

        // Dentro de la pantalla y sin scroll horizontal.
        expect(box.frame.left).toBeGreaterThanOrEqual(0)
        expect(box.frame.right).toBeLessThanOrEqual(viewport.width)
        expect(box.docScrollWidth).toBeLessThanOrEqual(viewport.width)
      })
    }
  })
}
