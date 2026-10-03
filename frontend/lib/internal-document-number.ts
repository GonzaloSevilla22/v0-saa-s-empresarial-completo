/**
 * presupuestos-modulo (D3) — etiqueta visible del número interno de un
 * documento comercial y lectura del texto de búsqueda del listado.
 *
 * Una sola definición por lenguaje: este módulo y
 * `backend/services/commercial_documents/numbering.py`, atadas por el fixture
 * `backend/tests/fixtures/internal_document_number_cases.json` que recorren
 * pytest y vitest. El número lo asigna la base (`internal_document_sequences`);
 * acá sólo se le da forma: prefijo por tipo + relleno a 8 dígitos
 * (`P-00000012`).
 *
 * `remitos-venta` suma su tipo acá y en el `CHECK` de la tabla de secuencias:
 * `delivery_note_sale` -> `R`. El prefijo `R` es SÓLO del sentido venta: cada
 * sentido numera desde 1, así que el remito de compra (`remitos-compra`, D2)
 * tiene el suyo: `delivery_note_purchase` -> `RC`. Por eso todo lugar que
 * rotula un remito lo hace con `formatDeliveryNoteNumber(direction, n)`, nunca
 * con una `R` escrita a mano.
 */

export type InternalDocumentType = "quote" | "delivery_note_sale" | "delivery_note_purchase"

const PREFIX_BY_TYPE: Record<InternalDocumentType, string> = {
  quote: "P",
  delivery_note_sale: "R",
  delivery_note_purchase: "RC",
}

const PAD = 8

/** `P-00000012` — un número de más de 8 dígitos se muestra completo, sin truncar. */
export function formatInternalDocumentNumber(type: InternalDocumentType, n: number): string {
  return `${PREFIX_BY_TYPE[type]}-${String(n).padStart(PAD, "0")}`
}

const QUERY_PATTERN_BY_TYPE: Record<InternalDocumentType, RegExp> = {
  quote: new RegExp(`^(?:${PREFIX_BY_TYPE.quote}-)?(\\d+)$`, "i"),
  delivery_note_sale: new RegExp(`^(?:${PREFIX_BY_TYPE.delivery_note_sale}-)?(\\d+)$`, "i"),
  delivery_note_purchase: new RegExp(`^(?:${PREFIX_BY_TYPE.delivery_note_purchase}-)?(\\d+)$`, "i"),
}

/**
 * El número que el usuario está buscando en el listado, o `null` si el texto
 * no es un número de documento (entonces se busca por nombre de cliente).
 * Acepta el prefijo del tipo del listado (`P-12` en presupuestos, `R-12` en
 * remitos), el número solo (`12`) y el relleno (`00000012`), sin distinguir
 * mayúsculas y con espacios. El prefijo de OTRO tipo no es de este listado:
 * devuelve `null` y se busca como texto.
 * Un número es un entero positivo y seguro: nunca se compara contra un valor
 * que JavaScript tuvo que redondear.
 */
export function parseInternalDocumentNumberQuery(query: string, type: InternalDocumentType): number | null {
  const match = QUERY_PATTERN_BY_TYPE[type].exec(query.trim())
  if (!match) return null
  const n = Number(match[1])
  return Number.isSafeInteger(n) && n > 0 ? n : null
}

/**
 * La etiqueta visible del número de un remito, según su SENTIDO (D2): `R-…` en
 * venta y `RC-…` en compra. `null` si el remito no tiene número (fila escrita
 * en modo réplica). Cada sentido numera desde 1, así que el mismo número se
 * rotula distinto: nunca se imprime el de compra sin prefijo ni con la `R` de
 * venta, que lo haría indistinguible de un remito de venta con el mismo número.
 */
export function formatDeliveryNoteNumber(direction: "sale" | "purchase", n: number | null): string | null {
  if (n === null) return null
  return formatInternalDocumentNumber(direction === "sale" ? "delivery_note_sale" : "delivery_note_purchase", n)
}
