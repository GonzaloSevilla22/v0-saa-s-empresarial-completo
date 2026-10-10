// Paso 7: rol seller (sin permiso de ajuste) por UI y por API. Paso 8: negativos por API con el owner.
import { chromium, ctxFor, open, shot, watch, rec, sql, log, rest, IDS, API, jwtFor } from './humo-lib.mjs'
const ids = IDS()
const browser = await chromium.launch()
const stockOf = (sku) => Number(sql(`select coalesce(sum(bs.quantity),0) from branch_stock bs join products p on p.id=bs.product_id where p.sku='${sku}'`))
const nMov = () => Number(sql('select count(*) from stock_movements'))
const api = async (step, role, method, path, body) => {
  const r = await rest(role, method, path, body)
  log('30_api_paso7_8.log', `[${step}] ${role} ${method} /rest/v1/${path} ${body === undefined ? '' : JSON.stringify(body)} -> HTTP ${r.status} ${r.body}`)
  return r
}

// ── Paso 7: UI con seller ──
const ctx = await ctxFor(browser, 'seller')
const page = await ctx.newPage()
watch(page, 'paso7')
let S = 'paso7'
await open(page, '/stock', 'Tomate perita')
const aj = await page.getByRole('button', { name: /ajustar/i }).count()
const imp = await page.getByRole('button', { name: /importar ajuste/i }).count()
const ajTitle = await page.locator('button[title="Ajustar stock"]').count()
const transfer = await page.getByRole('button', { name: /transferir stock de/i }).count()
await shot(page, `${S}-01-stock-seller`)
rec('7a', '/stock con rol seller', 'Sin acciones de ajuste (ni botón, ni por fila) ni "Importar ajuste"', `botones "ajustar"=${aj}; botones por fila con title "Ajustar stock"=${ajTitle}; "Importar ajuste"=${imp}; (referencia: botones "Transferir stock de"=${transfer})`, aj === 0 && imp === 0 && ajTitle === 0, `${S}-01-stock-seller.png`)

await open(page, '/productos', 'Tomate perita')
await page.getByRole('button', { name: /nuevo producto/i }).first().click()
const alta = page.getByRole('dialog', { name: /nuevo producto/i })
await alta.waitFor(); await page.waitForTimeout(800)
const campo = await alta.getByLabel(/^stock inicial$/i).count()
const nota = await alta.getByText(/el stock inicial lo carga/i).count()
await shot(page, `${S}-02-producto-alta-seller`)
rec('7b', '/productos > Nuevo producto con rol seller', 'Formulario sin el campo "Stock inicial" (con la línea que explica quién lo carga)', `campo "Stock inicial"=${campo}; línea explicativa=${nota}`, campo === 0 && nota === 1, `${S}-02-producto-alta-seller.png`)
await page.keyboard.press('Escape')
await alta.waitFor({ state: 'detached' }).catch(() => {})

const holder = page.getByText('Tomate perita').filter({ visible: true }).first().locator('xpath=ancestor::*[.//button[.//*[contains(@class,"lucide-pencil")]]][1]')
await holder.locator('button:has(.lucide-pencil)').first().click()
const edit = page.getByRole('dialog', { name: /editar producto/i })
await edit.waitFor(); await page.waitForTimeout(800)
const actual = (await edit.getByTestId('current-stock').textContent().catch(() => ''))?.trim()
const btnAj = await edit.getByRole('button', { name: /^ajustar stock$/i }).count()
const aviso = await edit.getByText(/el stock lo ajusta el depósito/i).count()
await shot(page, `${S}-03-producto-edicion-seller`)
rec('7c', '/productos > editar Tomate perita con rol seller', '"Stock actual" sólo lectura y sin botón "Ajustar stock"', `Stock actual="${actual}"; botón "Ajustar stock"=${btnAj}; aviso "El stock lo ajusta el depósito…"=${aviso}`, !!actual && btnAj === 0 && aviso === 1, `${S}-03-producto-edicion-seller.png`)
await ctx.close()

// ── Paso 7: API con seller ──
const before = nMov(), tom0 = stockOf('QA-TOMATE')
let r = await api('7d', 'seller', 'POST', 'rpc/rpc_stock_adjustment', { p_product_id: ids.tomate, p_type: 'adjustment', p_quantity_delta: 1, p_reason: 'intento de seller (humo)' })
rec('7d', 'API como seller: POST /rest/v1/rpc/rpc_stock_adjustment con motivo', 'Rechazado (P0403)', `HTTP ${r.status}: ${r.body}`, r.status >= 400 && /P0403|insufficient_role/.test(r.body), '30_api_paso7_8.log')
r = await api('7e', 'seller', 'PATCH', `branch_stock?product_id=eq.${ids.tomate}`, { quantity: 999 })
rec('7e', 'API como seller: PATCH /rest/v1/branch_stock?product_id=eq.<tomate> {quantity:999}', 'Rechazado (42501 / 403)', `HTTP ${r.status}: ${r.body}`, r.status === 403 && /42501/.test(r.body), '30_api_paso7_8.log')
r = await api('7f', 'seller', 'POST', 'rpc/rpc_adjust_branch_stock', { p_product_id: ids.tomate, p_branch_id: ids.br1, p_new_quantity: 500, p_reason: 'intento de seller (humo)' })
rec('7f', 'API como seller (extra): POST /rest/v1/rpc/rpc_adjust_branch_stock con motivo', 'Rechazado (P0403)', `HTTP ${r.status}: ${r.body}`, r.status >= 400 && /P0403|insufficient_role/.test(r.body), '30_api_paso7_8.log')
rec('7g', 'Estado tras los intentos del seller', 'Sin cambios: ni saldo ni movimientos', `movimientos ${before} -> ${nMov()}; stock Tomate ${tom0} -> ${stockOf('QA-TOMATE')}`, nMov() === before && stockOf('QA-TOMATE') === tom0, '')

// ── Paso 8: negativos con owner ──
const m0 = nMov(), t0 = stockOf('QA-TOMATE')
r = await api('8a', 'owner', 'POST', 'rpc/rpc_apply_product_stock_delta', { p_product_id: ids.tomate, p_delta: 1, p_log_movement: false })
rec('8a', 'API como owner: POST rpc_apply_product_stock_delta con p_log_movement=false', 'Rechazado (P0400)', `HTTP ${r.status}: ${r.body}`, r.status >= 400 && /P0400/.test(r.body), '30_api_paso7_8.log')
r = await api('8b', 'owner', 'POST', 'stock_movements', { account_id: ids.accA, product_id: ids.tomate, type: 'adjustment', quantity_delta: 1, reason: 'insert directo (humo)' })
rec('8b', 'API como owner: POST /rest/v1/stock_movements directo', 'Rechazado (42501 / 403)', `HTTP ${r.status}: ${r.body}`, r.status === 403 && /42501/.test(r.body), '30_api_paso7_8.log')
r = await api('8c', 'owner', 'POST', 'rpc/rpc_reverse_stock_movement', { p_reference_id: ids.tomate, p_reference_type: 'sale', p_reason: 'humo' })
rec('8c', 'API como owner: POST /rest/v1/rpc/rpc_reverse_stock_movement', 'Rechazado (404 PGRST202 o 42501)', `HTTP ${r.status}: ${r.body}`, (r.status === 404 && /PGRST202/.test(r.body)) || /42501/.test(r.body), '30_api_paso7_8.log')
r = await api('8d', 'owner', 'PATCH', `branch_stock?product_id=eq.${ids.tomate}`, { quantity: 999 })
rec('8d', 'API como owner (extra): PATCH /rest/v1/branch_stock', 'Rechazado (42501 / 403)', `HTTP ${r.status}: ${r.body}`, r.status === 403 && /42501/.test(r.body), '30_api_paso7_8.log')
r = await api('8e', 'owner', 'POST', 'rpc/rpc_stock_adjustment', { p_product_id: ids.tomate, p_type: 'adjustment', p_quantity_delta: 1, p_reason: '   ' })
rec('8e', 'API como owner (extra): POST rpc_stock_adjustment con motivo en blanco', 'Rechazado (P0400)', `HTTP ${r.status}: ${r.body}`, r.status >= 400 && /P0400/.test(r.body), '30_api_paso7_8.log')
rec('8f', 'Estado tras los negativos del owner', 'Sin cambios: ni saldo ni movimientos', `movimientos ${m0} -> ${nMov()}; stock Tomate ${t0} -> ${stockOf('QA-TOMATE')}`, nMov() === m0 && stockOf('QA-TOMATE') === t0, '')

// ── Extra: el alta con stock inicial por el backend con seller es 403 y no crea el producto ──
const jwt = await jwtFor('seller')
const cnt0 = Number(sql("select count(*) from products where sku='HUMO-SELLER-1'"))
const catId = sql(`select id from product_categories where account_id='${ids.accA}' and name='Alimentos'`)
const resp = await fetch('http://localhost:8000/products', { method: 'POST', headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'Intento seller', sku: 'HUMO-SELLER-1', category_id: catId, price: 100, cost: 50, stock: 5, min_stock: 0, stock_control_type: 'tracked' }) })
const txt = (await resp.text()).slice(0, 400)
const cnt1 = sql("select count(*) from products where sku='HUMO-SELLER-1'")
log('30_api_paso7_8.log', `[7h] seller POST http://localhost:8000/products {stock:5} -> HTTP ${resp.status} ${txt}`)
rec('7h', 'Backend como seller (extra): POST /products con stock inicial 5', 'Rechazado (403) y el producto no se crea', `HTTP ${resp.status}: ${txt}; productos con SKU HUMO-SELLER-1: ${cnt0} -> ${cnt1}`, resp.status === 403 && cnt1 === '0', '30_api_paso7_8.log')
await browser.close()
