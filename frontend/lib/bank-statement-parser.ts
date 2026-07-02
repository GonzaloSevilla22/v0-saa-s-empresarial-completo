/**
 * Parser de extracto bancario (bank-reconciliation C3, design D2).
 *
 * El parseo vive en el CLIENTE: el backend recibe filas NORMALIZADAS
 * ({ line_no, value_date, description, amount, balance? }) — sin dependencias
 * de parsing en Render. Formato de entrada V1: CSV (los home bankings exportan
 * CSV; un Excel se guarda como CSV antes de subir — la UI lo documenta).
 *
 * Heurística de columnas por alias (es-AR + en), separador `;`/`,` autodetectado,
 * BOM UTF-8, fechas dd/mm/yyyy · dd-mm-yyyy · yyyy-mm-dd, montos formato
 * argentino ("1.234,56") o plano ("1234.56").
 */

export interface NormalizedStatementLine {
  line_no: number
  value_date: string // ISO yyyy-mm-dd
  description: string | null
  amount: string // decimal como string (sin float — RN-D4)
  balance: string | null
}

export type BankStatementParseResult =
  | { ok: true; lines: NormalizedStatementLine[] }
  | { ok: false; error: string }

const DATE_ALIASES = ["fecha valor", "fecha", "fecha operacion", "fecha operación", "fecha mov", "date"]
const DESC_ALIASES = ["descripcion", "descripción", "concepto", "detalle", "referencia", "movimiento", "description"]
const AMOUNT_ALIASES = ["importe", "monto", "amount", "importe ($)", "debito/credito", "débito/crédito"]
const BALANCE_ALIASES = ["saldo", "balance", "saldo ($)"]

export const MAX_STATEMENT_LINES = 5000

// ── Parseo ─────────────────────────────────────────────────────────────────────

export function parseBankStatementText(text: string): BankStatementParseResult {
  const clean = text.replace(/^﻿/, "")
  const rawLines = clean.split(/\r?\n/).filter((l) => l.trim() !== "")

  if (rawLines.length < 2) {
    return { ok: false, error: "El archivo no contiene datos (mínimo: encabezado + 1 fila)." }
  }

  const sep = rawLines[0].includes(";") ? ";" : ","
  const headers = splitCsvLine(rawLines[0], sep).map((h) => h.toLowerCase().trim())

  const dateIdx = findColumn(headers, DATE_ALIASES)
  const amountIdx = findColumn(headers, AMOUNT_ALIASES)
  const descIdx = findColumn(headers, DESC_ALIASES)
  const balanceIdx = findColumn(headers, BALANCE_ALIASES)

  if (dateIdx < 0 || amountIdx < 0) {
    return {
      ok: false,
      error:
        "No se reconocieron las columnas del extracto. Se esperan encabezados de " +
        "fecha (Fecha / Fecha valor) e importe (Importe / Monto); descripción y saldo son opcionales.",
    }
  }

  const lines: NormalizedStatementLine[] = []
  for (let i = 1; i < rawLines.length; i++) {
    const cells = splitCsvLine(rawLines[i], sep)
    const rawDate = (cells[dateIdx] ?? "").trim()
    const rawAmount = (cells[amountIdx] ?? "").trim()
    if (rawDate === "" && rawAmount === "") continue // fila decorativa/vacía

    const valueDate = parseDate(rawDate)
    if (!valueDate) {
      return { ok: false, error: `Fila ${i + 1}: fecha inválida "${rawDate}".` }
    }
    const amount = parseAmount(rawAmount)
    if (amount === null) {
      return { ok: false, error: `Fila ${i + 1}: importe inválido "${rawAmount}".` }
    }

    const balanceRaw = balanceIdx >= 0 ? (cells[balanceIdx] ?? "").trim() : ""
    const balance = balanceRaw !== "" ? parseAmount(balanceRaw) : null

    lines.push({
      line_no: lines.length + 1,
      value_date: valueDate,
      description: descIdx >= 0 ? (cells[descIdx] ?? "").trim() || null : null,
      amount,
      balance,
    })

    if (lines.length > MAX_STATEMENT_LINES) {
      return { ok: false, error: `El extracto supera el máximo de ${MAX_STATEMENT_LINES} líneas por import.` }
    }
  }

  if (lines.length === 0) {
    return { ok: false, error: "El archivo no contiene filas de movimientos válidas." }
  }

  return { ok: true, lines }
}

export async function parseBankStatementFile(file: File): Promise<BankStatementParseResult> {
  try {
    const text = await file.text()
    return parseBankStatementText(text)
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "No se pudo leer el archivo." }
  }
}

/** SHA-256 hex del contenido del archivo — dedupe de dominio del import (D2). */
export async function hashFileSHA256(file: File): Promise<string> {
  const buffer = await file.arrayBuffer()
  const digest = await crypto.subtle.digest("SHA-256", buffer)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

// ── Helpers ────────────────────────────────────────────────────────────────────

function findColumn(headers: string[], aliases: string[]): number {
  for (const alias of aliases) {
    const idx = headers.findIndex((h) => h === alias || h.startsWith(alias))
    if (idx >= 0) return idx
  }
  return -1
}

/** Split CSV respetando comillas dobles. */
function splitCsvLine(line: string, sep: string): string[] {
  const cells: string[] = []
  let current = ""
  let inQuotes = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"'
        i++
      } else {
        inQuotes = !inQuotes
      }
    } else if (ch === sep && !inQuotes) {
      cells.push(current)
      current = ""
    } else {
      current += ch
    }
  }
  cells.push(current)
  return cells
}

/** dd/mm/yyyy · dd-mm-yyyy · yyyy-mm-dd → ISO yyyy-mm-dd (o null). */
export function parseDate(raw: string): string | null {
  const iso = raw.match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (iso) {
    return isValidDate(+iso[1], +iso[2], +iso[3]) ? raw : null
  }
  const arg = raw.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/)
  if (arg) {
    const [, d, m, y] = arg
    if (!isValidDate(+y, +m, +d)) return null
    return `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}`
  }
  return null
}

function isValidDate(y: number, m: number, d: number): boolean {
  if (m < 1 || m > 12 || d < 1 || d > 31) return false
  const date = new Date(Date.UTC(y, m - 1, d))
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d
}

/**
 * "1.234,56" (AR) · "1234.56" · "-350" · "$ -1.234,56" → decimal string (o null).
 * Nunca float: se devuelve string para que el backend lo tome como NUMERIC (RN-D4).
 */
export function parseAmount(raw: string): string | null {
  let s = raw.replace(/[$\s]/g, "")
  if (s === "") return null

  const negative = s.startsWith("-") || (s.startsWith("(") && s.endsWith(")"))
  s = s.replace(/[()-]/g, "")

  const hasComma = s.includes(",")
  const hasDot = s.includes(".")

  if (hasComma && hasDot) {
    // el separador decimal es el que aparece último
    if (s.lastIndexOf(",") > s.lastIndexOf(".")) {
      s = s.replace(/\./g, "").replace(",", ".") // AR: 1.234,56
    } else {
      s = s.replace(/,/g, "") // US: 1,234.56
    }
  } else if (hasComma) {
    s = s.replace(",", ".") // 1234,56
  }

  if (!/^\d+(\.\d+)?$/.test(s)) return null
  const normalized = negative ? `-${s}` : s
  return normalized
}
