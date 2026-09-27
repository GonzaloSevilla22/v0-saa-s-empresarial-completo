import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
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
 * factura-fiscal-imprimible — de punta a punta en el stack LOCAL (Next → FastAPI
 * → Postgres con la cadena completa → relay con el STUB en homologación):
 *
 *   1. /configuracion/fiscal: con los datos del emisor vacíos, el aviso nombra
 *      lo que falta; se completan desde la UI y el aviso desaparece.
 *   2. /ventas: se factura una venta a mano, el relay (stub) la autoriza y el
 *      bloque del comprobante muestra "Factura C …", el CAE y "Verificar en ARCA".
 *   3. El menú pasa a "Factura"; "Descargar factura (PDF)" baja
 *      `factura-C-PPPP-NNNNNNNN.pdf`, un PDF de verdad generado por el backend.
 *   4. /ventas/ordenes muestra "Autorizado" al cargar (antes: "En trámite" fijo).
 *   5. La base: el comprobante quedó con la fecha que "ARCA" (el stub) confirmó
 *      y la foto del emisor tomada al autorizar.
 *
 * Corre en las 4 combinaciones (1366×768 / 375×812 × claro / oscuro). Con
 * FACTURA_VISUAL_DIR definido deja las capturas ahí.
 */

const VISUAL_DIR = process.env.FACTURA_VISUAL_DIR

test.describe('Factura imprimible (stack local + stub)', () => {
  test.beforeAll(() => assertLocalEnv('factura-imprimible'))

  for (const combo of COMBOS) {
    const tag = comboTag(combo)

    test(`datos del emisor → factura autorizada con CAE → PDF → órdenes · ${tag}`, async ({ page, request, context }) => {
      await applyCombo(page, context, combo)
      const db = rest(request)

      const ctx = await qaUserAndAccount(request)
      const profile = await ensureFiscalSetup(request, ctx.accountId)
      // Punto de partida conocido: sin datos del emisor (service_role local).
      await db.patch(`fiscal_profiles?id=eq.${profile.id}`, {
        razon_social: null, nombre_fantasia: null, domicilio_comercial: null,
        iibb_numero: null, inicio_actividades: null,
      })

      // ── 1. Configuración → Datos para imprimir la factura ────────────────
      await page.goto('/configuracion/fiscal')
      const seccion = page.getByText('Datos para imprimir la factura', { exact: true })
      await expect(seccion).toBeVisible({ timeout: 60_000 })
      const aviso = page.getByText(/Para imprimir tus facturas falta completar/)
      await expect(aviso).toBeVisible()
      await expect(aviso).toContainText('el domicilio comercial')
      await expect(aviso).toContainText('la fecha de inicio de actividades')
      await aviso.scrollIntoViewIfNeeded()
      await expectNoHorizontalOverflow(page)
      await snap(page, VISUAL_DIR, `${tag}-1-config-faltan`)

      await page.getByLabel('Razón social').fill('PEREZ MARIA LAURA')
      await page.getByLabel('Nombre de fantasía (opcional)').fill('Sumar')
      await page.getByLabel('Domicilio comercial').fill('Av. San Martín 1234, Mendoza')
      await page.getByLabel('Número de Ingresos Brutos').fill('0712345')
      await page.getByLabel('Inicio de actividades').fill('2019-03-01')
      await page.getByRole('button', { name: 'Guardar datos para imprimir' }).click()
      await expect(page.getByText('Datos para imprimir guardados.')).toBeVisible({ timeout: 30_000 })
      await expect(aviso).toBeHidden()
      await page.getByLabel('Razón social').scrollIntoViewIfNeeded()
      await snap(page, VISUAL_DIR, `${tag}-2-config-completo`)

      const [perfil] = await db.get(`fiscal_profiles?id=eq.${profile.id}&select=razon_social,domicilio_comercial,inicio_actividades,cuit`)
      expect(perfil.razon_social).toBe('PEREZ MARIA LAURA')
      expect(perfil.inicio_actividades).toBe('2019-03-01')

      // ── 2. /ventas: facturar → autorizar (stub) → CAE visible ────────────
      const productName = `Factura imprimible ${tag} ${Date.now()}`
      const operationId = await seedManualSale(request, ctx, productName)
      await page.goto('/ventas')
      await page.getByPlaceholder('Buscar en esta página...').fill(productName)
      await page.getByText(productName).filter({ visible: true }).first().click()
      await page.getByRole('button', { name: 'Facturar esta venta en AFIP' }).click()
      await page.getByRole('button', { name: /Emitir comprobante/ }).click()
      await expect(page.getByText('En trámite (esperando CAE)').filter({ visible: true }).first()).toBeVisible({ timeout: 30_000 })
      // En trámite no hay CAE ni verificación.
      await expect(page.getByRole('link', { name: /Verificar en ARCA/ })).toHaveCount(0)

      const relay = await request.post(`${BACKEND}/fiscal/documents/process-pending-cron`, {
        headers: { Authorization: `Bearer ${RELAY_SECRET}` },
      })
      expect(relay.status(), await relay.text()).toBe(200)

      await expect(page.getByText('Autorizado por AFIP').filter({ visible: true }).first()).toBeVisible({ timeout: 60_000 })
      const factura = page.getByText(/^Factura C \d{4}-\d{8}$/).filter({ visible: true }).first()
      await expect(factura).toBeVisible({ timeout: 30_000 })
      const label = ((await factura.textContent()) ?? '').replace('Factura C ', '').trim()
      await expect(page.getByText(/^\d{14}$/).filter({ visible: true }).first()).toBeVisible()
      await expect(page.getByText(/vence \d{2}\/\d{2}\/\d{4}/).filter({ visible: true }).first()).toBeVisible()
      const verificar = page.getByRole('link', { name: /Verificar en ARCA/ }).filter({ visible: true }).first()
      await expect(verificar).toHaveAttribute('href', 'https://servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx')
      await expect(verificar).toHaveAttribute('rel', 'noopener noreferrer')
      await verificar.scrollIntoViewIfNeeded()
      await expectNoHorizontalOverflow(page)
      await snap(page, VISUAL_DIR, `${tag}-3-venta-autorizada-cae`)

      // ── 3. Menú "Factura" → descargar el PDF ─────────────────────────────
      const menu = page.getByRole('button', { name: /^Factura/ }).filter({ visible: true }).first()
      await menu.click()
      for (const item of ['Ver / imprimir factura', 'Descargar factura (PDF)', 'Descargar duplicado', 'Verificar en ARCA',
        'Comprobante interno (sin validez fiscal)']) {
        await expect(page.getByRole('menuitem', { name: item })).toBeVisible()
      }
      await snap(page, VISUAL_DIR, `${tag}-4-menu-factura`)

      const pdfResponse = page.waitForResponse((r) => r.url().includes('/fiscal/documents/') && r.url().includes('/pdf'))
      const download = page.waitForEvent('download')
      await page.getByRole('menuitem', { name: 'Descargar factura (PDF)' }).click()
      const res = await pdfResponse
      expect(res.status()).toBe(200)
      expect(res.headers()['content-type']).toBe('application/pdf')
      const file = await download
      expect(file.suggestedFilename()).toBe(`factura-C-${label}.pdf`)
      const savedPath = VISUAL_DIR ? path.join(VISUAL_DIR, `${tag}-factura.pdf`) : await file.path()
      if (VISUAL_DIR) await file.saveAs(savedPath)
      const bytes = await readFile(savedPath)
      expect(bytes.subarray(0, 4).toString('latin1')).toBe('%PDF')

      // ── 4. /ventas/ordenes: estado REAL al cargar ────────────────────────
      await page.goto('/ventas/ordenes')
      const ordenLabel = page.getByText(`Factura C ${label}`, { exact: true }).filter({ visible: true }).first()
      await expect(ordenLabel).toBeVisible({ timeout: 60_000 })
      await ordenLabel.scrollIntoViewIfNeeded()
      await expect(page.getByText('Autorizado por AFIP').filter({ visible: true }).first()).toBeVisible()
      await expectNoHorizontalOverflow(page)
      await snap(page, VISUAL_DIR, `${tag}-5-ordenes-autorizada`)

      // ── 5. La base: fecha confirmada y foto del emisor ───────────────────
      const orders = await db.get(`sales_orders?sale_operation_id=eq.${operationId}&select=fiscal_document_id`)
      const [doc] = await db.get(
        `fiscal_documents?id=eq.${orders[0].fiscal_document_id}&select=status,fecha_comprobante,emisor_snapshot`,
      )
      expect(doc.status).toBe('authorized')
      expect(String(doc.fecha_comprobante)).toMatch(/^\d{4}-\d{2}-\d{2}$/)
      const snapshot = doc.emisor_snapshot as Record<string, unknown>
      expect(snapshot.razon_social).toBe('PEREZ MARIA LAURA')
      expect(snapshot.domicilio_comercial).toBe('Av. San Martín 1234, Mendoza')
      expect(snapshot.ambiente).toBe('homologacion')
    })
  }
})
