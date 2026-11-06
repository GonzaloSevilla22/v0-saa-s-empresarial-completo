/**
 * productos-padre-variantes (task 12.2) — pasada visual obligatoria (regla PO 2026-08-02: desktop Y
 * mobile, claro Y oscuro, antes del merge) de /productos: el paso «¿Qué querés crear?», los tres
 * formularios (padre, simple, variante), «Corregir unidad» (con y sin conflicto) y «Modificar precios»
 * (con vista previa), más el listado con el rango «desde $X» del padre.
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds) contra /dev-harness/productos-padre, que monta
 * la PÁGINA REAL con un backend simulado por intercept de `fetch`. Además de capturar, fija lo que
 * jsdom no puede ver: ningún diálogo desborda el viewport (375 px incluido), el documento no desborda
 * horizontalmente, el CTA primario de cada diálogo queda dentro del viewport y los textos de ayuda /
 * avisos cumplen contraste AA (>= 4,5:1) en los dos temas.
 */
import { test, expect, type Locator, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR =
  process.env.PRODUCTOS_PADRE_SHOT_DIR ?? '../openspec/changes/productos-padre-variantes/evidence/tanda-b'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 800 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const
const THEMES = ['light', 'dark'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

function visible(loc: Locator): Locator {
  return loc.filter({ visible: true }).first()
}

/** Contraste WCAG entre el color del texto y el fondo opaco efectivo del primer elemento que matchea. */
async function contrastOf(page: Page, selector: string): Promise<number> {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel) as HTMLElement
    if (!el) throw new Error(`contrastOf: no existe ${sel}`)
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

async function abrir(page: Page, vp: { width: number; height: number }, theme: string) {
  await page.setViewportSize({ width: vp.width, height: vp.height })
  await page.goto(`/dev-harness/productos-padre?theme=${theme}`)
  // Techo generoso: el primer test paga la compilación en frío de la ruta (Turbopack).
  await expect(page.getByRole('button', { name: /nuevo producto/i }).first()).toBeVisible({ timeout: 180_000 })
  // El listado renderiza cada fila dos veces (tarjeta móvil + tabla de escritorio): sólo una es visible.
  await expect(visible(page.getByText('Aceite suelto'))).toBeVisible()
}

async function dialogEntraEnElViewport(page: Page, vp: { width: number; height: number }) {
  const dialog = page.getByRole('dialog').last()
  const box = await dialog.boundingBox()
  expect(box, 'el diálogo tiene caja').not.toBeNull()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(vp.width + 1)
  expect(box!.y).toBeGreaterThanOrEqual(0)
  expect(box!.y + box!.height).toBeLessThanOrEqual(vp.height + 1)
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow, 'el documento no desborda horizontalmente').toBeLessThanOrEqual(1)
  // El CONTENIDO tampoco desborda el diálogo (sus hijos no lo ensanchan ni se recortan por la derecha).
  const contentOverflow = await dialog.evaluate((el) => el.scrollWidth - el.clientWidth)
  expect(contentOverflow, 'el contenido no desborda el diálogo').toBeLessThanOrEqual(1)
}

async function elegirOpcion(page: Page, trigger: Locator, option: RegExp) {
  await trigger.click()
  await page.getByRole('option', { name: option }).first().click()
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    const tag = `${vp.name}-${theme}`

    test(`alta: paso, formulario del padre y primera variante — ${tag}`, async ({ page }) => {
      await abrir(page, vp, theme)
      await visible(page.getByRole('button', { name: /nuevo producto/i })).click()
      const dialog = page.getByRole('dialog')

      // Paso «¿Qué querés crear?»
      await expect(dialog.getByRole('radiogroup', { name: /qué querés crear/i })).toBeVisible()
      await expect(dialog.getByRole('button', { name: /continuar/i })).toBeDisabled()
      await dialogEntraEnElViewport(page, vp)
      expect(await contrastOf(page, '[role="dialog"] [id$="-simple-description"]')).toBeGreaterThanOrEqual(4.5)
      await page.screenshot({ path: `${SHOT_DIR}/01-paso-${tag}.png` })

      // Formulario del padre: sólo nombre, categoría y unidad de la familia.
      await dialog.getByRole('radio', { name: /producto con variantes/i }).click()
      await dialog.getByRole('button', { name: /continuar/i }).click()
      await expect(dialog.getByLabel(/^nombre/i)).toBeVisible()
      await expect(dialog.getByText(/unidad de la familia/i)).toBeVisible()
      for (const absent of [/stock inicial/i, /stock mínimo/i, /código de barras/i, /código de balanza/i, /^sku/i, /^precio/i, /^costo/i]) {
        await expect(dialog.getByLabel(absent)).toHaveCount(0)
      }
      await dialogEntraEnElViewport(page, vp)
      await page.screenshot({ path: `${SHOT_DIR}/02-padre-${tag}.png` })

      // Crear el padre → «Agregar la primera variante» con el padre fijo.
      await dialog.getByLabel(/^nombre/i).fill('Remeras de algodón')
      const combos = dialog.getByRole('combobox')
      await elegirOpcion(page, combos.nth(0), /^ropa/i)
      await elegirOpcion(page, combos.nth(1), /^unidad/i)
      await dialog.getByRole('button', { name: /crear y agregar variantes/i }).click()
      await expect(dialog.getByText(/agregar la primera variante/i)).toBeVisible()
      await expect(dialog.getByText('Remeras de algodón')).toBeVisible()
      await expect(dialog.getByTestId('inherited-unit')).toContainText(/unidad/i)
      await dialogEntraEnElViewport(page, vp)
      expect(await contrastOf(page, '[role="dialog"] p.text-muted-foreground')).toBeGreaterThanOrEqual(4.5)
      await page.screenshot({ path: `${SHOT_DIR}/03-primera-variante-${tag}.png` })
    })

    test(`alta: producto simple con la sugerencia ×1,5 — ${tag}`, async ({ page }) => {
      await abrir(page, vp, theme)
      await visible(page.getByRole('button', { name: /nuevo producto/i })).click()
      const dialog = page.getByRole('dialog')
      await dialog.getByRole('radio', { name: /producto simple/i }).click()
      await dialog.getByRole('button', { name: /continuar/i }).click()

      await expect(dialog.getByText(/producto padre/i)).toHaveCount(0)
      await dialog.getByLabel(/^costo/i).fill('1000')
      await expect(dialog.getByLabel(/^precio/i)).toHaveValue('1500')
      await dialog.getByLabel(/^precio/i).fill('1700')
      await dialog.getByLabel(/^costo/i).fill('2000')
      await expect(dialog.getByLabel(/^precio/i)).toHaveValue('1700') // lo escrito no se pisa
      await dialog.getByLabel(/^costo/i).fill('1000')
      await expect(dialog.getByText(/costo × 1,5/i)).toBeVisible()
      expect(await contrastOf(page, '[role="dialog"] p.text-muted-foreground')).toBeGreaterThanOrEqual(4.5)
      await page.screenshot({ path: `${SHOT_DIR}/04-simple-${tag}.png` })
    })

    test(`variante desde la fila: categoría y unidad en sólo lectura — ${tag}`, async ({ page }) => {
      await abrir(page, vp, theme)
      await visible(page.getByRole('button', { name: /^variante$/i }).filter({ has: page.locator('svg') })).click()
      const dialog = page.getByRole('dialog')

      await expect(dialog.getByText('Variante de:')).toBeVisible()
      await expect(dialog.getByTestId('inherited-category')).toBeVisible()
      await expect(dialog.getByTestId('inherited-unit')).toBeVisible()
      await expect(dialog.getByText(/producto padre \(variante\)/i)).toHaveCount(0)
      await dialogEntraEnElViewport(page, vp)
      await page.screenshot({ path: `${SHOT_DIR}/05-variante-${tag}.png` })
    })

    test(`Corregir unidad: vista previa y conflicto — ${tag}`, async ({ page }) => {
      await abrir(page, vp, theme)

      // Harina: stock en la variante → el selector libre se reemplaza por la acción.
      await visible(page.getByRole('button', { name: 'Editar Harina 000' })).click()
      let dialog = page.getByRole('dialog')
      await expect(dialog.getByRole('button', { name: /corregir unidad/i })).toBeVisible()
      await expect(dialog.getByTestId('current-unit')).toContainText(/unidad/i)
      await page.screenshot({ path: `${SHOT_DIR}/06-padre-con-historia-${tag}.png` })

      await dialog.getByRole('button', { name: /corregir unidad/i }).click()
      dialog = page.getByRole('dialog').last()
      await elegirOpcion(page, dialog.getByRole('combobox'), /kilogramo/i)
      await expect(dialog.getByText(/12 u pasarán a leerse 12 kg/i)).toBeVisible()
      await expect(dialog.getByRole('button', { name: /confirmar corrección/i })).toBeEnabled()
      await dialogEntraEnElViewport(page, vp)
      expect(await contrastOf(page, '[role="dialog"] p.text-xs.text-muted-foreground')).toBeGreaterThanOrEqual(4.5)
      await page.screenshot({ path: `${SHOT_DIR}/07-corregir-unidad-${tag}.png` })
      await dialog.getByRole('button', { name: /cancelar/i }).click()
      await page.keyboard.press('Escape')

      // Nike: una venta grabada en «Unidad» → otra unidad es conflicto y no se puede confirmar.
      await visible(page.getByRole('button', { name: 'Editar Zapatillas Nike' })).click()
      await page.getByRole('dialog').getByRole('button', { name: /corregir unidad/i }).click()
      dialog = page.getByRole('dialog').last()
      await elegirOpcion(page, dialog.getByRole('combobox'), /kilogramo/i)
      const alert = dialog.getByRole('alert')
      await expect(alert).toContainText(/otra unidad/i)
      await expect(dialog.getByRole('button', { name: /confirmar corrección/i })).toBeDisabled()
      await dialogEntraEnElViewport(page, vp)
      expect(await contrastOf(page, '[role="dialog"] [role="alert"] span')).toBeGreaterThanOrEqual(4.5)
      await page.screenshot({ path: `${SHOT_DIR}/08-corregir-unidad-conflicto-${tag}.png` })
    })

    test(`Modificar precios: vista previa antes de confirmar — ${tag}`, async ({ page }) => {
      await abrir(page, vp, theme)

      // El listado: el padre muestra «desde $X», nunca su precio 0.
      await expect(visible(page.getByText(/desde\s*\$\s*12\.000/))).toBeVisible()
      await page.screenshot({ path: `${SHOT_DIR}/09-listado-${tag}.png` })

      await visible(page.getByRole('checkbox', { name: 'Seleccionar Aceite suelto' })).click()
      await visible(page.getByRole('checkbox', { name: 'Seleccionar Zapatillas Nike' })).click()
      const bar = page.getByRole('region', { name: /acciones en lote/i })
      await expect(bar.getByRole('button', { name: /cambiar categoría/i })).toBeVisible()
      await bar.getByRole('button', { name: /modificar precios/i }).click()

      const dialog = page.getByRole('dialog')
      const apply = dialog.getByRole('button', { name: /aplicar cambio/i })
      await expect(apply).toBeDisabled()
      await dialog.getByLabel(/^valor/i).fill('10')
      await dialog.getByRole('button', { name: /ver vista previa/i }).click()
      await expect(dialog.getByTestId('bulk-price-preview')).toBeVisible()
      await expect(dialog.getByText(/productos cambian/i)).toBeVisible()
      await expect(dialog.getByText(/1 producto con variantes omitido/i)).toBeVisible()
      await expect(apply).toBeEnabled()
      await expect(apply).toBeInViewport()
      await dialogEntraEnElViewport(page, vp)
      expect(await contrastOf(page, '[data-testid="bulk-price-preview"] p.text-muted-foreground')).toBeGreaterThanOrEqual(4.5)
      await page.screenshot({ path: `${SHOT_DIR}/10-modificar-precios-${tag}.png` })

      // Tocar un valor invalida la vista previa.
      await dialog.getByLabel(/^valor/i).fill('15')
      await expect(apply).toBeDisabled()
    })
  }
}
