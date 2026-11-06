/**
 * invitaciones-hardening (task 9.3) — pasada visual obligatoria (regla PO 2026-08-02: desktop Y mobile, claro Y oscuro,
 * antes del merge) de:
 *
 *   1. `/organizacion/invitar`: la lista con el estado de la última entrega («Enviado», «En cola», «No se pudo enviar»,
 *      «Sin confirmación»), vía /dev-harness/invitaciones (el `PendingInvitations` REAL con el listado sembrado).
 *   2. Regresión de la pantalla pública `/invitacion/<token>` (la URL se conserva, decisión del PO): sin sesión, el mensaje
 *      genérico con «Ingresar» y «Crear cuenta».
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds). Además de capturar, fija los contratos que jsdom no ve: el documento
 * no desborda horizontalmente en 375 px, «Reenviar» destacado entra en el viewport del teléfono, y los distintivos de las
 * cuatro entregas están presentes.
 */
import { test, expect, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const SHOT_DIR =
  process.env.INVITACIONES_SHOT_DIR ?? '../openspec/changes/invitaciones-hardening/evidence/visual'

const VIEWPORTS = [
  { name: 'desktop-1366', width: 1366, height: 900 },
  { name: 'mobile-375', width: 375, height: 1100 },
] as const
const THEMES = ['light', 'dark'] as const

const TOKEN = '0123456789abcdef'.repeat(4)

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

async function sinDesborde(page: Page) {
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  )
  expect(overflow, 'el documento no debe desbordar horizontalmente').toBeLessThanOrEqual(1)
}

for (const vp of VIEWPORTS) {
  for (const theme of THEMES) {
    test.describe(`${vp.name} · ${theme}`, () => {
      test.use({ viewport: { width: vp.width, height: vp.height } })

      test('lista de invitaciones con el estado de la entrega', async ({ page }) => {
        await page.goto(`/dev-harness/invitaciones?theme=${theme}`)
        const list = page.getByRole('list', { name: /invitaciones de la cuenta/i })
        await expect(list).toBeVisible({ timeout: 150_000 })

        for (const label of ['Enviado', 'En cola', 'No se pudo enviar', 'Sin confirmación']) {
          await expect(list.getByText(label, { exact: true }).first()).toBeVisible()
        }
        // La fila fallida destaca «Reenviar» (primario) y explica qué pasó; la enviada no.
        const failed = list.getByRole('listitem', { name: /fallida@ejemplo\.com: No se pudo enviar/i })
        await expect(failed.getByText(/el email no llegó a salir/i)).toBeVisible()
        const resend = failed.getByRole('button', { name: /reenviar la invitación a fallida@ejemplo\.com/i })
        await expect(resend).toBeInViewport()
        await expect(resend).toHaveClass(/bg-primary/)
        const sentRow = list.getByRole('listitem', { name: /enviada@ejemplo\.com: Enviado/i })
        await expect(sentRow.getByText(/el email no llegó a salir/i)).toHaveCount(0)

        await sinDesborde(page)
        await page.screenshot({ path: `${SHOT_DIR}/lista-${vp.name}-${theme}.png`, fullPage: true })
      })

      test('regresión: /invitacion/<token> sin sesión sigue igual', async ({ page }) => {
        await page.emulateMedia({ colorScheme: theme })
        await page.addInitScript((t) => {
          try {
            window.localStorage.setItem('theme', t)
          } catch {
            /* sin storage */
          }
        }, theme)
        await page.goto(`/invitacion/${TOKEN}`)
        await expect(page.getByText(/ingresá o creá tu cuenta/i).first()).toBeVisible({ timeout: 150_000 })
        await expect(page.getByRole('link', { name: /ingresar/i }).first()).toBeVisible()
        await expect(page.getByRole('link', { name: /crear cuenta/i }).first()).toBeVisible()
        // El token nunca se imprime en pantalla.
        expect(await page.locator('body').innerText()).not.toContain(TOKEN)
        await sinDesborde(page)
        await page.screenshot({ path: `${SHOT_DIR}/aceptacion-${vp.name}-${theme}.png`, fullPage: true })
      })
    })
  }
}
