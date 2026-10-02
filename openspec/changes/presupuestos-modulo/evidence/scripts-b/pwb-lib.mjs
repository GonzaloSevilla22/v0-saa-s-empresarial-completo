import { createRequire } from 'node:module'
import { mkdirSync, existsSync } from 'node:fs'
const require = createRequire('C:/Users/Usuario/Desktop/EIE/wt-presupuestos/frontend/package.json')
export const { chromium } = require('@playwright/test')

export const BASE = 'http://localhost:3000'
export const OUT = 'C:/Users/Usuario/Desktop/EIE/scratchpad-presupuestos/capturas-b'
export const AUTH = 'C:/Users/Usuario/Desktop/EIE/scratchpad-presupuestos/qa-auth-tb.json'
mkdirSync(OUT, { recursive: true })

export const VIEWPORTS = { desktop: { width: 1280, height: 800 }, mobile: { width: 375, height: 812 } }
export const COMBOS = [
  ['desktop', 'light'], ['desktop', 'dark'], ['mobile', 'light'], ['mobile', 'dark'],
]

export async function newCtx(browser, viewport, theme, storageState = AUTH) {
  const ctx = await browser.newContext({
    viewport: VIEWPORTS[viewport],
    colorScheme: theme,
    storageState: existsSync(storageState) ? storageState : undefined,
    isMobile: viewport === 'mobile',
    hasTouch: viewport === 'mobile',
    acceptDownloads: true,
    permissions: ['clipboard-read', 'clipboard-write'],
  })
  await ctx.addInitScript((t) => { try { localStorage.setItem('theme', t) } catch {} }, theme)
  return ctx
}

export async function login(browser, email, password, path = AUTH) {
  const ctx = await browser.newContext({ viewport: VIEWPORTS.desktop })
  const page = await ctx.newPage()
  await page.goto(BASE + '/auth/login', { waitUntil: 'domcontentloaded', timeout: 180000 })
  await page.getByTestId('login-email').fill(email)
  await page.getByTestId('login-password').fill(password)
  await page.getByTestId('login-submit').click()
  await page.waitForURL(/\/dashboard/, { timeout: 180000 })
  await ctx.storageState({ path })
  await ctx.close()
}

// Mide desborde por elemento: contra el viewport y contra su card/contenedor no scrolleable.
export async function measureOverflow(page) {
  return await page.evaluate(() => {
    const vw = document.documentElement.clientWidth
    const issues = []
    const main = document.querySelector('main') || document.body
    const docOverflow = document.documentElement.scrollWidth - vw
    const els = main.querySelectorAll('*')
    const scrolls = (el) => { const s = getComputedStyle(el); return ['auto', 'scroll'].includes(s.overflowX) }
    const hidden = (el) => { const s = getComputedStyle(el); const r = el.getBoundingClientRect(); return s.display === 'none' || s.visibility === 'hidden' || r.width === 0 || r.height === 0 }
    for (const el of els) {
      if (hidden(el)) continue
      const r = el.getBoundingClientRect()
      // ignorar lo que vive dentro de un contenedor con scroll horizontal propio
      let p = el.parentElement, inScroller = false
      while (p && p !== main) { if (scrolls(p)) { inScroller = true; break } p = p.parentElement }
      if (inScroller) continue
      if (el.closest('[aria-hidden="true"], [data-radix-popper-content-wrapper], [role="tooltip"]')) continue
      if (r.right > vw + 1) { issues.push({ kind: 'viewport', tag: el.tagName, cls: (el.className || '').toString().slice(0, 60), text: (el.textContent || '').trim().slice(0, 40), right: Math.round(r.right), vw }); continue }
      // contra el card/section más cercano con borde o fondo
      let c = el.parentElement
      while (c && c !== main) {
        const s = getComputedStyle(c)
        const boxed = parseFloat(s.borderTopWidth) > 0 || s.overflowX !== 'visible'
        if (boxed) break
        c = c.parentElement
      }
      if (c && c !== main) {
        const cr = c.getBoundingClientRect()
        if (r.right > cr.right + 1.5 && !scrolls(c) && getComputedStyle(c).overflowX !== 'hidden' && getComputedStyle(c).overflowX !== 'clip') {
          issues.push({ kind: 'card', tag: el.tagName, cls: (el.className || '').toString().slice(0, 60), text: (el.textContent || '').trim().slice(0, 40), right: Math.round(r.right), cardRight: Math.round(cr.right) })
        }
      }
    }
    // Contenedores con scroll horizontal propio cuyo contenido no entra (columnas escondidas)
    for (const el of main.querySelectorAll('*')) {
      if (hidden(el) || !scrolls(el)) continue
      if (el.scrollWidth > el.clientWidth + 1) issues.push({ kind: 'scroller', tag: el.tagName, cls: (el.className || '').toString().slice(0, 60), text: (el.textContent || '').trim().slice(0, 40), scrollW: el.scrollWidth, clientW: el.clientWidth })
    }
    return { docOverflow, issues: issues.slice(0, 8), count: issues.length }
  })
}

export function consoleCollector(page) {
  const errs = []
  page.on('console', (m) => { if (m.type() === 'error') errs.push(m.text().slice(0, 200)) })
  page.on('pageerror', (e) => errs.push('pageerror: ' + String(e).slice(0, 200)))
  return errs
}

export async function shot(page, name, viewport, theme, report) {
  await page.waitForTimeout(600)
  const file = `${OUT}/${name}-${viewport}-${theme}.png`
  await page.screenshot({ path: file, fullPage: false })
  const ov = await measureOverflow(page)
  report.push({ name, viewport, theme, docOverflow: ov.docOverflow, overflowCount: ov.count, issues: ov.issues })
  const flag = ov.docOverflow > 1 || ov.count > 0 ? '  <<< DESBORDE' : ''
  console.log(`shot ${name}-${viewport}-${theme}  docOverflow=${ov.docOverflow} elementOverflow=${ov.count}${flag}`)
  if (flag) console.log('   ', JSON.stringify(ov.issues.slice(0, 4)))
}
