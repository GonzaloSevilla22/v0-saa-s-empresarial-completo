import { test, expect, type Page, type BrowserContext } from '@playwright/test'

/**
 * fix/comprobante-print-csp-nonce.
 *
 * Fija, contra un navegador real y la CSP real de la app, el MECANISMO que
 * arregla "Ventas → Comprobante → Descargar / Imprimir": un documento
 * `blob:` HEREDA la política del documento que crea la URL
 * (`lib/supabase/middleware.ts`: `script-src` con nonce + `'strict-dynamic'`,
 * SIN `'unsafe-inline'` en ningún entorno — ver `buildContentSecurityPolicy`).
 * Un `<script>` inline en ese blob corre si lleva el nonce vigente de la
 * página que lo creó; el mismo script sin nonce (o con uno distinto) queda
 * bloqueado en silencio — exactamente el bug que reportó el PO (se abre la
 * pestaña, nunca imprime).
 *
 * Corre en el proyecto `harness` (frontend/playwright.config.ts): sin sesión,
 * sin seeds, contra `/dev-harness/popover` (cualquier ruta pública sirve —
 * el middleware pone la CSP en todo lo que no sea un estático). No es un test
 * de `lib/receipt.ts` — ya cubierto en `__tests__/lib/receipt.test.ts` con
 * jsdom, que NO puede distinguir un script permitido de uno bloqueado (jsdom
 * no aplica CSP). Este spec es la única red que ejercita la CSP de verdad.
 */

const HARNESS = '/dev-harness/popover'

/** Abre un documento blob: con el `<script>` dado y espera a que cargue. */
async function openBlobScript(
  page: Page,
  context: BrowserContext,
  scriptTag: string,
  ranTitle: string,
) {
  const [popup] = await Promise.all([
    context.waitForEvent('page'),
    page.evaluate(
      ({ scriptTag, ranTitle }) => {
        const html = `<!DOCTYPE html><html><head><title>SIN-EJECUTAR</title></head><body>${scriptTag}document.title = ${JSON.stringify(ranTitle)}</script></body></html>`
        const url = URL.createObjectURL(new Blob([html], { type: 'text/html' }))
        window.open(url, '_blank')
      },
      { scriptTag, ranTitle },
    ),
  ])
  await popup.waitForLoadState('load')
  return popup
}

test.describe('CSP nonce inheritance — documento blob: (mecanismo del comprobante)', () => {
  test('un <script> con el nonce vigente de la página corre en el blob; el mismo script sin o con OTRO nonce queda bloqueado', async ({
    page,
    context,
  }) => {
    const response = await page.goto(HARNESS)
    expect(response).not.toBeNull()

    // Nonce real de ESTA petición, leído del header que el navegador aplica
    // de verdad — no de una copia en memoria del string de la política.
    const csp = response!.headers()['content-security-policy']
    expect(csp).toBeTruthy()
    const nonceMatch = csp!.match(/'nonce-([^']+)'/)
    expect(nonceMatch, `script-src sin nonce en la CSP real: ${csp}`).not.toBeNull()
    const nonce = nonceMatch![1]
    expect(nonce.length).toBeGreaterThan(10)

    // ── (a) CON el nonce vigente → el script corre ─────────────────────────
    const popupWithNonce = await openBlobScript(page, context, `<script nonce="${nonce}">`, 'NONCE-OK-EJECUTO')
    await expect.poll(() => popupWithNonce.title(), { timeout: 5000 }).toBe('NONCE-OK-EJECUTO')
    await popupWithNonce.close()

    // ── (b) SIN nonce → la CSP bloquea el mismo script (reproduce el bug) ──
    const popupNoNonce = await openBlobScript(page, context, '<script>', 'NO-DEBERIA-EJECUTAR')
    expect(await popupNoNonce.title()).toBe('SIN-EJECUTAR')
    await popupNoNonce.close()

    // ── (c) con OTRO nonce (no el vigente) → también bloqueado ─────────────
    // No alcanza con "tiene el atributo nonce": tiene que ser EL de esta
    // petición. Cubre, p. ej., un nonce cacheado/desactualizado de una carga
    // anterior tras una navegación de cliente.
    const popupWrongNonce = await openBlobScript(page, context, `<script nonce="${nonce}-distinto">`, 'NONCE-INCORRECTO-EJECUTO')
    expect(await popupWrongNonce.title()).toBe('SIN-EJECUTAR')
    await popupWrongNonce.close()
  })
})
