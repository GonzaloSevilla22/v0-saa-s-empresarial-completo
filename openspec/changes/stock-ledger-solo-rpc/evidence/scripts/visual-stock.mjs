// Pasada visual del ajuste manual de stock (tanda B): desktop 1280 y móvil 375 x tema claro y oscuro. Stack LOCAL.
// Capturas en evidence/screenshots/<pantalla>-<viewport>-<tema>.png; desborde de documento; consola; foco.
// Uso: run.sh visual-stock.mjs [filtro "desktop-light"]
import { readFileSync, writeFileSync } from 'node:fs'
import { chromium, BASE, newCtx, login as uiLogin, COMBOS, measureOverflow, consoleCollector, OUT, SCRATCH } from './pw-lib.mjs'
import { check, results, USERS } from './lib.mjs'

const IDS = JSON.parse(readFileSync(`${SCRATCH}/ids.json`, 'utf8'))
const browser = await chromium.launch()
const AUTH = { owner: `${SCRATCH}/qa-auth-owner.json`, stock: `${SCRATCH}/qa-auth-stock.json`, seller: `${SCRATCH}/qa-auth-seller.json` }
for (const role of Object.keys(AUTH)) await uiLogin(browser, ...USERS[role], AUTH[role])

const report = []
const consoleErrors = []

async function open(page, path, ready) {
  await page.goto(BASE + path, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
  if (ready) await ready(page)
  await page.waitForTimeout(1200)
}

async function snap(page, name, vp, th, note = '') {
  await page.waitForTimeout(500)
  await page.screenshot({ path: `${OUT}/${name}-${vp}-${th}.png` })
  const ov = await measureOverflow(page)
  report.push({ name, vp, th, docOverflow: ov.docOverflow, issues: ov.issues, note })
  check(`sin desborde de documento: ${name} ${vp} ${th}`, ov.docOverflow <= 1, JSON.stringify(ov.issues.slice(0, 2)))
}


// Contraste WCAG del texto de un elemento contra su fondo efectivo (primer ancestro con fondo opaco).
async function contrast(page, selector) {
  return await page.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return null
    const parse = (c) => { const m = c.match(/rgba?\(([^)]+)\)/); if (!m) return null; const v = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number); return { r: v[0], g: v[1], b: v[2], a: v[3] === undefined ? 1 : v[3] } }
    const lum = ({ r, g, b }) => { const f = (x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4 }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b) }
    const fg = parse(getComputedStyle(el).color)
    let bg = null, n = el
    while (n) { const c = parse(getComputedStyle(n).backgroundColor); if (c && c.a > 0.99) { bg = c; break } n = n.parentElement }
    if (!fg || !bg) return null
    const [a, b] = [lum(fg), lum(bg)].sort((x, y) => y - x)
    return Math.round(((a + 0.05) / (b + 0.05)) * 100) / 100
  }, selector)
}

async function step(name, vp, th, fn) {
  try { await fn() } catch (e) { check(`${name} ${vp} ${th}`, false, String(e).split('\n')[0]) }
}

const only = process.argv[2] ? new RegExp(process.argv[2]) : null
for (const [vp, th] of COMBOS.filter(([v, t]) => !only || only.test(`${v}-${t}`))) {
  // ── /stock con rol de depósito (ve todo) y con rol de vendedor (no ve el ajuste) ──────────────
  for (const role of ['stock', 'seller']) {
    const ctx = await newCtx(browser, vp, th, AUTH[role])
    const page = await ctx.newPage()
    consoleCollector(page).forEach((e) => consoleErrors.push(e))
    const errs = consoleCollector(page)
    await step(`/stock rol ${role}`, vp, th, async () => {
      await open(page, '/stock', (p) => p.getByText('Tomate perita').filter({ visible: true }).first().waitFor({ timeout: 90000 }))
      const adjust = await page.getByRole('button', { name: /ajustar/i }).count()
      const importar = await page.getByRole('button', { name: /importar ajuste/i }).count()
      check(`/stock rol ${role}: ${role === 'stock' ? 've' : 'NO ve'} las acciones de ajuste ${vp} ${th}`,
        role === 'stock' ? adjust > 0 && importar > 0 : adjust === 0 && importar === 0, `ajustar=${adjust} importar=${importar}`)
      await snap(page, `stock-rol-${role}`, vp, th)
    })

    if (role === 'stock') {
      // modal con motivo vacío → con error del servidor
      await step('modal de ajuste', vp, th, async () => {
        await open(page, '/stock', (p) => p.getByText('Tomate perita').filter({ visible: true }).first().waitFor({ timeout: 90000 }))
        await page.getByRole('button', { name: /^(ajustar stock|ajustar)$/i }).first().click()
        const dialog = page.getByRole('dialog', { name: /ajuste de inventario/i })
        await dialog.waitFor()
        await dialog.getByRole('combobox').filter({ hasText: /seleccioná un producto/i }).click()
        await page.getByRole('option', { name: /tomate perita/i }).click()
        await dialog.getByPlaceholder('Cantidad…').fill('3')
        await page.waitForTimeout(300)
        const blocked = await dialog.getByRole('button', { name: /registrar ajuste/i }).isDisabled()
        check(`modal: envío deshabilitado con motivo vacío ${vp} ${th}`, blocked)
        const invalid = await dialog.getByLabel(/motivo/i).getAttribute('aria-invalid')
        check(`modal: motivo con aria-invalid ${vp} ${th}`, invalid === 'true', invalid)
        const ratio = await contrast(page, '#adj-reason-error')
        check(`modal: contraste del mensaje del motivo >= 4.5:1 (${ratio}) ${vp} ${th}`, ratio !== null && ratio >= 4.5)
        await snap(page, 'modal-ajuste-motivo-vacio', vp, th)
        // error del servidor: ajuste de salida de 999 (más de lo que hay)
        await dialog.getByRole('combobox').filter({ hasText: /ajuste de entrada/i }).click()
        await page.getByRole('option', { name: /ajuste de salida/i }).click()
        await dialog.getByPlaceholder('Cantidad…').fill('999')
        await dialog.getByLabel(/motivo/i).fill('Conteo de la verificación visual')
        await dialog.getByRole('button', { name: /registrar ajuste/i }).click()
        await dialog.getByText(/no alcanza el stock/i).waitFor({ timeout: 60000 })
        check(`modal: rechazo del servidor en castellano ${vp} ${th}`, true)
        await snap(page, 'modal-ajuste-error-servidor', vp, th)
      })

      // importador con filas sin motivo
      await step('importador', vp, th, async () => {
        await open(page, '/stock', (p) => p.getByText('Tomate perita').filter({ visible: true }).first().waitFor({ timeout: 90000 }))
        await page.getByRole('button', { name: /importar ajuste/i }).click()
        const dialog = page.getByRole('dialog')
        await dialog.waitFor()
        await snap(page, 'importador-paso-1', vp, th)
        const csv = 'Nombre;Tipo;Cantidad;Motivo\nTomate perita;Ajuste entrada;5;Reposición\nAlfajor artesanal;Pérdida;2;\nAceite QA;Transferencia entrada;4;Movimiento de depósito\n'
        await dialog.locator('input[type=file]').setInputFiles({ name: 'ajustes.csv', mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf8') })
        await dialog.getByText('Falta el motivo').first().waitFor({ timeout: 30000 })
        check(`importador: fila sin motivo marcada ${vp} ${th}`, true)
        await snap(page, 'importador-filas-sin-motivo', vp, th)
      })

      // inventario por sucursal
      await step('/sucursales/[id]/stock', vp, th, async () => {
        await open(page, `/sucursales/${IDS.br1}/stock`, (p) => p.getByText('Tomate perita').filter({ visible: true }).first().waitFor({ timeout: 90000 }))
        await snap(page, 'sucursal-stock-rol-stock', vp, th)
        await page.getByRole('button', { name: /ajustar stock de tomate perita/i }).click()
        const dialog = page.getByRole('dialog')
        await dialog.waitFor()
        await dialog.getByRole('button', { name: /^ajustar stock$/i }).click()
        await dialog.getByText(/el motivo es obligatorio/i).waitFor({ timeout: 15000 })
        check(`sucursal: motivo vacío bloqueado con mensaje ${vp} ${th}`, (await dialog.getByLabel(/motivo/i).getAttribute('aria-invalid')) === 'true')
        await snap(page, 'sucursal-ajuste-motivo-vacio', vp, th)
      })
    }
    if (role === 'seller') {
      await step('/sucursales/[id]/stock seller', vp, th, async () => {
        await open(page, `/sucursales/${IDS.br1}/stock`, (p) => p.getByText('Tomate perita').filter({ visible: true }).first().waitFor({ timeout: 90000 }))
        const ajustar = await page.getByRole('button', { name: /ajustar stock de/i }).count()
        const transferir = await page.getByRole('button', { name: /transferir stock de/i }).count()
        check(`sucursal rol seller: sin «Ajustar», con «Transferir» ${vp} ${th}`, ajustar === 0 && transferir > 0, `ajustar=${ajustar} transferir=${transferir}`)
        await snap(page, 'sucursal-stock-rol-seller', vp, th)
      })
    }
    errs.forEach((e) => consoleErrors.push(`${role} ${vp}-${th}: ${e}`))
    await ctx.close()
  }

  // ── Formulario de producto: alta con y sin rol; edición con el modal abierto encima ───────────
  for (const role of ['owner', 'seller']) {
    const ctx = await newCtx(browser, vp, th, AUTH[role])
    const page = await ctx.newPage()
    const errs = consoleCollector(page)
    await step(`producto alta ${role}`, vp, th, async () => {
      await open(page, '/productos', (p) => p.getByText('Tomate perita').filter({ visible: true }).first().waitFor({ timeout: 90000 }))
      await page.getByRole('button', { name: /nuevo producto/i }).first().click()
      const dialog = page.getByRole('dialog', { name: /nuevo producto/i })
      await dialog.waitFor()
      await page.waitForTimeout(800)
      const field = await dialog.getByLabel(/stock inicial/i).count()
      const note = await dialog.getByText(/el stock inicial lo carga/i).count()
      check(`alta rol ${role}: ${role === 'owner' ? 'campo «Stock inicial»' : 'línea explicativa sin campo'} ${vp} ${th}`,
        role === 'owner' ? field === 1 && note === 0 : field === 0 && note === 1, `campo=${field} nota=${note}`)
      await snap(page, `producto-alta-rol-${role}`, vp, th)
    })
    if (role === 'owner') {
      await step('producto edición + modal', vp, th, async () => {
        await open(page, '/productos', (p) => p.getByText('Tomate perita').filter({ visible: true }).first().waitFor({ timeout: 90000 }))
        const holder = page.getByText('Tomate perita').filter({ visible: true }).first().locator('xpath=ancestor::*[.//button[.//*[contains(@class,"lucide-pencil")]]][1]')
        await holder.locator('button:has(.lucide-pencil)').first().click()
        const edit = page.getByRole('dialog', { name: /editar producto/i })
        await edit.waitFor()
        await page.waitForTimeout(800)
        await snap(page, 'producto-edicion', vp, th)
        const trigger = edit.getByRole('button', { name: /ajustar stock/i })
        await trigger.click()
        const adj = page.getByRole('dialog', { name: /ajuste de inventario/i })
        await adj.waitFor()
        await page.waitForTimeout(600)
        await snap(page, 'producto-edicion-modal-ajuste', vp, th)
        await page.keyboard.press('Escape')
        await adj.waitFor({ state: 'detached' })
        await page.waitForTimeout(500)
        const focused = await page.evaluate(() => (document.activeElement?.textContent || '').trim().slice(0, 30))
        check(`edición: el foco vuelve al botón «Ajustar stock» al cerrar el modal ${vp} ${th}`, /ajustar stock/i.test(focused), focused)
      })
    }
    errs.forEach((e) => consoleErrors.push(`${role} producto ${vp}-${th}: ${e}`))
    await ctx.close()
  }
}

await browser.close()
const fails = results.filter(([, ok]) => !ok)
const rep = { generated: new Date().toISOString(), total: results.length, failed: fails.length, failures: fails.map(([n]) => n), report, consoleErrors: [...new Set(consoleErrors)].slice(0, 20) }
writeFileSync(`${OUT}/_reporte-visual.json`, JSON.stringify(rep, null, 1))
console.log(`\nRESUMEN: ${results.length - fails.length}/${results.length} PASS; errores de consola únicos: ${rep.consoleErrors.length}`)
process.exit(fails.length ? 1 : 0)
