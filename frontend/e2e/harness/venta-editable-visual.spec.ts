/**
 * venta-editable-sin-cae — pasada visual obligatoria (regla PO 2026-08-02:
 * desktop Y mobile, claro Y oscuro, antes del merge).
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds) contra
 * /dev-harness/venta-editable, que monta el listado y el formulario REALES con
 * las cinco clases de venta que el change distingue.
 *
 * Además de capturar, fija dos contratos que jsdom no puede ver:
 *   - el lápiz de una venta con comprobante ANULABLE queda dentro del viewport
 *     y habilitado en los dos anchos;
 *   - el AlertDialog de confirmación ("Guardar y anular") entra completo en un
 *     teléfono de 375 px, con su CTA primario dentro del propio diálogo (el
 *     mismo hallazgo de dos capas que documenta emitir-suscripcion-receptor:
 *     comparar contra el viewport de la ventana NO alcanza, porque
 *     DialogContent tiene su propio max-h + overflow).
 */
import { test, expect, type Locator, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

/**
 * El listado renderiza la MISMA fila dos veces: un bloque `sm:hidden` para
 * móvil y otro `hidden sm:grid` para desktop. O sea que cualquier texto o
 * control de la fila resuelve a DOS elementos, de los cuales uno está oculto
 * por CSS según el ancho — `.first()` a secas toma el de móvil (primero en el
 * DOM) y en desktop ese es justamente el invisible. Hay que filtrar por
 * visibilidad, no por posición.
 */
function visible(loc: Locator): Locator {
  return loc.filter({ visible: true }).first()
}

const SHOT_DIR =
  process.env.VENTA_EDITABLE_SHOT_DIR ??
  'C:/Users/Usuario/AppData/Local/Temp/claude/C--Users-Usuario-Desktop-EIE-v0-saa-s-empresarial-completo/adf8d8bc-a124-4b10-bf33-910b2c79ed59/scratchpad/venta-editable/visual'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 768 },
  { name: 'mobile-375', width: 375, height: 812 },
] as const

const THEMES = ['light', 'dark'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

async function abrirListado(page: Page, theme: string) {
  await page.goto(`/dev-harness/venta-editable?theme=${theme}`)
  await expect(page.getByTestId('harness-list')).toBeVisible({ timeout: 150_000 })
  // Ancla: la fila con el comprobante anulable ya renderizada (ver `visible()`).
  await expect(visible(page.getByText('Comprobante pendiente (anulable)'))).toBeVisible()
}

async function abrirFormulario(page: Page, theme: string) {
  await page.goto(`/dev-harness/venta-editable?theme=${theme}&view=form`)
  await expect(page.getByTestId('harness-form')).toBeVisible({ timeout: 150_000 })
  await expect(page.getByText('Esta venta tiene un comprobante pendiente')).toBeVisible()
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    test(`listado — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrirListado(page, theme)

      await page.screenshot({
        path: `${SHOT_DIR}/listado-${vp.name}-${theme}.png`,
        fullPage: true,
      })

      // Sin scroll horizontal del documento (regla de responsive-shell).
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      )
      expect(overflow, 'el documento no debe desbordar horizontalmente').toBeLessThanOrEqual(1)
    })

    test(`detalle con badge Anulado — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrirListado(page, theme)

      // Expandir la fila del comprobante ANULADO para ver el badge y el CTA de
      // "Volver a facturar" (la re-emisión que habilita D5).
      await visible(page.getByText('Comprobante anulado')).click()
      await expect(visible(page.getByText('Anulado (no se envió a ARCA)'))).toBeVisible()
      await expect(visible(page.getByRole('button', { name: /Volver a facturar/i }))).toBeVisible()

      await page.screenshot({
        path: `${SHOT_DIR}/detalle-anulado-${vp.name}-${theme}.png`,
        fullPage: true,
      })
    })

    test(`formulario con aviso de anulación — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrirFormulario(page, theme)

      await expect(page.getByText('0003-00000005').first()).toBeVisible()
      await page.screenshot({
        path: `${SHOT_DIR}/formulario-aviso-${vp.name}-${theme}.png`,
        fullPage: true,
      })
    })

    test(`confirmación "Guardar y anular" — ${vp.name} ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height })
      await abrirFormulario(page, theme)

      await page.getByRole('button', { name: /Guardar cambios/i }).click()

      const dialog = page.getByRole('alertdialog')
      await expect(dialog).toBeVisible()
      await expect(dialog.getByText(/¿Guardar los cambios y anular el comprobante\?/i)).toBeVisible()

      await page.screenshot({
        path: `${SHOT_DIR}/confirmacion-anular-${vp.name}-${theme}.png`,
      })

      // El CTA primario tiene que entrar en el PROPIO diálogo, no sólo en el
      // viewport de la ventana (DialogContent tiene su max-h + overflow).
      const cta = dialog.getByRole('button', { name: /Guardar y anular/i })
      const ctaBox = await cta.boundingBox()
      const dialogBox = await dialog.boundingBox()
      expect(ctaBox, 'el CTA primario debe existir').not.toBeNull()
      expect(dialogBox, 'el diálogo debe existir').not.toBeNull()
      expect(
        ctaBox!.y + ctaBox!.height,
        'el CTA "Guardar y anular" debe quedar dentro del diálogo',
      ).toBeLessThanOrEqual(dialogBox!.y + dialogBox!.height + 1)
      expect(
        dialogBox!.x + dialogBox!.width,
        'el diálogo no debe desbordar el viewport',
      ).toBeLessThanOrEqual(vp.width + 1)
    })
  }
}

test('el lápiz de la venta anulable queda habilitado y avisa; los bloqueados no', async ({ page }) => {
  await page.setViewportSize({ width: 1366, height: 768 })
  await abrirListado(page, 'light')

  const anulable = visible(page.getByTitle(/se va a anular el comprobante pendiente 0003-00000005/i))
  await expect(anulable).toBeVisible()
  await expect(anulable).toBeEnabled()

  for (const motivo of [
    /autorizado por ARCA/i,
    /ya se envió a ARCA y estamos esperando la respuesta/i,
  ]) {
    const bloqueado = visible(page.getByTitle(motivo))
    await expect(bloqueado).toBeVisible()
    await expect(bloqueado).toBeDisabled()
  }
})
