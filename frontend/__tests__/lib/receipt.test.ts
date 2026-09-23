/**
 * fix/comprobante-print-csp-nonce.
 *
 * "Ventas → Comprobante → Descargar / Imprimir" abre el HTML generado acá en
 * una pestaña `blob:`. Ese documento HEREDA la CSP del documento que creó la
 * URL (`lib/supabase/middleware.ts`: `script-src` sin `'unsafe-inline'` en
 * producción), así que el `<script>` inline que dispara `window.print()` queda
 * bloqueado sin el nonce de esa política — el bug reportado por el PO
 * ("me abre otra pestaña pero no empieza a descargar").
 *
 * El arreglo: `generateReceiptHTML` acepta `opts.scriptNonce` opcional. Si
 * viene y tiene forma de nonce válido, el `<script>` sale con `nonce="…"`; si
 * no viene, o no matchea el alfabeto, sale sin el atributo (nunca se
 * interpola un valor no validado — HTML injection si alguien pudiera
 * controlar el nonce). El documento también gana un botón visible como red de
 * seguridad si algún navegador igual bloquea la ejecución automática.
 */
import { describe, it, expect } from "vitest"
import { generateReceiptHTML, type ReceiptOptions } from "@/lib/receipt"
import type { SaleOperation } from "@/lib/group-operations"
import type { Sale } from "@/lib/types"

function makeItem(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "s1",
    date: "2026-09-18",
    productId: "p1",
    productName: "Producto A",
    clientId: "c1",
    clientName: "Consumidor Final",
    quantity: 2,
    unitPrice: 100,
    total: 200,
    currency: "ARS",
    ...overrides,
  }
}

function makeOp(overrides: Partial<SaleOperation> = {}): SaleOperation {
  return {
    key: "op1",
    operationId: "op1",
    date: "2026-09-18",
    clientId: "c1",
    clientName: "Consumidor Final",
    currency: "ARS",
    items: [makeItem()],
    total: 200,
    isGrouped: false,
    paymentMethodId: null,
    branchId: null,
    canal: null,
    unitId: null,
    isFiscallyLocked: false,
    fiscal: null,
    isPaymentLocked: false,
    hasAccountCharge: false,
    hasCashMovement: false,
    hasBankMovement: false,
    ...overrides,
  }
}

const BASE_OPTS: ReceiptOptions = { businessName: "Mi Negocio" }

/** El único bloque <script> del comprobante — el de impresión. */
function printScriptTagOpen(html: string): string {
  const match = html.match(/<script[^>]*>/)
  if (!match) throw new Error("no se encontró ningún <script> en el HTML generado")
  return match[0]
}

describe("generateReceiptHTML — nonce del <script> de impresión", () => {
  it("con un nonce válido, el <script> lo lleva", () => {
    const html = generateReceiptHTML(makeOp(), { ...BASE_OPTS, scriptNonce: "AbC123+/=" })

    expect(printScriptTagOpen(html)).toBe('<script nonce="AbC123+/=">')
  })

  it("con OTRO nonce válido, lleva ESE (no uno fijo)", () => {
    const html = generateReceiptHTML(makeOp(), { ...BASE_OPTS, scriptNonce: "z9Y8x7W6-_" })

    expect(printScriptTagOpen(html)).toBe('<script nonce="z9Y8x7W6-_">')
  })

  it("sin nonce, el <script> no lleva el atributo", () => {
    const html = generateReceiptHTML(makeOp(), BASE_OPTS)

    expect(printScriptTagOpen(html)).toBe("<script>")
  })

  it("con un nonce fuera del alfabeto (comillas), se OMITE — nunca se interpola crudo", () => {
    const malicious = '"><script>alert(1)</script>'
    const html = generateReceiptHTML(makeOp(), { ...BASE_OPTS, scriptNonce: malicious })

    // El único <script> del documento sigue siendo el de impresión, sin nonce.
    expect(printScriptTagOpen(html)).toBe("<script>")
    // Y el valor rechazado no aparece en NINGÚN lado del documento.
    expect(html).not.toContain(malicious)
    expect(html.match(/<script/gi)).toHaveLength(1)
  })

  it("con un nonce fuera del alfabeto (espacio + '>'), también se OMITE", () => {
    const html = generateReceiptHTML(makeOp(), { ...BASE_OPTS, scriptNonce: "abc def>" })

    expect(printScriptTagOpen(html)).toBe("<script>")
  })
})

describe("generateReceiptHTML — botón de impresión visible", () => {
  it("el documento trae un botón visible para imprimir/descargar", () => {
    const html = generateReceiptHTML(makeOp(), BASE_OPTS)

    expect(html).toMatch(/<button[^>]*>[^<]*(Imprimir|Descargar)[^<]*<\/button>/i)
  })

  it("el botón está en un contenedor con la clase que @media print oculta", () => {
    const html = generateReceiptHTML(makeOp(), BASE_OPTS)

    // Extraído del bloque @media print (no un regex greedy sobre todo el
    // documento — revisión adversarial MINOR 3: una regla `.no-print` fuera
    // del bloque, después de su apertura, pasaba igual con el regex viejo).
    const mediaPrintMatch = html.match(/@media print\s*\{([\s\S]*?)\n\s*\}\s*\n/)
    expect(mediaPrintMatch).not.toBeNull()
    expect(mediaPrintMatch![1]).toMatch(/\.no-print\s*\{[^}]*display:\s*none/)

    const noPrintBlock = html.match(/<div class="no-print"[^>]*>[\s\S]*?<\/div>/)
    expect(noPrintBlock).not.toBeNull()
    expect(noPrintBlock![0]).toMatch(/<button/i)
  })

  it("trae una pista de texto fijo (sin depender del script) para el caso en que el diálogo no se abre solo", () => {
    // Revisión adversarial MINOR 2: el botón vive dentro del mismo <script>
    // con nonce que puede fallar (nonce vacío, navegador sin IDL .nonce,
    // etc.) — justo el modo de falla que motiva este fix. Un texto fijo, sin
    // script, cubre ese caso.
    const html = generateReceiptHTML(makeOp(), BASE_OPTS)
    const noPrintBlock = html.match(/<div class="no-print"[^>]*>[\s\S]*?<\/div>\s*<\/div>/)

    expect(noPrintBlock).not.toBeNull()
    expect(noPrintBlock![0]).toMatch(/Ctrl\+P/i)
  })
})

describe("generateReceiptHTML — sin manejadores inline (CSP-safe)", () => {
  it("no existe ningún atributo on*= en todo el HTML", () => {
    const html = generateReceiptHTML(makeOp(), { ...BASE_OPTS, scriptNonce: "AbC123" })

    expect(html).not.toMatch(/\son[a-z]+\s*=/i)
  })

  it("el script conserva la impresión automática y cablea el botón por addEventListener", () => {
    const html = generateReceiptHTML(makeOp(), BASE_OPTS)
    const script = html.match(/<script[^>]*>([\s\S]*?)<\/script>/)
    expect(script).not.toBeNull()
    const body = script![1]

    // Auto-impresión al cargar (comportamiento previo, conservado).
    expect(body).toMatch(/window\.print\s*\(\s*\)/)
    // Cableado del botón SIN atributo on*= (addEventListener, no onclick=).
    expect(body).toMatch(/addEventListener\(\s*["']click["']/)
    // Y el botón click también dispara print (2 llamadas: onload + click).
    expect(body.match(/window\.print\s*\(\s*\)/g)!.length).toBeGreaterThanOrEqual(2)
  })
})

describe("generateReceiptHTML — escapado de datos del usuario (no regresión)", () => {
  it("business name, cliente y producto con HTML/comillas siguen escapados", () => {
    const op = makeOp({
      clientName: `<img src=x onerror=alert(1)> & "Cliente"`,
      items: [makeItem({ productName: `<b>Producto</b> & "especial"` })],
    })
    const opts: ReceiptOptions = { businessName: `Mi Negocio <script>alert(2)</script> & "SRL"` }

    const html = generateReceiptHTML(op, opts)

    expect(html).not.toContain("<img src=x onerror=alert(1)>")
    expect(html).not.toContain("<b>Producto</b>")
    expect(html).not.toContain("<script>alert(2)</script>")
    expect(html).toContain("&lt;img src=x onerror=alert(1)&gt;")
    expect(html).toContain("&lt;b&gt;Producto&lt;/b&gt;")
    expect(html).toContain("&lt;script&gt;alert(2)&lt;/script&gt;")
    expect(html).toContain("&quot;Cliente&quot;")
    expect(html).toContain("&quot;especial&quot;")
    expect(html).toContain("&quot;SRL&quot;")
    // El único <script> real del documento sigue siendo el de impresión.
    expect(html.match(/<script(?:\s|>)/gi)).toHaveLength(1)
  })
})
