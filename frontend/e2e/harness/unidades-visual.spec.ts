/**
 * ventas-unidades-conversion — pasada visual obligatoria (regla PO 2026-08-02:
 * desktop Y mobile, claro Y oscuro, antes del merge).
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds) contra
 * /dev-harness/unidades, que monta las columnas reales de /stock, filas reales
 * del historial y el formulario de venta real con un catálogo sintético.
 *
 * Además de capturar, fija dos contratos que jsdom no puede ver en un
 * navegador real:
 *   - el listado de stock no desborda horizontalmente con "0.550 kg" en la
 *     columna y en la tarjeta móvil;
 *   - el selector de unidad de un producto en kilos ofrece SOLO kg/g/tn (nunca
 *     mL, L, m, u), y el de un producto sin unidad base sólo unidades base.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR = process.env.VENTAS_UNIDADES_SHOT_DIR ?? './test-results/ventas-unidades-shots'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 768 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const

const THEMES = ['light', 'dark'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

async function abrirStock(page: Page, theme: string, mobile: boolean) {
  await page.goto(`/dev-harness/unidades?theme=${theme}&view=stock`)
  await expect(page.getByTestId('harness-stock')).toBeVisible({ timeout: 150_000 })
  // Escritorio: la celda dice "0.550 kg"; por debajo de md la tabla queda oculta
  // y la tarjeta móvil muestra "0.550 / 0.500 kg" (stock / mínimo, D8).
  await expect(page.getByText(mobile ? '0.550 / 0.500 kg' : '0.550 kg').first()).toBeVisible()
}

async function abrirFormulario(page: Page, theme: string) {
  await page.goto(`/dev-harness/unidades?theme=${theme}&view=form`)
  await expect(page.getByTestId('harness-form')).toBeVisible({ timeout: 150_000 })
}

async function elegirProducto(page: Page, nombre: string) {
  // El ProductPicker no lleva nombre accesible: se ubica por su texto visible.
  await page.getByRole('combobox').filter({ hasText: 'Seleccionar producto' }).first().click()
  const search = page.getByPlaceholder('Buscar producto...')
  await expect(search).toBeVisible()
  await search.fill(nombre)
  await page.getByRole('option', { name: new RegExp(nombre, 'i') }).first().click()
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    test(`stock e historial con unidad — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      const mobile = vp.width < 768
      await abrirStock(page, theme, mobile)

      // Producto por unidades: sin decimales y "uds"; en kilos: tres decimales y "kg".
      await expect(page.getByText(mobile ? '12 / 30 uds' : '12 uds').first()).toBeVisible()
      await expect(page.getByText('-0.450 kg').first()).toBeVisible()

      await page.screenshot({ path: `${SHOT_DIR}/stock-${vp.name}-${theme}.png`, fullPage: true })

      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      )
      expect(overflow, 'el documento no debe desbordar horizontalmente').toBeLessThanOrEqual(1)
    })

    test(`selector de unidad compatible — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrirFormulario(page, theme)

      // Producto en kilos: la unidad base queda preseleccionada y el selector
      // ofrece sólo las de peso.
      await elegirProducto(page, 'Tomate redondo')
      const trigger = page.getByRole('combobox').filter({ hasText: /Kilogramo/ }).first()
      await expect(trigger).toBeVisible()
      await trigger.click()
      const listbox = page.getByRole('listbox')
      await expect(listbox).toBeVisible()
      await expect(listbox.getByRole('option', { name: /Gramo/ })).toBeVisible()
      await expect(listbox.getByRole('option', { name: /Tonelada/ })).toBeVisible()
      await expect(listbox.getByRole('option', { name: /Mililitro|Litro|Metro|Docena|Sin unidad/ })).toHaveCount(0)

      await page.screenshot({ path: `${SHOT_DIR}/selector-kg-${vp.name}-${theme}.png` })

      // Vender 450 g: la cantidad muestra la unidad elegida.
      await listbox.getByRole('option', { name: /Gramo/ }).click()
      await expect(page.getByText(/Cantidad \(g\)/)).toBeVisible()
      await page.screenshot({ path: `${SHOT_DIR}/linea-gramos-${vp.name}-${theme}.png` })
    })
  }
}

test('producto sin unidad base: sólo unidades base', async ({ page }) => {
  await page.setViewportSize({ width: 1366, height: 768 })
  await abrirFormulario(page, 'light')
  await elegirProducto(page, 'Huevo')
  const trigger = page.getByRole('combobox').filter({ hasText: /Sin unidad|Base/ }).first()
  await trigger.click()
  const listbox = page.getByRole('listbox')
  await expect(listbox).toBeVisible()
  await expect(listbox.getByRole('option', { name: /Sin unidad \(base\)/ })).toBeVisible()
  await expect(listbox.getByRole('option', { name: /Kilogramo|Litro|Metro|Unidad$|— Unidad/ }).first()).toBeVisible()
  await expect(listbox.getByRole('option', { name: /Gramo|Docena|Mililitro|Caja/ })).toHaveCount(0)
  await page.screenshot({ path: `${SHOT_DIR}/selector-sin-base-desktop-1366-light.png` })
})
