import { expect, type APIRequestContext, type BrowserContext, type Page } from '@playwright/test'
import path from 'node:path'

/**
 * Siembra fiscal compartida por los e2e del stack LOCAL (service_role local,
 * desde Node — nunca en el navegador). Extraída de facturar-venta-manual.spec.ts
 * cuando factura-fiscal-imprimible sumó un segundo spec que necesita lo mismo
 * (regla "reutilización antes que repetición").
 *
 * Candados: todo host tiene que ser local y el perfil fiscal tiene que estar en
 * `homologacion` — el relay local corre con el STUB, que se niega a producción.
 */

export const SUPABASE_URL = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL_LOCAL ?? ''
export const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
export const BACKEND = process.env.NEXT_PUBLIC_BACKEND_URL_LOCAL ?? 'http://localhost:8000'
export const RELAY_SECRET = process.env.RELAY_SECRET ?? ''
export const QA_EMAIL = process.env.QA_TEST_USER_EMAIL ?? ''

// CUIT y número de punto de venta propios del e2e (fn_guard_pos_cuit_cross_account
// rechaza el mismo CUIT con el mismo PV activo en otra cuenta).
//
// factura-fiscal-imprimible: el CUIT tiene que ser VÁLIDO (módulo 11) y con el
// formato con guiones que guarda la UI (los 2 perfiles de prod lo tienen así,
// medido 2026-09-26): toda escritura del perfil desde la pantalla pasa por
// `isValidCuit`, y el seed anterior ('20999999991', dígito verificador
// inválido y sin guiones) hacía imposible guardar desde la UI — nadie lo había
// notado porque ningún e2e editaba el perfil.
export const E2E_CUIT = '20-12345678-6'
export const E2E_PV = 9911

export type Row = Record<string, unknown>

export const COMBOS = [
  { w: 1366, h: 768, theme: 'light' as const },
  { w: 1366, h: 768, theme: 'dark' as const },
  { w: 375, h: 812, theme: 'light' as const },
  { w: 375, h: 812, theme: 'dark' as const },
]

export type Combo = (typeof COMBOS)[number]

export function comboTag(combo: Combo): string {
  return `${combo.w}x${combo.h}-${combo.theme === 'light' ? 'claro' : 'oscuro'}`
}

/** Falla temprano si falta el entorno o algún host no es local. */
export function assertLocalEnv(spec: string): void {
  for (const [k, v] of Object.entries({ SUPABASE_URL, SERVICE_KEY, RELAY_SECRET, QA_EMAIL })) {
    if (!v) throw new Error(`[${spec}] falta ${k} en el entorno`)
  }
  for (const u of [SUPABASE_URL, BACKEND]) {
    const host = new URL(u).hostname
    if (!['localhost', '127.0.0.1'].includes(host)) throw new Error(`[${spec}] ${u} no es local`)
  }
}

/** Viewport + tema (cookie de next-themes y localStorage) de una combinación. */
export async function applyCombo(page: Page, context: BrowserContext, combo: Combo): Promise<void> {
  await page.setViewportSize({ width: combo.w, height: combo.h })
  await context.addCookies([{ name: 'ui:theme', value: combo.theme, url: 'http://localhost:3000' }])
  await context.addInitScript((t) => { try { localStorage.setItem('theme', t) } catch { /* noop */ } }, combo.theme)
}

export function rest(request: APIRequestContext) {
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
    async patch(pathAndQuery: string, body: Row): Promise<Row[]> {
      const res = await request.patch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, { headers, data: body })
      expect(res.ok(), `PATCH ${pathAndQuery} → ${res.status()} ${await res.text()}`).toBeTruthy()
      return (await res.json()) as Row[]
    },
  }
}

export async function qaUserAndAccount(
  request: APIRequestContext,
): Promise<{ userId: string; accountId: string; branchId: string }> {
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
export async function ensureFiscalSetup(request: APIRequestContext, accountId: string): Promise<Row> {
  const db = rest(request)
  let profiles = await db.get(`fiscal_profiles?account_id=eq.${accountId}&select=id,ambiente,iva_condition,cuit`)
  if (profiles.length === 0) {
    profiles = await db.post('fiscal_profiles', {
      account_id: accountId, cuit: E2E_CUIT, iva_condition: 'monotributista',
      ambiente: 'homologacion', delegacion_autorizada: true,
    })
  } else if (profiles[0].cuit !== E2E_CUIT && profiles[0].ambiente === 'homologacion') {
    // Stack local sembrado con el CUIT viejo del e2e: se alinea (nunca un perfil de producción).
    profiles = await db.patch(`fiscal_profiles?id=eq.${profiles[0].id}`, { cuit: E2E_CUIT })
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
  return profiles[0]
}

/** Venta cargada a mano (forma del formulario, sin orden del POS): $1234,50 × 2. */
export async function seedManualSale(
  request: APIRequestContext,
  ctx: { userId: string; accountId: string; branchId: string },
  name: string,
): Promise<string> {
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

/** Captura sólo si el directorio de evidencia está definido. */
export async function snap(page: Page, dir: string | undefined, name: string): Promise<void> {
  if (!dir) return
  await page.screenshot({ path: path.join(dir, `${name}.png`), fullPage: false })
}

/** Sin scroll horizontal del documento. */
export async function expectNoHorizontalOverflow(page: Page): Promise<void> {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(1)
}
