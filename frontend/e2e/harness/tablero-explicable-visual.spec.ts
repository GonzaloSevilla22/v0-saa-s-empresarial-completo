/**
 * tablero-explicable (task 5.2) — pasada visual del Tablero contra
 * /dev-harness/tablero-explicable (componentes reales, sin sesión ni backend).
 *
 * Cuatro combinaciones (1366 / 375 x claro / oscuro) de:
 *   - gráfico de ventas: 7 días y 30 días con comparación; con el aviso de
 *     «período anterior fuera del historial del plan» (?clamped=1);
 *   - diálogo «de dónde sale» de «Ganancia neta del mes»: foco atrapado, Esc,
 *     foco devuelto a la tarjeta, contraste AA y sin desborde en 375 px;
 *   - campana: panel abierto, descartar una fila (desaparece y el contador
 *     baja) y clic en una de stock (navega a /stock?product=…);
 *   - Resumen IA: en carga, con el texto y con el límite del plan (429).
 *
 * Lo que fija en un navegador real y jsdom no puede ver: layout a 375 px sin
 * desborde horizontal, foco real del diálogo y contraste del texto nuevo.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR = process.env.TABLERO_SHOT_DIR ?? '../openspec/changes/tablero-explicable/evidence'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 900 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const
const THEMES = ['light', 'dark'] as const

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

async function noHorizontalOverflow(page: Page) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(0)
}

async function open(page: Page, vp: { width: number; height: number }, query: string) {
  await page.setViewportSize({ width: vp.width, height: vp.height })
  // Sin backend: cualquier navegación a una pantalla real se aborta; sólo se observa la petición.
  await page.route(/\/(stock|caja|presupuestos|cobranzas|planes)(\?|$|\/)/, (route) => route.abort())
  await page.goto(`/dev-harness/tablero-explicable?${query}`)
  // Techo generoso: el primer test paga la compilación en frío de la ruta (Turbopack).
  await expect(page.getByTestId('chart')).toBeVisible({ timeout: 150_000 })
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    const tag = `${vp.name} ${theme}`
    const file = (name: string) => `${SHOT_DIR}/${name}-${vp.name}-${theme}.png`

    test(`gráfico — 7 y 30 días con comparación — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}`)
      const chart = page.getByTestId('chart')

      await expect(chart.getByText('Ventas · últimos 7 días')).toBeVisible()
      await expect(chart.getByRole('radio', { name: '7 días' })).toBeChecked()
      await expect(chart.getByText(/vs\. período anterior/)).toBeVisible()
      await expect(chart.locator('[role="img"]')).toBeVisible()
      await chart.scrollIntoViewIfNeeded()
      await page.screenshot({ path: file('grafico-7d') })

      await chart.getByRole('radio', { name: '30 días' }).click()
      await expect(chart.getByText('Ventas · últimos 30 días')).toBeVisible()
      await expect(chart.getByText(/vs\. período anterior/)).toBeVisible()
      await expect(chart.getByText(/queda fuera del historial/)).toHaveCount(0)
      await page.screenshot({ path: file('grafico-30d') })

      await chart.getByRole('radio', { name: 'Personalizado' }).click()
      await expect(chart.getByRole('button', { name: 'Fecha desde' })).toBeVisible()
      await expect(chart.getByRole('button', { name: 'Fecha hasta' })).toBeVisible()
      await page.screenshot({ path: file('grafico-personalizado') })

      await noHorizontalOverflow(page)
    })

    test(`gráfico — comparación fuera del historial del plan — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}&clamped=1`)
      const chart = page.getByTestId('chart')

      await chart.getByRole('radio', { name: '30 días' }).click()
      await expect(chart.getByText(/El período anterior queda fuera del historial de tu plan/)).toBeVisible()
      await expect(chart.getByRole('link', { name: 'Ver planes' })).toHaveAttribute('href', '/planes')
      await expect(chart.getByText(/vs\. período anterior/)).toHaveCount(0)
      await chart.scrollIntoViewIfNeeded()
      await page.screenshot({ path: file('grafico-aviso-historial') })

      await noHorizontalOverflow(page)
    })

    test(`«de dónde sale» — diálogo de Ganancia neta del mes — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}`)
      const card = page.getByRole('button', { name: /^Ganancia neta del mes: .*Ver de dónde sale$/ })
      await card.scrollIntoViewIfNeeded()
      await card.click()

      const dialog = page.getByRole('dialog', { name: 'Ganancia neta del mes' })
      await expect(dialog).toBeVisible()
      await expect(dialog.getByText(/Ventas del mes − Gastos del mes − Compras del mes/)).toBeVisible()
      await expect(dialog.getByText('Sucursal: Centro')).toBeVisible()
      await expect(dialog.getByRole('link', { name: /Ver el detalle en Reporte comparativo/ })).toBeVisible()

      // El diálogo (animado) tiene que haber terminado de entrar antes de medir/capturar.
      await dialog.evaluate((el) =>
        Promise.all(el.getAnimations({ subtree: true }).map((a) => a.finished.catch(() => undefined))),
      )

      // Foco atrapado: Tab nunca sale del diálogo.
      for (let i = 0; i < 6; i++) {
        await page.keyboard.press('Tab')
        const inside = await page.evaluate(() => !!document.activeElement?.closest('[role="dialog"]'))
        expect(inside).toBe(true)
      }

      // Cabe en el viewport (375 px incluido) y el texto cumple contraste AA.
      const box = await dialog.boundingBox()
      expect(box).not.toBeNull()
      expect(box!.x).toBeGreaterThanOrEqual(0)
      expect(box!.x + box!.width).toBeLessThanOrEqual(vp.width + 1)
      expect(await contrastOf(page, '[role="dialog"] section p')).toBeGreaterThanOrEqual(4.5)
      expect(await contrastOf(page, '[role="dialog"] section h3')).toBeGreaterThanOrEqual(4.5)
      await noHorizontalOverflow(page)
      await page.screenshot({ path: file('de-donde-sale-ganancia-mes') })

      // Esc cierra y devuelve el foco a la tarjeta.
      await page.keyboard.press('Escape')
      await expect(dialog).toBeHidden()
      await expect(card).toBeFocused()

      // La cruz también cierra.
      await card.click()
      await expect(dialog).toBeVisible()
      await dialog.getByRole('button', { name: 'Cerrar' }).click()
      await expect(dialog).toBeHidden()
    })

    test(`«Por cobrar» sigue siendo un enlace a /cobranzas — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}`)
      await expect(page.getByRole('link', { name: /Por cobrar/ })).toHaveAttribute('href', '/cobranzas')
      await expect(page.getByRole('button', { name: /Por cobrar/ })).toHaveCount(0)
    })

    test(`campana — descartar, ir a la alerta y cierre automático — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}`)
      const bell = page.getByTestId('campana').getByRole('button', { name: /Notificaciones/ })
      await expect(bell).toContainText('9+')
      await bell.click()

      const panel = page.getByRole('dialog', { name: 'Notificaciones' })
      await expect(panel).toBeVisible()
      await expect(panel.getByText('270 sin leer')).toBeVisible()
      await panel.evaluate((el) =>
        Promise.all(el.getAnimations({ subtree: true }).map((a) => a.finished.catch(() => undefined))),
      )
      await page.screenshot({ path: file('campana-abierta') })

      // Descartar: la fila desaparece y el contador baja; el panel sigue abierto.
      const rows = panel.getByRole('listitem')
      await expect(rows).toHaveCount(15)
      await panel.getByRole('button', { name: /^Descartar: / }).first().click()
      await expect(rows).toHaveCount(14)
      await expect(panel.getByText('269 sin leer')).toBeVisible()
      await expect(panel).toBeVisible()
      await page.screenshot({ path: file('campana-descartada') })

      // Clic en una de stock: navega a /stock?product=… y el panel se cierra solo.
      const nav = page.waitForRequest((r) => /\/stock\?product=5f1c2b3e-8a4d-4c6e-9b7a-0123456789ab/.test(r.url()))
      await panel.getByRole('button', { name: /Stock por debajo del mínimo.*Ir a Stock/ }).first().click()
      await nav
      await expect(panel).toBeHidden()

      await noHorizontalOverflow(page)
    })

    test(`Resumen IA — en carga — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}&ai=loading`)
      const ai = page.getByTestId('ai')
      const status = ai.getByRole('status')
      await expect(status).toContainText('Generando el resumen… suele tardar unos segundos')
      await expect(ai.getByText(/Cargando resumen inteligente/)).toHaveCount(0)
      await expect(ai.getByRole('button', { name: /Regenerar/ })).toBeDisabled()
      expect(await contrastOf(page, '[data-testid="ai"] [role="status"] span')).toBeGreaterThanOrEqual(4.5)
      await ai.scrollIntoViewIfNeeded()
      await page.screenshot({ path: file('resumen-ia-carga') })
      await noHorizontalOverflow(page)
    })

    test(`Resumen IA — con el texto del día — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}&ai=ok`)
      const ai = page.getByTestId('ai')
      await expect(ai.getByText(/Hoy vendiste \$184\.200 en 27 operaciones/)).toBeVisible()
      await expect(ai.getByRole('status')).toHaveCount(0)
      await expect(ai.getByRole('button', { name: /Regenerar/ })).toBeEnabled()
      await ai.scrollIntoViewIfNeeded()
      await page.screenshot({ path: file('resumen-ia-ok') })
      await noHorizontalOverflow(page)
    })

    test(`Resumen IA — límite mensual del plan (429) — ${tag}`, async ({ page }) => {
      await open(page, vp, `theme=${theme}&ai=429`)
      const ai = page.getByTestId('ai')
      await expect(
        ai.getByText('Llegaste al límite mensual de consultas de IA de tu plan. Se reinicia el 1.º de cada mes.'),
      ).toBeVisible()
      await expect(ai.getByRole('button', { name: /Regenerar/ })).toBeEnabled()
      expect(await contrastOf(page, '[data-testid="ai"] [role="alert"]')).toBeGreaterThanOrEqual(4.5)
      await ai.scrollIntoViewIfNeeded()
      await page.screenshot({ path: file('resumen-ia-429') })
      await noHorizontalOverflow(page)
    })
  }
}
