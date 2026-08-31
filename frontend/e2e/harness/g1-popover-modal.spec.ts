/**
 * qa-integral-modulos G1 (H1 — el bug del PO): el desplegable de productos no
 * se puede desplazar dentro de ningún modal.
 *
 * Contrato (funcional, independiente del mecanismo del fix):
 *  - SANO (protege la regresión): fuera de un modal el popover se portaliza a
 *    document.body, scrollea con la rueda y cierra por clic afuera y Escape.
 *  - BUG (RED — hoy falla): dentro de un Dialog / Sheet la lista del selector
 *    debe scrollear con la rueda y con el dedo; el último ítem debe ser
 *    alcanzable.
 *
 * Corre contra el arnés /dev-harness/popover (componentes reales del design
 * system, sin sesión ni seeds). jsdom no implementa layout ni scroll ante
 * wheel/touchmove, por eso esto vive en Playwright (tasks.md 1.1/1.2).
 */
import { test, expect } from '@playwright/test'
import { touchDragUp, wheelOver, scrollTopOf } from './helpers'

const HARNESS = '/dev-harness/popover'

test.describe('G1 — comportamiento sano fuera de modal (escritorio)', () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test('portaliza a document.body, scrollea con la rueda y cierra por clic afuera y Escape', async ({ page }) => {
    await page.goto(HARNESS)
    const seccion = page.getByTestId('seccion-fuera')
    await seccion.getByRole('combobox').click()

    const lista = page.locator('[cmdk-list]')
    await expect(lista).toBeVisible()

    // Portal al body (comportamiento actual sano — no debe cambiar fuera de modales)
    expect(
      await page.evaluate(() => {
        const wrapper = document.querySelector('[data-radix-popper-content-wrapper]')
        return wrapper?.parentElement === document.body
      }),
    ).toBe(true)

    // Scrollea con la rueda
    await wheelOver(page, lista, 300)
    await expect.poll(() => scrollTopOf(lista), { timeout: 3000 }).toBeGreaterThan(0)

    // Cierra por Escape
    await page.keyboard.press('Escape')
    await expect(lista).toBeHidden()

    // Cierra por clic afuera
    await seccion.getByRole('combobox').click()
    await expect(page.locator('[cmdk-list]')).toBeVisible()
    await page.getByTestId('zona-neutra').click()
    await expect(page.locator('[cmdk-list]')).toBeHidden()
  })
})

test.describe('G1 — dentro de un Dialog (escritorio, rueda)', () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test('la lista del selector scrollea con la rueda dentro del Dialog', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('abrir-dialog').click()
    await page.getByTestId('select-en-dialog').getByRole('combobox').click()

    const lista = page.locator('[cmdk-list]')
    await expect(lista).toBeVisible()

    // Precondición: la lista es realmente scrolleable (32 ítems > alto visible)
    const overflow = await lista.evaluate((el) => el.scrollHeight - el.clientHeight)
    expect(overflow).toBeGreaterThan(0)

    await wheelOver(page, lista, 300)
    await expect.poll(() => scrollTopOf(lista), { timeout: 3000 }).toBeGreaterThan(0)
  })

  test('el último producto es alcanzable y visible (sin recorte, R1)', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('abrir-dialog').click()
    await page.getByTestId('select-en-dialog').getByRole('combobox').click()

    const lista = page.locator('[cmdk-list]')
    await expect(lista).toBeVisible()

    // Scroll hasta el fondo con la rueda (gesto de usuario, no scrollTop directo)
    for (let i = 0; i < 6; i++) {
      await wheelOver(page, lista, 400)
    }
    await expect
      .poll(() => lista.evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop), {
        timeout: 3000,
      })
      .toBeLessThan(4)

    // El último ítem responde al hit-test: no está recortado por el diálogo
    const ultimo = lista.getByText('Producto 32')
    await expect(ultimo).toBeVisible()
    const enHitTest = await ultimo.evaluate((el) => {
      const r = el.getBoundingClientRect()
      const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
      return hit !== null && (el.contains(hit) || hit.contains(el))
    })
    expect(enHitTest).toBe(true)
  })

  test('el product-picker también scrollea dentro del Dialog', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('abrir-dialog').click()
    await page.getByTestId('picker-en-dialog').getByRole('combobox').click()

    const lista = page.locator('[cmdk-list]')
    await expect(lista).toBeVisible()
    await wheelOver(page, lista, 300)
    await expect.poll(() => scrollTopOf(lista), { timeout: 3000 }).toBeGreaterThan(0)
  })

  test('Escape y clic afuera cierran el desplegable sin cerrar el Dialog', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('abrir-dialog').click()
    const dialogo = page.getByTestId('dialog-content')

    await page.getByTestId('select-en-dialog').getByRole('combobox').click()
    await expect(page.locator('[cmdk-list]')).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page.locator('[cmdk-list]')).toBeHidden()
    await expect(dialogo).toBeVisible()

    await page.getByTestId('select-en-dialog').getByRole('combobox').click()
    await expect(page.locator('[cmdk-list]')).toBeVisible()
    // Clic sobre el cuerpo del diálogo, fuera del popover. Por coordenadas:
    // con el desplegable abierto el bloqueo modal pone pointer-events:none en
    // el resto de la página (así que el chequeo de accionabilidad de
    // locator.click() nunca lo consideraría clickeable) — el gesto real del
    // usuario es este pointerdown, y su contrato es "el primer toque afuera
    // cierra el desplegable, no el Dialog".
    const titulo = await dialogo.getByText('Formulario en Dialog').boundingBox()
    expect(titulo).not.toBeNull()
    await page.mouse.click(titulo!.x + titulo!.width / 2, titulo!.y + titulo!.height / 2)
    await expect(page.locator('[cmdk-list]')).toBeHidden()
    await expect(dialogo).toBeVisible()
  })
})

test.describe('G1 — táctil real en móvil 390x844', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test('la lista scrollea con el dedo dentro del Dialog', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('abrir-dialog').tap()
    await page.getByTestId('select-en-dialog').getByRole('combobox').tap()

    const lista = page.locator('[cmdk-list]')
    await expect(lista).toBeVisible()

    const box = await lista.boundingBox()
    expect(box).not.toBeNull()
    await touchDragUp(page, box!.x + box!.width / 2, box!.y + box!.height - 20, 200)
    await expect.poll(() => scrollTopOf(lista), { timeout: 3000 }).toBeGreaterThan(0)
  })

  test('la lista scrollea con el dedo dentro del Sheet (panel desde abajo)', async ({ page }) => {
    await page.goto(HARNESS)
    await page.getByTestId('abrir-sheet').tap()
    await page.getByTestId('select-en-sheet').getByRole('combobox').tap()

    const lista = page.locator('[cmdk-list]')
    await expect(lista).toBeVisible()

    const box = await lista.boundingBox()
    expect(box).not.toBeNull()
    await touchDragUp(page, box!.x + box!.width / 2, box!.y + box!.height - 20, 200)
    await expect.poll(() => scrollTopOf(lista), { timeout: 3000 }).toBeGreaterThan(0)
  })
})
