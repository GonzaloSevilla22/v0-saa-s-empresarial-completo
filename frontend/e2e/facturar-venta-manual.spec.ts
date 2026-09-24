import { test, expect, type APIRequestContext, type Page } from '@playwright/test'
import path from 'node:path'

/**
 * venta-editable-vs-promocion-legacy — "Facturar" de una venta cargada a mano,
 * de punta a punta y DE VERDAD: Next (pnpm dev) → FastAPI local → Postgres
 * local con la cadena de migraciones entera → relay del CAE con el STUB en
 * homologación → Realtime de vuelta al badge.
 *
 * Es la prueba que habría atrapado N2: el botón existía desde el PR #242 y la
 * promoción abortaba con 42883 en cada llamada — ningún test lo apretaba.
 *
 *   1. Siembra (service_role LOCAL, desde Node — nunca en el navegador): perfil
 *      fiscal monotributista en `homologacion`, UN punto de venta activo, y una
 *      venta cargada a mano ($1234,50 × 2 = $2469).
 *   2. /ventas → Facturar → «Emitir comprobante» → badge "En trámite
 *      (esperando CAE)" con el número del comprobante.
 *   3. El relay local (POST /fiscal/documents/process-pending-cron con el
 *      RELAY_SECRET del backend local; el backend corre SIN certificado de
 *      plataforma → WSFEStubAdapter).
 *   4. El badge pasa a "Autorizado por AFIP" SIN recargar (Realtime) y la fila
 *      a "Comprobante enviado a ARCA"; recargando, sigue autorizado con el
 *      mismo número (verdad del servidor).
 *   5. La base confirma: comprobante authorized por $2469 en homologación.
 *
 * Corre en las 4 combinaciones de la pasada visual (1366×768 / 375×812 ×
 * claro / oscuro). Con FACTURAR_VISUAL_DIR definido deja las capturas ahí.
 */

const SUPABASE_URL = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL_LOCAL ?? ''
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
const BACKEND = process.env.NEXT_PUBLIC_BACKEND_URL_LOCAL ?? 'http://localhost:8000'
const RELAY_SECRET = process.env.RELAY_SECRET ?? ''
const QA_EMAIL = process.env.QA_TEST_USER_EMAIL ?? ''
const VISUAL_DIR = process.env.FACTURAR_VISUAL_DIR

// CUIT y número de punto de venta propios del e2e (fn_guard_pos_cuit_cross_account
// rechaza el mismo CUIT con el mismo PV activo en otra cuenta).
const E2E_CUIT = '20999999991'
const E2E_PV = 9911

type Row = Record<string, unknown>

function rest(request: APIRequestContext) {
  const headers = {
    apikey: SERVICE_KEY,
    Authorization: `Bearer ${SERVICE_KEY}`,
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
  }
  return {
    async get(pathAndQuery: string): Promise<Row[]> {
      const res = await request.get(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, { headers })
      expect(res.ok(), `GET ${pathAndQuery} → ${res.status()} ${await res.text()}`).toBeTruthy()
      return (await res.json()) as Row[]
    },
    async post(table: string, body: Row): Promise<Row[]> {
      const res = await request.post(`${SUPABASE_URL}/rest/v1/${table}`, { headers, data: body })
      expect(res.ok(), `POST ${table} → ${res.status()} ${await res.text()}`).toBeTruthy()
      return (await res.json()) as Row[]
    },
  }
}

async function qaUserAndAccount(request: APIRequestContext): Promise<{ userId: string; accountId: string; branchId: string }> {
  const res = await request.get(`${SUPABASE_URL}/auth/v1/admin/users?per_page=1000`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  })
  expect(res.ok()).toBeTruthy()
  const users = ((await res.json()) as { users: { id: string; email: string }[] }).users
  const user = users.find((u) => u.email === QA_EMAIL)
  expect(user, `no existe el usuario QA ${QA_EMAIL} (¿corriste seed-users.mjs?)`).toBeTruthy()
  const db = rest(request)
  const members = await db.get(`account_members?user_id=eq.${user!.id}&select=account_id&order=created_at.asc&limit=1`)
  const accountId = String(members[0].account_id)
  const branches = await db.get(`branches?account_id=eq.${accountId}&is_active=eq.true&select=id&order=created_at.asc&limit=1`)
  return { userId: user!.id, accountId, branchId: String(branches[0].id) }
}

/** Perfil fiscal monotributista en homologación + un único PV activo (idempotente). */
async function ensureFiscalSetup(request: APIRequestContext, accountId: string): Promise<void> {
  const db = rest(request)
  let profiles = await db.get(`fiscal_profiles?account_id=eq.${accountId}&select=id,ambiente,iva_condition`)
  if (profiles.length === 0) {
    profiles = await db.post('fiscal_profiles', {
      account_id: accountId, cuit: E2E_CUIT, iva_condition: 'monotributista',
      ambiente: 'homologacion', delegacion_autorizada: true,
    })
  }
  // Candado del e2e: jamás correr contra un perfil de producción.
  expect(profiles[0].ambiente).toBe('homologacion')
  expect(profiles[0].iva_condition).toBe('monotributista')
  const pvs = await db.get(`points_of_sale?account_id=eq.${accountId}&is_active=eq.true&select=id`)
  if (pvs.length === 0) {
    await db.post('points_of_sale', {
      fiscal_profile_id: profiles[0].id, account_id: accountId, numero: E2E_PV, is_active: true,
    })
  }
}

/** Venta cargada a mano (forma del formulario, sin orden del POS): $1234,50 × 2. */
async function seedManualSale(request: APIRequestContext, ctx: { userId: string; accountId: string; branchId: string }, name: string) {
  const db = rest(request)
  const [product] = await db.post('products', {
    user_id: ctx.userId, account_id: ctx.accountId, name, sku: `E2E-FVM-${Date.now()}`, cost: 500, price: 1234.5,
  })
  const operationId = crypto.randomUUID()
  await db.post('sales', {
    user_id: ctx.userId, account_id: ctx.accountId, client_id: null, product_id: product.id,
    amount: 1234.5, quantity: 2, total: 2469, currency: 'ARS', date: new Date().toISOString(),
    operation_id: operationId, branch_id: ctx.branchId, canal: 'e2e-facturar',
  })
  return operationId
}

async function snap(page: Page, name: string) {
  if (!VISUAL_DIR) return
  await page.screenshot({ path: path.join(VISUAL_DIR, `${name}.png`), fullPage: false })
}

const COMBOS = [
  { w: 1366, h: 768, theme: 'light' as const },
  { w: 1366, h: 768, theme: 'dark' as const },
  { w: 375, h: 812, theme: 'light' as const },
  { w: 375, h: 812, theme: 'dark' as const },
]

test.describe('Facturar una venta cargada a mano (stack local + stub)', () => {
  test.beforeAll(() => {
    for (const [k, v] of Object.entries({ SUPABASE_URL, SERVICE_KEY, RELAY_SECRET, QA_EMAIL })) {
      if (!v) throw new Error(`[facturar-venta-manual] falta ${k} en el entorno`)
    }
    for (const u of [SUPABASE_URL, BACKEND]) {
      const host = new URL(u).hostname
      if (!['localhost', '127.0.0.1'].includes(host)) throw new Error(`[facturar-venta-manual] ${u} no es local`)
    }
  })

  for (const combo of COMBOS) {
    const tag = `${combo.w}x${combo.h}-${combo.theme === 'light' ? 'claro' : 'oscuro'}`

    test(`Facturar → Emitir → En trámite → relay (stub) → Autorizado · ${tag}`, async ({ page, request, context }) => {
      await page.setViewportSize({ width: combo.w, height: combo.h })
      await context.addCookies([{ name: 'ui:theme', value: combo.theme, url: 'http://localhost:3000' }])
      await context.addInitScript((t) => { try { localStorage.setItem('theme', t) } catch { /* noop */ } }, combo.theme)

      const ctx = await qaUserAndAccount(request)
      await ensureFiscalSetup(request, ctx.accountId)
      const productName = `Servicio e2e facturar ${tag} ${Date.now()}`
      const operationId = await seedManualSale(request, ctx, productName)

      await page.goto('/ventas')
      await page.getByPlaceholder('Buscar en esta página...').fill(productName)
      const rowTitle = page.getByText(productName).filter({ visible: true }).first()
      await expect(rowTitle).toBeVisible({ timeout: 60_000 })
      await rowTitle.click()

      // 1. Sin orden: "Facturar".
      const facturar = page.getByRole('button', { name: 'Facturar esta venta en AFIP' })
      await expect(facturar).toBeVisible()
      await snap(page, `${tag}-1-facturar`)
      await facturar.click()

      // 3. Preparada: "Emitir comprobante".
      await expect(page.getByText('Venta lista para facturar. Tocá «Emitir comprobante» para mandarla a ARCA.')).toBeVisible({ timeout: 30_000 })
      const emitir = page.getByRole('button', { name: /Emitir comprobante/ })
      await expect(emitir).toBeVisible()
      await expect(emitir).toBeEnabled()
      await expect(emitir).toHaveText(/Emitir comprobante/)
      // El botón entra en el viewport (también a 375 px).
      const box = await emitir.boundingBox()
      expect(box && box.x >= 0 && box.x + box.width <= combo.w).toBeTruthy()
      await snap(page, `${tag}-3-emitir-comprobante`)
      await emitir.click()

      // 5. En trámite, con el número, en la fila (read model refrescado).
      await expect(page.getByText('Comprobante enviado a ARCA — en trámite')).toBeVisible({ timeout: 30_000 })
      await expect(page.getByText('En trámite (esperando CAE)').filter({ visible: true }).first()).toBeVisible({ timeout: 30_000 })
      const numero = page.getByText(/^\d{4}-\d{8}$/).filter({ visible: true }).first()
      await expect(numero).toBeVisible({ timeout: 30_000 })
      const label = (await numero.textContent())?.trim() ?? ''
      expect(label).toMatch(/^\d{4}-\d{8}$/)
      await snap(page, `${tag}-5-en-tramite`)

      // Sin scroll horizontal del documento.
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
      expect(overflow).toBeLessThanOrEqual(1)

      // Relay local con el stub (homologación).
      const relay = await request.post(`${BACKEND}/fiscal/documents/process-pending-cron`, {
        headers: { Authorization: `Bearer ${RELAY_SECRET}` },
      })
      expect(relay.status(), await relay.text()).toBe(200)

      // 6. Autorizado SIN recargar (Realtime) + texto lateral de la fila.
      await expect(page.getByText('Autorizado por AFIP').filter({ visible: true }).first()).toBeVisible({ timeout: 60_000 })
      await expect(page.getByText('Comprobante enviado a ARCA', { exact: true }).filter({ visible: true }).first()).toBeVisible({ timeout: 30_000 })
      await snap(page, `${tag}-6-autorizado`)

      // Verdad del servidor: recargar mantiene "Autorizado" y el MISMO número.
      await page.reload()
      await page.getByPlaceholder('Buscar en esta página...').fill(productName)
      await page.getByText(productName).filter({ visible: true }).first().click()
      await expect(page.getByText('Autorizado por AFIP').filter({ visible: true }).first()).toBeVisible({ timeout: 60_000 })
      await expect(page.getByText(label, { exact: true }).filter({ visible: true }).first()).toBeVisible()
      await snap(page, `${tag}-7-autorizado-recargado`)

      // La base: comprobante authorized por $2469 en homologación.
      const db = rest(request)
      const orders = await db.get(`sales_orders?sale_operation_id=eq.${operationId}&select=id,total,fiscal_document_id,status`)
      expect(orders).toHaveLength(1)
      expect(Number(orders[0].total)).toBe(2469)
      const docs = await db.get(`fiscal_documents?id=eq.${orders[0].fiscal_document_id}&select=status,total,cae,fiscal_profile_id`)
      expect(docs[0].status).toBe('authorized')
      expect(Number(docs[0].total)).toBe(2469)
      expect(String(docs[0].cae ?? '')).toMatch(/^\d{14}$/)
      const prof = await db.get(`fiscal_profiles?id=eq.${docs[0].fiscal_profile_id}&select=ambiente`)
      expect(prof[0].ambiente).toBe('homologacion')
    })
  }
})
