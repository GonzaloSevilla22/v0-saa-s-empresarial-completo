import { test, expect, type APIRequestContext, type Browser, type Page } from '@playwright/test'
import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises'
import { deflateSync } from 'node:zlib'
import os from 'node:os'
import path from 'node:path'
import {
  BACKEND,
  COMBOS,
  SERVICE_KEY,
  SUPABASE_URL,
  applyCombo,
  assertLocalEnv,
  comboTag,
  expectNoHorizontalOverflow,
  rest,
  seedManualSale,
  snap,
  type Combo,
} from './fixtures/fiscal-e2e'

/**
 * documentos-marca-empresa — de punta a punta en el stack LOCAL (Next → FastAPI → Postgres):
 *
 *   1. /configuracion?tab=documentos de una cuenta SIN marca: la vista previa cae a la cascada
 *      (negocio del perfil del dueño), los datos fiscales y de contacto son editables.
 *   2. El dueño completa la marca, sube un PNG generado en el test, elige «Bordó» y guarda: la
 *      vista previa cambia en vivo, la base queda con la fila y la huella del logo, y al
 *      recargar todo se conserva (logo incluido, bajado como data: URI).
 *   3. Un color personalizado ilegible (< 4,5:1) avisa en vivo y bloquea «Guardar».
 *   4. Con un perfil fiscal cargado, razón social/CUIT/domicilio/IVA pasan a sólo lectura con
 *      enlace a AFIP.
 *   5. Un presupuesto y un remito sembrados bajan como PDF REAL (con la imagen del logo
 *      embebida); el comprobante interno de una venta baja con la marca y SIN el email de Auth.
 *   6. Un vendedor ve la pestaña en sólo lectura (sin «Guardar», sin subida de logo).
 *
 * Corre en las 4 combinaciones (1366×768 / 375×812 × claro / oscuro), con una cuenta propia del
 * spec (dueño + vendedor) para no depender del estado que dejaron los demás e2e. Con
 * DOCS_VISUAL_DIR definido deja las capturas y los PDF/HTML descargados ahí.
 */

const VISUAL_DIR = process.env.DOCS_VISUAL_DIR
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL ?? ''

// Credenciales del stack LOCAL, propias de este spec (no son secretos).
const OWNER_EMAIL = 'docs.owner.e2e@local.test'
const SELLER_EMAIL = 'docs.seller.e2e@local.test'
const PASSWORD = 'docs-marca-e2e-local-1'
const OWNER_BUSINESS = 'Negocio del Dueño E2E'
// CUIT válido (módulo 11) distinto del de los e2e fiscales.
const FISCAL_CUIT = '27-12345678-7'

// ── PNG de prueba generado en el test (sin dependencias) ─────────────────────

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

function crc32(buf: Buffer): number {
  let c = 0xffffffff
  for (const byte of buf) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function pngChunk(type: string, data: Buffer): Buffer {
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const out = Buffer.alloc(8 + data.length + 4)
  out.writeUInt32BE(data.length, 0)
  body.copy(out, 4)
  out.writeUInt32BE(crc32(body), 4 + body.length)
  return out
}

/** Un logo de juguete: banda de color con un degradé, sin transparencia. */
function makeLogoPng(width = 360, height = 120): Buffer {
  const raw = Buffer.alloc((width * 3 + 1) * height)
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1)
    raw[row] = 0
    for (let x = 0; x < width; x++) {
      const o = row + 1 + x * 3
      const inFrame = x < 6 || y < 6 || x >= width - 6 || y >= height - 6
      raw[o] = inFrame ? 20 : 30 + Math.floor((x / width) * 200)
      raw[o + 1] = inFrame ? 40 : 90 + Math.floor((y / height) * 100)
      raw[o + 2] = inFrame ? 120 : 200
    }
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // profundidad
  ihdr[9] = 2 // RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ])
}

// ── Siembra (service_role LOCAL, desde Node; nunca en el navegador) ──────────

const ADMIN_HEADERS = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' }

async function ensureUser(request: APIRequestContext, email: string): Promise<string> {
  const list = await request.get(`${SUPABASE_URL}/auth/v1/admin/users?per_page=1000`, { headers: ADMIN_HEADERS })
  expect(list.ok()).toBeTruthy()
  const found = ((await list.json()) as { users: { id: string; email: string }[] }).users.find((u) => u.email === email)
  if (found) return found.id
  const created = await request.post(`${SUPABASE_URL}/auth/v1/admin/users`, {
    headers: ADMIN_HEADERS, data: { email, password: PASSWORD, email_confirm: true },
  })
  expect(created.ok(), `crear ${email} → ${created.status()} ${await created.text()}`).toBeTruthy()
  return ((await created.json()) as { id: string }).id
}

async function accountOf(request: APIRequestContext, userId: string) {
  const db = rest(request)
  const [member] = await db.get(`account_members?user_id=eq.${userId}&select=account_id&order=created_at.asc&limit=1`)
  const accountId = String(member.account_id)
  const [branch] = await db.get(`branches?account_id=eq.${accountId}&is_active=eq.true&select=id&order=created_at.asc&limit=1`)
  return { userId, accountId, branchId: String(branch.id) }
}

/** El vendedor sólo pertenece a la cuenta del dueño (se le saca la propia que le crea el alta). */
async function ensureSellerOf(request: APIRequestContext, sellerId: string, accountId: string): Promise<void> {
  const db = rest(request)
  const own = await db.get(`account_members?user_id=eq.${sellerId}&select=id,account_id`)
  for (const member of own) {
    if (member.account_id !== accountId) await db.del(`account_members?id=eq.${member.id}`)
  }
  const [already] = await db.get(`account_members?user_id=eq.${sellerId}&account_id=eq.${accountId}&select=id`)
  if (already) return
  const [member] = await db.post('account_members', { account_id: accountId, user_id: sellerId, role: 'member' })
  await db.post('account_member_roles', { account_id: accountId, member_id: member.id, role: 'seller' })
}

async function jwtFor(request: APIRequestContext, email: string): Promise<string> {
  const res = await request.post(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' }, data: { email, password: PASSWORD },
  })
  expect(res.ok(), `login API ${email} → ${res.status()}`).toBeTruthy()
  return ((await res.json()) as { access_token: string }).access_token
}

async function backendPost<T>(request: APIRequestContext, jwt: string, route: string, data: object): Promise<T> {
  const res = await request.post(`${BACKEND}${route}`, {
    headers: { Authorization: `Bearer ${jwt}`, 'Idempotency-Key': crypto.randomUUID() }, data,
  })
  expect(res.ok(), `POST ${route} → ${res.status()} ${await res.text()}`).toBeTruthy()
  return (await res.json()) as T
}

async function loginViaUi(page: Page, email: string): Promise<void> {
  await page.goto('/auth/login')
  await page.getByTestId('login-email').fill(email)
  await page.getByTestId('login-password').fill(PASSWORD)
  await page.getByTestId('login-submit').click()
  await expect(page).toHaveURL(/\/dashboard/, { timeout: 150_000 })
}

/** Una sesión limpia (sin el estado del usuario QA del proyecto) con el viewport y tema de la combinación. */
async function freshSession(browser: Browser, combo: Combo, email: string): Promise<{ page: Page; close: () => Promise<void> }> {
  const context = await browser.newContext({ storageState: { cookies: [], origins: [] } })
  const page = await context.newPage()
  await applyCombo(page, context, combo)
  await loginViaUi(page, email)
  return { page, close: () => context.close() }
}

async function saveDownload(page: Page, fileName: string, action: () => Promise<void>): Promise<{ file: string; bytes: Buffer }> {
  const dir = VISUAL_DIR ?? path.join(os.tmpdir(), 'documentos-marca-e2e')
  await mkdir(dir, { recursive: true })
  const downloading = page.waitForEvent('download')
  await action()
  const download = await downloading
  const file = path.join(dir, fileName)
  await download.saveAs(file)
  return { file, bytes: await readFile(file) }
}

/**
 * Contraste de TODO el texto visible del panel de la pestaña (WCAG AA: 4,5:1; 3:1 para texto grande),
 * medido con los colores calculados por el navegador contra el fondo efectivo (se mezclan las capas
 * con alfa hacia arriba). Se excluyen el "papel" de la vista previa (es un documento, siempre sobre
 * blanco, con su propia regla de ≥ 4,5:1 en la paleta) y los controles deshabilitados (exentos en WCAG).
 */
async function textContrastViolations(page: Page): Promise<{ checked: number; violations: string[]; lowest: string }> {
  return page.evaluate(() => {
    const parse = (value: string): number[] | null => {
      const m = value.match(/^(?:rgba?|color\(srgb)\(?\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)?/)
      if (!m) return null
      const isSrgb = value.startsWith('color(')
      const channel = (v: string) => (isSrgb ? Number(v) * 255 : Number(v))
      const alpha = m[4] === undefined ? 1 : m[4].endsWith('%') ? Number(m[4].slice(0, -1)) / 100 : Number(m[4])
      return [channel(m[1]), channel(m[2]), channel(m[3]), alpha]
    }
    const lum = (rgb: number[]) => {
      const f = (c: number) => { const v = c / 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
      return 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2])
    }
    const effectiveBackground = (el: Element): number[] => {
      const layers: number[][] = []
      for (let node: Element | null = el; node; node = node.parentElement) {
        const bg = parse(getComputedStyle(node).backgroundColor)
        if (bg && bg[3] > 0) { layers.push(bg); if (bg[3] >= 1) break }
      }
      let base = [255, 255, 255]
      if (!layers.length || layers[layers.length - 1][3] < 1) {
        const body = parse(getComputedStyle(document.body).backgroundColor)
        if (body && body[3] > 0) base = body.slice(0, 3)
      }
      for (const layer of layers.reverse()) {
        const a = layer[3]
        base = base.map((c, i) => layer[i] * a + c * (1 - a))
      }
      return base
    }
    const panel = document.querySelector('[role="tabpanel"][data-state="active"]')
    if (!panel) return { checked: 0, violations: ['sin tabpanel'], lowest: '' }
    const violations: string[] = []
    let checked = 0
    let lowest = { ratio: Infinity, text: '' }
    const walker = document.createTreeWalker(panel, NodeFilter.SHOW_TEXT)
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = (node.textContent ?? '').trim()
      const el = node.parentElement
      if (!text || !el) continue
      if (el.closest('[role="img"]')) continue
      if (el.closest(':disabled, fieldset:disabled, [aria-disabled="true"]')) continue
      const style = getComputedStyle(el)
      if (style.visibility === 'hidden' || style.display === 'none' || el.getBoundingClientRect().width === 0) continue
      const fg = parse(style.color)
      if (!fg) continue
      const bg = effectiveBackground(el)
      const blended = fg.slice(0, 3).map((c, i) => c * fg[3] + bg[i] * (1 - fg[3]))
      const ratio = (Math.max(lum(blended), lum(bg)) + 0.05) / (Math.min(lum(blended), lum(bg)) + 0.05)
      const px = parseFloat(style.fontSize)
      const large = px >= 24 || (px >= 18.66 && Number(style.fontWeight) >= 700)
      checked++
      if (ratio < lowest.ratio) lowest = { ratio, text: `${text.slice(0, 40)} (${large ? 'grande' : 'normal'})` }
      if (ratio < (large ? 3 : 4.5)) violations.push(`${ratio.toFixed(2)}:1 "${text.slice(0, 40)}" (${style.color} sobre rgb(${bg.map(Math.round).join(',')}))`)
    }
    return { checked, violations, lowest: `${lowest.ratio.toFixed(2)}:1 "${lowest.text}"` }
  })
}

async function expectAccessibleText(page: Page, label: string): Promise<void> {
  const { checked, violations, lowest } = await textContrastViolations(page)
  expect(checked, `${label}: no se midió ningún texto`).toBeGreaterThan(5)
  expect(violations, `${label}: textos bajo AA`).toEqual([])
  if (VISUAL_DIR) {
    await mkdir(VISUAL_DIR, { recursive: true })
    await appendFile(path.join(VISUAL_DIR, 'contraste-textos.jsonl'), `${JSON.stringify({ label, checked, lowest })}
`)
  }
}

/** Control positivo del medidor: un texto del color del fondo tiene que aparecer como violación (en cualquier tema). */
async function expectContrastProbeIsDetected(page: Page): Promise<void> {
  await page.evaluate(() => {
    const probe = document.createElement('p')
    probe.id = 'contrast-probe'
    probe.textContent = 'texto de control ilegible'
    probe.style.color = 'transparent'    // el mismo color que el fondo, sea cual sea el tema: contraste 1:1
    document.querySelector('[role="tabpanel"][data-state="active"]')!.appendChild(probe)
  })
  const { violations } = await textContrastViolations(page)
  await page.evaluate(() => document.getElementById('contrast-probe')?.remove())
  expect(violations.some((v) => v.includes('texto de control ilegible')), 'el medidor no vio el texto de control').toBe(true)
}

/**
 * Una flecha "de verdad": Radix marca la flecha como presionada en keydown y la suelta en keyup, y el
 * foco del RadioGroup se mueve en un timeout posterior al keydown. `keyboard.press` manda keyup al
 * instante y la selección por flecha no llega a producirse; una pulsación humana dura ~100 ms.
 */
async function pressArrow(page: Page, key: 'ArrowUp' | 'ArrowDown'): Promise<void> {
  await page.keyboard.down(key)
  await page.waitForTimeout(120)
  await page.keyboard.up(key)
}

/**
 * El logo de la vista previa convive con el título del documento sin pisarlo: lado a lado (el logo termina
 * antes de que empiece el título) o, si no alcanza el ancho, el título debajo. Ambos dentro del papel.
 * Mide las cajas reales del navegador; jsdom no calcula layout. Deja la geometría en DOCS_VISUAL_DIR.
 */
async function expectPreviewLogoClearOfTitle(page: Page, label: string): Promise<void> {
  const g = await page.evaluate(() => {
    const paper = document.querySelector('[role="img"][aria-label^="Vista previa del encabezado"]')
    const logo = paper?.querySelector('img[alt="Logo de la empresa"]')
    const title = Array.from(paper?.querySelectorAll('p') ?? []).find((p) => p.textContent === 'PRESUPUESTO')
    if (!paper || !logo || !title) return null
    const r = (el: Element) => { const b = el.getBoundingClientRect(); return { left: b.left, right: b.right, top: b.top, bottom: b.bottom, width: b.width, height: b.height } }
    return { paper: r(paper), logo: r(logo), title: r(title) }
  })
  expect(g, `${label}: no se encontró el logo o el título en la vista previa`).not.toBeNull()
  const { paper, logo, title } = g!
  const sideBySide = logo.right <= title.left + 0.5
  const stacked = logo.bottom <= title.top + 0.5
  expect(sideBySide || stacked, `${label}: el logo (${logo.left.toFixed(0)}-${logo.right.toFixed(0)}) se superpone con el título (${title.left.toFixed(0)}-${title.right.toFixed(0)})`).toBe(true)
  expect(logo.left, `${label}: el logo se sale del papel por la izquierda`).toBeGreaterThanOrEqual(paper.left - 0.5)
  expect(title.right, `${label}: el título se sale del papel por la derecha`).toBeLessThanOrEqual(paper.right + 0.5)
  expect(logo.right, `${label}: el logo se sale del papel por la derecha`).toBeLessThanOrEqual(paper.right + 0.5)
  if (VISUAL_DIR) {
    await mkdir(VISUAL_DIR, { recursive: true })
    const line = { label, layout: sideBySide ? 'lado a lado' : 'apilado', logo, title, paper }
    await appendFile(path.join(VISUAL_DIR, 'preview-logo-geometria.jsonl'), JSON.stringify(line) + '\n')
  }
}

/** La pestaña es más larga que el viewport: se captura con uno alto y se restaura el de la combinación. */
async function snapTall(page: Page, combo: Combo, name: string): Promise<void> {
  if (!VISUAL_DIR) return
  await page.setViewportSize({ width: combo.w, height: 2600 })
  await page.waitForTimeout(400)
  await snap(page, VISUAL_DIR, name)
  await page.setViewportSize({ width: combo.w, height: combo.h })
}

// ── El spec ──────────────────────────────────────────────────────────────────

test.describe('Documentos con la marca de la cuenta (stack local)', () => {
  test.beforeAll(() => assertLocalEnv('documentos-marca'))

  for (const combo of COMBOS) {
    const tag = comboTag(combo)

    test(`marca → vista previa → PDF/comprobante con logo y paleta → vendedor en sólo lectura · ${tag}`, async ({ request, browser }) => {
      const db = rest(request)
      const ownerId = await ensureUser(request, OWNER_EMAIL)
      const sellerId = await ensureUser(request, SELLER_EMAIL)
      const account = await accountOf(request, ownerId)
      await ensureSellerOf(request, sellerId, account.accountId)

      // Punto de partida conocido: sin marca, sin perfil fiscal, con el negocio del perfil del dueño.
      await db.del(`account_branding?account_id=eq.${account.accountId}`)
      await db.del(`fiscal_profiles?account_id=eq.${account.accountId}`)
      await db.patch(`profiles?id=eq.${ownerId}`, { business_name: OWNER_BUSINESS, phone: '2610000001' })

      const owner = await freshSession(browser, combo, OWNER_EMAIL)
      const page = owner.page
      try {
        // ── 1. Cuenta sin marca: la vista previa usa la cascada ───────────────
        await page.goto('/configuracion?tab=documentos')
        const preview = page.getByRole('img', { name: /vista previa del encabezado/i })
        await expect(preview).toBeVisible({ timeout: 90_000 })
        await expect(preview).toContainText(OWNER_BUSINESS)
        await expect(preview.getByAltText('Logo de la empresa')).toHaveCount(0)
        await expect(page.getByLabel('Razón social')).toBeEnabled()
        await expect(page.getByLabel('CUIT')).toBeEnabled()
        await expect(page.getByRole('button', { name: 'Guardar' })).toBeDisabled()
        await expect(page.getByRole('radio', { name: 'Neutro (blanco)' })).toBeChecked()
        await expectNoHorizontalOverflow(page)
        await expectContrastProbeIsDetected(page)
        await expectAccessibleText(page, `${tag} sin marca`)
        await snapTall(page, combo, `${tag}-1-documentos-sin-marca`)

        // ── 2. Completar la marca, subir el logo y elegir Bordó ───────────────
        await page.getByLabel('Nombre comercial').fill('Sumar Ropa Deportiva')
        await page.getByLabel('Razón social').fill('Ropa Deportiva SRL')
        await page.getByLabel('CUIT').fill('20123456786')
        await page.getByLabel('Domicilio').fill('Av. San Martín 1234, Mendoza')
        await page.getByLabel('Teléfono').fill('2617175072')
        await page.getByLabel('Email del negocio').fill('ventas@sumar.com.ar')
        await page.getByLabel('Sitio web').fill('sumar.com.ar')
        await page.getByLabel('Leyenda al pie de los papeles').fill('Alias para transferencias: sumar.ropa')

        await page.locator('input[type="file"]').setInputFiles({ name: 'logo.png', mimeType: 'image/png', buffer: makeLogoPng() })
        await expect(page.getByText(/Logo actualizado/)).toBeVisible({ timeout: 60_000 })
        await expect(preview.getByAltText('Logo de la empresa')).toBeVisible({ timeout: 30_000 })
        await expectPreviewLogoClearOfTitle(page, `${tag} logo recién subido`)

        await page.getByRole('radio', { name: 'Bordó' }).click()
        await expect(preview.getByText('PRESUPUESTO')).toHaveCSS('color', 'rgb(159, 18, 57)')
        await expect(preview).toContainText('Sumar Ropa Deportiva')
        await expect(preview).toContainText('CUIT: 20-12345678-6')
        await expect(preview).toContainText('Alias para transferencias: sumar.ropa')
        await expectNoHorizontalOverflow(page)
        await snapTall(page, combo, `${tag}-2-documentos-completando`)

        await page.getByRole('button', { name: 'Guardar' }).click()
        await expect(page.getByText(/Guardamos los datos de tus documentos/)).toBeVisible({ timeout: 30_000 })
        await expect(page.getByRole('button', { name: 'Guardar' })).toBeDisabled()

        const [saved] = await db.get(
          `account_branding?account_id=eq.${account.accountId}&select=display_name,tax_id,palette_preset,accent_color,logo_sha256,logo_width,logo_height,updated_by`,
        )
        expect(saved.display_name).toBe('Sumar Ropa Deportiva')
        expect(saved.tax_id).toBe('20-12345678-6')
        expect(saved.palette_preset).toBe('bordo')
        expect(saved.accent_color).toBeNull()
        expect(String(saved.logo_sha256)).toMatch(/^[0-9a-f]{64}$/)
        expect(saved.updated_by).toBe(ownerId)

        // Persistencia: al recargar vuelve todo, el logo incluido.
        await page.reload()
        await expect(page.getByLabel('Nombre comercial')).toHaveValue('Sumar Ropa Deportiva', { timeout: 60_000 })
        await expect(page.getByRole('radio', { name: 'Bordó' })).toBeChecked()
        await expect(preview.getByAltText('Logo de la empresa')).toBeVisible({ timeout: 30_000 })
        await expect(preview.getByText('PRESUPUESTO')).toHaveCSS('color', 'rgb(159, 18, 57)')
        await expectPreviewLogoClearOfTitle(page, `${tag} guardado y recargado`)
        await snapTall(page, combo, `${tag}-3-documentos-guardado-bordo`)

        // Teclado: las flechas recorren las paletas (RadioGroup), el foco se ve y la elección cambia la vista previa.
        await page.getByRole('radio', { name: 'Bordó' }).focus()
        await pressArrow(page, 'ArrowUp')
        await expect(page.getByRole('radio', { name: 'Grafito' })).toBeChecked()
        await expect(page.getByRole('radio', { name: 'Grafito' })).toBeFocused()
        await expect(preview.getByText('PRESUPUESTO')).toHaveCSS('color', 'rgb(51, 65, 85)')
        const ring = await page.getByRole('radio', { name: 'Grafito' }).evaluate((el) => {
          const style = getComputedStyle(el)
          return `${style.boxShadow} ${style.outlineStyle}`
        })
        expect(ring, 'el radio enfocado por teclado tiene que mostrar el foco').not.toMatch(/^none none$/)
        await snap(page, VISUAL_DIR, `${tag}-3b-foco-teclado-paleta`)
        await pressArrow(page, 'ArrowDown')
        await expect(page.getByRole('radio', { name: 'Bordó' })).toBeChecked()

        // ── 3. Color personalizado: aviso en vivo y Guardar bloqueado ─────────
        await page.getByRole('radio', { name: 'Personalizado' }).click()
        await page.getByLabel('Código del color (#rrggbb)').fill('#facc15')
        await expect(page.getByText(/No se lee bien sobre blanco · 1,53:1/)).toBeVisible()
        await expect(page.getByRole('button', { name: 'Guardar' })).toBeDisabled()
        await expect(preview.getByText('PRESUPUESTO')).toHaveCSS('color', 'rgb(30, 41, 59)')
        await expectAccessibleText(page, `${tag} color ilegible (aviso en destructive)`)
        await snapTall(page, combo, `${tag}-4-color-ilegible-bloquea`)
        await page.getByLabel('Código del color (#rrggbb)').fill('#7c2d12')
        await expect(page.getByText(/Se lee bien sobre blanco · 9,37:1/)).toBeVisible()
        await expect(page.getByRole('button', { name: 'Guardar' })).toBeEnabled()
        await expectAccessibleText(page, `${tag} color legible (aviso en success)`)
        await snapTall(page, combo, `${tag}-5-color-legible`)
        await page.getByRole('radio', { name: 'Bordó' }).click()   // sin guardar el personalizado

        // ── 4. Con perfil fiscal: lo fiscal pasa a sólo lectura con enlace a AFIP ─
        await db.post('fiscal_profiles', {
          account_id: account.accountId, cuit: FISCAL_CUIT, iva_condition: 'monotributista',
          ambiente: 'homologacion', delegacion_autorizada: true,
          razon_social: 'PEREZ MARIA LAURA', nombre_fantasia: 'Sumar Fiscal', domicilio_comercial: 'Calle Fiscal 99, Mendoza',
        })
        await page.reload()
        const fiscalBlock = page.getByText(/Sale de Datos fiscales \(AFIP\)/)
        await expect(fiscalBlock).toBeVisible({ timeout: 60_000 })
        const block = page.locator('section', { has: fiscalBlock })
        await expect(block).toContainText('PEREZ MARIA LAURA')
        await expect(block).toContainText(FISCAL_CUIT)
        await expect(block).toContainText('IVA RESPONSABLE MONOTRIBUTO')
        await expect(block.getByRole('link', { name: /Datos fiscales/ })).toHaveAttribute('href', '/configuracion?tab=fiscal')
        await expect(page.getByLabel('Razón social')).toHaveCount(0)
        await expect(preview).toContainText(FISCAL_CUIT)        // el CUIT fiscal gana sobre el de la marca
        await expect(preview).toContainText('Sumar Ropa Deportiva') // el nombre comercial de la marca gana
        await expectNoHorizontalOverflow(page)
        await expectAccessibleText(page, `${tag} con perfil fiscal (bloque de sólo lectura)`)
        await expectPreviewLogoClearOfTitle(page, `${tag} con perfil fiscal (más líneas de emisor)`)
        await snapTall(page, combo, `${tag}-6-documentos-con-perfil-fiscal`)

        // ── 5. Papeles reales: presupuesto y remito en PDF, comprobante interno en HTML ─
        const jwt = await jwtFor(request, OWNER_EMAIL)
        const [client] = await db.post('clients', { user_id: ownerId, account_id: account.accountId, name: 'Cliente Documentos E2E' })
        const productName = `Remera marca ${tag} ${Date.now()}`
        const [product] = await db.post('products', {
          user_id: ownerId, account_id: account.accountId, name: productName, sku: `E2E-DOC-${Date.now()}`, cost: 500, price: 1234.5,
        })

        // El remito descuenta stock al emitirse: se le da existencia a la sucursal (RPC interna, service_role local).
        const stock = await request.post(`${SUPABASE_URL}/rest/v1/rpc/c21_apply_branch_stock_delta`, {
          headers: ADMIN_HEADERS,
          data: { p_account_id: account.accountId, p_product_id: product.id, p_branch_id: account.branchId, p_delta: 50 },
        })
        expect(stock.ok(), `stock → ${stock.status()} ${await stock.text()}`).toBeTruthy()

        const quote = await backendPost<{ id: string; number_label: string }>(request, jwt, '/quotes', {
          client_id: client.id, branch_id: account.branchId,
          items: [
            { product_id: product.id, quantity: 2, price: 1234.5, subtotal: 2469 },
            { description: 'Servicio de armado', quantity: 1, price: 800, subtotal: 800 },
          ],
        })
        await page.goto(`/presupuestos/${quote.id}`)
        await expect(page.getByRole('button', { name: 'Compartir' }).filter({ visible: true }).first()).toBeVisible({ timeout: 90_000 })
        await snap(page, VISUAL_DIR, `${tag}-7-presupuesto-detalle`)
        const quotePdf = await saveDownload(page, `${tag}-presupuesto.pdf`, async () => {
          await page.getByRole('button', { name: 'Compartir' }).filter({ visible: true }).first().click()
          await page.getByRole('menuitem', { name: 'Descargar PDF' }).click()
        })
        expect(quotePdf.bytes.subarray(0, 4).toString('latin1')).toBe('%PDF')
        expect(quotePdf.bytes.toString('latin1')).toContain('/Subtype /Image')   // el logo viaja embebido

        const note = await backendPost<{ id: string }>(request, jwt, '/delivery-notes', {
          client_id: client.id, branch_id: account.branchId, delivery_address: 'Av. Entrega 456, Mendoza',
          items: [{ product_id: product.id, quantity: 1, price: 1234.5, subtotal: 1234.5 }],
        })
        await page.goto(`/remitos/${note.id}`)
        await expect(page.getByRole('button', { name: 'Compartir' }).filter({ visible: true }).first()).toBeVisible({ timeout: 90_000 })
        const notePdf = await saveDownload(page, `${tag}-remito.pdf`, async () => {
          await page.getByRole('button', { name: 'Compartir' }).filter({ visible: true }).first().click()
          await page.getByRole('menuitem', { name: 'Descargar PDF' }).click()
        })
        expect(notePdf.bytes.subarray(0, 4).toString('latin1')).toBe('%PDF')
        expect(notePdf.bytes.toString('latin1')).toContain('/Subtype /Image')

        // Comprobante interno de una venta: HTML con la marca y SIN el email de Auth del dueño.
        const saleName = `Venta marca ${tag} ${Date.now()}`
        await seedManualSale(request, account, saleName)
        await page.goto('/ventas')
        await page.getByPlaceholder('Buscar en esta página...').fill(saleName)
        await page.getByText(saleName).filter({ visible: true }).first().click()
        // "Descargar / Imprimir" abre el comprobante en una pestaña nueva (blob:), lista para imprimir.
        const popupOpened = page.context().waitForEvent('page')
        await page.getByRole('button', { name: /^Comprobante/ }).filter({ visible: true }).first().click()
        await page.getByRole('menuitem', { name: 'Descargar / Imprimir' }).click()
        const printable = await popupOpened
        await printable.waitForLoadState('domcontentloaded')
        await expect(printable.getByText('Sumar Ropa Deportiva').first()).toBeVisible({ timeout: 30_000 })
        const html = await printable.content()
        expect(html).toContain('Sumar Ropa Deportiva')
        expect(html).toContain('#9f1239')                       // Bordó
        expect(html).toMatch(/src="data:image\/(png|jpeg);base64,/) // logo embebido (el servidor lo normaliza: sin alfa queda JPEG)
        expect(html).not.toContain(OWNER_EMAIL)                 // jamás el email de Auth
        expect(html).not.toContain('@local.test')
        await printable.setViewportSize({ width: combo.w, height: combo.h })
        await snap(printable, VISUAL_DIR, `${tag}-8-comprobante-interno-html`)
        if (VISUAL_DIR) await writeFile(path.join(VISUAL_DIR, `${tag}-comprobante-interno.html`), html, 'utf8')
        await printable.close()
      } finally {
        await owner.close()
      }

      // ── 6. Un vendedor ve la pestaña, pero en sólo lectura ──────────────────
      const seller = await freshSession(browser, combo, SELLER_EMAIL)
      try {
        await seller.page.goto('/configuracion?tab=documentos')
        const preview = seller.page.getByRole('img', { name: /vista previa del encabezado/i })
        await expect(preview).toBeVisible({ timeout: 90_000 })
        await expect(preview).toContainText('Sumar Ropa Deportiva')
        await expect(seller.page.getByLabel('Nombre comercial')).toBeDisabled()
        await expect(seller.page.getByLabel('Email del negocio')).toBeDisabled()
        await expect(seller.page.getByRole('radio', { name: 'Bordó' })).toBeDisabled()
        await expect(seller.page.getByRole('button', { name: 'Guardar' })).toHaveCount(0)
        await expect(seller.page.getByRole('button', { name: /Subir logo|Cambiar logo|Quitar logo/ })).toHaveCount(0)
        await expect(seller.page.getByText(/Sólo el dueño o un administrador/)).toBeVisible()
        await expectNoHorizontalOverflow(seller.page)
        await expectAccessibleText(seller.page, `${tag} vendedor (aviso de sólo lectura)`)
        await expectPreviewLogoClearOfTitle(seller.page, `${tag} vendedor`)
        await snapTall(seller.page, combo, `${tag}-9-documentos-vendedor-solo-lectura`)

        // El servidor también lo cierra: el vendedor no puede guardar por la API.
        const sellerJwt = await jwtFor(request, SELLER_EMAIL)
        const forbidden = await request.put(`${BACKEND}/document-branding`, {
          headers: { Authorization: `Bearer ${sellerJwt}` },
          data: { display_name: 'Intento del vendedor', palette_preset: 'verde' },
        })
        expect(forbidden.status()).toBe(403)
        const [after] = await db.get(`account_branding?account_id=eq.${account.accountId}&select=display_name,palette_preset`)
        expect(after.display_name).toBe('Sumar Ropa Deportiva')
        expect(after.palette_preset).toBe('bordo')
      } finally {
        await seller.close()
      }
    })
  }
})
