/**
 * qa-integral-modulos G5 (H5): la campana mostraba 6 de 15 notificaciones y el
 * panel no scrolleaba — el max-h-80 vivía en el ROOT del ScrollArea
 * (overflow-hidden, recorta) en vez del viewport interno (habilita el scroll).
 *
 * Contrato (funcional): con 15 notificaciones, el último ítem es ALCANZABLE
 * por scroll con la rueda y con el dedo; con pocas notificaciones el panel
 * sigue mostrando todo sin scroll (sano). jsdom no implementa layout ni
 * scroll, por eso esto vive en Playwright (task 5.1).
 */
import { test, expect } from '@playwright/test'
import { touchDragUp, wheelOver } from './helpers'

const HARNESS = '/dev-harness/bell'
const VIEWPORT_SEL = '[data-radix-scroll-area-viewport]'

test.describe('G5 — campana de notificaciones', () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test('con 15 notificaciones, la rueda scrollea el panel y el último ítem es alcanzable', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('campana-15').getByRole('button').click()

    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible()
    const items = menu.getByRole('menuitem')
    await expect(items).toHaveCount(15)

    const viewport = menu.locator(VIEWPORT_SEL)

    // Precondición del fixture: hay más contenido que alto visible.
    const clipped = await viewport.evaluate((el) => el.scrollHeight > el.clientHeight)
    expect(clipped, 'el fixture debe desbordar el max-h del panel').toBe(true)

    // La rueda tiene que mover la lista (hoy: scrollTop clavado en 0).
    await wheelOver(page, menu, 300)
    await expect
      .poll(() => viewport.evaluate((el) => el.scrollTop), { timeout: 3000 })
      .toBeGreaterThan(0)

    // Y el último ítem tiene que ser ALCANZABLE con el mismo gesto.
    for (let i = 0; i < 10; i++) {
      await wheelOver(page, menu, 300)
    }
    await expect
      .poll(
        () =>
          viewport.evaluate(
            (el) => el.scrollTop + el.clientHeight >= el.scrollHeight - 1,
          ),
        { timeout: 3000 },
      )
      .toBe(true)
    const lastBox = await items.nth(14).boundingBox()
    const menuBox = await menu.boundingBox()
    expect(lastBox, 'el último ítem debe tener caja visible').not.toBeNull()
    expect(menuBox).not.toBeNull()
    expect(lastBox!.y + lastBox!.height).toBeLessThanOrEqual(
      menuBox!.y + menuBox!.height + 1,
    )
  })

  test('con 15 notificaciones, el dedo también scrollea (táctil real por CDP)', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('campana-15').getByRole('button').click()

    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible()
    const viewport = menu.locator(VIEWPORT_SEL)

    const box = await menu.boundingBox()
    expect(box).not.toBeNull()
    await touchDragUp(page, box!.x + box!.width / 2, box!.y + box!.height * 0.7, 150)
    await expect
      .poll(() => viewport.evaluate((el) => el.scrollTop), { timeout: 3000 })
      .toBeGreaterThan(0)
  })

  test('SANO: con 3 notificaciones se ven las 3 sin necesidad de scroll', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('campana-3').getByRole('button').click()

    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible()
    const items = menu.getByRole('menuitem')
    await expect(items).toHaveCount(3)

    const menuBox = await menu.boundingBox()
    for (let i = 0; i < 3; i++) {
      const box = await items.nth(i).boundingBox()
      expect(box, `ítem ${i + 1} visible`).not.toBeNull()
      expect(box!.y).toBeGreaterThanOrEqual(menuBox!.y - 1)
      expect(box!.y + box!.height).toBeLessThanOrEqual(menuBox!.y + menuBox!.height + 1)
    }
  })
})
