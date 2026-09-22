/**
 * fiscal-emision-segura (G5/H3, task 5.5 — pasada visual + contrato de layout).
 *
 * El diálogo de "Enviar al ARCA" gana un selector de receptor (identificado /
 * consumidor final). Lo que este spec fija, y que jsdom no puede ver:
 *   - el diálogo no desborda el viewport en 375 px (ni gana scroll horizontal);
 *   - el CTA primario queda dentro del viewport en los dos anchos;
 *   - las 4 combinaciones (1366 / 375 × claro / oscuro) quedan capturadas para
 *     la revisión visual del PR (regla del PO: desktop Y mobile, claro Y
 *     oscuro, antes del merge).
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds) contra
 * /dev-harness/emitir-suscripcion, que monta el componente real.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR =
  process.env.FISCAL_SHOT_DIR ??
  'C:/Users/Usuario/AppData/Local/Temp/claude/C--Users-Usuario-Desktop-EIE-v0-saa-s-empresarial-completo/adf8d8bc-a124-4b10-bf33-910b2c79ed59/scratchpad/fiscal-fix/visual'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 900 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const

const THEMES = ['light', 'dark'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

async function abrirDialogo(page: Page, theme: string) {
  await page.goto(`/dev-harness/emitir-suscripcion?theme=${theme}`)
  // Techo generoso porque el primer test paga la compilación en frío de la ruta
  // (Turbopack) y el diálogo se monta recién al hidratar. El ancla es el propio
  // diálogo y NO el heading del arnés: con el diálogo abierto, Radix marca
  // `aria-hidden` en el resto de la página y el h1 desaparece del árbol de
  // accesibilidad (lo aprendimos acá: el h1 no aparecía nunca).
  await expect(page.getByRole('dialog')).toBeVisible({ timeout: 150_000 })
  await expect(page.getByRole('radio', { name: /Identificado con CUIT o DNI/i })).toBeVisible()
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    test(`diálogo de suscripción — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrirDialogo(page, theme)

      // (1) Modo identificado (default) — captura.
      await page.screenshot({
        path: `${SHOT_DIR}/${vp.name}-${theme}-1-identificado.png`,
        fullPage: false,
      })

      // El diálogo no se sale del viewport ni genera scroll horizontal.
      const box = await page.getByRole('dialog').boundingBox()
      expect(box).not.toBeNull()
      if (box) {
        expect(box.x).toBeGreaterThanOrEqual(-1)
        expect(box.x + box.width).toBeLessThanOrEqual(vp.width + 1)
      }
      const docScroll = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      )
      expect(docScroll).toBeLessThanOrEqual(1)

      // (2) Modo consumidor final — el input desaparece y el CTA se habilita.
      await page.getByRole('radio', { name: /Consumidor final/i }).click()
      await expect(page.getByLabel(/CUIT o DNI del receptor/i)).toHaveCount(0)
      const cta = page.getByRole('button', { name: /Confirmar y enviar al ARCA/i })
      await expect(cta).toBeEnabled()

      await page.screenshot({
        path: `${SHOT_DIR}/${vp.name}-${theme}-2-consumidor-final.png`,
        fullPage: false,
      })

      // El CTA queda alcanzable dentro del viewport.
      const ctaBox = await cta.boundingBox()
      expect(ctaBox).not.toBeNull()
      if (ctaBox) {
        expect(ctaBox.x + ctaBox.width).toBeLessThanOrEqual(vp.width + 1)
        expect(ctaBox.y + ctaBox.height).toBeLessThanOrEqual(vp.height + 1)
      }

      // (3) El payload que sale al confirmar lleva los dos campos en null.
      await cta.click()
      await expect(page.getByTestId('ultimo-payload')).toContainText('"receptor_doc_tipo":null')
      await expect(page.getByTestId('ultimo-payload')).toContainText('"receptor_doc_nro":null')
    })
  }
}
