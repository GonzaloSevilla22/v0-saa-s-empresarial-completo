"use client"

/**
 * documentos-marca-empresa (D10, task 11.1) — vista previa del encabezado de un documento
 * (un presupuesto) con lo que se está editando en la pestaña «Documentos».
 *
 * REPRESENTA EL PAPEL, así que es la única excepción declarada a la regla de tokens: fondo
 * BLANCO también en tema oscuro y colores tomados de la paleta de la cuenta (estilos en
 * línea desde hex VALIDADO con `isSafeHexColor`; uno inválido cae al de Neutro), no de los
 * tokens de la app. El marco que la rodea sí usa tokens semánticos.
 *
 * Los textos se renderizan como texto (React escapa) y el logo sólo como `data:` PNG/JPEG
 * validado. Ancho fluido y palabras largas que se parten: no desborda a 360 px.
 *
 * El logo se acota al ancho de SU columna (la del emisor, `min-w-0`) y a 3 rem de alto, sin deformarse
 * (`object-contain`), y el bloque del título no se encoge (`shrink-0`): como en el PDF, emisor a la
 * izquierda y título a la derecha SIN solaparse, aunque el logo sea ancho (360×120) y la columna chica.
 */

import { isSafeHexColor, isSafeLogoDataUri, NEUTRAL_PALETTE, type PrintedIssuer, type ResolvedPalette } from "@/lib/document-branding"
import { cn } from "@/lib/utils"

interface DocumentHeaderPreviewProps {
  issuer: PrintedIssuer
  footerNote: string | null
  palette: ResolvedPalette
  /** `data:` URI del logo normalizado (el que devolvió el servidor); ausente = sin logo. */
  logoDataUri?: string | null
  className?: string
}

/** Un color de la paleta sólo entra al estilo si es `#rrggbb`; si no, el de Neutro. */
function safe(value: string | null | undefined, fallback: string): string {
  return isSafeHexColor(value) ? value : fallback
}

const SAMPLE_LINES = [
  { description: "Remera deportiva", quantity: "2", price: "$ 12.000,00", subtotal: "$ 24.000,00" },
  { description: "Calza larga", quantity: "1", price: "$ 18.500,00", subtotal: "$ 18.500,00" },
]

export function DocumentHeaderPreview({ issuer, footerNote, palette, logoDataUri, className }: DocumentHeaderPreviewProps) {
  const ink = safe(palette.ink, NEUTRAL_PALETTE.ink)
  const muted = safe(palette.muted, NEUTRAL_PALETTE.muted)
  const rule = safe(palette.rule, NEUTRAL_PALETTE.rule)
  const heading = safe(palette.heading, NEUTRAL_PALETTE.heading)
  const strongRule = safe(palette.strong_rule, NEUTRAL_PALETTE.strong_rule)
  const headFill = safe(palette.table_head_fill, NEUTRAL_PALETTE.table_head_fill)
  const headText = safe(palette.table_head_text, NEUTRAL_PALETTE.table_head_text)
  const total = safe(palette.total, NEUTRAL_PALETTE.total)

  const showLegalName =
    issuer.legal_name !== null && issuer.legal_name.trim().toLowerCase() !== issuer.name.trim().toLowerCase()
  const lines: Array<{ text: string; bold?: boolean }> = []
  if (showLegalName && issuer.legal_name) lines.push({ text: issuer.legal_name })
  if (issuer.cuit) lines.push({ text: `CUIT: ${issuer.cuit}` })
  if (issuer.iva_legend) lines.push({ text: issuer.iva_legend, bold: true })
  if (issuer.address) lines.push({ text: issuer.address })
  if (issuer.phone) lines.push({ text: `Tel: ${issuer.phone}` })
  if (issuer.email) lines.push({ text: issuer.email })
  if (issuer.website) lines.push({ text: issuer.website })

  return (
    <div
      role="img"
      aria-label="Vista previa del encabezado de un documento"
      className={cn(
        "w-full max-w-xl overflow-hidden rounded-md border border-border p-4 text-left text-xs shadow-sm break-words [overflow-wrap:anywhere]",
        className,
      )}
      style={{ backgroundColor: "#ffffff", color: ink }}
    >
      <div className="grid grid-cols-[minmax(0,1fr)_auto] gap-3">
        <div className="min-w-0">
          {isSafeLogoDataUri(logoDataUri) && (
            // eslint-disable-next-line @next/next/no-img-element -- data: URI normalizado por el servidor
            <img src={logoDataUri} alt="Logo de la empresa" className="mb-1.5 block h-auto max-h-12 w-auto max-w-full object-contain" />
          )}
          <p className="text-sm font-bold leading-tight" style={{ color: ink }}>{issuer.name}</p>
          {lines.map((line) => (
            <p key={line.text} className={cn("mt-0.5 text-[11px] leading-snug", line.bold && "font-semibold")} style={{ color: line.bold ? ink : muted }}>
              {line.text}
            </p>
          ))}
        </div>
        <div className="shrink-0 text-right">
          <p className="text-sm font-bold" style={{ color: heading }}>PRESUPUESTO</p>
          <p className="mt-0.5 text-[11px] font-semibold" style={{ color: ink }}>N° P-00000001</p>
          <p className="mt-0.5 text-[11px]" style={{ color: ink }}>Fecha: 01/10/2026</p>
        </div>
      </div>

      <div className="my-2.5" style={{ borderTop: `2px solid ${strongRule}` }} />

      <div
        data-testid="preview-table-head"
        className="grid grid-cols-[minmax(0,1fr)_2.5rem_4.5rem] gap-2 rounded-sm px-2 py-1 text-[11px] font-bold"
        style={{ backgroundColor: headFill, color: headText }}
      >
        <span>Descripción</span>
        <span className="text-center">Cant.</span>
        <span className="text-right">Subtotal</span>
      </div>
      {SAMPLE_LINES.map((line) => (
        <div
          key={line.description}
          data-testid="preview-line"
          className="grid grid-cols-[minmax(0,1fr)_2.5rem_4.5rem] gap-2 px-2 py-1 text-[11px]"
          style={{ borderBottom: `1px solid ${rule}`, color: ink }}
        >
          <span>{line.description}</span>
          <span className="text-center">{line.quantity}</span>
          <span className="text-right">{line.subtotal}</span>
        </div>
      ))}
      <div className="mt-2 flex items-baseline justify-end gap-3 px-2">
        <span className="text-xs font-bold" style={{ color: ink }}>TOTAL</span>
        <span data-testid="preview-total" className="text-sm font-bold" style={{ color: total }}>$ 42.500,00</span>
      </div>

      {footerNote && (
        <p className="mt-3 whitespace-pre-line text-center text-[10px] italic" style={{ color: muted }}>{footerNote}</p>
      )}
    </div>
  )
}
