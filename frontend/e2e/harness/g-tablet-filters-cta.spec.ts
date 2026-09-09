/**
 * tablet-filtros-cta: a 1024px con el riel del sidebar expandido, la barra de
 * FILTROS de /ventas, /gastos, /compras y /clientes no wrappeaba (a
 * diferencia de la barra de ACCIONES, que qa-integral-modulos G2 ya había
 * arreglado en la task 2.4) y empujaba el CTA primario fuera del viewport
 * inicial — alcanzable con el scroll propio del contenedor, pero no visible
 * al abrir (openspec/specs/responsive-shell/spec.md, cláusula que antes se
 * acotaba a móvil).
 *
 * Contrato:
 *  - RED (antes del fix): a 1024x768 con el sidebar expandido, el CTA
 *    primario queda con su borde derecho más allá de x=1024 (fuera del
 *    viewport inicial, sin haber scrolleado).
 *  - GREEN (con el fix): la barra de filtros wrappea (lg:flex-wrap en el
 *    contenedor + flex-wrap en el grupo de filtros) y el CTA cae dentro de
 *    0..1024 x 0..768, con scrollY === 0 (no hizo falta desplazarse).
 *
 * Igual que g2-shell-overflow.spec.ts: corre contra el arnés de
 * /dev-harness/tablet-filters (sin sesión ni seeds — ver
 * app/dev-harness/README.md), porque el contrato es puramente de layout
 * (CSS flex-wrap) y no depende de datos reales de ninguna de las 4 páginas.
 */
import { test, expect } from '@playwright/test'

const ROUTES = ['ventas', 'gastos', 'compras', 'clientes'] as const

test.describe('G-tablet-filters-cta — 1024x768, sidebar expandido', () => {
  test.use({ viewport: { width: 1024, height: 768 } })

  for (const route of ROUTES) {
    test(`el CTA primario de /${route} entra en el viewport inicial sin scroll`, async ({ page }) => {
      await page.goto(`/dev-harness/tablet-filters?route=${route}`)

      // Sidebar expandido (defaultOpen del arnés, mismo estado inicial que
      // AppSidebar en la app real) — precondición: si el sidebar colapsara
      // solo, el ancho disponible para la barra de controles sería mayor y
      // el test no probaría el caso real (riel expandido).
      const sidebar = page.locator('[data-sidebar="sidebar"]')
      await expect(sidebar).toBeVisible()
      const sidebarBox = await sidebar.boundingBox()
      expect(sidebarBox).not.toBeNull()
      expect(sidebarBox!.width).toBeGreaterThan(200) // ~256px expandido, no ~48px colapsado

      const cta = page.getByTestId('cta-primario')
      await expect(cta).toBeVisible()

      // El contrato: sin haber scrolleado…
      const scrollY = await page.evaluate(() => window.scrollY)
      expect(scrollY).toBe(0)

      // …el CTA cae dentro del viewport inicial (0..1024 x 0..768).
      const box = await cta.boundingBox()
      expect(box).not.toBeNull()
      expect(box!.x).toBeGreaterThanOrEqual(0)
      expect(box!.x + box!.width).toBeLessThanOrEqual(1024)
      expect(box!.y + box!.height).toBeLessThanOrEqual(768)

      // El documento tampoco se estiró horizontalmente (min-w-0 del shell,
      // ya cubierto por G2, pero es gratis reafirmarlo acá).
      const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth)
      expect(scrollWidth).toBeLessThanOrEqual(1024)
    })
  }
})

test.describe('G-tablet-filters-cta — control desktop 1440x900: el layout no cambia', () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test('a 1440px la barra de filtros de /ventas no necesita wrappear para que el CTA entre', async ({ page }) => {
    await page.goto('/dev-harness/tablet-filters?route=ventas')

    const cta = page.getByTestId('cta-primario')
    await expect(cta).toBeVisible()

    const scrollY = await page.evaluate(() => window.scrollY)
    expect(scrollY).toBe(0)

    const box = await cta.boundingBox()
    expect(box).not.toBeNull()
    expect(box!.x + box!.width).toBeLessThanOrEqual(1440)
  })
})
