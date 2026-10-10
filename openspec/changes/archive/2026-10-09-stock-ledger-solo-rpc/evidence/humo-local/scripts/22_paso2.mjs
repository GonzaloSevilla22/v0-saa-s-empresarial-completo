// Paso 2: /stock > Importar ajuste con CSV de 2 filas (una sin motivo) -> fila bloqueada; CSV corregido -> importa; historial con motivos.
import { chromium, ctxFor, open, shot, watch, rec, sql } from './humo-lib.mjs'
const browser = await chromium.launch()
const ctx = await ctxFor(browser, 'owner')
const page = await ctx.newPage()
watch(page, 'paso2')
const S = 'paso2'
const csv = (s) => ({ name: 'ajustes.csv', mimeType: 'text/csv', buffer: Buffer.from(s, 'utf8') })
const stockOf = (sku) => sql(`select coalesce(sum(bs.quantity),0) from branch_stock bs join products p on p.id=bs.product_id where p.sku='${sku}'`)
const movs = () => sql("select count(*) from stock_movements")
await open(page, '/stock', 'Tomate perita')
await page.getByRole('button', { name: /importar ajuste/i }).click()
const dialog = page.getByRole('dialog')
await dialog.waitFor()
await shot(page, `${S}-01-importador-paso1`)

// 2a: dos filas, una sin motivo
const csvA = 'Nombre;Tipo;Cantidad;Motivo\nTomate perita;Ajuste entrada;5;Reposición humo importador\nAlfajor artesanal;Pérdida;2;\n'
const m0 = movs(), tom0 = stockOf('QA-TOMATE'), alf0 = stockOf('QA-ALF')
await dialog.locator('input[type=file]').setInputFiles(csv(csvA))
await dialog.getByText('Falta el motivo').first().waitFor({ timeout: 30000 })
const applyBtnA = dialog.getByRole('button', { name: /^aplicar/i })
const textA = (await applyBtnA.textContent())?.trim(), disA = await applyBtnA.isDisabled()
const faltaCount = await dialog.getByText('Falta el motivo').count()
const omitMsg = (await dialog.getByText(/se omitirán al confirmar/i).textContent().catch(() => ''))?.trim()
await shot(page, `${S}-02-fila-sin-motivo`)
rec('2a', 'Importar ajuste con CSV de 2 filas (Tomate con motivo, Alfajor SIN motivo)', 'La fila sin motivo queda bloqueada y explicada', `"Falta el motivo" x${faltaCount} en la fila de Alfajor; botón de confirmar="${textA}" (deshabilitado=${disA}); aviso="${omitMsg}"`, faltaCount >= 1, `${S}-02-fila-sin-motivo.png`)

// 2b: una sola fila y sin motivo -> confirmar deshabilitado
await dialog.getByRole('button', { name: /cambiar archivo/i }).click()
const csvB = 'Nombre;Tipo;Cantidad;Motivo\nAlfajor artesanal;Pérdida;2;\n'
await dialog.locator('input[type=file]').setInputFiles(csv(csvB))
await dialog.getByText('Falta el motivo').first().waitFor({ timeout: 30000 })
const applyBtnB = dialog.getByRole('button', { name: /^aplicar/i })
const textB = (await applyBtnB.textContent())?.trim(), disB = await applyBtnB.isDisabled()
await shot(page, `${S}-03-sin-filas-validas`)
rec('2b', 'CSV con una única fila y sin motivo', 'Confirmación deshabilitada (no hay nada aplicable)', `botón="${textB}" deshabilitado=${disB}`, disB, `${S}-03-sin-filas-validas.png`)

// 2c: CSV corregido
await dialog.getByRole('button', { name: /cambiar archivo/i }).click()
const csvC = 'Nombre;Tipo;Cantidad;Motivo\nTomate perita;Ajuste entrada;5;Reposición humo importador\nAlfajor artesanal;Pérdida;2;Rotura en depósito (humo)\n'
await dialog.locator('input[type=file]').setInputFiles(csv(csvC))
await dialog.getByRole('button', { name: /^aplicar 2 ajustes$/i }).waitFor({ timeout: 30000 })
const faltaC = await dialog.getByText('Falta el motivo').count()
await shot(page, `${S}-04-csv-corregido-preview`)
await dialog.getByRole('button', { name: /^aplicar 2 ajustes$/i }).click()
await dialog.getByText(/2 ajustes registrados correctamente/i).waitFor({ timeout: 60000 })
await shot(page, `${S}-05-resultado`)
const rows = sql("select type||' | '||quantity_delta||' | '||coalesce(reason,'NULL')||' | '||product_name from stock_movements order by movement_number desc limit 2")
const m1 = movs(), tom1 = stockOf('QA-TOMATE'), alf1 = stockOf('QA-ALF')
rec('2c', 'CSV corregido (ambas filas con motivo) > Aplicar 2 ajustes', 'Importa y el historial muestra los movimientos con su motivo', `movimientos ${m0} -> ${m1}; tomate ${tom0} -> ${tom1}; alfajor ${alf0} -> ${alf1}; filas "Falta el motivo"=${faltaC}; últimos: ${rows.replace(/\n/g, ' // ')}`, Number(m1) === Number(m0) + 2 && Number(tom1) === Number(tom0) + 5 && Number(alf1) === Number(alf0) - 2 && /Reposición humo importador/.test(rows) && /Rotura en depósito/.test(rows), `${S}-04-csv-corregido-preview.png, ${S}-05-resultado.png`)
await dialog.getByRole('button', { name: /cerrar/i }).first().click()
await dialog.waitFor({ state: 'detached' }).catch(() => {})
await page.waitForTimeout(800)
await page.getByText('Historial de movimientos').first().click()
await page.getByText('Rotura en depósito (humo)').first().waitFor({ timeout: 30000 }).catch(() => {})
const vis1 = await page.getByText('Reposición humo importador').filter({ visible: true }).count()
const vis2 = await page.getByText('Rotura en depósito (humo)').filter({ visible: true }).count()
await page.getByText('Rotura en depósito (humo)').first().scrollIntoViewIfNeeded().catch(() => {})
await shot(page, `${S}-06-historial`)
rec('2d', '/stock > Historial de movimientos tras la importación', 'Ambos movimientos con su motivo', `visibles: "Reposición humo importador"=${vis1}, "Rotura en depósito (humo)"=${vis2}`, vis1 >= 1 && vis2 >= 1, `${S}-06-historial.png`)
await browser.close()
