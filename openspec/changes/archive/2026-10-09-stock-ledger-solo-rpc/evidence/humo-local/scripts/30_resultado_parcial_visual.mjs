// Pasada visual del fix stock-import-resultado-parcial (stack LOCAL únicamente): importador de ajustes de /stock con un CSV
// de 1 fila válida + 1 sin motivo. 4 combinaciones (1280/375 px x claro/oscuro) x 2 pasos (Revisión, Resultado) = 8 capturas
// en screenshots/fix-resultado-parcial/, más la medición de desborde horizontal y del contraste (WCAG) de todo el texto del diálogo.
// Uso: bash run.sh 30_resultado_parcial_visual.mjs [etiqueta-de-salida]
import { mkdirSync, writeFileSync } from 'node:fs'
import { chromium, OUT, AUTH, open, watch, sql, LOGS } from './humo-lib.mjs'
import { newCtx } from './pw-lib.mjs'

const TAG = process.argv[2] || 'antes'
const DIR = `${OUT}/fix-resultado-parcial`
mkdirSync(DIR, { recursive: true })
const COMBOS = [['1280', 'desktop', 'light'], ['1280', 'desktop', 'dark'], ['375', 'mobile', 'light'], ['375', 'mobile', 'dark']]
const CSV = 'Nombre;Tipo;Cantidad;Motivo\nAceite QA;Ajuste entrada;1;Reposición parcial (pasada visual)\nProducto escaso QA;Pérdida;1;\n'
const stockOf = (sku) => Number(sql(`select coalesce(sum(bs.quantity),0) from branch_stock bs join products p on p.id=bs.product_id where p.sku='${sku}'`))

// Se evalúa dentro de la página: contraste WCAG de cada nodo de texto bajo `selector` contra su fondo REAL (capas con alfa compuestas).
const contrastInPage = (selector) => {
  const parse = (css) => {
    let m = css.match(/^rgba?\(([^)]+)\)$/)
    if (m) { const p = m[1].split(/[\s,/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1] }
    m = css.match(/^color\(srgb ([^)]+)\)$/)
    if (m) { const p = m[1].split(/[\s/]+/).filter(Boolean).map(Number); return [p[0] * 255, p[1] * 255, p[2] * 255, p.length > 3 ? p[3] : 1] }
    return null
  }
  const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b) }
  const over = (fg, bg) => [fg[0] * fg[3] + bg[0] * (1 - fg[3]), fg[1] * fg[3] + bg[1] * (1 - fg[3]), fg[2] * fg[3] + bg[2] * (1 - fg[3])]
  const bgOf = (el) => {
    const stack = []
    for (let n = el; n; n = n.parentElement) {
      const c = parse(getComputedStyle(n).backgroundColor)
      if (c && c[3] > 0) { stack.push(c); if (c[3] >= 0.999) break }
    }
    let base = [255, 255, 255]
    for (let i = stack.length - 1; i >= 0; i--) base = over(stack[i], base)
    return base
  }
  const root = document.querySelector(selector)
  if (!root) return { error: 'sin ' + selector, rows: [] }
  const rows = []
  for (const el of root.querySelectorAll('*')) {
    const own = [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join('').replace(/\s+/g, ' ').trim()
    if (!own) continue
    const st = getComputedStyle(el), r = el.getBoundingClientRect()
    if (st.display === 'none' || st.visibility === 'hidden' || r.width === 0 || r.height === 0 || el.closest('.sr-only,[aria-hidden="true"]')) continue
    const fg = parse(st.color)
    if (!fg) { rows.push({ text: own.slice(0, 44), cls: String(el.className).slice(0, 80), error: 'color no parseable: ' + st.color }); continue }
    const bg = bgOf(el), eff = over(fg, bg)
    const ratio = (Math.max(lum(eff), lum(bg)) + 0.05) / (Math.min(lum(eff), lum(bg)) + 0.05)
    rows.push({ text: own.slice(0, 44), cls: String(el.className).split(/\s+/).filter((c) => /^(text|bg)-/.test(c) && !/^text-(xs|sm|base|lg|\[)/.test(c)).join(' '), size: st.fontSize, weight: st.fontWeight, ratio: Math.round(ratio * 100) / 100, fg: eff.map(Math.round).join(','), bg: bg.map(Math.round).join(',') })
  }
  return { rows }
}

const overflowInPage = () => {
  const dlg = document.querySelector('[role=dialog]')
  const dr = dlg?.getBoundingClientRect()
  const wide = []
  if (dlg) for (const el of dlg.querySelectorAll('*')) {
    const r = el.getBoundingClientRect()
    if (r.width && (r.right > dr.right + 1 || r.left < dr.left - 1) && !el.closest('[data-radix-scroll-area-viewport]')) wide.push((el.textContent || '').trim().slice(0, 30))
  }
  return {
    docScrollWidth: document.documentElement.scrollWidth, innerWidth: window.innerWidth,
    docOverflowOk: document.documentElement.scrollWidth <= window.innerWidth,
    dialogScrollWidth: dlg?.scrollWidth, dialogClientWidth: dlg?.clientWidth, dialogOverflowOk: dlg ? dlg.scrollWidth <= dlg.clientWidth + 1 : null,
    dialogRect: dr ? [Math.round(dr.left), Math.round(dr.right)] : null, outsideDialog: wide.slice(0, 5),
  }
}

const browser = await chromium.launch()
const report = []
for (const [vw, viewport, theme] of COMBOS) {
  const ctx = await newCtx(browser, viewport, theme, AUTH.owner)
  const page = await ctx.newPage()
  watch(page, `visual-${vw}-${theme}`)
  const aceite0 = stockOf('QA-ACEITE'), escaso0 = stockOf('QA-ESCASO')
  await open(page, '/stock', 'Aceite QA')
  const isDark = await page.evaluate(() => document.documentElement.classList.contains('dark'))
  await page.getByRole('button', { name: /importar ajuste/i }).filter({ visible: true }).first().click()
  const dialog = page.getByRole('dialog')
  await dialog.waitFor()
  await dialog.locator('input[type=file]').setInputFiles({ name: 'ajustes-mixto.csv', mimeType: 'text/csv', buffer: Buffer.from(CSV, 'utf8') })
  await dialog.getByText('Falta el motivo').first().waitFor({ timeout: 30000 })
  const btn = dialog.getByRole('button', { name: /^aplicar/i })
  const btnText = (await btn.textContent())?.trim()
  const nota = (await dialog.getByText(/se omitirá al confirmar/).locator('xpath=..').textContent())?.replace(/\s+/g, ' ').trim()
  const rev = { step: 'revision', btnText, nota, overflow: await page.evaluate(overflowInPage), contrast: (await page.evaluate(contrastInPage, '[role=dialog]')).rows }
  await page.waitForTimeout(500)
  await page.screenshot({ path: `${DIR}/${vw}-${theme}-1-revision.png` })

  await btn.click()
  await dialog.getByText('1 aplicado · 1 omitida', { exact: true }).waitFor({ timeout: 60000 })
  await page.getByText(/revisá los detalles/).first().waitFor({ timeout: 15000 })
  const headline = (await dialog.getByText('1 aplicado · 1 omitida', { exact: true }).textContent())?.trim()
  const toastText = (await page.getByText(/revisá los detalles/).first().textContent())?.trim()
  const omitidas = (await dialog.getByText('Filas omitidas', { exact: true }).locator('xpath=..').textContent())?.replace(/\s+/g, ' ').trim()
  const res = { step: 'resultado', headline, toastText, omitidas, overflow: await page.evaluate(overflowInPage), contrast: (await page.evaluate(contrastInPage, '[role=dialog]')).rows, toastContrast: (await page.evaluate(contrastInPage, '[data-sonner-toaster]')).rows }
  await page.waitForTimeout(400)
  await page.screenshot({ path: `${DIR}/${vw}-${theme}-2-resultado.png` })
  const aceite1 = stockOf('QA-ACEITE'), escaso1 = stockOf('QA-ESCASO')
  report.push({ vw, theme, isDark, stock: { aceite: [aceite0, aceite1], escaso: [escaso0, escaso1] }, rev, res })
  console.log(`${vw} ${theme} dark=${isDark} boton="${btnText}" | ${headline} | toast="${toastText}" | stock aceite ${aceite0}->${aceite1}, escaso ${escaso0}->${escaso1} | overflow rev=${rev.overflow.docOverflowOk}/${rev.overflow.dialogOverflowOk} res=${res.overflow.docOverflowOk}/${res.overflow.dialogOverflowOk}`)
  await ctx.close()
}
writeFileSync(`${LOGS}/30_resultado_parcial_visual_${TAG}.json`, JSON.stringify(report, null, 1))
await browser.close()
