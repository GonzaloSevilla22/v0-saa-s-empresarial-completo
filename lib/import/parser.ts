/**
 * Import file parser.
 *
 * Responsibilities:
 *   - Read a File (CSV or XLSX) and return an array of RawImportRow.
 *   - Handle UTF-8 BOM, `;`/`,` separator auto-detection.
 *   - Detect dynamic attribute columns (headers prefixed with "Atributo:").
 *   - Attach the original line number to each row for error reporting.
 *
 * Does NOT validate types or business rules — that is the validator's job.
 */

import {
  IMPORT_COLUMN_MAP,
  ATTRIBUTE_PREFIX,
  type RawImportRow,
} from "@/lib/import/types"

// ─── Public API ───────────────────────────────────────────────────────────────

export type ParseResult =
  | { ok: true;  rows: RawImportRow[] }
  | { ok: false; error: string }

/**
 * Parses a CSV (or XLSX-exported-as-CSV) File into raw import rows.
 * Each row retains its 1-based file line number for error messages.
 */
export async function parseImportFile(file: File): Promise<ParseResult> {
  try {
    const text = await readFileText(file)
    return parseImportText(text)
  } catch (err: any) {
    return { ok: false, error: err?.message ?? "No se pudo leer el archivo." }
  }
}

/**
 * Parses a raw CSV text string (used in tests and server-side processing).
 */
export function parseImportText(text: string): ParseResult {
  try {
    const clean = text.replace(/^﻿/, "")  // strip UTF-8 BOM
    const lines = clean.split(/\r?\n/)

    if (lines.length < 2) {
      return { ok: false, error: "El archivo no contiene datos (mínimo: encabezado + 1 fila)." }
    }

    const sep = lines[0].includes(";") ? ";" : ","
    const rawHeaders = parseLine(lines[0], sep)
    const headers = rawHeaders.map((h) => h.toLowerCase().trim())

    // ── Detect known columns ──────────────────────────────────────────────────
    const knownKeyIndices = new Map<string, number>()
    for (const col of IMPORT_COLUMN_MAP) {
      const idx = headers.indexOf(col.csvHeader.toLowerCase())
      if (idx >= 0) knownKeyIndices.set(col.key, idx)
    }

    // ── Detect dynamic attribute columns ─────────────────────────────────────
    // Header format: "Atributo: Color", "Atributo: Talle", etc.
    const attributeColumns: Array<{ attributeKey: string; colIndex: number }> = []
    for (let i = 0; i < headers.length; i++) {
      if (headers[i].startsWith(ATTRIBUTE_PREFIX)) {
        const attributeKey = headers[i]
          .slice(ATTRIBUTE_PREFIX.length)
          .trim()
          .toLowerCase()
        if (attributeKey) {
          attributeColumns.push({ attributeKey, colIndex: i })
        }
      }
    }

    // ── Parse data rows ───────────────────────────────────────────────────────
    const rows: RawImportRow[] = []

    for (let i = 1; i < lines.length; i++) {
      const line = lines[i]
      if (!line.trim()) continue

      const values = parseLine(line, sep)

      const get = (key: string): string =>
        knownKeyIndices.has(key)
          ? (values[knownKeyIndices.get(key)!] ?? "").trim()
          : ""

      // Skip entirely blank rows (all mapped fields empty)
      const nombre = get("nombre")
      const tipo   = get("tipo")
      if (!nombre && !tipo) continue

      // Extract dynamic attributes
      const attributes: Record<string, string> = {}
      for (const { attributeKey, colIndex } of attributeColumns) {
        const val = (values[colIndex] ?? "").trim()
        if (val) attributes[attributeKey] = val
      }

      rows.push({
        lineNumber:      i + 1,
        tipo:            tipo,
        nombre:          nombre,
        sku:             get("sku"),
        sku_padre:       get("sku_padre"),
        producto_padre:  get("producto_padre"),
        precio:          get("precio"),
        costo:           get("costo"),
        categoria:       get("categoria"),
        stock:           get("stock"),
        stock_minimo:    get("stock_minimo"),
        codigo:          get("codigo"),
        attributes,
      })
    }

    if (rows.length === 0) {
      return { ok: false, error: "El archivo no contiene filas de datos válidas." }
    }

    return { ok: true, rows }
  } catch (err: any) {
    return { ok: false, error: err?.message ?? "Error al parsear el archivo." }
  }
}

// ─── File reading ─────────────────────────────────────────────────────────────

const MAX_FILE_SIZE = 10 * 1024 * 1024  // 10 MB

function readFileText(file: File): Promise<string> {
  if (file.size > MAX_FILE_SIZE) {
    return Promise.reject(
      new Error(`El archivo supera el límite de 10 MB (${(file.size / 1024 / 1024).toFixed(1)} MB).`)
    )
  }
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload  = () => resolve(reader.result as string)
    reader.onerror = () => reject(new Error("No se pudo leer el archivo."))
    reader.readAsText(file, "UTF-8")
  })
}

// ─── RFC 4180 line parser ─────────────────────────────────────────────────────

function parseLine(line: string, sep: string): string[] {
  const result: string[] = []
  let current   = ""
  let inQuotes  = false

  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (inQuotes) {
      if (ch === '"') {
        if (i + 1 < line.length && line[i + 1] === '"') {
          current += '"'
          i++
        } else {
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
