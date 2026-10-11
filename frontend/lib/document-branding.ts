/**
 * lib/document-branding.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * documentos-marca-empresa (D8/D10) — tipos del contrato `/document-branding`, el
 * formulario de la pestaña "Documentos", la vista previa del emisor y lo que se
 * interpola en el comprobante interno (HTML y textos).
 *
 * Pura — sin React, sin fetch. Lo que NO se inventa acá:
 *   - la cascada del emisor (`previewIssuer`) REFLEJA la del servidor
 *     (`backend/services/commercial_documents/issuer.py`); se ata a ella con el
 *     fixture compartido `backend/tests/fixtures/document_issuer_cascade_cases.json`;
 *   - el catálogo de paletas y su resolución los trae el servidor (`palette`,
 *     `palettes`): el frontend nunca copia los colores de un preset;
 *   - el contraste del color personalizado se avisa acá (`lib/color-contrast.ts`) pero el
 *     que RECHAZA es el servidor.
 *
 * Seguridad del HTML imprimible (D8): el logo sólo se interpola como `data:` PNG/JPEG
 * validado y los colores sólo como `#rrggbb` validado; los textos pasan por `esc()` en
 * `lib/receipt.ts` y la web se imprime como TEXTO, nunca como enlace.
 */

import { z } from "zod"
import { displayContrast, hexToRgb, contrastRatio, MIN_ACCENT_CONTRAST, WHITE } from "@/lib/color-contrast"
import { formatCuit, isValidCuit } from "@/lib/cuit-utils"

// ─── Contrato de la API ──────────────────────────────────────────────────────

export type PaletteKey = "neutro" | "azul" | "verde" | "grafito" | "bordo" | "personalizado"

export const PALETTE_KEYS: readonly PaletteKey[] = ["neutro", "azul", "verde", "grafito", "bordo", "personalizado"]

export interface BrandingSettings {
  display_name: string | null
  legal_name: string | null
  tax_id: string | null
  address: string | null
  phone: string | null
  email: string | null
  website: string | null
  footer_note: string | null
  palette_preset: PaletteKey
  accent_color: string | null
}

export interface LogoDescriptor {
  sha256: string
  mime: string
  width: number
  height: number
}

/** El emisor tal como lo imprimen los papeles (cascada única del servidor). */
export interface PrintedIssuer {
  name: string
  legal_name: string | null
  cuit: string | null
  iva_legend: string | null
  address: string | null
  phone: string | null
  email: string | null
  website: string | null
}

/** Lo que viene del perfil fiscal (AFIP): se muestra de sólo lectura. */
export interface FiscalData {
  razon_social: string | null
  nombre_fantasia: string | null
  cuit: string | null
  domicilio_comercial: string | null
  iva_condition: string | null
}

/** El respaldo del perfil del dueño (nombre del negocio y teléfono). */
export interface OwnerFallback {
  business_name: string | null
  phone: string | null
}

export interface ResolvedPalette {
  key: string
  accent: string | null
  ink: string
  muted: string
  rule: string
  surface: string
  heading: string
  strong_rule: string
  table_head_fill: string
  table_head_text: string
  total: string
  accepted_stamp: string
}

export interface PaletteChoice {
  key: PaletteKey
  label: string
  accent: string | null
}

/** De dónde salió cada dato impreso. */
export type DataSource = "brand" | "fiscal" | "owner" | "default"

export interface DocumentBranding {
  settings: BrandingSettings
  /** True cuando la cuenta nunca guardó su marca (Neutro, sin logo). */
  is_default: boolean
  logo: LogoDescriptor | null
  issuer: PrintedIssuer
  sources: Record<string, string>
  fiscal: FiscalData | null
  owner_fallback: OwnerFallback
  footer_note: string | null
  palette: ResolvedPalette
  palettes: PaletteChoice[]
  updated_at: string | null
  updated_by: string | null
}

/** Lo que viaja en `PUT /document-branding` (los diez campos de datos y paleta). */
export type BrandingPayload = BrandingSettings

// ─── Valores por defecto (respuesta inválida o cuenta sin marca) ─────────────

/** Neutro: "blanco", la tinta de la Factura C. Mismos hex que `palette.py::NEUTRAL`. */
export const NEUTRAL_PALETTE: ResolvedPalette = {
  key: "neutro",
  accent: null,
  ink: "#1e293b",
  muted: "#64748b",
  rule: "#94a3b8",
  surface: "#f1f5f9",
  heading: "#1e293b",
  strong_rule: "#1e293b",
  table_head_fill: "#f1f5f9",
  table_head_text: "#1e293b",
  total: "#1e293b",
  accepted_stamp: "#1e293b",
}

const DEFAULT_PALETTES: PaletteChoice[] = [
  { key: "neutro", label: "Neutro (blanco)", accent: null },
  { key: "azul", label: "Azul", accent: "#1d4ed8" },
  { key: "verde", label: "Verde", accent: "#047857" },
  { key: "grafito", label: "Grafito", accent: "#334155" },
  { key: "bordo", label: "Bordó", accent: "#9f1239" },
  { key: "personalizado", label: "Personalizado", accent: null },
]

export const DEFAULT_ISSUER_NAME = "Mi Negocio"

export const DEFAULT_DOCUMENT_BRANDING: DocumentBranding = {
  settings: {
    display_name: null, legal_name: null, tax_id: null, address: null, phone: null, email: null,
    website: null, footer_note: null, palette_preset: "neutro", accent_color: null,
  },
  is_default: true,
  logo: null,
  issuer: {
    name: DEFAULT_ISSUER_NAME, legal_name: null, cuit: null, iva_legend: null, address: null, phone: null,
    email: null, website: null,
  },
  sources: {},
  fiscal: null,
  owner_fallback: { business_name: null, phone: null },
  footer_note: null,
  palette: NEUTRAL_PALETTE,
  palettes: DEFAULT_PALETTES,
  updated_at: null,
  updated_by: null,
}

// ─── Parseo de la respuesta ──────────────────────────────────────────────────

const nullableText = z.string().nullable()
const hexOrNull = z.string().nullable()

const settingsSchema = z.object({
  display_name: nullableText, legal_name: nullableText, tax_id: nullableText, address: nullableText,
  phone: nullableText, email: nullableText, website: nullableText, footer_note: nullableText,
  palette_preset: z.enum(["neutro", "azul", "verde", "grafito", "bordo", "personalizado"]),
  accent_color: hexOrNull,
})

const documentBrandingSchema = z.object({
  settings: settingsSchema,
  is_default: z.boolean(),
  logo: z.object({ sha256: z.string(), mime: z.string(), width: z.number(), height: z.number() }).nullable().optional(),
  issuer: z.object({
    name: z.string(), legal_name: nullableText, cuit: nullableText, iva_legend: nullableText, address: nullableText,
    phone: nullableText, email: nullableText, website: nullableText,
  }),
  sources: z.record(z.string(), z.string()),
  fiscal: z.object({
    razon_social: nullableText, nombre_fantasia: nullableText, cuit: nullableText, domicilio_comercial: nullableText,
    iva_condition: nullableText,
  }).nullable().optional(),
  owner_fallback: z.object({ business_name: nullableText, phone: nullableText }),
  footer_note: nullableText.optional(),
  palette: z.object({
    key: z.string(), accent: hexOrNull, ink: z.string(), muted: z.string(), rule: z.string(), surface: z.string(),
    heading: z.string(), strong_rule: z.string(), table_head_fill: z.string(), table_head_text: z.string(),
    total: z.string(), accepted_stamp: z.string(),
  }),
  palettes: z.array(z.object({
    key: z.enum(["neutro", "azul", "verde", "grafito", "bordo", "personalizado"]), label: z.string(), accent: hexOrNull,
  })),
  updated_at: z.string().nullable().optional(),
  updated_by: z.string().nullable().optional(),
})

/**
 * La respuesta de `GET /document-branding` o los valores por defecto si es inválida
 * (una base sin la migración, un backend viejo, una respuesta de error): la pantalla y
 * los papeles NUNCA se rompen por esto, salen con Neutro y sin logo.
 */
export function parseDocumentBranding(raw: unknown): DocumentBranding {
  const parsed = documentBrandingSchema.safeParse(raw)
  if (!parsed.success) return DEFAULT_DOCUMENT_BRANDING
  const data = parsed.data
  return {
    ...data,
    logo: data.logo ?? null,
    fiscal: data.fiscal ?? null,
    footer_note: data.footer_note ?? null,
    updated_at: data.updated_at ?? null,
    updated_by: data.updated_by ?? null,
  }
}

// ─── Formulario ──────────────────────────────────────────────────────────────

export interface BrandingForm {
  display_name: string
  legal_name: string
  tax_id: string
  address: string
  phone: string
  email: string
  website: string
  footer_note: string
  palette_preset: PaletteKey
  accent_color: string
}

export function emptyBrandingForm(): BrandingForm {
  return {
    display_name: "", legal_name: "", tax_id: "", address: "", phone: "", email: "", website: "",
    footer_note: "", palette_preset: "neutro", accent_color: "",
  }
}

export function formFromSettings(settings: BrandingSettings): BrandingForm {
  return {
    display_name: settings.display_name ?? "",
    legal_name: settings.legal_name ?? "",
    tax_id: settings.tax_id ?? "",
    address: settings.address ?? "",
    phone: settings.phone ?? "",
    email: settings.email ?? "",
    website: settings.website ?? "",
    footer_note: settings.footer_note ?? "",
    palette_preset: settings.palette_preset,
    accent_color: settings.accent_color ?? "",
  }
}

const EMAIL = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/
const WEBSITE_FORBIDDEN = /[\s<>"]/
const HEX_ANY_CASE = /^#[0-9a-f]{6}$/i

/** "2,54:1" — el contraste como se le muestra a la persona (2 decimales, coma). */
export function formatContrast(ratio: number): string {
  return `${displayContrast(ratio).toFixed(2).replace(".", ",")}:1`
}

const maxLength = (max: number, label: string) =>
  z.string().refine((value) => value.trim().length <= max, { message: `${label}: hasta ${max} caracteres.` })

export const documentBrandingFormSchema = z
  .object({
    display_name: maxLength(80, "El nombre comercial"),
    legal_name: maxLength(120, "La razón social"),
    tax_id: z
      .string()
      .refine((value) => value.trim() === "" || isValidCuit(formatCuit(value.trim())), {
        message: "El CUIT no es válido (formato 20-12345678-6 con su dígito verificador).",
      }),
    address: maxLength(200, "El domicilio"),
    phone: maxLength(40, "El teléfono"),
    email: maxLength(120, "El email").refine((value) => value.trim() === "" || EMAIL.test(value.trim()), {
      message: "El email del negocio no tiene forma de dirección de correo.",
    }),
    website: maxLength(120, "El sitio web").refine((value) => !WEBSITE_FORBIDDEN.test(value.trim()), {
      message: "El sitio web no puede tener espacios ni caracteres como < > \".",
    }),
    footer_note: maxLength(280, "La leyenda al pie"),
    palette_preset: z.enum(["neutro", "azul", "verde", "grafito", "bordo", "personalizado"]),
    accent_color: z.string(),
  })
  .superRefine((form, ctx) => {
    const color = form.accent_color.trim()
    if (form.palette_preset !== "personalizado") {
      if (color !== "") {
        ctx.addIssue({ code: "custom", path: ["accent_color"], message: "Sólo la paleta personalizada lleva un color propio." })
      }
      return
    }
    if (!HEX_ANY_CASE.test(color)) {
      ctx.addIssue({ code: "custom", path: ["accent_color"], message: "El color tiene que ser #rrggbb." })
      return
    }
    const ratio = contrastRatio(hexToRgb(color)!, WHITE)
    if (ratio < MIN_ACCENT_CONTRAST) {
      ctx.addIssue({
        code: "custom",
        path: ["accent_color"],
        message: `El color no se lee bien sobre blanco (${formatContrast(ratio)}; hace falta 4,5:1).`,
      })
    }
  })

function textOrNull(value: string): string | null {
  const trimmed = value.trim()
  return trimmed === "" ? null : trimmed
}

/** El cuerpo del `PUT`: vacíos como `null`, CUIT con guiones, color en minúsculas y sin color
 *  fuera de la paleta personalizada. */
export function formToPayload(form: BrandingForm): BrandingPayload {
  const taxId = textOrNull(form.tax_id)
  const custom = form.palette_preset === "personalizado"
  return {
    display_name: textOrNull(form.display_name),
    legal_name: textOrNull(form.legal_name),
    tax_id: taxId === null ? null : formatCuit(taxId),
    address: textOrNull(form.address),
    phone: textOrNull(form.phone),
    email: textOrNull(form.email),
    website: textOrNull(form.website),
    footer_note: textOrNull(form.footer_note),
    palette_preset: form.palette_preset,
    accent_color: custom ? (textOrNull(form.accent_color)?.toLowerCase() ?? null) : null,
  }
}

// ─── Vista previa del emisor (refleja la cascada del servidor) ───────────────

const ISSUER_IVA_LEGEND: Record<string, string> = {
  monotributista: "IVA RESPONSABLE MONOTRIBUTO",
  exento: "IVA EXENTO",
  responsable_inscripto: "IVA RESPONSABLE INSCRIPTO",
}

export interface IssuerPreview {
  issuer: PrintedIssuer
  footer_note: string | null
  sources: Record<string, DataSource>
}

function clean(value: string | null | undefined): string | null {
  if (value === null || value === undefined) return null
  const trimmed = value.trim()
  return trimmed === "" ? null : trimmed
}

function firstOf(...candidates: Array<[string | null, DataSource]>): [string | null, DataSource] {
  for (const [value, source] of candidates) if (value !== null) return [value, source]
  return [null, "default"]
}

/**
 * El emisor que imprimirían los papeles con lo que hay en el formulario (`form`, aunque
 * todavía no se haya guardado), el perfil fiscal y el respaldo del dueño. Misma cascada
 * que el servidor: el perfil fiscal manda en la identidad fiscal; la marca, en el nombre
 * comercial y el contacto; el dueño es el respaldo del nombre y el teléfono; el email sale
 * SÓLO de la marca.
 */
export function previewIssuer(
  form: BrandingForm,
  fiscal: FiscalData | null,
  owner: OwnerFallback,
): IssuerPreview {
  const brandName = clean(form.display_name)
  const fantasy = clean(fiscal?.nombre_fantasia)
  const fiscalLegal = clean(fiscal?.razon_social)
  const brandLegal = clean(form.legal_name)
  const ownerName = clean(owner.business_name)

  const [name, nameSource] = firstOf(
    [brandName, "brand"], [fantasy, "fiscal"], [fiscalLegal, "fiscal"], [brandLegal, "brand"], [ownerName, "owner"],
  )
  const [legalName, legalSource] = firstOf([fiscalLegal, "fiscal"], [brandLegal, "brand"])
  const [cuitRaw, cuitSource] = firstOf([clean(fiscal?.cuit), "fiscal"], [clean(form.tax_id), "brand"])
  const [address, addressSource] = firstOf([clean(fiscal?.domicilio_comercial), "fiscal"], [clean(form.address), "brand"])
  const [phone, phoneSource] = firstOf([clean(form.phone), "brand"], [clean(owner.phone), "owner"])
  const ivaLegend = ISSUER_IVA_LEGEND[clean(fiscal?.iva_condition) ?? ""] ?? null
  const email = clean(form.email)
  const website = clean(form.website)
  const footer = clean(form.footer_note)

  return {
    issuer: {
      name: name ?? DEFAULT_ISSUER_NAME,
      legal_name: legalName,
      cuit: cuitRaw ? formatCuit(cuitRaw) : null,
      iva_legend: ivaLegend,
      address,
      phone,
      email,
      website,
    },
    footer_note: footer,
    sources: {
      name: name ? nameSource : "default",
      legal_name: legalSource,
      cuit: cuitSource,
      iva: ivaLegend ? "fiscal" : "default",
      address: addressSource,
      phone: phoneSource,
      email: email ? "brand" : "default",
      website: website ? "brand" : "default",
      footer_note: footer ? "brand" : "default",
    },
  }
}

// ─── Anti-XSS del HTML imprimible ────────────────────────────────────────────

/** El tope de un logo normalizado (300 KB) en base64, con margen. */
const MAX_LOGO_DATA_URI_LENGTH = 420_000
const LOGO_DATA_URI = /^data:image\/(?:png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$/

/** ¿Es un `data:` PNG/JPEG en base64 seguro de interpolar en un atributo `src`? Nunca una
 *  URL, un SVG ni nada con comillas o marcado. */
export function isSafeLogoDataUri(value: string | undefined | null): value is string {
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_LOGO_DATA_URI_LENGTH) return false
  return LOGO_DATA_URI.test(value)
}

const SAFE_HEX = /^#[0-9a-f]{6}$/

/** ¿Es un `#rrggbb` en minúsculas, seguro de interpolar en un estilo? */
export function isSafeHexColor(value: string | undefined | null): value is string {
  return typeof value === "string" && SAFE_HEX.test(value)
}

// ─── Lo que consume el comprobante interno (HTML y textos) ───────────────────

export interface ReceiptIssuer {
  name: string
  legalName: string | null
  cuit: string | null
  ivaLegend: string | null
  address: string | null
  phone: string | null
  email: string | null
  website: string | null
}

export interface ReceiptPalette {
  accent: string | null
  ink: string
  muted: string
  rule: string
  surface: string
  heading: string
  strongRule: string
  tableHeadFill: string
  tableHeadText: string
  total: string
}

export interface ReceiptBranding {
  issuer: ReceiptIssuer
  footerNote: string | null
  palette: ReceiptPalette
  /** `data:` PNG/JPEG ya validado; ausente = se dibuja la inicial. */
  logoDataUri?: string
}

function safeColor(candidate: string, fallback: string): string {
  return isSafeHexColor(candidate) ? candidate : fallback
}

/**
 * La marca que lee `lib/receipt.ts`: el emisor y la leyenda del servidor, la paleta con cada
 * color VALIDADO (uno inválido cae al de Neutro, campo por campo) y el logo sólo si es un
 * `data:` PNG/JPEG válido.
 */
export function toReceiptBranding(branding: DocumentBranding, logoDataUri?: string | null): ReceiptBranding {
  const palette = branding.palette
  const neutral = NEUTRAL_PALETTE
  return {
    issuer: {
      name: branding.issuer.name || DEFAULT_ISSUER_NAME,
      legalName: branding.issuer.legal_name,
      cuit: branding.issuer.cuit,
      ivaLegend: branding.issuer.iva_legend,
      address: branding.issuer.address,
      phone: branding.issuer.phone,
      email: branding.issuer.email,
      website: branding.issuer.website,
    },
    footerNote: branding.footer_note,
    palette: {
      accent: isSafeHexColor(palette.accent) ? palette.accent : null,
      ink: safeColor(palette.ink, neutral.ink),
      muted: safeColor(palette.muted, neutral.muted),
      rule: safeColor(palette.rule, neutral.rule),
      surface: safeColor(palette.surface, neutral.surface),
      heading: safeColor(palette.heading, neutral.heading),
      strongRule: safeColor(palette.strong_rule, neutral.strong_rule),
      tableHeadFill: safeColor(palette.table_head_fill, neutral.table_head_fill),
      tableHeadText: safeColor(palette.table_head_text, neutral.table_head_text),
      total: safeColor(palette.total, neutral.total),
    },
    logoDataUri: isSafeLogoDataUri(logoDataUri) ? logoDataUri : undefined,
  }
}

/**
 * La marca por defecto del comprobante: Neutro, sin logo, sin contacto, con el nombre que se
 * tenga (el último cacheado o "Mi Negocio"). Es el camino de respaldo cuando la marca no se
 * pudo cargar: el comprobante sale igual, con el diseño básico.
 */
export function defaultReceiptBranding(name: string = DEFAULT_ISSUER_NAME): ReceiptBranding {
  return toReceiptBranding({
    ...DEFAULT_DOCUMENT_BRANDING,
    issuer: { ...DEFAULT_DOCUMENT_BRANDING.issuer, name: name.trim() || DEFAULT_ISSUER_NAME },
  })
}
