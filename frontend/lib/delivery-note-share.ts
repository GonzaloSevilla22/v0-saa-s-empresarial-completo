/**
 * remitos-venta / remitos-compra (D11) — el texto corto que acompaña al PDF del
 * remito cuando se manda por WhatsApp y el nombre del archivo. Funciones puras.
 *
 * Venta: "Hola Ana, te envío el remito R-00000012 de la mercadería entregada el
 * 02/10/2026. Kiosco Lola".
 * Compra: "Hola Andina, te confirmo la recepción de la mercadería del remito
 * RC-00000012 (tu remito N° 0004-00012345) el 03/10/2026. Kiosco Lola".
 *
 * Sin nombre: sin saludo personalizado; sin negocio, la cola se omite; sin número
 * del proveedor, el paréntesis se omite. `onShared` no cambia el estado: el
 * remito no tiene "enviado".
 */
import type { DeliveryNoteDirection } from "@/lib/delivery-note-types"

export interface DeliveryNoteShareTextInput {
  /** Sentido del remito; sin él, venta (retrocompatible). */
  direction?: DeliveryNoteDirection
  /** Venta: a quién se entregó. */
  clientName?: string | null
  /** Compra: quién entregó la mercadería (el destinatario del mensaje). */
  supplierName?: string | null
  /** Compra: el número del remito del proveedor (`supplier_reference`), si lo hay. */
  supplierReference?: string | null
  /** `R-00000012` / `RC-00000012`; `null` en una fila sin numerar: se omite en vez de inventarlo. */
  numberLabel: string | null
  /** Fecha ISO `YYYY-MM-DD` (fecha de negocio, no instante). */
  issuedOn: string
  businessName?: string | null
}

/** `2026-10-02` -> `02/10/2026`, desde el texto: pasar por `Date` correría el día. */
function formatIsoDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-")
  return `${d}/${m}/${y}`
}

export function buildDeliveryNoteShareText({
  direction = "sale",
  clientName,
  supplierName,
  supplierReference,
  numberLabel,
  issuedOn,
  businessName,
}: DeliveryNoteShareTextInput): string {
  const remitoRef = numberLabel ? `remito ${numberLabel}` : "remito"
  const date = formatIsoDate(issuedOn)
  let sentence: string
  if (direction === "purchase") {
    const name = supplierName?.trim()
    const greeting = name ? `Hola ${name},` : "Hola,"
    const reference = supplierReference?.trim()
    const yours = reference ? ` (tu remito N° ${reference})` : ""
    sentence = `${greeting} te confirmo la recepción de la mercadería del ${remitoRef}${yours} el ${date}.`
  } else {
    const name = clientName?.trim()
    const greeting = name ? `Hola ${name},` : "Hola,"
    sentence = `${greeting} te envío el ${remitoRef} de la mercadería entregada el ${date}.`
  }
  const business = businessName?.trim()
  return business ? `${sentence} ${business}` : sentence
}

/**
 * Nombre del archivo del PDF: `remito-R-00000012.pdf` en venta y
 * `remito-compra-RC-00000012.pdf` en compra (igual que el backend, D10). La
 * variante con precios lleva `-con-precios` para que nadie confunda, en una
 * carpeta de descargas, el remito que se le puede mandar a un tercero con el que
 * muestra los importes.
 */
export function deliveryNoteFileName(
  direction: DeliveryNoteDirection,
  numberLabel: string | null,
  showPrices: boolean,
): string {
  const prefix = direction === "purchase" ? "remito-compra" : "remito"
  const base = numberLabel ? `${prefix}-${numberLabel}` : prefix
  return showPrices ? `${base}-con-precios.pdf` : `${base}.pdf`
}
