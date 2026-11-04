import { readFileSync, writeFileSync } from 'node:fs'
import { login, USERS, be } from './lib.mjs'
const { id } = JSON.parse(readFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/dn-a.json', 'utf8'))
const tok = await login(...USERS.owner)
const r = await fetch(`http://127.0.0.1:8000/delivery-notes/${id}/pdf?disposition=attachment`, { headers: { Authorization: `Bearer ${tok}` } })
writeFileSync('C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf/remito-ui-unidades.pdf', Buffer.from(await r.arrayBuffer()))
