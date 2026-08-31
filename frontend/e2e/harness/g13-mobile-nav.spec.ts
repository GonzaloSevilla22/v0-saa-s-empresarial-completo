/**
 * qa-integral-modulos G13 (H18/H19): navegación móvil.
 *
 *  - H18: el botón de menú medía 28x28 px — piso WCAG 24, objetivo 44.
 *  - H19: el drawer móvil del sidebar no mostraba la X ([&>button]:hidden) y
 *    no cerraba con Escape.
 *
 * RED sano (13.3): el sidebar desktop NO cambia — cubierto por el control de
 * g2-shell-overflow.spec.ts (mismo arnés, 1440).
 */
import { test, expect } from '@playwright/test'

const HARNESS = '/dev-harness/shell'

test.describe('G13 — móvil 390x844', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test('el botón de menú tiene área táctil de al menos 44x44', async ({ page }) => {
    await page.goto(HARNESS)
    const trigger = page.getByTestId('trigger-menu')
    await expect(trigger).toBeVisible()
    const box = await trigger.boundingBox()
    expect(box).not.toBeNull()
    expect(box!.width).toBeGreaterThanOrEqual(44)
    expect(box!.height).toBeGreaterThanOrEqual(44)
  })

  test('el drawer móvil muestra la X, cierra con la X y cierra con Escape', async ({ page }) => {
    await page.goto(HARNESS)

    // Abrir el drawer
    await page.getByTestId('trigger-menu').tap()
    const drawer = page.locator('[data-sidebar="sidebar"][data-mobile="true"]')
    await expect(drawer).toBeVisible()

    // La X existe y es visible (H19: hoy la esconde [&>button]:hidden)
    const cerrar = drawer.getByRole('button', { name: /close|cerrar/i })
    await expect(cerrar).toBeVisible()

    // …y su área táctil respeta el piso
    const box = await cerrar.boundingBox()
    expect(box).not.toBeNull()
    expect(box!.width).toBeGreaterThanOrEqual(24)
    expect(box!.height).toBeGreaterThanOrEqual(24)

    // Cierra con la X
    await cerrar.tap()
    await expect(drawer).toBeHidden()

    // Reabrir y cerrar con Escape (H19: hoy Escape no cierra)
    await page.getByTestId('trigger-menu').tap()
    await expect(drawer).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(drawer).toBeHidden()
  })
})
