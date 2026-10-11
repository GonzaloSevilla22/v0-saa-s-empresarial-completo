// Baja los PDF reales (presupuesto y remito) del stack LOCAL con tres marcas distintas (Neutro sin logo,
// Azul con logo, Bordó con logo) para revisarlos a ojo. Usa la cuenta que dejó el e2e (docs.owner.e2e).
// Env: el de env.sh. Uso: node pdf_variants.mjs <directorio de salida>
import { mkdirSync, writeFileSync } from 'node:fs'
import { deflateSync } from 'node:zlib'
import path from 'node:path'

const url = process.env.SUPABASE_URL
const key = process.env.SUPABASE_SERVICE_ROLE_KEY
const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY_LOCAL
const backend = process.env.NEXT_PUBLIC_BACKEND_URL_LOCAL
if (![url, backend].every((u) => /127\.0\.0\.1|localhost/.test(u ?? ''))) throw new Error('env no local')
const out = process.argv[2]
mkdirSync(out, { recursive: true })

const admin = { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }
const OWNER = 'docs.owner.e2e@local.test'
const PASSWORD = 'docs-marca-e2e-local-1'

const login = await (await fetch(`${url}/auth/v1/token?grant_type=password`, {
  method: 'POST', headers: { apikey: anon, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: OWNER, password: PASSWORD }),
})).json()
const jwt = login.access_token
const api = (route, init = {}) => fetch(`${backend}${route}`, { ...init, headers: { Authorization: `Bearer ${jwt}`, ...(init.headers ?? {}) } })

const account = (await (await fetch(`${url}/rest/v1/account_members?user_id=eq.${login.user.id}&select=account_id&limit=1`, { headers: admin })).json())[0].account_id
const quote = (await (await fetch(`${url}/rest/v1/quotes?account_id=eq.${account}&select=id&order=created_at.desc&limit=1`, { headers: admin })).json())[0]
const note = (await (await fetch(`${url}/rest/v1/delivery_notes?account_id=eq.${account}&select=id&order=created_at.desc&limit=1`, { headers: admin })).json())[0]

// el mismo logo de juguete del e2e (un PNG degradé)
function crc32(buf) { let c = ~0; for (const b of buf) { c ^= b; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1 } return ~c >>> 0 }
const chunk = (type, data) => { const body = Buffer.concat([Buffer.from(type), data]); const o = Buffer.alloc(8 + data.length + 4); o.writeUInt32BE(data.length, 0); body.copy(o, 4); o.writeUInt32BE(crc32(body), 4 + body.length); return o }
function logoPng(w = 360, h = 120) {
  const raw = Buffer.alloc((w * 3 + 1) * h)
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const o = y * (w * 3 + 1) + 1 + x * 3; raw[o] = 30 + Math.floor((x / w) * 200); raw[o + 1] = 90 + Math.floor((y / h) * 100); raw[o + 2] = 200 }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
}

const base = { display_name: 'Sumar Ropa Deportiva', phone: '2617175072', email: 'ventas@sumar.com.ar', website: 'sumar.com.ar', footer_note: 'Alias para transferencias: sumar.ropa' }
const variants = [
  ['neutro-sin-logo', { ...base, palette_preset: 'neutro' }, false],
  ['azul-con-logo', { ...base, palette_preset: 'azul' }, true],
  ['bordo-con-logo', { ...base, palette_preset: 'bordo' }, true],
  ['personalizado-con-logo', { ...base, palette_preset: 'personalizado', accent_color: '#7c2d12' }, true],
]
for (const [name, body, withLogo] of variants) {
  let r = await api('/document-branding', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
  if (!r.ok) throw new Error(`PUT ${name} ${r.status} ${await r.text()}`)
  if (withLogo) r = await api('/document-branding/logo', { method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' }, body: logoPng() })
  else r = await api('/document-branding/logo', { method: 'DELETE' })
  if (!r.ok) throw new Error(`logo ${name} ${r.status}`)
  for (const [kind, id, route] of [['presupuesto', quote.id, `/quotes/${quote.id}/pdf`], ['remito', note.id, `/delivery-notes/${note.id}/pdf`]]) {
    const pdf = await api(route)
    if (!pdf.ok) throw new Error(`${kind} ${name} ${pdf.status} ${await pdf.text()}`)
    const file = path.join(out, `${kind}-${name}.pdf`)
    writeFileSync(file, Buffer.from(await pdf.arrayBuffer()))
    console.log('ok', file)
  }
  // Comprobante interno de venta en PDF (el que se comparte por WhatsApp). El cuerpo trae los campos OBSOLETOS
  // del frontend anterior —un nombre falso y el email de ACCESO del dueño—: el servidor tiene que ignorarlos.
  const receipt = await api('/sales/receipt-pdf', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': crypto.randomUUID() },
    body: JSON.stringify({
      receipt_number: 'A0F25DAB', date_label: 'Domingo, 11 de octubre de 2026', total: 3269, currency: 'ARS', client_name: 'Cliente Documentos E2E',
      items: [{ name: 'Remera deportiva', quantity: '2', unit_price: 1234.5, subtotal: 2469 }, { name: 'Servicio de armado', quantity: '1', unit_price: 800, subtotal: 800 }],
      business_name: 'NOMBRE FALSO DEL CLIENTE VIEJO', business_phone: '0000000', business_email: OWNER,
    }),
  })
  if (!receipt.ok) throw new Error(`receipt ${name} ${receipt.status} ${await receipt.text()}`)
  const rfile = path.join(out, `comprobante-${name}.pdf`)
  writeFileSync(rfile, Buffer.from(await receipt.arrayBuffer()))
  console.log('ok', rfile)
}
