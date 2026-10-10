// Recaptura sin mutar datos: el diálogo de edición de producto desplazado al final (sección Stock completa), owner y seller.
import { chromium, ctxFor, open, shot } from './humo-lib.mjs'
const browser = await chromium.launch()
for (const [role, file] of [['owner', 'paso3-01b-edicion-stock-actual-completa'], ['seller', 'paso7-03b-edicion-seller-completa']]) {
  const ctx = await ctxFor(browser, role)
  const page = await ctx.newPage()
  await open(page, '/productos', 'Tomate perita')
  const holder = page.getByText('Tomate perita').filter({ visible: true }).first().locator('xpath=ancestor::*[.//button[.//*[contains(@class,"lucide-pencil")]]][1]')
  await holder.locator('button:has(.lucide-pencil)').first().click()
  const edit = page.getByRole('dialog', { name: /editar producto/i })
  await edit.waitFor(); await page.waitForTimeout(800)
  await edit.getByRole('button', { name: /actualizar producto/i }).scrollIntoViewIfNeeded()
  await shot(page, file)
  console.log('captura', file)
  await ctx.close()
}
await browser.close()
