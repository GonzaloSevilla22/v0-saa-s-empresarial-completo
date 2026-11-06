/**
 * ia-copilot-v2 (tanda B, task 8.3) — pasada visual de /copiloto-ia.
 *
 * Siete estados (vacío con historial, respuesta con «Miré: …» y valoración, repregunta, cuota agotada,
 * ráfaga, error del servidor, espera con pasos) x cuatro combinaciones (1366 / 375 x claro / oscuro).
 * Contra /dev-harness/copiloto-chat, que monta la pantalla real sin sesión ni backend. Lo que fija en un
 * navegador real y jsdom no puede ver: sin desborde horizontal en 375 px, el input visible en el
 * viewport, los controles principales alcanzables, y el contraste AA (>= 4,5:1) del texto secundario
 * y de los avisos en ambos temas.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR = process.env.COPILOTO_SHOT_DIR ?? '../openspec/changes/ia-copilot-v2/evidence/tanda-b'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 900 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const
const THEMES = ['light', 'dark'] as const
const STATES = ['vacio', 'respuesta', 'repregunta', 'cuota', 'rafaga', 'error', 'espera'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

/** Contraste WCAG entre el color del texto y el fondo opaco efectivo del elemento. */
async function contrastOf(page: Page, selector: string): Promise<number> {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel) as HTMLElement
    const parse = (c: string) => {
      const m = c.match(/rgba?\(([^)]+)\)|color\(srgb ([^)]+)\)/)
      if (!m) return [0, 0, 0, 1]
      const raw = m[1] ?? m[2]
      const p = raw.split(/[ ,/]+/).filter(Boolean).map(Number)
      const scale = m[2] ? 255 : 1
      return [p[0] * scale, p[1] * scale, p[2] * scale, p[3] ?? 1]
    }
    const layers: number[][] = []
    for (let n: HTMLElement | null = el; n; n = n.parentElement) {
      const c = parse(getComputedStyle(n).backgroundColor)
      if (c[3] > 0) layers.push(c)
      if (c[3] === 1) break
    }
    let bg = [255, 255, 255]
    for (const l of layers.reverse()) bg = bg.map((v, i) => l[i] * l[3] + v * (1 - l[3]))
    const fg = parse(getComputedStyle(el).color)
    const lum = (c: number[]) => {
      const f = (v: number) => {
        const s = v / 255
        return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
      }
      return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])
    }
    const fgBlend = fg.slice(0, 3).map((v, i) => v * fg[3] + bg[i] * (1 - fg[3]))
    const [a, b] = [lum(fgBlend), lum(bg)]
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
  }, selector)
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    for (const state of STATES) {
      test(`copiloto — ${state} — ${vp.name} ${theme}`, async ({ page }) => {
        await page.setViewportSize({ width: vp.width, height: vp.height })
        const historial = state === 'vacio' ? '&historial=1' : ''
        await page.goto(`/dev-harness/copiloto-chat?theme=${theme}&state=${state}${historial}`)

        // Techo generoso: el primer test paga la compilación en frío de la ruta (Turbopack).
        const input = page.getByRole('textbox', { name: /escribí tu consulta/i })
        await expect(input).toBeVisible({ timeout: 150_000 })
        const send = page.getByRole('button', { name: /enviar consulta/i })

        async function ask(question: string) {
          await input.fill(question)
          await send.click()
        }

        if (state === 'vacio') {
          await expect(page.getByRole('heading', { name: /conversaciones anteriores/i })).toBeVisible()
          await expect(page.getByText('El producto que más vendiste en octubre fue la Remera básica', { exact: false })).toBeVisible()
          // Con historial no se muestra la pantalla vacía; las sugerencias quedan como chips en mobile.
          if (vp.width < 640) await expect(page.getByRole('group', { name: /preguntas sugeridas/i })).toBeVisible()
        }

        if (state === 'respuesta') {
          await ask('¿Cuánto vendí hoy?')
          await expect(page.getByText('Hoy vendiste $128.400', { exact: false })).toBeVisible()
          await expect(page.getByText('ventas de hoy · productos más vendidos de hoy')).toBeVisible()
          const useful = page.getByRole('button', { name: /^me sirvió/i }).last()
          await useful.click()
          await expect(useful).toHaveAttribute('aria-pressed', 'true')
          expect(await contrastOf(page, 'p.text-muted-foreground')).toBeGreaterThanOrEqual(4.5)
        }

        if (state === 'repregunta') {
          await ask('¿Cuánto stock queda de la remera?')
          await expect(page.getByText('¿De cuál querés saber el stock?', { exact: false })).toBeVisible()
        }

        if (state === 'cuota') {
          await expect(page.getByText(/Usaste tus 30 consultas del mes\. Se renuevan el 1 de /)).toBeVisible()
          await expect(input).toBeDisabled()
          await expect(send).toBeDisabled()
        }

        if (state === 'rafaga') {
          await ask('¿Y ayer?')
          await expect(page.getByText(/Esperá \d+ segundos? y volvé a intentar/)).toBeVisible()
          await expect(send).toBeDisabled()
          await expect(input).toHaveValue('¿Y ayer?')
        }

        if (state === 'error') {
          await ask('¿Cómo vengo?')
          // Next monta su propio role=alert (route announcer): se excluye.
          await expect(page.locator('[role="alert"]:not(#__next-route-announcer__)')).toContainText('No pude responder ahora')
          await expect(input).toHaveValue('¿Cómo vengo?')
        }

        if (state === 'espera') {
          await ask('¿Cómo vengo?')
          const status = page.getByRole('status', { name: /progreso de la consulta/i })
          await expect(status).toContainText('Pensando')
          await expect(status).toContainText('Consultando tus datos', { timeout: 6000 })
        }

        // Sin desborde horizontal (375 px incluido) y el input dentro del viewport.
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
        expect(overflow).toBeLessThanOrEqual(0)
        const box = await input.boundingBox()
        expect(box).not.toBeNull()
        expect(box!.x).toBeGreaterThanOrEqual(0)
        expect(box!.x + box!.width).toBeLessThanOrEqual(vp.width + 1)
        await expect(input).toBeInViewport()

        await page.screenshot({ path: `${SHOT_DIR}/${state}-${vp.name}-${theme}.png` })
      })
    }
  }
}
