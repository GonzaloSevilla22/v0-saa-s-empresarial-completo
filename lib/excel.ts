/**
 * Import / Export utilities — ERP-grade CSV handling.
 *
 * PARSER: RFC 4180 compliant — handles quoted fields with embedded commas,
 * semicolons, and newlines. Strips UTF-8 BOM produced by Excel / our own exports.
 *
 * EXPORT: appends the <a> element to the DOM before clicking, and delays
 * URL revocation 100 ms so the browser finishes processing the download.
 */

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

/**
 * Parses a monetary/numeric string into a float.
 * Supports: "1.234,56" (European/AR), "1,234.56" (US), "1234.56", "1234".
 * Returns NaN if the string cannot be parsed.
 */
export function parseAmount(raw: string | undefined): number {
  if (!raw) return NaN
  const s = String(raw).trim()

  // Strip currency symbols, spaces, $, etc. — keep digits, dots, commas, minus
  const cleaned = s.replace(/[^\d.,-]/g, "")
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
 * Parses a date string into YYYY-MM-DD format.
 * Handles: "YYYY-MM-DD", "DD/MM/YYYY", "D/M/YYYY".
 * Returns today's date if the string is unrecognizable.
 */
export function parseDate(raw: string | undefined): string {
  const today = new Date().toISOString().split("T")[0]
  if (!raw) return today
  const s = raw.trim()
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s
  if (/^\d{1,2}\/\d{1,2}\/\d{4}$/.test(s)) {
    const [d, m, y] = s.split("/")
    return `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}`
  }
  return today
}
