import { test, expect, type Page } from '@playwright/test'
import {
  BACKEND,
  COMBOS,
  RELAY_SECRET,
  applyCombo,
  assertLocalEnv,
  comboTag,
  ensureFiscalSetup,
  expectNoHorizontalOverflow,
  qaUserAndAccount,
  rest,
  seedManualSale,
  snap,
} from './fixtures/fiscal-e2e'

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

const VISUAL_DIR = process.env.FACTURAR_VISUAL_DIR

// factura-fiscal-imprimible: la siembra (usuario QA, perfil fiscal en
// homologación, PV, venta a mano) vive en fixtures/fiscal-e2e.ts, compartida
// con factura-imprimible.spec.ts.
async function snapHere(page: Page, name: string) {
  await snap(page, VISUAL_DIR, name)
}

test.describe('Facturar una venta cargada a mano (stack local + stub)', () => {
  test.beforeAll(() => assertLocalEnv('facturar-venta-manual'))

  for (const combo of COMBOS) {
    const tag = comboTag(combo)

    test(`Facturar → Emitir → En trámite → relay (stub) → Autorizado · ${tag}`, async ({ page, request, context }) => {
      await applyCombo(page, context, combo)

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
      await snapHere(page, `${tag}-1-facturar`)
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
      await snapHere(page, `${tag}-3-emitir-comprobante`)
      await emitir.click()

      // 5. En trámite, con el número, en la fila (read model refrescado).
      await expect(page.getByText('Comprobante enviado a ARCA — en trámite')).toBeVisible({ timeout: 30_000 })
      await expect(page.getByText('En trámite (esperando CAE)').filter({ visible: true }).first()).toBeVisible({ timeout: 30_000 })
      // factura-fiscal-imprimible: el bloque del comprobante nombra el tipo
      // ("Factura C 9911-00000005"), no sólo el número.
      const numero = page.getByText(/^Factura C \d{4}-\d{8}$/).filter({ visible: true }).first()
      await expect(numero).toBeVisible({ timeout: 30_000 })
      const label = (await numero.textContent())?.trim() ?? ''
      expect(label).toMatch(/^Factura C \d{4}-\d{8}$/)
      await snapHere(page, `${tag}-5-en-tramite`)

      // Sin scroll horizontal del documento.
      await expectNoHorizontalOverflow(page)

      // Relay local con el stub (homologación).
      const relay = await request.post(`${BACKEND}/fiscal/documents/process-pending-cron`, {
        headers: { Authorization: `Bearer ${RELAY_SECRET}` },
      })
      expect(relay.status(), await relay.text()).toBe(200)

      // 6. Autorizado SIN recargar (Realtime) + texto lateral de la fila.
      await expect(page.getByText('Autorizado por AFIP').filter({ visible: true }).first()).toBeVisible({ timeout: 60_000 })
      await expect(page.getByText('Comprobante enviado a ARCA', { exact: true }).filter({ visible: true }).first()).toBeVisible({ timeout: 30_000 })
      await snapHere(page, `${tag}-6-autorizado`)

      // Verdad del servidor: recargar mantiene "Autorizado" y el MISMO número.
      await page.reload()
      await page.getByPlaceholder('Buscar en esta página...').fill(productName)
      await page.getByText(productName).filter({ visible: true }).first().click()
      await expect(page.getByText('Autorizado por AFIP').filter({ visible: true }).first()).toBeVisible({ timeout: 60_000 })
      await expect(page.getByText(label, { exact: true }).filter({ visible: true }).first()).toBeVisible()
      await snapHere(page, `${tag}-7-autorizado-recargado`)

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
