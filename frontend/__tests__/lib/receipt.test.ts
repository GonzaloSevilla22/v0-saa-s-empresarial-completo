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
    hasBankMovement: false, sourceQuoteId: null, sourceQuoteNumber: null, hasServiceLines: false,
    ...overrides,
  }
}

const BASE_OPTS: ReceiptOptions = { branding: defaultReceiptBranding("Mi Negocio") }

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
    const opts: ReceiptOptions = { branding: defaultReceiptBranding(`Mi Negocio <script>alert(2)</script> & "SRL"`) }

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

// ── ventas-unidades-conversion (task 6.3): la cantidad lleva la unidad de la línea ──
import { generateReceiptText, generateReceiptShortText, buildSalesReceiptPdfPayload } from "@/lib/receipt"

describe("comprobante — la cantidad lleva el símbolo de la unidad de la línea", () => {
  const unitSymbolFor = (unitId?: string) => (unitId === "u-g" ? "g" : unitId === "u-kg" ? "kg" : undefined)
  const opts: ReceiptOptions = { ...BASE_OPTS, unitSymbolFor }
  const op = makeOp({
    items: [
      makeItem({ id: "s1", productName: "Tomate", quantity: 450, unitPrice: 1, total: 450, unitId: "u-g" }),
      makeItem({ id: "s2", productName: "Zapallo", quantity: 1.25, unitPrice: 100, total: 125, unitId: "u-kg" }),
      makeItem({ id: "s3", productName: "Bolsa", quantity: 3, unitPrice: 10, total: 30 }),
    ],
    total: 605,
  })

  it("HTML: 450 g, 1.250 kg y 3 sin unidad", () => {
    const html = generateReceiptHTML(op, opts)
    expect(html).toContain('<td class="center">450 g</td>')
    expect(html).toContain('<td class="center">1.250 kg</td>')
    expect(html).toContain('<td class="center">3</td>')
  })

  it("texto para WhatsApp / portapapeles: x450 g", () => {
    const text = generateReceiptText(op, opts)
    expect(text).toContain("Tomate x450 g →")
    expect(text).toContain("Zapallo x1.250 kg →")
    expect(text).toContain("Bolsa x3 →")
  })

  it("payload del PDF: la cantidad viaja ya formateada con su unidad", () => {
    const payload = buildSalesReceiptPdfPayload(op, opts)
    expect(payload.items.map((i) => i.quantity)).toEqual(["450 g", "1.250 kg", "3"])
  })

  it("sin resolver unidades, la cantidad sale sin símbolo (nunca inventa uno)", () => {
    const html = generateReceiptHTML(op, BASE_OPTS)
    expect(html).toContain('<td class="center">450</td>')
    expect(html).not.toContain("450 g")
  })
})


// ══════════════════════════════════════════════════════════════════════════════
// documentos-marca-empresa (task 10.1) — el comprobante interno lleva la MARCA de la
// cuenta (la que resuelve el servidor y lee `GET /document-branding`), nunca el perfil, el
// avatar ni el email de acceso de quien lo imprime. Neutro por defecto: ni un píxel del
// verde anterior.
// ══════════════════════════════════════════════════════════════════════════════
import {
  DEFAULT_DOCUMENT_BRANDING,
  defaultReceiptBranding,
  toReceiptBranding,
  type DocumentBranding,
} from "@/lib/document-branding"

const PNG_URI = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

const AZUL_PALETTE = {
  key: "azul", accent: "#1d4ed8", ink: "#1e293b", muted: "#64748b", rule: "#94a3b8", surface: "#f1f5f9",
  heading: "#1d4ed8", strong_rule: "#1d4ed8", table_head_fill: "#1d4ed8", table_head_text: "#ffffff",
  total: "#1d4ed8", accepted_stamp: "#1d4ed8",
}

const FULL: DocumentBranding = {
  ...DEFAULT_DOCUMENT_BRANDING,
  is_default: false,
  issuer: {
    name: "Sumar", legal_name: "Ropa Deportiva SRL", cuit: "20-12345678-6", iva_legend: "IVA RESPONSABLE MONOTRIBUTO",
    address: "Av. San Martín 1234, Mendoza", phone: "2615550999", email: "ventas@sumar.com.ar", website: "sumar.com.ar",
  },
  footer_note: "Alias para transferencias: sumar.ropa",
  palette: AZUL_PALETTE,
}

const fullOpts = (over: Partial<ReceiptOptions> = {}, logo: string | null = PNG_URI): ReceiptOptions => ({
  branding: toReceiptBranding(FULL, logo),
  ...over,
})

describe("comprobante interno — la marca de la cuenta en el HTML", () => {
  it("imprime nombre, razón social, CUIT, IVA, domicilio, teléfono, email del negocio, web y leyenda al pie", () => {
    const html = generateReceiptHTML(makeOp(), fullOpts())
    for (const needle of [
      "Sumar", "Ropa Deportiva SRL", "CUIT: 20-12345678-6", "IVA RESPONSABLE MONOTRIBUTO",
      "Av. San Martín 1234, Mendoza", "2615550999", "ventas@sumar.com.ar", "sumar.com.ar",
      "Alias para transferencias: sumar.ropa",
    ]) {
      expect(html, needle).toContain(needle)
    }
  })

  it("la razón social sólo se imprime si difiere del nombre", () => {
    const same = { ...FULL, issuer: { ...FULL.issuer, name: "Ropa Deportiva SRL" } }
    const html = generateReceiptHTML(makeOp(), { branding: toReceiptBranding(same) })
    expect(html.match(/Ropa Deportiva SRL/g)!.length).toBe(2)   // el nombre en el <title> y en el encabezado; ninguna segunda línea
  })

  it("el logo es una imagen data: PNG/JPEG y no la URL de un avatar", () => {
    const html = generateReceiptHTML(makeOp(), fullOpts())
    expect(html).toContain(`<img class="business-logo" src="${PNG_URI}"`)
    expect(html).not.toMatch(/src="https?:/)
  })

  it.each(["https://evil.example/logo.png", "javascript:alert(1)", "data:image/svg+xml;base64,PHN2Zz4=", "data:image/png;base64,AAA\" onerror=\"x"])(
    "un logo inválido (%s) no genera <img>: se dibuja la inicial",
    (bad) => {
      const html = generateReceiptHTML(makeOp(), { branding: { ...toReceiptBranding(FULL), logoDataUri: bad } })
      expect(html).not.toContain("<img")
      expect(html).toContain('class="business-initial"')
      expect(html).not.toContain(bad)
    },
  )

  it("sin logo se dibuja la inicial del nombre", () => {
    const html = generateReceiptHTML(makeOp(), fullOpts({}, null))
    expect(html).toContain('<div class="business-initial">S</div>')
  })

  it("ya no queda ningún rastro del verde anterior", () => {
    for (const opts of [fullOpts(), { branding: defaultReceiptBranding() }]) {
      const html = generateReceiptHTML(makeOp(), opts)
      expect(html).not.toMatch(/emerald/i)
      expect(html).not.toMatch(/#059669|#10b981|rgb\(16,\s*185,\s*129\)/i)
    }
  })

  it("la paleta de la cuenta entra como variables CSS", () => {
    const html = generateReceiptHTML(makeOp(), fullOpts())
    expect(html).toContain("--heading: #1d4ed8")
    expect(html).toContain("--strong-rule: #1d4ed8")
    expect(html).toContain("--thead-bg: #1d4ed8")
    expect(html).toContain("--thead-text: #ffffff")
    expect(html).toContain("--total: #1d4ed8")
    expect(html).toContain("--ink: #1e293b")
  })

  it("Neutro: sin acento, tinta de la factura y cabecera de la tabla en la superficie clara", () => {
    const html = generateReceiptHTML(makeOp(), { branding: defaultReceiptBranding("Kiosco") })
    expect(html).toContain("--heading: #1e293b")
    expect(html).toContain("--thead-bg: #f1f5f9")
    expect(html).toContain("--thead-text: #1e293b")
    expect(html).toContain("--total: #1e293b")
  })

  it("un color inválido NO entra al HTML: cae al de Neutro", () => {
    const branding = toReceiptBranding(FULL)
    const evil = {
      ...branding,
      palette: { ...branding.palette, heading: "red", total: "#1d4ed8;background:url(javascript:alert(1))", tableHeadFill: "#ABCDEF" },
    }
    const html = generateReceiptHTML(makeOp(), { branding: evil })
    expect(html).toContain("--heading: #1e293b")
    expect(html).toContain("--total: #1e293b")
    expect(html).toContain("--thead-bg: #f1f5f9")
    expect(html).not.toContain("javascript:alert")
    expect(html).not.toContain("#ABCDEF")
  })

  it("todos los textos de la marca van escapados", () => {
    const hostile = (s: string) => `${s}<script>alert('${s}')</script>&"`
    const branding = toReceiptBranding({
      ...FULL,
      issuer: {
        name: hostile("n"), legal_name: hostile("l"), cuit: hostile("c"), iva_legend: hostile("i"), address: hostile("a"),
        phone: hostile("p"), email: hostile("e"), website: hostile("w"),
      },
      footer_note: hostile("f"),
    })
    const html = generateReceiptHTML(makeOp(), { branding })
    expect(html.match(/<script(?:\s|>)/gi)).toHaveLength(1)     // sólo el de impresión
    expect(html).toContain("&lt;script&gt;alert('n')&lt;/script&gt;")   // escapado en un nodo de texto (el apóstrofo es inofensivo ahí)
  })

  it("la web se imprime como TEXTO, nunca como enlace", () => {
    const html = generateReceiptHTML(makeOp(), fullOpts())
    expect(html).toContain("sumar.com.ar")
    expect(html).not.toMatch(/<a\s/i)
    expect(html).not.toMatch(/href=/i)
  })

  it("no imprime el email de acceso: sólo existe el del negocio", () => {
    const html = generateReceiptHTML(makeOp(), { branding: defaultReceiptBranding("Kiosco") })
    expect(html).not.toMatch(/[\w.+-]+@[\w-]+\.[\w.-]+/)          // ninguna dirección de correo (el CSS tiene @page/@media)
  })

  it("el rótulo de comprobante interno sigue ahí", () => {
    const html = generateReceiptHTML(makeOp(), fullOpts())
    expect(html).toContain("Comprobante de venta")
    expect(html).toContain("Este documento es su comprobante de venta.")
  })
})

describe("comprobante interno — textos de WhatsApp y portapapeles", () => {
  it("el texto largo lleva el contacto del negocio (teléfono, email del negocio, web)", () => {
    const text = generateReceiptText(makeOp(), fullOpts())
    expect(text).toContain("Sumar")
    expect(text).toContain("2615550999")
    expect(text).toContain("ventas@sumar.com.ar")
    expect(text).toContain("sumar.com.ar")
  })

  it("sin contacto cargado no hay bloque de contacto, y nunca un email de login", () => {
    const text = generateReceiptText(makeOp(), { branding: defaultReceiptBranding("Kiosco") })
    expect(text).not.toContain("Contacto")
    expect(text).not.toMatch(/[\w.+-]+@[\w-]+\.[\w.-]+/)
  })

  it("el mensaje corto nombra al negocio de la marca", () => {
    const text = generateReceiptShortText(makeOp(), { ...fullOpts(), clientFirstName: "Ana" })
    expect(text).toContain("*Sumar*")
  })

  it("el nombre por defecto es Mi Negocio", () => {
    expect(generateReceiptShortText(makeOp(), { branding: defaultReceiptBranding() })).toContain("*Mi Negocio*")
  })
})

describe("comprobante interno — payload del PDF del servidor", () => {
  it("ya no manda nombre, teléfono ni email del negocio: los resuelve el servidor", () => {
    const payload = buildSalesReceiptPdfPayload(makeOp(), fullOpts())
    expect(Object.keys(payload).sort()).toEqual(
      ["client_name", "currency", "date_label", "items", "receipt_number", "total"],
    )
    expect(JSON.stringify(payload)).not.toContain("Sumar")
    expect(JSON.stringify(payload)).not.toContain("ventas@sumar.com.ar")
  })
})
