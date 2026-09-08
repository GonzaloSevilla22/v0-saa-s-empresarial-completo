/**
 * Import / Export utilities — ERP-grade CSV handling.
 *
 * PARSER: RFC 4180 compliant — handles quoted fields with embedded commas,
 * semicolons, and newlines. Strips UTF-8 BOM produced by Excel / our own exports.
 *
 * EXPORT: appends the <a> element to the DOM before clicking, and delays
 * URL revocation 100 ms so the browser finishes processing the download.
 */

import { argentinaToday } from "@/lib/date-range"
import { formatNumber } from "@/lib/format"

// ─── Constants ────────────────────────────────────────────────────────────────

/** Maximum file size accepted for import (prevents main-thread freeze). */
export const MAX_IMPORT_SIZE_BYTES = 5 * 1024 * 1024 // 5 MB

// ─── Export ───────────────────────────────────────────────────────────────────

/**
 * Exports `data` to a UTF-8 CSV file using `;` as separator.
 * The file is compatible with Excel (auto-detects the separator when BOM present).
 */
export function exportToCSV<T extends Record<string, unknown>>(
  data: T[],
  columns: { key: string; header: string }[],
  filename: string,
): void {
  const BOM = "﻿"
  const header = columns.map((c) => `"${c.header}"`).join(";")
  const rows = data.map((row) =>
    columns
      .map((c) => {
        const val = row[c.key]
        if (val === null || val === undefined) return '""'
        // Escape embedded double quotes by doubling them (RFC 4180 §2.7)
        const str = String(val).replace(/"/g, '""')
        return `"${str}"`
      })
      .join(";"),
  )
  const csv = BOM + [header, ...rows].join("\n")
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" })
  const url = URL.createObjectURL(blob)

  // Append to DOM — required in Firefox and some Chromium builds
  const link = document.createElement("a")
  link.href = url
  link.download = `${filename}.csv`
  link.style.display = "none"
  document.body.appendChild(link)
  link.click()

  // Delay revocation: the browser must process the click before we free the URL
  setTimeout(() => {
    URL.revokeObjectURL(url)
    document.body.removeChild(link)
  }, 150)
}

// ─── Import helpers ───────────────────────────────────────────────────────────

/**
 * Reads a File as text, always using UTF-8 encoding.
 * Throws if the file exceeds MAX_IMPORT_SIZE_BYTES.
 */
export function readFileAsText(file: File): Promise<string> {
  if (file.size > MAX_IMPORT_SIZE_BYTES) {
    return Promise.reject(
      new Error(`El archivo supera el límite de 5 MB (${(file.size / 1024 / 1024).toFixed(1)} MB).`),
    )
  }
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = () => reject(new Error("No se pudo leer el archivo."))
    reader.readAsText(file, "UTF-8")
  })
}

/**
 * Validates that all required CSV headers are present.
 * Returns { ok: true } or { ok: false, missing: string[] }.
 */
export function validateImportColumns(
  text: string,
  requiredHeaders: string[],
): { ok: true } | { ok: false; missing: string[] } {
  // Strip BOM and grab the first line
  const firstLine = text.replace(/^﻿/, "").split(/\r?\n/)[0] ?? ""
  const sep = firstLine.includes(";") ? ";" : ","
  const foundHeaders = parseLine(firstLine, sep).map((h) => h.toLowerCase())

  const missing = requiredHeaders.filter(
    (req) => !foundHeaders.includes(req.toLowerCase()),
  )
  return missing.length === 0 ? { ok: true } : { ok: false, missing }
}

// ─── RFC 4180 CSV parser ──────────────────────────────────────────────────────

/**
 * Splits a single CSV line respecting quoted fields.
 * Handles: fields with embedded separator, embedded quotes (doubled), empty fields.
 */
function parseLine(line: string, sep: string): string[] {
  const result: string[] = []
  let current = ""
  let inQuotes = false

  for (let i = 0; i < line.length; i++) {
    const ch = line[i]

    if (inQuotes) {
      if (ch === '"') {
        if (i + 1 < line.length && line[i + 1] === '"') {
          // Escaped quote (RFC 4180 §2.7): "" inside quotes → single "
          current += '"'
          i++
        } else {
          // End of quoted field
          inQuotes = false
        }
      } else {
        current += ch
      }
    } else {
      if (ch === '"') {
        inQuotes = true
      } else if (ch === sep) {
        result.push(current.trim())
        current = ""
      } else {
        current += ch
      }
    }
  }
  result.push(current.trim())
  return result
}

/**
 * Parses a CSV/TXT string into an array of mapped objects.
 *
 * - Strips UTF-8 BOM automatically.
 * - Detects separator (`;` or `,`) from the first line.
 * - RFC 4180 compliant: quoted fields with embedded separators/newlines are handled.
 * - Column matching is case-insensitive.
 * - Rows where none of the requested keys were found are skipped.
 *
 * @param text     Raw file content (UTF-8 string).
 * @param columnMap  Mapping from CSV header names to output key names.
 * @returns Array of plain objects with string values.
 */
export function parseCSV(
  text: string,
  columnMap: { csvHeader: string; key: string }[],
): Record<string, string>[] {
  // Strip UTF-8 BOM (produced by Excel and by our own exportToCSV)
  const clean = text.replace(/^﻿/, "")
  const lines = clean.split(/\r?\n/).filter((l) => l.trim() !== "")

  if (lines.length < 2) return []

  const sep = lines[0].includes(";") ? ";" : ","
  const headers = parseLine(lines[0], sep).map((h) => h.toLowerCase())

  const results: Record<string, string>[] = []

  for (let i = 1; i < lines.length; i++) {
    const values = parseLine(lines[i], sep)
    const row: Record<string, string> = {}

    for (const cm of columnMap) {
      const idx = headers.findIndex((h) => h === cm.csvHeader.toLowerCase())
      if (idx >= 0 && values[idx] !== undefined) {
        row[cm.key] = values[idx]
      }
    }

    // Skip rows where no mapped key was found (e.g. blank trailing lines)
    if (Object.keys(row).length > 0) {
      results.push(row)
    }
  }

  return results
}

// ─── Amount parsing helper (handles European and US formats) ─────────────────

export interface ParseAmountOptions {
  /**
   * Una coma sin punto es SIEMPRE decimal ("1,250" → 1.25) y más de una coma
   * sin punto es inválida (NaN). Sin la opción rige la heurística de importes:
   * coma seguida de tres o más dígitos = separador de miles ("1,250" → 1250).
   * Usarla para cantidades físicas (stock en kg, litros, metros), donde tres
   * decimales son normales; los importes en pesos conservan el default.
   */
  loneCommaIsDecimal?: boolean
}

/**
 * Descarta todo lo que no sea dígito, punto, coma o signo menos — el mismo
 * texto que ven `parseAmount`, `parseQuantity` y `amountAmbiguityWarning`
 * antes de leer el número o detectar ambigüedad de miles, así un sufijo de
 * ruido ("kg", "$") no evade ninguno de los tres chequeos.
 */
function cleanNumericText(raw: string): string {
  return raw.replace(/[^\d.,-]/g, "")
}

/**
 * Parses a monetary/numeric string into a float.
 * Supports: "1.234,56" (European/AR), "1,234.56" (US), "1234.56", "1234".
 * Returns NaN if the string cannot be parsed.
 */
export function parseAmount(raw: string | undefined, options: ParseAmountOptions = {}): number {
  if (!raw) return NaN
  const s = String(raw).trim()

  // Strip currency symbols, spaces, $, etc. — keep digits, dots, commas, minus
  const cleaned = cleanNumericText(s)
  if (!cleaned) return NaN

  const hasComma = cleaned.includes(",")
  const hasDot = cleaned.includes(".")

  if (hasComma && hasDot) {
    const lastComma = cleaned.lastIndexOf(",")
    const lastDot = cleaned.lastIndexOf(".")
    if (lastComma > lastDot) {
      // European: "1.234,56" → remove dots, replace comma with dot
      return parseFloat(cleaned.replace(/\./g, "").replace(",", "."))
    } else {
      // US: "1,234.56" → remove commas
      return parseFloat(cleaned.replace(/,/g, ""))
    }
  }

  if (hasComma && !hasDot) {
    // Could be "1234,56" (decimal comma) or "1,234" (thousands separator)
    const parts = cleaned.split(",")
    if (options.loneCommaIsDecimal) {
      // Cantidad física: la coma es decimal sin mirar cuántos dígitos siguen
      // ("1,250" → 1.25); dos o más comas no son un número ("1,5,2" → NaN).
      return parts.length === 2 ? parseFloat(cleaned.replace(",", ".")) : NaN
    }
    if (parts.length === 2 && parts[1].length <= 2) {
      // Treat as decimal comma: "1234,56"
      return parseFloat(cleaned.replace(",", "."))
    }
    // Treat as thousands separator: "1,234" → 1234
    return parseFloat(cleaned.replace(/,/g, ""))
  }

  return parseFloat(cleaned)
}

/**
 * ¿El texto de un número podría leerse también como agrupación de miles
 * ("1,250", "1.250", "12.345.678")? Grupos de tres dígitos separados por un
 * único tipo de separador. Sin `separator`, cualquiera de los dos separadores
 * cuenta (consistente en todo el número, como ya usaba el importador de
 * ajustes de stock); con `separator`, sólo ese separador — usarlo cuando el
 * otro separador ya tiene un significado fijo en el contrato (p.ej. la coma
 * es siempre decimal con `loneCommaIsDecimal`, así que sólo el punto puede
 * ser una agrupación de miles ambigua).
 */
export function looksLikeThousandsGrouping(raw: string, separator?: "." | ","): boolean {
  const s = raw.trim()
  if (separator) {
    const esc = separator === "." ? "\\." : ","
    return new RegExp(`^-?\\d{1,3}(?:${esc}\\d{3})+$`).test(s)
  }
  return /^-?\d{1,3}([.,])\d{3}(?:\1\d{3})*$/.test(s)
}

/** Rótulos en uso por los dos callers del helper — cierra el union para poder derivar la concordancia de género (ver `QUANTITY_ADJECTIVES`) sin `any`. */
export type QuantityLabel = "Stock" | "Stock mínimo" | "Cantidad"

/**
 * Concordancia de género por rótulo: "Stock"/"Stock mínimo" son masculinos
 * ("el stock inválido"); "Cantidad" es femenino ("la cantidad inválida") —
 * sin esto, `quantityInvalidMessage`/`quantityAmbiguousMessage` hardcodeaban
 * el masculino y "Cantidad inválido"/"Cantidad ambiguo" quedaba mal.
 */
const QUANTITY_ADJECTIVES: Record<QuantityLabel, { invalid: string; ambiguous: string }> = {
  Stock: { invalid: "inválido", ambiguous: "ambiguo" },
  "Stock mínimo": { invalid: "inválido", ambiguous: "ambiguo" },
  Cantidad: { invalid: "inválida", ambiguous: "ambigua" },
}

export interface ParseQuantityOptions {
  /** Rótulo usado en los textos de warning — fija la concordancia de género (ver `QuantityLabel`). */
  label: QuantityLabel
  /**
   * Redondea hacia arriba (Math.ceil) cuando el valor no es entero, con
   * warning (columnas `integer` en DB, p.ej. `min_stock`). Tiene prioridad
   * sobre `maxDecimals` si ambos se pasan.
   */
  integer?: boolean
  /** Redondea a este número de decimales cuando el texto trae más, con warning. */
  maxDecimals?: number
  /**
   * Un valor negativo es inválido por defecto (mismo criterio que un
   * importe/cantidad física: no hay lectura negativa razonable). Pasar
   * `true` para dejarlo pasar tal cual — lo usa el importador de ajustes de
   * stock, que arma su propio mensaje ("no puede ser negativa") en vez de
   * reemplazarlo por 0 en silencio.
   */
  allowNegative?: boolean
  /**
   * Suprime todo texto de warning — para un caller con su propio canal de
   * errores/warnings por fila (el importador de ajustes de stock).
   */
  silent?: boolean
}

export interface ParsedQuantity {
  value: number | null
  warnings: string[]
  invalid: boolean
}

function quantityInvalidMessage(label: QuantityLabel, raw: string, integer?: boolean): string {
  const adj = QUANTITY_ADJECTIVES[label].invalid
  return integer
    ? `${label} ${adj}: "${raw}" — debe ser un entero ≥ 0, se usará 0 (sin umbral de alerta).`
    : `${label} ${adj}: "${raw}" — se usará 0.`
}

function quantityAmbiguousMessage(label: QuantityLabel, raw: string, value: number): string {
  const adj = QUANTITY_ADJECTIVES[label].ambiguous
  return (
    `${label} ${adj}: "${raw}" — se interpretó como ${formatNumber(value, 4)}. ` +
    `Usá coma para decimales y ningún separador para miles.`
  )
}

function quantityRoundedMessage(label: string, raw: string, rounded: number, maxDecimals: number): string {
  return `${label} "${raw}" se redondeó a ${formatNumber(rounded, maxDecimals)} (máximo ${maxDecimals} decimales).`
}

function quantityCeiledMessage(label: string, raw: string, ceiled: number): string {
  return `${label} "${raw}" no admite decimales: se usará ${ceiled}.`
}

/**
 * Helper canónico de cantidades — reglas compartidas por el importador de
 * productos (stock / stock_minimo, `lib/import/validator.ts`) y el
 * importador de ajustes de stock (cantidad, `lib/stock-import-parser.ts`).
 * Sobre `parseAmount` con `loneCommaIsDecimal` (una coma sin punto SIEMPRE
 * es decimal en una cantidad física, nunca miles):
 *   - 2+ puntos sin coma ("1.234.567") → inválido, en vez de leerse parcial
 *     hasta el 2do punto (lo que hacía `parseFloat` en silencio);
 *   - un punto único con grupos de tres dígitos ("1.500") o una coma con el
 *     mismo patrón ("1,500") se leen como decimal pero avisan la ambigüedad
 *     (también podrían ser miles);
 *   - `integer` redondea hacia arriba (Math.ceil) con aviso; `maxDecimals`
 *     redondea con aviso cuando el texto trae más decimales de los que la
 *     columna admite;
 *   - un valor negativo es inválido salvo `allowNegative`;
 *   - `silent` suprime todo texto (el caller tiene su propio canal);
 *   - una celda vacía (o sólo espacios) SIEMPRE devuelve
 *     `{ value: null, invalid: true, warnings: [] }`, sin importar `silent`
 *     ni `integer`: una celda no cargada no es lo mismo que un texto
 *     ilegible, y el warning de "inválido" citando una cadena vacía
 *     (`${label} inválido: "" — …`) no le sirve a nadie. Los callers que
 *     quieren un default silencioso ya evitan llegar acá con texto vacío
 *     (`raw.stock.trim()` en `lib/import/validator.ts`); el que no guarda
 *     (`lib/stock-import-parser.ts`) llama con `silent: true`, así que el
 *     resultado no cambia para el usuario en ningún caso.
 */
export function parseQuantity(raw: string, opts: ParseQuantityOptions): ParsedQuantity {
  const { label, integer, maxDecimals, allowNegative = false, silent = false } = opts
  const trimmed = raw.trim()
  if (trimmed === "") {
    return { value: null, invalid: true, warnings: [] }
  }
  // Mismo texto que ve parseAmount (descarta ruido como "kg" o "$"): así el
  // pre-chequeo de puntos y el detector de ambigüedad no se evaden con un sufijo.
  const cleaned = cleanNumericText(trimmed)
  const dotCount = (cleaned.match(/\./g) ?? []).length
  const tooManyDots = !cleaned.includes(",") && dotCount >= 2

  const parsed = tooManyDots ? NaN : parseAmount(trimmed, { loneCommaIsDecimal: true })
  const isNegative = !isNaN(parsed) && parsed < 0
  const invalid = isNaN(parsed) || (isNegative && !allowNegative)

  if (invalid) {
    return {
      value: null,
      invalid: true,
      warnings: silent ? [] : [quantityInvalidMessage(label, trimmed, integer)],
    }
  }

  const warnings: string[] = []
  let value = parsed

  if (!silent && looksLikeThousandsGrouping(cleaned)) {
    warnings.push(quantityAmbiguousMessage(label, trimmed, value))
  }

  if (integer) {
    if (!Number.isInteger(value)) {
      const ceiled = Math.ceil(value)
      if (!silent) warnings.push(quantityCeiledMessage(label, trimmed, ceiled))
      value = ceiled
    }
  } else if (maxDecimals !== undefined) {
    const factor = 10 ** maxDecimals
    const rounded = Math.round(value * factor) / factor
    if (Math.abs(rounded - value) > 1e-9) {
      if (!silent) warnings.push(quantityRoundedMessage(label, trimmed, rounded, maxDecimals))
      value = rounded
    }
  }

  return { value, warnings, invalid: false }
}

/**
 * Warning NO bloqueante para un importe (precio, costo, monto de gasto)
 * leído con `parseAmount` default (default, no `loneCommaIsDecimal`): un
 * punto único con grupos de tres dígitos ("1.500") se interpreta como
 * decimal ($1,5) pero también podría ser miles ($1500) — mismo detector que
 * `parseQuantity` usa para stock, aplicado sólo al punto porque en un
 * importe la coma ya tiene lectura fija (decimal con ≤2 dígitos, si no
 * miles — `parseAmount`, sin `loneCommaIsDecimal`). El contrato de lectura
 * NO cambia: sigue devolviendo lo mismo que hoy, esto sólo agrega el aviso.
 * El valor mostrado usa `formatNumber(value, 4)`, no `formatMoney` (2
 * decimales fijos): un texto como "12.345.678" se lee hoy como 12.345 (2+
 * puntos, `parseFloat` se detiene en el 2do) y `formatMoney` lo redondearía
 * a $12,35 — un número que no es el que se importa. `formatNumber` muestra
 * la precisión real, sin mentir por el redondeo del formato monetario.
 * Devuelve `null` cuando el texto no es ambiguo (no hace falta avisar).
 */
export function amountAmbiguityWarning(label: string, raw: string, value: number): string | null {
  const trimmed = raw.trim()
  const cleaned = cleanNumericText(trimmed)
  if (!looksLikeThousandsGrouping(cleaned, ".")) return null
  return (
    `${label} ambiguo: "${trimmed}" — se interpretó como $ ${formatNumber(value, 4)}. ` +
    `Usá coma para decimales y ningún separador para miles.`
  )
}

/**
 * Parses a date string into YYYY-MM-DD format.
 * Handles: "YYYY-MM-DD", "DD/MM/YYYY", "D/M/YYYY".
 * Returns today's date if the string is unrecognizable.
 */
export function parseDate(raw: string | undefined): string {
  const today = argentinaToday()
  if (!raw) return today
  const s = raw.trim()
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s
  if (/^\d{1,2}\/\d{1,2}\/\d{4}$/.test(s)) {
    const [d, m, y] = s.split("/")
    return `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}`
  }
  return today
}
