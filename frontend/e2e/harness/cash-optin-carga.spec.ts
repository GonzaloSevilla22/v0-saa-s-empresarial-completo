/**
 * caja-optin-carga — pasada visual y contrato de layout del bloque «Registrar en caja».
 *
 * El bloque gana un estado («Verificando la caja…») mientras se averigua la sesión
 * de caja, y el botón de confirmar que lo acompaña se deshabilita. Lo que este spec
 * fija en un navegador real, y que jsdom no puede ver:
 *   - los tres estados se pintan (cargando con spinner, elegible con la casilla,
 *     sin caja con el motivo) y NO desbordan el viewport en 375 px;
 *   - el estado de carga se anuncia como `role="status"` (lector de pantalla) y el
 *     botón queda deshabilitado SÓLO ahí — con la sesión resuelta, haya o no, se
 *     habilita (no se bloquea para siempre);
 *   - las 4 combinaciones (desktop / 375 × claro / oscuro) quedan capturadas para la
 *     revisión visual del PR (regla del PO: desktop Y mobile, claro Y oscuro).
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds) contra /dev-harness/cash-optin,
 * que monta el `CashOptinBlock` real.
 */
import { test, expect } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR = process.env.CASH_OPTIN_SHOT_DIR ?? 'test-results/cash-optin-carga'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 900 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const

const THEMES = ['light', 'dark'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    test(`bloque de caja — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await page.goto(`/dev-harness/cash-optin?theme=${theme}`)

      const cargando = page.getByTestId('estado-cargando')
      const elegible = page.getByTestId('estado-elegible')
      const sinCaja = page.getByTestId('estado-sin-caja')
      // Techo generoso: el primer test paga la compilación en frío de la ruta (Turbopack).
      await expect(cargando).toBeVisible({ timeout: 150_000 })

      // (1) Cargando: aviso accesible con spinner y botón deshabilitado.
      const status = cargando.getByRole('status')
      await expect(status).toHaveText('Verificando la caja…')
      await expect(status).toHaveAttribute('aria-live', 'polite')
      await expect(status.locator('svg.animate-spin')).toBeVisible()
      await expect(cargando.getByRole('button', { name: 'Confirmar compra' })).toBeDisabled()
      await expect(cargando.getByRole('checkbox')).toHaveCount(0)

      // (2) Sesión abierta: casilla pre-marcada y botón habilitado.
      await expect(elegible.getByRole('checkbox')).toBeChecked()
      await expect(elegible.getByText(/Registrar en caja — sesión a1b2c3d4…/)).toBeVisible()
      await expect(elegible.getByRole('button', { name: 'Confirmar compra' })).toBeEnabled()
      await expect(elegible.getByRole('status')).toHaveCount(0)

      // (3) Sin caja abierta: el motivo, y el botón habilitado (no bloquea para siempre).
      await expect(sinCaja.getByRole('note')).toContainText('No hay caja abierta en esta sucursal')
      await expect(sinCaja.getByRole('button', { name: 'Confirmar compra' })).toBeEnabled()

      // Ningún estado desborda el viewport (375 px incluido).
      const overflow = await page.evaluate(() => ({
        doc: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        blocks: Array.from(document.querySelectorAll('section')).map(
          (s) => s.scrollWidth - s.clientWidth,
        ),
      }))
      expect(overflow.doc).toBeLessThanOrEqual(0)
      expect(overflow.blocks.every((d) => d <= 0)).toBe(true)

      await page.screenshot({ path: `${SHOT_DIR}/${vp.name}-${theme}.png`, fullPage: true })
    })
  }
}
