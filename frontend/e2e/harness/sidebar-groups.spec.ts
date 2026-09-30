/**
 * sidebar-menu-grupos — el menú lateral por grupos plegables en un navegador
 * real (desktop Y móvil, tema claro Y oscuro, regla PO 2026-08-02).
 *
 * Corre en el proyecto `harness` (sin sesión ni seeds) contra
 * /dev-harness/sidebar, que monta el `AppSidebar` REAL (no una réplica).
 * Lo que jsdom no ve y acá sí:
 *   - el plegado/desplegado visible de verdad (el contenido no ocupa lugar
 *     cerrado, sí abierto);
 *   - con el riel colapsado, el desplegable a la derecha (un portal fuera del
 *     árbol del sidebar) con los módulos del grupo;
 *   - en móvil, el drawer con las categorías plegadas y su cierre con Escape.
 *
 * La navegación real rebota sin sesión, así que el cierre "al tocar un módulo"
 * se asserta cancelando la navegación del enlace (un listener de captura que
 * hace preventDefault: next/link ve `defaultPrevented` y no navega, pero el
 * onClick del módulo —que es el que cierra el grupo— sí corre). El cierre por
 * cambio de ruta real lo cubre AppSidebarGroups.test.tsx.
 *
 * Capturas (4 por combinación de tema): expandido cerrado, expandido con
 * Operaciones abierto, riel colapsado con el desplegable abierto y drawer móvil.
 * Destino: SIDEBAR_SHOT_DIR (por defecto ./test-results/sidebar-shots).
 */
import { test, expect, type Locator, type Page } from '@playwright/test'
import { mkdirSync } from 'node:fs'

const HARNESS = '/dev-harness/sidebar'
const SHOT_DIR = process.env.SIDEBAR_SHOT_DIR ?? './test-results/sidebar-shots'

const GRUPOS = ['Operaciones', 'Catálogo', 'Inteligencia', 'Estadísticas', 'Ecosistema', 'Mi Cuenta']
const MODULOS_OPERACIONES = ['Ventas', 'POS — Venta Rápida', 'Compras', 'Gastos', 'Caja', 'Banco', 'Cobranzas']
const THEMES = ['light', 'dark'] as const

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
})

async function setTheme(page: Page, theme: (typeof THEMES)[number]) {
  await page.evaluate((t) => document.documentElement.classList.toggle('dark', t === 'dark'), theme)
  // Los ítems del desplegable llevan transition-colors: sin esperar, la captura
  // sale a mitad del cambio de color (texto gris sobre fondo oscuro).
  await page.waitForTimeout(400)
}

/** Que tocar un enlace NO navegue (el onClick del módulo corre igual). */
async function cancelarNavegacion(page: Page) {
  await page.evaluate(() => {
    document.addEventListener(
      'click',
      (e) => {
        if ((e.target as Element | null)?.closest('a')) e.preventDefault()
      },
      true,
    )
  })
}

async function abrir(page: Page) {
  await page.goto(HARNESS)
  // La primera compilación de la ruta en frío puede tardar. Se espera el botón
  // del header (existe en escritorio y en móvil: en móvil el contenido del
  // sidebar vive dentro del drawer y no está en el DOM hasta abrirlo). El
  // AuthProvider sólo renderiza a sus hijos ya hidratados, así que con el
  // botón visible los handlers ya están puestos.
  await expect(page.getByTestId('trigger-menu')).toBeVisible({ timeout: 150_000 })
  await cancelarNavegacion(page)
}

const grupo = (page: Page, nombre: string) => page.getByRole('button', { name: nombre, exact: true })

test.describe('menú por grupos — escritorio 1440x900', () => {
  test.use({ viewport: { width: 1440, height: 900 } })

  test('carga con las seis categorías CERRADAS y el Tablero suelto arriba', async ({ page }) => {
    await abrir(page)

    for (const nombre of GRUPOS) {
      await expect(grupo(page, nombre)).toHaveAttribute('aria-expanded', 'false')
    }
    await expect(page.getByRole('link', { name: 'Tablero', exact: true })).toBeVisible()
    // Sin módulos de grupo a la vista ni rótulo "Principal".
    await expect(page.getByRole('link', { name: 'Ventas', exact: true })).toHaveCount(0)
    await expect(page.getByText('Principal', { exact: true })).toHaveCount(0)

    // El Tablero queda por encima de la primera categoría.
    const tablero = await page.getByRole('link', { name: 'Tablero', exact: true }).boundingBox()
    const operaciones = await grupo(page, 'Operaciones').boundingBox()
    expect(tablero).not.toBeNull()
    expect(operaciones).not.toBeNull()
    expect(tablero!.y).toBeLessThan(operaciones!.y)

    // En escritorio una fila del menú mide lo mismo que siempre (32 px); los
    // 44 px de objetivo táctil son sólo del drawer móvil (ver el caso móvil).
    expect(operaciones!.height).toBe(32)

    for (const theme of THEMES) {
      await setTheme(page, theme)
      await page.screenshot({ path: `${SHOT_DIR}/expandido-cerrado-${theme}.png` })
    }
  })

  test('tocar Operaciones muestra sus 7 módulos y tocar un módulo cierra el grupo solo', async ({ page }) => {
    await abrir(page)

    await grupo(page, 'Operaciones').click()
    await expect(grupo(page, 'Operaciones')).toHaveAttribute('aria-expanded', 'true')
    for (const nombre of MODULOS_OPERACIONES) {
      await expect(page.getByRole('link', { name: nombre, exact: true })).toBeVisible()
    }
    // Un módulo de fila mide lo mismo que los ítems de primer nivel de siempre.
    const fila = await page.getByRole('link', { name: 'Ventas', exact: true }).boundingBox()
    expect(fila!.height).toBe(32)

    for (const theme of THEMES) {
      await setTheme(page, theme)
      await page.screenshot({ path: `${SHOT_DIR}/expandido-operaciones-abierto-${theme}.png` })
    }

    await page.getByRole('link', { name: 'Ventas', exact: true }).click()
    await expect(grupo(page, 'Operaciones')).toHaveAttribute('aria-expanded', 'false')
    await expect(page.getByRole('link', { name: 'Ventas', exact: true })).toHaveCount(0)
  })

  test('abrir otra categoría cierra la que estaba abierta (un solo grupo a la vez)', async ({ page }) => {
    await abrir(page)

    await grupo(page, 'Operaciones').click()
    await expect(page.getByRole('link', { name: 'Compras', exact: true })).toBeVisible()

    await grupo(page, 'Estadísticas').click()
    await expect(grupo(page, 'Operaciones')).toHaveAttribute('aria-expanded', 'false')
    await expect(grupo(page, 'Estadísticas')).toHaveAttribute('aria-expanded', 'true')
    await expect(page.getByRole('link', { name: 'Compras', exact: true })).toHaveCount(0)
    await expect(page.getByRole('link', { name: 'Libro diario', exact: true })).toBeVisible()
  })

  test('riel colapsado: cada categoría abre un desplegable a la derecha con sus módulos', async ({ page }) => {
    await abrir(page)

    // Colapsar con el botón del header (mismo trigger que el layout real).
    await page.getByTestId('trigger-menu').click()
    const panel = page.locator('[data-sidebar="sidebar"]')
    await expect.poll(async () => (await panel.boundingBox())?.width ?? 0).toBeLessThanOrEqual(49)

    // Disparadores de desplegable, no de pliegue.
    await expect(grupo(page, 'Operaciones')).toHaveAttribute('aria-haspopup', 'menu')

    await grupo(page, 'Operaciones').click()
    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible()
    for (const nombre of MODULOS_OPERACIONES) {
      await expect(menu.getByRole('menuitem', { name: nombre, exact: true })).toBeVisible()
    }
    // Se abre A LA DERECHA del riel, no encima.
    const caja = await menu.boundingBox()
    expect(caja!.x).toBeGreaterThanOrEqual(40)

    // El desplegable entra con fade/zoom: capturar recién con la animación terminada.
    await expect(menu).toHaveCSS('opacity', '1')
    for (const theme of THEMES) {
      await setTheme(page, theme)
      await page.screenshot({ path: `${SHOT_DIR}/riel-colapsado-desplegable-${theme}.png` })
    }

    await page.keyboard.press('Escape')
    await expect(menu).toHaveCount(0)

    // Ninguna categoría se pierde en el riel: las seis abren su desplegable.
    for (const nombre of GRUPOS) {
      await grupo(page, nombre).click()
      await expect(page.getByRole('menu')).toBeVisible()
      await page.keyboard.press('Escape')
      await expect(page.getByRole('menu')).toHaveCount(0)
    }
  })
})

test.describe('menú por grupos — móvil 390x844', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

  test('el drawer abre con las categorías cerradas, se despliegan y Escape lo cierra', async ({ page }) => {
    await abrir(page)

    await page.getByTestId('trigger-menu').tap()
    const drawer = page.locator('[data-sidebar="sidebar"][data-mobile="true"]')
    await expect(drawer).toBeVisible()

    for (const nombre of GRUPOS) {
      await expect(drawer.getByRole('button', { name: nombre, exact: true })).toHaveAttribute('aria-expanded', 'false')
    }
    await expect(drawer.getByRole('link', { name: 'Ventas', exact: true })).toHaveCount(0)

    // Objetivo táctil de las filas del menú en móvil: 44 px (D5; objetivo de
    // diseño de responsive-shell para controles de fila). En escritorio siguen en 32.
    const alto = async (fila: Locator) => (await fila.boundingBox())?.height ?? 0
    expect(await alto(drawer.getByRole('link', { name: 'Tablero', exact: true }))).toBeGreaterThanOrEqual(44)
    expect(await alto(drawer.getByRole('button', { name: 'Operaciones', exact: true }))).toBeGreaterThanOrEqual(44)

    await drawer.getByRole('button', { name: 'Operaciones', exact: true }).tap()
    for (const nombre of MODULOS_OPERACIONES) {
      await expect(drawer.getByRole('link', { name: nombre, exact: true })).toBeVisible()
    }
    expect(await alto(drawer.getByRole('link', { name: 'Ventas', exact: true }))).toBeGreaterThanOrEqual(44)
    // En móvil no hay desplegables de riel.
    await expect(drawer.getByRole('button', { name: 'Operaciones', exact: true })).not.toHaveAttribute('aria-haspopup', 'menu')

    // El drawer no se desborda horizontalmente con el grupo abierto.
    const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth)
    expect(scrollWidth).toBeLessThanOrEqual(390)

    for (const theme of THEMES) {
      await setTheme(page, theme)
      await page.screenshot({ path: `${SHOT_DIR}/drawer-movil-operaciones-${theme}.png` })
    }

    // Escape cierra el drawer con el foco puesto en una categoría (H19).
    await drawer.getByRole('button', { name: 'Catálogo', exact: true }).focus()
    await page.keyboard.press('Escape')
    await expect(drawer).toBeHidden()

    // Al reabrirlo, vuelve todo plegado.
    await page.getByTestId('trigger-menu').tap()
    await expect(drawer).toBeVisible()
    await expect(drawer.getByRole('button', { name: 'Operaciones', exact: true })).toHaveAttribute('aria-expanded', 'false')
    await expect(drawer.getByRole('link', { name: 'Compras', exact: true })).toHaveCount(0)
  })
})
