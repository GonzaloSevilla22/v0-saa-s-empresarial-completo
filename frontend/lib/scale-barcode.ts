/**
 * lib/scale-barcode.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * balanza-etiquetas-pos (D5) — decodificador puro de una etiqueta de balanza.
 *
 * ⚠️  Pura — reutiliza `validateEAN13` existente (`lib/barcode-utils.ts`),
 *     nunca reimplementa el verificador EAN-13.
 */

import { validateEAN13 } from "@/lib/barcode-utils"
import type { ScaleLayout, ScaleSettings } from "@/lib/scale-layout"

// ─── Resultado ────────────────────────────────────────────────────────────────

export type ScaleDecodeResult =
  | { status: "not_scale"; reason: "disabled" | "not_ean13" | "no_layout_match" }
  | { status: "invalid"; reason: "check_digit" | "value_zero" | "missing_check_digit" }
  | { status: "unsupported"; reason: "multi_item" | "generic_item" }
  | {
      status: "ok"
      layout: "weighed" | "unit"
      /** Sin ceros a la izquierda (`0261` → `261`). */
      plu: number
      value: { kind: "amount" | "weight" | "quantity"; amount: number }
    }

// ─── Decodificador ────────────────────────────────────────────────────────────

/**
 * Busca, entre los formatos HABILITADOS, aquel cuya cabecera (campo A) es
 * prefijo del código. D4.5 garantiza a lo sumo uno; se toma el primero que
 * coincida.
 */
function findMatchingLayout(code: string, settings: ScaleSettings): ScaleLayout | undefined {
  return settings.layouts.find((layout) => {
    if (!layout.enabled) return false
    const fieldA = layout.segments[0]
    if (!fieldA || fieldA.field !== "fixed" || !fieldA.value) return false
    return code.startsWith(fieldA.value)
  })
}

/**
 * Decodifica un código leído contra la configuración de balanza de la cuenta
 * (D5). Nunca lanza — toda entrada, válida o no, produce un `ScaleDecodeResult`.
 *
 * El `reason` de `not_scale` no cambia el flujo de resolución (se sigue
 * buscando por SKU, D6), pero lo usan el probador de la pestaña Balanza y el
 * mensaje final de "no encontrado".
 */
export function decodeScaleBarcode(code: string, settings: ScaleSettings): ScaleDecodeResult {
  if (!settings.enabled) return { status: "not_scale", reason: "disabled" }

  // 12 dígitos que empiezan con una cabecera habilitada: el lector está
  // configurado para no transmitir el dígito verificador EAN-13 — la falla
  // de configuración más probable en la primera instalación.
  if (/^\d{12}$/.test(code) && findMatchingLayout(code, settings)) {
    return { status: "invalid", reason: "missing_check_digit" }
  }

  if (!/^\d{13}$/.test(code)) return { status: "not_scale", reason: "not_ean13" }

  const layout = findMatchingLayout(code, settings)
  if (!layout) return { status: "not_scale", reason: "no_layout_match" }

  if (!validateEAN13(code)) return { status: "invalid", reason: "check_digit" }

  if (layout.kind === "multi") return { status: "unsupported", reason: "multi_item" }

  let pos = 0
  let plu: number | null = null
  let value: { kind: "amount" | "weight" | "quantity"; amount: number } | null = null

  for (const segment of layout.segments) {
    const chunk = code.slice(pos, pos + segment.digits)
    pos += segment.digits

    if (segment.field === "plu") {
      plu = chunk.length > 0 ? parseInt(chunk, 10) : 0
    } else if (segment.field === "amount" || segment.field === "quantity") {
      const raw = chunk.length > 0 ? parseInt(chunk, 10) : 0
      const decimals = segment.decimals ?? 0
      const amount = raw / 10 ** decimals
      // "amount" para un campo de importe; "weight" para una cantidad en el
      // formato de peso; "quantity" para una cantidad en el de unidad.
      const kind: "amount" | "weight" | "quantity" =
        segment.field === "amount" ? "amount" : layout.kind === "weighed" ? "weight" : "quantity"
      value = { kind, amount }
    }
    // "fixed" / "ignored": se descartan (tara, sección, n.º de balanza).
  }

  // El PLU 0 es el artículo genérico de fábrica (pág. 34): la etiqueta es
  // legítima pero no identifica el producto.
  if (plu === null || plu === 0) return { status: "unsupported", reason: "generic_item" }

  // Una etiqueta con importe, peso o cantidad cero nunca es una línea: pasa
  // con un PLU sin precio cargado en la balanza.
  if (!value || value.amount === 0) return { status: "invalid", reason: "value_zero" }

  return { status: "ok", layout: layout.kind as "weighed" | "unit", plu, value }
}

// ─── Mensajes ─────────────────────────────────────────────────────────────────

/**
 * Mensaje accionable para un resultado NO `ok`. No cubre `not_scale` (ese
 * `reason` lo interpreta `lib/scan-resolution.ts`, que decide si sigue
 * buscando o arma el mensaje final de "no encontrado" / "parece una etiqueta").
 */
export function scaleDecodeErrorMessage(result: Exclude<ScaleDecodeResult, { status: "ok" }>): string {
  if (result.status === "invalid") {
    switch (result.reason) {
      case "missing_check_digit":
        return "el lector no envía el dígito verificador: habilitá la transmisión del check digit EAN-13 en el lector"
      case "check_digit":
        return "El código no es una etiqueta válida: el dígito verificador no coincide."
      case "value_zero":
        return "La etiqueta tiene un valor en cero: no corresponde a ninguna venta."
    }
  }
  if (result.status === "unsupported") {
    switch (result.reason) {
      case "multi_item":
        return "Este código es un ticket de varios artículos: cargá los productos uno por uno."
      case "generic_item":
        return "Etiqueta de venta genérica de la balanza (PLU 0): no identifica el producto — vendelo con su PLU o cargalo a mano."
    }
  }
  // not_scale: sin mensaje propio — lo arma lib/scan-resolution.ts con el código.
  return "El código leído no es una etiqueta de balanza reconocible."
}
