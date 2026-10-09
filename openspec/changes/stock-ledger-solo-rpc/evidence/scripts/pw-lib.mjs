import { createRequire } from 'node:module'
import { mkdirSync, existsSync } from 'node:fs'
import { WT } from './lib.mjs'
const require = createRequire(`${WT}/frontend/package.json`)
export const { chromium } = require('@playwright/test')

export const BASE = 'http://localhost:3000'
export const OUT = `${WT}/openspec/changes/stock-ledger-solo-rpc/evidence/screenshots`
export const SCRATCH = process.env.SCRATCH_DIR
mkdirSync(OUT, { recursive: true })

export const VIEWPORTS = { desktop: { width: 1280, height: 800 }, mobile: { width: 375, height: 812 } }
export const COMBOS = [['desktop', 'light'], ['desktop', 'dark'], ['mobile', 'light'], ['mobile', 'dark']]

export async function newCtx(browser, viewport, theme, storageState) {
  const ctx = await browser.newContext({
    viewport: VIEWPORTS[viewport],
    colorScheme: theme,
    storageState: storageState && existsSync(storageState) ? storageState : undefined,
    isMobile: viewport === 'mobile',
    hasTouch: viewport === 'mobile',
  })
  await ctx.addInitScript((t) => { try { localStorage.setItem('theme', t) } catch {} }, theme)
  return ctx
}

export async function login(browser, email, password, path) {
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

// Desborde por elemento: contra el viewport (documento) y contra un contenedor con scroll propio.
export async function measureOverflow(page) {
  return await page.evaluate(() => {
    const vw = document.documentElement.clientWidth
    const issues = []
    const main = document.querySelector('main') || document.body
    const docOverflow = document.documentElement.scrollWidth - vw
    const scrolls = (el) => ['auto', 'scroll'].includes(getComputedStyle(el).overflowX)
    const hidden = (el) => { const s = getComputedStyle(el); const r = el.getBoundingClientRect(); return s.display === 'none' || s.visibility === 'hidden' || r.width === 0 || r.height === 0 }
    for (const el of main.querySelectorAll('*')) {
      if (hidden(el)) continue
      const r = el.getBoundingClientRect()
      let p = el.parentElement, inScroller = false
      while (p && p !== main) { if (scrolls(p)) { inScroller = true; break } p = p.parentElement }
      if (inScroller) continue
      if (el.closest('[aria-hidden="true"], [data-radix-popper-content-wrapper], [role="tooltip"]')) continue
      if (r.right > vw + 1) issues.push({ kind: 'viewport', tag: el.tagName, text: (el.textContent || '').trim().slice(0, 40), right: Math.round(r.right), vw })
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
