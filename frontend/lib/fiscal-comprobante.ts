/**
 * fiscal-emision-segura (G7, 2026-09-22) — identidad de un comprobante fiscal.
 *
 * Formato de ARCA: punto de venta en 4 dígitos + número en 8
 * ("Factura C 0003-00000002"), el mismo que el PO ve en la constatación de
 * comprobantes. Es el dato que G3 empezó a persistir de verdad (hasta ese
 * change se descartaba el número que ARCA confirmaba y quedaba el local): sin
 * una pantalla que lo muestre, corregirlo no lo verifica nadie.
 *
 * Vive en `lib/` y no en el hook de emisión a propósito: son funciones PURAS y
 * el módulo del hook arrastra `python-client`, que aborta en import si
 * NEXT_PUBLIC_BACKEND_URL no está definida — o sea que no serían testeables sin
 * mockear media app.
 */

import { isFiscalDocumentStatus, type SaleFiscalState } from "@/lib/types"

/**
 * Número de punto de venta con el formato de ARCA (4 dígitos: 3 → "0003").
 * punto-venta-seleccion (D6): única fuente del padding — la usan el
 * comprobante, el selector de PV y la configuración fiscal.
 */
export function formatPuntoDeVenta(puntoDeVenta: number): string {
  return String(puntoDeVenta).padStart(4, "0")
}

/**
 * Devuelve el comprobante formateado como lo numera ARCA, o `null` si falta
 * cualquiera de los dos datos. `null` es deliberado: la pantalla no debe
 * renderizar un "—" donde va un número, porque parece un número que no existe.
 */
export function formatComprobante(
  puntoDeVenta?: number | null,
  numero?: number | null,
): string | null {
  if (puntoDeVenta == null || numero == null) return null
  return `${formatPuntoDeVenta(puntoDeVenta)}-${String(numero).padStart(8, "0")}`
}

/**
 * factura-fiscal-imprimible (D10): los campos del estado fiscal tal como los
 * devuelven `/sales` y `/sales-orders` (mismos nombres en los dos read models).
 */
export interface FiscalReadModelRow {
  fiscal_document_id?: string | null
  fiscal_document_status?: string | null
  fiscal_punto_de_venta?: number | null
  fiscal_number?: number | null
  fiscal_submitted_to_arca?: boolean | null
  fiscal_frozen?: boolean | null
  fiscal_pending_voidable?: boolean | null
  fiscal_cae?: string | null
  fiscal_cae_due_date?: string | null
  fiscal_comprobante_type?: string | null
}

/**
 * Un solo mapeo del estado fiscal para ventas y órdenes (antes vivía en
 * `use-sales.ts`; las órdenes lo necesitan igual). `null` = sin comprobante.
 * Un estado que el cliente no conoce cae en `pending_cae`: el estado que no
 * ofrece ninguna acción (ni imprimir ni anular); las decisiones reales las
 * toma el servidor.
 */
export function mapFiscalState(row: FiscalReadModelRow): SaleFiscalState | null {
  if (!row.fiscal_document_id) return null
  return {
    documentId:      row.fiscal_document_id,
    status:          isFiscalDocumentStatus(row.fiscal_document_status)
                       ? row.fiscal_document_status
                       : "pending_cae",
    label:           formatComprobante(row.fiscal_punto_de_venta, row.fiscal_number),
    submittedToArca: row.fiscal_submitted_to_arca ?? false,
    frozen:          row.fiscal_frozen ?? false,
    voidable:        row.fiscal_pending_voidable ?? false,
    cae:             row.fiscal_cae ?? null,
    caeDueDate:      row.fiscal_cae_due_date ? row.fiscal_cae_due_date.slice(0, 10) : null,
    comprobanteType: row.fiscal_comprobante_type ?? null,
  }
}

/** Etiqueta legible del tipo de comprobante ("factura_c" → "Factura C"). */
export function comprobanteTypeLabel(comprobanteType?: string | null): string {
  if (!comprobanteType) return "Comprobante"
  const parts = comprobanteType.split("_")
  const head = parts[0] ?? ""
  const letter = parts.slice(1).join(" ").toUpperCase()
  const capitalized = head.charAt(0).toUpperCase() + head.slice(1)
  return letter ? `${capitalized} ${letter}` : capitalized
}

/**
 * factura-fiscal-imprimible (D10): constatación pública de comprobantes con CAE
 * de ARCA — el "Verificar en ARCA" de la venta y de la orden.
 */
export const ARCA_CONSTATACION_URL = "https://servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx"

/** Letra del tipo de factura ("factura_c" → "C"); null si no es una factura A/B/C. */
export function comprobanteLetter(comprobanteType?: string | null): string | null {
  const match = /^factura_([abc])$/.exec(comprobanteType ?? "")
  return match ? match[1].toUpperCase() : null
}

/**
 * Nombre del archivo de la factura impresa: el mismo que manda el backend en
 * `Content-Disposition` (`factura-C-0003-00000501.pdf`). El duplicado se
 * descarga con sufijo para no pisar al original en la carpeta de descargas.
 */
export function invoiceFileName(
  fiscal: Pick<SaleFiscalState, "comprobanteType" | "label">,
  copy: "original" | "duplicado" = "original",
): string {
  const letter = comprobanteLetter(fiscal.comprobanteType) ?? "C"
  const base = `factura-${letter}-${fiscal.label ?? "comprobante"}`
  return `${base}${copy === "duplicado" ? "-duplicado" : ""}.pdf`
}

/** "Factura C 0003-00000501", o sólo el número si el tipo no se conoce. */
export function invoiceDisplayName(fiscal: Pick<SaleFiscalState, "comprobanteType" | "label">): string | null {
  if (!fiscal.label) return null
  return fiscal.comprobanteType
    ? `${comprobanteTypeLabel(fiscal.comprobanteType)} ${fiscal.label}`
    : fiscal.label
}

/** ¿Hay una factura autorizada para ver, imprimir o enviar? */
export function hasPrintableInvoice(fiscal?: SaleFiscalState | null): fiscal is SaleFiscalState {
  return !!fiscal && fiscal.status === "authorized" && !fiscal.frozen
}

