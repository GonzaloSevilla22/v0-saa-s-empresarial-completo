/**
 * qa-integral-modulos G2 (H2): el <main> de SidebarInset sin min-w-0 dejaba
 * que cualquier contenido ancho estirara el documento entero (12 pantallas
 * desbordadas en móvil/tablet escondiendo botones primarios).
 *
 * Contrato:
 *  - RED (hoy falla): con contenido más ancho que el viewport en 390 px, el
 *    documento NO se estira (scrollWidth <= viewport) y el CTA primario queda
 *    dentro de la pantalla; el desborde vive en el contenedor con overflow
 *    propio de la tabla.
 *  - SANO (protege el desktop): en 1440 el sidebar mide 16rem expandido /
 *    3rem colapsado (collapsible="icon") y el inset ocupa el resto — el fix
 *    no cambia el layout de escritorio.
 *
 * jsdom siempre reporta scrollWidth 0 (el assert pasaría trivialmente ANTES
 * del fix) — por eso esto vive en Playwright (tasks.md 2.1/2.2).
 */
import { test, expect } from '@playwright/test'

const HARNESS = '/dev-harness/shell'

test.describe('G2 — móvil 390x844: el shell contiene el desborde', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test('el documento no se estira más allá del viewport con contenido ancho', async ({ page }) => {
    await page.goto(HARNESS)
    await expect(page.getByTestId('cta-primario')).toBeVisible()

    // Precondición: el contenido ES más ancho que el viewport (si no, el test
    // no probaría nada) — la tabla tiene ~700 px de columnas fijas.
    const tabla = page.getByTestId('tabla-ancha')
    const anchoContenido = await tabla.evaluate((el) => el.scrollWidth)
    expect(anchoContenido).toBeGreaterThan(390)

    // El contrato: el documento no se estira…
    const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth)
    expect(scrollWidth).toBeLessThanOrEqual(390)

    // …y el CTA primario queda dentro del viewport, no escondido a la derecha.
    const cta = await page.getByTestId('cta-primario').boundingBox()
    expect(cta).not.toBeNull()
    expect(cta!.x + cta!.width).toBeLessThanOrEqual(390)

    // El desborde queda scrolleable DENTRO de la tabla (overflow-x propio).
    const clientWidth = await tabla.evaluate((el) => el.clientWidth)
    expect(anchoContenido).toBeGreaterThan(clientWidth)
  })
})

test.describe('G2 — control desktop 1440x900: el layout no cambia', () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test('sidebar 16rem expandido / 3rem colapsado, inset ocupa el resto', async ({ page }) => {
    await page.goto(HARNESS)
    const sidebar = page.locator('[data-sidebar="sidebar"]')
    const inset = page.getByTestId('inset')

    // Tolerancia de 1 px: el contenedor lleva border-r, así que el panel
    // interno [data-sidebar="sidebar"] mide 255 (256 - 1 de borde).
    const cerca = (real: number, esperado: number) => Math.abs(real - esperado) <= 1

    await expect(sidebar).toBeVisible()
    const expandido = await sidebar.boundingBox()
    expect(expandido).not.toBeNull()
    expect(cerca(expandido!.width, 256)).toBe(true) // 16rem

    let insetBox = await inset.boundingBox()
    expect(insetBox).not.toBeNull()
    expect(cerca(insetBox!.width, 1440 - 256)).toBe(true)

    // Colapsar (collapsible="icon" — el modo de AppSidebar)
    await page.getByTestId('trigger-menu').click()
    await expect
      .poll(async () => cerca((await sidebar.boundingBox())!.width, 48), { timeout: 3000 })
      .toBe(true) // 3rem

    insetBox = await inset.boundingBox()
    expect(cerca(insetBox!.width, 1440 - 48)).toBe(true)

    // Reexpandir — vuelve al estado inicial
    await page.getByTestId('trigger-menu').click()
    await expect
      .poll(async () => cerca((await sidebar.boundingBox())!.width, 256), { timeout: 3000 })
      .toBe(true)
  })
})
