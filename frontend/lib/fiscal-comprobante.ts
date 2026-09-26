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

/** Etiqueta legible del tipo de comprobante ("factura_c" → "Factura C"). */
export function comprobanteTypeLabel(comprobanteType?: string | null): string {
  if (!comprobanteType) return "Comprobante"
  const parts = comprobanteType.split("_")
  const head = parts[0] ?? ""
  const letter = parts.slice(1).join(" ").toUpperCase()
  const capitalized = head.charAt(0).toUpperCase() + head.slice(1)
  return letter ? `${capitalized} ${letter}` : capitalized
}
