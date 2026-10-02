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
 * `remitos-venta` suma su tipo acá y en el `CHECK` de la tabla de secuencias.
 */

export type InternalDocumentType = "quote"

const PREFIX_BY_TYPE: Record<InternalDocumentType, string> = {
  quote: "P",
}

const PAD = 8

/** `P-00000012` — un número de más de 8 dígitos se muestra completo, sin truncar. */
export function formatInternalDocumentNumber(type: InternalDocumentType, n: number): string {
  return `${PREFIX_BY_TYPE[type]}-${String(n).padStart(PAD, "0")}`
}

const QUERY_PATTERN = new RegExp(
  `^(?:(?:${Object.values(PREFIX_BY_TYPE).join("|")})-)?(\\d+)$`,
  "i",
)

/**
 * El número que el usuario está buscando en el listado, o `null` si el texto
 * no es un número de documento (entonces se busca por nombre de cliente).
 * Acepta `P-12`, `12` y `00000012`, sin distinguir mayúsculas y con espacios.
 * Un número es un entero positivo y seguro: nunca se compara contra un valor
 * que JavaScript tuvo que redondear.
 */
export function parseInternalDocumentNumberQuery(query: string): number | null {
  const match = QUERY_PATTERN.exec(query.trim())
  if (!match) return null
  const n = Number(match[1])
  return Number.isSafeInteger(n) && n > 0 ? n : null
}
