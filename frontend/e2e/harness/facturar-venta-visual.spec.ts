/**
 * venta-editable-vs-promocion-legacy — pasada visual de los caminos de ERROR de
 * "Facturar" (regla PO 2026-08-02: desktop Y mobile, claro Y oscuro). El
 * camino feliz de punta a punta (En trámite → Autorizado con el stub) lo
 * cubre e2e/facturar-venta-manual.spec.ts contra el stack local real; estos
 * dos rechazos no se pueden provocar a demanda ahí, así que viven acá, contra
 * /dev-harness/facturar-venta (listado REAL, fetch interceptado).
 *
 * Contratos que jsdom no ve:
 *   - el toast del rechazo entra completo en el viewport (también a 375 px);
 *   - sin scroll horizontal del documento;
 *   - tras el rechazo de la emisión la fila VUELVE a "Facturar" (visible y
 *     habilitado), que es la salida del usuario.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'
import path from 'node:path'

// Local: FACTURAR_VISUAL_DIR apunta al directorio de evidencia; en CI las
// capturas quedan en test-results (se suben con el reporte si algo falla).
const SHOT_DIR = process.env.FACTURAR_VISUAL_DIR ?? path.join('test-results', 'facturar-venta-visual')

const VIEWPORTS = [
  { name: '1366x768', width: 1366, height: 768 },
  { name: '375x812', width: 375, height: 812 },
] as const
const THEMES = [{ id: 'light', label: 'claro' }, { id: 'dark', label: 'oscuro' }] as const

test.beforeAll(() => { mkdirSync(SHOT_DIR, { recursive: true }) })

async function abrir(page: Page, theme: string, error: string) {
  await page.goto(`/dev-harness/facturar-venta?theme=${theme}&error=${error}`)
  await expect(page.getByTestId('harness-title')).toBeVisible({ timeout: 150_000 })
  await page.getByText('Servicio de instalación').filter({ visible: true }).first().click()
  await expect(page.getByRole('button', { name: 'Facturar esta venta en AFIP' })).toBeVisible()
}

async function assertToastInViewport(page: Page, text: string, width: number, height: number) {
  const toast = page.locator('[data-sonner-toast]').filter({ hasText: text }).first()
  await expect(toast).toBeVisible({ timeout: 15_000 })
  // Sonner lo hace ENTRAR deslizándolo desde abajo (~400 ms): medido en el
  // primer cuadro, la caja todavía asoma por debajo del viewport (visto en la
  // primera corrida: bottom 815 > 769 en 6/8 casos, y la captura del fallo lo
  // mostraba entero). Se mide la caja YA ASENTADA — la aserción no se relaja:
  // si el toast asentado no entra, esto sigue fallando.
  await expect(toast).toHaveAttribute('data-mounted', 'true')
  await expect
    .poll(async () => {
      const b = await toast.boundingBox()
      return b ? b.y + b.height : Number.POSITIVE_INFINITY
    }, { timeout: 5_000 })
    .toBeLessThanOrEqual(height + 1)
  const box = await toast.boundingBox()
  expect(box, 'el toast tiene que tener caja').not.toBeNull()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.y).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(width + 1)
  expect(box!.y + box!.height).toBeLessThanOrEqual(height + 1)
}

async function noHorizontalScroll(page: Page) {
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  )
  expect(overflow, 'el documento no debe desbordar horizontalmente').toBeLessThanOrEqual(1)
}

for (const vp of VIEWPORTS) {
  for (const th of THEMES) {
    const tag = `${vp.name}-${th.label}`

    test(`emisión rechazada (sales_order_out_of_sync) — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, th.id, 'out_of_sync')
      await page.getByRole('button', { name: 'Facturar esta venta en AFIP' }).click()
      const emitir = page.getByRole('button', { name: /Emitir comprobante/ })
      await expect(emitir).toBeVisible()
      await emitir.click()

      const texto = 'La venta cambió después de prepararla para facturar. Tocá «Facturar» de nuevo para actualizarla.'
      await assertToastInViewport(page, texto, vp.width, vp.height)
      // La fila vuelve a "Facturar" (la salida del usuario), sin "Emitir".
      const facturar = page.getByRole('button', { name: 'Facturar esta venta en AFIP' })
      await expect(facturar).toBeVisible()
      await expect(facturar).toBeEnabled()
      await expect(page.getByRole('button', { name: /Emitir comprobante/ })).toHaveCount(0)
      await noHorizontalScroll(page)
      await page.screenshot({ path: `${SHOT_DIR}/harness-${tag}-error-out-of-sync.png` })
    })

    test(`preparación rechazada (operation_inconsistent) — ${tag}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrir(page, th.id, 'inconsistent')
      await page.getByRole('button', { name: 'Facturar esta venta en AFIP' }).click()

      const texto = 'Esta venta tiene ítems con distinto cliente o sucursal. Editala para unificarlos y después facturala.'
      await assertToastInViewport(page, texto, vp.width, vp.height)
      await expect(page.getByRole('button', { name: /Emitir comprobante/ })).toHaveCount(0)
      await noHorizontalScroll(page)
      await page.screenshot({ path: `${SHOT_DIR}/harness-${tag}-error-inconsistent.png` })
    })
  }
}
