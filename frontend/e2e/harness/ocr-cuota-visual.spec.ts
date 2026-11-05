/**
 * v31-ia-ratelimit-budget (task 4.9) — pasada visual del diálogo «Leer factura con IA» en `/compras`.
 *
 * Tres estados (con saldo, en 0, error de ráfaga) x cuatro combinaciones (1366 / 375 x claro / oscuro).
 * Contra /dev-harness/ocr-cuota, que monta el `InvoiceAIButton` real sin sesión ni backend. Lo que fija
 * en un navegador real y jsdom no puede ver: el diálogo no desborda el viewport en 375 px, el CTA
 * «Ver planes» está en el viewport, y el texto del aviso cumple contraste AA (>= 4,5:1) en ambos temas.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR = process.env.OCR_CUOTA_SHOT_DIR ?? '../openspec/changes/v31-ia-ratelimit-budget/evidence'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 900 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const
const THEMES = ['light', 'dark'] as const
const STATES = ['saldo', 'cero', 'rafaga'] as const

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
    // Fondo efectivo: compone las capas translúcidas hasta llegar a una opaca.
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
      test(`diálogo OCR — ${state} — ${vp.name} ${theme}`, async ({ page }) => {
        await page.setViewportSize({ width: vp.width, height: vp.height })
        await page.goto(`/dev-harness/ocr-cuota?theme=${theme}&state=${state}`)

        // Techo generoso: el primer test paga la compilación en frío de la ruta (Turbopack).
        const trigger = page.getByRole('button', { name: /subir factura ia/i })
        await expect(trigger).toBeVisible({ timeout: 150_000 })
        await trigger.click()
        const dialog = page.getByRole('dialog')
        await expect(dialog).toBeVisible()

        if (state === 'saldo') {
          await expect(dialog.getByText('Te quedan 18 lecturas de factura este mes')).toBeVisible()
          await expect(dialog.locator('input[type="file"]').first()).toBeAttached()
          expect(await contrastOf(page, '[role="dialog"] p.text-muted-foreground')).toBeGreaterThanOrEqual(4.5)
        }

        if (state === 'cero') {
          await expect(dialog.getByText(/Usaste las 5 lecturas de factura de tu plan este mes\. Se renuevan el 1 de /)).toBeVisible()
          const planes = dialog.getByRole('link', { name: 'Ver planes' })
          await expect(planes).toBeInViewport()
          await expect(planes).toHaveAttribute('href', '/planes')
          // Sin zona de subida: ningún <input type=file>.
          await expect(dialog.locator('input[type="file"]')).toHaveCount(0)
          expect(await contrastOf(page, '[role="dialog"] span')).toBeGreaterThanOrEqual(4.5)
        }

        if (state === 'rafaga') {
          await dialog.locator('input[type="file"]').first().setInputFiles({
            name: 'factura.png', mimeType: 'image/png', buffer: Buffer.from('x'),
          })
          await expect(dialog.getByText('Esperá 40 segundos y volvé a intentar')).toBeVisible()
        }

        // El diálogo no desborda el viewport (375 px incluido).
        const box = await dialog.boundingBox()
        expect(box).not.toBeNull()
        expect(box!.x).toBeGreaterThanOrEqual(0)
        expect(box!.x + box!.width).toBeLessThanOrEqual(vp.width + 1)
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
        expect(overflow).toBeLessThanOrEqual(0)

        await page.screenshot({ path: `${SHOT_DIR}/${state}-${vp.name}-${theme}.png` })
      })
    }
  }
}
