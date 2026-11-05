/**
 * edicion-operaciones-con-dinero (tanda C, 16.1) — pasada visual obligatoria (regla PO 2026-08-02: desktop Y mobile, claro Y
 * oscuro, antes del merge) del formulario de edición con sus bloques de dinero, el diálogo del plan y el historial de cambios.
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds) contra /dev-harness/edicion-dinero, que monta los componentes REALES
 * (`SaleForm`, `PurchaseForm`, `ExpenseForm`, `SaleOperationsList`) con un backend simulado por intercept de `fetch`.
 *
 * Además de capturar, fija los contratos que jsdom no puede ver:
 *   - el documento no desborda horizontalmente en 375 px;
 *   - el diálogo del plan entra completo en un teléfono y su CTA primario queda dentro del propio diálogo;
 *   - con un bloqueo, el CTA queda deshabilitado y el motivo es visible.
 */
import { test, expect, type Locator, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

function visible(loc: Locator): Locator {
  return loc.filter({ visible: true }).first()
}

const SHOT_DIR =
  process.env.EDICION_DINERO_SHOT_DIR ??
  'C:/Users/Usuario/Desktop/EIE/wt-edicion-c/openspec/changes/edicion-operaciones-con-dinero/evidence/tanda-c'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 768 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const

const THEMES = ['light', 'dark'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

async function abrir(page: Page, query: string, ready: (p: Page) => Locator) {
  await page.goto(`/dev-harness/edicion-dinero?${query}`)
  await expect(ready(page)).toBeVisible({ timeout: 150_000 })
}

async function sinDesborde(page: Page) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow, 'el documento no debe desbordar horizontalmente').toBeLessThanOrEqual(1)
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    const tag = `${vp.name}-${theme}`

    test(`formulario de venta a crédito en edición — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=venta`, (p) => p.getByLabel(/Vencimiento/i))
      await expect(page.getByLabel(/Vencimiento/i)).toHaveValue('2026-12-01')
      await expect(page.getByText(/Después de guardar/i)).toBeVisible()
      await expect(page.getByLabel(/Motivo del cambio/i)).toBeVisible()
      await page.screenshot({ path: `${SHOT_DIR}/formulario-venta-credito-${tag}.png`, fullPage: true })
      await sinDesborde(page)
    })

    test(`formulario de venta en efectivo en edición — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=venta-caja`, (p) => p.getByText(/Registrado en caja/i))
      await expect(page.getByRole('checkbox')).toHaveAttribute('data-state', 'checked')
      await page.screenshot({ path: `${SHOT_DIR}/formulario-venta-efectivo-${tag}.png`, fullPage: true })
      await sinDesborde(page)
    })

    test(`formulario de compra a crédito en edición — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=compra`, (p) => p.getByLabel(/Vencimiento/i))
      await expect(page.getByText(/Después de guardar/i)).toBeVisible()
      await page.screenshot({ path: `${SHOT_DIR}/formulario-compra-credito-${tag}.png`, fullPage: true })
      await sinDesborde(page)
    })

    test(`formulario de gasto en efectivo en edición — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=gasto`, (p) => p.getByText(/Registrado en caja/i))
      await expect(page.getByLabel(/Motivo del cambio/i)).toBeVisible()
      await page.screenshot({ path: `${SHOT_DIR}/formulario-gasto-efectivo-${tag}.png`, fullPage: true })
      await sinDesborde(page)
    })

    test(`diálogo del plan SIN bloqueo (cuenta corriente) — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=venta&plan=cuenta`, (p) => p.getByRole('button', { name: /Guardar cambios/i }))
      await page.getByRole('button', { name: /Guardar cambios/i }).click()

      const dialog = page.getByRole('alertdialog')
      await expect(dialog).toBeVisible()
      await expect(dialog.getByText(/Se revertirá el cargo/i)).toBeVisible()
      await expect(dialog.getByText(/Se registrará un cargo/i)).toBeVisible()
      const cta = dialog.getByRole('button', { name: /Confirmar y guardar/i })
      await expect(cta).toBeEnabled()
      await page.screenshot({ path: `${SHOT_DIR}/dialogo-plan-cuenta-${tag}.png` })

      const ctaBox = await cta.boundingBox()
      const dialogBox = await dialog.boundingBox()
      expect(ctaBox).not.toBeNull()
      expect(dialogBox).not.toBeNull()
      expect(ctaBox!.y + ctaBox!.height, 'el CTA debe quedar dentro del diálogo').toBeLessThanOrEqual(dialogBox!.y + dialogBox!.height + 1)
      expect(dialogBox!.x + dialogBox!.width, 'el diálogo no debe desbordar el viewport').toBeLessThanOrEqual(vp.width + 1)
    })

    test(`diálogo del plan en efectivo (entra y sale de la caja) — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=venta-caja&plan=caja`, (p) => p.getByRole('button', { name: /Guardar cambios/i }))
      await page.getByRole('button', { name: /Guardar cambios/i }).click()
      const dialog = page.getByRole('alertdialog')
      await expect(dialog.getByText(/Salen .* de la caja/i)).toBeVisible()
      await expect(dialog.getByText(/Entran .* a la caja/i)).toBeVisible()
      await page.screenshot({ path: `${SHOT_DIR}/dialogo-plan-caja-${tag}.png` })
    })

    test(`diálogo del plan CON bloqueo — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=venta&plan=bloqueo`, (p) => p.getByRole('button', { name: /Guardar cambios/i }))
      await page.getByRole('button', { name: /Guardar cambios/i }).click()

      const dialog = page.getByRole('alertdialog')
      await expect(dialog).toBeVisible()
      await expect(dialog.getByRole('alert')).toContainText(/Abrí la caja/i)
      await expect(dialog.getByRole('alert')).toContainText(/Anulá primero el cobro/i)
      const cta = dialog.getByRole('button', { name: /Confirmar y guardar/i })
      await expect(cta).toBeDisabled()
      await page.screenshot({ path: `${SHOT_DIR}/dialogo-plan-bloqueo-${tag}.png` })

      // Los motivos se leen enteros: el diálogo no recorta el aviso en un teléfono.
      const dialogBox = await dialog.boundingBox()
      expect(dialogBox!.x + dialogBox!.width).toBeLessThanOrEqual(vp.width + 1)
      expect(dialogBox!.y + dialogBox!.height).toBeLessThanOrEqual(vp.height + 1)
    })

    test(`historial de cambios en el detalle expandido — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, `theme=${theme}&view=lista`, (p) => visible(p.getByText('Remera algodón')))
      await visible(page.getByText('Remera algodón')).click()
      const toggle = visible(page.getByRole('button', { name: /Historial de cambios/i }))
      await expect(toggle).toBeVisible()
      await toggle.click()
      await expect(page.getByText('Laura Gómez')).toBeVisible()
      await expect(page.getByText(/Motivo: El cliente llevó dos unidades más/i)).toBeVisible()
      await page.screenshot({ path: `${SHOT_DIR}/historial-${tag}.png`, fullPage: true })
      await sinDesborde(page)
    })
  }
}
