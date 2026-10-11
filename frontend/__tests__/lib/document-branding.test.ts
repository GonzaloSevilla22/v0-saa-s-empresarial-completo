/**
 * documentos-marca-empresa (task 9.2) — RED→GREEN de `lib/document-branding.ts`.
 *
 * Tres contratos que el frontend NO inventa:
 *   - la cascada del emisor (`previewIssuer`): la vista previa en vivo de la pestaña
 *     "Documentos" tiene que mostrar lo que el servidor va a imprimir, así que este
 *     archivo lee el MISMO fixture que pytest
 *     (`backend/tests/fixtures/document_issuer_cascade_cases.json`);
 *   - las validaciones del formulario: espejan las del backend (largos, email, CUIT con su
 *     dígito verificador, sitio web, color, coherencia paleta/color y contraste mínimo);
 *   - lo que se interpola en el HTML imprimible: sólo `data:` PNG/JPEG validado y colores
 *     `#rrggbb` validados (anti-XSS), y la web como texto.
 */
import { describe, expect, it } from "vitest"
import fs from "node:fs"
import path from "node:path"
import {
  DEFAULT_DOCUMENT_BRANDING,
  defaultReceiptBranding,
  documentBrandingFormSchema,
  emptyBrandingForm,
  formFromSettings,
  formToPayload,
  isSafeHexColor,
  isSafeLogoDataUri,
  parseDocumentBranding,
  previewIssuer,
  toReceiptBranding,
  type BrandingForm,
  type DocumentBranding,
  type FiscalData,
  type OwnerFallback,
} from "@/lib/document-branding"
import { formatCuit } from "@/lib/cuit-utils"

// ─── cascada del emisor (fixture compartido con pytest) ──────────────────────

interface CascadeCase {
  name: string
  rpc: Record<string, string | null> | null
  expected: {
    name: string
    legal_name: string | null
    cuit: string | null
    address: string | null
    phone: string | null
    iva_legend: string | null
    email: string | null
    website: string | null
    footer_note: string | null
  }
  sources: Record<string, string>
}

const CASCADE = (
  JSON.parse(
    fs.readFileSync(
      path.resolve(__dirname, "../../../backend/tests/fixtures/document_issuer_cascade_cases.json"),
      "utf-8",
    ),
  ) as { cases: CascadeCase[] }
).cases

/** Las claves de `rpc_commercial_issuer` repartidas en las tres fuentes que ve la pestaña. */
function splitRpc(rpc: CascadeCase["rpc"]): { form: BrandingForm; fiscal: FiscalData; owner: OwnerFallback } {
  const raw = rpc ?? {}
  const text = (key: string): string => raw[key] ?? ""
  return {
    form: {
      ...emptyBrandingForm(),
      display_name: text("brand_display_name"),
      legal_name: text("brand_legal_name"),
      tax_id: text("brand_tax_id"),
      address: text("brand_address"),
      phone: text("brand_phone"),
      email: text("brand_email"),
      website: text("brand_website"),
      footer_note: text("brand_footer_note"),
    },
    fiscal: {
      razon_social: raw.razon_social ?? null,
      nombre_fantasia: raw.nombre_fantasia ?? null,
      cuit: raw.cuit ?? null,
      domicilio_comercial: raw.domicilio_comercial ?? null,
      iva_condition: raw.iva_condition ?? null,
    },
    owner: { business_name: raw.business_name ?? null, phone: raw.phone ?? null },
  }
}

describe("previewIssuer — la cascada del servidor, caso por caso", () => {
  it("el fixture tiene casos", () => {
    expect(CASCADE.length).toBeGreaterThanOrEqual(20)
  })

  it.each(CASCADE.map((c) => [c.name, c] as const))("%s", (_name, c) => {
    const { form, fiscal, owner } = splitRpc(c.rpc)
    const preview = previewIssuer(form, fiscal, owner)
    expect(preview.issuer).toEqual({
      name: c.expected.name,
      legal_name: c.expected.legal_name,
      cuit: c.expected.cuit,
      iva_legend: c.expected.iva_legend,
      address: c.expected.address,
      phone: c.expected.phone,
      email: c.expected.email,
      website: c.expected.website,
    })
    expect(preview.footer_note).toBe(c.expected.footer_note)
    expect(preview.sources).toEqual(c.sources)
  })

  it("sin perfil fiscal (null) usa la marca y el dueño", () => {
    const form = { ...emptyBrandingForm(), display_name: "Kiosco Lola", tax_id: "20111111112" }
    const preview = previewIssuer(form, null, { business_name: "Almacén", phone: "2615550101" })
    expect(preview.issuer.name).toBe("Kiosco Lola")
    expect(preview.issuer.cuit).toBe("20-11111111-2")
    expect(preview.issuer.phone).toBe("2615550101")
  })

  it("cambia en vivo con lo que se escribe (el formulario manda sobre lo guardado)", () => {
    const before = previewIssuer({ ...emptyBrandingForm(), display_name: "Uno" }, null, { business_name: null, phone: null })
    const after = previewIssuer({ ...emptyBrandingForm(), display_name: "Dos" }, null, { business_name: null, phone: null })
    expect([before.issuer.name, after.issuer.name]).toEqual(["Uno", "Dos"])
  })
})

// ─── formulario (zod) ─────────────────────────────────────────────────────────

const valid = (over: Partial<BrandingForm> = {}): BrandingForm => ({ ...emptyBrandingForm(), ...over })
const errorsOf = (form: BrandingForm): string[] => {
  const result = documentBrandingFormSchema.safeParse(form)
  return result.success ? [] : result.error.issues.map((i) => String(i.path[0]))
}

describe("documentBrandingFormSchema", () => {
  it("un formulario vacío es válido (todo opcional, Neutro)", () => {
    expect(documentBrandingFormSchema.safeParse(emptyBrandingForm()).success).toBe(true)
  })

  it("una marca completa es válida", () => {
    const form = valid({
      display_name: "Sumar", legal_name: "Ropa Deportiva SRL", tax_id: "20-12345678-6", address: "Av. San Martín 1234",
      phone: "2615550999", email: "ventas@sumar.com.ar", website: "sumar.com.ar", footer_note: "Alias: sumar.ropa",
      palette_preset: "personalizado", accent_color: "#7c2d12",
    })
    expect(documentBrandingFormSchema.safeParse(form).success).toBe(true)
  })

  it.each([
    ["display_name", "x".repeat(81)],
    ["legal_name", "x".repeat(121)],
    ["address", "x".repeat(201)],
    ["phone", "1".repeat(41)],
    ["footer_note", "x".repeat(281)],
    ["email", "no-es-un-email"],
    ["email", "a b@c.com"],
    ["email", "a@b"],
    ["tax_id", "20-12345678-7"],
    ["tax_id", "123"],
    ["website", "sumar com.ar"],
    ["website", "sumar<script>"],
    ["website", "x".repeat(121)],
  ] as const)("rechaza %s = %j", (field, value) => {
    expect(errorsOf(valid({ [field]: value }))).toContain(field)
  })

  it("acepta los límites exactos", () => {
    const form = valid({
      display_name: "x".repeat(80), legal_name: "x".repeat(120), address: "x".repeat(200), phone: "1".repeat(40),
      footer_note: "x".repeat(280), website: "x".repeat(120),
    })
    expect(documentBrandingFormSchema.safeParse(form).success).toBe(true)
  })

  it("acepta el CUIT con o sin guiones", () => {
    expect(errorsOf(valid({ tax_id: "20123456786" }))).toEqual([])
    expect(errorsOf(valid({ tax_id: "20-12345678-6" }))).toEqual([])
  })

  it("los espacios sobrantes no cuentan como largo ni como dato", () => {
    expect(errorsOf(valid({ display_name: "   " + "x".repeat(80) + "   " }))).toEqual([])
    expect(errorsOf(valid({ email: "   " }))).toEqual([])
  })

  describe("paleta y color", () => {
    it("la paleta personalizada exige un color", () => {
      expect(errorsOf(valid({ palette_preset: "personalizado", accent_color: "" }))).toContain("accent_color")
    })

    it("un color con una paleta del catálogo es incoherente", () => {
      expect(errorsOf(valid({ palette_preset: "azul", accent_color: "#112233" }))).toContain("accent_color")
    })

    it.each(["abc", "#abc", "#12345g", "azul", "#1234567"])("rechaza el color %j", (color) => {
      expect(errorsOf(valid({ palette_preset: "personalizado", accent_color: color }))).toContain("accent_color")
    })

    it.each(["#10b981", "#facc15", "#ffffff", "#a96081"])("rechaza %s por contraste (< 4,5:1)", (color) => {
      const result = documentBrandingFormSchema.safeParse(valid({ palette_preset: "personalizado", accent_color: color }))
      expect(result.success).toBe(false)
      expect(JSON.stringify(result)).toContain("no se lee bien sobre blanco")
    })

    it.each(["#7c2d12", "#a76180", "#000000", "#047857"])("acepta %s", (color) => {
      expect(errorsOf(valid({ palette_preset: "personalizado", accent_color: color }))).toEqual([])
    })

    it("acepta el color en mayúsculas (el servidor lo guarda en minúsculas)", () => {
      expect(errorsOf(valid({ palette_preset: "personalizado", accent_color: "#7C2D12" }))).toEqual([])
    })

    it("un preset fuera del catálogo se rechaza", () => {
      expect(errorsOf({ ...emptyBrandingForm(), palette_preset: "rosa" as never })).toContain("palette_preset")
    })
  })
})

describe("formToPayload / formFromSettings", () => {
  it("los vacíos viajan como null y los textos recortados", () => {
    const payload = formToPayload(valid({ display_name: "  Sumar  ", phone: "   ", website: "" }))
    expect(payload.display_name).toBe("Sumar")
    expect(payload.phone).toBeNull()
    expect(payload.website).toBeNull()
    expect(payload.palette_preset).toBe("neutro")
    expect(payload.accent_color).toBeNull()
  })

  it("el CUIT viaja con guiones y el color en minúsculas", () => {
    const payload = formToPayload(valid({ tax_id: "20123456786", palette_preset: "personalizado", accent_color: "#7C2D12" }))
    expect(payload.tax_id).toBe("20-12345678-6")
    expect(payload.accent_color).toBe("#7c2d12")
  })

  it("el color se descarta con una paleta del catálogo", () => {
    expect(formToPayload(valid({ palette_preset: "azul", accent_color: "#112233" })).accent_color).toBeNull()
  })

  it("el formulario se arma de lo guardado (null → texto vacío) y vuelve igual", () => {
    const saved = { ...DEFAULT_DOCUMENT_BRANDING.settings, display_name: "Sumar", palette_preset: "bordo" as const }
    const form = formFromSettings(saved)
    expect(form.display_name).toBe("Sumar")
    expect(form.phone).toBe("")
    expect(form.palette_preset).toBe("bordo")
    expect(formToPayload(form)).toEqual(saved)
  })
})

// ─── anti-XSS del HTML imprimible ─────────────────────────────────────────────

describe("isSafeLogoDataUri", () => {
  const b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  it.each([`data:image/png;base64,${b64}`, "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBD"])("acepta %.40s…", (uri) => {
    expect(isSafeLogoDataUri(uri)).toBe(true)
  })

  it.each([
    "https://evil.example/logo.png",
    "http://x/y.png",
    "javascript:alert(1)",
    "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=",
    "data:image/gif;base64,R0lGODlhAQABAAAAACw=",
    "data:text/html;base64,PHNjcmlwdD4=",
    "data:image/png;base64,AAA\" onerror=\"alert(1)",
    "data:image/png;base64,AAA<script>",
    "data:image/png,rawdata",
    "",
    "   data:image/png;base64,AAAA",
  ])("rechaza %j", (uri) => {
    expect(isSafeLogoDataUri(uri)).toBe(false)
  })

  it("rechaza un logo que supera el tope razonable de 300 KB en base64", () => {
    expect(isSafeLogoDataUri("data:image/png;base64," + "A".repeat(500_000))).toBe(false)
  })

  it("no es vulnerable a backtracking con una cadena larga y casi válida", () => {
    const started = performance.now()
    isSafeLogoDataUri("data:image/png;base64," + "A".repeat(400_000) + "!")
    expect(performance.now() - started).toBeLessThan(500)
  })
})

describe("isSafeHexColor", () => {
  it.each(["#000000", "#1d4ed8", "#ffffff", "#7c2d12"])("acepta %s", (c) => expect(isSafeHexColor(c)).toBe(true))
  it.each(["", "#abc", "#ABCDEF", "red", "#12345g", "#1234567", "javascript:1", "#1d4ed8;background:url(x)", "#1d4ed8\""])(
    "rechaza %j",
    (c) => expect(isSafeHexColor(c)).toBe(false),
  )
})

// ─── toReceiptBranding ────────────────────────────────────────────────────────

const AZUL = {
  key: "azul", accent: "#1d4ed8", ink: "#1e293b", muted: "#64748b", rule: "#94a3b8", surface: "#f1f5f9",
  heading: "#1d4ed8", strong_rule: "#1d4ed8", table_head_fill: "#1d4ed8", table_head_text: "#ffffff",
  total: "#1d4ed8", accepted_stamp: "#1d4ed8",
}

const branding = (over: Partial<DocumentBranding> = {}): DocumentBranding => ({
  ...DEFAULT_DOCUMENT_BRANDING,
  issuer: { name: "Sumar", legal_name: "Ropa SRL", cuit: "20-12345678-6", iva_legend: "IVA RESPONSABLE MONOTRIBUTO",
            address: "Calle 1", phone: "2615550999", email: "ventas@sumar.com.ar", website: "sumar.com.ar" },
  footer_note: "Alias: sumar.ropa",
  palette: AZUL,
  ...over,
})

describe("toReceiptBranding", () => {
  const png = "data:image/png;base64,iVBORw0KGgo="

  it("arma el emisor, la leyenda y la paleta del servidor", () => {
    const receipt = toReceiptBranding(branding(), png)
    expect(receipt.issuer).toEqual({
      name: "Sumar", legalName: "Ropa SRL", cuit: "20-12345678-6", ivaLegend: "IVA RESPONSABLE MONOTRIBUTO",
      address: "Calle 1", phone: "2615550999", email: "ventas@sumar.com.ar", website: "sumar.com.ar",
    })
    expect(receipt.footerNote).toBe("Alias: sumar.ropa")
    expect(receipt.palette.heading).toBe("#1d4ed8")
    expect(receipt.palette.tableHeadText).toBe("#ffffff")
    expect(receipt.logoDataUri).toBe(png)
  })

  it("omite un logo que no es un data: PNG/JPEG válido", () => {
    expect(toReceiptBranding(branding(), "https://evil.example/x.png").logoDataUri).toBeUndefined()
    expect(toReceiptBranding(branding(), "data:image/svg+xml;base64,PHN2Zz4=").logoDataUri).toBeUndefined()
    expect(toReceiptBranding(branding(), undefined).logoDataUri).toBeUndefined()
  })

  it("un color inválido cae al de Neutro (campo por campo)", () => {
    const evil = { ...AZUL, heading: "red", total: "#1d4ed8;background:url(x)", table_head_fill: "#ABCDEF", accent: "javascript:1" }
    const receipt = toReceiptBranding(branding({ palette: evil }), undefined)
    expect(receipt.palette.heading).toBe("#1e293b")
    expect(receipt.palette.total).toBe("#1e293b")
    expect(receipt.palette.tableHeadFill).toBe("#f1f5f9")
    expect(receipt.palette.accent).toBeNull()
    expect(receipt.palette.ink).toBe("#1e293b")
  })

  it("por defecto es Neutro y no tiene verde", () => {
    const receipt = toReceiptBranding(DEFAULT_DOCUMENT_BRANDING, undefined)
    expect(receipt.palette.accent).toBeNull()
    expect(Object.values(receipt.palette).join(" ")).not.toMatch(/#10b981|#059669/i)
    expect(receipt.issuer.name).toBe("Mi Negocio")
  })
})

// ─── parseDocumentBranding ────────────────────────────────────────────────────

describe("parseDocumentBranding", () => {
  it("una respuesta inválida o vacía cae a los valores por defecto sin romper", () => {
    expect(parseDocumentBranding(null)).toEqual(DEFAULT_DOCUMENT_BRANDING)
    expect(parseDocumentBranding({ nada: true })).toEqual(DEFAULT_DOCUMENT_BRANDING)
    expect(parseDocumentBranding("html")).toEqual(DEFAULT_DOCUMENT_BRANDING)
  })

  it("una respuesta válida se respeta", () => {
    const parsed = parseDocumentBranding(branding({ is_default: false }))
    expect(parsed.is_default).toBe(false)
    expect(parsed.issuer.name).toBe("Sumar")
    expect(parsed.palette.key).toBe("azul")
  })
})

describe("formatCuit", () => {
  it.each([["20123456786", "20-12345678-6"], ["20-12345678-6", "20-12345678-6"], ["123", "123"], ["", ""]])(
    "%j → %j",
    (input, out) => expect(formatCuit(input)).toBe(out),
  )
})

describe("defaultReceiptBranding", () => {
  it("es Neutro, sin logo, sin contacto y con el nombre dado", () => {
    const branding = defaultReceiptBranding("Kiosco Lola")
    expect(branding.issuer).toMatchObject({ name: "Kiosco Lola", phone: null, email: null, website: null, cuit: null })
    expect(branding.palette.accent).toBeNull()
    expect(branding.logoDataUri).toBeUndefined()
    expect(branding.footerNote).toBeNull()
  })

  it("sin nombre (o en blanco) usa Mi Negocio", () => {
    expect(defaultReceiptBranding().issuer.name).toBe("Mi Negocio")
    expect(defaultReceiptBranding("   ").issuer.name).toBe("Mi Negocio")
  })
})
