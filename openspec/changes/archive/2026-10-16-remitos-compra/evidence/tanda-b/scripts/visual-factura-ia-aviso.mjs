// Verificación por la UI real del aviso contra la doble suma en la FACTURA IA (remitos-compra tanda B, 7.9), en las 4 combinaciones.
// El OCR (Edge Function + OpenAI + Storage) NO corre en el stack local: se intercepta SÓLO el tramo externo de la pipeline
// (subida a Storage, alta de invoice_documents y la respuesta de invoice-ocr); todo lo demás es la app real contra FastAPI
// + PostgREST + Postgres locales. El aviso cuenta los remitos de compra pendientes reales de la base local.
import { COMBOS, chromium, BASE, newCtx, consoleCollector, OUT } from './pw-lib.mjs'
import { SP, mkDn, ensureSession, check, sql, A, login, USERS, results } from './hb.mjs'

const tok = await login(...USERS.owner)
await ensureSession(tok)
await mkDn(tok) // al menos un remito de compra pendiente
const pendientes = Number(sql(`select count(*) from delivery_notes where account_id='${A}' and direction='purchase' and status='issued'`))
const browser = await chromium.launch()
const AUTH = `${SP}/qa-auth-owner.json`
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }
const PARSED = {
  supplier: { name: 'Proveedor Demo QA', cuit: null, address: null, invoice_type: 'B' },
  invoice: { number: '0001-00000042', date: new Date().toISOString().slice(0, 10), currency: 'ARS' },
  totals: { subtotal: 1000, vat_amount: 0, vat_rate: 0, other_taxes: 0, discount: 0, total: 1000 },
  items: [{ raw_description: 'Alfajor artesanal', description: 'Alfajor artesanal', quantity: 4, unit: null, unit_price: 250, discount_pct: null, subtotal: 1000 }],
  confidence: 0.95,
  warnings: [],
}
// JPEG mínimo válido de 1x1
const JPG = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=', 'base64')
const report = []

for (const [vp, th] of COMBOS) {
  const ctx = await newCtx(browser, vp, th, AUTH)
  const page = await ctx.newPage()
  const errs = consoleCollector(page)
  await page.route(/\/storage\/v1\/object\//, (r) => r.request().method() === 'OPTIONS' ? r.fulfill({ status: 204, headers: CORS }) : r.fulfill({ status: 200, headers: CORS, contentType: 'application/json', body: JSON.stringify({ Key: 'qa/x.jpg', Id: 'qa' }) }))
  await page.route(/\/rest\/v1\/invoice_documents/, (r) => {
    const m = r.request().method()
    if (m === 'OPTIONS') return r.fulfill({ status: 204, headers: CORS })
    if (m === 'POST') return r.fulfill({ status: 201, headers: CORS, contentType: 'application/json', body: JSON.stringify({ id: crypto.randomUUID() }) })
    return r.fulfill({ status: 204, headers: CORS })
  })
  await page.route(/\/functions\/v1\/invoice-ocr/, (r) => r.request().method() === 'OPTIONS' ? r.fulfill({ status: 204, headers: CORS }) : r.fulfill({ status: 200, headers: CORS, contentType: 'application/json', body: JSON.stringify({ ok: true, result: PARSED }) }))
  await page.goto(`${BASE}/compras`, { waitUntil: 'domcontentloaded', timeout: 180000 })
  await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 120000 })
  await page.getByRole('button', { name: /Subir factura IA/i }).first().click().catch(async () => { await page.locator('button:has(svg.lucide-scan-text)').first().click() })
  await page.locator('input[type="file"]').first().setInputFiles({ name: 'factura.jpg', mimeType: 'image/jpeg', buffer: JPG })
  const dlg = page.getByRole('dialog').filter({ has: page.getByRole('note') }).first()
  await dlg.getByRole('note').waitFor({ timeout: 60000 })
  const text = await dlg.getByRole('note').innerText()
  check(`(${vp}/${th}) Factura IA: la revisión muestra el aviso con los remitos de compra pendientes de la cuenta`, new RegExp(`${pendientes} remitos? de compra pendientes?`).test(text) && /para no sumar el stock dos veces/.test(text), text.replace(/\n/g, ' '))
  const href = await dlg.getByRole('note').getByRole('link').getAttribute('href')
  check(`(${vp}/${th}) el enlace lleva a los pendientes de COMPRA de toda la cuenta (sin proveedor)`, href === '/remitos?sentido=compra&estado=pendientes', href)
  const confirm = dlg.getByRole('button', { name: /Confirmar|Registrar/ }).last()
  check(`(${vp}/${th}) es un aviso, no un bloqueo: el botón de confirmar sigue habilitado`, await confirm.isEnabled())
  await page.waitForTimeout(500)
  await page.screenshot({ path: `${OUT}/b-factura-ia-aviso-${vp}-${th}.png` })
  const ov = await page.evaluate(() => {
    const d = document.querySelector('[role="dialog"]'); const vw = document.documentElement.clientWidth
    const dr = d.getBoundingClientRect(); const issues = []
    const scrolls = (el) => ['auto', 'scroll'].includes(getComputedStyle(el).overflowX)
    for (const el of d.querySelectorAll('*')) {
      const s = getComputedStyle(el), r = el.getBoundingClientRect()
      if (s.display === 'none' || s.visibility === 'hidden' || r.width === 0 || r.height === 0) continue
      let p = el.parentElement, sc = false
      while (p && p !== d) { if (scrolls(p)) { sc = true; break } p = p.parentElement }
      if (sc) continue
      if (r.right > Math.min(dr.right, vw) + 1.5) issues.push({ tag: el.tagName, text: (el.textContent || '').trim().slice(0, 40), right: Math.round(r.right) })
    }
    return { count: issues.length, issues: issues.slice(0, 4), doc: document.documentElement.scrollWidth - vw }
  })
  console.log(`shot b-factura-ia-aviso-${vp}-${th} dialogOverflow=${ov.count} docOverflow=${ov.doc}`)
  check(`(${vp}/${th}) Factura IA: sin desborde propio dentro del diálogo ni del documento`, ov.count === 0 && ov.doc <= 1, JSON.stringify(ov.issues))
  check(`(${vp}/${th}) la consola no tiene errores propios`, errs.filter((e) => !/404|409|Failed to load resource|favicon/.test(e)).length === 0, errs.slice(0, 3).join(' | '))
  report.push({ vp, th, ...ov })
  await ctx.close()
}
const bad = results.filter(([, ok]) => !ok)
console.log(`\n== ${results.length - bad.length}/${results.length} PASS`)
await browser.close()
process.exit(bad.length ? 1 : 0)
